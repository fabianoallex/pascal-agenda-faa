# The desktop client by hand (M6)

What the smoke (`client/desktop/smoke`) can't judge: a person using the program, on the VCL
(Delphi) and on the LCL (Lazarus/FPC). Each step says what to do and what should happen. Mark
each one in the table at the end, for both builds. Anything that looks wrong, even if it
works (a clipped label, a focus that jumps, a slow screen), goes in the notes.

## Setup

1. The api, on a database with data. `tools/test_http.sh` leaves `agenda-scenarios.sqlite`
   next to the api it ran (tenant `demo`, users, services, professionals). In the api's folder
   (`api/Win32/Debug/` for Delphi), a `.env`:

   ```
   DEV_MODE=true
   DB_FILE=agenda-scenarios.sqlite
   PORT=9410
   ```

   Start it: `api/Win32/Debug/AgendaApi.exe` (or `AgendaApi.exe 9410`).
2. The desktop, a `.env` next to each build:
   - VCL: `client/desktop/Win32/Debug/AgendaDesktop.exe` → `client/desktop/Win32/Debug/.env`
   - LCL: `client/desktop/AgendaDesktop.exe` → `client/desktop/.env`

   ```
   AGENDA_SERVER=http://127.0.0.1:9410
   AGENDA_TENANT=demo
   AGENDA_EMAIL=owner@demo.test
   ```

   The password is `correct horse battery staple`.

   Save each `.env` as UTF-8. PowerShell 5.1's `>` writes UTF-16, which stops the VCL build
   with EEncodingError and leaves the LCL build on the defaults, saying nothing (a library
   fault, recorded in `docs/design.md`). Write it with
   `Set-Content -Encoding utf8 .env -Value 'KEY=value', ...`, or in an editor as UTF-8.
3. Some steps need a second window on the same server: start the same program twice (two
   instances, the same user is fine).

## 1. Login

| # | Do | Expected |
|---|---|---|
| 1.1 | Open the program | "Agenda: log in", Server, Company and Email filled from the `.env`; Tab goes Server, Company, Email, Password, Log in |
| 1.2 | Clear Company | Log in disabled; filled again, enabled |
| 1.3 | A wrong password, Enter | "Logging in...", then "Wrong company, email or password." in red; the dialog stays |
| 1.4 | The right password, Enter | The dialog closes, the day window opens on today |
| 1.5 | Open again, press Esc | The program ends without an error |
| 1.6 | Stop the api, try to log in | "The server didn't answer. Check the connection and try again." (after a few seconds: the GET retries); start the api again before going on |

## 2. The day

| # | Do | Expected |
|---|---|---|
| 2.1 | Look at the window | Date between `<` and `>`, the professional, the columns Time, Customer, Service, Professional, Status; the bottom line "Appointments: N (America/Sao_Paulo)" |
| 2.2 | `>`, `<`, Today | The date changes, "Reading the day..." briefly, the list follows; Today comes back |
| 2.3 | Click `>` several times fast | No flicker of an old day at the end: the last day asked for is the one shown |
| 2.4 | Change the professional | The list is that professional's day |
| 2.5 | F5 and Reload (F5) | The day read again; the selected row stays selected (it follows the appointment, not the line) |
| 2.6 | Nothing selected | Move, Confirm, Done, No show, Cancel it disabled |
| 2.7 | Resize the window, maximize | The list grows; the top and bottom bars stay whole; nothing clipped |
| 2.8 | Leave it open over 60 s while the second window books on this day | The first window shows the new appointment by itself (the 60 s reload) |

## 3. Booking

| # | Do | Expected |
|---|---|---|
| 3.1 | Book... | "Agenda: book", service and professional lists filled, the day of the main window |
| 3.2 | Pick a service and a professional | Free times listed; a day with none says "No free time on this day." |
| 3.3 | `<` / `>` | Another day's free times |
| 3.4 | Type part of a name without accents (`joao`, `conceicao`), Find customer | Customers with accents found (`João`, `Conceição`), shown with the accents |
| 3.5 | New... next to the search | The customer dialog; save one, it comes back already chosen in the list |
| 3.6 | A time and a customer chosen, Book (or Enter) | The dialog closes; the day shows the appointment at that time, status booked |
| 3.7 | Both windows on the same free time, book in one, then in the other | The second says "That time was just taken. The free times were read again." and the time is gone from its list |
| 3.8 | Close with Esc | Closes, nothing booked |

