#!/bin/sh
# docker-compose.yml end to end: builds the api and the worker (FPC 3.2.2 on
# Linux, docker/Dockerfile), starts the stack and waits for its health
# checks, seeds it (tools/seed_scenarios.sh through tools/compose_api.sh),
# runs tools/http_scenarios_mail.sh (the email in Mailpit, one trace in the
# collector), stops the worker with SIGTERM and checks it stopped cleanly,
# and removes the stack and its volumes.
#
# Needs the CI image (agenda-fpc322: sh tools/ci-test.sh builds it, or set
# FPC_IMAGE). Host ports of its own, so a development stack or another
# broker on the defaults doesn't collide: 19400, 18025 and 25672
# (AGENDA_PORT, MAILPIT_PORT, RABBITMQ_UI_PORT). KEEP=1 leaves it running.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export PASSWORD_ITERATIONS=20000 AUTH_RATE_LIMIT=60 AMQP_RETRY_MS=2000
export AGENDA_PORT="${AGENDA_PORT:-19400}" MAILPIT_PORT="${MAILPIT_PORT:-18025}"
export RABBITMQ_UI_PORT="${RABBITMQ_UI_PORT:-25672}"
COMPOSE="docker compose -f $ROOT/docker-compose.yml"

cleanup() {
  [ "${KEEP:-}" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT
$COMPOSE down -v >/dev/null 2>&1 || true
echo "== build and start"
$COMPOSE up -d --build --wait
echo "== seed"
sh tools/seed_scenarios.sh "$ROOT/tools/compose_api.sh" > /dev/null
echo "== mail and trace"
RC=0
sh tools/http_scenarios_mail.sh "$AGENDA_PORT" "$MAILPIT_PORT" || RC=$?
echo "== the worker stopped (SIGTERM)"
$COMPOSE stop worker >/dev/null
LOG="$($COMPOSE logs worker 2>&1)"
echo "$LOG" | grep -q "agenda-worker stopped" || { echo "FAIL: no clean stop"; echo "$LOG" | tail -20; RC=1; }
STATE="$($COMPOSE ps -a --format '{{.ExitCode}}' worker)"
[ "$STATE" = 0 ] || { echo "FAIL: the worker exited $STATE"; RC=1; }
if echo "$LOG" | grep -q "ERROR"; then
  echo "FAIL: the worker logged errors"; echo "$LOG" | grep ERROR | head -10; RC=1
fi
[ $RC -eq 0 ] && echo "ok: compose, mail through RabbitMQ and SMTP, one trace, a clean stop"
exit $RC
