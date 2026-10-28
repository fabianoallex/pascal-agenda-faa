// The api under load (docs/design.md, M5 decision 7), for k6 (grafana/k6 in
// Docker; tools/load_test.sh runs it). One tenant ("load" by default) made
// by the runner with an owner and a staff user; setup() adds what the run
// books on: professionals open every day 08:00-20:00, two services, customers.
//
// Scenarios, at once, for DURATION:
//   reads     the free slots, the day, the appointments, the services, the
//             customers (a search), as a front desk would
//   bookings  a staff user books a free slot it just read (201; 409 when
//             another booking took it meanwhile), and confirms one in ten
//             with If-Match
//   race      RACE_GROUP bookings of the same slot arrive together, on a
//             professional of its own: one 201, the others 409
//   public    the public catalog and free slots (no token)
//
// What fails a run (thresholds): any 5xx or network error
// (http_req_failed: 4xx are answers here, http.expectedStatuses), a check
// that failed (an unexpected status), two bookings of one slot (teardown
// reads every day booked through /agenda/day). The speed is recorded, not
// gated. tools/load_check.py compares the counts with the api's /metrics.
//
// Environment: BASE (http://host.docker.internal:9500), SLUG (load),
// PASSWORD, DURATION (60s), VUS (20: reads; bookings half; public a fifth),
// RACE_RATE (20 iterations a second), RACE_GROUP (4), RUN (a tag for the
// names, so passes don't meet).
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';
import exec from 'k6/execution';

const BASE = __ENV.BASE || 'http://host.docker.internal:9500';
const SLUG = __ENV.SLUG || 'load';
const PASSWORD = __ENV.PASSWORD || 'correct horse battery staple';
const DURATION = __ENV.DURATION || '60s';
const VUS = parseInt(__ENV.VUS || '20', 10);
const RACE_RATE = parseInt(__ENV.RACE_RATE || '20', 10);
const RACE_GROUP = parseInt(__ENV.RACE_GROUP || '4', 10);
const RUN = __ENV.RUN || String(Date.now());
const PROS = 4;
const DAYS = 14;
// The tenant's zone is America/Sao_Paulo (UTC-3, no daylight saving): 08:00
// there is 11:00Z.
const OPEN_UTC_HOUR = 11;
const SLOTS_PER_DAY = 24; // 30-minute slots, 08:00-20:00
const RACE_FIRST_DAY = 30;

export const booked = new Counter('agenda_booked');
export const conflicts = new Counter('agenda_conflicts');
export const raceBooked = new Counter('agenda_race_booked');
export const raceConflicts = new Counter('agenda_race_conflicts');
export const doubleBookings = new Counter('agenda_double_bookings');

http.setResponseCallback(http.expectedStatuses({ min: 200, max: 499 }));

// A failed check, with what came back: the first few of each virtual user
// go to k6's log (the summary only counts them).
let reported = 0;
function verify(r, name, ok) {
  const passed = check(r, { [name]: ok });
  if (!passed && reported < 3) {
    reported++;
    console.warn(name + ': ' + r.request.method + ' ' + r.url.replace(BASE, '') + ' status ' +
      r.status + (r.error ? ' (' + r.error_code + ' ' + r.error + ')' : '') +
      (r.status >= 500 ? ': ' + String(r.body).slice(0, 200) : ''));
  }
  return passed;
}

export const options = {
  setupTimeout: '120s',
  teardownTimeout: '180s',
  summaryTrendStats: ['avg', 'p(50)', 'p(95)', 'p(99)', 'max'],
  thresholds: {
    http_req_failed: ['rate==0'],
    checks: ['rate==1'],
    agenda_double_bookings: ['count==0'],
  },
  scenarios: {
    reads: { executor: 'constant-vus', exec: 'reads', vus: VUS, duration: DURATION },
    bookings: {
      executor: 'constant-vus', exec: 'bookings', vus: Math.max(1, Math.floor(VUS / 2)),
      duration: DURATION,
    },
    race: {
      executor: 'constant-arrival-rate', exec: 'race', rate: RACE_RATE, timeUnit: '1s',
      duration: DURATION, preAllocatedVUs: RACE_GROUP * 4, maxVUs: RACE_GROUP * 8,
    },
    public: {
      executor: 'constant-vus', exec: 'publicReads', vus: Math.max(1, Math.floor(VUS / 5)),
      duration: DURATION,
    },
  },
};

