# MediaWiki on Rock8Cloud

MediaWiki running natively against **Postgres** (no compat shim needed,
unlike WordPress) with **S3** for uploads via `Extension:AWS`.

## Why Postgres works natively here

Unlike WordPress, MediaWiki has first-class Postgres support built in -
no translation layer required. Rock8Cloud offers no native MySQL and no
persistent volumes (the container filesystem is ephemeral), so Postgres
+ S3 is the natural fit rather than a workaround.

## Gotchas worth knowing before repeating this

- **Don't `chmod -R 777` the webroot.** Only the specific directories
  MediaWiki actually writes to at runtime (image thumbnails cache, an
  upload staging path) need write access - not the entire installed
  tree. A blanket `chown -R` + `chmod -R 777` over everything is both
  slower to build and a much larger blast radius than necessary; scope
  ownership/permissions to just the directories that need it.
- **S3 public URLs need the right subdomain.** A Garage/S3-compatible
  gateway (like Rock8Cloud's) commonly exposes a bucket at *three* different
  hostnames: a bare gateway host (routes nowhere on its own), an
  authenticated API host (bucket-prefixed), and a separate public/
  unsigned-read host (often one more subdomain level in, gated behind
  the bucket's own "public access" toggle). Verify all three directly
  with `curl` before assuming which one a given SDK/extension needs.
- **`MediaWiki::config` vs `update.php` install order matters.** Running
  the installer against a fresh Postgres database has a specific
  sequencing requirement (schema creation before certain config values
  are meaningful) - if install fails partway, check whether it's a
  genuine Postgres-compat issue in the wiki software itself vs. a
  sequencing problem in how the container's first-boot script runs
  `install.php`/`update.php`.

## Testing

`tests/test_mediawiki.py` (and the `.sh` variant) are plain
`requests`-based smoke tests: main page renders, static assets 200, API
login works, a page can be created/edited, a file can be uploaded and
then fetched back from its *public* URL (proves both persistence and
that the bucket's public-read setting is actually on, not just that the
upload API call succeeded). Point them at your own deployed URL via
`BASE_URL` (argv[1] or env var) - don't hardcode a specific deployment's
URL into the test files themselves.

## Known limitations

- File uploads depend on the S3 bucket's public-read setting being
  enabled (see the URL-pattern gotcha above) - if uploads succeed but
  don't display, check that first.
