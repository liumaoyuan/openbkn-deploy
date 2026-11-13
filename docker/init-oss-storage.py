"""初始化默认 OSS 存储：确保 MinIO 桶存在，并在 OSS 网关注册为默认存储。

为什么需要这一步：docker 部署若缺少它，t_storage_config 为空，operator-integration
查不到默认存储，执行工厂的 SKILL 包上传会报 desc.OSSGatewayDefaultStorageNotFound；
即使存储登记成功，MinIO 里没有对应桶时上传仍会报 NoSuchBucket。

运行环境：jiuge-bkn/sandbox-control-plane 镜像（包内唯一自带 S3 客户端的镜像，
boto3 在 /app/.venv 中）。在 compose 网络内执行，可访问 minio 与 oss-gateway-backend。

幂等：桶已存在、默认存储已存在时都直接跳过。
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

import boto3
from botocore.exceptions import ClientError

GATEWAY = os.environ.get("OSS_GATEWAY_URL", "http://oss-gateway-backend:8080/api/v1")
BUCKET = os.environ.get("BKN_OSS_BUCKET", "jiuge-bkn-objects")
STORAGE_NAME = os.environ.get("BKN_OSS_STORAGE_NAME", "minio-default")
ENDPOINT = os.environ.get("S3_ENDPOINT_URL", "http://minio:9000")
REGION = os.environ.get("S3_REGION", "us-east-1")
ACCESS_KEY = os.environ.get("S3_ACCESS_KEY_ID", "")
SECRET_KEY = os.environ.get("S3_SECRET_ACCESS_KEY", "")
MAX_ATTEMPTS = int(os.environ.get("OSS_MAX_ATTEMPTS", "30"))


def log(message):
    print(f"[oss-storage-init] {message}", flush=True)


def fail(message):
    print(f"[oss-storage-init] 失败：{message}", file=sys.stderr, flush=True)
    sys.exit(1)


def http(method, path, payload=None):
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(GATEWAY + path, data=body, method=method)
    if body is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode("utf-8"))


def ensure_bucket(client):
    try:
        client.head_bucket(Bucket=BUCKET)
        log(f"桶已存在：{BUCKET}")
        return
    except ClientError as exc:
        code = str((exc.response or {}).get("Error", {}).get("Code", ""))
        if code not in {"404", "NoSuchBucket", "NotFound"}:
            fail(f"检查桶 {BUCKET} 失败：{exc}")
    client.create_bucket(Bucket=BUCKET)
    log(f"已创建桶：{BUCKET}")


def wait_for_gateway():
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return http("GET", "/storages?enabled=true&is_default=true")
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            if attempt >= MAX_ATTEMPTS:
                fail(f"OSS 网关接口不可达（{GATEWAY}）：{exc}")
            time.sleep(2)


def main():
    if not ACCESS_KEY or not SECRET_KEY:
        fail("缺少 S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY（应由 MinIO 账号提供）")

    client = boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        region_name=REGION,
    )
    ensure_bucket(client)

    existing = wait_for_gateway()
    if existing.get("data"):
        log("默认 OSS 存储已存在，跳过")
        return

    created = http(
        "POST",
        "/storages",
        {
            "storage_name": STORAGE_NAME,
            "vendor_type": "ECEPH",
            "endpoint": ENDPOINT,
            "bucket_name": BUCKET,
            "access_key_id": ACCESS_KEY,
            "access_key_secret": SECRET_KEY,
            "region": REGION,
            "is_default": True,
        },
    )
    storage_id = (created.get("data") or {}).get("id")
    if not storage_id:
        fail(f"注册默认存储返回异常：{created}")
    log(f"已注册默认存储 {storage_id}（bucket={BUCKET}, endpoint={ENDPOINT}）")

    try:
        checked = http("POST", f"/storages/{storage_id}/check")
    except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
        log(f"警告：连接检查请求失败：{exc}")
        return
    if (checked.get("data") or {}).get("connected") is True:
        log("连接检查通过")
    else:
        log(f"警告：连接检查未通过：{checked}")


if __name__ == "__main__":
    main()
