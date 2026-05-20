---
name: rock8-deploy
description: Deploy any web application (WordPress, MediaWiki, Matomo, custom PHP/Node/Python apps) to Rock8Cloud - project/service setup, Dockerfile patterns, Postgres/S3(Garage) wiring, env var linking, real client IPs behind the envoy ingress, healthchecks, debugging failed deploys, and ephemeral-filesystem rules. Use when creating or deploying a new service on Rock8Cloud, wiring linked env vars, configuring S3 buckets, fixing "Live but crashing"/failed deployments, or when app logs show internal 10.x IPs instead of client IPs.
---

# Deploy an application on Rock8Cloud

Battle-tested recipe distilled from deploying WordPress (master branch) and
MediaWiki (feature/mediawiki) in this repo. Read fully before starting a new
deployment; every gotcha below was hit for real and cost hours.

## Platform model (non-negotiable facts)

- **No MySQL** on Rock8Cloud. Native services: **PostgreSQL** + **S3 (Garage)**.
  An app needing MySQL must use a compat layer (WP: PG4WP) or native PG.
- **No PVCs.** The container filesystem is EPHEMERAL - everything written at
  runtime is lost on every redeploy (and pods get replaced randomly).
  Persistent data goes: DB -> managed Postgres, files/uploads -> S3,
  config/code -> git.
- **Container port MUST be 8080** (sed Apache `Listen 80` -> `8080`).
- **Immutable deployment**: bake all config/plugins into the image via
  Dockerfile `COPY`; entrypoint may only bootstrap data, never write config.

## MCP tool workflow (in order)

1. `list_organizations` -> org id
2. `list_projects` / `create_project`
3. `create_repo_service` (repoUrl, branch with the app's Dockerfile,
   containerPort `8080`)
4. `provision_postgres` and/or `provision_object_storage` if needed
5. `link_env_vars` **with key renaming** - source exports bare keys:
   ```
   HOST->DB_HOST, PORT->DB_PORT, NAME->DB_NAME, USER->DB_USER,
   PASSWORD->DB_PASSWORD   (S3: S3_ENDPOINT/S3_BUCKET/S3_REGION/
   S3_FORCE_PATH_STYLE/S3_ACCESS_KEY/S3_SECRET_KEY keep their names)
   ```
6. Manual runtime env vars via `write_manual_env_vars` (e.g. server URL)
7. `deploy_service`; then poll `get_latest_build` /
   `get_deployment_status` (do NOT blind-sleep)

## Branch strategy in this repo

- `master` = WordPress deployment - **do not touch**
- one `feature/<app>` branch per app; each has its own root `Dockerfile`

## Dockerfile pattern

```dockerfile
FROM debian:bookworm-slim            # or language-official image
ARG CACHE_BUST=1                     # bump value to force rebuild
RUN apt-get update && apt-get install -y apache2 ... # php/python/node deps
# ... download/install app code ...
RUN sed -i 's/Listen 80/Listen 8080/g' /etc/apache2/ports.conf \
 && sed -i 's/<VirtualHost \*:80>/<VirtualHost \*:8080>/g' /etc/apache2/sites-available/*.conf

RUN echo "cache bust ${CACHE_BUST}"   # <-- MUST be USED before COPYs!
COPY docker/app-config.php /var/www/html/...
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### Cache-bust gotcha (cost us a stale-config incident)
Docker invalidates cache only from the FIRST instruction that USES an ARG.
An ARG declared at the top but referenced in the LAST layer does nothing -
`COPY docker/config.php` layers stay cached and ship STALE config forever.
Always put `RUN echo ${CACHE_BUST}` immediately BEFORE the COPY steps.
Verify what actually shipped by building locally (`podman build`) and
grepping the file inside the image - remote build logs show `(cached)` per
step, that's the tell.

## Entrypoint rules

- Idempotent: safe on every restart (check schema/data exists first).
- **Fail-open**: wrap maintenance scripts (`if ! php maintenance/update.php;
  then echo WARNING; fi`). A failing maintenance task that exits non-zero
  kills the container BEFORE the app starts -> crash loop marked
  "Live · Crashing" even though only a side concern (e.g. storage) broke.
- Keep it fast: platform healthcheck window after rollout is short (~15-60 s).

## Health endpoint

Provide `/health.php` (or similar): dependency-free, `http_response_code(200)`,
no auth. Add an explicit rewrite SKIP for it (see .htaccess below), otherwise
clean-URL rewrites turn it into a wiki/CMS page route and the probe gets a
301/404 -> deployment marked Failed although the app is fine.

## Clean URLs (.htaccess)

RewriteCond binds only to the NEXT RewriteRule - an unconditioned catch-all
rewrites EVERYTHING including load.php/static assets. Explicitly skip each
front controller and static dir:

```apacheconf
RewriteRule ^(favicon\.ico|load\.php|api\.php|rest\.php|health\.php)$ - [L]
RewriteRule ^(resources|images)/ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule ^(.*)$ index.php [L]
```

## S3 (Garage) specifics

- Bucket name == Rock8Cloud service name. Public URL of objects:
  `https://<bucket>.public.storage.rock8.cloud/<key>`
