
is_bitnami_mariadb_image() {
    local image="$1"
    [[ "${image}" == *"/bitnami/mariadb:"* || "${image}" == "bitnami/mariadb:"* ]]
}

# Update RDS type to internal in config.yaml after MariaDB installation
update_rds_type_to_internal() {
    local config_file="${CONFIG_YAML_PATH}"
    
    if [[ ! -f "${config_file}" ]]; then
        log_warn "Config file not found: ${config_file}"
        return 1
    fi
    
    log_info "Updating RDS type to 'internal' in config.yaml..."
    
    # Update rds section's source_type from external to internal
    # Use a more flexible sed pattern that doesn't require end-of-line anchor
    # -i.bak (then rm) keeps this portable: BSD sed on macOS requires a suffix arg to -i.
    sed -i.bak '/^  rds:/,/^  [a-z]/s/source_type: external/source_type: internal/' "${config_file}" && rm -f "${config_file}.bak"
    
    # Verify the change
    if grep -A 10 "^  rds:" "${config_file}" | grep -q "source_type: internal"; then
        log_info "✓ RDS type successfully updated to 'internal'"
        return 0
    else
        log_warn "⚠ Failed to update RDS type to 'internal', trying alternative method..."
        # Fallback: use a simpler global replacement
        sed -i.bak 's/source_type: external/source_type: internal/g' "${config_file}" && rm -f "${config_file}.bak"
        if grep -q "source_type: internal" "${config_file}"; then
            log_info "✓ RDS type successfully updated to 'internal' (using fallback)"
            return 0
        else
            log_error "✗ Failed to update RDS type to 'internal'"
            return 1
        fi
    fi
}

# When values file used loopback RDS hosts (e.g. mac/kind samples), point depServices.rds at
# the in-cluster MariaDB Service so Helm hooks and pods resolve MySQL correctly.
sync_config_rds_for_in_cluster_mariadb() {
    local config_file="${CONFIG_YAML_PATH:-}"
    local ns="${MARIADB_NAMESPACE:-resource}"
    local svc_host="mariadb.${ns}.svc.cluster.local"

    [[ -f "${config_file}" ]] || return 0
    if ! grep -A40 '^  rds:' "${config_file}" | grep -E '^[[:space:]]*host(Read)?:' | grep -qE "127\.0\.0\.1|'127\.0\.0\.1'|localhost|'localhost'"; then
        return 0
    fi

    log_info "Updating ${config_file}: depServices.rds -> internal + ${svc_host} (replacing loopback placeholders)"
    update_rds_type_to_internal || true

    local tmp
    tmp="$(mktemp)"
    awk -v h="${svc_host}" '
        /^  rds:/ { inr=1 }
        inr && /^  [a-z]/ && $0 !~ /^  rds:/ { inr=0 }
        inr && /^    host:/ { print "    host: '\''" h "'\''"; next }
        inr && /^    hostRead:/ { print "    hostRead: '\''" h "'\''"; next }
        { print }
    ' "${config_file}" > "${tmp}"
    mv "${tmp}" "${config_file}"
}

_mariadb_resolve_image_defaults() {
    local image_registry
    image_registry="$(resolve_openbkn_image_registry "${MARIADB_IMAGE_REGISTRY:-}")"
    MARIADB_IMAGE_REGISTRY="${image_registry}"
    if [[ -z "${MARIADB_IMAGE}" ]]; then
        MARIADB_IMAGE="$(compose_image_ref "${image_registry}" "${MARIADB_IMAGE_REPOSITORY:-mariadb}" "${MARIADB_IMAGE_TAG}")"
    fi
}

_mariadb_escape_sql_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\'\'}"
    printf '%s' "${value}"
}

# JSON Patch "add" replaces an existing array and creates a missing one, so the
# same call covers StatefulSets that never had an args field.
_mariadb_restore_statefulset_args() {
    local ns="$1" sts="$2" args_json="$3"
    kubectl -n "${ns}" patch statefulset "${sts}" --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":${args_json}}]" >/dev/null 2>&1
}

# `mariadb-admin ping` returns 0 whenever mysqld answers, even when the
# credentials are rejected ("Access denied" still counts as alive). Using it as
# a readiness probe hides an out-of-sync root password until the grant step
# fails with a bare ERROR 1045. Probe with a real query instead.
_mariadb_auth_probe() {
    local ns="$1" pod="$2"
    kubectl -n "${ns}" exec "${pod}" -- \
        mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" --connect-timeout=5 \
        -e 'SELECT 1' &>/dev/null
}

_mariadb_server_alive() {
    local ns="$1" pod="$2"
    kubectl -n "${ns}" exec "${pod}" -- mariadb-admin ping -h 127.0.0.1 &>/dev/null
}

_mariadb_root_password_from_secret() {
    local ns="$1" encoded
    encoded="$(kubectl -n "${ns}" get secret mariadb-auth -o jsonpath='{.data.mariadb-root-password}' 2>/dev/null)" || return 1
    [[ -n "${encoded}" ]] || return 1
    printf '%s' "${encoded}" | base64 -d 2>/dev/null
}

