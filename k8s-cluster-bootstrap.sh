#!/usr/bin/env bash

set -Eeuo pipefail

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

valid_cidr() {
  local cidr="$1"
  local ip prefix

  [[ "$cidr" == */* ]] || return 1
  ip="${cidr%/*}"
  prefix="${cidr##*/}"
  valid_ipv4 "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
}

validate_bool() {
  local name="$1"
  local value="$2"
  [[ "$value" == 'true' || "$value" == 'false' ]] || die "$name must be true or false."
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

  [[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: $CONFIG_FILE. Copy cluster.env.example to cluster.env first."

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
      NODE_ROLE|CLUSTER_ID|KUBELET_NODE_IP|KUBERNETES_VERSION|CONTAINERD_VERSION|CALICO_VERSION|HELM_VERSION|CONTROL_PLANE_IP|POD_CIDR|INSTALL_CALICO|INSTALL_METRICS_SERVER|METRICS_SERVER_VERSION|REGULAR_USER_HOME|GPU_WORKER_COUNT|JOIN_COMMAND_BASE64|INSTALL_NVIDIA_STACK|NVIDIA_DRIVER_VERSION|NVIDIA_CONTAINER_TOOLKIT_VERSION|NVIDIA_GPU_MODEL|NVIDIA_GPU_MEMORY_MIB|NVIDIA_GPU_COUNT_PER_WORKER|GPU_OPERATOR_VERSION|INSTALL_DYNAMO_PLATFORM|DYNAMO_PLATFORM_VERSION|DYNAMO_VLLM_VERSION|DYNAMO_VLLM_IMAGE|DYNAMO_NAMESPACE|DYNAMO_NATS_STORAGE_CLASS|DYNAMO_NATS_STORAGE_SIZE|DYNAMO_NATS_STORAGE_PATH|PREPULL_DYNAMO_VLLM_IMAGE|INSTALL_GATEWAY_FOUNDATION|GATEWAY_API_VERSION|GAIE_VERSION|AGENTGATEWAY_VERSION|AGENTGATEWAY_NAMESPACE)
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

persist_config_value() {
  local key="$1"
  local value="$2"
  local temp_file owner mode

  [[ "$NODE_ROLE" == 'control-plane' ]] || return 0
  [[ ! -L "$CONFIG_FILE" ]] || die "Refusing to update symlinked configuration file: $CONFIG_FILE"
  temp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  LOCAL_TEMP_PATHS+=("$temp_file")
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!found) {
        print key "=" value
        found = 1
      }
      next
    }
    { print }
    END {
      if (!found) print key "=" value
    }
  ' "$CONFIG_FILE" > "$temp_file"
  owner="$(stat -c '%u:%g' "$CONFIG_FILE")"
  mode="$(stat -c '%a' "$CONFIG_FILE")"
  chown "$owner" "$temp_file"
  chmod "$mode" "$temp_file"
  mv -f -- "$temp_file" "$CONFIG_FILE"
}

local_kubernetes_state_exists() {
  local path

  for path in /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d /var/lib/cni /var/lib/calico; do
    if [[ -e "$path" ]]; then
      if [[ ! -d "$path" ]] || [[ -n "$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

ensure_cluster_id() {
  if [[ -z "$CLUSTER_ID" ]]; then
    [[ "$NODE_ROLE" == 'control-plane' ]] || die 'Worker configuration is missing CLUSTER_ID.'
    [[ "$BOOTSTRAP_MODE" == 'full' && ! -e "$NODE_MARKER_FILE" ]] && ! local_kubernetes_state_exists || \
      die 'CLUSTER_ID is empty, but existing cluster state was detected. Refusing to invent a new identity; restore the matching cluster.env.'
    CLUSTER_ID="$(tr 'A-F' 'a-f' < /proc/sys/kernel/random/uuid)"
    valid_cluster_id "$CLUSTER_ID" || die 'Failed to generate a valid cluster ID.'
    persist_config_value CLUSTER_ID "$CLUSTER_ID"
    printstyle "Generated and saved cluster ID ${CLUSTER_ID} in cluster.env.\n" success
  fi
  valid_cluster_id "$CLUSTER_ID" || die 'CLUSTER_ID must be a lowercase RFC 4122 UUID.'
}

prompt_if_empty() {
  local variable_name="$1"
  local prompt="$2"
  local secret="${3:-false}"
  local value="${!variable_name:-}"

  if [[ -n "$value" ]]; then
    return
  fi
  [[ -t 0 ]] || die "$variable_name is empty and no interactive terminal is available."

  if [[ "$secret" == 'true' ]]; then
    read -r -s -p "$prompt" value
    printf '\n'
  else
    read -r -p "$prompt" value
  fi
  [[ -n "$value" ]] || die "$variable_name cannot be empty."
  printf -v "$variable_name" '%s' "$value"
  persist_config_value "$variable_name" "$value"
}

validate_versions() {
  local version_name canonical_storage_path

  [[ "$KUBERNETES_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'KUBERNETES_VERSION must use X.Y.Z format.'
  [[ "$CONTAINERD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'CONTAINERD_VERSION must use X.Y.Z format.'
  CALICO_VERSION="${CALICO_VERSION#v}"
  [[ "$CALICO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'CALICO_VERSION must use X.Y.Z format.'
  GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION#v}"

  for version_name in HELM_VERSION METRICS_SERVER_VERSION NVIDIA_DRIVER_VERSION NVIDIA_CONTAINER_TOOLKIT_VERSION GPU_OPERATOR_VERSION DYNAMO_PLATFORM_VERSION DYNAMO_VLLM_VERSION; do
    [[ "${!version_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$version_name must use X.Y.Z format."
  done

  [[ "$NVIDIA_GPU_COUNT_PER_WORKER" =~ ^[1-9][0-9]*$ ]] || die 'NVIDIA_GPU_COUNT_PER_WORKER must be a positive integer.'
  [[ "$NVIDIA_GPU_MEMORY_MIB" =~ ^[1-9][0-9]*$ ]] || die 'NVIDIA_GPU_MEMORY_MIB must be a positive integer.'
  [[ "$DYNAMO_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 'DYNAMO_NAMESPACE must be a valid Kubernetes namespace name.'
  [[ "$DYNAMO_VLLM_IMAGE" =~ ^[A-Za-z0-9._:/-]+$ ]] || die 'DYNAMO_VLLM_IMAGE contains unsupported characters.'
  [[ "$DYNAMO_NATS_STORAGE_CLASS" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || die 'DYNAMO_NATS_STORAGE_CLASS must be a valid storage class name.'
  [[ "$DYNAMO_NATS_STORAGE_SIZE" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]] || die 'DYNAMO_NATS_STORAGE_SIZE must use a Kubernetes binary size such as 10Gi.'
  [[ "$DYNAMO_NATS_STORAGE_PATH" =~ ^/var/lib/[A-Za-z0-9._/-]+$ ]] || die 'DYNAMO_NATS_STORAGE_PATH must be an absolute path below /var/lib.'
  canonical_storage_path="$(realpath -m -- "$DYNAMO_NATS_STORAGE_PATH")" || die 'Cannot canonicalize DYNAMO_NATS_STORAGE_PATH.'
  [[ "$DYNAMO_NATS_STORAGE_PATH" == "$canonical_storage_path" && "$canonical_storage_path" == /var/lib/* ]] || \
    die 'DYNAMO_NATS_STORAGE_PATH must be a canonical child path below /var/lib (no .. components).'
  [[ "$GATEWAY_API_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'GATEWAY_API_VERSION must use X.Y.Z format.'
  [[ "$GAIE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'GAIE_VERSION must use X.Y.Z format.'
  [[ "$AGENTGATEWAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'AGENTGATEWAY_VERSION must use X.Y.Z format.'
  [[ "$AGENTGATEWAY_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 'AGENTGATEWAY_NAMESPACE must be a valid Kubernetes namespace name.'

  if [[ "$DYNAMO_PLATFORM_VERSION" == '1.3.0' ]]; then
    [[ "$DYNAMO_VLLM_VERSION" == '0.23.0' ]] || die 'Dynamo Platform 1.3.0 must use the bundled vLLM 0.23.0 runtime.'
    [[ "$DYNAMO_VLLM_IMAGE" == *':1.3.0' ]] || die 'Dynamo Platform 1.3.0 must use a vLLM runtime image pinned to tag 1.3.0.'
  fi

  KUBERNETES_MINOR_VERSION="${KUBERNETES_VERSION%.*}"
  KUBERNETES_PACKAGE_VERSION="${KUBERNETES_VERSION}-1.1"
  CALICO_TAG="v${CALICO_VERSION}"
}

validate_fixed_research_stack() {
  local pair name expected
  local fixed_values=(
    'KUBERNETES_VERSION=1.35.6'
    'CONTAINERD_VERSION=2.2.6'
    'CALICO_VERSION=3.32.1'
    'HELM_VERSION=3.20.0'
    'METRICS_SERVER_VERSION=0.8.1'
    'NVIDIA_DRIVER_VERSION=580.173.02'
    'NVIDIA_CONTAINER_TOOLKIT_VERSION=1.19.1'
    'NVIDIA_GPU_MODEL=RTX 3090'
    'NVIDIA_GPU_MEMORY_MIB=24576'
    'NVIDIA_GPU_COUNT_PER_WORKER=1'
    'GPU_OPERATOR_VERSION=26.3.3'
    'DYNAMO_PLATFORM_VERSION=1.3.0'
    'DYNAMO_VLLM_VERSION=0.23.0'
    'DYNAMO_VLLM_IMAGE=nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0'
    'DYNAMO_NAMESPACE=dynamo-system'
    'DYNAMO_NATS_STORAGE_CLASS=pactllm-local-nats'
    'DYNAMO_NATS_STORAGE_SIZE=10Gi'
    'DYNAMO_NATS_STORAGE_PATH=/var/lib/pactllm/dynamo-nats'
    'GATEWAY_API_VERSION=1.5.1'
    'GAIE_VERSION=1.2.1'
    'AGENTGATEWAY_VERSION=1.0.0'
    'AGENTGATEWAY_NAMESPACE=agentgateway-system'
    'CONTROL_PLANE_IP=192.168.0.10'
    'POD_CIDR=10.244.0.0/16'
    'REGULAR_USER_HOME=/home/dnclab'
    'INSTALL_CALICO=true'
    'INSTALL_METRICS_SERVER=true'
    'INSTALL_NVIDIA_STACK=true'
    'INSTALL_DYNAMO_PLATFORM=true'
    'PREPULL_DYNAMO_VLLM_IMAGE=true'
    'INSTALL_GATEWAY_FOUNDATION=true'
  )

  for pair in "${fixed_values[@]}"; do
    name="${pair%%=*}"
    expected="${pair#*=}"
    [[ "${!name}" == "$expected" ]] || die "$name is fixed to '$expected' for this research cluster."
  done
}

collect_workers() {
  local index ip_var user_var password_var ip user password worker_index
  declare -A seen_ips=()

  prompt_if_empty GPU_WORKER_COUNT 'GPU backend worker node count: '
  [[ "$GPU_WORKER_COUNT" =~ ^[0-9]+$ ]] || die 'GPU_WORKER_COUNT must be zero or a positive integer.'
  GPU_WORKER_COUNT="$((10#$GPU_WORKER_COUNT))"
  (( GPU_WORKER_COUNT == 4 )) || die 'This research topology requires exactly 4 GPU backend workers.'

  for ((index = 1; index <= GPU_WORKER_COUNT; index++)); do
    ip_var="GPU_WORKER_${index}_IP"
    user_var="GPU_WORKER_${index}_SSH_USER"
    password_var="GPU_WORKER_${index}_SSH_PASSWORD"

    prompt_if_empty "$ip_var" "GPU backend worker ${index} IP: "
    prompt_if_empty "$user_var" "GPU backend worker ${index} SSH username: "
    prompt_if_empty "$password_var" "GPU backend worker ${index} SSH/sudo password: " true

    ip="${!ip_var}"
    user="${!user_var}"
    password="${!password_var}"

    valid_ipv4 "$ip" || die "Invalid GPU backend worker IP: $ip"
    [[ "$ip" != "$CONTROL_PLANE_IP" ]] || die "Worker IP cannot equal the control-plane IP: $ip"
    [[ -z "${seen_ips[$ip]:-}" ]] || die "Duplicate worker IP: $ip"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Invalid SSH username for GPU backend worker $index: $user"
    [[ "$user" == 'dnclab' ]] || die "GPU backend worker $index SSH username is fixed to dnclab."
    [[ "$ip" == "192.168.0.$((10 + index))" ]] || \
      die "GPU backend worker $index IP is fixed to 192.168.0.$((10 + index))."
    seen_ips["$ip"]=1

    WORKER_IPS+=("$ip")
    WORKER_USERS+=("$user")
    WORKER_PASSWORDS+=("$password")
    WORKER_ROLES+=('gpu-backend')
    worker_index=$((${#WORKER_IPS[@]} - 1))
    GPU_WORKER_INDICES+=("$worker_index")
  done
}

install_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https ca-certificates curl gnupg openssh-client runc sshpass tar
}

install_orchestration_dependencies() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates openssh-client sshpass
}

host_owns_ipv4() {
  local expected_ip="$1"
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$expected_ip"
}

validate_node_marker_file() {
  local expected_role="$1"
  local expected_ip="$2"

  [[ -f "$NODE_MARKER_FILE" && ! -L "$NODE_MARKER_FILE" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' "$NODE_MARKER_FILE")" == '0:0:600' ]] || return 1
  grep -Fxq "CLUSTER_ID=${CLUSTER_ID}" "$NODE_MARKER_FILE" &&
    grep -Fxq "NODE_ROLE=${expected_role}" "$NODE_MARKER_FILE" &&
    grep -Fxq "NODE_IP=${expected_ip}" "$NODE_MARKER_FILE" &&
    grep -Fxq "KUBERNETES_VERSION=${KUBERNETES_VERSION}" "$NODE_MARKER_FILE" &&
    grep -Fxq 'CLEANUP_STATE=active' "$NODE_MARKER_FILE"
}

control_plane_initialized_state() {
  awk -F= '$1 == "CONTROL_PLANE_INITIALIZED" { print $2; exit }' "$NODE_MARKER_FILE"
}

set_control_plane_initialized() {
  local temp_file

  validate_node_marker_file platform "$CONTROL_PLANE_IP" || \
    die 'Cannot update an invalid control-plane bootstrap marker.'
  temp_file="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$temp_file")
  awk '
    /^CONTROL_PLANE_INITIALIZED=/ {
      if (!done) print "CONTROL_PLANE_INITIALIZED=true"
      done = 1
      next
    }
    { print }
    END { if (!done) print "CONTROL_PLANE_INITIALIZED=true" }
  ' "$NODE_MARKER_FILE" > "$temp_file"
  install -o root -g root -m 0600 "$temp_file" "$NODE_MARKER_FILE"
}

validate_cleaned_node_marker_file() {
  local expected_role="$1"
  local expected_ip="$2"
  local expected_cluster_id="${3:-$CLUSTER_ID}"

  [[ -f "$NODE_MARKER_FILE" && ! -L "$NODE_MARKER_FILE" ]] || return 1
  [[ "$(stat -c '%u:%g:%a' "$NODE_MARKER_FILE")" == '0:0:600' ]] || return 1
  grep -Fxq "CLUSTER_ID=${expected_cluster_id}" "$NODE_MARKER_FILE" &&
    grep -Fxq "NODE_ROLE=${expected_role}" "$NODE_MARKER_FILE" &&
    grep -Fxq "NODE_IP=${expected_ip}" "$NODE_MARKER_FILE" &&
    grep -Fxq "KUBERNETES_VERSION=${KUBERNETES_VERSION}" "$NODE_MARKER_FILE" &&
    grep -Fxq 'CLEANUP_STATE=cleaned' "$NODE_MARKER_FILE"
}

write_node_marker() {
  local role="$1"
  local node_ip="$2"
  local temp_file

  if [[ -e "$NODE_MARKER_FILE" ]]; then
    validate_cleaned_node_marker_file "$role" "$node_ip" || \
      die "An active or foreign bootstrap marker already exists at $NODE_MARKER_FILE. Use --resume or the matching cleanup first."
  fi
  install -d -o root -g root -m 0700 "$NODE_MARKER_DIR"
  temp_file="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$temp_file")
  {
    printf 'CLUSTER_ID=%s\n' "$CLUSTER_ID"
    printf 'NODE_ROLE=%s\n' "$role"
    printf 'NODE_IP=%s\n' "$node_ip"
    printf 'KUBERNETES_VERSION=%s\n' "$KUBERNETES_VERSION"
    printf 'CLEANUP_STATE=active\n'
    if [[ "$role" == 'platform' ]]; then
      printf 'CONTROL_PLANE_INITIALIZED=false\n'
    fi
  } > "$temp_file"
  install -o root -g root -m 0600 "$temp_file" "$NODE_MARKER_FILE"
}

verify_local_host_preflight() {
  local require_unjoined="$1"
  local os_id os_version architecture hostname_short ntp_synced

  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_version="${VERSION_ID:-}"
  architecture="$(dpkg --print-architecture)"
  hostname_short="$(hostname -s)"
  ntp_synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"

  [[ "$os_id" == 'ubuntu' && "$os_version" == '24.04' ]] || die 'The control plane must run Ubuntu 24.04.'
  [[ "$architecture" == 'amd64' ]] || die 'The fixed research stack requires amd64 on every node.'
  [[ "$hostname_short" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Control-plane hostname is not a Kubernetes-safe DNS label: $hostname_short"
  [[ "$ntp_synced" == 'yes' ]] || die 'The control-plane clock is not NTP-synchronized.'
  host_owns_ipv4 "$CONTROL_PLANE_IP" || die "This host does not own CONTROL_PLANE_IP $CONTROL_PLANE_IP."
  [[ "$KUBELET_NODE_IP" == "$CONTROL_PLANE_IP" ]] || die 'KUBELET_NODE_IP must equal CONTROL_PLANE_IP on the control plane.'
  LOCAL_HOSTNAME="$hostname_short"

  if [[ "$require_unjoined" == 'true' ]]; then
    if [[ -e "$NODE_MARKER_FILE" ]]; then
      validate_cleaned_node_marker_file platform "$CONTROL_PLANE_IP" || \
        die "An active or foreign bootstrap marker exists at $NODE_MARKER_FILE. Use --resume or the matching cleanup first."
    fi
    ! local_kubernetes_state_exists || die 'Existing or partial Kubernetes state was detected on the control-plane host. Use the matching cleanup first.'
    if command -v helm >/dev/null 2>&1 || [[ -e /usr/local/bin/helm ]]; then
      die 'Helm is already installed. This bootstrap only manages a clean host without a pre-existing Helm binary.'
    fi
    [[ ! -e "$HOME/.kube/config" ]] || die "Refusing to overwrite an existing kubeconfig: $HOME/.kube/config"
    if [[ -n "$REGULAR_USER_HOME" ]]; then
      [[ "$REGULAR_USER_HOME" =~ ^/home/[a-zA-Z0-9._-]+$ ]] || die "Unsafe REGULAR_USER_HOME value: $REGULAR_USER_HOME"
      [[ -d "$REGULAR_USER_HOME" ]] || die "REGULAR_USER_HOME does not exist: $REGULAR_USER_HOME"
      [[ ! -e "$REGULAR_USER_HOME/.kube/config" ]] || die "Refusing to overwrite an existing kubeconfig: $REGULAR_USER_HOME/.kube/config"
    fi
  else
    validate_node_marker_file platform "$CONTROL_PLANE_IP" || die 'The local bootstrap marker does not match this cluster, platform role, and control-plane IP.'
  fi
}

stage_node_markers() {
  local index role ip command staged=0

  write_node_marker platform "$CONTROL_PLANE_IP"
  for index in "${!WORKER_IPS[@]}"; do
    role="${WORKER_ROLES[$index]}"
    ip="${WORKER_IPS[$index]}"
    command="install -d -o root -g root -m 0700 '${NODE_MARKER_DIR}'; umask 077; printf '%s\\n' 'CLUSTER_ID=${CLUSTER_ID}' 'NODE_ROLE=${role}' 'NODE_IP=${ip}' 'KUBERNETES_VERSION=${KUBERNETES_VERSION}' 'CLEANUP_STATE=active' > '${NODE_MARKER_FILE}'; chown root:root '${NODE_MARKER_FILE}'; chmod 0600 '${NODE_MARKER_FILE}'"
    if ! remote_privileged_command "$index" "$command" || ! verify_remote_marker "$index"; then
      for ((staged = 0; staged <= index; staged++)); do
        remote_privileged_command "$staged" "rm -rf -- '${NODE_MARKER_DIR}'" >/dev/null 2>&1 || true
      done
      rm -rf -- "$NODE_MARKER_DIR"
      die "Failed to stage the bootstrap marker on ${WORKER_USERS[$index]}@${ip}. No cluster installation was started."
    fi
  done
  printstyle "Staged cluster identity ${CLUSTER_ID} on the platform and all four GPU workers.\n" success
}

prepare_ssh_state() {
  install -d -o root -g root -m 0700 "$SSH_STATE_DIR"
  touch "$SSH_KNOWN_HOSTS_FILE"
  chown root:root "$SSH_KNOWN_HOSTS_FILE"
  chmod 0600 "$SSH_KNOWN_HOSTS_FILE"
}

verify_remote_marker() {
  local index="$1"
  local role ip command

  role="${WORKER_ROLES[$index]}"
  ip="${WORKER_IPS[$index]}"
  command="test -f '${NODE_MARKER_FILE}' && test ! -L '${NODE_MARKER_FILE}' && test \"\$(stat -c '%u:%g:%a' '${NODE_MARKER_FILE}')\" = '0:0:600' && grep -Fxq 'CLUSTER_ID=${CLUSTER_ID}' '${NODE_MARKER_FILE}' && grep -Fxq 'NODE_ROLE=${role}' '${NODE_MARKER_FILE}' && grep -Fxq 'NODE_IP=${ip}' '${NODE_MARKER_FILE}' && grep -Fxq 'KUBERNETES_VERSION=${KUBERNETES_VERSION}' '${NODE_MARKER_FILE}' && grep -Fxq 'CLEANUP_STATE=active' '${NODE_MARKER_FILE}'"
  remote_privileged_command "$index" "$command"
}

verify_remote_cleaned_marker() {
  local index="$1"
  local role ip command

  role="${WORKER_ROLES[$index]}"
  ip="${WORKER_IPS[$index]}"
  command="test -f '${NODE_MARKER_FILE}' && test ! -L '${NODE_MARKER_FILE}' && test \"\$(stat -c '%u:%g:%a' '${NODE_MARKER_FILE}')\" = '0:0:600' && grep -Fxq 'CLUSTER_ID=${CLUSTER_ID}' '${NODE_MARKER_FILE}' && grep -Fxq 'NODE_ROLE=${role}' '${NODE_MARKER_FILE}' && grep -Fxq 'NODE_IP=${ip}' '${NODE_MARKER_FILE}' && grep -Fxq 'KUBERNETES_VERSION=${KUBERNETES_VERSION}' '${NODE_MARKER_FILE}' && grep -Fxq 'CLEANUP_STATE=cleaned' '${NODE_MARKER_FILE}'"
  remote_privileged_command "$index" "$command"
}

preflight_remote_gpu() {
  local index="$1"
  local target password inventory line gpu_name driver_version memory_total gpu_count=0

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  if ! inventory="$(SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" \
    "nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader")"; then
    die "nvidia-smi failed on $target. Install and load the host NVIDIA driver first."
  fi

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    IFS=',' read -r gpu_name driver_version memory_total <<< "$line"
    gpu_name="${gpu_name#"${gpu_name%%[![:space:]]*}"}"
    gpu_name="${gpu_name%"${gpu_name##*[![:space:]]}"}"
    driver_version="${driver_version#"${driver_version%%[![:space:]]*}"}"
    driver_version="${driver_version%"${driver_version##*[![:space:]]}"}"
    memory_total="${memory_total#"${memory_total%%[![:space:]]*}"}"
    memory_total="${memory_total%"${memory_total##*[![:space:]]}"}"
    memory_total="${memory_total% MiB}"

    [[ "$gpu_name" == "$NVIDIA_SMI_GPU_NAME" ]] || die "Unexpected GPU on $target: $gpu_name (expected $NVIDIA_SMI_GPU_NAME)."
    [[ "$driver_version" == "$NVIDIA_DRIVER_VERSION" ]] || die "Unexpected NVIDIA driver on $target: $driver_version (expected $NVIDIA_DRIVER_VERSION)."
    [[ "$memory_total" == "$NVIDIA_GPU_MEMORY_MIB" ]] || die "Unexpected GPU memory on $target: ${memory_total} MiB (expected ${NVIDIA_GPU_MEMORY_MIB} MiB)."
    gpu_count=$((gpu_count + 1))
  done <<< "$inventory"

  (( gpu_count == NVIDIA_GPU_COUNT_PER_WORKER )) || \
    die "Worker $target has $gpu_count GPUs; expected $NVIDIA_GPU_COUNT_PER_WORKER."
  printstyle "GPU preflight passed on $target: ${gpu_count}x ${NVIDIA_GPU_MODEL} (${NVIDIA_GPU_MEMORY_MIB} MiB), driver ${NVIDIA_DRIVER_VERSION}.\n" success
}

preflight_remote_access() {
  local require_unjoined="${1:-true}"
  local index target password user facts facts_command os_id os_version architecture hostname_short owned_ip ntp_synced remote_epoch local_epoch skew
  declare -A seen_hostnames=(["$LOCAL_HOSTNAME"]=1)

  for index in "${!WORKER_IPS[@]}"; do
    target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
    password="${WORKER_PASSWORDS[$index]}"
    user="${WORKER_USERS[$index]}"
    printstyle "Checking SSH and sudo access to $target ...\n" info

    if ! SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" 'true'; then
      die "Cannot connect to $target using the configured password."
    fi
    if [[ "$user" != 'root' ]] && ! printf '%s\n' "$password" | SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "sudo -S -p '' true"; then
      die "Configured account cannot run sudo on $target with the same password."
    fi
    facts_command='set -eu; . /etc/os-release; owned_ip=no; '
    facts_command+="ip -4 -o addr show | awk '{print \$4}' | cut -d/ -f1 | grep -Fxq '${WORKER_IPS[$index]}' && owned_ip=yes; "
    facts_command+='printf '\''%s|%s|%s|%s|%s|%s|%s\n'\'' "${ID:-}" "${VERSION_ID:-}" "$(dpkg --print-architecture)" "$(hostname -s)" "$owned_ip" "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" "$(date +%s)"'
    facts="$(remote_privileged_command "$index" "$facts_command")" || \
      die "Cannot collect host facts from $target."
    IFS='|' read -r os_id os_version architecture hostname_short owned_ip ntp_synced remote_epoch <<< "$facts"
    [[ "$os_id" == 'ubuntu' && "$os_version" == '24.04' ]] || die "$target must run Ubuntu 24.04."
    [[ "$architecture" == 'amd64' ]] || die "$target must use amd64."
    [[ "$hostname_short" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "Worker hostname is not a Kubernetes-safe DNS label: $hostname_short"
    [[ -z "${seen_hostnames[$hostname_short]:-}" ]] || die "Duplicate node hostname detected: $hostname_short"
    seen_hostnames["$hostname_short"]=1
    WORKER_HOSTNAMES[$index]="$hostname_short"
    [[ "$owned_ip" == 'yes' ]] || die "$target does not own configured IP ${WORKER_IPS[$index]}."
    [[ "$ntp_synced" == 'yes' ]] || die "$target is not NTP-synchronized."
    [[ "$remote_epoch" =~ ^[0-9]+$ ]] || die "Cannot read the clock on $target."
    local_epoch="$(date +%s)"
    skew=$((local_epoch - remote_epoch))
    (( skew < 0 )) && skew=$((-skew))
    (( skew <= MAX_CLOCK_SKEW_SECONDS )) || die "$target clock differs from the control plane by ${skew}s (maximum ${MAX_CLOCK_SKEW_SECONDS}s)."
    if [[ "$require_unjoined" == 'true' ]] && ! remote_privileged_command "$index" \
      'for path in /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d /var/lib/cni /var/lib/calico; do if [ -e "$path" ] && { [ ! -d "$path" ] || [ -n "$(find "$path" -mindepth 1 -print -quit 2>/dev/null)" ]; }; then exit 1; fi; done'; then
      die "Worker $target already has existing or partial Kubernetes state. Refusing to overwrite it."
    fi
    if [[ "$require_unjoined" == 'true' ]]; then
      if ! remote_privileged_command "$index" "test ! -e '${NODE_MARKER_FILE}'"; then
        verify_remote_cleaned_marker "$index" || die "Worker $target has an active or foreign bootstrap marker. Use --resume or the matching cleanup first."
      fi
    else
      verify_remote_marker "$index" || die "Worker $target has no matching root-owned cluster marker. Refusing to resume against it."
    fi
    if [[ "$INSTALL_NVIDIA_STACK" == 'true' ]]; then
      preflight_remote_gpu "$index"
    fi
  done
}

disable_swap_and_firewall() {
  lineprint
  printstyle 'Disabling swap and UFW ...\n' info
  swapoff -a
  sed -i '/^[[:space:]]*#/! { /[[:space:]]swap[[:space:]]/ s/^/#/; }' /etc/fstab
  if command -v ufw >/dev/null 2>&1; then
    ufw disable
  fi
  printstyle 'Success!\n\n' success
}

remove_conflicting_packages() {
  local packages=(
    docker.io docker-doc docker-compose docker-ce docker-ce-cli
    docker-ce-rootless-extras podman-docker containerd containerd.io
  )
  local package installed_packages=()

  lineprint
  printstyle 'Removing conflicting runtime packages ...\n' info
  for package in "${packages[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Fxq installed; then
      installed_packages+=("$package")
    fi
  done
  if (( ${#installed_packages[@]} > 0 )); then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y "${installed_packages[@]}"
  fi
  printstyle 'Success!\n\n' success
}

install_containerd() {
  local architecture archive release_url temp_dir service_file

  lineprint
  printstyle "Installing exact containerd v${CONTAINERD_VERSION} ...\n" info

  architecture="$(dpkg --print-architecture)"
  case "$architecture" in
    amd64|arm64) ;;
    *) die "Unsupported architecture for containerd: $architecture" ;;
  esac

  archive="containerd-${CONTAINERD_VERSION}-linux-${architecture}.tar.gz"
  release_url="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}"
  temp_dir="$(mktemp -d)"
  LOCAL_TEMP_PATHS+=("$temp_dir")

  curl -fsSL -o "$temp_dir/$archive" "$release_url/$archive" || die "Failed to download containerd v${CONTAINERD_VERSION}."
  curl -fsSL -o "$temp_dir/$archive.sha256sum" "$release_url/$archive.sha256sum" || die "Failed to download the containerd checksum."
  (cd "$temp_dir" && sha256sum -c "$archive.sha256sum") || die "containerd v${CONTAINERD_VERSION} checksum verification failed."

  tar -C /usr/local -xzf "$temp_dir/$archive"
  service_file='/usr/local/lib/systemd/system/containerd.service'
  mkdir -p "$(dirname "$service_file")"
  curl -fsSL -o "$service_file" "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service" || die 'Failed to download the pinned containerd systemd service.'

  mkdir -p /etc/containerd
  /usr/local/bin/containerd config default > /etc/containerd/config.toml
  sed -i 's/            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml
  sed -i -E "s#^([[:space:]]*sandbox = ).*#\\1'${SANDBOX_IMAGE}'#" /etc/containerd/config.toml
  grep -Fxq 'version = 3' /etc/containerd/config.toml || die 'containerd 2.x config version 3 was not generated.'
  grep -Fq 'SystemdCgroup = true' /etc/containerd/config.toml || die 'Failed to enable SystemdCgroup in containerd.'
  grep -Fq "sandbox = '${SANDBOX_IMAGE}'" /etc/containerd/config.toml || die 'Failed to configure the Kubernetes pause image in containerd.'
  grep -Fq "default_runtime_name = 'runc'" /etc/containerd/config.toml || die 'containerd default runtime must remain runc.'
  grep -Fq 'enable_cdi = true' /etc/containerd/config.toml || die 'containerd native CDI support is not enabled.'

  systemctl daemon-reload
  systemctl enable --now containerd
  /usr/local/bin/containerd --version | grep -Fq "v${CONTAINERD_VERSION}" || die "Installed containerd version is not v${CONTAINERD_VERSION}."
  printstyle 'Success!\n\n' success
}

install_nvidia_container_toolkit() {
  local keyring='/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
  local repository='/etc/apt/sources.list.d/nvidia-container-toolkit.list'
  local package_version="${NVIDIA_CONTAINER_TOOLKIT_VERSION}-1"
  local package
  local packages=(
    nvidia-container-toolkit
    nvidia-container-toolkit-base
    libnvidia-container-tools
    libnvidia-container1
  )

  if [[ "$INSTALL_NVIDIA_STACK" != 'true' ]]; then
    return 0
  fi
  lineprint
  printstyle "Installing exact NVIDIA Container Toolkit v${NVIDIA_CONTAINER_TOOLKIT_VERSION} ...\n" info

  command -v nvidia-smi >/dev/null 2>&1 || die 'nvidia-smi is not installed on this GPU worker.'
  nvidia-smi >/dev/null || die 'The NVIDIA driver is not healthy on this GPU worker.'

  curl -fsSL 'https://nvidia.github.io/libnvidia-container/gpgkey' | gpg --yes --dearmor -o "$keyring"
  curl -fsSL 'https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list' | \
    sed "s#deb https://#deb [signed-by=${keyring}] https://#g" > "$repository"
  apt-get update

  for package in "${packages[@]}"; do
    apt-cache madison "$package" | awk '{print $3}' | grep -Fxq "$package_version" || \
      die "$package package version $package_version was not found in the NVIDIA repository."
  done

  apt-mark unhold "${packages[@]}" >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    "nvidia-container-toolkit=$package_version" \
    "nvidia-container-toolkit-base=$package_version" \
    "libnvidia-container-tools=$package_version" \
    "libnvidia-container1=$package_version"
  apt-mark hold "${packages[@]}"

  nvidia-ctk runtime configure --runtime=containerd
  [[ -f /etc/containerd/conf.d/99-nvidia.toml ]] || die 'The NVIDIA containerd drop-in configuration was not created.'
  systemctl restart nvidia-cdi-refresh.service || die 'Failed to generate the NVIDIA CDI specification.'
  [[ -s /var/run/cdi/nvidia.yaml || -s /etc/cdi/nvidia.yaml ]] || die 'The NVIDIA CDI specification was not generated.'
  systemctl restart containerd
  systemctl is-active --quiet containerd || die 'containerd failed after NVIDIA runtime configuration.'

  nvidia-ctk --version | grep -Fq "$NVIDIA_CONTAINER_TOOLKIT_VERSION" || die 'Installed NVIDIA Container Toolkit version does not match cluster.env.'
  /usr/local/bin/containerd config dump | grep -Eq "default_runtime_name = ['\"]runc['\"]" || die 'containerd default runtime is not runc.'
  /usr/local/bin/containerd config dump | grep -Fq 'nvidia-container-runtime' || die 'The NVIDIA runtime handler was not registered in containerd.'
  nvidia-ctk cdi list | grep -Fq 'nvidia.com/gpu=' || die 'The NVIDIA CDI specification does not expose any GPU devices.'
  nvidia-container-cli info >/dev/null || die 'NVIDIA Container Toolkit cannot query the host GPU.'
  printstyle 'NVIDIA Container Toolkit and CDI configuration succeeded; runc remains the default runtime.\n\n' success
}

install_kubernetes() {
  local keyring='/etc/apt/keyrings/kubernetes-apt-keyring.gpg'
  local repository='/etc/apt/sources.list.d/kubernetes.list'
  local component

  lineprint
  printstyle "Installing exact Kubernetes v${KUBERNETES_VERSION} ...\n" info

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR_VERSION}/deb/Release.key" | gpg --yes --dearmor -o "$keyring"
  printf 'deb [signed-by=%s] https://pkgs.k8s.io/core:/stable:/v%s/deb/ /\n' "$keyring" "$KUBERNETES_MINOR_VERSION" > "$repository"
  apt-get update

  for component in kubeadm kubelet kubectl; do
    apt-cache madison "$component" | awk '{print $3}' | grep -Fxq "$KUBERNETES_PACKAGE_VERSION" || \
      die "$component package $KUBERNETES_PACKAGE_VERSION was not found in the v${KUBERNETES_MINOR_VERSION} repository."
  done

  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades \
    "kubelet=$KUBERNETES_PACKAGE_VERSION" \
    "kubeadm=$KUBERNETES_PACKAGE_VERSION" \
    "kubectl=$KUBERNETES_PACKAGE_VERSION"
  apt-mark hold kubelet kubeadm kubectl

  printf 'KUBELET_EXTRA_ARGS=--node-ip=%s\n' "$KUBELET_NODE_IP" > /etc/default/kubelet
  systemctl daemon-reload
  systemctl restart kubelet >/dev/null 2>&1 || true

  kubeadm version -o short | grep -Fxq "v${KUBERNETES_VERSION}" || die 'Installed kubeadm version does not match cluster.env.'
  kubelet --version | grep -Fxq "Kubernetes v${KUBERNETES_VERSION}" || die 'Installed kubelet version does not match cluster.env.'
  printstyle 'Success!\n\n' success
}

configure_kernel() {
  lineprint
  printstyle 'Configuring kernel modules and sysctl values ...\n' info

  cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system
  printstyle 'Success!\n\n' success
}

install_node_components() {
  disable_swap_and_firewall
  remove_conflicting_packages
  install_dependencies
  install_containerd
  install_kubernetes
  configure_kernel
}

configure_kubeconfig() {
  local target_home uid_gid

  mkdir -p "$HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  if [[ -n "$REGULAR_USER_HOME" ]]; then
    target_home="$REGULAR_USER_HOME"
    [[ -d "$target_home" ]] || die "REGULAR_USER_HOME does not exist: $target_home"
    uid_gid="$(stat -c '%u:%g' "$target_home")"
    mkdir -p "$target_home/.kube"
    cp -f /etc/kubernetes/admin.conf "$target_home/.kube/config"
    chown "$uid_gid" "$target_home/.kube" "$target_home/.kube/config"
  fi
}

cluster_identity_configmap_matches() {
  local identity

  identity="$(KUBECONFIG=/etc/kubernetes/admin.conf kubectl -n kube-system get configmap pactllm-cluster-identity \
    -o jsonpath='{.data.cluster_id}{"|"}{.data.control_plane_ip}{"|"}{.data.kubernetes_version}' 2>/dev/null || true)"
  [[ "$identity" == "${CLUSTER_ID}|${CONTROL_PLANE_IP}|${KUBERNETES_VERSION}" ]]
}

record_cluster_identity_configmap() {
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: pactllm-cluster-identity
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: pactllm-bootstrap
data:
  cluster_id: "${CLUSTER_ID}"
  control_plane_ip: "${CONTROL_PLANE_IP}"
  kubernetes_version: "${KUBERNETES_VERSION}"
EOF
  cluster_identity_configmap_matches || die 'Failed to persist the Kubernetes API cluster identity.'
}

initialize_control_plane() {
  local init_args

  [[ ! -e /etc/kubernetes/admin.conf ]] || die 'An existing Kubernetes control plane was detected. Refusing to overwrite it.'

  lineprint
  printstyle 'Initializing the control plane ...\n' info
  init_args=(
    "--kubernetes-version=v${KUBERNETES_VERSION}"
    "--apiserver-advertise-address=${CONTROL_PLANE_IP}"
    "--cri-socket=${CRI_SOCKET}"
    '--skip-token-print'
  )
  if [[ "$INSTALL_CALICO" == 'true' ]]; then
    init_args+=("--pod-network-cidr=${POD_CIDR}")
  fi
  kubeadm init "${init_args[@]}"
  configure_kubeconfig
  record_cluster_identity_configmap
  set_control_plane_initialized
  printstyle 'Control plane initialized.\n\n' success
}

install_calico() {
  local manifest

  if [[ "$INSTALL_CALICO" != 'true' ]]; then
    return 0
  fi
  lineprint
  printstyle "Installing exact Calico v${CALICO_VERSION} ...\n" info

  manifest="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$manifest")
  curl -fsSL -o "$manifest" "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_TAG}/manifests/calico.yaml" || die "Failed to download Calico ${CALICO_TAG}."
  sed -i \
    -e 's|^            # - name: CALICO_IPV4POOL_CIDR$|            - name: CALICO_IPV4POOL_CIDR|' \
    -e "s|^            #   value: \"192.168.0.0/16\"$|              value: \"${POD_CIDR}\"|" \
    -e '/^              value: "autodetect"$/a\            - name: IP_AUTODETECTION_METHOD\n              value: "kubernetes-internal-ip"' \
    "$manifest"
  grep -Fxq '            - name: CALICO_IPV4POOL_CIDR' "$manifest" || die 'Failed to enable CALICO_IPV4POOL_CIDR in the manifest.'
  grep -Fxq "              value: \"${POD_CIDR}\"" "$manifest" || die 'Failed to set the configured Calico Pod CIDR.'
  grep -Fxq '            - name: IP_AUTODETECTION_METHOD' "$manifest" || die 'Failed to set Calico IP autodetection.'
  grep -Fxq '              value: "kubernetes-internal-ip"' "$manifest" || die 'Calico must follow the Kubernetes InternalIP on multi-NIC hosts.'
  kubectl apply -f "$manifest"
  pin_system_deployment_to_platform calico-kube-controllers
  printstyle 'Calico manifest applied.\n\n' success
}

install_metrics_server() {
  local manifest

  if [[ "$INSTALL_METRICS_SERVER" != 'true' ]]; then
    return 0
  fi
  lineprint
  printstyle 'Installing metrics-server ...\n' info
  manifest="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$manifest")
  curl -fsSL -o "$manifest" "https://github.com/kubernetes-sigs/metrics-server/releases/download/v${METRICS_SERVER_VERSION}/components.yaml" || \
    die "Failed to download metrics-server v${METRICS_SERVER_VERSION}."
  sed -i '/--metric-resolution=15s/a\        - --kubelet-insecure-tls' "$manifest"
  kubectl apply -f "$manifest"
  pin_system_deployment_to_platform metrics-server
  printstyle "metrics-server v${METRICS_SERVER_VERSION} manifest applied.\n\n" success
}

node_name_for_ip() {
  local target_ip="$1"
  local node addresses match='' match_count=0

  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    addresses="$(kubectl get "$node" -o jsonpath='{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}')"
    if grep -Fxq "$target_ip" <<< "$addresses"; then
      match="${node#node/}"
      match_count=$((match_count + 1))
    fi
  done < <(kubectl get nodes -o name)
  (( match_count == 1 )) || return 1
  printf '%s\n' "$match"
}

label_platform_node() {
  local control_plane_node

  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die "No Kubernetes node owns control-plane IP $CONTROL_PLANE_IP."
  kubectl label node "$control_plane_node" \
    pactllm-role=platform \
    pactllm-cluster-id="$CLUSTER_ID" \
    nvidia.com/gpu.deploy.operands=false \
    --overwrite
}

pin_system_deployment_to_platform() {
  local deployment="$1"

  kubectl -n kube-system patch deployment "$deployment" --type=strategic -p \
    '{"spec":{"template":{"spec":{"nodeSelector":{"pactllm-role":"platform"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}' >/dev/null
}

pin_core_cluster_services() {
  label_platform_node
  pin_system_deployment_to_platform coredns
}

label_cluster_nodes() {
  local control_plane_node index worker_node gpu_ordinal=0

  lineprint
  printstyle 'Applying fixed research node roles before GPU Operator installation ...\n' info
  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die "No Kubernetes node owns control-plane IP $CONTROL_PLANE_IP."
  kubectl label node "$control_plane_node" \
    pactllm-role=platform \
    pactllm-cluster-id="$CLUSTER_ID" \
    nvidia.com/gpu.deploy.operands=false \
    --overwrite

  for index in "${!WORKER_IPS[@]}"; do
    worker_node="$(node_name_for_ip "${WORKER_IPS[$index]}")" || die "No Kubernetes node owns worker IP ${WORKER_IPS[$index]}."
    gpu_ordinal=$((gpu_ordinal + 1))
    kubectl label node "$worker_node" \
      pactllm-role=gpu-backend \
      pactllm-cluster-id="$CLUSTER_ID" \
      pactllm-backend-index="$gpu_ordinal" \
      pactllm-gpu-model=rtx3090 \
      --overwrite
    kubectl label node "$worker_node" nvidia.com/gpu.deploy.operands- 2>/dev/null || true
  done

  [[ "$(kubectl get nodes -l pactllm-role=platform --no-headers | wc -l | tr -d '[:space:]')" == '1' ]] || die 'Expected exactly one platform node.'
  [[ "$(kubectl get nodes -l pactllm-role=gpu-backend --no-headers | wc -l | tr -d '[:space:]')" == "$GPU_WORKER_COUNT" ]] || die 'GPU backend node labeling failed.'
  [[ "$(kubectl get nodes -l "pactllm-cluster-id=${CLUSTER_ID}" --no-headers | wc -l | tr -d '[:space:]')" == "$((GPU_WORKER_COUNT + 1))" ]] || \
    die 'Cluster identity labeling failed.'
  printstyle 'Node roles and stable experiment indices applied: 1 platform and GPU backends 1-4.\n\n' success
}

prepare_dynamo_nats_storage() {
  local control_plane_node

  if [[ "$INSTALL_DYNAMO_PLATFORM" != 'true' ]]; then
    return 0
  fi
  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die 'Cannot resolve the platform node for NATS storage.'
  install -d -m 0750 "$DYNAMO_NATS_STORAGE_PATH"

  lineprint
  printstyle "Preparing pinned local NATS JetStream storage at ${DYNAMO_NATS_STORAGE_PATH} ...\n" info
  kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${DYNAMO_NATS_STORAGE_CLASS}
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pactllm-dynamo-nats
spec:
  capacity:
    storage: ${DYNAMO_NATS_STORAGE_SIZE}
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ${DYNAMO_NATS_STORAGE_CLASS}
  local:
    path: ${DYNAMO_NATS_STORAGE_PATH}
  nodeAffinity:
    required:
      nodeSelectorTerms:
        - matchExpressions:
            - key: kubernetes.io/hostname
              operator: In
              values:
                - ${control_plane_node}
EOF
  printstyle 'NATS JetStream local storage is ready.\n\n' success
}

install_helm() {
  local architecture archive release_url temp_dir expected_checksum actual_checksum

  lineprint
  printstyle "Installing exact Helm v${HELM_VERSION} ...\n" info
  install -d -o root -g root -m 0700 "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
  architecture="$(dpkg --print-architecture)"
  case "$architecture" in
    amd64|arm64) ;;
    *) die "Unsupported architecture for Helm: $architecture" ;;
  esac

  archive="helm-v${HELM_VERSION}-linux-${architecture}.tar.gz"
  release_url="https://get.helm.sh/${archive}"
  temp_dir="$(mktemp -d)"
  LOCAL_TEMP_PATHS+=("$temp_dir")

  curl -fsSL -o "$temp_dir/$archive" "$release_url" || die "Failed to download Helm v${HELM_VERSION}."
  curl -fsSL -o "$temp_dir/$archive.sha256sum" "$release_url.sha256sum" || die 'Failed to download the Helm checksum.'
  expected_checksum="$(awk '{print $1}' "$temp_dir/$archive.sha256sum")"
  actual_checksum="$(sha256sum "$temp_dir/$archive" | awk '{print $1}')"
  [[ -n "$expected_checksum" && "$actual_checksum" == "$expected_checksum" ]] || die "Helm v${HELM_VERSION} checksum verification failed."

  tar -C "$temp_dir" -xzf "$temp_dir/$archive"
  install -m 0755 "$temp_dir/linux-${architecture}/helm" /usr/local/bin/helm
  helm version --short | grep -Fq "v${HELM_VERSION}" || die 'Installed Helm version does not match cluster.env.'
  printstyle 'Helm installation succeeded.\n\n' success
}

wait_for_cluster_policy() {
  local deadline state

  deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    state="$(kubectl get clusterpolicy cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || true)"
    if [[ "${state,,}" == 'ready' ]]; then
      return
    fi
    sleep 10
  done
  die "GPU Operator ClusterPolicy did not become ready (last state: ${state:-missing})."
}

verify_gpu_resources() {
  local inventory line node_name role gpu_count gpu_nodes=0 total_gpus=0
  local expected_total=$((GPU_WORKER_COUNT * NVIDIA_GPU_COUNT_PER_WORKER))

  inventory="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.metadata.labels.pactllm-role}{"="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}')" || \
    die 'Failed to read allocatable NVIDIA GPU resources.'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    node_name="${line%%=*}"
    role="${line#*=}"
    role="${role%%=*}"
    gpu_count="${line##*=}"
    if [[ "$role" == 'gpu-backend' ]]; then
      [[ "$gpu_count" =~ ^[0-9]+$ ]] || die "GPU backend $node_name does not expose an NVIDIA GPU resource."
      (( gpu_count == NVIDIA_GPU_COUNT_PER_WORKER )) || \
        die "GPU backend $node_name exposes $gpu_count GPUs; expected $NVIDIA_GPU_COUNT_PER_WORKER."
      gpu_nodes=$((gpu_nodes + 1))
      total_gpus=$((total_gpus + gpu_count))
    elif [[ "$role" == 'platform' ]]; then
      [[ -z "$gpu_count" || "$gpu_count" == '0' ]] || die "Platform node $node_name unexpectedly exposes $gpu_count NVIDIA GPUs."
    else
      die "Node $node_name has an unexpected or missing pactllm-role label: ${role:-missing}"
    fi
  done <<< "$inventory"

  (( gpu_nodes == GPU_WORKER_COUNT )) || die "Kubernetes reports $gpu_nodes GPU backend nodes; expected $GPU_WORKER_COUNT."
  (( total_gpus == expected_total )) || die "Kubernetes reports $total_gpus allocatable GPUs; expected $expected_total."
  printstyle "Kubernetes GPU resources verified: ${gpu_nodes} RTX 3090 backend nodes and ${total_gpus} GPUs; platform GPUs exposed: 0.\n" success
}

install_gpu_operator() {
  local deployment daemonset control_plane_node operator_node

  if [[ "$INSTALL_NVIDIA_STACK" != 'true' ]]; then
    return 0
  fi
  [[ -f "$GPU_OPERATOR_VALUES_FILE" ]] || die "GPU Operator values file not found: $GPU_OPERATOR_VALUES_FILE"
  lineprint
  printstyle "Installing exact GPU Operator v${GPU_OPERATOR_VERSION} ...\n" info

  helm repo add nvidia 'https://helm.ngc.nvidia.com/nvidia' --force-update
  helm repo update nvidia
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    --version="v${GPU_OPERATOR_VERSION}" \
    --values "$GPU_OPERATOR_VALUES_FILE" \
    --wait \
    --timeout=15m

  wait_for_cluster_policy
  while IFS= read -r deployment; do
    [[ -n "$deployment" ]] || continue
    kubectl -n gpu-operator rollout status "$deployment" --timeout=900s
  done < <(kubectl -n gpu-operator get deployment -o name)
  while IFS= read -r daemonset; do
    [[ -n "$daemonset" ]] || continue
    kubectl -n gpu-operator rollout status "$daemonset" --timeout=900s
  done < <(kubectl -n gpu-operator get daemonset -o name)

  helm get values gpu-operator -n gpu-operator | grep -A1 '^driver:' | grep -Fq 'enabled: false' || die 'GPU Operator driver.enabled is not false.'
  helm get values gpu-operator -n gpu-operator | grep -A1 '^toolkit:' | grep -Fq 'enabled: false' || die 'GPU Operator toolkit.enabled is not false.'
  kubectl get runtimeclass nvidia >/dev/null || die 'GPU Operator did not create the nvidia RuntimeClass.'
  [[ "$(kubectl get runtimeclass nvidia -o jsonpath='{.handler}')" == 'nvidia' ]] || die 'The nvidia RuntimeClass has an unexpected handler.'
  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die 'Cannot resolve the platform node for GPU Operator placement verification.'
  operator_node="$(kubectl -n gpu-operator get pod -l app.kubernetes.io/component=gpu-operator -o jsonpath='{.items[0].spec.nodeName}')"
  [[ "$operator_node" == "$control_plane_node" ]] || die "GPU Operator controller was scheduled outside the platform node: $operator_node"
  verify_gpu_resources
  printstyle 'GPU Operator, CDI, RuntimeClass, and GPU resource verification succeeded.\n\n' success
}

install_dynamo_platform() {
  local chart_url chart_metadata resource images control_plane_node nats_pvc_status

  if [[ "$INSTALL_DYNAMO_PLATFORM" != 'true' ]]; then
    return 0
  fi
  [[ -f "$DYNAMO_PLATFORM_VALUES_FILE" ]] || die "Dynamo Platform values file not found: $DYNAMO_PLATFORM_VALUES_FILE"
  lineprint
  printstyle "Installing exact Dynamo Platform v${DYNAMO_PLATFORM_VERSION} ...\n" info

  chart_url="https://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform-${DYNAMO_PLATFORM_VERSION}.tgz"
  chart_metadata="$(helm show chart "$chart_url")" || die "Dynamo Platform chart v${DYNAMO_PLATFORM_VERSION} was not found at the NVIDIA release URL."
  grep -Fxq 'name: dynamo-platform' <<< "$chart_metadata" || die 'Downloaded Dynamo chart has an unexpected name.'
  grep -Fxq "version: ${DYNAMO_PLATFORM_VERSION}" <<< "$chart_metadata" || die 'Downloaded Dynamo chart version does not match cluster.env.'

  helm upgrade --install dynamo-platform \
    "$chart_url" \
    --namespace "$DYNAMO_NAMESPACE" \
    --create-namespace \
    --values "$DYNAMO_PLATFORM_VALUES_FILE" \
    --set global.etcd.install=false \
    --set global.nats.install=true \
    --set-string "nats.config.jetstream.fileStore.pvc.storageClassName=${DYNAMO_NATS_STORAGE_CLASS}" \
    --set-string "nats.config.jetstream.fileStore.pvc.size=${DYNAMO_NATS_STORAGE_SIZE}" \
    --wait \
    --timeout=15m

  helm status dynamo-platform -n "$DYNAMO_NAMESPACE" >/dev/null
  kubectl get crd dynamographdeployments.nvidia.com >/dev/null || die 'DynamoGraphDeployment CRD was not installed.'
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    kubectl -n "$DYNAMO_NAMESPACE" rollout status "$resource" --timeout=900s
  done < <(kubectl -n "$DYNAMO_NAMESPACE" get deployment,statefulset \
    -l app.kubernetes.io/instance=dynamo-platform -o name)

  images="$(kubectl -n "$DYNAMO_NAMESPACE" get pods -l app.kubernetes.io/instance=dynamo-platform -o jsonpath='{..image}')" || die 'Failed to inspect Dynamo Platform images.'
  grep -Fq "kubernetes-operator:${DYNAMO_PLATFORM_VERSION}" <<< "$images" || \
    die "Dynamo Kubernetes Operator image is not pinned to ${DYNAMO_PLATFORM_VERSION}."
  if kubectl -n "$DYNAMO_NAMESPACE" get pods -l app.kubernetes.io/instance=dynamo-platform -o name | grep -Fq 'etcd'; then
    die 'Dynamo etcd was deployed even though Kubernetes-native discovery is required.'
  fi
  kubectl -n "$DYNAMO_NAMESPACE" get statefulset -o name | grep -Fq 'nats' || die 'Dynamo bundled NATS StatefulSet was not installed.'
  nats_pvc_status="$(kubectl -n "$DYNAMO_NAMESPACE" get pvc -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"\n"}{end}' | grep -E 'nats.*=Bound$' || true)"
  [[ -n "$nats_pvc_status" ]] || die 'The NATS JetStream PVC is not Bound.'

  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die 'Cannot resolve the platform node for Dynamo placement verification.'
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    [[ "$resource" == "$control_plane_node" ]] || die "A Dynamo Platform pod was scheduled outside the platform node: $resource"
  done < <(kubectl -n "$DYNAMO_NAMESPACE" get pods -l app.kubernetes.io/instance=dynamo-platform -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
  printstyle 'Dynamo Operator and bundled NATS JetStream are ready on the platform node; Dynamo etcd is disabled.\n\n' success
}

install_gateway_foundation() {
  local gateway_manifest gaie_manifest deployment control_plane_node pod_node

  if [[ "$INSTALL_GATEWAY_FOUNDATION" != 'true' ]]; then
    return 0
  fi
  [[ -f "$AGENTGATEWAY_VALUES_FILE" ]] || die "agentgateway values file not found: $AGENTGATEWAY_VALUES_FILE"

  lineprint
  printstyle "Installing Gateway API v${GATEWAY_API_VERSION}, GAIE v${GAIE_VERSION}, and agentgateway v${AGENTGATEWAY_VERSION} ...\n" info
  gateway_manifest="$(mktemp)"
  gaie_manifest="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$gateway_manifest" "$gaie_manifest")
  curl -fsSL -o "$gateway_manifest" \
    "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/standard-install.yaml" || \
    die "Failed to download Gateway API v${GATEWAY_API_VERSION}."
  curl -fsSL -o "$gaie_manifest" \
    "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v${GAIE_VERSION}/manifests.yaml" || \
    die "Failed to download GAIE v${GAIE_VERSION}."

  kubectl apply --server-side --force-conflicts -f "$gateway_manifest"
  kubectl apply -f "$gaie_manifest"
  kubectl wait --for=condition=Established crd/gateways.gateway.networking.k8s.io --timeout=180s
  kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=180s
  kubectl wait --for=condition=Established crd/inferencepools.inference.networking.k8s.io --timeout=180s

  helm upgrade --install agentgateway-crds \
    oci://cr.agentgateway.dev/charts/agentgateway-crds \
    --namespace "$AGENTGATEWAY_NAMESPACE" \
    --create-namespace \
    --version "v${AGENTGATEWAY_VERSION}" \
    --wait \
    --timeout=10m
  helm upgrade --install agentgateway \
    oci://cr.agentgateway.dev/charts/agentgateway \
    --namespace "$AGENTGATEWAY_NAMESPACE" \
    --version "v${AGENTGATEWAY_VERSION}" \
    --values "$AGENTGATEWAY_VALUES_FILE" \
    --wait \
    --timeout=10m

  while IFS= read -r deployment; do
    [[ -n "$deployment" ]] || continue
    kubectl -n "$AGENTGATEWAY_NAMESPACE" rollout status "$deployment" --timeout=600s
  done < <(kubectl -n "$AGENTGATEWAY_NAMESPACE" get deployment \
    -l app.kubernetes.io/instance=agentgateway -o name)
  kubectl wait --for=condition=Accepted gatewayclass/agentgateway --timeout=180s || die 'agentgateway GatewayClass was not accepted.'
  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die 'Cannot resolve the platform node for agentgateway placement verification.'
  while IFS= read -r pod_node; do
    [[ -n "$pod_node" ]] || continue
    [[ "$pod_node" == "$control_plane_node" ]] || die "An agentgateway controller pod was scheduled outside the platform node: $pod_node"
  done < <(kubectl -n "$AGENTGATEWAY_NAMESPACE" get pods -l app.kubernetes.io/instance=agentgateway -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}')
  if kubectl get gateway --all-namespaces -o name 2>/dev/null | grep -q .; then
    if [[ "$BOOTSTRAP_MODE" == 'full' ]]; then
      die 'A Gateway instance already exists; the foundation bootstrap must not create experiment instances.'
    fi
    printstyle 'Existing experiment Gateway instances were preserved during resume.\n' warning
  fi
  printstyle 'Gateway API, GAIE, agentgateway controller, and GatewayClass are ready; no Gateway instance was created.\n\n' success
}

remote_gpu_runtime_stack_is_exact() {
  local index="$1"
  local package_version="${NVIDIA_CONTAINER_TOOLKIT_VERSION}-1"
  local command

  command="set -eu; nvidia-ctk --version | grep -F '${NVIDIA_CONTAINER_TOOLKIT_VERSION}' >/dev/null; "
  command+="for package in nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1; do "
  command+="test \"\$(dpkg-query -W -f='\${Version}' \"\$package\" 2>/dev/null)\" = '${package_version}'; "
  command+="apt-mark showhold | grep -Fx \"\$package\" >/dev/null; done; "
  command+="test -s /var/run/cdi/nvidia.yaml -o -s /etc/cdi/nvidia.yaml; "
  command+="/usr/local/bin/containerd config dump | grep -Eq \"default_runtime_name = ['\\\"]runc['\\\"]\"; "
  command+="/usr/local/bin/containerd config dump | grep -F 'nvidia-container-runtime' >/dev/null; "
  command+="nvidia-ctk cdi list | grep -F 'nvidia.com/gpu=' >/dev/null"
  remote_privileged_command "$index" "$command" >/dev/null 2>&1
}

worker_node_versions_and_identity_match() {
  local index="$1"
  local node_name kubelet_version runtime_version

  node_name="$(node_name_for_ip "${WORKER_IPS[$index]}")" || return 1
  [[ "$node_name" == "${WORKER_HOSTNAMES[$index]}" ]] || return 1
  kubelet_version="$(kubectl get node "$node_name" -o jsonpath='{.status.nodeInfo.kubeletVersion}')"
  runtime_version="$(kubectl get node "$node_name" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')"
  [[ "$kubelet_version" == "v${KUBERNETES_VERSION}" && "$runtime_version" == "containerd://${CONTAINERD_VERSION}" ]]
}

worker_node_is_ready() {
  local index="$1"
  local node_name ready_status

  worker_node_versions_and_identity_match "$index" || return 1
  node_name="${WORKER_HOSTNAMES[$index]}"
  ready_status="$(kubectl get node "$node_name" -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')"
  [[ "$ready_status" == 'True' ]] || return 1
  if [[ "${WORKER_ROLES[$index]}" == 'gpu-backend' ]]; then
    remote_gpu_runtime_stack_is_exact "$index" || return 1
  fi
}

reconcile_workers() {
  local join_command index node_name deadline
  local -a missing_indices=()

  for index in "${!WORKER_IPS[@]}"; do
    if worker_node_is_ready "$index"; then
      printstyle "Worker ${WORKER_IPS[$index]} is already registered and Ready; preserving it.\n" success
      continue
    fi
    if worker_node_versions_and_identity_match "$index"; then
      printstyle "Worker ${WORKER_IPS[$index]} is temporarily NotReady; allowing a bounded recovery window.\n" warning
      remote_privileged_command "$index" 'systemctl restart containerd; systemctl restart kubelet' >/dev/null 2>&1 || true
      deadline=$((SECONDS + 120))
      until worker_node_is_ready "$index"; do
        (( SECONDS < deadline )) || break
        sleep 5
      done
      if worker_node_is_ready "$index"; then
        printstyle "Worker ${WORKER_IPS[$index]} recovered without reset.\n" success
        continue
      fi
    fi
    missing_indices+=("$index")
  done
  (( ${#missing_indices[@]} > 0 )) || return 0

  join_command="$(kubeadm token create --print-join-command) --cri-socket=${CRI_SOCKET}"
  [[ -n "$join_command" ]] || die 'Failed to create a worker join command during resume.'
  for index in "${missing_indices[@]}"; do
    if node_name="$(node_name_for_ip "${WORKER_IPS[$index]}" 2>/dev/null)"; then
      kubectl delete node "$node_name" --wait=true --timeout=120s || die "Failed to remove stale Node object $node_name."
    fi
    remote_privileged_command "$index" \
      "if command -v kubeadm >/dev/null 2>&1; then kubeadm reset -f --cleanup-tmp-dir --cri-socket '${CRI_SOCKET}' || exit 1; fi; systemctl stop kubelet >/dev/null 2>&1 || true; for iface in cni0 tunl0 vxlan.calico vxlan-v6.calico wireguard.cali wg-v6.cali; do ip link delete \"\$iface\" 2>/dev/null || true; done; ip -o link show | awk -F': ' '\$2 ~ /^cali/ { split(\$2, a, \"@\"); print a[1] }' | while read -r iface; do ip link delete \"\$iface\" 2>/dev/null || true; done; rm -rf /etc/kubernetes /etc/cni/net.d /var/lib/cni /var/lib/calico /var/run/calico" || \
      die "Failed to reset the marked partial worker ${WORKER_IPS[$index]}."
    install_remote_worker "$index" "$join_command"
  done
}

resume_cluster_bootstrap() {
  local deadline control_plane_state

  lineprint
  printstyle 'Reconciling and resuming the existing marked research cluster ...\n' info

  verify_local_host_preflight false
  install_orchestration_dependencies
  prepare_ssh_state
  preflight_remote_access false
  control_plane_state="$(control_plane_initialized_state)"
  if [[ -z "$control_plane_state" ]]; then
    if [[ -f /etc/kubernetes/admin.conf ]] && command -v kubectl >/dev/null 2>&1 && \
       KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw='/readyz' --request-timeout=10s 2>/dev/null | grep -Fxq ok && \
       cluster_identity_configmap_matches; then
      printstyle 'Migrating a healthy legacy marker to the explicit control-plane phase format.\n' warning
      set_control_plane_initialized
      control_plane_state='true'
    else
      die 'The marker has no control-plane phase and the API is unavailable. Refusing an unsafe automatic reset; use the matching cleanup first.'
    fi
  fi
  [[ "$control_plane_state" == 'true' || "$control_plane_state" == 'false' ]] || \
    die "Invalid CONTROL_PLANE_INITIALIZED state in $NODE_MARKER_FILE."
  if [[ "$control_plane_state" == 'true' && -f /etc/kubernetes/admin.conf ]] && \
     KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw='/readyz' --request-timeout=10s 2>/dev/null | grep -Fxq ok; then
    cluster_identity_configmap_matches || \
      die 'The live Kubernetes API does not carry the cluster identity from cluster.env. Refusing to touch an unrelated cluster.'
  fi
  if [[ "$control_plane_state" == 'false' ]]; then
    printstyle 'The marked control plane stopped before kubeadm init completed; rebuilding its local foundation.\n' warning
    if command -v kubeadm >/dev/null 2>&1; then
      kubeadm reset -f --cleanup-tmp-dir --cri-socket "$CRI_SOCKET" || die 'Cannot reset the partial marked control plane.'
    fi
    systemctl stop kubelet >/dev/null 2>&1 || true
    rm -rf /etc/kubernetes /etc/cni/net.d /var/lib/etcd
    rm -f /root/.kube/config
    if [[ -n "$REGULAR_USER_HOME" ]]; then
      rm -f -- "$REGULAR_USER_HOME/.kube/config"
    fi
    install_node_components
    initialize_control_plane
  fi
  export KUBECONFIG=/etc/kubernetes/admin.conf
  command -v kubectl >/dev/null 2>&1 || die 'Cannot resume: kubectl is not installed.'
  systemctl restart containerd >/dev/null 2>&1 || true
  systemctl restart kubelet >/dev/null 2>&1 || true
  deadline=$((SECONDS + 120))
  until kubectl get --raw='/readyz' --request-timeout=10s 2>/dev/null | grep -Fxq ok; do
    (( SECONDS < deadline )) || die 'Cannot resume: the Kubernetes API did not become ready within 120 seconds.'
    sleep 5
  done
  cluster_identity_configmap_matches || \
    die 'The live Kubernetes API does not carry the cluster identity from cluster.env. Refusing to mutate an unrelated cluster.'
  pin_core_cluster_services
  install_calico
  install_metrics_server
  reconcile_workers
  verify_cluster
  label_cluster_nodes
  verify_cross_node_network
  if ! command -v helm >/dev/null 2>&1 || ! helm version --short 2>/dev/null | grep -Fq "v${HELM_VERSION}"; then
    install_helm
  fi
  install_gpu_operator
  prepare_dynamo_nats_storage
  install_dynamo_platform
  install_gateway_foundation
  prepull_dynamo_vllm_runtime
  verify_gpu_runtime_smoke
  verify_infrastructure_placement
  write_environment_report

  lineprint
  printstyle 'Cluster resume completed successfully. No DGD or inference workload was applied.\n' success
  printstyle "Prepared runtime: ${DYNAMO_VLLM_IMAGE} (bundled vLLM ${DYNAMO_VLLM_VERSION}).\n" success
}

prepull_dynamo_vllm_runtime() {
  local index target pull_command

  if [[ "$INSTALL_DYNAMO_PLATFORM" != 'true' || "$PREPULL_DYNAMO_VLLM_IMAGE" != 'true' ]]; then
    return 0
  fi
  lineprint
  printstyle "Pre-pulling Dynamo vLLM runtime image on every GPU worker: ${DYNAMO_VLLM_IMAGE} ...\n" info
  for index in "${GPU_WORKER_INDICES[@]}"; do
    target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
    printstyle "Pulling runtime image on $target ...\n" info
    pull_command="/usr/local/bin/ctr --namespace k8s.io images pull '${DYNAMO_VLLM_IMAGE}' && /usr/local/bin/ctr --namespace k8s.io images list -q | grep -Fx '${DYNAMO_VLLM_IMAGE}'"
    remote_privileged_command "$index" "$pull_command" >/dev/null || die "Failed to pre-pull ${DYNAMO_VLLM_IMAGE} on $target."
  done
  printstyle "Dynamo vLLM runtime image is present on all ${GPU_WORKER_COUNT} GPU workers (bundled vLLM ${DYNAMO_VLLM_VERSION}).\n\n" success
}

cleanup_gpu_smoke_pods() {
  local selector remaining

  for selector in \
    'app.kubernetes.io/name=pactllm-gpu-smoke' \
    'app.kubernetes.io/name=pactllm-gpu-runtimeclass-smoke'; do
    kubectl -n kube-system delete pod \
      -l "$selector" \
      --ignore-not-found \
      --wait=true \
      --timeout=120s >/dev/null 2>&1 || \
      die "Failed to delete old GPU smoke pods for selector $selector."
    remaining="$(kubectl -n kube-system get pod -l "$selector" --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
    [[ "$remaining" == '0' ]] || die "Old GPU smoke pods still exist for selector $selector."
  done
}

verify_gpu_runtime_smoke() {
  local index ordinal=0 node_name pod_name deadline phases succeeded output gpu_output gpu_name driver_version memory_total actual_vllm actual_cuda image_id expected_image_id=''

  if [[ "$INSTALL_NVIDIA_STACK" != 'true' ]]; then
    return 0
  fi

  lineprint
  printstyle 'Running native-CDI and explicit RuntimeClass GPU/vLLM smoke pods on every backend ...\n' info
  cleanup_gpu_smoke_pods
  for index in "${GPU_WORKER_INDICES[@]}"; do
    ordinal=$((ordinal + 1))
    node_name="$(node_name_for_ip "${WORKER_IPS[$index]}")" || die "Cannot resolve GPU backend ${WORKER_IPS[$index]} for the smoke test."
    pod_name="pactllm-gpu-smoke-${ordinal}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: kube-system
  labels:
    app.kubernetes.io/name: pactllm-gpu-smoke
spec:
  restartPolicy: Never
  nodeName: ${node_name}
  containers:
    - name: runtime-check
      image: ${DYNAMO_VLLM_IMAGE}
      imagePullPolicy: IfNotPresent
      command:
        - /bin/sh
        - -c
      args:
        - |
          set -eu
          python3 -c 'import sys, torch, vllm; print("VLLM_VERSION=" + vllm.__version__); print("CUDA_VERSION=" + str(torch.version.cuda)); sys.exit(0 if vllm.__version__ == "${DYNAMO_VLLM_VERSION}" and str(torch.version.cuda) == "13.0" else 1)'
          nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits | sed 's/^/GPU=/'
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
  done

  deadline=$((SECONDS + 900))
  while (( SECONDS < deadline )); do
    phases="$(kubectl -n kube-system get pods -l app.kubernetes.io/name=pactllm-gpu-smoke -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}')"
    if grep -Fxq Failed <<< "$phases"; then
      kubectl -n kube-system describe pods -l app.kubernetes.io/name=pactllm-gpu-smoke || true
      cleanup_gpu_smoke_pods
      die 'At least one native-CDI GPU/vLLM smoke pod failed.'
    fi
    succeeded="$(grep -Fxc Succeeded <<< "$phases" || true)"
    if [[ "$succeeded" == "$GPU_WORKER_COUNT" ]]; then
      break
    fi
    sleep 5
  done
  [[ "${succeeded:-0}" == "$GPU_WORKER_COUNT" ]] || {
    kubectl -n kube-system describe pods -l app.kubernetes.io/name=pactllm-gpu-smoke || true
    cleanup_gpu_smoke_pods
    die 'Native-CDI GPU/vLLM smoke pods did not complete before the timeout.'
  }

  while IFS= read -r pod_name; do
    [[ -n "$pod_name" ]] || continue
    output="$(kubectl -n kube-system logs "$pod_name")" || {
      cleanup_gpu_smoke_pods
      die "Cannot read GPU smoke output from $pod_name."
    }
    actual_vllm="$(sed -n 's/^VLLM_VERSION=//p' <<< "$output")"
    actual_cuda="$(sed -n 's/^CUDA_VERSION=//p' <<< "$output")"
    gpu_output="$(sed -n 's/^GPU=//p' <<< "$output")"
    [[ "$actual_vllm" == "$DYNAMO_VLLM_VERSION" ]] || {
      cleanup_gpu_smoke_pods
      die "Unexpected vLLM version from $pod_name: ${actual_vllm:-missing}"
    }
    [[ "$actual_cuda" == '13.0' ]] || {
      cleanup_gpu_smoke_pods
      die "Unexpected CUDA runtime from $pod_name: ${actual_cuda:-missing}; expected CUDA 13.0."
    }
    IFS=',' read -r gpu_name driver_version memory_total <<< "$gpu_output"
    gpu_name="${gpu_name#"${gpu_name%%[![:space:]]*}"}"
    driver_version="${driver_version#"${driver_version%%[![:space:]]*}"}"
    driver_version="${driver_version%"${driver_version##*[![:space:]]}"}"
    memory_total="${memory_total#"${memory_total%%[![:space:]]*}"}"
    memory_total="${memory_total%"${memory_total##*[![:space:]]}"}"
    if [[ "$gpu_name" != "$NVIDIA_SMI_GPU_NAME" || "$driver_version" != "$NVIDIA_DRIVER_VERSION" || "$memory_total" != "$NVIDIA_GPU_MEMORY_MIB" ]]; then
      cleanup_gpu_smoke_pods
      die "Unexpected GPU smoke output from $pod_name: $gpu_output"
    fi
    image_id="$(kubectl -n kube-system get "$pod_name" -o jsonpath='{.status.containerStatuses[0].imageID}')"
    [[ -n "$image_id" ]] || {
      cleanup_gpu_smoke_pods
      die "The pulled image digest is missing for $pod_name."
    }
    if [[ -z "$expected_image_id" ]]; then
      expected_image_id="$image_id"
    elif [[ "$image_id" != "$expected_image_id" ]]; then
      cleanup_gpu_smoke_pods
      die "GPU workers resolved ${DYNAMO_VLLM_IMAGE} to different image digests."
    fi
    DYNAMO_VLLM_IMAGE_IDS+="${pod_name}=${image_id};"
  done < <(kubectl -n kube-system get pods -l app.kubernetes.io/name=pactllm-gpu-smoke -o name)

  ordinal=0
  for index in "${GPU_WORKER_INDICES[@]}"; do
    ordinal=$((ordinal + 1))
    node_name="$(node_name_for_ip "${WORKER_IPS[$index]}")" || die "Cannot resolve GPU backend ${WORKER_IPS[$index]} for the RuntimeClass smoke test."
    pod_name="pactllm-gpu-runtimeclass-smoke-${ordinal}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: kube-system
  labels:
    app.kubernetes.io/name: pactllm-gpu-runtimeclass-smoke
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  nodeName: ${node_name}
  containers:
    - name: nvidia-smi
      image: ${DYNAMO_VLLM_IMAGE}
      imagePullPolicy: IfNotPresent
      command: [/bin/sh, -c]
      args: ['nvidia-smi --query-gpu=name --format=csv,noheader']
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
  done
  if ! kubectl -n kube-system wait --for=jsonpath='{.status.phase}'=Succeeded pod \
    -l app.kubernetes.io/name=pactllm-gpu-runtimeclass-smoke --timeout=600s; then
    kubectl -n kube-system describe pods -l app.kubernetes.io/name=pactllm-gpu-runtimeclass-smoke || true
    cleanup_gpu_smoke_pods
    die 'At least one explicit nvidia RuntimeClass smoke pod failed.'
  fi
  while IFS= read -r pod_name; do
    [[ -n "$pod_name" ]] || continue
    [[ "$(kubectl -n kube-system logs "$pod_name")" == "$NVIDIA_SMI_GPU_NAME" ]] || {
      cleanup_gpu_smoke_pods
      die "The explicit nvidia RuntimeClass did not expose the exact expected GPU in $pod_name."
    }
  done < <(kubectl -n kube-system get pods -l app.kubernetes.io/name=pactllm-gpu-runtimeclass-smoke -o name)

  cleanup_gpu_smoke_pods
  printstyle "Native CDI and RuntimeClass nvidia succeeded on all ${GPU_WORKER_COUNT} GPU backends; vLLM ${DYNAMO_VLLM_VERSION} and CUDA 13.0 were verified.\n\n" success
}

write_environment_report() {
  local report_file temp_file owner index target password

  report_file="$SCRIPT_DIR/cluster-bootstrap-report.txt"
  temp_file="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$temp_file")
  {
    printf 'PactLLM research cluster bootstrap report\n'
    printf 'generated_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'cluster_id=%s\n' "$CLUSTER_ID"
    printf 'control_plane_ip=%s\n' "$CONTROL_PLANE_IP"
    printf 'clock_policy=all nodes NTP synchronized, maximum observed preflight skew <= %ss\n' "$MAX_CLOCK_SKEW_SECONDS"
    printf 'topology=1 platform + %s gpu-backend\n' "$GPU_WORKER_COUNT"
    printf 'kubernetes=%s\ncontainerd=%s\ncalico=%s\nhelm=%s\nmetrics_server=%s\n' "$KUBERNETES_VERSION" "$CONTAINERD_VERSION" "$CALICO_VERSION" "$HELM_VERSION" "$METRICS_SERVER_VERSION"
    printf 'nvidia_driver=%s\nnvidia_container_toolkit=%s\ngpu_operator=%s\n' "$NVIDIA_DRIVER_VERSION" "$NVIDIA_CONTAINER_TOOLKIT_VERSION" "$GPU_OPERATOR_VERSION"
    printf 'dynamo_platform=%s\ndynamo_vllm=%s\ndynamo_vllm_image=%s\n' "$DYNAMO_PLATFORM_VERSION" "$DYNAMO_VLLM_VERSION" "$DYNAMO_VLLM_IMAGE"
    printf 'dynamo_vllm_image_ids=%s\n' "$DYNAMO_VLLM_IMAGE_IDS"
    printf 'validated_cuda_runtime=13.0\n'
    printf 'gateway_api=%s\ngaie=%s\nagentgateway=%s\n' "$GATEWAY_API_VERSION" "$GAIE_VERSION" "$AGENTGATEWAY_VERSION"
    printf '\n[NODES]\n'
    kubectl get nodes -L pactllm-role,pactllm-backend-index,pactllm-gpu-model -o wide
    printf '\n[GPU ALLOCATABLE]\n'
    kubectl get nodes -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.pactllm-role,GPU:.status.allocatable.nvidia\.com/gpu'
    printf '\n[RUNTIME CLASSES]\n'
    kubectl get runtimeclass
    printf '\n[HELM RELEASES]\n'
    helm list --all-namespaces
    printf '\n[PLATFORM STORAGE]\n'
    kubectl get storageclass "$DYNAMO_NATS_STORAGE_CLASS"
    kubectl get pv pactllm-dynamo-nats
    kubectl -n "$DYNAMO_NAMESPACE" get pvc
    printf '\n[PLATFORM PODS]\n'
    kubectl -n "$DYNAMO_NAMESPACE" get pods -o wide
    kubectl -n "$AGENTGATEWAY_NAMESPACE" get pods -o wide
    printf '\n[GATEWAY FOUNDATION]\n'
    kubectl get gatewayclass
    kubectl get gateway --all-namespaces 2>/dev/null || true
    printf '\n[REMOTE GPU INVENTORY]\n'
    for index in "${!WORKER_IPS[@]}"; do
      target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
      password="${WORKER_PASSWORDS[$index]}"
      printf '%s role=%s\n' "$target" "${WORKER_ROLES[$index]}"
      SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" \
        "nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || printf 'no-host-gpu-or-driver\\n'" || \
        printf 'inventory-unavailable\n'
    done
  } > "$temp_file"

  install -m 0644 "$temp_file" "$report_file"
  owner="$(stat -c '%u:%g' "$SCRIPT_DIR")"
  chown "$owner" "$report_file"
  printstyle "Environment report written to ${report_file}.\n" success
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

cleanup_remote_worker_files() {
  local index="$1"
  local remote_dir="$2"
  remote_privileged_command "$index" "rm -f -- '${remote_dir}/bootstrap.sh' '${remote_dir}/worker.env'; rmdir -- '${remote_dir}' 2>/dev/null || true" >/dev/null 2>&1 || true
}

install_remote_worker() {
  local index="$1"
  local join_command="$2"
  local target password remote_dir local_config join_base64 remote_command status worker_role

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  remote_dir="/tmp/k8s-cluster-bootstrap-${KUBERNETES_VERSION//./-}"
  local_config="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$local_config")
  join_base64="$(printf '%s' "$join_command" | base64 -w0)"
  worker_role="${WORKER_ROLES[$index]}"
  [[ "$worker_role" == 'gpu-backend' ]] || die "Unexpected worker role for ${WORKER_IPS[$index]}: $worker_role"

  {
    printf 'NODE_ROLE=%s-worker\n' "$worker_role"
    printf 'CLUSTER_ID=%s\n' "$CLUSTER_ID"
    printf 'KUBELET_NODE_IP=%s\n' "${WORKER_IPS[$index]}"
    printf 'KUBERNETES_VERSION=%s\n' "$KUBERNETES_VERSION"
    printf 'CONTAINERD_VERSION=%s\n' "$CONTAINERD_VERSION"
    printf 'CALICO_VERSION=%s\n' "$CALICO_VERSION"
    printf 'HELM_VERSION=%s\n' "$HELM_VERSION"
    printf 'CONTROL_PLANE_IP=%s\n' "$CONTROL_PLANE_IP"
    printf 'POD_CIDR=%s\n' "$POD_CIDR"
    printf 'INSTALL_CALICO=%s\n' "$INSTALL_CALICO"
    printf 'INSTALL_METRICS_SERVER=false\n'
    printf 'METRICS_SERVER_VERSION=%s\n' "$METRICS_SERVER_VERSION"
    printf 'REGULAR_USER_HOME=\n'
    printf 'GPU_WORKER_COUNT=0\n'
    printf 'INSTALL_NVIDIA_STACK=%s\n' "$INSTALL_NVIDIA_STACK"
    printf 'NVIDIA_DRIVER_VERSION=%s\n' "$NVIDIA_DRIVER_VERSION"
    printf 'NVIDIA_CONTAINER_TOOLKIT_VERSION=%s\n' "$NVIDIA_CONTAINER_TOOLKIT_VERSION"
    printf 'NVIDIA_GPU_MODEL=%s\n' "$NVIDIA_GPU_MODEL"
    printf 'NVIDIA_GPU_MEMORY_MIB=%s\n' "$NVIDIA_GPU_MEMORY_MIB"
    printf 'NVIDIA_GPU_COUNT_PER_WORKER=%s\n' "$NVIDIA_GPU_COUNT_PER_WORKER"
    printf 'GPU_OPERATOR_VERSION=%s\n' "$GPU_OPERATOR_VERSION"
    printf 'INSTALL_DYNAMO_PLATFORM=false\n'
    printf 'DYNAMO_PLATFORM_VERSION=%s\n' "$DYNAMO_PLATFORM_VERSION"
    printf 'DYNAMO_VLLM_VERSION=%s\n' "$DYNAMO_VLLM_VERSION"
    printf 'DYNAMO_VLLM_IMAGE=%s\n' "$DYNAMO_VLLM_IMAGE"
    printf 'DYNAMO_NAMESPACE=%s\n' "$DYNAMO_NAMESPACE"
    printf 'DYNAMO_NATS_STORAGE_CLASS=%s\n' "$DYNAMO_NATS_STORAGE_CLASS"
    printf 'DYNAMO_NATS_STORAGE_SIZE=%s\n' "$DYNAMO_NATS_STORAGE_SIZE"
    printf 'DYNAMO_NATS_STORAGE_PATH=%s\n' "$DYNAMO_NATS_STORAGE_PATH"
    printf 'PREPULL_DYNAMO_VLLM_IMAGE=false\n'
    printf 'INSTALL_GATEWAY_FOUNDATION=false\n'
    printf 'GATEWAY_API_VERSION=%s\n' "$GATEWAY_API_VERSION"
    printf 'GAIE_VERSION=%s\n' "$GAIE_VERSION"
    printf 'AGENTGATEWAY_VERSION=%s\n' "$AGENTGATEWAY_VERSION"
    printf 'AGENTGATEWAY_NAMESPACE=%s\n' "$AGENTGATEWAY_NAMESPACE"
    printf 'JOIN_COMMAND_BASE64=%s\n' "$join_base64"
  } > "$local_config"
  chmod 600 "$local_config"

  lineprint
  printstyle "Installing and joining ${worker_role} worker $target ...\n" info
  if ! SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "umask 077; mkdir -p '$remote_dir'" || \
     ! SSHPASS="$password" sshpass -e scp "${SCP_OPTIONS[@]}" "$SCRIPT_PATH" "$target:$remote_dir/bootstrap.sh" || \
     ! SSHPASS="$password" sshpass -e scp "${SCP_OPTIONS[@]}" "$local_config" "$target:$remote_dir/worker.env"; then
    cleanup_remote_worker_files "$index" "$remote_dir"
    die "Failed to transfer bootstrap files to $target."
  fi

  remote_command="chmod 700 '${remote_dir}/bootstrap.sh'; chmod 600 '${remote_dir}/worker.env'; env CONFIG_FILE='${remote_dir}/worker.env' '${remote_dir}/bootstrap.sh'"
  status=0
  remote_privileged_command "$index" "$remote_command" || status=$?
  cleanup_remote_worker_files "$index" "$remote_dir"
  (( status == 0 )) || die "Worker installation failed on $target."
  printstyle "Worker $target joined successfully.\n\n" success
}

verify_worker_bootstrap_marker() {
  local worker_role="${NODE_ROLE%-worker}"

  host_owns_ipv4 "$KUBELET_NODE_IP" || die "This worker does not own configured KUBELET_NODE_IP $KUBELET_NODE_IP."
  validate_node_marker_file "$worker_role" "$KUBELET_NODE_IP" || \
    die 'The root-owned worker marker does not match this cluster, role, IP, and Kubernetes version.'
}

join_worker_node() {
  local join_command

  require_config_value JOIN_COMMAND_BASE64
  [[ ! -e /etc/kubernetes/kubelet.conf ]] || die 'This worker already has Kubernetes kubelet configuration. Refusing to overwrite it.'
  join_command="$(printf '%s' "$JOIN_COMMAND_BASE64" | base64 -d)" || die 'Invalid encoded join command.'
  [[ "$join_command" == kubeadm\ join\ * ]] || die 'Decoded worker join command is invalid.'

  lineprint
  printstyle 'Joining this node to the cluster ...\n' info
  bash -c "$join_command"
  printstyle 'Worker joined successfully.\n' success
}

verify_configured_node_inventory() {
  local node_name index

  node_name="$(node_name_for_ip "$CONTROL_PLANE_IP")" || \
    die "The configured control-plane IP $CONTROL_PLANE_IP does not map to exactly one Kubernetes Node."
  [[ "$node_name" == "$LOCAL_HOSTNAME" ]] || \
    die "Control-plane hostname mismatch: expected $LOCAL_HOSTNAME, Kubernetes reports $node_name for $CONTROL_PLANE_IP."
  for index in "${!WORKER_IPS[@]}"; do
    node_name="$(node_name_for_ip "${WORKER_IPS[$index]}")" || \
      die "Configured worker IP ${WORKER_IPS[$index]} does not map to exactly one Kubernetes Node."
    [[ "$node_name" == "${WORKER_HOSTNAMES[$index]}" ]] || \
      die "Worker hostname mismatch for ${WORKER_IPS[$index]}: expected ${WORKER_HOSTNAMES[$index]}, Kubernetes reports $node_name."
  done
}

verify_cluster() {
  local timeout='600s'
  local expected_nodes actual_nodes api_status calico_node_image metrics_server_image kubelet_versions runtime_versions metrics_nodes metrics_output deadline

  expected_nodes=$((GPU_WORKER_COUNT + 1))
  lineprint
  printstyle 'Verifying the completed cluster ...\n' info

  kubectl wait --for=condition=Ready nodes --all --timeout="$timeout" || die 'Not all Kubernetes nodes became Ready.'
  actual_nodes="$(kubectl get nodes --no-headers | wc -l | tr -d '[:space:]')"
  [[ "$actual_nodes" == "$expected_nodes" ]] || die "Expected $expected_nodes nodes, but Kubernetes reports $actual_nodes."
  verify_configured_node_inventory
  kubelet_versions="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}')" || die 'Failed to read node kubelet versions.'
  runtime_versions="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}')" || die 'Failed to read node runtime versions.'
  if grep -Fvx "v${KUBERNETES_VERSION}" <<< "$kubelet_versions" | grep -q .; then
    die "At least one node is not running kubelet v${KUBERNETES_VERSION}."
  fi
  if grep -Fvx "containerd://${CONTAINERD_VERSION}" <<< "$runtime_versions" | grep -q .; then
    die "At least one node is not running containerd v${CONTAINERD_VERSION}."
  fi

  api_status="$(kubectl get --raw='/readyz')"
  [[ "$api_status" == 'ok' ]] || die "Kubernetes API readiness check failed: $api_status"
  cluster_identity_configmap_matches || die 'Kubernetes API cluster identity changed during bootstrap.'
  kubectl -n kube-system rollout status deployment/coredns --timeout="$timeout"

  if [[ "$INSTALL_CALICO" == 'true' ]]; then
    kubectl -n kube-system rollout status daemonset/calico-node --timeout="$timeout"
    kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout="$timeout"
    calico_node_image="$(kubectl -n kube-system get daemonset/calico-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="calico-node")].image}')"
    [[ "$calico_node_image" == *"calico/node:v${CALICO_VERSION}" ]] || die "Calico node image does not match v${CALICO_VERSION}: $calico_node_image"
    verify_calico_node_ips
  fi
  if [[ "$INSTALL_METRICS_SERVER" == 'true' ]]; then
    kubectl -n kube-system rollout status deployment/metrics-server --timeout="$timeout"
    metrics_server_image="$(kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].image}')"
    [[ "$metrics_server_image" == *"metrics-server:v${METRICS_SERVER_VERSION}" ]] || die "metrics-server image does not match v${METRICS_SERVER_VERSION}: $metrics_server_image"
    kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=300s || \
      die 'The Metrics APIService did not become Available.'
    deadline=$((SECONDS + 300))
    metrics_nodes=0
    while (( SECONDS < deadline )); do
      metrics_output="$(kubectl top nodes --no-headers 2>/dev/null || true)"
      metrics_nodes="$(grep -c . <<< "$metrics_output" || true)"
      [[ "$metrics_nodes" == "$expected_nodes" ]] && break
      sleep 5
    done
    [[ "$metrics_nodes" == "$expected_nodes" ]] || \
      die "Metrics Server returned data for ${metrics_nodes}/${expected_nodes} nodes."
  fi

  lineprint
  kubectl get nodes -o wide
  printf '\n'
  kubectl get pods --all-namespaces
  lineprint
  printstyle "Cluster verification succeeded: ${actual_nodes}/${expected_nodes} nodes are Ready.\n" success
  printstyle "Versions: Kubernetes v${KUBERNETES_VERSION}, containerd v${CONTAINERD_VERSION}, Calico v${CALICO_VERSION}\n" success
}

verify_calico_node_ips() {
  local node_name internal_ip calico_ip

  while IFS='=' read -r node_name internal_ip; do
    [[ -n "$node_name" && -n "$internal_ip" ]] || continue
    calico_ip="$(kubectl get node.crd.projectcalico.org "$node_name" -o jsonpath='{.spec.bgp.ipv4Address}' 2>/dev/null || true)"
    calico_ip="${calico_ip%%/*}"
    [[ "$calico_ip" == "$internal_ip" ]] || \
      die "Calico selected ${calico_ip:-no IPv4 address} for $node_name, but Kubernetes InternalIP is $internal_ip."
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{end}{"\n"}{end}')
  printstyle 'Calico addresses match every Kubernetes InternalIP.\n' success
}

cleanup_network_smoke_pods() {
  local remaining

  kubectl -n kube-system delete pod \
    -l app.kubernetes.io/part-of=pactllm-network-smoke \
    --ignore-not-found \
    --wait=true \
    --timeout=120s >/dev/null 2>&1 || die 'Failed to delete old network smoke pods.'
  remaining="$(kubectl -n kube-system get pod -l app.kubernetes.io/part-of=pactllm-network-smoke --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')"
  [[ "$remaining" == '0' ]] || die 'Old network smoke pods still exist.'
}

verify_cross_node_network() {
  local index ordinal=0 node_name pod_name server_ips='' output control_plane_node client_count

  lineprint
  printstyle 'Testing Kubernetes DNS plus platform-to-GPU and GPU-to-GPU Pod TCP paths ...\n' info
  cleanup_network_smoke_pods

  for index in "${GPU_WORKER_INDICES[@]}"; do
    ordinal=$((ordinal + 1))
    node_name="$(node_name_for_ip "${WORKER_IPS[$index]}")" || die "Cannot resolve GPU backend ${WORKER_IPS[$index]} for network smoke testing."
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pactllm-network-server-${ordinal}
  namespace: kube-system
  labels:
    app.kubernetes.io/name: pactllm-network-server
    app.kubernetes.io/part-of: pactllm-network-smoke
spec:
  restartPolicy: Never
  nodeName: ${node_name}
  containers:
    - name: http
      image: ${NETWORK_SMOKE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: [/bin/sh, -c]
      args: ['printf ok > /tmp/health; exec httpd -f -h /tmp -p 18080']
EOF
  done
  if ! kubectl -n kube-system wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=pactllm-network-server --timeout=300s; then
    kubectl -n kube-system describe pods -l app.kubernetes.io/part-of=pactllm-network-smoke || true
    cleanup_network_smoke_pods
    die 'GPU-side TCP smoke servers did not become Ready.'
  fi
  server_ips="$(kubectl -n kube-system get pods -l app.kubernetes.io/name=pactllm-network-server -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}')"
  [[ "$(wc -w <<< "$server_ips" | tr -d '[:space:]')" == "$GPU_WORKER_COUNT" ]] || {
    cleanup_network_smoke_pods
    die 'Not every GPU-side network smoke pod received an IP.'
  }

  control_plane_node="$(node_name_for_ip "$CONTROL_PLANE_IP")" || die 'Cannot resolve the platform node for network smoke testing.'
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: pactllm-network-client-platform
  namespace: kube-system
  labels:
    app.kubernetes.io/name: pactllm-network-client
    app.kubernetes.io/part-of: pactllm-network-smoke
spec:
  restartPolicy: Never
  nodeName: ${control_plane_node}
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: checks
      image: ${NETWORK_SMOKE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: [/bin/sh, -c]
      args:
        - 'set -eu; nslookup kubernetes.default.svc.cluster.local >/dev/null; for endpoint in ${server_ips}; do wget -q -T 10 -O /dev/null "http://\${endpoint}:18080/health"; echo "TCP_OK=\${endpoint}"; done'
EOF

  ordinal=0
  for index in "${GPU_WORKER_INDICES[@]}"; do
    ordinal=$((ordinal + 1))
    node_name="$(node_name_for_ip "${WORKER_IPS[$index]}")" || die "Cannot resolve GPU backend ${WORKER_IPS[$index]} for network smoke testing."
    pod_name="pactllm-network-client-gpu-${ordinal}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: kube-system
  labels:
    app.kubernetes.io/name: pactllm-network-client
    app.kubernetes.io/part-of: pactllm-network-smoke
spec:
  restartPolicy: Never
  nodeName: ${node_name}
  containers:
    - name: checks
      image: ${NETWORK_SMOKE_IMAGE}
      imagePullPolicy: IfNotPresent
      command: [/bin/sh, -c]
      args:
        - 'set -eu; nslookup kubernetes.default.svc.cluster.local >/dev/null; for endpoint in ${server_ips}; do wget -q -T 10 -O /dev/null "http://\${endpoint}:18080/health"; echo "TCP_OK=\${endpoint}"; done'
EOF
  done

  if ! kubectl -n kube-system wait --for=jsonpath='{.status.phase}'=Succeeded pod \
    -l app.kubernetes.io/name=pactllm-network-client --timeout=300s; then
    kubectl -n kube-system describe pods -l app.kubernetes.io/part-of=pactllm-network-smoke || true
    cleanup_network_smoke_pods
    die 'A platform/GPU DNS/TCP network smoke client failed.'
  fi
  client_count="$(kubectl -n kube-system get pods -l app.kubernetes.io/name=pactllm-network-client --no-headers | wc -l | tr -d '[:space:]')"
  [[ "$client_count" == "$((GPU_WORKER_COUNT + 1))" ]] || {
    cleanup_network_smoke_pods
    die "Expected $((GPU_WORKER_COUNT + 1)) network smoke clients, but found $client_count."
  }
  while IFS= read -r pod_name; do
    [[ -n "$pod_name" ]] || continue
    output="$(kubectl -n kube-system logs "$pod_name")"
    [[ "$(grep -c '^TCP_OK=' <<< "$output")" == "$GPU_WORKER_COUNT" ]] || {
      cleanup_network_smoke_pods
      die "$pod_name did not reach all GPU-side Pod IPs."
    }
  done < <(kubectl -n kube-system get pods -l app.kubernetes.io/name=pactllm-network-client -o name)

  cleanup_network_smoke_pods
  printstyle "Cross-node DNS/TCP verification succeeded from the platform and all ${GPU_WORKER_COUNT} GPU backends to every GPU backend.\n\n" success
}

verify_selected_pods_on_platform() {
  local namespace="$1"
  local selector="$2"
  local description="$3"
  local pod_count=0 pod_name node_name role

  while IFS='|' read -r pod_name node_name; do
    [[ -n "$pod_name" ]] || continue
    pod_count=$((pod_count + 1))
    role="$(kubectl get node "$node_name" -o jsonpath='{.metadata.labels.pactllm-role}')"
    [[ "$role" == 'platform' ]] || die "$description pod $pod_name is on $node_name ($role), not the platform node."
  done < <(kubectl -n "$namespace" get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}')
  (( pod_count > 0 )) || die "No $description pods were found for placement verification."
}

verify_infrastructure_placement() {
  verify_selected_pods_on_platform kube-system 'k8s-app=kube-dns' 'CoreDNS'
  verify_selected_pods_on_platform kube-system 'k8s-app=calico-kube-controllers' 'Calico controller'
  verify_selected_pods_on_platform kube-system 'k8s-app=metrics-server' 'metrics-server'
  verify_selected_pods_on_platform gpu-operator 'app.kubernetes.io/component=gpu-operator' 'GPU Operator controller'
  verify_selected_pods_on_platform gpu-operator 'app.kubernetes.io/name=node-feature-discovery,role=master' 'NFD master'
  verify_selected_pods_on_platform gpu-operator 'app.kubernetes.io/name=node-feature-discovery,role=gc' 'NFD garbage collector'
  verify_selected_pods_on_platform "$DYNAMO_NAMESPACE" 'app.kubernetes.io/instance=dynamo-platform' 'Dynamo platform'
  verify_selected_pods_on_platform "$AGENTGATEWAY_NAMESPACE" 'app.kubernetes.io/instance=agentgateway' 'agentgateway controller'
  printstyle 'All long-lived infrastructure controllers are isolated on the platform node.\n' success
}

cleanup_local_temp_paths() {
  local path
  for path in "${LOCAL_TEMP_PATHS[@]:-}"; do
    if [[ -d "$path" ]]; then
      rm -rf -- "$path"
    elif [[ -f "$path" ]]; then
      rm -f -- "$path"
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die 'Please run this script as root.'
fi
BOOTSTRAP_MODE='full'
case "$#:${1:-}" in
  0:) ;;
  1:--resume|1:--resume-dynamo) BOOTSTRAP_MODE='resume' ;;
  *) die 'Usage: k8s-cluster-bootstrap.sh [--resume]' ;;
esac

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/cluster.env}"
MANIFEST_DIR="$SCRIPT_DIR/manifests"
GPU_OPERATOR_VALUES_FILE="$MANIFEST_DIR/gpu-operator-values.yaml"
DYNAMO_PLATFORM_VALUES_FILE="$MANIFEST_DIR/dynamo-platform-values.yaml"
AGENTGATEWAY_VALUES_FILE="$MANIFEST_DIR/agentgateway-values.yaml"
CRI_SOCKET='unix:///run/containerd/containerd.sock'
SANDBOX_IMAGE='registry.k8s.io/pause:3.10.1'
NETWORK_SMOKE_IMAGE='docker.io/library/busybox:1.37.0'
NVIDIA_SMI_GPU_NAME='NVIDIA GeForce RTX 3090'
NODE_MARKER_DIR='/etc/pactllm-bootstrap'
NODE_MARKER_FILE="${NODE_MARKER_DIR}/node.env"
HELM_STATE_ROOT='/var/lib/pactllm-bootstrap/helm'
HELM_CONFIG_HOME="${HELM_STATE_ROOT}/config"
HELM_CACHE_HOME="${HELM_STATE_ROOT}/cache"
HELM_DATA_HOME="${HELM_STATE_ROOT}/data"
export HELM_CONFIG_HOME HELM_CACHE_HOME HELM_DATA_HOME
SSH_STATE_DIR='/var/lib/pactllm-bootstrap/ssh'
SSH_KNOWN_HOSTS_FILE="${SSH_STATE_DIR}/known_hosts"
MAX_CLOCK_SKEW_SECONDS=5
NODE_ROLE=''
CLUSTER_ID=''
KUBELET_NODE_IP=''
KUBERNETES_VERSION=''
CONTAINERD_VERSION=''
CALICO_VERSION=''
HELM_VERSION=''
CONTROL_PLANE_IP=''
POD_CIDR=''
INSTALL_CALICO='true'
INSTALL_METRICS_SERVER='false'
METRICS_SERVER_VERSION=''
REGULAR_USER_HOME=''
GPU_WORKER_COUNT=''
JOIN_COMMAND_BASE64=''
INSTALL_NVIDIA_STACK='true'
NVIDIA_DRIVER_VERSION=''
NVIDIA_CONTAINER_TOOLKIT_VERSION=''
NVIDIA_GPU_MODEL=''
NVIDIA_GPU_MEMORY_MIB=''
NVIDIA_GPU_COUNT_PER_WORKER=''
GPU_OPERATOR_VERSION=''
INSTALL_DYNAMO_PLATFORM='true'
DYNAMO_PLATFORM_VERSION=''
DYNAMO_VLLM_VERSION=''
DYNAMO_VLLM_IMAGE=''
DYNAMO_VLLM_IMAGE_IDS=''
DYNAMO_NAMESPACE='dynamo-system'
DYNAMO_NATS_STORAGE_CLASS='pactllm-local-nats'
DYNAMO_NATS_STORAGE_SIZE='10Gi'
DYNAMO_NATS_STORAGE_PATH='/var/lib/pactllm/dynamo-nats'
PREPULL_DYNAMO_VLLM_IMAGE='true'
INSTALL_GATEWAY_FOUNDATION='true'
GATEWAY_API_VERSION=''
GAIE_VERSION=''
AGENTGATEWAY_VERSION=''
AGENTGATEWAY_NAMESPACE='agentgateway-system'
KUBERNETES_MINOR_VERSION=''
KUBERNETES_PACKAGE_VERSION=''
CALICO_TAG=''
declare -a WORKER_IPS=()
declare -a WORKER_USERS=()
declare -a WORKER_PASSWORDS=()
declare -a WORKER_ROLES=()
declare -a WORKER_HOSTNAMES=()
declare -a GPU_WORKER_INDICES=()
declare -a LOCAL_TEMP_PATHS=()
SSH_OPTIONS=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15)
SCP_OPTIONS=(-o "UserKnownHostsFile=${SSH_KNOWN_HOSTS_FILE}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
trap cleanup_local_temp_paths EXIT

load_config
ensure_cluster_id
if [[ -z "$KUBELET_NODE_IP" ]]; then
  KUBELET_NODE_IP="$CONTROL_PLANE_IP"
fi
require_config_value NODE_ROLE
require_config_value CLUSTER_ID
require_config_value KUBERNETES_VERSION
require_config_value CONTAINERD_VERSION
require_config_value CALICO_VERSION
require_config_value HELM_VERSION
require_config_value METRICS_SERVER_VERSION
require_config_value CONTROL_PLANE_IP
require_config_value NVIDIA_DRIVER_VERSION
require_config_value NVIDIA_CONTAINER_TOOLKIT_VERSION
require_config_value NVIDIA_GPU_MODEL
require_config_value NVIDIA_GPU_MEMORY_MIB
require_config_value NVIDIA_GPU_COUNT_PER_WORKER
require_config_value GPU_OPERATOR_VERSION
require_config_value DYNAMO_PLATFORM_VERSION
require_config_value DYNAMO_VLLM_VERSION
require_config_value DYNAMO_VLLM_IMAGE
require_config_value DYNAMO_NAMESPACE
require_config_value DYNAMO_NATS_STORAGE_CLASS
require_config_value DYNAMO_NATS_STORAGE_SIZE
require_config_value DYNAMO_NATS_STORAGE_PATH
require_config_value GATEWAY_API_VERSION
require_config_value GAIE_VERSION
require_config_value AGENTGATEWAY_VERSION
require_config_value AGENTGATEWAY_NAMESPACE
validate_versions
validate_bool INSTALL_CALICO "$INSTALL_CALICO"
validate_bool INSTALL_METRICS_SERVER "$INSTALL_METRICS_SERVER"
validate_bool INSTALL_NVIDIA_STACK "$INSTALL_NVIDIA_STACK"
validate_bool INSTALL_DYNAMO_PLATFORM "$INSTALL_DYNAMO_PLATFORM"
validate_bool PREPULL_DYNAMO_VLLM_IMAGE "$PREPULL_DYNAMO_VLLM_IMAGE"
validate_bool INSTALL_GATEWAY_FOUNDATION "$INSTALL_GATEWAY_FOUNDATION"
if [[ "$INSTALL_DYNAMO_PLATFORM" == 'true' && "$INSTALL_NVIDIA_STACK" != 'true' ]]; then
  die 'INSTALL_DYNAMO_PLATFORM=true requires INSTALL_NVIDIA_STACK=true.'
fi
if [[ "$PREPULL_DYNAMO_VLLM_IMAGE" == 'true' && "$INSTALL_DYNAMO_PLATFORM" != 'true' ]]; then
  die 'PREPULL_DYNAMO_VLLM_IMAGE=true requires INSTALL_DYNAMO_PLATFORM=true.'
fi
if [[ "$INSTALL_GATEWAY_FOUNDATION" == 'true' && "$INSTALL_DYNAMO_PLATFORM" != 'true' ]]; then
  die 'INSTALL_GATEWAY_FOUNDATION=true requires INSTALL_DYNAMO_PLATFORM=true.'
fi
valid_ipv4 "$CONTROL_PLANE_IP" || die "Invalid CONTROL_PLANE_IP: $CONTROL_PLANE_IP"
valid_ipv4 "$KUBELET_NODE_IP" || die "Invalid KUBELET_NODE_IP: $KUBELET_NODE_IP"
if [[ "$INSTALL_CALICO" == 'true' ]]; then
  require_config_value POD_CIDR
  valid_cidr "$POD_CIDR" || die "Invalid POD_CIDR: $POD_CIDR"
fi

printstyle "Configuration: $CONFIG_FILE\n" info
printstyle "Core versions: Kubernetes v${KUBERNETES_VERSION}, containerd v${CONTAINERD_VERSION}, Calico v${CALICO_VERSION}\n" info
printstyle "GPU/AI versions: Toolkit v${NVIDIA_CONTAINER_TOOLKIT_VERSION}, GPU Operator v${GPU_OPERATOR_VERSION}, Dynamo v${DYNAMO_PLATFORM_VERSION}, vLLM v${DYNAMO_VLLM_VERSION}\n" info

case "$NODE_ROLE" in
  gpu-backend-worker)
    verify_worker_bootstrap_marker
    install_node_components
    install_nvidia_container_toolkit
    join_worker_node
    ;;
  control-plane)
    validate_fixed_research_stack
    collect_workers
    if [[ "$INSTALL_NVIDIA_STACK" == 'true' && "$GPU_WORKER_COUNT" == '0' ]]; then
      die 'INSTALL_NVIDIA_STACK=true requires at least one GPU backend worker.'
    fi
    if [[ "$BOOTSTRAP_MODE" == 'resume' ]]; then
      resume_cluster_bootstrap
    else
      verify_local_host_preflight true
      install_orchestration_dependencies
      prepare_ssh_state
      preflight_remote_access
      stage_node_markers
      install_node_components
      initialize_control_plane
      pin_core_cluster_services
      install_calico
      install_metrics_server

      lineprint
      printstyle "Provisioning and joining ${GPU_WORKER_COUNT} GPU backend worker(s) over SSH ...\n" info
      JOIN_COMMAND="$(kubeadm token create --print-join-command) --cri-socket=${CRI_SOCKET}"
      [[ -n "$JOIN_COMMAND" ]] || die 'Failed to create the worker join command.'
      for index in "${!WORKER_IPS[@]}"; do
        install_remote_worker "$index" "$JOIN_COMMAND"
      done
      verify_cluster
      label_cluster_nodes
      verify_cross_node_network
      if [[ "$INSTALL_NVIDIA_STACK" == 'true' || "$INSTALL_DYNAMO_PLATFORM" == 'true' ]]; then
        install_helm
      fi
      install_gpu_operator
      prepare_dynamo_nats_storage
      install_dynamo_platform
      install_gateway_foundation
      prepull_dynamo_vllm_runtime
      verify_gpu_runtime_smoke
      verify_infrastructure_placement
      write_environment_report
      lineprint
      printstyle 'Full bootstrap completed successfully. No DGD or inference workload was applied.\n' success
      printstyle "Prepared runtime: ${DYNAMO_VLLM_IMAGE} (bundled vLLM ${DYNAMO_VLLM_VERSION}).\n" success
    fi
    ;;
  *)
    die 'NODE_ROLE must be control-plane. Worker roles are reserved for internal remote execution.'
    ;;
esac
