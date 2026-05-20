# WAF in front of a private origin, on Rock8Cloud

PoC: [OWASP CoreRuleSet](https://coreruleset.org/) / ModSecurity as a
reverse-proxy WAF in front of the `wordpress` branch's app, which is
itself never directly publicly reachable - only the WAF is.

## Why this is possible on Rock8Cloud

Rock8Cloud repo services can have public routing disabled while still
running and reachable **internally** from other services in the same
project - the same internal linking mechanism normally used for database
credentials (`HOST`/`PORT`/`URL`) also works for routing a public
reverse-proxy/WAF to a private origin service. This isn't specific to
WordPress - the same pattern works for putting a WAF (or any other
reverse proxy) in front of any other app in this repo.

```
Internet -> this service (public, ModSecurity/CRS reverse proxy)
              -> internal network -> origin app (no public route)
```

## Image and configuration

`owasp/modsecurity-crs:nginx` (official), fully configured via env vars -
`BACKEND` (composed from the origin's linked `HOST`/`PORT` - see gotchas
below), `NGINX_ALWAYS_TLS_REDIRECT=off` (the platform terminates TLS
upstream of this container).

## Gotchas worth knowing before repeating this

- **A linking API that only exposes metadata, not resolved values, means
  you can't preview the shape of a linked var ahead of time.** Rather
  than guess whether an origin's `URL` key is already in the exact
  `http://host:port` form a WAF/proxy needs, link `HOST`/`PORT`
  separately and compose the target URL yourself at container start.
- **Order matters when composing an env var that a template-rendering
  step consumes.** If a startup script builds `BACKEND` from other env
  vars, it must run *before* whatever renders the nginx config template
  that references `${BACKEND}` - composing it after silently leaves the
  variable unset at render time, with no error, just a fallback to
  `localhost` and every request failing.
- **Don't trust a base image's "main" branch source to match the exact
  published/pinned tag.** A full copy of the upstream nginx config
  template (to add one small addition) crash-looped nginx with `unknown
  variable` - the base image's own env-var substitution only fills in
  variables that actually exist in the container, and the real deployed
  image apparently sets/uses some defaults differently than what the
  latest "main" branch template/Dockerfile reflect. **Prefer patching the
  already-rendered output** (via a script that runs right after whatever
  renders it) over shipping a full copy of a template you can't verify
  byte-for-byte against the real image.
- **`X-Forwarded-Proto` isn't automatically derived from the actual
  connection scheme** in some proxy image templates - it can be sourced
  from an env var that defaults to empty/unset. If pages load but assets
  break as mixed content (`http://` links on an `https://` page), check
  whether the proxy is actually forwarding this header with the correct
  value, rather than assuming a reverse proxy does this by default.
- **A generic WAF ruleset will false-positive on legitimate app behavior
  that looks like an attack pattern** - e.g. a CMS that stores raw HTML
  comments or inline `<img>` tags as part of its own content format gets
  flagged by generic XSS/HTML-injection rules. The fix is a *narrowly
  scoped* rule exclusion (specific rule ID, specific request path,
  specific argument name) via the WAF's documented override mechanism -
  not lowering the overall paranoia/sensitivity level, which weakens
  protection everywhere, not just for the one false positive.
- **Verify a WAF rule-exclusion citation against the actual GitHub issue
  before writing it down** - two different false positives from the same
  underlying app-behavior category (raw HTML in stored content) can be
  *separate*, independently-reported issues against *different* rule
  IDs, not one report covering both. Don't assume one citation covers a
  second, similar-looking problem without checking.

## Verified working

- Plain requests return the real origin app's content (not just a 200
  status).
- A classic SQLi payload gets blocked with 403 (`libinjection`-based
  detection).
- Dotfile/sensitive-path probing (`.git`, `.env`, etc.) returns 404 -
  added as an explicit nginx rule, since a generic WAF ruleset doesn't
  treat "a path that shouldn't exist" as an attack signature the way it
  does an actual malicious payload.
- The origin app's own admin/API traffic (including the false-positive
  cases above) passes through cleanly after the scoped rule exclusions.

## Known limitations (PoC)

- This is a proof of concept demonstrating the platform's private-origin
  linking mechanism generalizes beyond database credentials - not a
  general-purpose hardened WAF configuration. Review the CRS paranoia
  level and rule exclusions before relying on this for anything beyond a
  PoC.