# A reused PVC keeps the root password it was initialized with; config.yaml and
# the mariaadb-auth Secret may since have been regenerated. Say that plainly
# instead of surfacing only "Failed to grant privileges".
_mariadb_explain_auth_failure() {
    local ns="$1"
    local secret_root=""

    secret_root="$(_mariadb_root_password_from_secret "${ns}" || true)"

    log_error "MariaDB is running but rejected root authentication (ERROR 1045)."
    log_error "The data directory was initialized with a different root password than the one in use now."
    log_error "  Config file : ${CONFIG_YAML_PATH:-<unset>}"
    log_error "  Config value: ${MARIADB_ROOT_PASSWORD:+<set, hidden>}${MARIADB_ROOT_PASSWORD:-<empty>}"
    if [[ -n "${secret_root}" ]]; then
        if [[ "${secret_root}" == "${MARIADB_ROOT_PASSWORD}" ]]; then
            log_error "  Secret value: <set, hidden> — same as config, so the PVC is the odd one out"
        else
            log_error "  Secret value: <set, hidden> — differs from config.yaml"
        fi
    else
        log_error "  Secret value: <mariadb-auth/mariadb-root-password not readable>"
    fi
    log_error ""
    log_error "Fix it in one of two ways:"
    log_error "  1) Reset the password to the configured value, keeping existing data:"
    log_error "     bash deploy.sh mariadb repair-password"
    log_error "  2) Reinitialize with empty data (only if no application data exists yet):"
    log_error "     bash deploy.sh mariadb uninstall --force --delete-data"
    log_error "     bash deploy.sh mariadb install"
}

