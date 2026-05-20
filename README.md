# Multi-app deployment monorepo (Rock8Cloud)

`master` is just this index — it carries no app code. Each deployed app
lives on its own branch, stripped down to just what it needs (Dockerfile +
config).

**This repo is written for an AI coding agent to pick up and extend**, not
primarily for a human to read top-to-bottom. If you're an agent about to
deploy a new app here (or redeploy an existing one), read
`.claude/skills/rock8-deploy/SKILL.md` (present on every app branch) first -
it's the actual playbook: MCP tool call order, port/TLS/S3 gotchas, how to
debug a failed deploy. This README is the map; that file is the manual.

**Keep the table below up to date when you add, move, or retire an app** -
and register it in Gatus so it's monitored.

## Apps in this repo

| App | Branch | Notes |
|---|---|---|
| WordPress (PG4WP + S3-Uploads) | `wordpress` | PoC-quality, see known problems below |
| MediaWiki 1.43 + Postgres + S3 | `feature/mediawiki` | Solid, no open problems |
| Gatus uptime monitor | `gatus` | Monitors the other apps |
| Vaultwarden | `vaultwarden` | No S3 backend for attachments yet |
| Wiki.js | `wikijs` | No S3 backend for uploads yet |
| Mattermost | `mattermost` | Blocked on a platform-side S3 limitation |
| WAF in front of a private origin | `wordpress-with-waf` | PoC, not a standalone app - see its own README |
| Zipline (drag-n-drop file share) | `zipline` | Working end-to-end, no open problems |
| Shlink (URL shortener + QR codes) | `shlink` | Working end-to-end, two services (API + web UI) |

Deployed URLs are specific to whichever Rock8Cloud org you deploy under -
they won't carry over to a fork, so they're deliberately not listed here.
Each app branch's own `README.md` has the full picture for that app.

Each app also has its own managed Postgres database and, where it needs
file storage, an S3 (Garage) bucket - provisioned per-app via the MCP tools
described in the `rock8-deploy` skill. Exact resource names/IDs are
instance-specific (regenerated on every fork/every deploy) and not tracked
in this repo.

## Status & known problems, per app

### WordPress (PG4WP + S3-Uploads) — `wordpress`
**Not really tiered — treat as a proof-of-concept, not production, until
Rock8Cloud offers a native managed MySQL/MariaDB.** Running WordPress on
Postgres via PG4WP is fundamentally a compat shim over a database engine WP
core was never designed for; it keeps surfacing MySQL-dialect assumptions
that PG4WP doesn't cover. Every fix so far has been "find the next query
PG4WP mistranslates."
- **Plugin/theme installation is structurally broken**: no PVC means nothing
  written at runtime survives a redeploy, so `DISALLOW_FILE_MODS` /
  `DISALLOW_FILE_EDIT` are set and wp-admin's "install plugin" flow is
  disabled outright. The only way to add a plugin is to vendor it into the
  Dockerfile and commit + redeploy. A volume-backed `wp-content/plugins`
  (the normal fix for this) isn't available on this platform - there is no
  middle ground between "baked into the image" and "impossible."
- No login rate-limiting configured.
- Postgres role in use is not scoped down (broader than necessary).

### MediaWiki 1.43 + Postgres + S3 — `feature/mediawiki`
Solid in practice: native Postgres (no PG4WP-style hack needed), S3 uploads
working end-to-end, functional tests passing. No open problems - see that
branch's `README.md` for the dead ends that got resolved along the way.

### Gatus — `gatus`
No known problems.

