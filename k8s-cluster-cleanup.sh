#!/usr/bin/env bash

set -Eeuo pipefail

CRI_SOCKET='unix:///run/containerd/containerd.sock'
EXPECTED_KUBERNETES_VERSION='1.35.6'
EXPECTED_CONTAINERD_VERSION='2.2.6'
EXPECTED_CALICO_VERSION='3.32.1'
EXPECTED_HELM_VERSION='3.20.0'
EXPECTED_METRICS_SERVER_VERSION='0.8.1'
EXPECTED_NVIDIA_DRIVER_VERSION='580.173.02'
EXPECTED_NVIDIA_TOOLKIT_VERSION='1.19.1'
EXPECTED_NVIDIA_GPU_MODEL='RTX 3090'
EXPECTED_NVIDIA_SMI_GPU_NAME='NVIDIA GeForce RTX 3090'
EXPECTED_NVIDIA_GPU_MEMORY_MIB='24576'
EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER=1
EXPECTED_GPU_OPERATOR_VERSION='26.3.3'
EXPECTED_DYNAMO_VERSION='1.3.0'
EXPECTED_DYNAMO_VLLM_VERSION='0.23.0'
EXPECTED_DYNAMO_VLLM_IMAGE='nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0'
EXPECTED_DYNAMO_NAMESPACE='dynamo-system'
EXPECTED_DYNAMO_NATS_STORAGE_CLASS='pactllm-local-nats'
EXPECTED_DYNAMO_NATS_STORAGE_SIZE='10Gi'
EXPECTED_DYNAMO_NATS_STORAGE_PATH='/var/lib/pactllm/dynamo-nats'
EXPECTED_GATEWAY_API_VERSION='1.5.1'
EXPECTED_GAIE_VERSION='1.2.1'
EXPECTED_AGENTGATEWAY_VERSION='1.0.0'
EXPECTED_AGENTGATEWAY_NAMESPACE='agentgateway-system'
EXPECTED_CONTROL_PLANE_IP='192.168.0.10'
EXPECTED_POD_CIDR='10.244.0.0/16'
EXPECTED_REGULAR_USER_HOME='/home/dnclab'
EXPECTED_WORKER_USER='dnclab'
EXPECTED_GPU_WORKER_COUNT=4
REMOTE_CLEANUP_DIR='/tmp/k8s-cluster-cleanup-1-35-6'
NODE_MARKER_DIR='/etc/pactllm-bootstrap'
NODE_MARKER_FILE="${NODE_MARKER_DIR}/node.env"
BOOTSTRAP_STATE_ROOT='/var/lib/pactllm-bootstrap'
HELM_STATE_ROOT="${BOOTSTRAP_STATE_ROOT}/helm"
HELM_CONFIG_HOME="${HELM_STATE_ROOT}/config"
HELM_CACHE_HOME="${HELM_STATE_ROOT}/cache"
HELM_DATA_HOME="${HELM_STATE_ROOT}/data"
export HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME
SSH_STATE_DIR="${BOOTSTRAP_STATE_ROOT}/ssh"
SSH_KNOWN_HOSTS_FILE="${SSH_STATE_DIR}/known_hosts"

printstyle() {
  local message="$1"
  local style="${2:-default}"
  local color

  case "$style" in
    info) color='96m' ;;
    success) color='92m' ;;
    warning) color='93m' ;;
    danger) color='91m' ;;
    *) color='0m' ;;
  esac

  if [[ "$style" == 'danger' ]]; then
    printf '\e[%s%b\e[0m' "$color" "$message" >&2
  else
    printf '\e[%s%b\e[0m' "$color" "$message"
  fi
}

lineprint() {
  local width="${COLUMNS:-70}"
  printf '%*s\n' "$width" '' | tr ' ' '='
}

die() {
  printstyle "$1\n" danger
  exit 1
}

warn() {
  printstyle "$1\n" warning
}

