#!/usr/bin/env bash

set -Eeuo pipefail

CRI_SOCKET='unix:///run/containerd/containerd.sock'
EXPECTED_KUBERNETES_VERSION='1.35.6'
EXPECTED_CONTAINERD_VERSION='1.7.34'
EXPECTED_CALICO_VERSION='3.32.1'
EXPECTED_HELM_VERSION='3.20.0'
EXPECTED_NVIDIA_DRIVER_VERSION='580.173.02'
EXPECTED_NVIDIA_TOOLKIT_VERSION='1.19.1'
EXPECTED_NVIDIA_GPU_MODEL='RTX 3090'
EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER=1
EXPECTED_GPU_OPERATOR_VERSION='26.3.3'
EXPECTED_DYNAMO_VERSION='1.3.0'
EXPECTED_DYNAMO_VLLM_VERSION='0.23.0'
EXPECTED_DYNAMO_VLLM_IMAGE='nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.3.0'
EXPECTED_DYNAMO_NAMESPACE='dynamo-system'
EXPECTED_CONTROL_PLANE_IP='192.168.0.10'
EXPECTED_POD_CIDR='10.244.0.0/16'
EXPECTED_REGULAR_USER_HOME='/home/dnclab'
EXPECTED_WORKER_USER='dnclab'
EXPECTED_WORKER_COUNT=4
EXPECTED_WORKER_IPS=('192.168.0.11' '192.168.0.12' '192.168.0.13' '192.168.0.14')
REMOTE_CLEANUP_DIR='/tmp/k8s-cluster-cleanup-1-35-6'

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
      NODE_ROLE|KUBERNETES_VERSION|CONTAINERD_VERSION|CALICO_VERSION|HELM_VERSION|CONTROL_PLANE_IP|POD_CIDR|INSTALL_CALICO|INSTALL_METRICS_SERVER|REGULAR_USER_HOME|WORKER_COUNT|INSTALL_NVIDIA_STACK|NVIDIA_DRIVER_VERSION|NVIDIA_CONTAINER_TOOLKIT_VERSION|NVIDIA_GPU_MODEL|NVIDIA_GPU_COUNT_PER_WORKER|GPU_OPERATOR_VERSION|INSTALL_DYNAMO_PLATFORM|DYNAMO_PLATFORM_VERSION|DYNAMO_VLLM_VERSION|DYNAMO_VLLM_IMAGE|DYNAMO_NAMESPACE|PREPULL_DYNAMO_VLLM_IMAGE)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        if [[ "$key" =~ ^WORKER_[1-9][0-9]*_(IP|SSH_USER|SSH_PASSWORD)$ ]]; then
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
  [[ "$NVIDIA_DRIVER_VERSION" == "$EXPECTED_NVIDIA_DRIVER_VERSION" ]] || die "Cleanup only preserves NVIDIA Driver $EXPECTED_NVIDIA_DRIVER_VERSION."
  [[ "$NVIDIA_CONTAINER_TOOLKIT_VERSION" == "$EXPECTED_NVIDIA_TOOLKIT_VERSION" ]] || die "Cleanup only supports NVIDIA Container Toolkit $EXPECTED_NVIDIA_TOOLKIT_VERSION."
  [[ "$NVIDIA_GPU_MODEL" == "$EXPECTED_NVIDIA_GPU_MODEL" ]] || die "Cleanup only supports NVIDIA GPU model $EXPECTED_NVIDIA_GPU_MODEL."
  [[ "$NVIDIA_GPU_COUNT_PER_WORKER" == "$EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER" ]] || die "Cleanup expects $EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER GPU per worker."
  [[ "${GPU_OPERATOR_VERSION#v}" == "$EXPECTED_GPU_OPERATOR_VERSION" ]] || die "Cleanup only supports GPU Operator $EXPECTED_GPU_OPERATOR_VERSION."
  [[ "$DYNAMO_PLATFORM_VERSION" == "$EXPECTED_DYNAMO_VERSION" ]] || die "Cleanup only supports Dynamo $EXPECTED_DYNAMO_VERSION."
  [[ "$DYNAMO_VLLM_VERSION" == "$EXPECTED_DYNAMO_VLLM_VERSION" ]] || die "Cleanup only supports Dynamo vLLM $EXPECTED_DYNAMO_VLLM_VERSION."
  [[ "$DYNAMO_VLLM_IMAGE" == "$EXPECTED_DYNAMO_VLLM_IMAGE" ]] || die "Unexpected Dynamo vLLM image in cluster.env."
  [[ "$DYNAMO_NAMESPACE" == "$EXPECTED_DYNAMO_NAMESPACE" ]] || die "Cleanup only supports Dynamo namespace $EXPECTED_DYNAMO_NAMESPACE."
  [[ "$INSTALL_CALICO" == 'true' ]] || die 'The fixed cleanup expects INSTALL_CALICO=true.'
  [[ "$INSTALL_METRICS_SERVER" == 'true' ]] || die 'The fixed cleanup expects INSTALL_METRICS_SERVER=true.'
  [[ "$INSTALL_NVIDIA_STACK" == 'true' ]] || die 'The fixed cleanup expects INSTALL_NVIDIA_STACK=true.'
  [[ "$INSTALL_DYNAMO_PLATFORM" == 'true' ]] || die 'The fixed cleanup expects INSTALL_DYNAMO_PLATFORM=true.'
  [[ "$PREPULL_DYNAMO_VLLM_IMAGE" == 'true' ]] || die 'The fixed cleanup expects PREPULL_DYNAMO_VLLM_IMAGE=true.'
  valid_ipv4 "$CONTROL_PLANE_IP" || die "Invalid CONTROL_PLANE_IP: $CONTROL_PLANE_IP"
  [[ "$CONTROL_PLANE_IP" == "$EXPECTED_CONTROL_PLANE_IP" ]] || die "Cleanup is pinned to control-plane IP $EXPECTED_CONTROL_PLANE_IP."
  [[ "$POD_CIDR" == "$EXPECTED_POD_CIDR" ]] || die "Cleanup is pinned to pod CIDR $EXPECTED_POD_CIDR."
  [[ "$REGULAR_USER_HOME" == "$EXPECTED_REGULAR_USER_HOME" ]] || die "Cleanup is pinned to regular user home $EXPECTED_REGULAR_USER_HOME."
  [[ "$WORKER_COUNT" =~ ^[1-9][0-9]*$ ]] || die 'WORKER_COUNT must be a positive integer.'
  WORKER_COUNT="$((10#$WORKER_COUNT))"
  (( WORKER_COUNT == EXPECTED_WORKER_COUNT )) || die "Cleanup is pinned to $EXPECTED_WORKER_COUNT workers."
}

