#!/bin/sh
# 由 hydra-client-seed 服务调用：按 docker/.env 注册/更新 Studio 的 OAuth 客户端。
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
CLIENT_ID="openbkn-studio"

BODY=$(cat <<JSON
{
  "client_id": "${CLIENT_ID}",
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
  code=$(curl -sS -o /tmp/seed-body -w '%{http_code}' \
    -X "$method" -H 'Content-Type: application/json' --data "$BODY" "$url" || echo 000)
  echo "  $method $url -> $code"
  case "$code" in
    200 | 201 | 204) return 0 ;;
    409) return 0 ;;                    # 已存在，等同成功
    *) cat /tmp/seed-body 2>/dev/null >&2; return 1 ;;
  esac
}

# 重试：等 hydra 真正可写，同时容忍瞬时错误
attempt=0
while [ "$attempt" -lt 5 ]; do
  attempt=$((attempt + 1))
  echo "第 ${attempt} 次注册 $CLIENT_ID (base=$BASE)"

  code=$(curl -sS -o /tmp/seed-body -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/json' --data "$BODY" \
    "$ADMIN/admin/clients/$CLIENT_ID" || echo 000)

  if [ "$code" = "200" ] || [ "$code" = "201" ] || [ "$code" = "204" ]; then
    echo "openbkn-studio 客户端已更新: $BASE"
    exit 0
  fi

  if [ "$code" = "404" ]; then
    # 客户端不存在：用 POST 创建
    if write_client POST "$ADMIN/admin/clients"; then
      echo "openbkn-studio 客户端已创建: $BASE"
      exit 0
    fi
  else
    echo "PUT 返回 $code: $(cat /tmp/seed-body 2>/dev/null)" >&2
  fi

  sleep 3
done

echo "注册 openbkn-studio 客户端失败（已重试 ${attempt} 次）" >&2
exit 1
