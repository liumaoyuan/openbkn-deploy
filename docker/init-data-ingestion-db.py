#!/usr/bin/env python3
"""Create the Data Ingestion control database when deployment preconfigures it.

An empty DATA_INGESTION_DATABASE_URL intentionally leaves the control database
uninitialized so an administrator can configure it from Studio on first login.
"""

from __future__ import annotations

import os
import re
import time

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url


def main() -> None:
    value = os.getenv("DATA_INGESTION_DATABASE_URL", "").strip()
    if not value:
        print(
            "DATA_INGESTION_DATABASE_URL is empty; "
            "control database initialization will be performed in Studio."
        )
        return

    url = make_url(value)
    backend = url.get_backend_name()
    if backend not in {"mysql", "mariadb", "postgresql"}:
        raise RuntimeError("数据入库控制库必须使用 MySQL/MariaDB/PostgreSQL")

    database = (url.database or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_]+", database):
        raise RuntimeError("DATA_INGESTION_DATABASE_URL 必须包含合法的数据库名")

    engine = None
    last_error: Exception | None = None
    for _ in range(30):
        try:
            server_url = (
                url.set(database="postgres")
                if backend == "postgresql"
                else url.set(database=None)
            )
            engine = create_engine(
                server_url,
                pool_pre_ping=True,
                connect_args={"connect_timeout": 10},
            )
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            break
        except Exception as error:
            last_error = error
            if engine is not None:
                engine.dispose()
                engine = None
            time.sleep(2)
    if engine is None:
        raise RuntimeError(f"外部 MySQL/MariaDB 连接失败: {last_error}")
    try:
        with engine.connect().execution_options(
            isolation_level="AUTOCOMMIT"
        ) as connection:
            if backend == "postgresql":
                exists = connection.scalar(
                    text(
                        "SELECT 1 FROM pg_database "
                        "WHERE datname = :database"
                    ),
                    {"database": database},
                )
            else:
                exists = connection.scalar(
                    text("SHOW DATABASES LIKE :database"),
                    {"database": database},
                )
            if exists is None:
                if backend == "postgresql":
                    create_sql = f'CREATE DATABASE "{database}"'
                else:
                    create_sql = (
                        f"CREATE DATABASE `{database}` "
                        "CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
                    )
                connection.execute(
                    text(create_sql)
                )
                print(f"database created: {database}")
            else:
                print(f"database exists: {database}")
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
