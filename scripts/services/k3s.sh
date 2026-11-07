
# Single-node k3s installation helpers (Linux).
# Keeps Traefik disabled; use install_ingress_nginx from ingress_nginx.sh for ingress.

K3S_INSTALL_URL="${K3S_INSTALL_URL:-https://rancher-mirror.rancher.cn/k3s/k3s-install.sh}"
INSTALL_K3S_MIRROR="${INSTALL_K3S_MIRROR:-cn}"
INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.30.6+k3s1}"
INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC:-server --disable=traefik --write-kubeconfig-mode=644}"
# Passed to rancher k3s-install.sh. Empty = auto (see install_k3s); set true/false to force.
INSTALL_K3S_SKIP_SELINUX_RPM="${INSTALL_K3S_SKIP_SELINUX_RPM:-}"

# Pre-seed k3s containerd with system images that the rancher k3s installer
# does NOT bundle (busybox for local-path-provisioner helper-pod, ...).
# k3s auto-imports any *.tar / *.tar.gz / *.tar.zst in /var/lib/rancher/k3s/agent/images/
# on first agent boot. Must run BEFORE the rancher installer, otherwise the
# agent dir is owned by k3s and our copy may race the first reconcile.
_seed_k3s_system_images() {
    local target_dir=/var/lib/rancher/k3s/agent/images
    local src_dir
    src_dir="${SCRIPT_DIR}/images"
    if [[ ! -d "${src_dir}" ]]; then
        log_warn "k3s system-image cache ${src_dir} missing; skipping seed (helper-pod busybox may need to be pulled from docker.io)"
        return 0
    fi

    local -a tarballs=()
    local f
    for f in "${src_dir}"/*.tar "${src_dir}"/*.tar.gz "${src_dir}"/*.tar.zst; do
        [[ -f "${f}" ]] && tarballs+=("${f}")
    done
    if [[ ${#tarballs[@]} -eq 0 ]]; then
        log_warn "No tarballs in ${src_dir}; skipping k3s system-image seed"
        return 0
    fi

    mkdir -p "${target_dir}"
    for f in "${tarballs[@]}"; do
        cp -f "${f}" "${target_dir}/"
        log_info "Seeded k3s image: ${target_dir}/$(basename "${f}")"
    done
}

_export_k3s_kubeconfig() {
    if [[ -f /root/.kube/config ]]; then
        export KUBECONFIG=/root/.kube/config
    elif [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi
}

_k3s_is_ipv4() {
    local value="${1:-}"
    [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    awk -F. '
        NF != 4 { exit 1 }
        $1 == 0 || $1 > 255 { exit 1 }
        $2 > 255 || $3 > 255 || $4 > 255 { exit 1 }
    ' <<<"${value}"
}

# Prefer the source address selected by the default route. On multi-NIC hosts,
# hostname -I can return Docker/CNI or unrelated interface addresses first.
_k3s_detect_node_ip() {
    local candidate=""

    if [[ -n "${TARGET_IP:-}" ]]; then
        if ! _k3s_is_ipv4 "${TARGET_IP}" || [[ "${TARGET_IP}" == 127.* ]]; then
            log_error "TARGET_IP must be a non-loopback IPv4 address: ${TARGET_IP}"
            return 1
        fi
        printf '%s' "${TARGET_IP}"
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        candidate="$(
            ip -4 route get 1.1.1.1 2>/dev/null |
                awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}'
        )"
    fi

    if ! _k3s_is_ipv4 "${candidate}" || [[ "${candidate}" == 127.* ]]; then
        candidate=""
        while IFS= read -r address; do
            _k3s_is_ipv4 "${address}" || continue
            case "${address}" in
                0.*|127.*|169.254.*|10.42.*|10.43.*) continue ;;
            esac
            candidate="${address}"
            break
        done < <(hostname -I 2>/dev/null | tr ' ' '\n')
    fi

    if [[ -z "${candidate}" ]]; then
        log_error "Could not detect a non-loopback node IPv4 address. Set TARGET_IP explicitly."
        return 1
    fi

    printf '%s' "${candidate}"
}

_k3s_exec_add_node_address() {
    local exec_args="$1"
    local node_ip="$2"

    if [[ " ${exec_args} " != *" --advertise-address="* &&
          " ${exec_args} " != *" --advertise-address "* ]]; then
        exec_args="${exec_args} --advertise-address=${node_ip}"
    fi
    if [[ " ${exec_args} " != *" --tls-san="* &&
          " ${exec_args} " != *" --tls-san "* ]]; then
        exec_args="${exec_args} --tls-san=${node_ip}"
    fi

    printf '%s' "${exec_args}"
}

_k3s_write_node_address_config() {
    local node_ip="$1"
    local config_dir=/etc/rancher/k3s/config.yaml.d
    local config_file="${config_dir}/99-openbkn-node-address.yaml"
    local config_tmp

    mkdir -p "${config_dir}"
    config_tmp="$(mktemp "${config_file}.tmp.XXXXXX")"
    cat >"${config_tmp}" <<EOF
# Managed by OpenBKN. Keeps the Kubernetes API endpoint aligned with this node.
node-ip: "${node_ip}"
advertise-address: "${node_ip}"
tls-san+:
  - "${node_ip}"
EOF
    chmod 0600 "${config_tmp}"

    if [[ -f "${config_file}" ]] && cmp -s "${config_tmp}" "${config_file}"; then
        rm -f "${config_tmp}"
        return 0
    fi

    if [[ -f "${config_file}" ]]; then
        cp -a "${config_file}" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    mv -f "${config_tmp}" "${config_file}"
    if command -v restorecon >/dev/null 2>&1; then
        restorecon -RF "${config_dir}" >/dev/null 2>&1 || true
    fi
    log_info "Configured k3s node/API address ${node_ip} in ${config_file}"
}

_k3s_get_kubernetes_endpoint_ips() {
    local endpoint_ips=""

    if ! command -v kubectl >/dev/null 2>&1; then
        return 1
    fi

    endpoint_ips="$(
        kubectl get endpointslice -n default \
            -l kubernetes.io/service-name=kubernetes \
            -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' \
            --request-timeout=10s 2>/dev/null
    )" || true

    if [[ -z "${endpoint_ips}" ]]; then
        endpoint_ips="$(
            kubectl get endpoints kubernetes -n default \
                -o jsonpath='{range .subsets[*]}{range .addresses[*]}{.ip}{"\n"}{end}{end}' \
                --request-timeout=10s 2>/dev/null
        )" || true
    fi

    [[ -n "${endpoint_ips}" ]] || return 1
    printf '%s\n' "${endpoint_ips}"
}

_k3s_node_address_matches() {
    local node_ip="$1"
    local endpoint_ips

    endpoint_ips="$(_k3s_get_kubernetes_endpoint_ips)" || return 1
    awk -v expected="${node_ip}" '
        NF && $1 != expected { bad = 1 }
        END { exit bad }
    ' <<<"${endpoint_ips}"
}

_k3s_wait_for_node_address() {
    local node_ip="$1"
    local attempts="${2:-60}"
    local endpoint_ips=""
    local attempt

    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if _k3s_node_address_matches "${node_ip}"; then
            log_info "Kubernetes API Endpoint matches node address ${node_ip}."
            return 0
        fi
        sleep 2
    done

    endpoint_ips="$(_k3s_get_kubernetes_endpoint_ips 2>/dev/null || true)"
    log_error "Kubernetes API Endpoint does not match node address ${node_ip}."
    log_error "Current Endpoint(s): ${endpoint_ips:-unavailable}"
    log_error "Check: kubectl get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o wide"
    log_error "Review: journalctl -u k3s -n 200 --no-pager"
    return 1
}

_k3s_repair_node_address() {
    local node_ip="$1"

    _export_k3s_kubeconfig
    _k3s_write_node_address_config "${node_ip}" || return 1

    if _k3s_node_address_matches "${node_ip}"; then
        return 0
    fi

    if ! systemctl is-active --quiet k3s; then
        return 0
    fi

    log_warn "Existing k3s Kubernetes API Endpoint does not match ${node_ip}; restarting k3s to apply the managed node-address config."
    systemctl restart k3s
    _k3s_wait_for_node_address "${node_ip}"
}

# Return 0 if kubectl can reach a Ready cluster using k3s kubeconfig paths.
k3s_is_running() {
    _export_k3s_kubeconfig

    if [[ -z "${KUBECONFIG:-}" ]]; then
        return 1
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        return 1
    fi

    if kubectl get nodes >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

show_k3s_status() {
    _export_k3s_kubeconfig
    if [[ -z "${KUBECONFIG:-}" ]]; then
        log_warn "No k3s kubeconfig found (/root/.kube/config or /etc/rancher/k3s/k3s.yaml)."
        return 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not found; k3s may be misconfigured."
        return 1
    fi
    log_info "kubectl context: ${KUBECONFIG}"
    echo ""
    kubectl get nodes -o wide 2>/dev/null || true
    echo ""
    kubectl get pods -A 2>/dev/null || true
}

install_k3s() {
    check_root

    local node_ip
    node_ip="$(_k3s_detect_node_ip)" || return 1
    export TARGET_IP="${TARGET_IP:-${node_ip}}"

    _k3s_write_node_address_config "${node_ip}" || return 1

    if systemctl is-active --quiet k3s || k3s_is_running; then
        log_info "k3s is already installed; checking the Kubernetes API Endpoint."
        _k3s_repair_node_address "${node_ip}" || return 1
        log_info "k3s cluster already running and the Kubernetes API Endpoint is valid."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required to install k3s."
        return 1
    fi

    INSTALL_K3S_EXEC="$(_k3s_exec_add_node_address "${INSTALL_K3S_EXEC}" "${node_ip}")"
    log_info "Installing k3s (version ${INSTALL_K3S_VERSION})..."
    log_info "K3S_INSTALL_URL=${K3S_INSTALL_URL}"
    log_info "INSTALL_K3S_MIRROR=${INSTALL_K3S_MIRROR}"
    log_info "INSTALL_K3S_EXEC=${INSTALL_K3S_EXEC}"

    _seed_k3s_system_images

    # k3s-install.sh maps HCE VERSION_ID (e.g. 2.0) to el9 k3s-selinux, which requires
    # container-selinux >= 3:2.191 — often missing on Huawei/yum mirrors → dnf aborts before k3s starts.
    # Skip the SELinux RPM when SELinux is off, or on hce/openEuler (aligns with permissive/disabled lab setups).
    local _skip_selinux_rpm="${INSTALL_K3S_SKIP_SELINUX_RPM}"
    if [[ -z "${_skip_selinux_rpm}" ]]; then
        local _want_skip=false
        local os_id=""
        if [[ -f /etc/os-release ]]; then
            os_id="$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)"
        fi
        case "${os_id}" in
            hce|openEuler|openeuler) _want_skip=true ;;
        esac
        if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Disabled" ]]; then
            _want_skip=true
        fi
        if [[ -f /etc/selinux/config ]] && grep -qE '^[[:space:]]*SELINUX[[:space:]]*=[[:space:]]*disabled' /etc/selinux/config 2>/dev/null; then
            _want_skip=true
        fi
        if [[ "${_want_skip}" == "true" ]]; then
            _skip_selinux_rpm=true
            log_info "INSTALL_K3S_SKIP_SELINUX_RPM=true (auto: hce/openEuler and/or SELinux disabled — avoid k3s-selinux dependency failure). Override with INSTALL_K3S_SKIP_SELINUX_RPM=false if you need the RPM after satisfying container-selinux)."
        fi
    else
        log_info "INSTALL_K3S_SKIP_SELINUX_RPM=${INSTALL_K3S_SKIP_SELINUX_RPM} (user-set)"
    fi

    curl -sfL "${K3S_INSTALL_URL}" \
        | INSTALL_K3S_VERSION="${INSTALL_K3S_VERSION}" \
            INSTALL_K3S_MIRROR="${INSTALL_K3S_MIRROR}" \
            INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC}" \
            INSTALL_K3S_SKIP_SELINUX_RPM="${_skip_selinux_rpm:-false}" \
            sh -

    if [[ ! -f /etc/rancher/k3s/k3s.yaml ]]; then
        log_error "k3s install finished but /etc/rancher/k3s/k3s.yaml is missing."
        return 1
    fi

    mkdir -p /root/.kube
    install -m 0600 /etc/rancher/k3s/k3s.yaml /root/.kube/config
    export KUBECONFIG=/root/.kube/config

    if ! command -v kubectl >/dev/null 2>&1; then
        log_error "kubectl not available after k3s install."
        return 1
    fi

    log_info "Waiting for all nodes to be Ready..."
    kubectl wait --for=condition=Ready node --all --timeout=300s

    log_info "Waiting for the Kubernetes API Endpoint to use node address ${node_ip}..."
    _k3s_wait_for_node_address "${node_ip}" || return 1

    log_info "k3s install completed."
}

uninstall_k3s() {
    check_root

    local uninstaller=""
    for candidate in /usr/local/bin/k3s-uninstall.sh /usr/bin/k3s-uninstall.sh; do
        if [[ -x "${candidate}" ]]; then
            uninstaller="${candidate}"
            break
        fi
    done

    if [[ -z "${uninstaller}" ]]; then
        log_warn "k3s-uninstall.sh not found; k3s does not appear to be installed."
        return 0
    fi

    log_info "Running ${uninstaller} ..."
    bash "${uninstaller}"
}
