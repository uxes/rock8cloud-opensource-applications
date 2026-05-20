#!/bin/sh
# Patches to the S3-Uploads (humanmade) vendor plugin.
set -eu

WRAPPER=/var/www/html/wp-content/plugins/s3-uploads/inc/class-stream-wrapper.php

# S3-Uploads 3.0.3's stream wrapper was written against the AWS SDK's older
# ListObjects call; the bundled SDK version here only implements the newer
# ListObjectsV2 (which Rock8Cloud's S3-compatible gateway also expects). Swap it.
sed -i "s/getPaginator( 'ListObjects'/getPaginator( 'ListObjectsV2'/g" "$WRAPPER"
sed -i "s/listObjects(/listObjectsV2(/g" "$WRAPPER"