### Vaultwarden — `vaultwarden`
Non-root, but no S3 storage wired in - same gap as Wiki.js below. File
attachments have nowhere persistent to live: they write to the container's
local disk and are lost on every redeploy. Core vault data (logins, notes -
anything Postgres-backed) is unaffected. Needs Vaultwarden's S3 attachment
backend added as a follow-up. `ADMIN_TOKEN` is also stored as plaintext
rather than hashed (Vaultwarden's own recommendation) - low priority for a
PoC.

### Wiki.js — `wikijs`
Deployed and working, non-root at runtime, but has no S3 storage wired in
yet - uploads aren't backed by anything persistent until that follow-up
lands (same class of gap as Vaultwarden). Postgres connection needs a local
stunnel proxy to work around a TLS limitation in Wiki.js itself (documented
in that branch's `README.md`) - working, just non-obvious plumbing, not an
open problem.

### Mattermost — `mattermost`
**Blocked, not usable yet.** Rock8Cloud's S3 gateway (Garage)
returns 403 for any request whose User-Agent contains `minio-go` - exactly
what Mattermost's Go S3 client sends (full writeup: that branch's
`ROCK8_S3_UA_FILTER_REPORT.md`). The workaround this needs (a local proxy
that only rewrites User-Agent, routed to via a DNS/hosts-level alias so the
SigV4 signature stays valid) turns out to need a writable `/etc/hosts` at
runtime, which this platform doesn't allow - confirmed directly via a
`Permission denied` boot error, not just suspected. See that branch's
`README.md` for the full chain. Everything else (messaging, Postgres-backed
data) works fine - only file uploads are affected.

### WAF PoC — `wordpress-with-waf`
Proof of concept, not a standalone app - puts OWASP CoreRuleSet/ModSecurity
in front of the `wordpress` branch's app, which becomes privately-routed
(no public URL of its own). Demonstrates that Rock8Cloud's internal
service-linking mechanism (normally used for DB credentials) generalizes to
routing a public reverse proxy to *any* private origin service, not just a
database. See that branch's `README.md` for the WAF-specific gotchas.

### Zipline (drag-n-drop file share) — `zipline`
Working end-to-end: upload, S3-backed storage, HTTPS shareable links
downloadable by anyone with the link (no account needed). Postgres via
Drizzle ORM, not the SQLite-locked Pingvin Share candidates originally
considered - see that branch's `README.md` for why, plus several
platform-specific gotchas (double bucket-prefixing, a broken Docker
layer cache, and an OOM crash on first-admin setup at the platform's
default resource allocation).

### Shlink (URL shortener + QR codes) — `shlink`
Working end-to-end: shorten a link, generate a QR code for it, no
third-party service ever sees the destination. Two Rock8Cloud services from
one branch (API + web UI, two Dockerfiles) - see that branch's
`README.md` for why, plus a Postgres-TLS gotcha that *didn't* need a
workaround (a useful counterexample to the pattern every other branch
hits) and a reminder that QR generation moved client-side as of
Shlink 5.0, so the web UI isn't optional for this use case.

## Where to look next

- **Deploying something new?** Read `.claude/skills/rock8-deploy/SKILL.md`
  (present on every app branch) first - battle-tested gotchas (ports, TLS,
  S3 addressing, health checks, debugging a failed deploy) that cost real
  hours to learn.
- **Digging into one app's history?** Each app branch keeps its own
  `README.md` - design decisions, gotchas, and current known limitations
  for that specific app.

## Platform constraints (why every branch looks the way it does)

These hold for any Rock8Cloud org, not just this fork's - they're the
reason every app branch is shaped the way it is:

- **No MySQL** on Rock8Cloud - Postgres only (native, managed). MySQL-only apps
  (e.g. Ghost) need a compat layer or don't fit.
- **No PVCs** - container filesystem is ephemeral, and on some tiers even
  parts of it are read-only outside `/tmp`. Persistent data goes:
  DB -> managed Postgres, files -> S3 (Garage), config/code -> git.
- **`/etc/hosts` is read-only at runtime** - a fix design that needs to
  write it at container start (e.g. a DNS-alias workaround) won't work -
  see the `mattermost` branch's `README.md` for a real case this blocked.
- **Postgres requires TLS**; its cert isn't from a trusted CA, so most
  clients need an explicit "don't verify" option (or a local stunnel proxy
  if the client can't express that - see the `wikijs` branch's `README.md`
  for why).
- **S3 buckets have multiple distinct hostnames** (bare gateway host,
  authenticated API host, separate public/unsigned-read host) - using the
  wrong one for the wrong purpose is an easy mistake. See the `wordpress`
  branch's `README.md` for the specifics.
- Env vars are linked from managed services (DB, S3) rather than
  hand-copied - see the `rock8-deploy` skill for the exact MCP workflow.

## Adding a new app - checklist

1. New branch off `master` (or any existing app branch), stripped to just
   `Dockerfile` + `docker/` config - no leftovers from other apps.
2. Official image where possible; container port just needs to match
   whatever's configured on the Rock8Cloud service (no fixed platform requirement).
3. Persistent data ONLY into managed Postgres / S3 - container FS is ephemeral.
4. Postgres connection needs TLS with lenient cert validation - see
   "Platform constraints" above.
5. Link env vars with renaming, e.g. `HOST->DB_HOST`, `NAME->DB_NAME`, ...
6. Add the new URL as an endpoint in the `gatus` branch (`docker/config.yaml`)
   AND add a row to the table above.
7. Log the deploy (design decisions, gotchas hit) in that branch's own
   `README.md`.
