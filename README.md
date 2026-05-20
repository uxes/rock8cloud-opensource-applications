# Shlink (URL shortener + QR codes) on Rock8Cloud

[Shlink](https://github.com/shlinkio/shlink) - self-hosted URL
shortener with a companion web UI. Working end to end: shorten a link,
generate a QR code for it, all without a third-party service ever
seeing the destination URL.

## Two services, not one

Shlink itself is API + CLI only - no built-in web dashboard. The
official companion app `shlink-web-client` (a React SPA, official image
`shlinkio/shlink-web-client`) provides the web UI, and configures itself
entirely via runtime env vars pointed at the API server's URL - no
build-time coupling between the two. So this branch has two
Dockerfiles: the root one for the API, `docker/web-client/Dockerfile`
for the UI, deployed as two separate Rock8Cloud services in the same
project.

## Env vars (confirmed from Shlink's own docs, not guessed)

API service:
- `DB_DRIVER=postgres`, `DB_HOST`/`DB_PORT`/`DB_NAME`/`DB_USER`/
  `DB_PASSWORD` - **these are Shlink's own native env var names**,
  which happen to already match this repo's usual Postgres-linking
  target keys (`HOST->DB_HOST` etc.) - no entrypoint wrapper needed to
  rename anything, unlike most other branches in this repo.
- `DB_USE_ENCRYPTION=true` - enables an encrypted DB connection.
  Unlike most other apps in this repo, this worked against Rock8Cloud's
  self-signed Postgres cert on the first try - no `sslmode=require`
  -style rejection, no workaround needed. Worth noting as a
  counterexample to this repo's usual Postgres-TLS gotcha.
- `DEFAULT_DOMAIN` - the public hostname used in generated short links.
  Only known after the service is created (Rock8Cloud assigns the subdomain)
  - set as a manual env var afterward, same bootstrap-order problem as
  WordPress's `WP_HOME`.
- `IS_HTTPS_ENABLED=true` - doesn't enforce HTTPS itself, just affects
  the scheme used in generated URLs; needed because Rock8Cloud's ingress
  terminates TLS before the container ever sees the request.
- `INITIAL_API_KEY` - bootstraps an API key at container start with no
  interactive CLI step needed. Generate with `openssl rand -base64 32`.
- `GEOLITE_LICENSE_KEY` intentionally omitted - optional, only disables
  visit geolocation, not needed for the core shorten+QR use case and
  requiring a third-party MaxMind account isn't worth it here.

Web UI service:
- `SHLINK_SERVER_URL` - the API service's public URL.
- `SHLINK_SERVER_API_KEY` - same value as the API's `INITIAL_API_KEY`.
- `SHLINK_SERVER_NAME` - display name only, cosmetic.

## OOM on the platform's default allocation

Same failure shape as the `zipline` branch: the API service's pod
repeated its full startup sequence (DB init -> API key creation -> RPC
plugin start) every ~20-25s with the *same* pod name and no app-level
error logged before each restart - i.e. killed from outside, not
crashing on its own. Still on the platform's default 250m CPU / 256Mi
memory. **Fix**: resized to 500m CPU / 1024Mi memory; the very next boot
reached the app's own "server started" log line (never seen before the
resize) and the health endpoint started responding.

**Lesson reinforced**: this platform's default per-service allocation is
tight enough that it's worth treating as a default suspect for any "pod
restarts with no error" symptom, not just a one-off. Check the org's
overall resource pool headroom too before assuming it's a cluster
capacity problem - in every case seen so far in this repo, the cluster
itself had plenty of free CPU/memory; it was purely the per-service
request being too low.

The web UI service (a static SPA served by nginx, much lighter than the
API's PHP/RoadRunner process) came up healthy on the platform default
with no resize needed - confirms this is about the API's own startup
weight, not a platform-wide problem every service hits.

## QR codes: not a bug, a v5.0 architecture change

`GET /{shortCode}/qr-code` on the API returns Shlink's own branded 404
page, not a QR image - don't take that as a config mistake and go
debugging the wrong thing. As of Shlink 5.0, QR code generation was
**intentionally removed from the API server entirely** (deprecated
since 4.5): the stated reasoning is that Shlink-the-server shouldn't own
image generation, and QR codes are now a `shlink-web-client`-side
feature, generated in the browser from the short URL text with no
server round trip. So the web UI isn't optional polish for this use
case - it's where QR actually lives now.

## Status

Both services working end to end: short URL creation and redirect via
the API, and QR code generation confirmed working through the web UI.
