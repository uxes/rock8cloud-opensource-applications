#!/bin/sh
# Turns wp-config-sample.php into a real, env-driven wp-config.php.
# Run at build time so the result is baked into the image.
set -eu

CONFIG=/var/www/html/wp-config.php
cp /var/www/html/wp-config-sample.php "$CONFIG"

# Load wp-config-extra.php (DB salts, S3 constants, WP_HOME/FORCE_SSL, ...)
# before anything else in wp-config.php runs. wp-config-sample.php always
# starts with a lone "<?php" on line 1, so inserting after line 1 is safe.
sed -i "1a require_once '/usr/local/etc/wp-config-extra.php';" "$CONFIG"

# Point DB_* constants at env vars instead of the sample's placeholders.
sed -i "s/define( 'DB_NAME', 'database_name_here' );/define( 'DB_NAME', getenv('DB_NAME') );/" "$CONFIG"
sed -i "s/define( 'DB_USER', 'username_here' );/define( 'DB_USER', getenv('DB_USER') );/" "$CONFIG"
sed -i "s/define( 'DB_PASSWORD', 'password_here' );/define( 'DB_PASSWORD', getenv('DB_PASSWORD') );/" "$CONFIG"
sed -i "s/define( 'DB_HOST', 'localhost' );/define( 'DB_HOST', getenv('DB_HOST') . (getenv('DB_PORT') ? ':' . getenv('DB_PORT') : '') );/" "$CONFIG"

# Real auth keys/salts are derived from WP_AUTH_KEY_SEED in wp-config-extra.php
# (see that file). Drop the sample's placeholder define()s so they don't
# collide with (and emit "already defined" warnings against) the real ones.
sed -i -E "/define\( '(AUTH_KEY|SECURE_AUTH_KEY|LOGGED_IN_KEY|NONCE_KEY|AUTH_SALT|SECURE_AUTH_SALT|LOGGED_IN_SALT|NONCE_SALT)',/d" "$CONFIG"