# Grant permissions to MariaDB user (always run for internal MariaDB)
grant_mariadb_user_permissions() {
    local ns="${MARIADB_NAMESPACE}"

    if [[ -z "${MARIADB_USER}" || -z "${MARIADB_PASSWORD}" ]]; then
        log_error "MariaDB application username or password is missing; cannot ensure remote access"
        return 1
    fi

    log_info "Granting permissions to MariaDB user '${MARIADB_USER}'..."

    # Find the correct pod name
    local pod_name
    pod_name=$(kubectl -n "${ns}" get pods -l app=mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${pod_name}" ]]; then
        log_warn "MariaDB Pod not found, skipping permission grant"
        return 1
    fi

    # Wait for MariaDB to be fully ready
    log_info "Waiting for MariaDB to be ready (Pod: ${pod_name})..."
    local max_attempts=15
    local attempt=0
    local ready="false"
    while [[ $attempt -lt $max_attempts ]]; do
        if _mariadb_auth_probe "${ns}" "${pod_name}"; then
            ready="true"
            break
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    if [[ "${ready}" != "true" ]]; then
        if _mariadb_server_alive "${ns}" "${pod_name}"; then
            _mariadb_explain_auth_failure "${ns}"
        else
            log_error "MariaDB Pod '${pod_name}' did not become ready; cannot grant application access"
        fi
        return 1
    fi

    local escaped_user escaped_password
    escaped_user="$(_mariadb_escape_sql_string "${MARIADB_USER}")"
    escaped_password="$(_mariadb_escape_sql_string "${MARIADB_PASSWORD}")"

    # Existing persistent volumes may lack the remote account; create it before granting.
    local sql_commands="CREATE USER IF NOT EXISTS '${escaped_user}'@'%' IDENTIFIED BY '${escaped_password}';"
    sql_commands+=" ALTER USER '${escaped_user}'@'%' IDENTIFIED BY '${escaped_password}';"
    sql_commands+=" GRANT ALL PRIVILEGES ON *.* TO '${escaped_user}'@'%';"
    sql_commands+=" FLUSH PRIVILEGES;"

    if echo "${sql_commands}" | kubectl -n "${ns}" exec -i "${pod_name}" -- mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" 2>&1; then
        log_info "✓ Ensured MariaDB access for '${MARIADB_USER}'@'%'"
    else
        log_error "✗ Failed to grant privileges to '${MARIADB_USER}'@'%'"
        _mariadb_explain_auth_failure "${ns}" || true
        return 1
    fi
}

# Reused PVCs keep the root password they were first initialized with, so a
# regenerated Secret/config.yaml locks the installer out. Restart MariaDB with
# --skip-grant-tables once and write the configured passwords back.
repair_mariadb_root_password() {
    local ns="${MARIADB_NAMESPACE}"
    local sts="mariadb"
    local configured_root configured_user configured_password
    local original_args

    configured_root="$(config_yaml_dep_field rds root_password)"
    configured_user="$(config_yaml_dep_field rds user)"
    configured_password="$(config_yaml_dep_field rds password)"

    if [[ -z "${configured_root}" ]]; then
        log_error "MariaDB root_password is missing from ${CONFIG_YAML_PATH:-config.yaml}; nothing to reset it to."
        return 1
    fi
    configured_user="${configured_user:-${MARIADB_USER:-openbkn}}"
    configured_password="${configured_password:-${MARIADB_PASSWORD}}"
    if [[ -z "${configured_password}" ]]; then
        log_error "MariaDB password is missing from ${CONFIG_YAML_PATH:-config.yaml}; regenerate the config first."
        return 1
    fi

    if ! kubectl -n "${ns}" get statefulset "${sts}" >/dev/null 2>&1; then
        log_error "StatefulSet ${sts} not found in namespace ${ns}."
        return 1
    fi

    # `-o jsonpath='{.spec...args}'` prints Go's slice form ("[a b]") which is not
    # valid JSON. Read element by element and rebuild the array ourselves.
    local -a orig_args=()
    local arg_line
    while IFS= read -r arg_line; do
        [[ -n "${arg_line}" ]] && orig_args+=("${arg_line}")
    done < <(kubectl -n "${ns}" get statefulset "${sts}" \
        -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null)

    original_args="[]"
    if [[ ${#orig_args[@]} -gt 0 ]]; then
        local joined="" arg
        for arg in "${orig_args[@]}"; do
            arg="${arg//\\/\\\\}"
            arg="${arg//\"/\\\"}"
            joined+="\"${arg}\","
        done
        original_args="[${joined%,}]"
    fi

    log_info "Restarting MariaDB with --skip-grant-tables to reset credentials..."
    if ! kubectl -n "${ns}" patch statefulset "${sts}" --type=json \
        -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--skip-grant-tables"}]' >/dev/null; then
        log_error "Failed to patch StatefulSet ${sts}; no changes were made."
        return 1
    fi

    kubectl -n "${ns}" rollout status statefulset/"${sts}" --timeout=300s || {
        log_error "MariaDB did not restart with --skip-grant-tables."
        _mariadb_restore_statefulset_args "${ns}" "${sts}" "${original_args}"
        return 1
    }

    local pod_name
    pod_name=$(kubectl -n "${ns}" get pods -l app=mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -z "${pod_name}" ]]; then
        log_error "MariaDB Pod not found after restart."
        _mariadb_restore_statefulset_args "${ns}" "${sts}" "${original_args}"
        return 1
    fi

    local escaped_user escaped_password
    escaped_user="$(_mariadb_escape_sql_string "${configured_user}")"
    escaped_password="$(_mariadb_escape_sql_string "${configured_password}")"
    local escaped_root
    escaped_root="$(_mariadb_escape_sql_string "${configured_root}")"

    # In --skip-grant-tables mode GRANT/ALTER USER only work after FLUSH PRIVILEGES.
    local sql_commands="FLUSH PRIVILEGES;"
    sql_commands+=" ALTER USER 'root'@'localhost' IDENTIFIED BY '${escaped_root}';"
    sql_commands+=" CREATE USER IF NOT EXISTS '${escaped_user}'@'%' IDENTIFIED BY '${escaped_password}';"
    sql_commands+=" ALTER USER '${escaped_user}'@'%' IDENTIFIED BY '${escaped_password}';"
    sql_commands+=" GRANT ALL PRIVILEGES ON *.* TO '${escaped_user}'@'%';"
    sql_commands+=" FLUSH PRIVILEGES;"

    if ! echo "${sql_commands}" | kubectl -n "${ns}" exec -i "${pod_name}" -- mariadb -u root 2>&1; then
        log_error "Failed to rewrite MariaDB credentials."
        _mariadb_restore_statefulset_args "${ns}" "${sts}" "${original_args}"
        return 1
    fi
    log_info "✓ Credentials rewritten for 'root'@'localhost' and '${configured_user}'@'%'"

    # Restore normal startup args before verifying, so the check uses the real config.
    if ! _mariadb_restore_statefulset_args "${ns}" "${sts}" "${original_args}"; then
        log_error "Failed to restore original StatefulSet args; run: kubectl -n ${ns} rollout restart statefulset/${sts}"
        return 1
    fi

    kubectl -n "${ns}" rollout status statefulset/"${sts}" --timeout=300s || {
        log_error "MariaDB did not restart with the original args."
        return 1
    }

    MARIADB_ROOT_PASSWORD="${configured_root}"
    pod_name=$(kubectl -n "${ns}" get pods -l app=mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    local attempt
    for attempt in $(seq 1 30); do
        if _mariadb_auth_probe "${ns}" "${pod_name}"; then
            log_info "✓ Root authentication now matches ${CONFIG_YAML_PATH:-config.yaml}"
            return 0
        fi
        sleep 2
    done

    log_error "Credentials were rewritten but root authentication still fails; check the MariaDB logs:"
    log_error "  kubectl -n ${ns} logs ${pod_name} --tail=50"
    return 1
}

# Create additional databases and grant permissions to adp user
setup_mariadb_databases() {
    local ns="${MARIADB_NAMESPACE}"
    local mariadb_host="mariadb.${ns}.svc.cluster.local"
    local mariadb_port="3306"

    # Always grant user permissions first
    grant_mariadb_user_permissions || return 1

    # The data-migrator also creates these databases in current bundles. Keep
    # this idempotent fallback because MariaDB may be installed independently or
    # upgraded before the migrator hook runs.
    local isf_manifest core_manifest
    isf_manifest="${ISF_VERSION_MANIFEST_FILE:-$(resolve_embedded_release_manifest "isf" "${HELM_CHART_VERSION:-}")}"
    core_manifest="${CORE_VERSION_MANIFEST_FILE:-$(resolve_embedded_release_manifest "bkn-foundry" "${HELM_CHART_VERSION:-}")}"

    if [[ -f "${isf_manifest}" ]] && should_skip_db_init_for_manifest "${isf_manifest}"; then
        log_info "ISF manifest ${isf_manifest} has pre-stage data-migrator; retaining idempotent database setup"
    fi

    if [[ -f "${core_manifest}" ]] && should_skip_db_init_for_manifest "${core_manifest}"; then
        log_info "Core manifest ${core_manifest} has pre-stage data-migrator; retaining idempotent database setup"
    fi

    log_info "Setting up additional databases and permissions..."

    # Find the correct pod name (could be mariadb-0 or mariadb-0 depending on chart)
    local pod_name
    pod_name=$(kubectl -n "${ns}" get pods -l app=mariadb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${pod_name}" ]]; then
        log_warn "MariaDB Pod not found, skipping database setup"
        return 1
    fi

    # Wait for MariaDB to be fully ready
    log_info "Waiting for MariaDB to be ready (Pod: ${pod_name})..."
    local max_attempts=15
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if kubectl -n "${ns}" exec "${pod_name}" -- mariadb-admin ping -h localhost -u root -p"${MARIADB_ROOT_PASSWORD}" &>/dev/null; then
            break
        fi
        ((attempt++))
        sleep 2
    done

    # List of databases to create
    local databases=(
        "safe"
        "bkn_trace"
    )

    # Execute SQL commands to create databases
    log_info "Creating databases..."
    local sql_commands="CREATE DATABASE IF NOT EXISTS \`${MARIADB_DATABASE}\` CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
    for db in "${databases[@]}"; do
        sql_commands+=" CREATE DATABASE IF NOT EXISTS \`${db}\` CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;"
    done

    if echo "${sql_commands}" | kubectl -n "${ns}" exec -i "${pod_name}" -- mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" 2>&1; then
        log_info "✓ Successfully created databases"
    else
        log_warn "⚠ Some databases may already exist or failed to create"
    fi

    log_info "MariaDB database setup completed"
}

# Install single-node MariaDB 11 using mariadb Helm chart
install_mariadb_helm() {
    log_info "Installing MariaDB (single-node) via mariadb Helm chart..."

    local ns="${MARIADB_NAMESPACE}"
    local fresh_install="true"
    local reuse_existing_values="false"

    # Check if MariaDB is already installed
    if helm status mariadb -n "${ns}" >/dev/null 2>&1; then
        local limit_status
        if bkn_helm_release_has_resource_limits mariadb "${ns}"; then
            log_info "MariaDB has resource limits. Reconciling chart values to remove them."
        else
            limit_status=$?
            if [[ "${limit_status}" == "1" ]]; then
                log_info "MariaDB is already installed without resource limits. Skipping upgrade."
                if is_rds_internal; then
                    local configured_user configured_password configured_root_password configured_database
                    configured_user="$(config_yaml_dep_field rds user)"
                    configured_password="$(config_yaml_dep_field rds password)"
                    configured_root_password="$(config_yaml_dep_field rds root_password)"
                    configured_database="$(config_yaml_dep_field rds database)"
                    [[ -n "${configured_user}" ]] && MARIADB_USER="${configured_user}"
                    [[ -n "${configured_password}" ]] && MARIADB_PASSWORD="${configured_password}"
                    [[ -n "${configured_root_password}" ]] && MARIADB_ROOT_PASSWORD="${configured_root_password}"
                    [[ -n "${configured_database}" ]] && MARIADB_DATABASE="${configured_database}"

                    if [[ -z "${MARIADB_ROOT_PASSWORD}" ]]; then
                        log_error "MariaDB root_password is missing from ${CONFIG_YAML_PATH}; cannot verify or repair access"
                        return 1
                    fi
                    setup_mariadb_databases || return 1
                fi
                return 0
            fi
            log_error "Could not inspect MariaDB Helm manifest for resource limits; skipping upgrade."
            return 1
        fi
        fresh_install="false"
        reuse_existing_values="true"
    fi

    # MariaDB password handling
    local existing_pass=$(config_yaml_dep_field rds password)
    if [[ -n "${existing_pass}" ]]; then
        MARIADB_PASSWORD="${existing_pass}"
        log_info "Using existing MariaDB password from config.yaml"
    elif [[ "${reuse_existing_values}" == "true" ]]; then
        log_error "MariaDB password is missing from config.yaml; refusing to upgrade an existing release."
        return 1
    else
        MARIADB_PASSWORD=$(generate_random_password 10)
        log_info "Generated random 10-character MariaDB password"
    fi

    local existing_root_pass=$(config_yaml_dep_field rds root_password)
    if [[ -n "${existing_root_pass}" ]]; then
        MARIADB_ROOT_PASSWORD="${existing_root_pass}"
        log_info "Using existing MariaDB root password from config.yaml"
    elif [[ "${reuse_existing_values}" == "true" ]]; then
        log_error "MariaDB root password is missing from config.yaml; refusing to upgrade an existing release."
        return 1
    else
        MARIADB_ROOT_PASSWORD=$(generate_random_password 10)
        log_info "Generated random 10-character MariaDB root password"
    fi

    if [[ "${reuse_existing_values}" == "true" ]]; then
        local existing_user existing_db
        existing_user=$(config_yaml_dep_field rds user)
        existing_db=$(config_yaml_dep_field rds database)
        [[ -n "${existing_user}" ]] && MARIADB_USER="${existing_user}"
        [[ -n "${existing_db}" ]] && MARIADB_DATABASE="${existing_db}"
    fi

    _mariadb_resolve_image_defaults
    # Parse image registry/repository/tag from MARIADB_IMAGE
    local image_without_tag="${MARIADB_IMAGE%:*}"
    local image_tag="${MARIADB_IMAGE##*:}"
    local chart_ref="mariadb"
    local use_local_chart="false"
    if [[ -f "${MARIADB_CHART_TGZ}" ]]; then
        chart_ref="${MARIADB_CHART_TGZ}"
        use_local_chart="true"
        log_info "Using local MariaDB chart: ${chart_ref}"
    else
        log_info "Using remote MariaDB chart: ${chart_ref} (version ${MARIADB_CHART_VERSION})"
    fi

    kubectl create namespace "${ns}" 2>/dev/null || true

    local persistence_enabled="${MARIADB_PERSISTENCE_ENABLED}"
    if [[ "${persistence_enabled}" == "true" ]]; then
        if [[ -z "$(kubectl get storageclass --no-headers 2>/dev/null)" ]]; then
            log_warn "No StorageClass found. MariaDB PVC will stay Pending."
            if [[ "${AUTO_INSTALL_LOCALPV}" == "true" ]]; then
                install_localpv
            fi
            if [[ -z "$(kubectl get storageclass --no-headers 2>/dev/null)" ]]; then
                log_warn "Still no StorageClass found. Disabling MariaDB persistence to avoid Pending PVC."
                persistence_enabled="false"
            fi
        fi
    fi

    local -a helm_args
    helm_args=(
        upgrade --install mariadb "${chart_ref}"
        --namespace "${ns}"
        --set image.repository="${image_without_tag}"
        --set image.tag="${image_tag}"
        --set mariadb.auth.rootPassword="${MARIADB_ROOT_PASSWORD}"
        --set mariadb.auth.database="${MARIADB_DATABASE}"
        --set mariadb.auth.username="${MARIADB_USER}"
        --set mariadb.auth.password="${MARIADB_PASSWORD}"
        --set mariadb.config.maxConnections="${MARIADB_MAX_CONNECTIONS}"
        --set mariadb.persistence.enabled="${persistence_enabled}"
    )

    if [[ "${persistence_enabled}" == "true" ]]; then
        helm_args+=(--set mariadb.persistence.size="${MARIADB_STORAGE_SIZE}")
        if [[ -n "${MARIADB_STORAGE_CLASS}" ]]; then
            helm_args+=(--set mariadb.persistence.storageClassName="${MARIADB_STORAGE_CLASS}")
        fi
    fi

    # Requests remain configurable, but limits must stay unset.  Passing JSON
    # null is important on upgrades: Helm otherwise retains a limit from the
    # previous release values.
    if [[ -n "${MARIADB_MEMORY_REQUEST}" ]]; then
        helm_args+=(--set resources.requests.memory="${MARIADB_MEMORY_REQUEST}")
    fi
    if [[ -n "${MARIADB_CPU_REQUEST}" ]]; then
        helm_args+=(--set resources.requests.cpu="${MARIADB_CPU_REQUEST}")
    fi
    helm_args+=(--set-json "resources.limits=null")

    helm_args+=(--wait --timeout=600s)

    log_info "Installing MariaDB with values:"
    log_info "  Chart: ${chart_ref}"
    log_info "  Namespace: ${ns}"
    log_info "  Image: ${image_without_tag}:${image_tag}"
    log_info "  Max Connections: ${MARIADB_MAX_CONNECTIONS}"
    log_info "  Storage: ${persistence_enabled}"

    if [[ "${reuse_existing_values}" == "true" ]]; then
        bkn_helm_upgrade_without_resource_limits mariadb "${ns}" "${helm_args[@]}" || return 1
    else
        helm "${helm_args[@]}" || return 1
    fi

    # Wait for MariaDB Pod to be ready
    log_info "Waiting for MariaDB Pod to be ready..."
    kubectl wait --for=condition=ready pod -l "app.kubernetes.io/instance=mariadb" -n "${ns}" --timeout=300s 2>/dev/null || {
        log_warn "MariaDB Pod may not be ready yet"
    }

    log_info "MariaDB installed successfully"
    log_info "MariaDB connection info:"
    log_info "  Host: mariadb.${ns}.svc.cluster.local"
    log_info "  Port: 3306"
    log_info "  Root Password: ${MARIADB_ROOT_PASSWORD}"
    log_info "  Database: ${MARIADB_DATABASE}"
    log_info "  Username: ${MARIADB_USER}"
    log_info "  Password: ${MARIADB_PASSWORD}"

    # Create additional databases and grant permissions
    setup_mariadb_databases || return 1

    sync_config_rds_for_in_cluster_mariadb

    if [[ "${fresh_install}" == "true" && "${AUTO_GENERATE_CONFIG}" == "true" ]]; then
        log_info "Updating conf/config.yaml after MariaDB fresh install..."
        generate_config_yaml
        # Update RDS type to internal since MariaDB is installed internally
        update_rds_type_to_internal
    fi
}

# Install single-node MariaDB 11 via manifest (official mariadb image)
install_mariadb_official() {
    log_info "Installing MariaDB (single-node) via manifest..."

    local ns="${MARIADB_NAMESPACE}"

    # MariaDB password handling
    local existing_pass=$(config_yaml_dep_field rds password)
    if [[ -n "${existing_pass}" ]]; then
        MARIADB_PASSWORD="${existing_pass}"
        log_info "Using existing MariaDB password from config.yaml"
    else
        MARIADB_PASSWORD=$(generate_random_password 10)
        log_info "Generated random 10-character MariaDB password"
    fi

    local existing_root_pass=$(config_yaml_dep_field rds root_password)
    if [[ -n "${existing_root_pass}" ]]; then
        MARIADB_ROOT_PASSWORD="${existing_root_pass}"
        log_info "Using existing MariaDB root password from config.yaml"
    else
        MARIADB_ROOT_PASSWORD=$(generate_random_password 10)
        log_info "Generated random 10-character MariaDB root password"
    fi

    if kubectl -n "${ns}" get statefulset mariadb >/dev/null 2>&1; then
        log_info "MariaDB is already installed (StatefulSet exists). Skipping installation."
        # Even if MariaDB is already installed, regenerate config.yaml if password is missing
        local existing_pass
        existing_pass=$(grep -A 20 "^  rds:" "${CONFIG_YAML_PATH}" 2>/dev/null | grep "password:" | head -1 | awk '{print $2}' | tr -d "'\"")
        if [[ -z "${existing_pass}" ]] && [[ "${AUTO_GENERATE_CONFIG}" == "true" ]]; then
            log_info "MariaDB password is missing in config.yaml, regenerating..."
            generate_config_yaml
            update_rds_type_to_internal
        fi
        return 0
    fi

    _mariadb_resolve_image_defaults

    # Create namespace if not exists
    kubectl create namespace "${ns}" 2>/dev/null || true

    local persistence_enabled="${MARIADB_PERSISTENCE_ENABLED}"
    if [[ "${persistence_enabled}" == "true" ]]; then
        if [[ -z "$(kubectl get storageclass --no-headers 2>/dev/null)" ]]; then
            log_warn "No StorageClass found. MariaDB PVC will stay Pending."
            if [[ "${AUTO_INSTALL_LOCALPV}" == "true" ]]; then
                install_localpv
            fi

            if [[ -z "$(kubectl get storageclass --no-headers 2>/dev/null)" ]]; then
                log_warn "Still no StorageClass found. Disabling MariaDB persistence to avoid Pending PVC."
                persistence_enabled="false"
            fi
        fi
    fi

    # Best-effort cleanup if a previous Bitnami release exists.
    helm uninstall mariadb -n "${ns}" 2>/dev/null || true
    kubectl -n "${ns}" delete statefulset mariadb 2>/dev/null || true
    kubectl -n "${ns}" delete svc mariadb mariadb-headless 2>/dev/null || true
    kubectl -n "${ns}" delete secret mariadb-auth 2>/dev/null || true

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: mariadb-auth
  namespace: ${ns}
type: Opaque
stringData:
  mariadb-root-password: "${MARIADB_ROOT_PASSWORD}"
  mariadb-database: "${MARIADB_DATABASE}"
  mariadb-user: "${MARIADB_USER}"
  mariadb-password: "${MARIADB_PASSWORD}"
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  namespace: ${ns}
  labels:
    app: mariadb
spec:
  type: ClusterIP
  selector:
    app: mariadb
  ports:
    - name: mysql
      port: 3306
      targetPort: 3306
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb-headless
  namespace: ${ns}
  labels:
    app: mariadb
spec:
  clusterIP: None
  selector:
    app: mariadb
  ports:
    - name: mysql
      port: 3306
      targetPort: 3306
EOF

    if [[ "${persistence_enabled}" == "true" ]]; then
        local storage_class_yaml=""
        if [[ -n "${MARIADB_STORAGE_CLASS}" ]]; then
            storage_class_yaml="        storageClassName: \"${MARIADB_STORAGE_CLASS}\""
        fi

        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mariadb
  namespace: ${ns}
spec:
  serviceName: mariadb-headless
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
        - name: mariadb
          image: ${MARIADB_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: mysql
              containerPort: 3306
          args:
            - --max-connections=${MARIADB_MAX_CONNECTIONS}
          env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-root-password
            - name: MARIADB_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-database
            - name: MARIADB_USER
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-user
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-password
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
          readinessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 375m
              memory: 384Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: ${MARIADB_STORAGE_SIZE}
${storage_class_yaml}
EOF
    else
        cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mariadb
  namespace: ${ns}
spec:
  serviceName: mariadb-headless
  replicas: 1
  selector:
    matchLabels:
      app: mariadb
  template:
    metadata:
      labels:
        app: mariadb
    spec:
      containers:
        - name: mariadb
          image: ${MARIADB_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: mysql
              containerPort: 3306
          args:
            - --max-connections=${MARIADB_MAX_CONNECTIONS}
          env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-root-password
            - name: MARIADB_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-database
            - name: MARIADB_USER
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-user
            - name: MARIADB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb-auth
                  key: mariadb-password
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
          readinessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 10
            periodSeconds: 5
          livenessProbe:
            tcpSocket:
              port: 3306
            initialDelaySeconds: 30
            periodSeconds: 10
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 375m
              memory: 384Mi
      volumes:
        - name: data
          emptyDir: {}
EOF
    fi

    kubectl -n "${ns}" rollout status statefulset/mariadb --timeout=600s 2>/dev/null || true
    kubectl -n "${ns}" wait --for=condition=Ready pod/mariadb-0 --timeout=600s 2>/dev/null || true
    
    log_info "MariaDB installed successfully"
    log_info "MariaDB connection info:"
    log_info "  Host: mariadb.${ns}.svc.cluster.local"
    log_info "  Port: 3306"
    log_info "  Root Password: ${MARIADB_ROOT_PASSWORD}"
    log_info "  Database: ${MARIADB_DATABASE}"
    log_info "  Username: ${MARIADB_USER}"
    log_info "  Password: ${MARIADB_PASSWORD}"

    # Create additional databases and grant permissions
    setup_mariadb_databases || return 1

    if [[ "${AUTO_GENERATE_CONFIG}" == "true" ]]; then
        log_info "Updating conf/config.yaml after MariaDB fresh install..."
        generate_config_yaml
        # Update RDS type to internal since MariaDB is installed internally
        update_rds_type_to_internal
    fi
}

# Install single-node MariaDB 11 using Bitnami chart (requires Bitnami image layout)
install_mariadb_bitnami() {
    log_info "Installing MariaDB (single-node) via Bitnami Helm chart..."

    local ns="${MARIADB_NAMESPACE}"
    local fresh_install="true"

    # Check if MariaDB is already installed
    if is_helm_installed "mariadb" "${ns}"; then
        fresh_install="false"
        log_info "MariaDB is already installed (Helm release exists). Skipping installation."
        # Even if MariaDB is already installed, regenerate config.yaml if password is missing
        local existing_pass
        existing_pass=$(grep -A 20 "^  rds:" "${CONFIG_YAML_PATH}" 2>/dev/null | grep "password:" | head -1 | awk '{print $2}' | tr -d "'\"")
        if [[ -z "${existing_pass}" ]] && [[ "${AUTO_GENERATE_CONFIG}" == "true" ]]; then
            log_info "MariaDB password is missing in config.yaml, regenerating..."
            generate_config_yaml
            update_rds_type_to_internal
        fi
        return 0
    fi

    # MariaDB password handling
    local existing_pass=$(config_yaml_dep_field rds password)
    if [[ -n "${existing_pass}" ]]; then
        MARIADB_PASSWORD="${existing_pass}"
        log_info "Using existing MariaDB password from config.yaml"
    else
        MARIADB_PASSWORD=$(generate_random_password 10)
        log_info "Generated random 10-character MariaDB password"
    fi

    local existing_root_pass=$(config_yaml_dep_field rds root_password)
    if [[ -n "${existing_root_pass}" ]]; then
        MARIADB_ROOT_PASSWORD="${existing_root_pass}"
        log_info "Using existing MariaDB root password from config.yaml"
    else
        MARIADB_ROOT_PASSWORD=$(generate_random_password 10)
        log_info "Generated random 10-character MariaDB root password"
    fi

    _mariadb_resolve_image_defaults

    # Parse image registry/repository/tag from MARIADB_IMAGE
    local image_without_tag="${MARIADB_IMAGE%:*}"
    local image_tag="${MARIADB_IMAGE##*:}"
    local image_registry="${image_without_tag%%/*}"
    local image_repo="${image_without_tag#*/}"

    local chart_ref="bitnami/mariadb"
    local use_local_chart="false"
    if [[ -f "${MARIADB_CHART_TGZ}" ]]; then
        chart_ref="${MARIADB_CHART_TGZ}"
        use_local_chart="true"
        log_info "Using local MariaDB chart: ${chart_ref}"
    else
        log_info "Using remote MariaDB chart: ${chart_ref} (version ${MARIADB_CHART_VERSION})"
    fi

    kubectl create namespace "${ns}" 2>/dev/null || true

    local persistence_enabled="${MARIADB_PERSISTENCE_ENABLED}"
    if [[ "${persistence_enabled}" == "true" ]]; then
        if [[ -z "$(kubectl get storageclass --no-headers 2>/dev/null)" ]]; then
            log_warn "No StorageClass found. MariaDB PVC will stay Pending."
            if [[ "${AUTO_INSTALL_LOCALPV}" == "true" ]]; then
                install_localpv
            fi
            if [[ -z "$(kubectl get storageclass --no-headers 2>/dev/null)" ]]; then
                log_warn "Still no StorageClass found. Disabling MariaDB persistence to avoid Pending PVC."
                persistence_enabled="false"
            fi
        fi
    fi

    if [[ "${use_local_chart}" != "true" ]]; then
        helm repo add --force-update bitnami "${HELM_REPO_BITNAMI}"
        helm repo update
    fi

    local -a helm_args
    helm_args=(
        upgrade --install mariadb "${chart_ref}"
        --namespace "${ns}"
        --set image.registry="${image_registry}"
        --set image.repository="${image_repo}"
        --set image.tag="${image_tag}"
        --set architecture=standalone
        --set auth.rootPassword="${MARIADB_ROOT_PASSWORD}"
        --set auth.database="${MARIADB_DATABASE}"
        --set auth.username="${MARIADB_USER}"
        --set auth.password="${MARIADB_PASSWORD}"
        --set primary.extraFlags="--max-connections=${MARIADB_MAX_CONNECTIONS}"
        --wait --timeout=600s
    )

    if [[ "${use_local_chart}" != "true" ]]; then
        helm_args+=(--version "${MARIADB_CHART_VERSION}")
    fi

    if [[ "${persistence_enabled}" == "true" ]]; then
        helm_args+=(
            --set primary.persistence.enabled=true
            --set primary.persistence.size="${MARIADB_STORAGE_SIZE}"
        )
        if [[ -n "${MARIADB_STORAGE_CLASS}" ]]; then
            helm_args+=(--set primary.persistence.storageClass="${MARIADB_STORAGE_CLASS}")
        fi
    else
        helm_args+=(--set primary.persistence.enabled=false)
    fi

    helm "${helm_args[@]}"

    # Wait for MariaDB Pod to be ready
    log_info "Waiting for MariaDB Pod to be ready..."
    kubectl wait --for=condition=ready pod -l "app.kubernetes.io/instance=mariadb" -n "${ns}" --timeout=300s 2>/dev/null || {
        log_warn "MariaDB Pod may not be ready yet"
    }

    log_info "MariaDB installed successfully"
    log_info "MariaDB connection info:"
    log_info "  Host: mariadb.${ns}.svc.cluster.local"
    log_info "  Port: 3306"
    log_info "  Root Password: ${MARIADB_ROOT_PASSWORD}"
    log_info "  Database: ${MARIADB_DATABASE}"
    log_info "  Username: ${MARIADB_USER}"
    log_info "  Password: ${MARIADB_PASSWORD}"

    # Create additional databases and grant permissions
    setup_mariadb_databases || return 1

    if [[ "${fresh_install}" == "true" && "${AUTO_GENERATE_CONFIG}" == "true" ]]; then
        log_info "Updating conf/config.yaml after MariaDB fresh install..."
        generate_config_yaml
        # Update RDS type to internal since MariaDB is installed internally
        update_rds_type_to_internal
    fi
}

install_mariadb() {
    _mariadb_resolve_image_defaults

    # Use mariadb Helm chart by default
    install_mariadb_helm
}

# Check if bkn-foundry (Core) services are installed before uninstalling MariaDB.
# Returns 0 (success) if NOT installed, 1 (error) if installed.
check_bkn_foundry_not_installed() {
    local namespace="${CORE_NAMESPACE:-openbkn}"
    
    # Check for core releases by looking for known release names
    # These are the main bkn-foundry services that depend on MariaDB
    local -a core_releases=(
        "bkn-backend"
        "ontology-query"
        "agent-retrieval"
        "bkn-safe"
        "vega-backend"
    )
    
    local found_releases=()
    for release in "${core_releases[@]}"; do
        if helm status "${release}" -n "${namespace}" >/dev/null 2>&1; then
            found_releases+=("${release}")
        fi
    done
    
    if [[ ${#found_releases[@]} -gt 0 ]]; then
        log_error "Cannot uninstall MariaDB: bkn-foundry services are still installed."
        log_error "Found installed releases in namespace '${namespace}':"
        for release in "${found_releases[@]}"; do
            log_error "  - ${release}"
        done
        log_error ""
        log_error "Please uninstall bkn-foundry first:"
        log_error "  bash deploy.sh foundry uninstall"
        log_error ""
        log_error "Or use --force to bypass this check (WARNING: will break bkn-foundry services):"
        log_error "  bash deploy.sh mariadb uninstall --force"
        return 1
    fi
    
    return 0
}

uninstall_mariadb() {
    local ns="${MARIADB_NAMESPACE}"
    local force="${MARIADB_UNINSTALL_FORCE:-false}"
    local purge="${MARIADB_PURGE_PVC:-false}"

    # Check if bkn-foundry is installed unless --force is specified
    if [[ "${force}" != "true" ]]; then
        if ! check_bkn_foundry_not_installed; then
            return 1
        fi
    else
        log_warn "Force mode enabled: skipping bkn-foundry check. This may break existing services!"
    fi

    log_info "Uninstalling MariaDB from namespace ${ns}..."

    # Use Helm to uninstall the release (automatically removes all managed resources)
    if helm status mariadb -n "${ns}" >/dev/null 2>&1; then
        log_info "Removing Helm release: mariadb"
        helm uninstall mariadb -n "${ns}"
    else
        log_info "Helm release mariadb not found, skipping Helm uninstall"
    fi

    # The PVC holds the root password the data directory was initialized with.
    # Deleting it silently made `--delete-data` meaningless and turned every
    # reinstall into a data-loss event, so make it explicit.
    if [[ "${purge}" == "true" ]]; then
        log_warn "Deleting MariaDB PVCs (data loss!)"
        kubectl delete pvc -n "${ns}" -l app.kubernetes.io/instance=mariadb 2>/dev/null || true
        kubectl delete pvc -n "${ns}" -l app.kubernetes.io/name=mariadb 2>/dev/null || true
        kubectl delete pvc -n "${ns}" data-mariadb-0 2>/dev/null || true
    else
        local remaining
        remaining="$(kubectl -n "${ns}" get pvc -l app.kubernetes.io/instance=mariadb -o name 2>/dev/null || true)"
        remaining+="$(kubectl -n "${ns}" get pvc data-mariadb-0 -o name 2>/dev/null || true)"
        if [[ -n "${remaining}" ]]; then
            log_info "Keeping MariaDB data (PVC): ${remaining//$'\n'/ }"
            log_info "Reinstalling reuses this data directory. If the root password in config.yaml"
            log_info "differs from the one stored there, run: bash deploy.sh mariadb repair-password"
            log_info "To wipe the data instead: bash deploy.sh mariadb uninstall --force --delete-data"
        fi
    fi

    log_info "MariaDB uninstall done"
}
