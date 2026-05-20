# Wiki.js on Rock8Cloud

[Wiki.js](https://js.wiki/) running against **Postgres** via a local
`stunnel` TLS proxy, non-root at runtime.

## Why the stunnel proxy

Rock8Cloud's managed Postgres enforces TLS but presents a self-signed
certificate. Wiki.js's own SSL config couldn't be made to tolerate that
directly - three approaches were tried and failed before landing on the
proxy:

1. `db.ssl: true` in config -> `DEPTH_ZERO_SELF_SIGNED_CERT`. Node's TLS
   defaults to strict validation, and a plain boolean `true` doesn't
   change that.
2. `+ NODE_TLS_REJECT_UNAUTHORIZED=0` -> same error, unchanged.
   `node-postgres` does not defer to this process-wide env var for its
   own SSL options object even when otherwise unset - a known
   `node-postgres` gotcha, not a Wiki.js one.
3. `db.ssl: { rejectUnauthorized: false }` baked into `config.yml` ->
   error flipped to `pg_hba.conf rejects connection ... no encryption`.
   Wiki.js's config loader only accepts a **boolean** for `db.ssl`, not
   an object - a nested object is silently dropped, so the connection
   fell back to plaintext, which Rock8Cloud's TLS-required `pg_hba.conf`
   then rejected.

**Working fix**: a local `stunnel` proxy (`127.0.0.1:15432`) forwarding
to the real Postgres host with `verify = 0`. Wiki.js talks plaintext to
localhost (`ssl: false`); the actual encrypted hop happens between
stunnel and Postgres, outside Wiki.js's own too-limited SSL config
surface.

## Gotchas worth knowing before repeating this

- **`stunnel`'s daemonized mode can fail silently.** `foreground = no`
  produced `ECONNRESET` on every connection attempt with no visible
  cause. Run it in the foreground as an explicit backgrounded shell job
  (`stunnel config.conf &`) instead - its own stdout/stderr then lands in
  your container logs rather than being lost, which is what surfaces the
  real error.
- **Generic TLS wrapping doesn't work against Postgres's wire protocol.**
  Postgres expects a plaintext `SSLRequest` packet and a single-byte
  `'S'`/`'N'` reply *before* the TLS handshake starts, not an immediate
  ClientHello. `stunnel` has built-in support for exactly this
  negotiation via `protocol = pgsql` in the service block - that's the
  actual fix, not just wrapping the connection in generic TLS.
- **Root isn't required at runtime just because it was needed at build
  time.** Installing `stunnel` (`apk add`) needs root, but `stunnel`
  itself only binds a high local port and connects outbound - neither
  needs elevated privilege. Switch back to the base image's own non-root
  user (`USER node` for this Node.js-based image) before the final
  `ENTRYPOINT`, after the root-only build steps are done.
- **A read-only runtime filesystem outside `/tmp` affects writable data
  dirs too**, not just obvious things like package installs - Wiki.js's
  own data directory (cache, sessions, upload staging) needs to be moved
  onto `/tmp` via a symlink baked at *build* time (when the filesystem is
  still writable), not created at entrypoint time (which would hit the
  same read-only restriction).

## Known limitations

- The browser-based first-run setup wizard (admin account, site title)
  still needs a human to complete it once, even though DB credentials
  come from env vars - not automatable from the container side.
- S3-backed uploads aren't wired in this branch - Wiki.js's S3 storage
  module is configured through the admin UI after setup, as a follow-up.
