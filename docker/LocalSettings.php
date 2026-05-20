<?php
// MediaWiki LocalSettings.php - baked into the image at build time.
// This file is the SINGLE SOURCE OF TRUTH for runtime configuration.
// docker/entrypoint.sh must NOT regenerate or overwrite it.
//
// All credentials/secrets are read from environment variables provided by
// Rock8Cloud (PG_HOST, PG_PORT, PG_DATABASE, PG_USER, PG_PASSWORD,
// MW_SECRET_KEY, MW_UPGRADE_KEY, optionally MW_SERVER).

$wgDBtype = "postgres";
$wgDBserver = getenv("PG_HOST") ?: "localhost";
$wgDBport = getenv("PG_PORT") ?: "5432";
$wgDBname = getenv("PG_DATABASE") ?: "mediawiki";
$wgDBuser = getenv("PG_USER") ?: "mediawiki";
$wgDBpassword = getenv("PG_PASSWORD") ?: "";
// NOTE: do NOT set $wgDBmwschema. In MediaWiki 1.43 the default is null =
// use the database default schema (public). The entrypoint creates all
// tables in the public schema via psql and runs update.php --dbschema=public;
// pointing this at a custom schema would make MediaWiki look for tables in
// the wrong place.

$wgSitename = "MediaWiki";

// $wgSecretKey protects session cookies and CSRF tokens; $wgUpgradeKey gates
// running maintenance/update.php. A hardcoded placeholder here is publicly
// known (visible in this repo) and makes sessions forgeable - same class of
// bug as the WordPress auth-salts issue found earlier in this project.
// Set MW_SECRET_KEY / MW_UPGRADE_KEY in Rock8Cloud env vars, e.g. via
// `openssl rand -hex 32` for each.
$wgSecretKey = getenv("MW_SECRET_KEY");
$wgUpgradeKey = getenv("MW_UPGRADE_KEY");
if (!$wgSecretKey || !$wgUpgradeKey) {
    error_log("[LocalSettings] WARNING: MW_SECRET_KEY/MW_UPGRADE_KEY not set - falling back to an insecure default. Set them in Rock8Cloud env vars.");
    $wgSecretKey = $wgSecretKey ?: "insecure-default-set-MW_SECRET_KEY-env-var";
    $wgUpgradeKey = $wgUpgradeKey ?: "insecure-default-set-MW_UPGRADE_KEY-env-var";
}

$wgEnableUploads = true;

// Prefer an explicit MW_SERVER env var; otherwise detect from the incoming
// request so generated CSS/JS (ResourceLoader /load.php) URLs always point
// back to the host the user actually visits. A hardcoded fallback like
// http://localhost:8080 breaks styling behind the Rock8Cloud proxy.
$wgServer = getenv("MW_SERVER");
if (!$wgServer && isset($_SERVER['HTTP_HOST'])) {
    $wgServer = (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] === 'on' ? 'https' : 'http')
        . '://' . $_SERVER['HTTP_HOST'];
}
if (!$wgServer) {
    // CLI context (update.php etc.) - no HTTP_HOST available.
    $wgServer = "http://localhost:8080";
}

// MediaWiki served from the root URL ("/"), not a subdirectory.
$wgScriptPath = "";
$wgScriptExtension = ".php";

// Clean URLs: /PageName -> index.php (rewritten by docker/mediawiki.htaccess).
$wgArticlePath = "/$1";
$wgUsePathInfo = true;

// Behind the Rock8Cloud ingress every request arrives from a Kubernetes pod IP
// (10.x.x.x). Without trusting that proxy, MediaWiki attributes ALL anonymous
// edits to the same internal address - real visitors become
// indistinguishable and IP blocks would hit everyone at once.
// NOTE: CIDR ranges MUST go into $wgCdnServersNoPurge - $wgCdnServers is
// matched with exact in_array() against single IPs, so ranges there never
// match (verified in includes/Request/ProxyLookup.php).
$wgUseCdn = true;
$wgCdnServersNoPurge = [ '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16' ];

$wgLanguageCode = "en";
$wgUseImageMagic = true;
$wgImageMagickConvertCommand = "/usr/bin/convert";

// Debug
$wgShowExceptionDetails = true;
$wgShowSQLErrors = true;
$wgDebugDumpOutput = true;