valid_ipv4() {
  local ip="$1"
  local octets octet

  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  (( ${#octets[@]} == 4 )) || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    (( 10#$octet >= 0 && 10#$octet <= 255 )) || return 1
  done
}

valid_cluster_id() {
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

require_config_value() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "Required configuration value is empty: $name"
}

load_config() {
  local line key value config_mode

  [[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: $CONFIG_FILE"
  config_mode="$(stat -c '%a' "$CONFIG_FILE")"
  if (( (8#$config_mode & 077) != 0 )); then
    die "Configuration file permissions are too open ($config_mode). Run: chmod 600 $CONFIG_FILE"
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if [[ ! "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      die "Invalid configuration line: $line"
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 ]] && { [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] || [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; }; then
      value="${value:1:${#value}-2}"
    fi

    case "$key" in
      NODE_ROLE|CLUSTER_ID|KUBERNETES_VERSION|CONTAINERD_VERSION|CALICO_VERSION|HELM_VERSION|CONTROL_PLANE_IP|POD_CIDR|INSTALL_CALICO|INSTALL_METRICS_SERVER|METRICS_SERVER_VERSION|REGULAR_USER_HOME|GPU_WORKER_COUNT|INSTALL_NVIDIA_STACK|NVIDIA_DRIVER_VERSION|NVIDIA_CONTAINER_TOOLKIT_VERSION|NVIDIA_GPU_MODEL|NVIDIA_GPU_MEMORY_MIB|NVIDIA_GPU_COUNT_PER_WORKER|GPU_OPERATOR_VERSION|INSTALL_DYNAMO_PLATFORM|DYNAMO_PLATFORM_VERSION|DYNAMO_VLLM_VERSION|DYNAMO_VLLM_IMAGE|DYNAMO_NAMESPACE|DYNAMO_NATS_STORAGE_CLASS|DYNAMO_NATS_STORAGE_SIZE|DYNAMO_NATS_STORAGE_PATH|PREPULL_DYNAMO_VLLM_IMAGE|INSTALL_GATEWAY_FOUNDATION|GATEWAY_API_VERSION|GAIE_VERSION|AGENTGATEWAY_VERSION|AGENTGATEWAY_NAMESPACE)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        if [[ "$key" =~ ^GPU_WORKER_[1-4]_(IP|SSH_USER|SSH_PASSWORD)$ ]]; then
          printf -v "$key" '%s' "$value"
        else
          die "Unknown configuration key: $key"
        fi
        ;;
    esac
  done < "$CONFIG_FILE"
}

validate_fixed_stack() {
  [[ "$NODE_ROLE" == 'control-plane' ]] || die 'NODE_ROLE must be control-plane.'
  [[ "$KUBERNETES_VERSION" == "$EXPECTED_KUBERNETES_VERSION" ]] || die "Cleanup only supports Kubernetes $EXPECTED_KUBERNETES_VERSION."
  [[ "$CONTAINERD_VERSION" == "$EXPECTED_CONTAINERD_VERSION" ]] || die "Cleanup only supports containerd $EXPECTED_CONTAINERD_VERSION."
  [[ "${CALICO_VERSION#v}" == "$EXPECTED_CALICO_VERSION" ]] || die "Cleanup only supports Calico $EXPECTED_CALICO_VERSION."
  [[ "$HELM_VERSION" == "$EXPECTED_HELM_VERSION" ]] || die "Cleanup only supports Helm $EXPECTED_HELM_VERSION."
  [[ "$METRICS_SERVER_VERSION" == "$EXPECTED_METRICS_SERVER_VERSION" ]] || die "Cleanup only supports metrics-server $EXPECTED_METRICS_SERVER_VERSION."
  [[ "$NVIDIA_DRIVER_VERSION" == "$EXPECTED_NVIDIA_DRIVER_VERSION" ]] || die "Cleanup only preserves NVIDIA Driver $EXPECTED_NVIDIA_DRIVER_VERSION."
  [[ "$NVIDIA_CONTAINER_TOOLKIT_VERSION" == "$EXPECTED_NVIDIA_TOOLKIT_VERSION" ]] || die "Cleanup only supports NVIDIA Container Toolkit $EXPECTED_NVIDIA_TOOLKIT_VERSION."
  [[ "$NVIDIA_GPU_MODEL" == "$EXPECTED_NVIDIA_GPU_MODEL" ]] || die "Cleanup only supports NVIDIA GPU model $EXPECTED_NVIDIA_GPU_MODEL."
  [[ "$NVIDIA_GPU_MEMORY_MIB" == "$EXPECTED_NVIDIA_GPU_MEMORY_MIB" ]] || die "Cleanup expects ${EXPECTED_NVIDIA_GPU_MEMORY_MIB} MiB on each GPU backend."
  [[ "$NVIDIA_GPU_COUNT_PER_WORKER" == "$EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER" ]] || die "Cleanup expects $EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER GPU per worker."
  [[ "${GPU_OPERATOR_VERSION#v}" == "$EXPECTED_GPU_OPERATOR_VERSION" ]] || die "Cleanup only supports GPU Operator $EXPECTED_GPU_OPERATOR_VERSION."
  [[ "$DYNAMO_PLATFORM_VERSION" == "$EXPECTED_DYNAMO_VERSION" ]] || die "Cleanup only supports Dynamo $EXPECTED_DYNAMO_VERSION."
  [[ "$DYNAMO_VLLM_VERSION" == "$EXPECTED_DYNAMO_VLLM_VERSION" ]] || die "Cleanup only supports Dynamo vLLM $EXPECTED_DYNAMO_VLLM_VERSION."
  [[ "$DYNAMO_VLLM_IMAGE" == "$EXPECTED_DYNAMO_VLLM_IMAGE" ]] || die "Unexpected Dynamo vLLM image in cluster.env."
  [[ "$DYNAMO_NAMESPACE" == "$EXPECTED_DYNAMO_NAMESPACE" ]] || die "Cleanup only supports Dynamo namespace $EXPECTED_DYNAMO_NAMESPACE."
  [[ "$DYNAMO_NATS_STORAGE_CLASS" == "$EXPECTED_DYNAMO_NATS_STORAGE_CLASS" ]] || die "Unexpected Dynamo NATS StorageClass."
  [[ "$DYNAMO_NATS_STORAGE_SIZE" == "$EXPECTED_DYNAMO_NATS_STORAGE_SIZE" ]] || die "Unexpected Dynamo NATS storage size."
  [[ "$DYNAMO_NATS_STORAGE_PATH" == "$EXPECTED_DYNAMO_NATS_STORAGE_PATH" ]] || die "Unexpected Dynamo NATS storage path."
  [[ "$GATEWAY_API_VERSION" == "$EXPECTED_GATEWAY_API_VERSION" ]] || die "Cleanup only supports Gateway API $EXPECTED_GATEWAY_API_VERSION."
  [[ "$GAIE_VERSION" == "$EXPECTED_GAIE_VERSION" ]] || die "Cleanup only supports GAIE $EXPECTED_GAIE_VERSION."
  [[ "$AGENTGATEWAY_VERSION" == "$EXPECTED_AGENTGATEWAY_VERSION" ]] || die "Cleanup only supports agentgateway $EXPECTED_AGENTGATEWAY_VERSION."
  [[ "$AGENTGATEWAY_NAMESPACE" == "$EXPECTED_AGENTGATEWAY_NAMESPACE" ]] || die "Unexpected agentgateway namespace."
  [[ "$INSTALL_CALICO" == 'true' ]] || die 'The fixed cleanup expects INSTALL_CALICO=true.'
  [[ "$INSTALL_METRICS_SERVER" == 'true' ]] || die 'The fixed cleanup expects INSTALL_METRICS_SERVER=true.'
  [[ "$INSTALL_NVIDIA_STACK" == 'true' ]] || die 'The fixed cleanup expects INSTALL_NVIDIA_STACK=true.'
  [[ "$INSTALL_DYNAMO_PLATFORM" == 'true' ]] || die 'The fixed cleanup expects INSTALL_DYNAMO_PLATFORM=true.'
  [[ "$PREPULL_DYNAMO_VLLM_IMAGE" == 'true' ]] || die 'The fixed cleanup expects PREPULL_DYNAMO_VLLM_IMAGE=true.'
  [[ "$INSTALL_GATEWAY_FOUNDATION" == 'true' ]] || die 'The fixed cleanup expects INSTALL_GATEWAY_FOUNDATION=true.'
  valid_ipv4 "$CONTROL_PLANE_IP" || die "Invalid CONTROL_PLANE_IP: $CONTROL_PLANE_IP"
  [[ "$CONTROL_PLANE_IP" == "$EXPECTED_CONTROL_PLANE_IP" ]] || die "Cleanup is pinned to control-plane IP $EXPECTED_CONTROL_PLANE_IP."
  [[ "$POD_CIDR" == "$EXPECTED_POD_CIDR" ]] || die "Cleanup is pinned to pod CIDR $EXPECTED_POD_CIDR."
  [[ "$REGULAR_USER_HOME" == "$EXPECTED_REGULAR_USER_HOME" ]] || die "Cleanup is pinned to regular user home $EXPECTED_REGULAR_USER_HOME."
  [[ "$GPU_WORKER_COUNT" =~ ^[1-9][0-9]*$ ]] || die 'GPU_WORKER_COUNT must be a positive integer.'
  GPU_WORKER_COUNT="$((10#$GPU_WORKER_COUNT))"
  (( GPU_WORKER_COUNT == EXPECTED_GPU_WORKER_COUNT )) || die "Cleanup is pinned to $EXPECTED_GPU_WORKER_COUNT GPU backend workers."
}

collect_workers() {
  local index ip_var user_var password_var ip user password
  declare -A seen_ips=()

  for ((index = 1; index <= GPU_WORKER_COUNT; index++)); do
    ip_var="GPU_WORKER_${index}_IP"
    user_var="GPU_WORKER_${index}_SSH_USER"
    password_var="GPU_WORKER_${index}_SSH_PASSWORD"
    require_config_value "$ip_var"
    require_config_value "$user_var"
    require_config_value "$password_var"

    ip="${!ip_var}"
    user="${!user_var}"
    password="${!password_var}"
    valid_ipv4 "$ip" || die "Invalid GPU backend worker IP: $ip"
    [[ "$ip" == "192.168.0.$((10 + index))" ]] || \
      die "GPU backend worker $index IP must be 192.168.0.$((10 + index))."
    [[ "$ip" != "$CONTROL_PLANE_IP" ]] || die "Worker IP cannot equal the control-plane IP: $ip"
    [[ -z "${seen_ips[$ip]:-}" ]] || die "Duplicate worker IP: $ip"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Invalid SSH username for GPU backend worker $index: $user"
    [[ "$user" == "$EXPECTED_WORKER_USER" ]] || die "GPU backend worker $index SSH user must be $EXPECTED_WORKER_USER."
    seen_ips["$ip"]=1

    WORKER_IPS+=("$ip")
    WORKER_USERS+=("$user")
    WORKER_PASSWORDS+=("$password")
  done
}

validate_node_marker_file() {
  local expected_cluster_id="$1"
  local expected_role="$2"
  local expected_ip="$3"

  valid_cluster_id "$expected_cluster_id" || return 1
  [[ -f "$NODE_MARKER_FILE" && ! -L "$NODE_MARKER_FILE" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' "$NODE_MARKER_FILE")" == '0:0:600' ]] || return 1
  grep -Fxq "CLUSTER_ID=${expected_cluster_id}" "$NODE_MARKER_FILE" &&
    grep -Fxq "NODE_ROLE=${expected_role}" "$NODE_MARKER_FILE" &&
    grep -Fxq "NODE_IP=${expected_ip}" "$NODE_MARKER_FILE" &&
    grep -Fxq "KUBERNETES_VERSION=${EXPECTED_KUBERNETES_VERSION}" "$NODE_MARKER_FILE" &&
    grep -Eq '^CLEANUP_STATE=(active|cleaned)$' "$NODE_MARKER_FILE"
}

node_cleanup_state() {
  awk -F= '$1 == "CLEANUP_STATE" { print $2; exit }' "$NODE_MARKER_FILE"
}

set_node_cleanup_state_cleaned() {
  local temp_file

  temp_file="$(mktemp)"
  awk '
    $0 ~ /^CLEANUP_STATE=/ {
      if (!done) print "CLEANUP_STATE=cleaned"
      done = 1
      next
    }
    { print }
    END { if (!done) print "CLEANUP_STATE=cleaned" }
  ' "$NODE_MARKER_FILE" > "$temp_file"
  install -o root -g root -m 0600 "$temp_file" "$NODE_MARKER_FILE"
  rm -f -- "$temp_file"
}

verify_remote_marker() {
  local index="$1"
  local ip command

  ip="${WORKER_IPS[$index]}"
  command="test -f '${NODE_MARKER_FILE}' && test ! -L '${NODE_MARKER_FILE}' && test \"\$(stat -c '%u:%g:%a' '${NODE_MARKER_FILE}')\" = '0:0:600' && grep -Fxq 'CLUSTER_ID=${CLUSTER_ID}' '${NODE_MARKER_FILE}' && grep -Fxq 'NODE_ROLE=gpu-backend' '${NODE_MARKER_FILE}' && grep -Fxq 'NODE_IP=${ip}' '${NODE_MARKER_FILE}' && grep -Fxq 'KUBERNETES_VERSION=${EXPECTED_KUBERNETES_VERSION}' '${NODE_MARKER_FILE}' && grep -Eq '^CLEANUP_STATE=(active|cleaned)$' '${NODE_MARKER_FILE}'"
  remote_privileged_command "$index" "$command"
}

remote_marker_cleanup_state() {
  local index="$1"
  remote_privileged_command "$index" "awk -F= '\$1 == \"CLEANUP_STATE\" { print \$2; exit }' '${NODE_MARKER_FILE}'"
}

prepare_ssh_state() {
  install -d -o root -g root -m 0700 "$SSH_STATE_DIR"
  touch "$SSH_KNOWN_HOSTS_FILE"
  chown root:root "$SSH_KNOWN_HOSTS_FILE"
  chmod 0600 "$SSH_KNOWN_HOSTS_FILE"
}

remote_privileged_command() {
  local index="$1"
  local command="$2"
  local target password user quoted_command

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  user="${WORKER_USERS[$index]}"
  printf -v quoted_command '%q' "$command"

  if [[ "$user" == 'root' ]]; then
    SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "bash -c $quoted_command"
  else
    printf '%s\n' "$password" | SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "sudo -S -p '' bash -c $quoted_command"
  fi
}

verify_remote_driver() {
  local index="$1"
  local target password inventory gpu_name driver_version memory_total
  local gpu_count=0

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  inventory="$(SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" \
    "nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader")" || \
    die "NVIDIA Driver check failed on $target. Cleanup will not start."
  [[ -n "$inventory" ]] || die "No NVIDIA GPU was reported on $target."

  while IFS=',' read -r gpu_name driver_version memory_total; do
    driver_version="${driver_version#"${driver_version%%[![:space:]]*}"}"
    driver_version="${driver_version%"${driver_version##*[![:space:]]}"}"
    memory_total="${memory_total#"${memory_total%%[![:space:]]*}"}"
    memory_total="${memory_total%"${memory_total##*[![:space:]]}"}"
    memory_total="${memory_total% MiB}"
    gpu_name="${gpu_name#"${gpu_name%%[![:space:]]*}"}"
    gpu_name="${gpu_name%"${gpu_name##*[![:space:]]}"}"
    [[ "$gpu_name" == "$EXPECTED_NVIDIA_SMI_GPU_NAME" ]] || die "Unexpected GPU on $target: $gpu_name"
    [[ "$driver_version" == "$EXPECTED_NVIDIA_DRIVER_VERSION" ]] || die "Worker $target is not using NVIDIA Driver $EXPECTED_NVIDIA_DRIVER_VERSION."
    [[ "$memory_total" == "$EXPECTED_NVIDIA_GPU_MEMORY_MIB" ]] || die "Unexpected GPU memory on $target: ${memory_total} MiB."
    ((gpu_count += 1))
  done <<< "$inventory"
  (( gpu_count == EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER )) || die "Worker $target does not have exactly $EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER GPU."
}

preflight_remote_workers() {
  local index target password user hostname_short
  declare -A seen_hostnames=(["$LOCAL_HOSTNAME"]=1)

  for index in "${!WORKER_IPS[@]}"; do
    target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
    password="${WORKER_PASSWORDS[$index]}"
    user="${WORKER_USERS[$index]}"
    printstyle "Checking SSH, sudo, target IP, and role prerequisites on $target ...\n" info

    SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" 'true' || \
      die "Cannot connect to $target. Cleanup has not started."
    if [[ "$user" != 'root' ]] && ! printf '%s\n' "$password" | SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "sudo -S -p '' true"; then
      die "Configured account cannot run sudo on $target. Cleanup has not started."
    fi
    if ! remote_privileged_command "$index" "ip -4 -o addr show | grep -Fq ' ${WORKER_IPS[$index]}/'" >/dev/null; then
      die "Remote host $target does not own the configured IP ${WORKER_IPS[$index]}. Cleanup has not started."
    fi
    hostname_short="$(remote_privileged_command "$index" 'hostname -s')" || \
      die "Cannot read the hostname from $target. Cleanup has not started."
    [[ "$hostname_short" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
      die "Remote host $target has an invalid Kubernetes node hostname: $hostname_short"
    [[ -z "${seen_hostnames[$hostname_short]:-}" ]] || die "Duplicate node hostname detected: $hostname_short"
    seen_hostnames["$hostname_short"]=1
    WORKER_HOSTNAMES[$index]="$hostname_short"
    verify_remote_marker "$index" || \
      die "Remote host $target does not have the matching root-owned cluster/role/IP marker. Cleanup has not started."
    WORKER_CLEANUP_STATES[$index]="$(remote_marker_cleanup_state "$index")"
    [[ "${WORKER_CLEANUP_STATES[$index]}" == 'active' || "${WORKER_CLEANUP_STATES[$index]}" == 'cleaned' ]] || \
      die "Remote host $target has an invalid cleanup marker state."
    verify_remote_driver "$index"
  done
}

verify_api_inventory_if_available() {
  local node node_name addresses matched_ip candidate_ip match_count role api_cluster_id index expected_name identity control_plane_phase
  declare -A expected_roles=()
  declare -A expected_names=()
  declare -A seen_ips=()

  if ! cluster_api_available; then
    warn 'Kubernetes API is unavailable; cleanup identity is guarded by the root-owned node markers only.'
    return 0
  fi
  if KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get configmap pactllm-cluster-identity >/dev/null 2>&1; then
    identity="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get configmap pactllm-cluster-identity \
      -o jsonpath='{.data.cluster_id}{"|"}{.data.control_plane_ip}{"|"}{.data.kubernetes_version}')"
    [[ "$identity" == "${CLUSTER_ID}|${CONTROL_PLANE_IP}|${KUBERNETES_VERSION}" ]] || \
      die 'The live Kubernetes API carries a different PactLLM cluster identity. Cleanup refused.'
  else
    control_plane_phase="$(awk -F= '$1 == "CONTROL_PLANE_INITIALIZED" { print $2; exit }' "$NODE_MARKER_FILE")"
    [[ "$control_plane_phase" != 'true' ]] || \
      die 'The marker says control-plane initialization completed, but the API identity ConfigMap is missing. Cleanup refused.'
    warn 'The API identity ConfigMap is absent; continuing only because the marker identifies an incomplete control-plane initialization.'
  fi
  expected_roles["$CONTROL_PLANE_IP"]='platform'
  expected_names["$CONTROL_PLANE_IP"]="$LOCAL_HOSTNAME"
  for index in "${!WORKER_IPS[@]}"; do
    expected_roles["${WORKER_IPS[$index]}"]='gpu-backend'
    expected_names["${WORKER_IPS[$index]}"]="${WORKER_HOSTNAMES[$index]}"
  done

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    node_name="${node#node/}"
    addresses="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get "$node" -o jsonpath='{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}')"
    matched_ip=''
    match_count=0
    for candidate_ip in "${!expected_roles[@]}"; do
      if grep -Fxq "$candidate_ip" <<< "$addresses"; then
        matched_ip="$candidate_ip"
        match_count=$((match_count + 1))
      fi
    done
    (( match_count > 0 )) || die "Unexpected Kubernetes Node $node_name has no configured cluster InternalIP. Cleanup refused."
    (( match_count == 1 )) || die "Kubernetes Node $node_name owns more than one configured cluster InternalIP. Cleanup refused."
    [[ -z "${seen_ips[$matched_ip]:-}" ]] || \
      die "Configured InternalIP $matched_ip is registered by more than one Kubernetes Node. Cleanup refused."
    seen_ips["$matched_ip"]="$node_name"
    expected_name="${expected_names[$matched_ip]}"
    [[ "$node_name" == "$expected_name" ]] || \
      die "Node name mismatch for $matched_ip: API=$node_name, host=$expected_name. Cleanup refused."

    role="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get "$node" -o jsonpath='{.metadata.labels.pactllm-role}')"
    api_cluster_id="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get "$node" -o jsonpath='{.metadata.labels.pactllm-cluster-id}')"
    if [[ -z "$role" && -z "$api_cluster_id" ]]; then
      warn "Node $node_name has no PactLLM identity labels yet; markers and exact host/IP identity match a partial bootstrap."
    else
      [[ "$role" == "${expected_roles[$matched_ip]}" ]] || \
        die "Node $node_name has role '${role:-missing}', expected '${expected_roles[$matched_ip]}'. Cleanup refused."
      [[ "$api_cluster_id" == "$CLUSTER_ID" ]] || \
        die "Node $node_name belongs to cluster ID '${api_cluster_id:-missing}', not '$CLUSTER_ID'. Cleanup refused."
    fi
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes -o name)

  for candidate_ip in "${!expected_roles[@]}"; do
    if [[ -z "${seen_ips[$candidate_ip]:-}" ]]; then
      warn "Marked node $candidate_ip is absent from the API; continuing for partial-cluster cleanup."
    fi
  done
}

confirm_destruction() {
  local confirmation

  [[ -t 0 ]] || die "Interactive confirmation is required. Run this cleanup from a terminal."
  lineprint
  printstyle 'WARNING: This permanently deletes Kubernetes, containerd data/images, the Toolkit installed on GPU backends, GPU Operator, Dynamo, and Gateway foundation.\n' danger
  printstyle "NVIDIA Driver ${EXPECTED_NVIDIA_DRIVER_VERSION} is preserved wherever it is installed.\n" warning
  printf 'Continue with cluster cleanup? [y/N]: '
  read -r -n 1 confirmation
  printf '\n'
  [[ "${confirmation,,}" == 'y' ]] || die 'Cleanup cancelled. Nothing was deleted.'
}

cluster_api_available() {
  command -v kubectl >/dev/null 2>&1 && \
    [[ -f /etc/kubernetes/admin.conf ]] && \
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw='/readyz' --request-timeout=8s 2>/dev/null | grep -Fxq ok
}

delete_namespaced_api_group_resources() {
  local api_group="$1"
  local resource

  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$resource" \
      --all --all-namespaces --wait=true --timeout=180s 2>/dev/null || \
      warn "Timed out deleting $resource objects; node reset will still remove cluster state."
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl api-resources --api-group="$api_group" --namespaced=true -o name 2>/dev/null || true)
}

delete_dynamo_custom_resources() {
  local resource

  # Delete the top-level desired state first while both Dynamo and Gateway
  # controllers are still running, so generated children cannot be recreated.
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$resource" --all --all-namespaces --wait=true --timeout=300s 2>/dev/null || \
      warn "Timed out deleting top-level Dynamo resource $resource."
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl api-resources --api-group=nvidia.com --namespaced=true -o name 2>/dev/null | \
    grep -E '^dynamographdeployments?(\.|$)' || true)

  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$resource" --all --all-namespaces --wait=true --timeout=180s 2>/dev/null || \
      warn "Timed out deleting namespaced Dynamo resource $resource."
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl api-resources --api-group=nvidia.com --namespaced=true -o name 2>/dev/null | \
    grep -E '^(dynamo|podsnapshots?(\.|$)|podsnapshotcontents?(\.|$))' | \
    grep -Ev '^dynamographdeployments?(\.|$)' || true)
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$resource" --all --wait=true --timeout=180s 2>/dev/null || \
      warn "Timed out deleting cluster-scoped Dynamo resource $resource."
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl api-resources --api-group=nvidia.com --namespaced=false -o name 2>/dev/null | \
    grep -E '^(dynamo|podsnapshots?(\.|$)|podsnapshotcontents?(\.|$))' || true)
}

cleanup_cluster_resources() {
  local crd

  lineprint
  if ! cluster_api_available; then
    warn 'Kubernetes API is unavailable. Skipping graceful Helm/API cleanup and continuing with node reset.'
    return 0
  fi

  printstyle 'Removing top-level Dynamo desired state while all controllers are still running ...\n' info
  delete_dynamo_custom_resources

  printstyle 'Removing residual experiment Gateway resources, agentgateway, Gateway API, and GAIE ...\n' info
  # The Dynamo operator can no longer recreate these generated objects after
  # its top-level desired state has been removed.
  delete_namespaced_api_group_resources gateway.networking.k8s.io
  delete_namespaced_api_group_resources inference.networking.k8s.io
  delete_namespaced_api_group_resources inference.networking.x-k8s.io
  delete_namespaced_api_group_resources agentgateway.dev
  if command -v helm >/dev/null 2>&1; then
    if KUBECONFIG=/etc/kubernetes/admin.conf helm status agentgateway -n "$AGENTGATEWAY_NAMESPACE" >/dev/null 2>&1; then
      KUBECONFIG=/etc/kubernetes/admin.conf helm uninstall agentgateway -n "$AGENTGATEWAY_NAMESPACE" --wait --timeout=10m || warn 'agentgateway uninstall reported an error; node reset will continue.'
    fi
    if KUBECONFIG=/etc/kubernetes/admin.conf helm status agentgateway-crds -n "$AGENTGATEWAY_NAMESPACE" >/dev/null 2>&1; then
      KUBECONFIG=/etc/kubernetes/admin.conf helm uninstall agentgateway-crds -n "$AGENTGATEWAY_NAMESPACE" --wait --timeout=10m || warn 'agentgateway CRD uninstall reported an error; explicit CRD cleanup will continue.'
    fi
  fi
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete namespace "$AGENTGATEWAY_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  while IFS= read -r crd; do
    [[ -n "$crd" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$crd" --wait=false 2>/dev/null || true
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get crd -o name 2>/dev/null | grep -E '(gateway\.networking\.k8s\.io|inference\.networking\.(k8s\.io|x-k8s\.io)|agentgateway\.dev)$' || true)

  printstyle 'Removing Dynamo workloads, platform, namespace, and CRDs ...\n' info
  if command -v helm >/dev/null 2>&1 && KUBECONFIG=/etc/kubernetes/admin.conf helm status dynamo-platform -n "$DYNAMO_NAMESPACE" >/dev/null 2>&1; then
    KUBECONFIG=/etc/kubernetes/admin.conf helm uninstall dynamo-platform -n "$DYNAMO_NAMESPACE" --wait --timeout=10m || warn 'Dynamo Helm uninstall reported an error; node reset will still remove etcd state.'
  fi
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete namespace "$DYNAMO_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete pv pactllm-dynamo-nats --ignore-not-found --wait=false 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete storageclass "$DYNAMO_NATS_STORAGE_CLASS" --ignore-not-found 2>/dev/null || true
  while IFS= read -r crd; do
    [[ -n "$crd" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$crd" --wait=false 2>/dev/null || true
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get crd -o name 2>/dev/null | \
    grep -E '/(dynamo.*|podsnapshots?|podsnapshotcontents?)\.nvidia\.com$' || true)

  printstyle 'Removing GPU Operator, RuntimeClass, namespace, and CRDs ...\n' info
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete clusterpolicy --all --wait=true --timeout=300s 2>/dev/null || \
    warn 'GPU ClusterPolicy deletion timed out; Helm uninstall and node reset will continue.'
  if command -v helm >/dev/null 2>&1 && KUBECONFIG=/etc/kubernetes/admin.conf helm status gpu-operator -n gpu-operator >/dev/null 2>&1; then
    KUBECONFIG=/etc/kubernetes/admin.conf helm uninstall gpu-operator -n gpu-operator --wait --timeout=10m || warn 'GPU Operator Helm uninstall reported an error; node reset will still remove etcd state.'
  fi
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete runtimeclass \
    nvidia nvidia-cdi nvidia-legacy --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete namespace gpu-operator --ignore-not-found --wait=false 2>/dev/null || true
  while IFS= read -r crd; do
    [[ -n "$crd" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$crd" --wait=false 2>/dev/null || true
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get crd -o name 2>/dev/null | grep -E '(\.nvidia\.com|\.nfd\.k8s-sigs\.io)$' || true)

  printstyle 'Removing Metrics Server API resources ...\n' info
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system delete deployment metrics-server --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system delete service metrics-server --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system delete serviceaccount metrics-server --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system delete rolebinding metrics-server-auth-reader --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete clusterrole system:aggregated-metrics-reader system:metrics-server --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete clusterrolebinding metrics-server:system:auth-delegator system:metrics-server --ignore-not-found 2>/dev/null || true
  printstyle 'Graceful cluster resource cleanup finished.\n\n' success
}

delete_cni_interfaces() {
  local iface

  for iface in cni0 flannel.1 tunl0 vxlan.calico vxlan-v6.calico wireguard.cali wg-v6.cali; do
    ip link delete "$iface" 2>/dev/null || true
  done
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    ip link delete "$iface" 2>/dev/null || true
  done < <(ip -o link show | awk -F': ' '$2 ~ /^cali/ { split($2, a, "@"); print a[1] }')
}

unmount_bootstrap_mounts() {
  local target

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    printstyle "Unmounting residual Kubernetes/containerd mount: ${target}\n" info
    if ! umount -- "$target" 2>/dev/null; then
      warn "Normal unmount failed for $target; detaching it lazily."
      umount --lazy -- "$target" || die "Failed to detach residual mount $target."
    fi
  done < <(
    findmnt -rn -o TARGET | \
      awk '$0 == "/var/lib/kubelet" || index($0, "/var/lib/kubelet/") == 1 ||
           $0 == "/var/lib/containerd" || index($0, "/var/lib/containerd/") == 1 ||
           $0 == "/run/containerd" || index($0, "/run/containerd/") == 1 ||
           $0 == "/run/calico" || index($0, "/run/calico/") == 1 ||
           $0 == "/var/run/calico" || index($0, "/var/run/calico/") == 1 ||
           $0 ~ /^\/run\/netns\/cni-/ {
             print length($0), $0
           }' | sort -rn | cut -d' ' -f2-
  )

  if findmnt -rn -o TARGET | awk '$0 == "/var/lib/kubelet" || index($0, "/var/lib/kubelet/") == 1 ||
      $0 == "/var/lib/containerd" || index($0, "/var/lib/containerd/") == 1 ||
      $0 == "/run/containerd" || index($0, "/run/containerd/") == 1 ||
      $0 == "/run/calico" || index($0, "/run/calico/") == 1 ||
      $0 == "/var/run/calico" || index($0, "/var/run/calico/") == 1 ||
      $0 ~ /^\/run\/netns\/cni-/ { found = 1 } END { exit !found }'; then
    die 'A Kubernetes/containerd mount is still active; refusing to remove mounted data.'
  fi

  if [[ -d /run/netns ]]; then
    find /run/netns -maxdepth 1 \( -type f -o -type l \) -name 'cni-*' -delete
    rmdir /run/netns 2>/dev/null || true
  fi
}

cleanup_kube_proxy_rules() {
  local image="registry.k8s.io/kube-proxy:v${EXPECTED_KUBERNETES_VERSION}"
  local container_id="pactllm-kube-proxy-cleanup-$$"

  if [[ ! -x /usr/local/bin/ctr ]] || ! systemctl is-active --quiet containerd; then
    warn 'containerd is unavailable; kube-proxy iptables/nftables/IPVS cleanup was skipped.'
    return 0
  fi
  if ! /usr/local/bin/ctr --namespace k8s.io images list -q | grep -Fxq "$image"; then
    /usr/local/bin/ctr --namespace k8s.io images pull "$image" >/dev/null 2>&1 || {
      warn "Could not pull $image; kube-proxy network rules may remain until the next cluster initializes."
      return 0
    }
  fi
  /usr/local/bin/ctr --namespace k8s.io run --rm --privileged --net-host \
    --mount type=bind,src=/lib/modules,dst=/lib/modules,options=rbind:ro \
    "$image" "$container_id" /usr/local/bin/kube-proxy --cleanup >/dev/null 2>&1 || \
    warn 'Pinned kube-proxy cleanup failed; broad iptables flushing was intentionally not attempted.'
}

purge_known_packages() {
  local package
  local known_packages=()

  for package in "$@"; do
    if dpkg-query -W "$package" >/dev/null 2>&1; then
      known_packages+=("$package")
    fi
  done
  if (( ${#known_packages[@]} > 0 )); then
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${known_packages[@]}"
  fi
}

purge_kubernetes_packages() {
  local packages=(kubelet kubeadm kubectl kubernetes-cni cri-tools)

  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  purge_known_packages "${packages[@]}"
  rm -f \
    /etc/apt/sources.list.d/kubernetes.list \
    /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    /usr/share/keyrings/kubernetes-archive-keyring.gpg
}

purge_nvidia_container_toolkit() {
  local packages=(
    nvidia-container-toolkit
    nvidia-container-toolkit-base
    libnvidia-container-tools
    libnvidia-container1
  )

  apt-mark unhold "${packages[@]}" >/dev/null 2>&1 || true
  purge_known_packages "${packages[@]}"
  rm -f \
    /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    /etc/cdi/nvidia.yaml \
    /var/run/cdi/nvidia.yaml
  rm -rf /etc/nvidia-container-runtime
  rmdir /etc/cdi /var/run/cdi 2>/dev/null || true
}

remove_upstream_containerd() {
  local binary
  local binaries=(
    /usr/local/bin/containerd
    /usr/local/bin/containerd-shim
    /usr/local/bin/containerd-shim-runc-v1
    /usr/local/bin/containerd-shim-runc-v2
    /usr/local/bin/containerd-stress
    /usr/local/bin/ctr
  )

  systemctl disable --now containerd >/dev/null 2>&1 || true
  for binary in "${binaries[@]}"; do
    rm -f -- "$binary"
  done
  rm -f /usr/local/lib/systemd/system/containerd.service
  rm -rf /etc/containerd /var/lib/containerd /run/containerd
  purge_known_packages runc containerd containerd.io
  systemctl daemon-reload
  systemctl reset-failed containerd >/dev/null 2>&1 || true
}

verify_node_cleanup() {
  local node_kind="$1"
  local command_name package versions gpu_name driver_version memory_total gpu_count=0
  local removed_commands=(kubeadm kubelet kubectl crictl containerd containerd-stress ctr runc)
  local removed_packages=(
    kubelet
    kubeadm
    kubectl
    kubernetes-cni
    cri-tools
    runc
    containerd
    containerd.io
  )

  if [[ "$node_kind" == 'gpu-backend-worker' ]]; then
    removed_commands+=(nvidia-ctk)
    removed_packages+=(
      nvidia-container-toolkit
      nvidia-container-toolkit-base
      libnvidia-container-tools
      libnvidia-container1
    )
  fi

  for command_name in "${removed_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 && die "$command_name is still installed on this node."
  done
  [[ ! -e /etc/kubernetes ]] || die '/etc/kubernetes still exists.'
  [[ ! -e /etc/containerd ]] || die '/etc/containerd still exists.'
  [[ ! -e /var/lib/containerd ]] || die '/var/lib/containerd still exists.'
  [[ ! -e /etc/cni/net.d ]] || die '/etc/cni/net.d still exists.'
  [[ ! -e /var/lib/kubelet ]] || die '/var/lib/kubelet still exists.'
  [[ ! -e /var/log/calico ]] || die '/var/log/calico still exists.'
  [[ ! -e /run/nodeagent && ! -e /var/run/nodeagent ]] || die 'Calico nodeagent state still exists.'
  if findmnt -rn -o TARGET | grep -Eq '^(/var/lib/kubelet|/var/lib/containerd|/run/containerd|/run/calico|/var/run/calico)(/|$)|^/run/netns/cni-'; then
    die 'A Kubernetes/containerd mount remains after cleanup.'
  fi
  if [[ -d /run/netns ]] && find /run/netns -maxdepth 1 -name 'cni-*' -print -quit | grep -q .; then
    die 'A Kubernetes CNI network namespace handle remains after cleanup.'
  fi
  if ip -o link show | awk -F': ' '{print $2}' | grep -Eq '^(cali|cni0($|@)|tunl0($|@)|vxlan(-v6)?\.calico($|@)|wireguard\.cali($|@)|wg-v6\.cali($|@))'; then
    die 'A Calico/CNI network interface remains after cleanup.'
  fi
  for package in "${removed_packages[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Eq '^(installed|config-files)$'; then
      die "$package was not fully purged."
    fi
  done

  if [[ "$node_kind" == 'gpu-backend-worker' ]]; then
    [[ ! -e /etc/cdi/nvidia.yaml && ! -e /var/run/cdi/nvidia.yaml ]] || die 'An NVIDIA CDI specification remains on the cleaned GPU backend.'
    command -v nvidia-smi >/dev/null 2>&1 || die 'nvidia-smi disappeared; the protected NVIDIA Driver may have been removed.'
    versions="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader)" || die 'The protected NVIDIA Driver is not healthy.'
    [[ -n "$versions" ]] || die 'No NVIDIA GPU was reported after cleanup.'
    while IFS=',' read -r gpu_name driver_version memory_total; do
      gpu_name="${gpu_name#"${gpu_name%%[![:space:]]*}"}"
      gpu_name="${gpu_name%"${gpu_name##*[![:space:]]}"}"
      driver_version="${driver_version#"${driver_version%%[![:space:]]*}"}"
      driver_version="${driver_version%"${driver_version##*[![:space:]]}"}"
      memory_total="${memory_total#"${memory_total%%[![:space:]]*}"}"
      memory_total="${memory_total%"${memory_total##*[![:space:]]}"}"
      memory_total="${memory_total% MiB}"
      [[ "$gpu_name" == "$EXPECTED_NVIDIA_SMI_GPU_NAME" ]] || die "Unexpected protected GPU after cleanup: $gpu_name"
      [[ "$driver_version" == "$EXPECTED_NVIDIA_DRIVER_VERSION" ]] || die "NVIDIA Driver changed during cleanup; expected $EXPECTED_NVIDIA_DRIVER_VERSION."
      [[ "$memory_total" == "$EXPECTED_NVIDIA_GPU_MEMORY_MIB" ]] || die "Unexpected protected GPU memory after cleanup: ${memory_total} MiB."
      gpu_count=$((gpu_count + 1))
    done <<< "$versions"
    (( gpu_count == EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER )) || die 'The protected GPU backend no longer has exactly one RTX 3090.'
  fi
  if [[ "$node_kind" == 'control-plane' ]]; then
    [[ ! -e "$EXPECTED_DYNAMO_NATS_STORAGE_PATH" ]] || die 'Dynamo NATS storage remains on the control plane.'
    [[ ! -e /usr/local/bin/helm ]] || die 'The Helm binary installed by this bootstrap remains on the control plane.'
  fi
}

cleanup_node() {
  local node_kind="$1"

  lineprint
  printstyle "Resetting Kubernetes state on this ${node_kind} node ...\n" info
  if command -v kubeadm >/dev/null 2>&1; then
    kubeadm reset -f --cleanup-tmp-dir --cri-socket "$CRI_SOCKET" || warn 'kubeadm reset reported an error; continuing with explicit cleanup.'
  fi
  systemctl stop kubelet >/dev/null 2>&1 || true

  if command -v crictl >/dev/null 2>&1 && systemctl is-active --quiet containerd; then
    crictl --runtime-endpoint "$CRI_SOCKET" rm -fa >/dev/null 2>&1 || true
    crictl --runtime-endpoint "$CRI_SOCKET" rmp -fa >/dev/null 2>&1 || true
  fi
  cleanup_kube_proxy_rules
  systemctl stop containerd >/dev/null 2>&1 || true
  unmount_bootstrap_mounts

  delete_cni_interfaces
  rm -rf \
    /etc/kubernetes \
    /var/lib/kubelet \
    /etc/cni/net.d \
    /var/lib/cni \
    /var/lib/calico \
    /run/calico \
    /var/run/calico \
    /run/nodeagent \
    /var/run/nodeagent \
    /var/log/calico \
    /var/run/kubernetes \
    /var/log/pods \
    /var/log/containers \
    /opt/cni/bin \
    /etc/systemd/system/kubelet.service.d
  if [[ "$node_kind" == 'control-plane' ]]; then
    [[ "$DYNAMO_NATS_STORAGE_PATH" == "$EXPECTED_DYNAMO_NATS_STORAGE_PATH" ]] || die 'Refusing to remove an unexpected NATS storage path.'
    rm -rf -- /var/lib/etcd "$DYNAMO_NATS_STORAGE_PATH"
  fi
  rm -f \
    /etc/modules-load.d/k8s.conf \
    /etc/sysctl.d/k8s.conf \
    /etc/crictl.yaml \
    /etc/default/kubelet

  printstyle 'Purging Kubernetes packages and repository configuration ...\n' info
  purge_kubernetes_packages
  if [[ "$node_kind" == 'gpu-backend-worker' ]]; then
    printstyle 'Purging NVIDIA Container Toolkit while preserving the NVIDIA Driver ...\n' info
    purge_nvidia_container_toolkit
  fi
  printstyle 'Removing upstream containerd, runtime configuration, images, and data ...\n' info
  remove_upstream_containerd
  apt-get clean

  hash -r
  verify_node_cleanup "$node_kind"
  set_node_cleanup_state_cleaned
  printstyle "${node_kind} node cleanup verified.\n\n" success
}

cleanup_remote_script() {
  local index="$1"
  local target password

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "rm -f -- '${REMOTE_CLEANUP_DIR}/cleanup.sh'; rmdir -- '${REMOTE_CLEANUP_DIR}' 2>/dev/null || true" >/dev/null 2>&1 || true
}

cleanup_remote_worker() {
  local index="$1"
  local target password status=0

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  if [[ "${WORKER_CLEANUP_STATES[$index]}" == 'cleaned' ]]; then
    printstyle "GPU backend worker $target was already cleaned in an earlier run; preserving its tombstone marker.\n" success
    return 0
  fi
  lineprint
  printstyle "Cleaning worker $target ...\n" info

  if ! SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "umask 077; mkdir -p '${REMOTE_CLEANUP_DIR}'" || \
     ! SSHPASS="$password" sshpass -e scp "${SCP_OPTIONS[@]}" "$SCRIPT_PATH" "$target:${REMOTE_CLEANUP_DIR}/cleanup.sh"; then
    cleanup_remote_script "$index"
    die "Failed to transfer the cleanup script to $target. The control plane was not reset."
  fi

  remote_privileged_command "$index" "chmod 700 '${REMOTE_CLEANUP_DIR}/cleanup.sh'; CLEANUP_NODE_ROLE='gpu-backend-worker' CLEANUP_CLUSTER_ID='${CLUSTER_ID}' CLEANUP_NODE_IP='${WORKER_IPS[$index]}' '${REMOTE_CLEANUP_DIR}/cleanup.sh'" || status=$?
  cleanup_remote_script "$index"
  (( status == 0 )) || die "Worker cleanup failed on $target. The control plane was not reset."
  printstyle "GPU backend worker $target cleanup completed; the NVIDIA Driver was preserved.\n\n" success
}

remove_generated_kubeconfig() {
  local home_dir="$1"
  local kubeconfig="${home_dir}/.kube/config"

  [[ -e "$kubeconfig" ]] || return 0
  if [[ -f /etc/kubernetes/admin.conf && -f "$kubeconfig" ]] && cmp -s /etc/kubernetes/admin.conf "$kubeconfig"; then
    rm -f -- "$kubeconfig"
    rmdir -- "$home_dir/.kube/cache" "$home_dir/.kube/http-cache" "$home_dir/.kube" 2>/dev/null || true
  else
    warn "Preserving $kubeconfig because it no longer matches the admin.conf generated by this bootstrap."
  fi
}

cleanup_master_files() {
  remove_generated_kubeconfig /root
  if [[ -n "$REGULAR_USER_HOME" ]]; then
    [[ "$REGULAR_USER_HOME" =~ ^/home/[a-zA-Z0-9._-]+$ ]] || die "Unsafe REGULAR_USER_HOME value: $REGULAR_USER_HOME"
    remove_generated_kubeconfig "$REGULAR_USER_HOME"
  fi
  rm -f /usr/local/bin/helm
  rm -f "$SCRIPT_DIR/cluster-bootstrap-report.txt"
  rm -rf -- "$BOOTSTRAP_STATE_ROOT"
}

main() {
  local cleanup_role="${CLEANUP_NODE_ROLE:-control-plane}"
  local index

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die 'Please run this cleanup script as root.'
  if [[ "$cleanup_role" == 'gpu-backend-worker' ]]; then
    require_config_value CLEANUP_CLUSTER_ID
    require_config_value CLEANUP_NODE_IP
    valid_ipv4 "$CLEANUP_NODE_IP" || die 'Invalid internal cleanup node IP.'
    validate_node_marker_file "$CLEANUP_CLUSTER_ID" "${cleanup_role%-worker}" "$CLEANUP_NODE_IP" || \
      die 'The worker cleanup marker does not match the requested cluster, role, IP, and version.'
    ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$CLEANUP_NODE_IP" || \
      die "This worker does not own CLEANUP_NODE_IP $CLEANUP_NODE_IP."
    if [[ "$(node_cleanup_state)" == 'cleaned' ]]; then
      printstyle "${cleanup_role} was already cleaned successfully; leaving its tombstone marker in place.\n" success
      exit 0
    fi
    cleanup_node "$cleanup_role"
    exit 0
  fi
  [[ "$cleanup_role" == 'control-plane' ]] || die 'Invalid internal cleanup role.'
  (( $# == 0 )) || die 'This cleanup does not accept command-line options. It uses cluster.env.'

  SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
  SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
  CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/cluster.env}"
  NODE_ROLE=''
  CLUSTER_ID=''
  KUBERNETES_VERSION=''
  CONTAINERD_VERSION=''
  CALICO_VERSION=''
  HELM_VERSION=''
  CONTROL_PLANE_IP=''
  POD_CIDR=''
  INSTALL_CALICO=''
  INSTALL_METRICS_SERVER=''
  METRICS_SERVER_VERSION=''
  REGULAR_USER_HOME=''
  GPU_WORKER_COUNT=''
  INSTALL_NVIDIA_STACK=''
  NVIDIA_DRIVER_VERSION=''
  NVIDIA_CONTAINER_TOOLKIT_VERSION=''
  NVIDIA_GPU_MODEL=''
  NVIDIA_GPU_MEMORY_MIB=''
  NVIDIA_GPU_COUNT_PER_WORKER=''
  GPU_OPERATOR_VERSION=''
  INSTALL_DYNAMO_PLATFORM=''
  DYNAMO_PLATFORM_VERSION=''
  DYNAMO_VLLM_VERSION=''
  DYNAMO_VLLM_IMAGE=''
  DYNAMO_NAMESPACE=''
  DYNAMO_NATS_STORAGE_CLASS=''
  DYNAMO_NATS_STORAGE_SIZE=''
  DYNAMO_NATS_STORAGE_PATH=''
  PREPULL_DYNAMO_VLLM_IMAGE=''
  INSTALL_GATEWAY_FOUNDATION=''
  GATEWAY_API_VERSION=''
  GAIE_VERSION=''
  AGENTGATEWAY_VERSION=''
  AGENTGATEWAY_NAMESPACE=''
  declare -g -a WORKER_IPS=()
  declare -g -a WORKER_USERS=()
  declare -g -a WORKER_PASSWORDS=()
  declare -g -a WORKER_HOSTNAMES=()
  declare -g -a WORKER_CLEANUP_STATES=()
  declare -g -a SSH_OPTIONS=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15)
  declare -g -a SCP_OPTIONS=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

  load_config
  for value_name in NODE_ROLE CLUSTER_ID KUBERNETES_VERSION CONTAINERD_VERSION CALICO_VERSION CONTROL_PLANE_IP GPU_WORKER_COUNT METRICS_SERVER_VERSION NVIDIA_DRIVER_VERSION NVIDIA_CONTAINER_TOOLKIT_VERSION NVIDIA_GPU_MEMORY_MIB GPU_OPERATOR_VERSION DYNAMO_PLATFORM_VERSION DYNAMO_NAMESPACE DYNAMO_NATS_STORAGE_CLASS DYNAMO_NATS_STORAGE_SIZE DYNAMO_NATS_STORAGE_PATH GATEWAY_API_VERSION GAIE_VERSION AGENTGATEWAY_VERSION AGENTGATEWAY_NAMESPACE; do
    require_config_value "$value_name"
  done
  validate_fixed_stack
  valid_cluster_id "$CLUSTER_ID" || die 'CLUSTER_ID must be a lowercase RFC 4122 UUID.'
  collect_workers
  LOCAL_HOSTNAME="$(hostname -s)"
  [[ "$LOCAL_HOSTNAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
    die "The control-plane hostname is not a Kubernetes-safe DNS label: $LOCAL_HOSTNAME"
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$CONTROL_PLANE_IP" || \
    die "This host does not own CONTROL_PLANE_IP $CONTROL_PLANE_IP. Cleanup refused."
  validate_node_marker_file "$CLUSTER_ID" platform "$CONTROL_PLANE_IP" || \
    die 'The control-plane marker does not match cluster.env, the platform role, and CONTROL_PLANE_IP. Cleanup refused.'

  command -v sshpass >/dev/null 2>&1 || die 'sshpass is required on the control plane.'
  command -v ssh >/dev/null 2>&1 || die 'ssh is required on the control plane.'
  command -v scp >/dev/null 2>&1 || die 'scp is required on the control plane.'
  prepare_ssh_state
  preflight_remote_workers
  verify_api_inventory_if_available
  if [[ "$(node_cleanup_state)" == 'cleaned' ]]; then
    for index in "${!WORKER_CLEANUP_STATES[@]}"; do
      [[ "${WORKER_CLEANUP_STATES[$index]}" == 'cleaned' ]] || \
        die 'The control plane is marked cleaned but at least one worker is still active; refusing an inconsistent rerun.'
    done
    rm -rf -- "$BOOTSTRAP_STATE_ROOT"
    printstyle 'Cluster cleanup had already completed successfully; all safety tombstone markers are intact.\n' success
    exit 0
  fi
  confirm_destruction

  cleanup_cluster_resources
  for index in "${!WORKER_IPS[@]}"; do
    cleanup_remote_worker "$index"
  done

  lineprint
  printstyle 'All workers are clean. Cleaning the control plane last ...\n' info
  cleanup_master_files
  cleanup_node control-plane

  lineprint
  printstyle 'Cluster cleanup completed successfully.\n' success
  printstyle "Safety tombstones were retained in ${NODE_MARKER_FILE} on all five nodes so an interrupted cleanup remains auditable and rerunnable.\n" success
  printstyle "Preserved component: NVIDIA Driver ${EXPECTED_NVIDIA_DRIVER_VERSION} on all four GPU backends.\n" success
  printstyle 'Not restored automatically: swap configuration and UFW state.\n' warning
  printstyle 'Reboot each worker, then reboot the control plane manually. After reboot, verify nvidia-smi on every GPU backend.\n' warning
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
