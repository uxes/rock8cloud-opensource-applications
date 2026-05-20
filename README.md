# Gatus uptime monitor, on Rock8Cloud

[Gatus](https://github.com/TwiN/gatus) watching every other app deployed
from this repo, with Postgres-backed status history.

## Design

- Official image (`twinproduction/gatus`) already listens on 8080,
  matching the platform's expected container port - no remap needed.
- `docker/config.yaml` is baked into the image at build time. Database
  credentials are **not** hardcoded - they arrive as linked env vars and
  Gatus's own config loader expands `${VAR}` references in the YAML at
  startup.
- Storage: `type: postgres`, connected via `?sslmode=require` (Rock8Cloud's
  managed Postgres enforces TLS).

## Gotchas worth knowing before repeating this

- **An empty `security.basic` block is invalid config**, not merely
  "no auth" - omit the `security` key entirely if you don't want
  Basic Auth in front of the dashboard, rather than leaving it empty.
- **Update `docker/config.yaml`'s endpoint list every time you deploy a
  new app** - it's static, baked in at build time, not auto-discovered.

## Adding an endpoint

Add a block to `docker/config.yaml`:

```yaml
endpoints:
  - name: My App
    url: https://your-app.apps.rock8.cloud/health
    interval: 60s
    conditions:
      - "[STATUS] == 200"
```

Redeploy this service afterward for the change to take effect.
