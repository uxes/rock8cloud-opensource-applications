# SilverBullet on Rock8Cloud

[SilverBullet](https://silverbullet.md/) (markdown-first, browser-based
personal notes) with a git-based persistence workaround for a platform
with no persistent volumes and no S3 backend option for this particular
app. Non-root at runtime.

## The core problem: no PVC, and no S3 backend for this app

Every other app in this repo routes persistent data through managed
Postgres or S3. SilverBullet has neither option available to it - its
`/space` folder (notes + attachments) is designed around a plain writable
filesystem, and the official image explicitly expects a volume mount.
There's no S3/object-storage backend for it at all (confirmed via the
project's own docs/GitHub).

**Solution: git-based sync**, using SilverBullet's own actively-maintained
Git plug/library:
- `docker/entrypoint.sh` clones (or pulls, on redeploy) `/space` from a
  git remote on boot, before handing off to the app itself.
- SilverBullet's Git plug, once enabled with `git.autoSync` set in its
  SETTINGS page (a one-time manual step via the web UI after first
  deploy - not automatable from the container side), auto-commits and
  pushes changes back on a timer while running.
- Data-loss window is bounded by the autoSync interval (e.g. 5 minutes),
  not "everything since the last deploy" - fine for personal notes, worth
  tightening if this becomes something more.

**The actual git remote is never hardcoded anywhere in this repo** -
Dockerfile, entrypoint, docs, commit messages, none of it. It's wired
entirely through Rock8Cloud env vars at deploy time:
- `NOTES_GIT_REPO` - remote host+path, no scheme (e.g.
  `some-git-host.example/owner/repo.git`). The entrypoint accepts both
  this bare form and SSH-shorthand (`git@host:owner/repo.git`) -
  normalizing the latter was a real bug fix, see below.
- `NOTES_GIT_TOKEN` - a write-scoped access token for that repo, used as
  an OAuth2-style bearer credential.
- `NOTES_GIT_BRANCH` - defaults to `main`.

## Auth

Built-in single-user auth via `SB_USER=username:password` (no multi-user/
signup support - a Space is inherently personal). Set as a manual Rock8
env var, never baked into the image.

## Gotchas worth knowing before repeating this

- **Don't trust a base image's GitHub source Dockerfile to match the
  actually-published tag.** Two separate assumptions from reading the
  upstream repo's Dockerfile turned out wrong for the real
  `docker.io/zefhemel/silverbullet:latest` image: it doesn't ship a
  `/docker-entrypoint.sh` wrapper with PUID/PGID privilege-drop logic (the
  published tag is just a single self-contained compiled binary at
  `/silverbullet`, confirmed via a runtime `ls -la /`), and there's no
  built-in privilege drop at all - this Dockerfile creates its own
  unprivileged user and drops to it explicitly via `su-exec` before the
  final `exec`. If a base-image assumption about internal file layout
  fails at runtime, verify against the actual running container rather
  than re-reading the source a second time.
- **Accept multiple credential-URL shapes, don't assume one.** The first
  production attempt failed because `NOTES_GIT_REPO` was set to
  SSH-shorthand (`git@host:owner/repo.git`) while the entrypoint expected
  a bare `host/path` string - the `:` before the path got parsed as a
  `host:port` separator by git/curl and rejected (`owner` isn't a numeric
  port). Fixed by normalizing: strip a leading scheme, strip a leading
  `user@`, and rewrite the first `host:path` colon to a slash - so both
  shapes work rather than requiring users to know the "right" one.
- **A hardcoded fallback path for a base image's entrypoint can fail even
  when it "should" be right per upstream source** (see the first gotcha)
  - search a few candidate paths, fall back to a bounded `find`, and log
    what was actually found (including its shebang) rather than assuming
    a single path and failing opaquely if it's wrong.

## Deployment target

Deployed to a persistent/production-tier environment rather than a
throwaway staging one - personal notes need actual reliability, not
best-effort uptime.

## Known limitations (PoC)

- First-run setup (enabling the Git plug, setting `git.autoSync`) needs a
  human, once, via the web UI - not pre-baked into the image.
- If the pod is killed between autoSync intervals, whatever wasn't synced
  yet is lost - acceptable for personal notes, worth tightening (shorter
  interval, or a sync-on-shutdown hook) for anything more critical.
- `git clone`/`pull` failures at boot are logged as warnings and the
  container still starts (fail-open) - a transient git-host outage could
  silently start SilverBullet with a stale or empty space rather than
  blocking startup. Worth reconsidering for production use beyond a PoC.
