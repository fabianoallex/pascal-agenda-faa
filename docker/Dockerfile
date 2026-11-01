# The api and the worker, built with plain fpc (FPC 3.2.2) on Linux, for
# docker-compose.yml. The build stage is the CI image (tools/ci-test.sh builds
# agenda-fpc322: Debian bookworm's fpc); the run stage only has what the two
# programs load at run time: libsqlite3, libpq, OpenSSL 3 (Synapse's SMTP over
# TLS) and curl (the api's health check). The context is the repository's
# root (.dockerignore keeps the build outputs out).
ARG FPC_IMAGE=agenda-fpc322

FROM ${FPC_IMAGE} AS build
WORKDIR /b
COPY src src
COPY api api
COPY worker worker
COPY external external
# The same paths as tools/test_http_docker.sh's: every library from its
# submodule, one copy each.
RUN set -e; E=/b/external; \
  P="-Fu/b/src -Fi/b/src"; \
  P="$P -Fu$E/pascal-api-infra-faa/src -Fi$E/pascal-api-infra-faa/src -Fu$E/pascal-api-infra-faa/src/horse"; \
  P="$P -Fu$E/horse/src -Fi$E/horse/src"; \
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"; \
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"; \
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src -Fu$E/pascal-db-faa/adapters/sqldb"; \
  P="$P -Fu$E/pascal-redis-faa/src -Fi$E/pascal-redis-faa/src"; \
  P="$P -Fu$E/pascal-amqp-faa/src -Fi$E/pascal-amqp-faa/src -Fu$E/pascal-amqp-faa/src/outbox -Fu$E/synapse -Fi$E/synapse"; \
  mkdir -p /b/units-api /b/units-worker; \
  cd /b/api && fpc -v0 -O2 -Mdelphi -dUseCThreads $P -FU/b/units-api -o/b/AgendaApi AgendaApi.dpr; \
  cd /b/worker && fpc -v0 -O2 -Mdelphi -dUseCThreads $P -FU/b/units-worker -o/b/AgendaWorker AgendaWorker.dpr

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 libpq5 libssl3 ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
COPY --from=build /b/AgendaApi /b/AgendaWorker /app/
WORKDIR /app
# Log lines in UTF-8 and the right case for accented letters (the libraries'
# gotcha on FPC/Linux with no LANG).
ENV LANG=C.UTF-8
