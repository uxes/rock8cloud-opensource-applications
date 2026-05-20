<?php
// Health endpoint for the platform probe. Keep it dependency-free and fast:
// it must answer 200 immediately after Apache starts (the healthcheck window
// is short and startup maintenance runs before this process exists).
http_response_code(200);
echo "OK";
