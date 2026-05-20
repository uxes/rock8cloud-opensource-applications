# Vaultwarden on Rock8Cloud

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) (Bitwarden-
compatible password manager), Postgres-backed, non-root at runtime.

## Design

- Official image, config purely via env vars, no build step needed
  beyond the hardening below.
- `docker/entrypoint.sh` composes `DATABASE_URL` from linked Postgres env
  vars (Vaultwarden only reads one combined connection string, unlike
  some apps that take discrete host/port/user/pass vars) and execs the
  image's own `/start.sh`.
- `sslmode=require` - Rock8Cloud's managed Postgres enforces TLS.

## Gotchas worth knowing before repeating this

- **The official image runs as root by default, with no built-in
  non-root option** (no `USER` directive, no PUID/PGID mechanism) - and
  it defaults to port 80, a privileged port that itself requires root to
  bind. Fixing just the `USER` directive without also moving the port
  (`ROCKET_PORT` env var, Vaultwarden's underlying web framework) leaves
  the privilege drop cosmetic - the process still needs root to bind
  <1024 regardless of which user owns it.
- **Check the base OS before writing user-creation commands.** This
  image is Debian-based (`debian:trixie-slim`) - `useradd`, not Alpine's
  `adduser -D`. Verify against the base image's own upstream Dockerfile
  source rather than assuming one or the other.
- **`disableUserRegistration` in `GET /api/config` is not a reliable
  signal** for whether registration is actually closed in this version -
  it can read `false` even after `SIGNUPS_ALLOWED=false` has taken
  effect. Trust the admin panel's actual checkbox state, or a real
  `POST /identity/accounts/register` attempt (expect `400`), over that
  API field.
- **`ADMIN_TOKEN` should be an Argon2 PHC hash, not plaintext** - the app
  itself logs a NOTICE recommending this at boot (`vaultwarden hash`).
  Worth doing before any real use, not just a PoC.

## Known limitations

- **File attachments live on the ephemeral container filesystem** - lost
  on every redeploy (and pods can be replaced at other times too). Regular
  vault items (logins, secure notes - including pasting a private key as
  note *text*) are Postgres-backed and durable; only file *attachments*
  are at risk. Don't rely on attachments for anything you can't afford to
  lose, unless/until this is wired to Vaultwarden's own S3 backend
  support.
