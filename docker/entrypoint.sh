#!/bin/bash
set -e

IP=/var/www/html

echo "=== ENTRYPOINT START ==="
echo "PWD: $(pwd)"
echo "ENV PG_HOST: ${PG_HOST}"
echo "ENV PG_PORT: ${PG_PORT}"
echo "=== ENTRYPOINT END ==="

# LocalSettings.php ships BAKED INTO THE IMAGE (docker/LocalSettings.php ->
# /var/www/html/LocalSettings.php). It reads all credentials from environment
# variables and already contains the skin configuration
# (wfLoadSkin('Vector'), $wgDefaultSkin = 'vector-2022').
#
# Do NOT regenerate or overwrite it here. Earlier versions of this script
# rewrote it with a heredoc on every start, which (a) made the committed
# docker/LocalSettings.php dead code and (b) dropped/mangled the skin config,
# breaking page rendering and CSS.
if [ ! -f "$IP/LocalSettings.php" ]; then
    echo "FATAL: $IP/LocalSettings.php is missing from the image - build is broken." >&2
    exit 1
fi
echo "Using baked-in LocalSettings.php (skin config included)."

# Check if schema already exists (idempotent restarts)
SCHEMA_PRESENT=$(php -r '
$h = $argv;
try {
  $p = new PDO("pgsql:host=".$h[1].";port=".$h[2].";dbname=".$h[3], $h[4], $h[5]);
  $s = $p->query("SELECT 1 FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname NOT IN ('"'"'pg_catalog'"'"','"'"'information_schema'"'"') AND c.relname='"'"'revision'"'"' AND c.relkind='"'"'r'"'"'");
  echo $s && $s->fetchColumn() ? "yes" : "no";
} catch (Exception $e) { echo "no"; }
' "$PG_HOST" "$PG_PORT" "$PG_DATABASE" "$PG_USER" "$PG_PASSWORD")

if [ "$SCHEMA_PRESENT" != "yes" ]; then
    echo "Database not initialized. Creating schema manually..."

    # Create schema using MediaWiki's own SQL files (tables land in the
    # default public schema; LocalSettings.php intentionally does NOT set
    # $wgDBmwschema so MediaWiki looks in public too).
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -f "$IP/maintenance/postgres/tables.sql" 2>/dev/null
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -f "$IP/maintenance/postgres/tables-generated.sql" 2>/dev/null
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "CREATE EXTENSION IF NOT EXISTS plpgsql;" 2>/dev/null

    # Create updatelog table and insert initial keys
    PGPASSWORD="$PG_PASSWORD" psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$PG_DATABASE" -c "
        CREATE TABLE IF NOT EXISTS updatelog (
            ul_key varchar(255) PRIMARY KEY,
            ul_value bytea NOT NULL default ''
        );
    " 2>/dev/null

    echo "Schema created."

    # Initialize database with update.php (LocalSettings.php already exists -
    # it is baked into the image, which is exactly what update.php needs).
    echo "Running MediaWiki update.php to initialize database..."
    # NOTE: update.php touches the file backend (DatabaseUpdater::setFileAccess
    # -> S3 directoryExists). If S3 is unreachable this used to throw an
    # uncaught ConnectException that killed the container BEFORE Apache ever
    # started -> crash loop with a dead wiki. Never let it take the pod down;
    # log loudly instead.
    if ! php "$IP/maintenance/update.php" --quick --skip-external-dependencies --dbserver="$PG_HOST" --dbport="$PG_PORT" --dbname="$PG_DATABASE" --dbschema=public --dbuser="$PG_USER" --dbpass="$PG_PASSWORD" --confpath="$IP"; then
        echo "WARNING: update.php FAILED - starting Apache anyway so the wiki stays up." >&2
    fi

    echo "Database initialized."
else
    echo "Database schema exists. Running schema updater..."
    if ! php "$IP/maintenance/update.php" --quick --skip-external-dependencies --force; then
        echo "WARNING: update.php (schema update) FAILED - starting Apache anyway." >&2
    fi
fi

# Ensure Admin user exists with known password
ADMIN_PASS="${MW_ADMIN_PASS:-MediaWikiAdmin2026!}"

echo "Creating/ensuring Admin user via createAndPromote.php..."

# Use MediaWiki's own maintenance script to create the user with proper password hashing
# --force will update existing user's password
# Arguments are positional: <username> [password]
php "$IP/maintenance/createAndPromote.php" \
    --bureaucrat \
    --sysop \
    --force \
    --dbpass="$PG_PASSWORD" \
    --dbuser="$PG_USER" \
    "Admin" "$ADMIN_PASS" \
    2>&1

if [ $? -eq 0 ]; then
    echo "Admin user created/updated successfully."
else
    echo "ERROR: Failed to create/update Admin user via createAndPromote.php" >&2
    exit 1
fi

echo "Starting Apache..."
exec /usr/sbin/apache2ctl -D FOREGROUND
