#!/bin/sh
# Everything CI runs (.github/workflows/ci.yml), also runnable locally with
# Docker: the API built with FPC 3.2.2 on Linux and checked over HTTP
# (tools/test_http_docker.sh). Delphi Community Edition can't build
# headless, so the Delphi side is checked in the IDE (README, "Building").
#
# FPC image: built here from Debian bookworm's fpc package (3.2.2) and tagged
# agenda-fpc322, unless FPC_IMAGE names an existing one.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -z "${FPC_IMAGE:-}" ]; then
  FPC_IMAGE=agenda-fpc322
  docker build -q -t "$FPC_IMAGE" - <<'DOCKERFILE' >/dev/null
FROM debian:bookworm
RUN apt-get update && apt-get install -y --no-install-recommends fpc curl ca-certificates libsqlite3-0 python3-pip && rm -rf /var/lib/apt/lists/* && pip3 install --no-cache-dir --break-system-packages openapi-spec-validator==0.7.1
RUN curl -fsSL https://github.com/prometheus/prometheus/releases/download/v2.53.0/prometheus-2.53.0.linux-amd64.tar.gz | tar -xz -C /usr/local/bin --strip-components=1 prometheus-2.53.0.linux-amd64/promtool
DOCKERFILE
fi
export FPC_IMAGE

echo "== unit suite (FPC 3.2.2, Linux)"
sh tools/test_fpc_docker.sh
echo "== HTTP scenarios (FPC 3.2.2, Linux)"
sh tools/test_http_docker.sh
