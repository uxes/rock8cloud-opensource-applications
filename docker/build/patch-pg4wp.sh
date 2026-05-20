#!/bin/sh
# All build-time patches to the PG4WP (Postgres-for-WordPress) vendor source.
# Keep every patch here, each with a comment on WHY it's needed - PG4WP is
# an old, thinly-maintained compat layer, and the next person touching this
# (including future-you) will want to know which patch to drop on a version
# bump, not have to re-derive it from a bare sed line.
set -eu

PG4WP_DIR=/var/www/html/wp-content/pg4wp
BUILD_DIR="$(dirname "$0")"

# Soften SQL-rewrite failures into logged warnings instead of fatal errors.
# PG4WP throws/re-throws when it can't confidently rewrite a query; on an
# already-fragile compat layer that turns "one query PG4WP doesn't know"
# into "the whole page 500s". We log instead and let WordPress carry on -
# newly discovered failures get a proper fix in
# docker/mu-plugins/pg4wp-quirks.php once found via those logs.
sed -i "s/throw new Exception/error_log/g" "$PG4WP_DIR/rewriters/SelectSQLRewriter.php"
sed -i "s/throw \$e;//g" "$PG4WP_DIR/driver_pgsql_rewrite.php"

# `'$table'::regclass` fails on Postgres when $table is empty (invalid cast);
# fall back to '0' so the query returns "no matching index" instead of erroring.
sed -i "s/i.indrelid = '\$table'::regclass/i.indrelid = (case when '\$table' = '' then '0' else '\$table' end)::regclass/g" "$PG4WP_DIR/driver_pgsql.php"

# INSERT-parsing edge cases (INSERT IGNORE, empty table/primary-key matches).
php "$BUILD_DIR/patch-pg4wp-insert.php" "$PG4WP_DIR/driver_pgsql.php"
