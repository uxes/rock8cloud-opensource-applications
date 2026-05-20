# WordPress on Rock8Cloud

WordPress running against **Postgres** (not MySQL) with **S3** for media
uploads, on a platform with no persistent volumes.

## Why this is unusual

Rock8Cloud offers no native MySQL and no PVCs (the container filesystem
is ephemeral - everything not in git or a managed backend is lost on
every redeploy). That rules out the standard WordPress+MySQL+local-disk
stack entirely, so this branch instead runs:

- **[PG4WP](https://github.com/PostgreSQL-For-Wordpress/postgresql-for-wordpress)**
  as a drop-in `wp-content/db.php` driver, translating WordPress's
  MySQL-flavored SQL to Postgres. It's a thinner-tested compat layer than
  stock WP-on-MySQL - expect occasional query-translation edge cases.
- **[S3-Uploads](https://github.com/humanmade/S3-Uploads)** (humanmade)
  so media goes straight to S3-compatible object storage instead of the
  local filesystem.
- `DISALLOW_FILE_MODS` / `DISALLOW_FILE_EDIT` - nothing installed or
  edited through wp-admin survives a redeploy anyway (plugins/themes only
  live in the image built from git), so the admin UI is locked down
  rather than offering changes that silently vanish.

## Gotchas worth knowing before repeating this

- **S3 public URLs need the right subdomain.** A Garage/S3-compatible
  gateway (like Rock8Cloud's) commonly exposes a bucket at *three* different
  hostnames: a bare gateway host (routes nowhere on its own), an
  authenticated API host (bucket-prefixed - what the AWS SDK builds
  internally for signed calls), and a separate public/unsigned-read host
  (often one more subdomain level in, and gated behind the bucket's own
  "public access" toggle). Getting the wrong one looks like it "should"
  work and doesn't - verify all three directly with `curl` rather than
  assuming from an SDK default.
- **Don't `chown -R` the whole webroot.** With `DISALLOW_FILE_MODS` and
  S3-only uploads, the web server user never needs write access to the
  WordPress tree at all - only read (which root-owned `COPY`'d files
  already provide). A recursive `chown` over the full core+plugins tree
  was, in testing, the single most expensive step in the whole build -
  minutes on a slower/shared build host, for zero runtime benefit.
- **Auth salts must come from a real secret.** Without an explicit seed,
  WordPress keeps its default placeholder auth key/salt constants, which
  are publicly known and make session cookies forgeable. Derive all eight
  salts from one securely-generated secret (e.g. `openssl rand -base64
  48`) via an env var, never hardcode or skip this.
- **`X-Forwarded-Proto` matters if anything proxies in front of this.**
  If a reverse proxy/WAF sits between the platform's edge and this
  container, make sure it forwards `X-Forwarded-Proto: https` (and that
  `wp-config.php` trusts it) - otherwise WordPress generates `http://`
  asset URLs on a page served over `https://`, and browsers block the
  mismatch as mixed content.

## Included plugins

- **[Elementor](https://elementor.com/)** + Hello Elementor theme (page
  builder).
- **[MCP Adapter](https://github.com/WordPress/mcp-adapter)** (official
  WordPress project) - exposes WordPress functionality over MCP. Tracked
  at its latest release rather than a pinned version, since it doesn't
  have a stable release cadence yet.

## Known limitations

- PG4WP is less battle-tested than stock MySQL-backed WordPress - if
  something breaks in an unusual way, suspect the compat layer before
  assuming it's a WordPress bug.
- No local file uploads outside S3 by design (see above) - anything
  expecting local-disk writes (some plugins/themes) won't work without
  adaptation.
