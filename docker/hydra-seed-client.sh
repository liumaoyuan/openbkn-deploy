#!/bin/sh
# 由 hydra-client-seed 服务调用：按 docker/.env 注册/更新 Studio 的 OAuth 客户端。
#
# 使用 PUT /admin/clients/{id}（Hydra 的 upsert 语义），所以访问地址变化后
# 重新执行一次就能把 redirect_uris 更新成新地址，不需要先删除客户端。
set -eu

ADMIN="${HYDRA_ADMIN:-http://bkn-safe-hydra-admin:4445}"
BASE="${WEB_BASE_URL:-http://localhost:8080}"
BASE="${BASE%/}"

BODY=$(cat <<JSON
{
  "client_id": "openbkn-studio",
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

i=0
until curl -fsS -o /dev/null "$ADMIN/health/alive"; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then
    echo "hydra admin 未就绪: $ADMIN" >&2
    exit 1
  fi
  sleep 2
done

curl -fsS -X PUT -H 'Content-Type: application/json' --data "$BODY" \
  "$ADMIN/admin/clients/openbkn-studio" >/dev/null

echo "openbkn-studio 客户端已更新: $BASE"
