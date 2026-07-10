#!/usr/bin/env bash
# bluegreen-validation.sh
# Integrated setup and validation script for Rocky Linux 9.8 with GPU and Ollama.

set -euo pipefail

export HOME=/root

APP_USER="appsuser"

OLLAMA_PORT=8502
OLLAMA_SERVICE_HOST="0.0.0.0:${OLLAMA_PORT}"
OLLAMA_CLIENT_HOST="http://127.0.0.1:${OLLAMA_PORT}"
OLLAMA_MODELS="/data/apps/ollama/models"

OLLAMA_TEST_MODEL="${OLLAMA_TEST_MODEL:-}"
OLLAMA_TEST_PROMPT="${OLLAMA_TEST_PROMPT:-Write a 500 word poem about blue green deployment on a GPU server.}"
OLLAMA_TEST_OUTPUT="/var/log/ollama-model-test-output.txt"

DOCKER_DATA_ROOT="/opt/apps/docker"

LOG_FILE="/var/log/bluegreen-validation.log"
SUMMARY_FILE="/var/log/bluegreen-validation-summary.json"

log() {
  local msg="[$(date '+%F %T')] $*"
  echo "${msg}"
  echo "${msg}" >> "${LOG_FILE}"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Run this script as root or with sudo."
}

init_log() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  : > "${LOG_FILE}"
}


install_base_packages() {
  log "Installing base packages..."
  dnf install -y dnf-plugins-core curl ca-certificates zstd
}

install_nvidia_gpu_drivers() {
  log "Installing NVIDIA drivers and CUDA Toolkit..."
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    dnf install -y epel-release
    dnf config-manager --set-enabled crb
    dnf makecache
    dnf groupinstall -y "Development Tools"
    dnf install -y kernel-devel-$(uname -r) kernel-headers-$(uname -r) dkms gcc make
    dnf config-manager --add-repo http://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
    dnf makecache
    dnf module install -y nvidia-driver:latest-dkms
    dnf install -y cuda-toolkit
  else
    log "NVIDIA Drivers already installed: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
  fi
}

install_docker() {
  log "Installing Docker..."

  if ! command -v docker >/dev/null 2>&1; then
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  else
    log "Docker already installed: $(docker --version)"
  fi
}

install_nvidia_container_toolkit() {
  log "Installing NVIDIA Container Toolkit..."
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | tee /etc/yum.repos.d/nvidia-container-toolkit.repo
    dnf install -y nvidia-container-toolkit
  else
    log "NVIDIA Container Toolkit already installed: $(nvidia-ctk --version | head -1)"
  fi
}

install_docker_compose_github() {
  log "Installing Docker Compose from GitHub..."

  local arch compose_arch
  arch="$(uname -m)"

  case "${arch}" in
    x86_64) compose_arch="x86_64" ;;
    aarch64|arm64) compose_arch="aarch64" ;;
    *) fail "Unsupported architecture for docker-compose: ${arch}" ;;
  esac

  curl -fL \
    "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${compose_arch}" \
    -o /usr/local/bin/docker-compose

  chmod 755 /usr/local/bin/docker-compose
  ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

  docker-compose version | tee -a "${LOG_FILE}"
}

