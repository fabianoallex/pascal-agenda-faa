#!/bin/sh
# The api's commands (--create-tenant, --create-user, ...) inside the running
# docker-compose.yml stack, so tools/seed_scenarios.sh can take this script
# as its executable. AGENDA_PASSWORD goes into the container when set.
cd "$(dirname "$0")/.." || exit 1
# Git Bash would turn /app/AgendaApi into a Windows path (and so the compose
# file is found in the current directory, not by a -f path).
export MSYS_NO_PATHCONV=1
if [ -n "$AGENDA_PASSWORD" ]; then
  exec docker compose exec -T -e AGENDA_PASSWORD="$AGENDA_PASSWORD" api /app/AgendaApi "$@"
fi
exec docker compose exec -T api /app/AgendaApi "$@"
