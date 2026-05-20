#!/bin/sh
# Rock8Cloud injects Postgres creds as linked env vars (DB_HOST/DB_PORT/DB_NAME/
# DB_USER/DB_PASSWORD). Vaultwarden itself only reads a single DATABASE_URL,
# so we compose it here rather than baking any config into the image.
set -e

export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"

exec /start.sh "$@"