configure_docker() {
  log "Configuring Docker data-root..."

  mkdir -p "${DOCKER_DATA_ROOT}"
  mkdir -p /etc/docker

  cat >/etc/docker/daemon.json <<EOF
{
  "data-root": "${DOCKER_DATA_ROOT}",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF

  systemctl daemon-reload
  systemctl enable docker.service
  systemctl restart docker.service
}

install_ollama() {
  log "Installing Ollama..."

  if ! command -v ollama >/dev/null 2>&1; then
    curl -fsSL https://ollama.com/install.sh | sh
  else
    log "Ollama already installed: $(ollama --version || true)"
  fi
}

configure_ollama() {
  log "Configuring Ollama service..."

  mkdir -p /data/apps/ollama
  mkdir -p "${OLLAMA_MODELS}"

  if ! id ollama >/dev/null 2>&1; then
    useradd -r -s /sbin/nologin ollama || true
  fi

  chown -R ollama:ollama /data/apps/ollama
  chmod -R g+rwX /data/apps/ollama

  cat >/etc/systemd/system/ollama.service <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
Type=simple
User=ollama
Group=ollama

Environment="OLLAMA_HOST=${OLLAMA_SERVICE_HOST}"
Environment="OLLAMA_PORT=${OLLAMA_PORT}"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS}"

ExecStart=/usr/local/bin/ollama serve
WorkingDirectory=/data/apps/ollama

Restart=always
RestartSec=3

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl stop ollama.service || true
  systemctl daemon-reload
  systemctl enable ollama.service
  systemctl start ollama.service
}

configure_appsuser_access() {
  log "Configuring ${APP_USER} access..."

  id "${APP_USER}" >/dev/null 2>&1 || fail "${APP_USER} does not exist"

  usermod -aG docker "${APP_USER}"
  usermod -aG ollama "${APP_USER}"

  getent group video >/dev/null 2>&1 && usermod -aG video "${APP_USER}"
  getent group render >/dev/null 2>&1 && usermod -aG render "${APP_USER}"

  log "${APP_USER} access configured"
}

detect_cuda_home() {
  local cuda_home="/usr/local/cuda"

  if [[ -L /usr/local/cuda ]]; then
    cuda_home="$(readlink -f /usr/local/cuda)"
  elif ls -d /usr/local/cuda-* >/dev/null 2>&1; then
    cuda_home="$(ls -d /usr/local/cuda-* | sort -V | tail -1)"
  fi

  echo "${cuda_home}"
}

update_shell_profiles() {
  log "Updating root and ${APP_USER} .bashrc files..."

  local cuda_home
  cuda_home="$(detect_cuda_home)"

  local bash_block="
# BEGIN MANAGED GPU/OLLAMA ENVIRONMENT
export CUDA_HOME=${cuda_home}
export CUDA_PATH=${cuda_home}
export PATH="\${CUDA_HOME}/bin:/usr/local/bin:/usr/bin:/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="/usr/lib64:\${CUDA_HOME}/lib64:\${LD_LIBRARY_PATH:-}"

export OLLAMA_HOST=${OLLAMA_CLIENT_HOST}
export OLLAMA_PORT=${OLLAMA_PORT}
export OLLAMA_MODELS=${OLLAMA_MODELS}
# END MANAGED GPU/OLLAMA ENVIRONMENT
"

  for profile in /root/.bashrc "/home/${APP_USER}/.bashrc" "/home/rocky/.bashrc"; do
    [[ -f "${profile}" ]] || continue

    sed -i '/# BEGIN MANAGED GPU\/OLLAMA ENVIRONMENT/,/# END MANAGED GPU\/OLLAMA ENVIRONMENT/d' "${profile}"
    printf "\n%s\n" "${bash_block}" >> "${profile}"

    local owner
    owner=$(stat -c "%U:%G" "$(dirname "${profile}")")
    chown "${owner}" "${profile}"
  done

  # Write system-wide profile environment for all shells
  local profile_file="/etc/profile.d/ollama.sh"
  log "Creating system-wide profile environment at ${profile_file}..."
  cat > "${profile_file}" <<EOF
# System-wide GPU and Ollama configuration
export CUDA_HOME=${cuda_home}
export CUDA_PATH=${cuda_home}
export PATH="\${CUDA_HOME}/bin:/usr/local/bin:/usr/bin:/usr/sbin:\${PATH}"
export LD_LIBRARY_PATH="/usr/lib64:\${CUDA_HOME}/lib64:\${LD_LIBRARY_PATH:-}"

export OLLAMA_HOST=${OLLAMA_CLIENT_HOST}
export OLLAMA_PORT=${OLLAMA_PORT}
export OLLAMA_MODELS=${OLLAMA_MODELS}
EOF
  chmod 644 "${profile_file}"

  # Configure sudo to preserve Ollama environment variables
  log "Configuring sudo to preserve Ollama environment variables..."
  echo 'Defaults env_keep += "OLLAMA_HOST OLLAMA_PORT"' > /etc/sudoers.d/ollama
  chmod 440 /etc/sudoers.d/ollama
}