## 4. Changing an appointment

| # | Do | Expected |
|---|---|---|
| 4.1 | Select a booked appointment | Move, Confirm and Cancel it enabled; Done and No show only once its time has started |
| 4.2 | Confirm | Status confirmed; Confirm disabled, Cancel it still enabled |
| 4.3 | Both windows on the same appointment: confirm in one, cancel in the other without reloading | The second says "Someone changed this appointment first. The day was read again." and shows the new status |
| 4.4 | An appointment already started: Done, another one No show | The statuses change; afterwards none of the buttons is enabled for them |
| 4.5 | Cancel it | Status cancelled; nothing left enabled for it |

## 5. Moving

| # | Do | Expected |
|---|---|---|
| 5.1 | Select a booked or confirmed appointment, Move... | "Agenda: move", the line "customer: service with professional, now at hh:mm", the free times of that day |
| 5.2 | `<` / `>` | Other days' free times |
| 5.3 | A time, Move (or Enter) | The dialog closes, the day reads again, the appointment at its new time |
| 5.4 | Both windows: open Move on the same appointment, move in one, then in the other | The second says "Someone changed this appointment first. Close this window: the day is read again." and Move stays disabled |
| 5.5 | Known limit, not a failure | Times that overlap the appointment's current time aren't offered |

## 6. Customers

| # | Do | Expected |
|---|---|---|
| 6.1 | Customers... | The list (Name, Phone, Email), "Page 1 of N", "Customers: total" |
| 6.2 | Search without accents (Enter in the box) | Found, as in 3.4 |
| 6.3 | `<` / `>` (more than 20 customers) | Pages change; `<` disabled on the first, `>` on the last |
| 6.4 | Edit... with nothing selected | Disabled; select a row, enabled; a double click edits too |
| 6.5 | New..., only a name with spaces | Save disabled, "A name is required." |
| 6.6 | New..., phone `12`, Save | The server's message about the phone in red; the dialog stays |
| 6.7 | Phone `+55 11 99999-0000`, Save | Closes; the list searched by the name, the new one selected, phone `+5511999990000` |
| 6.8 | Edit it, change nothing | Save disabled |
| 6.9 | Clear the email, Save | Closes; the email column empty; reopened, still empty |
| 6.10 | A name with accents (`Conceição Ávila`) | Saved and shown with the accents, in the list and in the booking search |

## 7. Failures and closing

| # | Do | Expected |
|---|---|---|
| 7.1 | Stop the api, F5 | "The server didn't answer. Check the connection and try again." in red; the window keeps working; start the api, F5 reads the day |
| 7.2 | Stop the api, Book... | The booking dialog shows the same message; Close works |
| 7.3 | Restart the api with `ACCESS_TOKEN_SECONDS=30` in its `.env`, log in, wait over 30 s, F5 | Reads normally (the token renewed without asking) |
| 7.4 | Restart it with `REFRESH_TOKEN_SECONDS=60` too, log in, wait over 60 s, F5 | "Agenda: your session ended, log in again", Server and Company disabled, the focus on Password; the password typed, the day goes on; Esc there ends the program. Take both lines out of the api's `.env` afterwards |
| 7.5 | Stop the api, F5, and close the window at once | The program ends in a few seconds, no error, no hanging process |
| 7.6 | Close the day window normally | The program ends; the api's log shows `POST /auth/logout` |
| 7.7 | Delphi Debug build | No memory leak report when the program ends |

## 8. Tracing (optional)

1. `python tools/otlp_sink.py 9411 traces.json` in a terminal (a stand-in collector).
2. Add `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:9411` to the desktop's `.env`.
3. Log in, book, move, cancel, close the program.
4. `traces.json` has lines with `"agenda-desktop"`; `python tools/desktop_traces.py traces.json
   <api log>` checks them (it expects every action the smoke does, so a short session reports
   the missing ones; the rest of its checks still apply).

Take the line out of the `.env` afterwards.

## Results

| Section | VCL | LCL | Notes |
|---|---|---|---|
| 1. Login | | | |
| 2. The day | | | |
| 3. Booking | | | |
| 4. Changing an appointment | | | |
| 5. Moving | | | |
| 6. Customers | | | |
| 7. Failures and closing | | | |
| 8. Tracing | | | |
