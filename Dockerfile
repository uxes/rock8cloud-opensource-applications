# Shlink (self-hosted URL shortener with built-in QR code generation) on
# Rock8Cloud - the REST API server. See docker/web-client/Dockerfile for
# the companion web UI (shlink-web-client), deployed as a second Rock8
# service pointing at this one.
#
# No entrypoint wrapper needed: Shlink's own env var names for DB config
# (DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD) already match the target
# keys used everywhere else in this repo's Postgres linking convention,
# so Rock8Cloud's link_env_vars can write straight into them. See README.md
# for the full env var list and the DB TLS gotcha.
FROM shlinkio/shlink:latest
EXPOSE 8080
