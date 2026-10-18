# pascal-agenda-faa — Guide for AI agents

A real application on the `*-faa` libraries, to validate them. Scope, decisions, milestones
and the list of library candidates: `docs/design.md`. Read it first.

- Everything in English (code, comments, docs, commits), as in the libraries.
- Dual-compiler (Delphi + FPC 3.2.2): follow the `dual-compiler-delphi-lazarus` and
  `using-faa-libraries` skills; the libraries' code rules apply here too.
- The libraries are submodules in `external/`, one copy each. Don't patch them here: a
  problem in a library is fixed there (or recorded as a candidate in `docs/design.md`).
- A piece that looks reusable is written in its own unit, under the libraries' rules, and
  listed in `docs/design.md` ("Library candidates"). Promoting it is the user's decision.
- Acceptance: 0 errors, 0 failures, 0 leaks on FPC (Windows, Linux) and Delphi (Win32, Win64).