validate_gpu() {
  log "===== GPU VALIDATION ====="

  command -v nvidia-smi >/dev/null || fail "nvidia-smi not found"

  nvidia-smi >> "${LOG_FILE}"

  log "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
  log "Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"
}

validate_cuda() {
  log "===== CUDA VALIDATION ====="

  local cuda_home
  cuda_home="$(grep '^export CUDA_HOME=' /root/.bashrc | tail -1 | cut -d= -f2)"

  [[ -d "${cuda_home}" ]] || fail "CUDA_HOME not found: ${cuda_home}"

  if [[ -x "${cuda_home}/bin/nvcc" ]]; then
    "${cuda_home}/bin/nvcc" --version >> "${LOG_FILE}"
  else
    log "WARNING: nvcc not found under ${cuda_home}/bin"
  fi

  log "CUDA_HOME=${cuda_home}"
}

validate_docker() {
  log "===== DOCKER VALIDATION ====="

  systemctl is-active --quiet docker.service || fail "docker.service not running"

  docker version >/dev/null || fail "docker command failed"
  docker-compose version >> "${LOG_FILE}" || fail "docker-compose failed"

  local root_dir
  root_dir="$(docker info --format '{{ .DockerRootDir }}')"

  [[ "${root_dir}" == "${DOCKER_DATA_ROOT}" ]] || \
    fail "Docker root mismatch. Expected ${DOCKER_DATA_ROOT}, got ${root_dir}"

  grep -q '"nvidia"' /etc/docker/daemon.json || fail "/etc/docker/daemon.json missing nvidia runtime"

  log "Docker RootDir: ${root_dir}"

  docker run --rm hello-world >> "${LOG_FILE}" 2>&1 || fail "Docker hello-world test failed"
}

validate_appsuser() {
  log "===== APPSUSER VALIDATION ====="

  id "${APP_USER}" >/dev/null || fail "${APP_USER} missing"

  id -nG "${APP_USER}" | grep -qw docker || fail "${APP_USER} not in docker group"
  id -nG "${APP_USER}" | grep -qw ollama || fail "${APP_USER} not in ollama group"

  su - "${APP_USER}" -c "docker ps" >> "${LOG_FILE}" 2>&1 || \
    fail "${APP_USER} cannot run docker ps"

  su - "${APP_USER}" -c "nvidia-smi" >> "${LOG_FILE}" 2>&1 || \
    fail "${APP_USER} cannot run nvidia-smi"

  su - "${APP_USER}" -c "OLLAMA_HOST=${OLLAMA_CLIENT_HOST} ollama list" >> "${LOG_FILE}" 2>&1 || \
    fail "${APP_USER} cannot run ollama list"

  su - "${APP_USER}" -c "docker-compose version" >> "${LOG_FILE}" 2>&1 || \
    fail "${APP_USER} cannot run docker-compose"

  log "${APP_USER} Docker, NVIDIA, and Ollama access validated"
}

