#!/bin/sh
# 由 hydra-client-seed 服务调用：按 docker/.env 注册/更新 OpenBKN 的 OAuth 客户端。
#
# 注册三类客户端：
#   openbkn-studio  Studio 网页登录（authorization_code）
#   openbkn-cli     CLI 浏览器登录（authorization_code + 本地回调）
#   openbkn-sdk     CLI 设备码登录（device_code）
#
# Hydra 的行为：
#   PUT  /admin/clients/{id}  只能更新已存在的客户端，不存在时返回 404
#   POST /admin/clients       新建，重复创建返回 409
# 所以这里先 PUT；404 再 POST；两者都失败才报错。已有客户端时再次执行会更新
# redirect_uris，访问地址变化后无需手工处理。
set -u

ADMIN="${HYDRA_ADMIN:-http://bkn-safe-hydra-admin:4445}"
BASE="${WEB_BASE_URL:-http://localhost:8080}"
BASE="${BASE%/}"

STUDIO_CLIENT_ID="openbkn-studio"
STUDIO_BODY=$(cat <<JSON
{
  "client_id": "${STUDIO_CLIENT_ID}",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",
  "redirect_uris": ["$BASE/studio/callback"],
  "post_logout_redirect_uris": ["$BASE/studio/", "$BASE/studio"],
  "scope": "openid offline",
  "audience": ["bkn-safe"]
}
JSON
)

# CLI 浏览器登录：0.1.0 SDK 默认监听 127.0.0.1:9010，并用 PKCE。
CLI_CLIENT_ID="openbkn-cli"
CLI_BODY=$(cat <<'JSON'
{
  "client_id": "openbkn-cli",
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",
  "redirect_uris": ["http://127.0.0.1:9010/callback"],
  "post_logout_redirect_uris": ["http://127.0.0.1:9010/successful-logout"],
  "scope": "openid offline all",
  "audience": ["bkn-safe"]
}
JSON
)

# CLI 设备码登录（RFC 8628），不依赖本地回调端口。
SDK_CLIENT_ID="openbkn-sdk"
SDK_BODY=$(cat <<'JSON'
{
  "client_id": "openbkn-sdk",
  "grant_types": ["urn:ietf:params:oauth:grant-type:device_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none",
  "scope": "openid offline",
  "audience": ["bkn-safe"]
}
JSON
)

# 等待 hydra admin 就绪
i=0
until curl -fsS -o /dev/null "$ADMIN/health/alive"; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then
    echo "hydra admin 未就绪: $ADMIN" >&2
    exit 1
  fi
  sleep 2
done

write_client() {
  method="$1"
  url="$2"
  body="$3"
  code=$(curl -sS -o /tmp/seed-body -w '%{http_code}' \
    -X "$method" -H 'Content-Type: application/json' --data "$body" "$url" || echo 000)
  echo "  $method $url -> $code"
  case "$code" in
    200 | 201 | 204) return 0 ;;
    409) return 0 ;;                    # 已存在，等同成功
    *) cat /tmp/seed-body 2>/dev/null >&2; return 1 ;;
  esac
}

seed_client() {
  client_id="$1"
  body="$2"
  attempt=0
  while [ "$attempt" -lt 5 ]; do
    attempt=$((attempt + 1))
    echo "第 ${attempt} 次注册 $client_id (base=$BASE)"

    code=$(curl -sS -o /tmp/seed-body -w '%{http_code}' \
      -X PUT -H 'Content-Type: application/json' --data "$body" \
      "$ADMIN/admin/clients/$client_id" || echo 000)

    if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "204" ]; then
      echo "$client_id 客户端已更新"
      return 0
    fi

    if [ "$code" = "404" ]; then
      # 客户端不存在：用 POST 创建
      if write_client POST "$ADMIN/admin/clients" "$body"; then
        echo "$client_id 客户端已创建"
        return 0
      fi
    else
      echo "PUT 返回 $code: $(cat /tmp/seed-body 2>/dev/null)" >&2
    fi

    sleep 3
  done

  echo "注册 $client_id 客户端失败（已重试 ${attempt} 次）" >&2
  return 1
}

# 重试：等 hydra 真正可写，同时容忍瞬时错误
seed_client "$STUDIO_CLIENT_ID" "$STUDIO_BODY" || exit 1
seed_client "$CLI_CLIENT_ID" "$CLI_BODY" || exit 1
seed_client "$SDK_CLIENT_ID" "$SDK_BODY" || exit 1

echo "OAuth 客户端注册完成"
exit 0
