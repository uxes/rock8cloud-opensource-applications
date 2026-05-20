# Mattermost on Rock8Cloud

Mattermost Team Edition against **Postgres**, with **S3** for file
storage. Chat/Postgres functionality works; file uploads are currently
blocked by a platform-side S3 gateway limitation (see below) - not a bug
in this branch's own code, as far as could be determined.

## Design

- Non-root at runtime.
- Plugins disabled wholesale (`MM_PLUGINSETTINGS_ENABLE=false`) - the
  largest RAM consumers (calls/AI/playbooks) mostly need licenses anyway.
- Listens on 8080 via `MM_SERVICESETTINGS_LISTENADDRESS` (Mattermost
  defaults to 8065).

## The S3 upload problem: two layered platform issues

**1. Rock8Cloud's S3 gateway (Garage) 403s any request whose `User-Agent`
contains `minio-go`** - Mattermost's Go S3 client sends exactly that,
with no config knob to change it. See `ROCK8_S3_UA_FILTER_REPORT.md` for
the full writeup with reproduction steps; short version: identical
SigV4-signed requests succeed with any other User-Agent, so this reads as
a UA-based anti-abuse rule, not an auth problem, and it breaks every
Go/minio-go-based S3 client on the platform, not just Mattermost.

**Workaround attempted**: a local nginx proxy that rewrites *only*
`User-Agent`, leaving everything else (crucially, `Host`) untouched -
because AWS SigV4 signs the `Host` header the client used, and a proxy
that changes `Host` after signing invalidates the signature (confirmed
empirically: rewriting `Host` to a virtual-hosted value turned "bucket
does not exist" into "Access Denied", a different failure mode, not a
fix). To route the client's TCP connection to this local proxy *without*
changing the Host header it signs with, the plan was to alias the real
bucket vhost to `127.0.0.1` via `/etc/hosts` at container start - Go's
own HTTP client builds its Host header from the configured endpoint URL,
independent of which IP that hostname actually resolves to, so this
should work in principle.

**2. `/etc/hosts` is read-only at runtime on this platform.** Confirmed
directly (not inferred) via the boot log:
```
cannot create /etc/hosts: Permission denied
```
So the vhost-alias workaround for problem 1 can never actually activate
here - this isn't a transient/flaky issue, it's a hard platform
constraint as of this writing. A fix would need a different way to route
the client's TCP connection to a local UA-rewriting proxy without relying
on a writable `/etc/hosts` (e.g. a local DNS resolver overriding
`resolv.conf` for just the one hostname - itself unverified whether
`resolv.conf` is writable here either).

## Gotchas worth knowing before repeating this

- **A UA-based 403 from an S3 gateway can look exactly like "bucket
  doesn't exist"** if the client SDK swallows the 403 and falls back to
  auto-creating the bucket (which then fails for a different, unrelated
  reason - insufficient permission to create buckets). Don't trust the
  client's own error message; test the same signed request with a
  different User-Agent to isolate whether it's actually a UA filter.
- **A reverse proxy that "just" changes one header can silently break
  SigV4** even when that header seems unrelated to the fix you're making
  - `Host` in particular is part of what SigV4 signs, so anything that
    rewrites it between signing and the origin invalidates the signature.
- **"Permission denied" writing `/etc/hosts` inside a container usually
  means the platform enforces this globally**, not that it's specific to
  one app's container config - worth checking early if a fix design
  depends on runtime `/etc/hosts` writes, since it may be a dead end from
  the start on a given platform.

## Known limitations

- File uploads/attachments don't work (see above) - everything else
  (messaging, channels, Postgres-backed data) is unaffected.
