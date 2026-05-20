# shlink-web-client (companion web UI for the Shlink API server defined
# in the repo-root Dockerfile). A React SPA served by nginx; it points
# at the API entirely via runtime env vars, no build-time config needed.
#
# SHLINK_SERVER_URL / SHLINK_SERVER_API_KEY are set as manual Rock8Cloud env
# vars on the deployed service, not baked in here (the API key is a
# secret - it does not belong in git).
FROM shlinkio/shlink-web-client:latest
EXPOSE 8080
