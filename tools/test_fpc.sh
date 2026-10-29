#!/bin/sh
# Regenerates the FPCUnit mirrors from the DUnitX masters, then builds and
# runs the unit suite on FPC (Windows, through lazbuild). Acceptance
# criterion: 0 errors, 0 failures and "0 unfreed memory blocks" (heaptrc).
#
# Delphi: build tests\Unit\Agenda.UnitTests.dproj in the IDE (Community
# Edition doesn't compile from the command line), then run the .exe.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe

cd "$ROOT"
python tools/gen_fpc_mirror.py
# Accented text is written as it reads ('João', never escapes), in a source
# saved as UTF-8 with a BOM: without one, Delphi reads the file in the ANSI
# code page and FPC (here) in UTF-8, so the literal passes on FPC and fails
# on Delphi (2026-10-29, "JoÃ£o").
python - <<'EOF'
import glob, sys
bad = [f for f in glob.glob('src/*.pas') + glob.glob('tests/**/*.pas', recursive=True)
       + glob.glob('client/**/*.pas', recursive=True)
       + [f for f in glob.glob('*/**/*.dpr', recursive=True) if not f.startswith('external')]
       if not open(f, 'rb').read().startswith(b'\xef\xbb\xbf')
       and any(c > 127 for c in open(f, 'rb').read())]
if bad:
    print('non-ASCII text in a source without a BOM (save it as UTF-8 with a BOM):', *bad)
    sys.exit(1)
EOF
# Agenda.OutboxTests opens SQLite: SQLdb loads sqlite3.dll next to the runner,
# and it must be sqlite.org's build (pascal-db-faa gotcha 23).
DLL="${SQLITE_DLL:-.deps/sqlite3.dll}"
[ -f "$DLL" ] || { echo "no sqlite.org sqlite3.dll: set SQLITE_DLL or put one in .deps/sqlite3.dll"; exit 1; }
cp "$DLL" tests/Unit/fpc/sqlite3.dll
cd tests/Unit/fpc
# Never pipe lazbuild into head: it hangs when the pipe closes.
if ! "$LAZBUILD" -B AgendaUnitTestsFpc.lpi > build.log 2>&1; then
  grep -E "Error|Fatal" build.log | head -30
  exit 1
fi
./AgendaUnitTestsFpc.exe --all --format=plain > run.log 2>&1 || true
grep -E "^Number of|unfreed" run.log
grep -A4 "Message:" run.log | head -40 || true
grep -qE "^Number of errors: +0$" run.log && grep -qE "^Number of failures: +0$" run.log \
  && grep -qE "^0 unfreed memory blocks" run.log
