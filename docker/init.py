#!/usr/bin/env python3
"""Create a local .env once and render Compose runtime configuration."""

from __future__ import annotations

import base64
import os
import secrets
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EXAMPLE = HERE / ".env.example"
ENV_FILE = HERE / ".env"
RENDERER = HERE / "render_config.py"


def secret(byte_count: int = 30) -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(byte_count)).decode("ascii").rstrip("=")


def initialize_env() -> None:
    if ENV_FILE.exists():
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
    ENV_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        os.chmod(ENV_FILE, 0o600)
    except OSError:
        pass


def main() -> int:
    initialize_env()
    result = subprocess.run(
        [sys.executable, str(RENDERER), "--env-file", str(ENV_FILE)], check=False
    )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