collect_workers() {
  local index ip_var user_var password_var ip user password
  declare -A seen_ips=()

  for ((index = 1; index <= WORKER_COUNT; index++)); do
    ip_var="WORKER_${index}_IP"
    user_var="WORKER_${index}_SSH_USER"
    password_var="WORKER_${index}_SSH_PASSWORD"
    require_config_value "$ip_var"
    require_config_value "$user_var"
    require_config_value "$password_var"

    ip="${!ip_var}"
    user="${!user_var}"
    password="${!password_var}"
    valid_ipv4 "$ip" || die "Invalid worker IP: $ip"
    [[ "$ip" == "${EXPECTED_WORKER_IPS[$((index - 1))]}" ]] || die "Worker $index must be ${EXPECTED_WORKER_IPS[$((index - 1))]}."
    [[ "$ip" != "$CONTROL_PLANE_IP" ]] || die "Worker IP cannot equal the control-plane IP: $ip"
    [[ -z "${seen_ips[$ip]:-}" ]] || die "Duplicate worker IP: $ip"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Invalid SSH username for worker $index: $user"
    [[ "$user" == "$EXPECTED_WORKER_USER" ]] || die "Worker $index SSH user must be $EXPECTED_WORKER_USER."
    seen_ips["$ip"]=1

    WORKER_IPS+=("$ip")
    WORKER_USERS+=("$user")
    WORKER_PASSWORDS+=("$password")
  done
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
  local target password inventory gpu_name driver_version
  local gpu_count=0

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  inventory="$(SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" \
    "nvidia-smi --query-gpu=name,driver_version --format=csv,noheader")" || \
    die "NVIDIA Driver check failed on $target. Cleanup will not start."
  [[ -n "$inventory" ]] || die "No NVIDIA GPU was reported on $target."

  while IFS=',' read -r gpu_name driver_version; do
    driver_version="${driver_version#"${driver_version%%[![:space:]]*}"}"
    driver_version="${driver_version%"${driver_version##*[![:space:]]}"}"
    [[ "$gpu_name" == *"$EXPECTED_NVIDIA_GPU_MODEL"* ]] || die "Unexpected GPU on $target: $gpu_name"
    [[ "$driver_version" == "$EXPECTED_NVIDIA_DRIVER_VERSION" ]] || die "Worker $target is not using NVIDIA Driver $EXPECTED_NVIDIA_DRIVER_VERSION."
    ((gpu_count += 1))
  done <<< "$inventory"
  (( gpu_count == EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER )) || die "Worker $target does not have exactly $EXPECTED_NVIDIA_GPU_COUNT_PER_WORKER GPU."
}