- **Public reads require the "Public Access" checkbox on the bucket in the
  Rock8Cloud GUI** (Garage has no anonymous S3 API access). Without it: upload
  succeeds, object exists, public URL 404s - looks like broken config.
- `S3_ENDPOINT` arrives bucket-prefixed WITH an artifact:
  `<bucket>.https/<host>`. Normalize: strip scheme, strip `.https`, strip
  bucket prefix joined by EITHER `.` OR `/`. Result: bare host
  (`storage.rock8.cloud`).
- Addressing style: respect `S3_FORCE_PATH_STYLE` per bucket; Rock8Cloud's gateway
  is virtual-hosted-style only (bucket baked into hostname). Wrong style =
  bare HTTP 404, not an S3 XML error.
- Use a maintained storage integration that replaces the WHOLE backend
  (MediaWiki: Extension:AWS; WP: S3-Uploads) - upload-stash/temp phases write
  before any post-upload hook can redirect them, so hand-rolled hooks can't
  prevent local-disk writes.

## Real client IPs behind the ingress

Every request arrives with `REMOTE_ADDR` = envoy pod IP (10.244.x.x); the
real IP is ONLY in `X-Forwarded-For` (also `X-Envoy-External-Address`).
The Rock8Cloud log viewer shows edge envoy logs with real IPs - container access
logs never appear there.

- **Apache apps**: enable `mod_remoteip` (`RemoteIPHeader X-Forwarded-For`,
  `RemoteIPTrustedProxy 10.0.0.0/8`) so REMOTE_ADDR becomes the real IP.
- **MediaWiki**: `$wgUseCdn = true; $wgCdnServersNoPurge = ['10.0.0.0/8'];`
  **CIDR ranges go in CdnServersNoPurge** - `$wgCdnServers` is exact-match
  `in_array()` only and silently never matches ranges.
- **Matomo/other PHP**: set its "trust X-Forwarded-For from proxy" option,
  proxy CIDR 10.0.0.0/8.

## Auth behind the proxy

Web-form logins can fail ("session timed out") due to cookie domain handling
between envoy and the container. Prefer API-based auth in tests/scripts
(MediaWiki: action=query&meta=tokens + action=login). Upload APIs need
`ignorewarnings=1` or duplicate content returns Warning+filekey and is NOT
published.

## Debugging a failed/unhealthy deploy

1. `get_latest_build` -> buildJobId; build OK? All steps `(cached)`?
2. `get_build_logs_by_build_id` for compile/clone errors
3. `get_runtime_logs` (search by exact error substring, e.g. `S3Exception`;
   level=error filters noise) - look for startup sequence: entrypoint ->
   update/migrate -> Apache start
4. Verify image CONTENT, not repo state (stale-cache trap): build locally
   with podman and grep the file inside the running container
5. Auto-deploy on push sometimes doesn't fire - trigger `deploy_service`
   manually before assuming the commit is broken
6. Envoy quirks: initial GETs may return 301/404 while the body contains the
   full page - judge by CONTENT, not status code
7. Never blind-sleep while waiting - poll `get_deployment_status`

## Testing

Keep smoke tests in `tests/` as plain python3+requests scripts taking
BASE_URL as argv[1]/env: main page renders, static assets 200, API login,
CRUD a page/post, upload file AND fetch it back from its PUBLIC URL
(proves both persistence and the GUI checkbox). See
`tests/test_mediawiki.py`, `tests/test_s3_upload.py`.

For deep history of dead ends (PG install vs update.php, PG4WP quirks,
S3 endpoint parsing evolution) see each app branch's own `README.md`
before repeating any investigation.
