#!/bin/sh
# 由 config-init 服务调用：把 config.template 里的 ${变量} 按 docker/.env 渲染到 config/。
#
# 使用 busybox awk 的 ENVIRON 读取环境变量，不依赖 gettext/envsubst，
# 离线环境也能运行。值里出现 & / \ 等字符时按字面量处理（拼接而非 gsub）。
set -eu

if [ ! -d /in ]; then
  echo "缺少 /in 配置模板目录" >&2
  exit 1
fi

mkdir -p /out

count=0
find /in -type f | while IFS= read -r src; do
  rel="${src#/in/}"
  # compose 会为“文件级挂载”预先创建同名空目录，这里先清掉，否则无法写入文件。
  if [ -d "/out/$rel" ]; then
    rm -rf "/out/$rel"
  fi
  mkdir -p "/out/$(dirname "$rel")"
  awk '
    {
      line = $0
      while (match(line, /\$\{[A-Z0-9_]+\}/)) {
        key = substr(line, RSTART + 2, RLENGTH - 3)
        value = (key in ENVIRON) ? ENVIRON[key] : ""
        line = substr(line, 1, RSTART - 1) value substr(line, RSTART + RLENGTH)
      }
      print line
    }
  ' "$src" > "/out/$rel"
done

echo "config rendered: $(find /out -type f | wc -l) files"