validate_ollama() {
  log "===== OLLAMA VALIDATION ====="

  systemctl is-active --quiet ollama.service || fail "ollama.service not running"
  systemctl is-enabled ollama.service >/dev/null || fail "ollama.service not enabled"

  grep -q '^User=ollama$' /etc/systemd/system/ollama.service || fail "ollama.service missing User=ollama"
  systemctl show ollama.service -p Environment | grep -q "OLLAMA_PORT=${OLLAMA_PORT}" || fail "OLLAMA_PORT mismatch"

  curl -fsS "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null || \
    fail "Ollama API not responding on ${OLLAMA_PORT}"

  ss -lntp | grep -q ":${OLLAMA_PORT}" || fail "Ollama not listening on ${OLLAMA_PORT}"

  if ss -lntp | grep -q ':11434'; then
    ss -lntp | grep ':11434' >> "${LOG_FILE}"
    fail "Ollama is listening on forbidden default port 11434"
  fi

  log "Installed Ollama models:"
  OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama list | tee -a "${LOG_FILE}"

  log "Ollama validation successful"
}

validate_ollama_model_gpu_run() {
  log "===== OLLAMA MODEL GPU RUNTIME VALIDATION ====="

  if [[ -z "${OLLAMA_TEST_MODEL}" ]]; then
    OLLAMA_TEST_MODEL="$(OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama list 2>/dev/null | awk 'NR==2 {print $1}')"
  fi
  if [[ -z "${OLLAMA_TEST_MODEL}" ]]; then
    log "No models found in ollama list. Defaulting to llama3.2 for testing."
    OLLAMA_TEST_MODEL="llama3.2"
  fi

  [[ -n "${OLLAMA_TEST_MODEL}" ]] || fail "No Ollama model found to test"

  log "Testing Ollama model: ${OLLAMA_TEST_MODEL}"
  log "Prompt: ${OLLAMA_TEST_PROMPT}"

  local before_gpu_mem after_gpu_mem before_gpu_proc after_gpu_proc
  before_gpu_mem="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
  before_gpu_proc="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | grep -i ollama || true)"

  timeout 300s bash -c "
    OLLAMA_HOST='${OLLAMA_CLIENT_HOST}' ollama run '${OLLAMA_TEST_MODEL}' '${OLLAMA_TEST_PROMPT}'
  " > "${OLLAMA_TEST_OUTPUT}" 2>&1 || fail "ollama run test failed for model ${OLLAMA_TEST_MODEL}"

  cat "${OLLAMA_TEST_OUTPUT}" >> "${LOG_FILE}"

  after_gpu_mem="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)"
  after_gpu_proc="$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | grep -i ollama || true)"

  log "GPU memory before model run: ${before_gpu_mem} MiB"
  log "GPU memory after model run : ${after_gpu_mem} MiB"

  {
    echo
    echo "===== NVIDIA GPU state after Ollama model run ====="
    nvidia-smi
    echo
    echo "===== Ollama GPU compute process before run ====="
    echo "${before_gpu_proc:-none}"
    echo
    echo "===== Ollama GPU compute process after run ====="
    echo "${after_gpu_proc:-none}"
  } >> "${LOG_FILE}"

  if [[ -n "${after_gpu_proc}" ]]; then
    log "Ollama GPU compute process detected"
  elif [[ "${after_gpu_mem}" -gt "${before_gpu_mem}" ]]; then
    log "GPU memory increased during Ollama model run"
  else
    fail "Could not validate Ollama NVIDIA GPU usage"
  fi

  grep -qiE "poem|deployment|server|gpu|blue|green" "${OLLAMA_TEST_OUTPUT}" || \
    fail "Ollama test output did not contain expected generated content"

  log "Ollama model runtime and NVIDIA GPU validation successful"
}

validate_zstd() {
  log "===== ZSTD VALIDATION ====="
  zstd --version | tee -a "${LOG_FILE}"
}

validate_filesystem() {
  log "===== FILESYSTEM VALIDATION ====="
  df -h "${DOCKER_DATA_ROOT}" /data/apps/ollama >> "${LOG_FILE}" 2>&1 || true
  [[ "$(stat -c "%U:%G" "${OLLAMA_MODELS}")" == "ollama:ollama" ]] || fail "Ollama models ownership mismatch"
  log "Filesystem validation successful"
}

