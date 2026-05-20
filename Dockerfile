# Zipline (drag-n-drop file share, ShareX-compatible) on Rock8Cloud.
#
# Unlike Pingvin Share (both the archived original and its maintained
# fork), Zipline uses Drizzle ORM against Postgres natively - not a
# Prisma schema with the DB provider hardcoded to "sqlite" at build time.
# That hardcoding was confirmed by reading both projects' actual
# schema.prisma files, not assumed - it's why this branch is Zipline, not
# Pingvin Share, despite the original recommendation. See README.md.
FROM ghcr.io/diced/zipline:latest

# entrypoint.sh is inlined via a RUN heredoc instead of COPY: this build
# pipeline's COPY layer cache was observed to stay "(cached)" across
# commits that genuinely changed entrypoint.sh's content (confirmed by
# diffing the actual committed file - not a local mistake), so fixes
# never reached the running container. A RUN heredoc's content is part
# of the instruction text itself, which does get hashed for caching, so
# this reliably busts the cache whenever the script changes.
RUN cat <<'ENTRYPOINT_EOF' > /usr/local/bin/entrypoint.sh
#!/bin/sh
# Compose Zipline env settings from linked Rock8Cloud service variables.
#
# Linked Postgres vars: DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD
# Linked S3 vars: S3_BUCKET S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_REGION
#                 S3_FORCE_PATH_STYLE (newer Rock8Cloud S3 services export this -
#                 "true when endpoint is the in-cluster service", per its
#                 own linkable-key label)
#
# Zipline env var names confirmed directly from its own source
# (src/lib/config/read/env.ts), not guessed from docs.
set -e

: "${DB_PORT:=5432}"
# sslmode=require encrypts but still validates the cert - Rock8Cloud's
# Postgres presents a self-signed one, which node-postgres (the driver
# behind Prisma's adapter-pg here) then rejects. Confirmed via runtime
# logs: "self-signed certificate" / TlsConnectionError. sslmode=no-verify
# (pg-connection-string's mapping to rejectUnauthorized: false) is what's
# actually needed - same class of gotcha as the wikijs branch's Postgres
# TLS fight, different app/driver.
export DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=no-verify"

# Zipline's S3 client (src/lib/datasource/S3.ts) builds a plain
# https.Agent with no rejectUnauthorized option and no app-level "trust
# this cert" config exposed at all (confirmed by reading that file - no
# TLS-related field in its constructor options). Unlike node-postgres
# (see the DATABASE_URL comment above), nothing here overrides Node's
# global TLS default, so NODE_TLS_REJECT_UNAUTHORIZED=0 actually works
# for this one. Broad (process-wide), but this container's only outbound
# HTTPS is to Rock8Cloud's own Postgres/S3 (both self-signed) - accepted
# tradeoff, no narrower option exists in the app itself.
export NODE_TLS_REJECT_UNAUTHORIZED=0

# Rock8Cloud's ingress (envoy) terminates TLS and forwards plain HTTP to the
# container, so without this Zipline thinks every request is http:// and
# generates http:// share links even though the public URL is https://.
# Confirmed via Zipline's own reverse-proxy guide (docs/guides/reverse-proxy):
# "If SSL terminates at your proxy, turn this on so links are returned as
# https://". Static platform-shape config, not a secret - belongs in code.
export CORE_RETURN_HTTPS_URLS=true

export DATASOURCE_TYPE=s3
export DATASOURCE_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export DATASOURCE_S3_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export DATASOURCE_S3_BUCKET="$S3_BUCKET"
export DATASOURCE_S3_REGION="${S3_REGION:-us-east-1}"

# Unlike the wordpress branch's S3-Uploads plugin (which needs the
# bucket manually prefixed onto the host), Zipline's real
# @aws-sdk/client-s3 client does virtual-hosted-style addressing itself
# whenever forcePathStyle is false: it takes DATASOURCE_S3_ENDPOINT as
# the *bare* host and prepends the bucket automatically. Manually
# prefixing the bucket here as well double-composed it
# ("zipline-s3.zipline-s3...") and Rock8Cloud's S3 gateway (Garage) then
# rejected that doubled name with NoSuchBucket - confirmed via a
# temporary diagnostic log showing the doubled DATASOURCE_S3_ENDPOINT
# value. So: always pass the bare endpoint through unmodified, and only
# the force-path-style flag differs by mode.
export DATASOURCE_S3_ENDPOINT="$S3_ENDPOINT"
if [ "${S3_FORCE_PATH_STYLE:-false}" = "true" ]; then
    export DATASOURCE_S3_FORCE_PATH_STYLE=true
fi

# Hand off to the base image's own real entrypoint (confirmed from its
# Dockerfile source: ENTRYPOINT ["/zipline/entrypoint"] - not guessed).
exec /zipline/entrypoint "$@"
ENTRYPOINT_EOF
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
