#!/usr/bin/env python3
"""从模板与环境变量生成 OpenBKN Compose 所需的运行时配置。"""

from __future__ import annotations

import argparse
import os
import re
import secrets
import string
import sys
from pathlib import Path
from typing import Any

import yaml

HERE = Path(__file__).resolve().parent
DEFAULT_ENV = HERE / ".env"
EXAMPLE_ENV = HERE / ".env.example"
OUTPUT = HERE.parent / "build" / "docker" / "config"
ROOT = HERE.parents[1]
FOUNDY = ROOT / "bkn-foundry"


def parse_env(path: Path | None) -> dict[str, str]:
    values = dict(os.environ)
    selected = path or (DEFAULT_ENV if DEFAULT_ENV.exists() else EXAMPLE_ENV)
    if not selected.exists():
        return values
    for line_no, line in enumerate(selected.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            raise ValueError(f"{selected}:{line_no}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values.setdefault(key, value)
    return values


def required(env: dict[str, str], key: str) -> str:
    value = env.get(key, "").strip()
    if not value or value.startswith("CHANGE_ME_"):
        raise ValueError(f"{key} is missing or still has its CHANGE_ME_ placeholder")
    return value


def random_password(length: int = 36) -> str:
    alphabet = string.ascii_letters + string.digits + "-_"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def yaml_dump(data: Any, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        yaml.safe_dump(data, allow_unicode=True, sort_keys=False, default_flow_style=False),
        encoding="utf-8",
    )


def load_template(relative: str) -> dict[str, Any]:
    path = FOUNDY / relative
    with path.open(encoding="utf-8") as stream:
        return yaml.safe_load(stream)


def render(env: dict[str, str]) -> None:
    mariadb_password = required(env, "MARIADB_PASSWORD")
    redis_password = required(env, "REDIS_PASSWORD")
    minio_user = required(env, "MINIO_ROOT_USER")
    minio_password = required(env, "MINIO_ROOT_PASSWORD")
    postgres_password = required(env, "POSTGRES_PASSWORD")
    opensearch_password = env.get("OPENSEARCH_PASSWORD", "")
    kafka_user = env.get("KAFKA_USER", "openbkn").strip()
    if not kafka_user:
        raise ValueError("KAFKA_USER must not be empty")
    kafka_password = required(env, "KAFKA_PASSWORD")
    safe_password = required(env, "BKN_SAFE_INITIAL_PASSWORD")
    oss_aes_key = required(env, "OSS_CRYPTO_AES_KEY")
    if len(oss_aes_key.encode("utf-8")) != 32:
        raise ValueError("OSS_CRYPTO_AES_KEY must be exactly 32 UTF-8 bytes")
    public_url = env.get("OPENBKN_PUBLIC_BASE_URL", "http://localhost:8080").rstrip("/")
    if not re.fullmatch(r"https?://[^/\s]+(?::\d+)?", public_url):
        raise ValueError("OPENBKN_PUBLIC_BASE_URL must be an HTTP(S) origin without a path")
    trace_token = env.get("BKN_TRACE_EVIDENCE_INGEST_TOKEN", "")
    if not trace_token or trace_token.startswith("CHANGE_ME_"):
        trace_token = random_password()
    artifact_token = env.get("BKN_TRACE_ARTIFACT_INGEST_TOKEN", "")
    if not artifact_token or artifact_token.startswith("CHANGE_ME_"):
        artifact_token = random_password()
    provenance_token = env.get("BKN_PROVENANCE_BOOTSTRAP_TOKEN", "")
    if not provenance_token or provenance_token.startswith("CHANGE_ME_"):
        provenance_token = random_password()
    env["BKN_TRACE_EVIDENCE_INGEST_TOKEN"] = trace_token
    env["BKN_TRACE_ARTIFACT_INGEST_TOKEN"] = artifact_token
    env["BKN_PROVENANCE_BOOTSTRAP_TOKEN"] = provenance_token

    # Core Go services: preserve upstream config shape and override only deployment endpoints.
    back = load_template("adp/bkn/bkn-backend/server/config/bkn-backend-config.yaml")
    back["depServices"]["rds"].update(host="mariadb", port=3306, user="openbkn",
                                      password=mariadb_password, type="MariaDB")
    back["depServices"]["mq"].update(
        mqHost="kafka", mqPort=9092, protocol="sasl_plaintext"
    )
    back["depServices"]["mq"]["auth"] = {
        "username": kafka_user, "password": kafka_password, "mechanism": "PLAIN"
    }
    back["depServices"]["opensearch"].update(host="opensearch", port=9200, protocol="http",
                                               user="admin", password=opensearch_password)
    for key, host, port in (
        ("hydra-admin", "bkn-safe-hydra-admin", 4445),
        ("mf-model-manager", "mf-model-manager", 9898),
        ("mf-model-api", "mf-model-api", 9898),
        ("ontology-query", "ontology-query-svc", 13018),
        ("vega-backend", "vega-backend-svc", 13014),
        ("agent-operator-integration", "agent-operator-integration", 9000),
    ):
        back["depServices"][key].update(host=host, port=port, protocol="http")
    yaml_dump(back, OUTPUT / "bkn-backend" / "bkn-backend-config.yaml")

    query = load_template("adp/bkn/ontology-query/server/config/ontology-query-config.yaml")
    query["depServices"]["rds"].update(host="mariadb", port=3306, user="openbkn",
                                       password=mariadb_password, type="MariaDB")
    query["depServices"]["opensearch"].update(host="opensearch", port=9200, protocol="http",
                                                user="admin", password=opensearch_password)
    for key, host, port in (
        ("authorization-private", "bkn-safe", 3000),
        ("user-management", "bkn-safe", 3000),
        ("hydra-public", "bkn-safe-hydra-public", 4444),
        ("hydra-admin", "bkn-safe-hydra-admin", 4445),
        ("model-factory", "mf-model-api", 9898),
        ("bkn-backend", "bkn-backend-svc", 13014),
        ("agent-operator-integration", "agent-operator-integration", 9000),
        ("mf-model-manager", "mf-model-manager", 9898),
        ("mf-model-api", "mf-model-api", 9898),
        ("vega-backend", "vega-backend-svc", 13014),
    ):
        query["depServices"][key].update(host=host, port=port, protocol="http")
    yaml_dump(query, OUTPUT / "ontology-query" / "ontology-query-config.yaml")

    vega = load_template("vega/vega-backend/server/config/vega-backend-config.yaml")
    vega["depServices"]["rds"].update(host="mariadb", port=3306, user="openbkn",
                                      password=mariadb_password, type="MariaDB")
    vega["depServices"]["mq"].update(
        mqHost="kafka", mqPort=9092, protocol="sasl_plaintext"
    )
    vega["depServices"]["mq"]["auth"] = {
        "username": kafka_user, "password": kafka_password, "mechanism": "PLAIN"
    }
    vega["depServices"]["opensearch"].update(host="opensearch", port=9200, protocol="http",
                                               user="admin", password=opensearch_password)
    for key, host, port in (
        ("hydra-admin", "bkn-safe-hydra-admin", 4445),
        ("kafka-connect", "kafka-connect", 8083),
        ("mf-model-manager", "mf-model-manager", 9898),
        ("mf-model-api", "mf-model-api", 9898),
        ("bkn-agent", "bkn-agent", 30800),
    ):
        vega["depServices"][key].update(host=host, port=port, protocol="http")
    yaml_dump(vega, OUTPUT / "vega-backend" / "vega-backend-config.yaml")

    retrieval = load_template(
        "adp/context-loader/agent-retrieval/server/infra/config/agent-retrieval.yaml"
    )
    retrieval["project"].update(host="0.0.0.0", port=30779, sandbox_port=30780,
                                name="agent-retrieval", pod_id="docker-compose")
    retrieval["oauth"].update(public_host="bkn-safe-hydra-public", admin_host="bkn-safe-hydra-admin")
    retrieval["bkn_backend"].update(private_host="bkn-backend-svc")
    retrieval["ontology_query"].update(private_host="ontology-query-svc")
    retrieval["vega"].update(private_host="vega-backend-svc")
    retrieval["operator_integration"].update(private_host="agent-operator-integration")
    retrieval["bkn_safe"].update(private_host="bkn-safe")
    retrieval["mf_model_api"].update(private_host="mf-model-api")
    retrieval["redis"].update(connectType="standalone", enableSSL=False, poolSize=10)
    yaml_dump(retrieval, OUTPUT / "agent-retrieval" / "agent-retrieval.yaml")
    retrieval_secret = {
        "redis": {
            "connectInfo": {
                "username": "", "password": redis_password, "host": "redis", "port": 6379,
                "masterHost": "", "masterPort": 0, "slaveHost": "", "slavePort": 0,
                "sentinelHost": "", "sentinelPort": 0, "sentinelUsername": "",
                "sentinelPassword": "", "masterGroupName": "",
            }
        }
    }
    yaml_dump(retrieval_secret, OUTPUT / "agent-retrieval" / "agent-retrieval-secret.yaml")
    retrieval_obs = load_template(
        "adp/context-loader/agent-retrieval/server/infra/config/observability.yaml"
    )
    retrieval_obs["otlp_endpoint"] = "http://agent-observability:8080"
    retrieval_obs["trace"]["enabled"] = False
    retrieval_obs["log"]["enabled"] = False
    yaml_dump(retrieval_obs, OUTPUT / "agent-retrieval" / "observability.yaml")

    operator = load_template(
        "adp/execution-factory/operator-integration/server/infra/config/agent-operator-integration.yaml"
    )
    operator["project"].update(host="0.0.0.0", port=9000, name="agent-operator-integration",
                               pod_id="docker-compose")
    operator["oauth"].update(public_host="bkn-safe-hydra-public", admin_host="bkn-safe-hydra-admin")
    operator["agent-operator-app"].update(private_host="agent-operator-integration")
    operator["mf-model-api"].update(private_host="mf-model-api")
    operator["mf-model-manager"].update(private_host="mf-model-manager")
    operator["sandbox-control-plane"].update(private_host="sandbox-control-plane")
    operator["vega-backend"].update(private_host="vega-backend-svc")
    operator["redis"].update(connectType="standalone", enableSSL=False, poolSize=10)
    operator["oss-gateway-backend"].update(private_host="oss-gateway-backend")
    operator["oss-gateway-backend"]["storage_id"] = ""
    yaml_dump(operator, OUTPUT / "agent-operator-integration" / "agent-operator-integration.yaml")
    operator_secret = {
        "db": {"host": "mariadb", "port": 3306, "user_name": "openbkn",
               "password": mariadb_password, "db_name": "openbkn", "charset": "utf8mb4"},
        "redis": retrieval_secret["redis"],
    }
    yaml_dump(operator_secret, OUTPUT / "agent-operator-integration" /
              "agent-operator-integration-secret.yaml")
    operator_mq = load_template(
        "adp/execution-factory/operator-integration/server/infra/config/mq_config.yaml"
    )
    operator_mq.update(mqHost="kafka", mqPort=9092, connectorType="kafka", mqType="kafka")
    operator_mq["auth"] = {
        "mechanism": "PLAIN", "password": kafka_password, "username": kafka_user
    }
    yaml_dump(operator_mq, OUTPUT / "agent-operator-integration" / "mq_config.yaml")
    operator_obs = load_template(
        "adp/execution-factory/operator-integration/server/infra/config/observability.yaml"
    )
    operator_obs["otlp_endpoint"] = "http://agent-observability:8080"
    operator_obs["trace"]["enabled"] = False
    operator_obs["log"]["enabled"] = False
    yaml_dump(operator_obs, OUTPUT / "agent-operator-integration" / "observability.yaml")

    # Hydra is a separate PostgreSQL application with stable signing material.
    safe = load_template("bkn-safe/server/config/config.local.yaml.example")
    yaml_dump(safe, OUTPUT / "bkn-safe" / "config.yaml")

    dm_secret = {
        "depServices": {
            "rds": {
                "source_type": "internal", "type": "mariadb", "host": "mariadb",
                "port": 3306, "user": "openbkn", "password": mariadb_password,
                "hostRead": "mariadb", "portRead": 3306,
            }
        }
    }
    yaml_dump(dm_secret, OUTPUT / "data-migrator-secret.yaml")

    # Legacy Python model services receive DB/broker/OpenSearch values through env.
    dm_svc = "TIME_ZON=(480)\nLANGUAGE=(cn)\nDM=(mariadb)\n[DM]\nLOGIN_MODE=(1)\n"
    (OUTPUT / "dm-svc-conf").mkdir(parents=True, exist_ok=True)
    (OUTPUT / "dm-svc-conf" / "rds_conf.yaml").write_text(dm_svc, encoding="utf-8")
    # 本栈带 bkn-safe + hydra，Studio 必须自己跑 OAuth 登录门禁。
    # "hosted" 模式假设上游已经完成鉴权；这里没有，会导致 401 后反复刷新。
    (OUTPUT / "studio-config.js").write_text(
        'window.__BKN_STUDIO_RUNTIME__ = { mode: "standalone" };\n',
        encoding="utf-8",
    )
    (OUTPUT / "rendered.env").write_text(
        "\n".join(
            f"{key}={value}"
            for key, value in sorted(env.items())
            if key.startswith(("BKN_TRACE_", "BKN_PROVENANCE_"))
        ) + "\n",
        encoding="utf-8",
    )
    print(f"Generated deployment config at {OUTPUT}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, help="读取额外的 KEY=VALUE 文件，默认 .env 或 .env.example")
    args = parser.parse_args()
    try:
        env = parse_env(args.env_file)
        render(env)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        print(f"配置生成失败：{exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
