<?php
add_filter("option_s3_uploads_enabled", function() { return "enabled"; });
add_filter("site_option_s3_uploads_enabled", function() { return "enabled"; });
add_filter("s3_uploads_s3_client_params", function($params) {
    $ep = getenv("S3_ENDPOINT");
    $bucket = getenv("S3_BUCKET");
    if ($ep) {
        $ep = str_replace(["http://", "https://"], "", $ep);
        if ($bucket && stripos($ep, $bucket . ".") === 0) {
            $ep = substr($ep, strlen($bucket) + 1);
        }
        $params["endpoint"] = "https://" . $ep;
    }
    $params["region"] = getenv("S3_REGION");
    // Rock8Cloud's S3 gateway is virtual-hosted-style only: the bucket lives in
    // the hostname (e.g. s3-mighty-967.storage.rock8.cloud), confirmed via
    // their dashboard "External URL". We strip the bucket prefix above to
    // get the bare host, then let the AWS SDK re-prepend the bucket itself
    // - that's exactly what path-style=false (virtual-hosted) does.
    // Forcing path-style here (bucket as URL path, e.g. host/bucket/) hits
    // routes Rock8Cloud's gateway doesn't serve and returns a bare HTTP 404.
    $params["use_path_style_endpoint"] = false;
    $params["signature_version"] = "v4";
    $connect_timeout = getenv("S3_CONNECT_TIMEOUT");
    $request_timeout = getenv("S3_REQUEST_TIMEOUT");
    $params["http"] = [
        "connect_timeout" => $connect_timeout !== false && $connect_timeout !== "" ? (float) $connect_timeout : 5.0,
        "timeout" => $request_timeout !== false && $request_timeout !== "" ? (float) $request_timeout : 30.0,
    ];
    $ssl_verify = getenv("S3_SSL_VERIFY");
    if ($ssl_verify !== false && $ssl_verify !== "") {
        $params["http"]["verify"] = filter_var($ssl_verify, FILTER_VALIDATE_BOOLEAN);
    }
    $params["debug"] = false;
    return $params;
});
if (file_exists(ABSPATH . "wp-content/plugins/s3-uploads/s3-uploads.php")) {
    require_once ABSPATH . "wp-content/plugins/s3-uploads/s3-uploads.php";
    if (class_exists("S3_Uploads\\Plugin")) {
        S3_Uploads\Plugin::get_instance()->setup();
    }
}
