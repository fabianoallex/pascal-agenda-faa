#!/bin/sh
# Builds and runs the unit suite on Linux FPC inside a Docker container, with
# heaptrc. Acceptance criterion: 0 errors, 0 failures, 0 unfreed blocks.
#
# heaptrc on Linux writes its summary only to a log file (HEAPTRC=log=...):
# a check that only reads the console passes on a leak.
#
# DOCKER_CPUS=1 runs it on one CPU, where a race between threads shows.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-agenda-fpc322}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
python3 tools/gen_fpc_mirror.py --check 2>/dev/null || python tools/gen_fpc_mirror.py --check

CPUS=""
[ -n "${DOCKER_CPUS:-}" ] && CPUS="--cpus=$DOCKER_CPUS"
# $CPUS unquoted on purpose: empty, or one argument.
MSYS_NO_PATHCONV=1 docker run --rm $CPUS -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
  set -e
  mkdir -p /t/u && cp -r /src/src /src/tests /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src"
  P="$P -Fu$E/pascal-api-infra-faa/src -Fi$E/pascal-api-infra-faa/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src -Fu$E/pascal-db-faa/adapters/sqldb"
  P="$P -Fu$E/pascal-redis-faa/src -Fi$E/pascal-redis-faa/src -Fu$E/synapse -Fi$E/synapse"
  cd /t/tests/Unit/fpc
  fpc -v0 -Mdelphi $P -FU/t/u -gh -gl -o/t/runner AgendaUnitTestsFpc.lpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t
  HEAPTRC="log=/t/heap.txt" ./runner --all --format=plain > /t/run.log 2>&1 || true
  grep -E "^Number of" /t/run.log
  grep "unfreed" /t/heap.txt
  grep -A4 "Message:" /t/run.log | head -40 || true
  grep -qE "^Number of errors: +0$" /t/run.log && grep -qE "^Number of failures: +0$" /t/run.log \
    && grep -qE "^0 unfreed memory blocks" /t/heap.txt'
