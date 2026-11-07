#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../services/mariadb.sh
source "${SCRIPT_DIR}/scripts/services/mariadb.sh"

manifest="$(mktemp)"
sql_log="$(mktemp)"
grant_sql_log="$(mktemp)"
trap 'rm -f "${manifest}" "${sql_log}" "${grant_sql_log}"' EXIT
printf '%s\n' 'pre-stage: core-data-migrator' >"${manifest}"

MARIADB_NAMESPACE=openbkn
MARIADB_DATABASE=openbkn
MARIADB_USER=openbkn
MARIADB_PASSWORD=test-app-password
MARIADB_ROOT_PASSWORD=test-root-password
CORE_VERSION_MANIFEST_FILE="${manifest}"
ISF_VERSION_MANIFEST_FILE=/nonexistent/isf-manifest.yaml

should_skip_db_init_for_manifest() { return 0; }
log_info() { :; }
log_warn() { :; }
log_error() { printf '%s\n' "$*" >&2; }
sleep() { :; }
kubectl() {
    if [[ "$*" == *"get pods"* ]]; then
        printf '%s' 'mariadb-0'
        return 0
    fi
    if [[ "$*" == *"mariadb-admin ping"* ]]; then
        return 0
    fi
    if [[ "$*" == *"exec -i"* ]]; then
        local sql_input
        sql_input="$(cat)"
        if [[ "${sql_input}" == *"CREATE USER IF NOT EXISTS"* ]]; then
            printf '%s\n' "${sql_input}" >"${grant_sql_log}"
        else
            printf '%s\n' "${sql_input}" >"${sql_log}"
        fi
        return 0
    fi
    return 0
}

setup_mariadb_databases

for database in openbkn safe bkn_trace; do
    if ! grep -Fq "CREATE DATABASE IF NOT EXISTS \`${database}\` CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci" "${sql_log}"; then
        echo "database fallback must create ${database} with the canonical utf8mb4 charset" >&2
        exit 1
    fi
done

for statement in \
    "CREATE USER IF NOT EXISTS 'openbkn'@'%' IDENTIFIED BY 'test-app-password'" \
    "GRANT ALL PRIVILEGES ON *.* TO 'openbkn'@'%'"; do
    if ! grep -Fq "${statement}" "${grant_sql_log}"; then
        echo "MariaDB access setup must include: ${statement}" >&2
        exit 1
    fi
done

sql_test_input="user'\\name"
expected_escaped_test="user''\\\\name"
if [[ "$(_mariadb_escape_sql_string "${sql_test_input}")" != "${expected_escaped_test}" ]]; then
    echo "MariaDB SQL string escaping must preserve quotes and backslashes" >&2
    exit 1
fi

grant_mariadb_user_permissions() { return 1; }
if setup_mariadb_databases; then
    echo "database setup must stop when MariaDB access repair fails" >&2
    exit 1
fi

setup_calls=0
helm() { return 0; }
bkn_helm_release_has_resource_limits() { return 1; }
is_rds_internal() { return 0; }
config_yaml_dep_field() {
    case "$2" in
        user) printf '%s' 'config-user' ;;
        password) printf '%s' 'config-password' ;;
        root_password) printf '%s' 'config-root-password' ;;
        database) printf '%s' 'config-database' ;;
    esac
}
setup_mariadb_databases() {
    [[ "${MARIADB_USER}" == "config-user" &&
        "${MARIADB_PASSWORD}" == "config-password" &&
        "${MARIADB_ROOT_PASSWORD}" == "config-root-password" &&
        "${MARIADB_DATABASE}" == "config-database" ]] || return 1
    setup_calls=$((setup_calls + 1))
}
install_mariadb_helm
if [[ "${setup_calls}" != "1" ]]; then
    echo "existing internal MariaDB must refresh application access" >&2
    exit 1
fi

is_rds_internal() { return 1; }
install_mariadb_helm
if [[ "${setup_calls}" != "1" ]]; then
    echo "external RDS must not be changed through the internal MariaDB Pod" >&2
    exit 1
fi

echo "mariadb_trace_database_test: passed"
