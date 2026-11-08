#!/usr/bin/env python3
"""创建/更新 .env，并渲染 Compose 运行时配置。

典型用法：

  本机直接运行（默认 http://localhost:8080）：
      python init.py

  为内网目标机渲染配置（必须先做这一步，内网机就不用装 Python）：
      python init.py --public-base-url http://10.0.0.5:8080

  需要只改绑定地址时：
      python init.py --public-base-url http://10.0.0.5:8080 --bind-address 0.0.0.0
"""

from __future__ import annotations

import argparse
import base64
import os
import secrets
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

HERE = Path(__file__).resolve().parent
EXAMPLE = HERE / ".env.example"
DEFAULT_ENV_FILE = HERE / ".env"
RENDERER = HERE / "render_config.py"

LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "0.0.0.0"}


def secret(byte_count: int = 30) -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(byte_count)).decode("ascii").rstrip("=")


def initialize_env(env_file: Path) -> None:
    """首次运行时从 .env.example 生成 .env，并为 CHANGE_ME_* 生成随机值。"""
    if env_file.exists():
        return
    lines = []
    for line in EXAMPLE.read_text(encoding="utf-8").splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            lines.append(line)
            continue
        key, value = line.split("=", 1)
        if value.startswith("CHANGE_ME_"):
            value = secret(24) if key == "OSS_CRYPTO_AES_KEY" else secret()
        lines.append(f"{key}={value}")
    env_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        os.chmod(env_file, 0o600)
    except OSError:
        pass


def update_env(env_file: Path, overrides: dict[str, str]) -> None:
    """就地更新 .env 中指定的键，未存在的键追加到末尾。"""
    lines = env_file.read_text(encoding="utf-8").splitlines()
    updated: set[str] = set()
    result: list[str] = []
    for line in lines:
        stripped = line.lstrip()
        if "=" in line and not stripped.startswith("#"):
            key = line.split("=", 1)[0].strip()
            if key in overrides:
                result.append(f"{key}={overrides[key]}")
                updated.add(key)
                continue
        result.append(line)
    for key, value in overrides.items():
        if key not in updated:
            result.append(f"{key}={value}")
    env_file.write_text("\n".join(result) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="创建/更新 .env 并渲染 Compose 运行时配置。",
    )
    parser.add_argument(
        "--public-base-url",
        help="对外访问地址，例如 http://10.0.0.5:8080；非本机地址会自动绑定 0.0.0.0。",
    )
    parser.add_argument(
        "--bind-address",
        help="监听地址，默认本机为 127.0.0.1、非本机地址为 0.0.0.0。",
    )
    parser.add_argument(
        "--env-file",
        type=Path,
        default=DEFAULT_ENV_FILE,
        help=".env 路径，默认 docker/.env。",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    env_file: Path = args.env_file
    initialize_env(env_file)

    overrides: dict[str, str] = {}
    if args.public_base_url:
        overrides["OPENBKN_PUBLIC_BASE_URL"] = args.public_base_url.rstrip("/")
    if args.bind_address:
        overrides["OPENBKN_BIND_ADDRESS"] = args.bind_address
    elif args.public_base_url:
        host = urlparse(args.public_base_url).hostname or ""
        overrides["OPENBKN_BIND_ADDRESS"] = "127.0.0.1" if host in LOCAL_HOSTS else "0.0.0.0"

    if overrides:
        update_env(env_file, overrides)
        for key, value in overrides.items():
            print(f"{key}={value}")

    # 内置纯 Python 版 PyYAML（vendor/yaml），目标机/开发机都不需要 pip 安装依赖。
    child_env = dict(os.environ)
    vendor = str(HERE / "vendor")
    child_env["PYTHONPATH"] = vendor + (
        os.pathsep + child_env["PYTHONPATH"] if child_env.get("PYTHONPATH") else ""
    )
    result = subprocess.run(
        [sys.executable, str(RENDERER), "--env-file", str(env_file)],
        env=child_env,
        check=False,
    )
    if result.returncode == 0 and args.public_base_url:
        print()
        print("离线迁移：把下面这些内容拷到内网机，保持相对位置不变：")
        print(f"  {HERE}")
        print(f"  {HERE.parent / 'build'}")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