// Skin configuration.
// wfLoadSkin('Vector') resolves $wgStyleDirectory/Vector/skin.json -
// CASE-SENSITIVE on Linux, so the Dockerfile must install the skin into
// /var/www/html/skins/Vector (capital V).
wfLoadSkin('Vector');
$wgDefaultSkin = 'vector-2022';

// S3 file storage via Extension:AWS - replaces the backend for ALL zones
// (public, thumb, temp, deleted), including the upload-stash/temp phase
// that a hook-based approach can't reach. Requires S3_BUCKET, S3_ENDPOINT,
// S3_ACCESS_KEY, S3_SECRET_KEY, S3_REGION env vars (linked to a Rock8Cloud S3
// storage service, same shape as the WordPress side of this project).
$s3Bucket = getenv('S3_BUCKET');
$s3Endpoint = getenv('S3_ENDPOINT');
$s3AccessKey = getenv('S3_ACCESS_KEY');
$s3SecretKey = getenv('S3_SECRET_KEY');
$s3Region = getenv('S3_REGION') ?: 'us-east-1';

if ($s3Bucket && $s3Endpoint && $s3AccessKey && $s3SecretKey) {
    wfLoadExtension('AWS');

    $wgAWSCredentials = [
        'key' => $s3AccessKey,
        'secret' => $s3SecretKey,
        'token' => false,
    ];
    $wgAWSRegion = $s3Region;
    $wgAWSBucketName = $s3Bucket;

    // Rock8Cloud exposes S3_FORCE_PATH_STYLE explicitly per-bucket ("true when
    // endpoint is the in-cluster service") - respect it rather than assume.
    // On the WordPress side of this project, the public-facing bucket
    // turned out to be virtual-hosted-style only (bucket baked into the
    // hostname) and setting use_path_style_endpoint=true there caused a
    // bare HTTP 404. Don't assume the same holds here without checking -
    // this flag is exactly what tells us which mode this bucket needs.
    //
    // S3_ENDPOINT from Rock8Cloud is bucket-prefixed (e.g.,
    // "mediawiki.https/storage.rock8.cloud"). The ".https" part is a Rock8
    // artifact — strip ".https" first, then strip the bucket prefix to get
    // the bare hostname, then let the AWS SDK re-prepend the bucket itself
    // (default virtual-hosted addressing).
    // S3_ENDPOINT from Rock8Cloud comes bucket-prefixed with a ".https" artifact
    // (e.g., "mediawiki.https/storage.rock8.cloud"). Normalize to the bare
    // hostname: drop any scheme, drop the ".https" artifact, then drop the
    // bucket prefix - it may be joined by a DOT ("bucket.host") or a SLASH
    // ("bucket/host"); only checking the dot variant left "mediawiki/..."
    // behind, producing the unresolvable host "mediawiki".
    $s3EndpointHost = preg_replace('#^https?://#', '', $s3Endpoint);
    $s3EndpointHost = str_replace('.https', '', $s3EndpointHost);
    foreach (['.', '/'] as $sep) {
        if (str_starts_with($s3EndpointHost, $s3Bucket . $sep)) {
            $s3EndpointHost = substr($s3EndpointHost, strlen($s3Bucket) + 1);
            break;
        }
    }
    $wgFileBackends['s3']['endpoint'] = 'https://' . $s3EndpointHost;

    if (filter_var(getenv('S3_FORCE_PATH_STYLE'), FILTER_VALIDATE_BOOLEAN)) {
        $wgFileBackends['s3']['use_path_style_endpoint'] = true;
    }

    // Public URL for serving images to browsers - separate from the API
    // endpoint above. Matches the WP side's public.storage.rock8.cloud
    // pattern; if the mediawiki bucket's actual public URL differs, update
    // this to match what the Rock8Cloud dashboard shows for it.
    $wgAWSBucketDomain = '$1.public.storage.rock8.cloud';

    $wgEnableUploads = true;
} else {
    error_log('[LocalSettings] S3 env vars not set (S3_BUCKET/S3_ENDPOINT/S3_ACCESS_KEY/S3_SECRET_KEY) - uploads disabled. Provision an S3 bucket in Rock8Cloud and link its credentials to this service.');
    $wgEnableUploads = false;
}
