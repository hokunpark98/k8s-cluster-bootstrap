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
      NODE_ROLE|KUBERNETES_VERSION|CONTAINERD_VERSION|CALICO_VERSION|HELM_VERSION|CONTROL_PLANE_IP|POD_CIDR|INSTALL_CALICO|INSTALL_METRICS_SERVER|REGULAR_USER_HOME|WORKER_COUNT|JOIN_COMMAND_BASE64|INSTALL_NVIDIA_STACK|NVIDIA_DRIVER_VERSION|NVIDIA_CONTAINER_TOOLKIT_VERSION|NVIDIA_GPU_MODEL|NVIDIA_GPU_COUNT_PER_WORKER|GPU_OPERATOR_VERSION|INSTALL_DYNAMO_PLATFORM|DYNAMO_PLATFORM_VERSION|DYNAMO_VLLM_VERSION|DYNAMO_VLLM_IMAGE|DYNAMO_NAMESPACE|PREPULL_DYNAMO_VLLM_IMAGE)
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
}

validate_versions() {
  local version_name

  [[ "$KUBERNETES_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'KUBERNETES_VERSION must use X.Y.Z format.'
  [[ "$CONTAINERD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'CONTAINERD_VERSION must use X.Y.Z format.'
  CALICO_VERSION="${CALICO_VERSION#v}"
  [[ "$CALICO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'CALICO_VERSION must use X.Y.Z format.'
  GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION#v}"

  for version_name in HELM_VERSION NVIDIA_DRIVER_VERSION NVIDIA_CONTAINER_TOOLKIT_VERSION GPU_OPERATOR_VERSION DYNAMO_PLATFORM_VERSION DYNAMO_VLLM_VERSION; do
    [[ "${!version_name}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$version_name must use X.Y.Z format."
  done

  [[ "$NVIDIA_GPU_COUNT_PER_WORKER" =~ ^[1-9][0-9]*$ ]] || die 'NVIDIA_GPU_COUNT_PER_WORKER must be a positive integer.'
  [[ "$DYNAMO_NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die 'DYNAMO_NAMESPACE must be a valid Kubernetes namespace name.'
  [[ "$DYNAMO_VLLM_IMAGE" =~ ^[A-Za-z0-9._:/-]+$ ]] || die 'DYNAMO_VLLM_IMAGE contains unsupported characters.'

  if [[ "$DYNAMO_PLATFORM_VERSION" == '1.3.0' ]]; then
    [[ "$DYNAMO_VLLM_VERSION" == '0.23.0' ]] || die 'Dynamo Platform 1.3.0 must use the bundled vLLM 0.23.0 runtime.'
    [[ "$DYNAMO_VLLM_IMAGE" == *':1.3.0' ]] || die 'Dynamo Platform 1.3.0 must use a vLLM runtime image pinned to tag 1.3.0.'
  fi

  KUBERNETES_MINOR_VERSION="${KUBERNETES_VERSION%.*}"
  KUBERNETES_PACKAGE_VERSION="${KUBERNETES_VERSION}-1.1"
  CALICO_TAG="v${CALICO_VERSION}"
}

collect_workers() {
  local index ip_var user_var password_var ip user password
  declare -A seen_ips=()

  if [[ -z "$WORKER_COUNT" ]]; then
    prompt_if_empty WORKER_COUNT 'Worker node count: '
  fi
  [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] || die 'WORKER_COUNT must be zero or a positive integer.'
  WORKER_COUNT="$((10#$WORKER_COUNT))"

  for ((index = 1; index <= WORKER_COUNT; index++)); do
    ip_var="WORKER_${index}_IP"
    user_var="WORKER_${index}_SSH_USER"
    password_var="WORKER_${index}_SSH_PASSWORD"

    prompt_if_empty "$ip_var" "Worker ${index} IP: "
    prompt_if_empty "$user_var" "Worker ${index} SSH username: "
    prompt_if_empty "$password_var" "Worker ${index} SSH/sudo password: " true

    ip="${!ip_var}"
    user="${!user_var}"
    password="${!password_var}"

    valid_ipv4 "$ip" || die "Invalid worker IP: $ip"
    [[ "$ip" != "$CONTROL_PLANE_IP" ]] || die "Worker IP cannot equal the control-plane IP: $ip"
    [[ -z "${seen_ips[$ip]:-}" ]] || die "Duplicate worker IP: $ip"
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*\$?$ ]] || die "Invalid SSH username for worker $index: $user"
    seen_ips["$ip"]=1

    WORKER_IPS+=("$ip")
    WORKER_USERS+=("$user")
    WORKER_PASSWORDS+=("$password")
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

preflight_remote_gpu() {
  local index="$1"
  local target password inventory line gpu_name driver_version gpu_count=0

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  if ! inventory="$(SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" "$target" \
    "nvidia-smi --query-gpu=name,driver_version --format=csv,noheader")"; then
    die "nvidia-smi failed on $target. Install and load the host NVIDIA driver first."
  fi

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    IFS=',' read -r gpu_name driver_version <<< "$line"
    gpu_name="${gpu_name#"${gpu_name%%[![:space:]]*}"}"
    gpu_name="${gpu_name%"${gpu_name##*[![:space:]]}"}"
    driver_version="${driver_version#"${driver_version%%[![:space:]]*}"}"
    driver_version="${driver_version%"${driver_version##*[![:space:]]}"}"

    [[ "$gpu_name" == *"$NVIDIA_GPU_MODEL"* ]] || die "Unexpected GPU on $target: $gpu_name (expected $NVIDIA_GPU_MODEL)."
    [[ "$driver_version" == "$NVIDIA_DRIVER_VERSION" ]] || die "Unexpected NVIDIA driver on $target: $driver_version (expected $NVIDIA_DRIVER_VERSION)."
    gpu_count=$((gpu_count + 1))
  done <<< "$inventory"

  (( gpu_count == NVIDIA_GPU_COUNT_PER_WORKER )) || \
    die "Worker $target has $gpu_count GPUs; expected $NVIDIA_GPU_COUNT_PER_WORKER."
  printstyle "GPU preflight passed on $target: ${gpu_count}x ${NVIDIA_GPU_MODEL}, driver ${NVIDIA_DRIVER_VERSION}.\n" success
}

preflight_remote_access() {
  local index target password user

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
    if ! remote_privileged_command "$index" 'test ! -e /etc/kubernetes/kubelet.conf'; then
      die "Worker $target already has Kubernetes kubelet configuration. Refusing to overwrite it."
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
  sed -i '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
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
  grep -Fq 'SystemdCgroup = true' /etc/containerd/config.toml || die 'Failed to enable SystemdCgroup in containerd.'

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

  [[ "$INSTALL_NVIDIA_STACK" == 'true' ]] || return
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

  nvidia-ctk runtime configure --runtime=containerd --set-as-default
  [[ -f /etc/containerd/conf.d/99-nvidia.toml ]] || die 'The NVIDIA containerd drop-in configuration was not created.'
  systemctl restart containerd
  systemctl is-active --quiet containerd || die 'containerd failed after NVIDIA runtime configuration.'

  nvidia-ctk --version | grep -Fq "$NVIDIA_CONTAINER_TOOLKIT_VERSION" || die 'Installed NVIDIA Container Toolkit version does not match cluster.env.'
  /usr/local/bin/containerd config dump | grep -Fq 'default_runtime_name = "nvidia"' || die 'containerd default runtime is not nvidia.'
  nvidia-container-cli info >/dev/null || die 'NVIDIA Container Toolkit cannot query the host GPU.'
  printstyle 'NVIDIA Container Toolkit and containerd runtime configuration succeeded.\n\n' success
}

install_kubernetes() {
  local keyring='/etc/apt/keyrings/kubernetes-apt-keyring.gpg'
  local repository='/etc/apt/sources.list.d/kubernetes.list'
  local component

  lineprint
  printstyle "Installing exact Kubernetes v${KUBERNETES_VERSION} ...\n" info

  mkdir -p -m 755 /etc/apt/keyrings
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

initialize_control_plane() {
  local init_args

  [[ ! -e /etc/kubernetes/admin.conf ]] || die 'An existing Kubernetes control plane was detected. Refusing to overwrite it.'

  lineprint
  printstyle 'Initializing the control plane ...\n' info
  init_args=(
    "--kubernetes-version=v${KUBERNETES_VERSION}"
    "--apiserver-advertise-address=${CONTROL_PLANE_IP}"
    "--cri-socket=${CRI_SOCKET}"
  )
  if [[ "$INSTALL_CALICO" == 'true' ]]; then
    init_args+=("--pod-network-cidr=${POD_CIDR}")
  fi
  kubeadm init "${init_args[@]}"
  configure_kubeconfig
  printstyle 'Control plane initialized.\n\n' success
}

install_calico() {
  local manifest

  [[ "$INSTALL_CALICO" == 'true' ]] || return
  lineprint
  printstyle "Installing exact Calico v${CALICO_VERSION} ...\n" info

  manifest="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$manifest")
  curl -fsSL -o "$manifest" "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_TAG}/manifests/calico.yaml" || die "Failed to download Calico ${CALICO_TAG}."
  sed -i \
    -e 's|^            # - name: CALICO_IPV4POOL_CIDR$|            - name: CALICO_IPV4POOL_CIDR|' \
    -e "s|^            #   value: \"192.168.0.0/16\"$|              value: \"${POD_CIDR}\"|" \
    "$manifest"
  grep -Fxq '            - name: CALICO_IPV4POOL_CIDR' "$manifest" || die 'Failed to enable CALICO_IPV4POOL_CIDR in the manifest.'
  grep -Fxq "              value: \"${POD_CIDR}\"" "$manifest" || die 'Failed to set the configured Calico Pod CIDR.'
  kubectl apply -f "$manifest"
  printstyle 'Calico manifest applied.\n\n' success
}

install_metrics_server() {
  local manifest

  [[ "$INSTALL_METRICS_SERVER" == 'true' ]] || return
  lineprint
  printstyle 'Installing metrics-server ...\n' info
  manifest="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$manifest")
  curl -fsSL -o "$manifest" 'https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml'
  sed -i '/--metric-resolution=15s/a\        - --kubelet-insecure-tls' "$manifest"
  kubectl apply -f "$manifest"
  printstyle 'metrics-server manifest applied.\n\n' success
}

install_helm() {
  local architecture archive release_url temp_dir expected_checksum actual_checksum

  lineprint
  printstyle "Installing exact Helm v${HELM_VERSION} ...\n" info
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
  local inventory line node_name gpu_count gpu_nodes=0 total_gpus=0
  local expected_total=$((WORKER_COUNT * NVIDIA_GPU_COUNT_PER_WORKER))

  inventory="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}')" || \
    die 'Failed to read allocatable NVIDIA GPU resources.'
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    node_name="${line%%=*}"
    gpu_count="${line#*=}"
    [[ -n "$gpu_count" ]] || continue
    [[ "$gpu_count" =~ ^[0-9]+$ ]] || die "Invalid NVIDIA GPU capacity on node $node_name: $gpu_count"
    (( gpu_count == NVIDIA_GPU_COUNT_PER_WORKER )) || \
      die "Node $node_name exposes $gpu_count GPUs; expected $NVIDIA_GPU_COUNT_PER_WORKER."
    gpu_nodes=$((gpu_nodes + 1))
    total_gpus=$((total_gpus + gpu_count))
  done <<< "$inventory"

  (( gpu_nodes == WORKER_COUNT )) || die "Kubernetes reports $gpu_nodes GPU nodes; expected $WORKER_COUNT."
  (( total_gpus == expected_total )) || die "Kubernetes reports $total_gpus allocatable GPUs; expected $expected_total."
  printstyle "Kubernetes GPU resources verified: ${gpu_nodes} nodes, ${total_gpus} GPUs.\n" success
}

install_gpu_operator() {
  local deployment daemonset

  [[ "$INSTALL_NVIDIA_STACK" == 'true' ]] || return
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
  verify_gpu_resources
  printstyle 'GPU Operator installation and GPU resource verification succeeded.\n\n' success
}

install_dynamo_platform() {
  local resource images

  [[ "$INSTALL_DYNAMO_PLATFORM" == 'true' ]] || return
  [[ -f "$DYNAMO_PLATFORM_VALUES_FILE" ]] || die "Dynamo Platform values file not found: $DYNAMO_PLATFORM_VALUES_FILE"
  lineprint
  printstyle "Installing exact Dynamo Platform v${DYNAMO_PLATFORM_VERSION} ...\n" info

  helm upgrade --install dynamo-platform \
    'oci://helm.ngc.nvidia.com/nvidia/ai-dynamo/charts/dynamo-platform' \
    --namespace "$DYNAMO_NAMESPACE" \
    --create-namespace \
    --version "$DYNAMO_PLATFORM_VERSION" \
    --values "$DYNAMO_PLATFORM_VALUES_FILE" \
    --wait \
    --timeout=15m

  helm status dynamo-platform -n "$DYNAMO_NAMESPACE" >/dev/null
  kubectl get crd dynamographdeployments.nvidia.com >/dev/null || die 'DynamoGraphDeployment CRD was not installed.'
  while IFS= read -r resource; do
    [[ -n "$resource" ]] || continue
    kubectl -n "$DYNAMO_NAMESPACE" rollout status "$resource" --timeout=900s
  done < <(kubectl -n "$DYNAMO_NAMESPACE" get deployment,statefulset -o name)

  images="$(kubectl -n "$DYNAMO_NAMESPACE" get pods -o jsonpath='{..image}')" || die 'Failed to inspect Dynamo Platform images.'
  grep -Fq "kubernetes-operator:${DYNAMO_PLATFORM_VERSION}" <<< "$images" || \
    die "Dynamo Kubernetes Operator image is not pinned to ${DYNAMO_PLATFORM_VERSION}."
  printstyle 'Dynamo Platform and cluster-wide Operator installation succeeded.\n\n' success
}

prepull_dynamo_vllm_runtime() {
  local index target pull_command

  [[ "$INSTALL_DYNAMO_PLATFORM" == 'true' && "$PREPULL_DYNAMO_VLLM_IMAGE" == 'true' ]] || return
  lineprint
  printstyle "Pre-pulling Dynamo vLLM runtime image on every GPU worker: ${DYNAMO_VLLM_IMAGE} ...\n" info
  for index in "${!WORKER_IPS[@]}"; do
    target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
    printstyle "Pulling runtime image on $target ...\n" info
    pull_command="/usr/local/bin/ctr --namespace k8s.io images pull '${DYNAMO_VLLM_IMAGE}' && /usr/local/bin/ctr --namespace k8s.io images list -q | grep -Fx '${DYNAMO_VLLM_IMAGE}'"
    remote_privileged_command "$index" "$pull_command" >/dev/null || die "Failed to pre-pull ${DYNAMO_VLLM_IMAGE} on $target."
  done
  printstyle "Dynamo vLLM runtime image is present on all ${WORKER_COUNT} GPU workers (bundled vLLM ${DYNAMO_VLLM_VERSION}).\n\n" success
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
  local target password remote_dir local_config join_base64 remote_command status

  target="${WORKER_USERS[$index]}@${WORKER_IPS[$index]}"
  password="${WORKER_PASSWORDS[$index]}"
  remote_dir="/tmp/k8s-cluster-bootstrap-${KUBERNETES_VERSION//./-}"
  local_config="$(mktemp)"
  LOCAL_TEMP_PATHS+=("$local_config")
  join_base64="$(printf '%s' "$join_command" | base64 -w0)"

  {
    printf 'NODE_ROLE=worker\n'
    printf 'KUBERNETES_VERSION=%s\n' "$KUBERNETES_VERSION"
    printf 'CONTAINERD_VERSION=%s\n' "$CONTAINERD_VERSION"
    printf 'CALICO_VERSION=%s\n' "$CALICO_VERSION"
    printf 'HELM_VERSION=%s\n' "$HELM_VERSION"
    printf 'CONTROL_PLANE_IP=%s\n' "$CONTROL_PLANE_IP"
    printf 'POD_CIDR=%s\n' "$POD_CIDR"
    printf 'INSTALL_CALICO=%s\n' "$INSTALL_CALICO"
    printf 'INSTALL_METRICS_SERVER=false\n'
    printf 'REGULAR_USER_HOME=\n'
    printf 'WORKER_COUNT=0\n'
    printf 'INSTALL_NVIDIA_STACK=%s\n' "$INSTALL_NVIDIA_STACK"
    printf 'NVIDIA_DRIVER_VERSION=%s\n' "$NVIDIA_DRIVER_VERSION"
    printf 'NVIDIA_CONTAINER_TOOLKIT_VERSION=%s\n' "$NVIDIA_CONTAINER_TOOLKIT_VERSION"
    printf 'NVIDIA_GPU_MODEL=%s\n' "$NVIDIA_GPU_MODEL"
    printf 'NVIDIA_GPU_COUNT_PER_WORKER=%s\n' "$NVIDIA_GPU_COUNT_PER_WORKER"
    printf 'GPU_OPERATOR_VERSION=%s\n' "$GPU_OPERATOR_VERSION"
    printf 'INSTALL_DYNAMO_PLATFORM=false\n'
    printf 'DYNAMO_PLATFORM_VERSION=%s\n' "$DYNAMO_PLATFORM_VERSION"
    printf 'DYNAMO_VLLM_VERSION=%s\n' "$DYNAMO_VLLM_VERSION"
    printf 'DYNAMO_VLLM_IMAGE=%s\n' "$DYNAMO_VLLM_IMAGE"
    printf 'DYNAMO_NAMESPACE=%s\n' "$DYNAMO_NAMESPACE"
    printf 'PREPULL_DYNAMO_VLLM_IMAGE=false\n'
    printf 'JOIN_COMMAND_BASE64=%s\n' "$join_base64"
  } > "$local_config"
  chmod 600 "$local_config"

  lineprint
  printstyle "Installing and joining worker $target ...\n" info
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

verify_cluster() {
  local timeout='600s'
  local expected_nodes actual_nodes api_status calico_node_image kubelet_versions runtime_versions

  expected_nodes=$((WORKER_COUNT + 1))
  lineprint
  printstyle 'Verifying the completed cluster ...\n' info

  kubectl wait --for=condition=Ready nodes --all --timeout="$timeout" || die 'Not all Kubernetes nodes became Ready.'
  actual_nodes="$(kubectl get nodes --no-headers | wc -l | tr -d '[:space:]')"
  [[ "$actual_nodes" == "$expected_nodes" ]] || die "Expected $expected_nodes nodes, but Kubernetes reports $actual_nodes."
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
  kubectl -n kube-system rollout status deployment/coredns --timeout="$timeout"

  if [[ "$INSTALL_CALICO" == 'true' ]]; then
    kubectl -n kube-system rollout status daemonset/calico-node --timeout="$timeout"
    kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout="$timeout"
    calico_node_image="$(kubectl -n kube-system get daemonset/calico-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="calico-node")].image}')"
    [[ "$calico_node_image" == *"calico/node:v${CALICO_VERSION}" ]] || die "Calico node image does not match v${CALICO_VERSION}: $calico_node_image"
  fi
  if [[ "$INSTALL_METRICS_SERVER" == 'true' ]]; then
    kubectl -n kube-system rollout status deployment/metrics-server --timeout="$timeout"
  fi

  lineprint
  kubectl get nodes -o wide
  printf '\n'
  kubectl get pods --all-namespaces
  lineprint
  printstyle "Cluster verification succeeded: ${actual_nodes}/${expected_nodes} nodes are Ready.\n" success
  printstyle "Versions: Kubernetes v${KUBERNETES_VERSION}, containerd v${CONTAINERD_VERSION}, Calico v${CALICO_VERSION}\n" success
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

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die 'Please run this script as root.'
fi
if (( $# != 0 )); then
  die 'This bootstrap does not accept command-line options. Edit cluster.env instead.'
fi

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/cluster.env}"
MANIFEST_DIR="$SCRIPT_DIR/manifests"
GPU_OPERATOR_VALUES_FILE="$MANIFEST_DIR/gpu-operator-values.yaml"
DYNAMO_PLATFORM_VALUES_FILE="$MANIFEST_DIR/dynamo-platform-values.yaml"
CRI_SOCKET='unix:///run/containerd/containerd.sock'
NODE_ROLE=''
KUBERNETES_VERSION=''
CONTAINERD_VERSION=''
CALICO_VERSION=''
HELM_VERSION=''
CONTROL_PLANE_IP=''
POD_CIDR=''
INSTALL_CALICO='true'
INSTALL_METRICS_SERVER='false'
REGULAR_USER_HOME=''
WORKER_COUNT=''
JOIN_COMMAND_BASE64=''
INSTALL_NVIDIA_STACK='true'
NVIDIA_DRIVER_VERSION=''
NVIDIA_CONTAINER_TOOLKIT_VERSION=''
NVIDIA_GPU_MODEL=''
NVIDIA_GPU_COUNT_PER_WORKER=''
GPU_OPERATOR_VERSION=''
INSTALL_DYNAMO_PLATFORM='true'
DYNAMO_PLATFORM_VERSION=''
DYNAMO_VLLM_VERSION=''
DYNAMO_VLLM_IMAGE=''
DYNAMO_NAMESPACE='dynamo-system'
PREPULL_DYNAMO_VLLM_IMAGE='true'
KUBERNETES_MINOR_VERSION=''
KUBERNETES_PACKAGE_VERSION=''
CALICO_TAG=''
declare -a WORKER_IPS=()
declare -a WORKER_USERS=()
declare -a WORKER_PASSWORDS=()
declare -a LOCAL_TEMP_PATHS=()
SSH_OPTIONS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15)
SCP_OPTIONS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
trap cleanup_local_temp_paths EXIT

load_config
require_config_value NODE_ROLE
require_config_value KUBERNETES_VERSION
require_config_value CONTAINERD_VERSION
require_config_value CALICO_VERSION
require_config_value HELM_VERSION
require_config_value CONTROL_PLANE_IP
require_config_value NVIDIA_DRIVER_VERSION
require_config_value NVIDIA_CONTAINER_TOOLKIT_VERSION
require_config_value NVIDIA_GPU_MODEL
require_config_value NVIDIA_GPU_COUNT_PER_WORKER
require_config_value GPU_OPERATOR_VERSION
require_config_value DYNAMO_PLATFORM_VERSION
require_config_value DYNAMO_VLLM_VERSION
require_config_value DYNAMO_VLLM_IMAGE
require_config_value DYNAMO_NAMESPACE
validate_versions
validate_bool INSTALL_CALICO "$INSTALL_CALICO"
validate_bool INSTALL_METRICS_SERVER "$INSTALL_METRICS_SERVER"
validate_bool INSTALL_NVIDIA_STACK "$INSTALL_NVIDIA_STACK"
validate_bool INSTALL_DYNAMO_PLATFORM "$INSTALL_DYNAMO_PLATFORM"
validate_bool PREPULL_DYNAMO_VLLM_IMAGE "$PREPULL_DYNAMO_VLLM_IMAGE"
if [[ "$INSTALL_DYNAMO_PLATFORM" == 'true' && "$INSTALL_NVIDIA_STACK" != 'true' ]]; then
  die 'INSTALL_DYNAMO_PLATFORM=true requires INSTALL_NVIDIA_STACK=true.'
fi
if [[ "$PREPULL_DYNAMO_VLLM_IMAGE" == 'true' && "$INSTALL_DYNAMO_PLATFORM" != 'true' ]]; then
  die 'PREPULL_DYNAMO_VLLM_IMAGE=true requires INSTALL_DYNAMO_PLATFORM=true.'
fi
valid_ipv4 "$CONTROL_PLANE_IP" || die "Invalid CONTROL_PLANE_IP: $CONTROL_PLANE_IP"
if [[ "$INSTALL_CALICO" == 'true' ]]; then
  require_config_value POD_CIDR
  valid_cidr "$POD_CIDR" || die "Invalid POD_CIDR: $POD_CIDR"
fi

printstyle "Configuration: $CONFIG_FILE\n" info
printstyle "Core versions: Kubernetes v${KUBERNETES_VERSION}, containerd v${CONTAINERD_VERSION}, Calico v${CALICO_VERSION}\n" info
printstyle "GPU/AI versions: Toolkit v${NVIDIA_CONTAINER_TOOLKIT_VERSION}, GPU Operator v${GPU_OPERATOR_VERSION}, Dynamo v${DYNAMO_PLATFORM_VERSION}, vLLM v${DYNAMO_VLLM_VERSION}\n" info

case "$NODE_ROLE" in
  worker)
    install_node_components
    install_nvidia_container_toolkit
    join_worker_node
    ;;
  control-plane)
    [[ ! -e /etc/kubernetes/admin.conf ]] || die 'An existing Kubernetes control plane was detected. Refusing to overwrite it.'
    collect_workers
    if [[ "$INSTALL_NVIDIA_STACK" == 'true' && "$WORKER_COUNT" == '0' ]]; then
      die 'INSTALL_NVIDIA_STACK=true requires at least one worker.'
    fi
    install_orchestration_dependencies
    preflight_remote_access
    install_node_components
    initialize_control_plane
    install_calico
    install_metrics_server

    JOIN_COMMAND="$(kubeadm token create --print-join-command) --cri-socket=${CRI_SOCKET}"
    [[ -n "$JOIN_COMMAND" ]] || die 'Failed to create the worker join command.'
    for index in "${!WORKER_IPS[@]}"; do
      install_remote_worker "$index" "$JOIN_COMMAND"
    done
    verify_cluster
    if [[ "$INSTALL_NVIDIA_STACK" == 'true' || "$INSTALL_DYNAMO_PLATFORM" == 'true' ]]; then
      install_helm
    fi
    install_gpu_operator
    install_dynamo_platform
    prepull_dynamo_vllm_runtime
    lineprint
    printstyle 'Full bootstrap completed successfully. No DGD or inference workload was applied.\n' success
    printstyle "Prepared runtime: ${DYNAMO_VLLM_IMAGE} (bundled vLLM ${DYNAMO_VLLM_VERSION}).\n" success
    ;;
  *)
    die 'NODE_ROLE must be control-plane. The worker role is reserved for internal remote execution.'
    ;;
esac
