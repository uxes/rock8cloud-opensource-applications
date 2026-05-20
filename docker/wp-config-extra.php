<?php
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { $_SERVER['HTTPS'] = 'on'; $_SERVER['SERVER_PORT'] = 443; }

// Auth keys/salts derived from one secret seed (set WP_AUTH_KEY_SEED in Rock8
// env vars to a long random string, e.g. `openssl rand -base64 48`).
// IMPORTANT: without this, wp-config.php keeps WordPress's default
// placeholder text for these constants, which is publicly known and makes
// auth cookies forgeable. Never skip this in production.
$__seed = getenv('WP_AUTH_KEY_SEED');
if ($__seed) {
    foreach (['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY', 'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'] as $__const) {
        if (!defined($__const)) define($__const, hash_hmac('sha256', $__const, $__seed));
    }
} else {
    error_log('[wp-config] WARNING: WP_AUTH_KEY_SEED is not set - using insecure default WordPress auth salts.');
}

// Nothing installed/edited through wp-admin survives a redeploy (no
// persistent disk on this platform - plugins/themes only live in the image
// built from git). Lock the admin UI down so it doesn't offer changes that
// silently vanish on the next deploy, and disable the plugin/theme editor.
define('DISALLOW_FILE_MODS', true);
define('DISALLOW_FILE_EDIT', true);

define('WP_HOME', 'https://' . ($_SERVER['HTTP_HOST'] ?? 'localhost'));
define('WP_SITEURL', 'https://' . ($_SERVER['HTTP_HOST'] ?? 'localhost'));
define('FORCE_SSL_ADMIN', true);
define('FS_METHOD', 'direct');
define('S3_UPLOADS_BUCKET', getenv('S3_BUCKET'));
define('S3_UPLOADS_REGION', getenv('S3_REGION'));
define('S3_UPLOADS_KEY', getenv('S3_KEY'));
define('S3_UPLOADS_SECRET', getenv('S3_SECRET'));
define('S3_UPLOADS_ENABLED', true);
// S3_ENDPOINT (Rock8Cloud's linked env var) is the bare gateway host, e.g.
// "storage.rock8cloud.cz" - NOT a per-bucket URL, and NOT the same host
// as public reads. Rock8Cloud serves a bucket's *authenticated* S3 API at
// "<bucket>.storage.rock8cloud.cz" (the AWS SDK builds this internally,
// why uploads already worked) but its *public* (unsigned, requires the
// bucket's own "Public Access" toggle enabled) reads live one subdomain
// further in, at "<bucket>.public.storage.rock8cloud.cz" - confirmed by
// testing both directly (bare host: connection failure; API host: 403;
// public host: 200), not guessed. S3_BUCKET_URL stays as an explicit
// full-URL override if ever needed.
$__s3_bucket_url = getenv('S3_BUCKET_URL');
if (!$__s3_bucket_url) {
    $__s3_endpoint = getenv('S3_ENDPOINT');
    $__s3_bucket = getenv('S3_BUCKET');
    if ($__s3_endpoint && $__s3_bucket) {
        $__s3_bucket_url = $__s3_bucket . '.public.' . $__s3_endpoint;
    } else {
        $__s3_bucket_url = $__s3_endpoint;
    }
}
if ($__s3_bucket_url) { define('S3_UPLOADS_BUCKET_URL', 'https://' . str_replace(['http://', 'https://'], '', $__s3_bucket_url)); }