preflight_remote_workers() {
  local index target password user

  for index in "${!WORKER_IPS[@]}"; do
    target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
    password="${WORKER_PASSWORDS[$index]}"
    user="${WORKER_USERS[$index]}"
    printstyle "Checking SSH, sudo, target IP, and NVIDIA Driver on $target ...\n" info

    SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" 'true' || \
      die "Cannot connect to $target. Cleanup has not started."
    if [[ "$user" != 'root' ]] && ! printf '%s\n' "$password" | SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "sudo -S -p '' true"; then
      die "Configured account cannot run sudo on $target. Cleanup has not started."
    fi
    if ! remote_privileged_command "$index" "ip -4 -o addr show | grep -Fq ' ${WORKER_IPS[$index]}/'" >/dev/null; then
      die "Remote host $target does not own the configured IP ${WORKER_IPS[$index]}. Cleanup has not started."
    fi
    verify_remote_driver "$index"
  done
}

confirm_destruction() {
  local expected confirmation

  expected="DESTROY ${CONTROL_PLANE_IP}"
  [[ -t 0 ]] || die "Interactive confirmation is required. Run this cleanup from a terminal."
  lineprint
  printstyle 'WARNING: This permanently deletes Kubernetes, containerd data/images, NVIDIA Container Toolkit, GPU Operator, and Dynamo from every configured node.\n' danger
  printstyle "NVIDIA Driver ${EXPECTED_NVIDIA_DRIVER_VERSION} is the only NVIDIA component that will be preserved.\n" warning
  printf 'Type exactly "%s" to continue: ' "$expected"
  read -r confirmation
  [[ "$confirmation" == "$expected" ]] || die 'Confirmation did not match. Nothing was deleted.'
}

cluster_api_available() {
  command -v kubectl >/dev/null 2>&1 && \
    [[ -f /etc/kubernetes/admin.conf ]] && \
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl get --raw='/readyz' --request-timeout=8s 2>/dev/null | grep -Fxq ok
}

delete_dynamo_custom_resources() {
  local resource

  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$resource" --all --all-namespaces --wait=false 2>/dev/null || true
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl api-resources --api-group=nvidia.com --namespaced=true -o name 2>/dev/null | grep '^dynamo' || true)
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$resource" --all --wait=false 2>/dev/null || true
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl api-resources --api-group=nvidia.com --namespaced=false -o name 2>/dev/null | grep '^dynamo' || true)
}

