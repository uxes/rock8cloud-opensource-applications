# Zipline on Rock8Cloud

[Zipline](https://github.com/diced/zipline) (drag-n-drop file share,
ShareX-compatible) against **Postgres** (via Drizzle ORM) and **S3** for
file storage. Working end to end: upload, generate a shareable link,
download from that link with no account needed.

## Why Zipline, not Pingvin Share

Pingvin Share (both the archived original `stonith404/pingvin-share` and
its maintained fork `smp46/pingvin-share-x`) was the first candidate for
a drag-n-drop file-share tool, but both have `provider = "sqlite"`
**hardcoded in their Prisma schema** (`backend/prisma/schema.prisma`) -
confirmed by reading the actual schema file in both repos, not assumed
from docs. That's a compile-time choice baked into the generated Prisma
client, not something `DATABASE_URL` alone can override to Postgres. On
a no-PVC platform that means the app's own database (users, share
records) would live on the ephemeral container filesystem and be wiped
on every redeploy - not viable here.

Zipline uses Drizzle ORM against Postgres natively (`DATABASE_URL=
postgres://...`, a first-class connection string, not a provider swap)
and has a documented native S3 datasource mode - confirmed via its own
`docker-compose.yml` and `src/lib/config/read/env.ts` source, not docs
alone.

## Env vars (confirmed from source, not guessed)

From `src/lib/config/read/env.ts`:
- `DATABASE_URL` - standard Postgres connection string.
- `CORE_SECRET` - signs session cookies. Must be a stable manual env var
  (like WordPress's `WP_AUTH_KEY_SEED` or Vaultwarden's `ADMIN_TOKEN`),
  not generated at container boot - regenerating it on every redeploy
  would invalidate every session/cookie. Generate with
  `openssl rand -base64 32`.
- `CORE_RETURN_HTTPS_URLS=true` - **needed behind any TLS-terminating
  reverse proxy**, Rock8Cloud's included. Without it, Zipline sees every
  request as plain HTTP (since TLS ends at the platform's ingress) and
  generates `http://` share links even though the public URL is
  `https://`. Confirmed via Zipline's own reverse-proxy guide.
- `DATASOURCE_TYPE=s3` plus `DATASOURCE_S3_ACCESS_KEY_ID`,
  `DATASOURCE_S3_SECRET_ACCESS_KEY`, `DATASOURCE_S3_REGION`,
  `DATASOURCE_S3_BUCKET`, `DATASOURCE_S3_ENDPOINT` (optionally
  `DATASOURCE_S3_FORCE_PATH_STYLE`).

## S3 endpoint: don't double-prefix the bucket

Unlike the `wordpress` branch's S3-Uploads plugin (which needs the
bucket manually prefixed onto the host - see that branch's README for
the three-hostname pattern this platform's S3 gateway uses), Zipline's
real `@aws-sdk/client-s3` client does virtual-hosted-style addressing
**itself** whenever `forcePathStyle` is false: it takes
`DATASOURCE_S3_ENDPOINT` as the *bare* host and prepends the bucket
automatically. Manually prefixing the bucket in the entrypoint as well
double-composes it (`<bucket>.<bucket>.<host>`), and Rock8Cloud's S3 gateway
(Garage) parses everything left of its known base domain as the bucket
name - producing a literal doubled bucket name in a `NoSuchBucket`
error. **Fix**: always pass `DATASOURCE_S3_ENDPOINT` through unmodified
(bare host, no manual bucket prefix) and let the SDK do the vhost
composition; `DATASOURCE_S3_FORCE_PATH_STYLE` is the only thing that
still varies by mode.

**Lesson for future branches**: the "prefix the bucket onto the host
yourself" pattern is specific to apps whose S3 client doesn't do
virtual-hosted addressing on its own - always check the app's actual S3
client behavior before assuming that pattern applies.

## TLS gotchas (same root cause, two layers)

Both Postgres and S3 on this platform present self-signed certs, which
broke this app twice, once per layer:

- **Postgres**: `?sslmode=require` in `DATABASE_URL` encrypts but still
  validates the cert against a trusted CA, which fails against a
  self-signed one. The driver here (`@prisma/adapter-pg` wrapping
  `pg`/`pg-connection-string`) maps `sslmode=no-verify` to
  `rejectUnauthorized: false` - that's the value that actually works.
- **S3**: Zipline's S3 client (`src/lib/datasource/S3.ts`) builds a
  plain `https.Agent` with no `rejectUnauthorized` option and no
  app-level "trust this cert" config exposed anywhere - no per-service
  knob like Postgres's `sslmode` to reach for. Fixed with
  `NODE_TLS_REJECT_UNAUTHORIZED=0` (process-wide, but this container's
  only outbound HTTPS is to Rock8Cloud's own Postgres/S3, both self-signed -
  accepted tradeoff, no narrower option exists in the app itself).

## Build-cache gotcha: a fix that silently didn't ship

After the S3 endpoint fix above, two redeploys in a row still produced
the *exact* pre-fix error. The build logs showed
`COPY docker/entrypoint.sh ... (cached)` on both builds, despite the
file's content genuinely differing between commits (verified directly
with `git show <commit>:docker/entrypoint.sh`). Adding a cache-bust
`ARG` before the `COPY` didn't help either - this build pipeline's
layer cache appeared to be keyed on the `COPY` instruction's (src, dst)
path pair, not actual file content.

**Fix**: stopped using `COPY docker/entrypoint.sh ...` entirely - the
entrypoint script is inlined directly in the `Dockerfile` via a
`RUN cat <<'EOF' > /usr/local/bin/entrypoint.sh` heredoc instead. A
`RUN` instruction's cache key is its literal command text (heredoc
content included), which reliably busts on any change, sidestepping
whatever the `COPY`-specific bug was.

**Lesson for future branches**: if a fix is committed, pushed, and the
build reports success, but runtime behavior doesn't change, don't
assume the fix is wrong first - check the build log for a suspicious
`(cached)` layer on the file you just edited.

## First-admin setup crashed the pod (OOM, not an app bug)

Creating the first super-admin account (`POST /api/setup`) consistently
killed the running pod - a 503 from the ingress, and runtime logs
showing a full app restart with **no app-level error logged
beforehand** (i.e. the process was killed from outside, not a graceful
crash). The service was still on the platform's bare-minimum default
allocation, which is tight for any Node app at idle - and creating the
first admin account is exactly the kind of one-off heavier-than-normal
request (password hashing, initial settings write) that pushes a Node
process over a tight memory ceiling and gets OOM-killed.

**Fix**: bumped the service's CPU/memory allocation (quadrupling the
default memory was enough). Confirmed fixed - registration completed
cleanly after the resize.

**Lesson for future branches**: if a pod restarts with no app-level
error logged right before it, suspect an OOM kill from being
under-provisioned rather than an app bug - especially around a request
that's heavier than the app's steady-state traffic (first-run setup,
migrations, large uploads).

## Status

Working: upload, S3-backed storage, shareable links (HTTPS, downloadable
by anyone with the link, no account needed), first-admin setup. Not
deeply tested: password-protected shares, expiring links, and Zipline's
other sharing features beyond the core upload/download path - this
branch proves the platform wiring, not full feature coverage.