const JSON_HEADERS = { headers: { 'Content-Type': 'application/json' } };

// "90s", "2m", "1m30s" in seconds.
function durationSeconds(text) {
  let total = 0;
  const re = /(\d+)(h|m|s)/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    total += parseInt(m[1], 10) * { h: 3600, m: 60, s: 1 }[m[2]];
  }
  return total || 60;
}

function auth(token, extra) {
  return { headers: Object.assign({ Authorization: 'Bearer ' + token }, extra || {}) };
}

function post(path, body, token, extra) {
  const params = auth(token, Object.assign({ 'Content-Type': 'application/json' }, extra || {}));
  return http.post(BASE + path, JSON.stringify(body), params);
}

function login(email) {
  const r = http.post(BASE + '/auth/login', JSON.stringify({ tenant: SLUG, email, password: PASSWORD }),
    JSON_HEADERS);
  if (r.status !== 200) {
    throw new Error('login ' + email + ': ' + r.status + ' ' + r.body);
  }
  return r.json('accessToken');
}

function dayString(offset) {
  const d = new Date(Date.now() + offset * 86400000);
  return d.toISOString().slice(0, 10);
}

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

export function setup() {
  const owner = login('owner@' + SLUG + '.test');
  const staff = login('staff@' + SLUG + '.test');
  const week = [];
  for (let d = 1; d <= 7; d++) {
    week.push({ weekday: d, from: '08:00', to: '20:00' });
  }
  const pros = [];
  for (let i = 0; i <= PROS; i++) {
    const r = post('/professionals', { name: 'Load Pro ' + RUN + ' ' + i }, owner);
    if (r.status !== 201) throw new Error('professional: ' + r.status + ' ' + r.body);
    const id = r.json('id');
    const w = http.put(BASE + '/professionals/' + id + '/working-hours',
      JSON.stringify({ intervals: week }),
      auth(owner, { 'Content-Type': 'application/json' }));
    if (w.status !== 200) throw new Error('working hours: ' + w.status + ' ' + w.body);
    pros.push(id);
  }
  const services = [];
  for (const [name, minutes] of [['Load Cut ', 30], ['Load Color ', 60]]) {
    const r = post('/services', { name: name + RUN, durationMinutes: minutes, price: 50 }, owner);
    if (r.status !== 201) throw new Error('service: ' + r.status + ' ' + r.body);
    services.push(r.json('id'));
  }
  const customers = [];
  for (let i = 0; i < 20; i++) {
    const r = post('/customers', { name: 'Load Customer ' + RUN + ' ' + i }, staff);
    if (r.status !== 201) throw new Error('customer: ' + r.status + ' ' + r.body);
    customers.push(r.json('id'));
  }
  const dates = [];
  for (let i = 1; i <= DAYS; i++) dates.push(dayString(i));
  // The last professional is the race's alone; the others take the bookings.
  return { owner, staff, pros: pros.slice(0, PROS), racePro: pros[PROS], services, customers, dates };
}

export function reads(data) {
  const n = Math.random();
  let r;
  if (n < 0.35) {
    r = http.get(BASE + '/professionals/' + pick(data.pros) + '/availability?service=' +
      pick(data.services) + '&date=' + pick(data.dates), auth(data.staff));
  } else if (n < 0.6) {
    r = http.get(BASE + '/agenda/day?date=' + pick(data.dates), auth(data.staff));
  } else if (n < 0.8) {
    r = http.get(BASE + '/appointments?limit=20&page=' + (1 + Math.floor(Math.random() * 3)),
      auth(data.staff));
  } else if (n < 0.9) {
    r = http.get(BASE + '/services', auth(data.staff));
  } else {
    r = http.get(BASE + '/customers?search=Load', auth(data.staff));
  }
  verify(r, 'reads: 200', (x) => x.status === 200);
}