cleanup_cluster_resources() {
  local crd

  lineprint
  if ! cluster_api_available; then
    warn 'Kubernetes API is unavailable. Skipping graceful Helm/API cleanup and continuing with node reset.'
    return 0
  fi

  printstyle 'Removing Dynamo workloads, platform, namespace, and CRDs ...\n' info
  delete_dynamo_custom_resources
  if command -v helm >/dev/null 2>&1 && KUBECONFIG=/etc/kubernetes/admin.conf helm status dynamo-platform -n "$DYNAMO_NAMESPACE" >/dev/null 2>&1; then
    KUBECONFIG=/etc/kubernetes/admin.conf helm uninstall dynamo-platform -n "$DYNAMO_NAMESPACE" --wait --timeout=10m || warn 'Dynamo Helm uninstall reported an error; node reset will still remove etcd state.'
  fi
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete namespace "$DYNAMO_NAMESPACE" --ignore-not-found --wait=false 2>/dev/null || true
  while IFS= read -r crd; do
    [[ -n "$crd" ]] || continue
    KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete "$crd" --wait=false 2>/dev/null || true
  done < <(KUBECONFIG=/etc/kubernetes/admin.conf kubectl get crd -o name 2>/dev/null | grep -E '/dynamo.*\.nvidia\.com$' || true)

  printstyle 'Removing GPU Operator, RuntimeClass, namespace, and CRDs ...\n' info
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete runtimeclass nvidia --ignore-not-found 2>/dev/null || true
  KUBECONFIG=/etc/kubernetes/admin.conf kubectl delete clusterpolicy --all --wait=false 2>/dev/null || true
  if command -v helm >/dev/null 2>&1 && KUBECONFIG=/etc/kubernetes/admin.conf helm status gpu-operator -n gpu-operator >/dev/null 2>&1; then
    KUBECONFIG=/etc/kubernetes/admin.conf helm uninstall gpu-operator -n gpu-operator --wait --timeout=10m || warn 'GPU Operator Helm uninstall reported an error; node reset will still remove etcd state.'
  fi
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

  for iface in cni0 flannel.1 tunl0 vxlan.calico; do
    ip link delete "$iface" 2>/dev/null || true
  done
  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    ip link delete "$iface" 2>/dev/null || true
  done < <(ip -o link show | awk -F': ' '$2 ~ /^cali/ { split($2, a, "@"); print a[1] }')
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
  local command_name package versions
  local removed_commands=(kubeadm kubelet kubectl crictl containerd ctr runc nvidia-ctk)
  local removed_packages=(
    kubelet
    kubeadm
    kubectl
    kubernetes-cni
    cri-tools
    runc
    containerd
    containerd.io
    nvidia-container-toolkit
    nvidia-container-toolkit-base
    libnvidia-container-tools
    libnvidia-container1
  )

  if [[ "$node_kind" == 'control-plane' ]]; then
    removed_commands+=(helm)
  fi

  for command_name in "${removed_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 && die "$command_name is still installed on this node."
  done
  [[ ! -e /etc/kubernetes ]] || die '/etc/kubernetes still exists.'
  [[ ! -e /etc/containerd ]] || die '/etc/containerd still exists.'
  [[ ! -e /var/lib/containerd ]] || die '/var/lib/containerd still exists.'
  for package in "${removed_packages[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -Eq '^(installed|config-files)$'; then
      die "$package was not fully purged."
    fi
  done

  if [[ "$node_kind" == 'worker' ]]; then
    command -v nvidia-smi >/dev/null 2>&1 || die 'nvidia-smi disappeared; the protected NVIDIA Driver may have been removed.'
    versions="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)" || die 'The protected NVIDIA Driver is not healthy.'
    [[ -n "$versions" ]] || die 'No NVIDIA GPU was reported after cleanup.'
    if grep -Fvx "$EXPECTED_NVIDIA_DRIVER_VERSION" <<< "$versions" | grep -q .; then
      die "NVIDIA Driver changed during cleanup; expected $EXPECTED_NVIDIA_DRIVER_VERSION."
    fi
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

  delete_cni_interfaces
  rm -rf \
    /etc/kubernetes \
    /var/lib/etcd \
    /var/lib/kubelet \
    /etc/cni/net.d \
    /var/lib/cni \
    /var/lib/calico \
    /var/run/calico \
    /var/run/kubernetes \
    /var/log/pods \
    /var/log/containers \
    /opt/cni/bin \
    /root/.kube \
    /etc/systemd/system/kubelet.service.d
  rm -f \
    /etc/modules-load.d/k8s.conf \
    /etc/sysctl.d/k8s.conf \
    /etc/crictl.yaml

  printstyle 'Purging Kubernetes packages and repository configuration ...\n' info
  purge_kubernetes_packages
  printstyle 'Purging NVIDIA Container Toolkit while preserving the NVIDIA Driver ...\n' info
  purge_nvidia_container_toolkit
  printstyle 'Removing upstream containerd, runtime configuration, images, and data ...\n' info
  remove_upstream_containerd
  apt-get clean

  hash -r
  verify_node_cleanup "$node_kind"
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
  lineprint
  printstyle "Cleaning worker $target ...\n" info

  if ! SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" "umask 077; mkdir -p '${REMOTE_CLEANUP_DIR}'" || \
     ! SSHPASS="$password" sshpass -e scp "${SCP_OPTIONS[@]}" "$SCRIPT_PATH" "$target:${REMOTE_CLEANUP_DIR}/cleanup.sh"; then
    cleanup_remote_script "$index"
    die "Failed to transfer the cleanup script to $target. The control plane was not reset."
  fi

  remote_privileged_command "$index" "chmod 700 '${REMOTE_CLEANUP_DIR}/cleanup.sh'; CLEANUP_NODE_ROLE=worker '${REMOTE_CLEANUP_DIR}/cleanup.sh'" || status=$?
  cleanup_remote_script "$index"
  (( status == 0 )) || die "Worker cleanup failed on $target. The control plane was not reset."
  printstyle "Worker $target cleanup completed and NVIDIA Driver ${EXPECTED_NVIDIA_DRIVER_VERSION} was preserved.\n\n" success
}

