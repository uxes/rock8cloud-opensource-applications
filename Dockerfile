# WAF PoC on Rock8Cloud: OWASP CoreRuleSet (ModSecurity) reverse-proxying to
# a private origin app in the same project (WordPress on staging). See
# PROGRESS.md for the full architecture and setup.
#
# Deliberately does NOT override ENTRYPOINT/CMD - the official image (built
# on the standard nginx image) already runs every *.sh/*.envsh script under
# /docker-entrypoint.d/ before starting nginx. We hook into that documented
# mechanism instead of guessing/replacing the base image's own entrypoint
# chain (lesson from the silverbullet branch).
FROM owasp/modsecurity-crs:nginx

# Base image already drops to a non-root user by this point - need root
# back to chmod a file under /docker-entrypoint.d/.
USER root

# .envsh (not .sh) - the base image's docker-entrypoint.sh sources these
# with `.`, so the exported BACKEND survives into the nginx process and
# into this image's own later docker-entrypoint.d scripts.
# Numbered 05 - MUST run before 20-envsubst-on-templates.sh, which bakes
# $BACKEND into the nginx config templates. Running after it (tried
# 40- first) silently left BACKEND unset at envsubst time, so nginx fell
# back to localhost:80 and every request 502'd.
COPY docker/05-compose-backend.envsh /docker-entrypoint.d/05-compose-backend.envsh
RUN chmod +x /docker-entrypoint.d/05-compose-backend.envsh

# Patches the RENDERED nginx config (not the template - see the script's
# own comment for why) to deny dotfile paths (.git, .env, etc.). Runs
# after 20-envsubst-on-templates.sh (base nginx image), which is why it's
# numbered 21.
COPY docker/21-deny-dotfiles.sh /docker-entrypoint.d/21-deny-dotfiles.sh
RUN chmod +x /docker-entrypoint.d/21-deny-dotfiles.sh

# Targeted ModSecurity rule exclusion (see the file's own comment) for a
# well-documented CRS false positive with WordPress's Gutenberg editor.
# This is the base image's own documented override template path
# (confirmed via 90-copy-modsecurity-config.sh's source, not guessed) -
# safe to replace outright since it contains no ${...} sequences for
# envsubst to mis-render, unlike the default.conf.template mistake.
COPY docker/modsecurity-override.conf.template /etc/nginx/templates/modsecurity.d/modsecurity-override.conf.template

# Back to the base image's own non-root runtime user (confirmed via its
# own Dockerfile source - "nginx" - rather than guessed).
USER nginx

EXPOSE 8080
