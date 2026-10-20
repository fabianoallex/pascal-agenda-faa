#!/bin/sh
# Creates, through the API's own commands, what tools/http_scenarios.sh
# expects in a fresh database (DB_FILE, or the default next to the
# executable): tenants demo and other, frozen (suspended), and their users.
#
#   sh tools/seed_scenarios.sh <path to AgendaApi executable>
#
# The passwords are the scenarios' (SCENARIO_PASSWORD), development only.
set -e
EXE="$1"
[ -n "$EXE" ] || { echo "usage: seed_scenarios.sh <AgendaApi executable>"; exit 1; }
PASSWORD="${SCENARIO_PASSWORD:-correct horse battery staple}"

"$EXE" --create-tenant demo "Demo Clinic" America/Sao_Paulo
"$EXE" --create-tenant other "Other Salon" Europe/Lisbon
"$EXE" --create-tenant frozen "Frozen Spa" America/New_York
AGENDA_PASSWORD="$PASSWORD" "$EXE" --create-user demo owner@demo.test owner
AGENDA_PASSWORD="$PASSWORD" "$EXE" --create-user demo staff@demo.test staff
AGENDA_PASSWORD="$PASSWORD" "$EXE" --create-user other owner@other.test owner
AGENDA_PASSWORD="$PASSWORD" "$EXE" --create-user frozen owner@frozen.test owner
"$EXE" --suspend-tenant frozen

# The commands refuse what they should.
if "$EXE" --create-tenant demo "Again" Europe/Lisbon >/dev/null 2>&1; then
  echo "FAIL: a second tenant demo was accepted"; exit 1
fi
if AGENDA_PASSWORD="$PASSWORD" "$EXE" --create-user demo owner@demo.test owner >/dev/null 2>&1; then
  echo "FAIL: a second owner@demo.test was accepted"; exit 1
fi
if "$EXE" --create-user demo nobody@demo.test owner >/dev/null 2>&1; then
  echo "FAIL: a user without AGENDA_PASSWORD was accepted"; exit 1
fi
if AGENDA_PASSWORD="$PASSWORD" "$EXE" --create-user nowhere x@nowhere.test owner >/dev/null 2>&1; then
  echo "FAIL: a user of an unknown tenant was accepted"; exit 1
fi
if "$EXE" --create-tenant mars "Mars Clinic" Mars/Olympus_Mons >/dev/null 2>&1; then
  echo "FAIL: an unknown time zone was accepted"; exit 1
fi
if OUT=$("$EXE" --create-tenant lower "Lower Clinic" america/sao_paulo 2>&1); then
  echo "FAIL: a time zone in the wrong case was accepted"; exit 1
fi
case "$OUT" in
  *'did you mean "America/Sao_Paulo"'*) ;;
  *) echo "FAIL: no spelling hint for america/sao_paulo: $OUT"; exit 1 ;;
esac
echo "seed: 3 tenants, 4 users; 6 refusals checked"