validate_shell_profiles() {
  log "===== SHELL PROFILE VALIDATION ====="
  for profile in /root/.bashrc "/home/${APP_USER}/.bashrc"; do
    grep -q "OLLAMA_PORT=${OLLAMA_PORT}" "${profile}" || fail "${profile} missing environment variables"
    log "Validated ${profile}"
  done
}

capture_service_logs() {
  log "===== SERVICE LOG CAPTURE ====="

  {
    echo
    echo "===== docker.service logs ====="
    journalctl -u docker.service -n 50 --no-pager || true

    echo
    echo "===== ollama.service logs ====="
    journalctl -u ollama.service -n 50 --no-pager || true
  } >> "${LOG_FILE}"
}

validation_summary() {
  log "===== BLUE/GREEN VALIDATION SUMMARY ====="

  local gpu_name driver_version docker_root compose_version cuda_home model_count
  gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 || echo unknown)"
  driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 || echo unknown)"
  docker_root="$(docker info --format '{{ .DockerRootDir }}' 2>/dev/null || echo unknown)"
  compose_version="$(docker-compose version --short 2>/dev/null || echo unknown)"
  cuda_home="$(grep '^export CUDA_HOME=' /root/.bashrc | tail -1 | cut -d= -f2 || echo unknown)"
  model_count="$(OLLAMA_HOST="${OLLAMA_CLIENT_HOST}" ollama list 2>/dev/null | tail -n +2 | wc -l || echo 0)"

  log "GPU                : ${gpu_name}"
  log "Driver             : ${driver_version}"
  log "Docker RootDir     : ${docker_root}"
  log "Docker Compose     : ${compose_version}"
  log "Apps User          : ${APP_USER}"
  log "Ollama Port        : ${OLLAMA_PORT}"
  log "Ollama Service Host: ${OLLAMA_SERVICE_HOST}"
  log "Ollama Client Host : ${OLLAMA_CLIENT_HOST}"
  log "Ollama Models Path : ${OLLAMA_MODELS}"
  log "Ollama Test Model  : ${OLLAMA_TEST_MODEL:-none}"
  log "Model Count        : ${model_count}"
  log "CUDA Home          : ${cuda_home}"
  log "Validation         : PASSED"
  log "Log File           : ${LOG_FILE}"
  log "Summary File       : ${SUMMARY_FILE}"
  log "Test Output File   : ${OLLAMA_TEST_OUTPUT}"

  cat > "${SUMMARY_FILE}" <<EOF
{
  "validation": "PASSED",
  "gpu": "${gpu_name}",
  "driver": "${driver_version}",
  "docker_root": "${docker_root}",
  "docker_compose": "${compose_version}",
  "apps_user": "${APP_USER}",
  "ollama_port": ${OLLAMA_PORT},
  "ollama_service_host": "${OLLAMA_SERVICE_HOST}",
  "ollama_client_host": "${OLLAMA_CLIENT_HOST}",
  "ollama_models": "${OLLAMA_MODELS}",
  "ollama_test_model": "${OLLAMA_TEST_MODEL:-}",
  "model_count": ${model_count},
  "cuda_home": "${cuda_home}",
  "log_file": "${LOG_FILE}",
  "ollama_test_output": "${OLLAMA_TEST_OUTPUT}"
}
EOF
}

main() {
  require_root
  init_log

  log "Starting Rocky Linux 9.8 GPU blue/green bootstrap and validation"

  install_base_packages
  install_nvidia_gpu_drivers

  install_docker
  install_nvidia_container_toolkit
  install_docker_compose_github
  configure_docker

  install_ollama
  configure_ollama

  configure_appsuser_access
  update_shell_profiles

  validate_gpu
  validate_cuda
  validate_docker
  validate_appsuser
  validate_ollama
  validate_ollama_model_gpu_run
  validate_zstd
  validate_filesystem
  validate_shell_profiles
  capture_service_logs
  validation_summary

  log "Blue/green server validation complete."
}

main "$@"