export function bookings(data) {
  const pro = pick(data.pros);
  const service = pick(data.services);
  const r = http.get(BASE + '/professionals/' + pro + '/availability?service=' + service +
    '&date=' + pick(data.dates), auth(data.staff));
  verify(r, 'bookings: availability 200', (x) => x.status === 200);
  if (r.status !== 200) return;
  const slots = r.json('slots');
  if (!slots || slots.length === 0) return;
  const b = post('/appointments', {
    professionalId: pro, serviceId: service, customerId: pick(data.customers),
    startsAt: pick(slots).startsAt,
  }, data.staff, { 'Idempotency-Key': 'load-' + RUN + '-' + exec.vu.idInTest + '-' + exec.vu.iterationInScenario });
  verify(b, 'bookings: 201 or 409', (x) => x.status === 201 || x.status === 409);
  if (b.status === 201) {
    booked.add(1);
    if (Math.random() < 0.1) {
      const c = http.patch(BASE + '/appointments/' + b.json('id'), JSON.stringify({ status: 'confirmed' }),
        auth(data.staff, { 'Content-Type': 'application/json', 'If-Match': '"' + b.json('version') + '"' }));
      verify(c, 'bookings: confirm 200', (x) => x.status === 200);
    }
  } else if (b.status === 409) {
    conflicts.add(1);
  }
}

export function race(data) {
  // RACE_GROUP consecutive iterations share a slot: one books, the rest 409.
  const index = Math.floor(exec.scenario.iterationInTest / RACE_GROUP);
  const day = RACE_FIRST_DAY + Math.floor(index / SLOTS_PER_DAY);
  const slot = index % SLOTS_PER_DAY;
  const start = new Date(dayString(day) + 'T00:00:00Z');
  start.setUTCHours(OPEN_UTC_HOUR, slot * 30, 0, 0);
  const b = post('/appointments', {
    professionalId: data.racePro, serviceId: data.services[0], customerId: pick(data.customers),
    startsAt: start.toISOString().replace('.000Z', 'Z'),
  }, data.staff);
  verify(b, 'race: 201 or 409', (x) => x.status === 201 || x.status === 409);
  if (b.status === 201) raceBooked.add(1);
  else if (b.status === 409) raceConflicts.add(1);
}

export function publicReads(data) {
  let r;
  if (Math.random() < 0.5) {
    r = http.get(BASE + '/public/' + SLUG + '/services');
  } else {
    r = http.get(BASE + '/public/' + SLUG + '/professionals/' + pick(data.pros) +
      '/availability?service=' + pick(data.services) + '&date=' + pick(data.dates));
  }
  // 429: the public limit by address (k6 is one address); an answer, not a failure.
  verify(r, 'public: 200 or 429', (x) => x.status === 200 || x.status === 429);
}

// No two active appointments of one professional overlap, on every day the
// run booked: the database's word, read back through the api.
export function teardown(data) {
  const days = data.dates.slice();
  const raceDays = Math.ceil((RACE_RATE * durationSeconds(DURATION)) / RACE_GROUP / SLOTS_PER_DAY) + 1;
  for (let i = 0; i < raceDays; i++) days.push(dayString(RACE_FIRST_DAY + i));
  const pros = data.pros.concat([data.racePro]);
  let seen = 0;
  for (const pro of pros) {
    for (const date of days) {
      const r = http.get(BASE + '/agenda/day?date=' + date + '&professional=' + pro, auth(data.staff));
      if (!check(r, { 'teardown: the day 200': (x) => x.status === 200 })) continue;
      const active = r.json('appointments').filter((a) => a.status !== 'cancelled')
        .map((a) => [Date.parse(a.startsAt), Date.parse(a.endsAt), a.id])
        .sort((x, y) => x[0] - y[0]);
      seen += active.length;
      for (let i = 1; i < active.length; i++) {
        if (active[i][0] < active[i - 1][1]) {
          doubleBookings.add(1);
          console.error('double booking: ' + active[i - 1][2] + ' and ' + active[i][2]);
        }
      }
    }
  }
  console.log('teardown: ' + seen + ' active appointments checked, no overlap expected');
}