cleanup_master_files() {
  local ip

  rm -f /usr/local/bin/helm
  rm -rf /root/.cache/helm /root/.config/helm /root/.local/share/helm
  if [[ -n "$REGULAR_USER_HOME" ]]; then
    [[ "$REGULAR_USER_HOME" =~ ^/home/[a-zA-Z0-9._-]+$ ]] || die "Unsafe REGULAR_USER_HOME value: $REGULAR_USER_HOME"
    rm -rf -- "$REGULAR_USER_HOME/.kube" "$REGULAR_USER_HOME/.cache/helm" "$REGULAR_USER_HOME/.config/helm" "$REGULAR_USER_HOME/.local/share/helm"
  fi
  if [[ -f /root/.ssh/known_hosts ]]; then
    for ip in "${WORKER_IPS[@]}"; do
      ssh-keygen -q -R "$ip" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true
    done
  fi
}

main() {
  local cleanup_role="${CLEANUP_NODE_ROLE:-control-plane}"
  local index

  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die 'Please run this cleanup script as root.'
  if [[ "$cleanup_role" == 'worker' ]]; then
    cleanup_node worker
    exit 0
  fi
  [[ "$cleanup_role" == 'control-plane' ]] || die 'Invalid internal cleanup role.'
  (( $# == 0 )) || die 'This cleanup does not accept command-line options. It uses cluster.env.'

  SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
  SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
  CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/cluster.env}"
  NODE_ROLE=''
  KUBERNETES_VERSION=''
  CONTAINERD_VERSION=''
  CALICO_VERSION=''
  HELM_VERSION=''
  CONTROL_PLANE_IP=''
  POD_CIDR=''
  INSTALL_CALICO=''
  INSTALL_METRICS_SERVER=''
  REGULAR_USER_HOME=''
  WORKER_COUNT=''
  INSTALL_NVIDIA_STACK=''
  NVIDIA_DRIVER_VERSION=''
  NVIDIA_CONTAINER_TOOLKIT_VERSION=''
  NVIDIA_GPU_MODEL=''
  NVIDIA_GPU_COUNT_PER_WORKER=''
  GPU_OPERATOR_VERSION=''
  INSTALL_DYNAMO_PLATFORM=''
  DYNAMO_PLATFORM_VERSION=''
  DYNAMO_VLLM_VERSION=''
  DYNAMO_VLLM_IMAGE=''
  DYNAMO_NAMESPACE=''
  PREPULL_DYNAMO_VLLM_IMAGE=''
  declare -g -a WORKER_IPS=()
  declare -g -a WORKER_USERS=()
  declare -g -a WORKER_PASSWORDS=()
  declare -g -a SSH_OPTIONS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15)
  declare -g -a SCP_OPTIONS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

  load_config
  for value_name in NODE_ROLE KUBERNETES_VERSION CONTAINERD_VERSION CALICO_VERSION CONTROL_PLANE_IP WORKER_COUNT NVIDIA_DRIVER_VERSION NVIDIA_CONTAINER_TOOLKIT_VERSION GPU_OPERATOR_VERSION DYNAMO_PLATFORM_VERSION DYNAMO_NAMESPACE; do
    require_config_value "$value_name"
  done
  validate_fixed_stack
  collect_workers
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$CONTROL_PLANE_IP" || \
    die "This host does not own CONTROL_PLANE_IP $CONTROL_PLANE_IP. Cleanup refused."

  command -v sshpass >/dev/null 2>&1 || die 'sshpass is required on the control plane.'
  command -v ssh >/dev/null 2>&1 || die 'ssh is required on the control plane.'
  command -v scp >/dev/null 2>&1 || die 'scp is required on the control plane.'
  preflight_remote_workers
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
  printstyle "Preserved component: NVIDIA Driver ${EXPECTED_NVIDIA_DRIVER_VERSION} on all GPU workers.\n" success
  printstyle 'Not restored automatically: swap configuration and UFW state.\n' warning
  printstyle 'Reboot each worker, then reboot the control plane manually. After reboot, verify nvidia-smi on every GPU worker.\n' warning
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
