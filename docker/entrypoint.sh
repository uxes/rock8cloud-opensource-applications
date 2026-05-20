#!/bin/sh
# Rock8Cloud's managed Postgres enforces TLS via pg_hba.conf but presents a
# self-signed cert. Neither `db.ssl: true` (node-postgres hardcodes strict
# cert validation, ignoring NODE_TLS_REJECT_UNAUTHORIZED - confirmed by
# testing) nor `db.ssl: {rejectUnauthorized: false}` (Wiki.js's config
# loader silently drops non-boolean ssl values, falling back to plaintext -
# confirmed via runtime logs) gets Wiki.js talking TLS-but-lenient to
# Postgres.
#
# Workaround: terminate TLS ourselves with a local stunnel proxy that skips
# certificate verification, and point Wiki.js at plaintext localhost -
# config.yml is baked with host 127.0.0.1:15432 and ssl: false accordingly.
#
# `foreground = yes` + shell `&` backgrounding instead of stunnel's own
# daemonization (`foreground = no`) - the first attempt at this used
# daemonized mode and every connection got ECONNRESET, which smelled like
# the proxy silently failing to come up; running it in the foreground as an
# explicit background job means its own stdout/stderr (config errors
# included) lands directly in our container logs instead of being lost.
#
# `protocol = pgsql` is the actual fix for a second ECONNRESET cause found
# via those logs: plain generic TLS wrapping doesn't work against Postgres's
# wire protocol, because Postgres expects an initial plaintext SSLRequest
# packet (and a single-byte 'S'/'N' reply) BEFORE the TLS handshake starts,
# not an immediate TLS ClientHello - stunnel has built-in awareness of this
# exact negotiation for Postgres via the `protocol` directive.
set -e

cat > /tmp/stunnel-pg.conf <<EOF
foreground = yes
[postgres]
client = yes
verify = 0
protocol = pgsql
accept = 127.0.0.1:15432
connect = ${DB_HOST}:${DB_PORT}
EOF

echo "--- stunnel config ---"
cat /tmp/stunnel-pg.conf
echo "--- starting stunnel ---"
stunnel /tmp/stunnel-pg.conf &
STUNNEL_PID=$!
sleep 1
if kill -0 "$STUNNEL_PID" 2>/dev/null; then
  echo "stunnel (pid $STUNNEL_PID) is running"
else
  echo "stunnel (pid $STUNNEL_PID) died immediately - see stunnel output above"
fi

exec "$@"
