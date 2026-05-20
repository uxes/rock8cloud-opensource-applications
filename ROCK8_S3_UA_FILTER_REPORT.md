# Bug Report: Rock8Cloud S3 gateway rejects requests by User-Agent ("minio-go")

**Priority:** High — blocks standard S3 SDK clients from working
**Affected service:** `*.storage.rock8.cloud` (Garage S3 gateway)
**Discovered:** 2026-08-23, while deploying Mattermost Team Edition 11.10

---

## Summary

The Rock8Cloud ingress/gateway in front of Garage S3 returns **403
AccessDenied** for correctly signed S3 API requests whose `User-Agent`
header contains the substring `minio-go` (case variants included).
Identical requests with any other User-Agent succeed.

This silently breaks every application built on the Go minio-go SDK —
including Mattermost, one of the most common self-hosted apps — with a
misleading error (`bucket does not exist`), because minio-go interprets
the 403 as "bucket missing", falls back to CreateBucket, and Garage
(rightly) denies bucket creation to application credentials.

## Evidence

Raw sigv4-signed HEAD requests executed **from inside the cluster pod**
against `https://<bucket>.storage.rock8.cloud/`, identical signatures,
only the User-Agent header varied:

| Request | User-Agent | Result |
|---|---|---|
| HEAD / | *(python default)* | **200 OK** |
| HEAD / | `x-amz-checksum-mode: enabled` | **200 OK** |
| HEAD / | `x-amz-sdk-checksum-algorithm: CRC32` | **200 OK** |
| HEAD / | `minio-go/v7.17.0` | **403 AccessDenied** |
| HEAD / | `minio-go` | **403 AccessDenied** |
| HEAD / | `MinIO` | **403 AccessDenied** |
| HEAD / | `foo minio-go bar` | **403 AccessDenied** |

Additional verified facts:

- The same credentials work via s3cmd and boto3 (vhosted style):
  ListObjects and PutObject succeed.
- Addressing style: **virtual-hosted works**, path-style returns 404 for
  all operations (relevant context, not the cause here).
- Missing `x-amz-content-sha256` header → 400 (expected S3 behaviour).
- The bucket exists; anonymous GET returns `AccessDenied` (private
  bucket), not `NoSuchBucket`.

## Impact

Any Rock8Cloud customer deploying an app whose S3 client identifies itself as
minio-go gets:

1. `BucketExists()` → false (403 swallowed by the SDK)
2. Automatic fallback to `MakeBucket()` → denied by Garage
3. Fatal startup or runtime errors like:
   `unable to create the s3 bucket: The specified bucket does not exist.`

Real-world casualties: Mattermost (file uploads completely broken),
MinIO-based backup tools, Go applications using aws-sdk-go with a custom
UA containing "minio".

## Expected behaviour

Signed, authenticated S3 requests should be routed to Garage regardless
of User-Agent. If UA filtering is an anti-abuse measure, it should not
match legitimate SDK identifiers, or there should be a documented
allowlist mechanism.

## Suggested fix

- Remove or narrow the UA rule matching `minio-go` on
  `*.storage.rock8.cloud`, **or**
- Document an internal/in-cluster S3 endpoint without the filter
  (`S3_FORCE_PATH_STYLE` hints that one exists) together with its
  addressing style, **or**
- Provide a per-bucket/per-key opt-out flag in the dashboard.

## Workarounds we had to consider

1. Binary-patching `/mattermost/bin/mattermost` at image build time:
   replacing the embedded string `minio-go` with an equal-length string
   so the UA passes the filter. Works, but is fragile and absurd.
2. Running a local TLS-terminating proxy in the pod solely to rewrite
   the User-Agent header.
3. Asking Rock8Cloud support to lift the filter (this report).

## Reproduction

```bash
# From any pod in the cluster, with valid bucket credentials:
curl -I https://<bucket>.storage.rock8.cloud/ \
  -H "Authorization: AWS4-HMAC-SHA256 <valid signature>" \
  -A "minio-go/v7.17.0"
# → 403 AccessDenied

# Same request, different UA:
curl -I https://<bucket>.storage.rock8.cloud/ \
  -H "Authorization: AWS4-HMAC-SHA256 <same valid signature>" \
  -A "anything-else"
# → 200 OK
```

Full diagnostic tooling used: a raw SigV4 request generator plus
boto3/s3cmd comparisons, run from inside a pod on this platform.
