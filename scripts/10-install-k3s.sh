#!/usr/bin/env bash
# scripts/10-install-k3s.sh
# [폐쇄망] K3s를 airgap 모드로 설치한다.
#
# 동작 흐름:
#   1. airgap 이미지 번들 → /var/lib/rancher/k3s/agent/images/ 배치
#   2. k3s 바이너리 → /usr/local/bin/k3s 설치
#   3. INSTALL_K3S_SKIP_DOWNLOAD=true 로 오프라인 설치 실행
#   4. systemd 서비스 시작 + 활성화
#   5. kubeconfig 복사 (~/.kube/config)
#   6. 노드 Ready 대기
#
# 사전 요구사항: airgap-bundle/ 이 현재 디렉터리에 존재할 것
# 실행 권한: sudo (또는 root)

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-$ROOT_DIR/airgap-bundle}"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

K3S_IMAGES_DEST="/var/lib/rancher/k3s/agent/images"
K3S_BIN_DEST="/usr/local/bin/k3s"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
USER_KUBECONFIG="${HOME}/.kube/config"

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/10-install-k3s.log"
  log_step "K3s airgap 설치 시작"

  # root 권한 확인
  if [[ $EUID -ne 0 ]]; then
    log_error "이 스크립트는 root 권한이 필요합니다. sudo 로 실행하세요."
    exit 1
  fi

  # 번들 존재 확인
  if [[ ! -d "$BINARIES_DIR" ]]; then
    log_error "바이너리 디렉터리가 없습니다: $BINARIES_DIR"
    log_error "먼저 02-download-binaries.sh 를 실행하세요."
    exit 1
  fi

  # 1. airgap 이미지 배치
  log_step "K3s airgap 이미지 배치"
  mkdir -p "$K3S_IMAGES_DEST"

  local airgap_file
  if [[ -f "$BINARIES_DIR/k3s-airgap-images-amd64.tar.zst" ]]; then
    airgap_file="$BINARIES_DIR/k3s-airgap-images-amd64.tar.zst"
  elif [[ -f "$BINARIES_DIR/k3s-airgap-images-amd64.tar.gz" ]]; then
    airgap_file="$BINARIES_DIR/k3s-airgap-images-amd64.tar.gz"
  else
    log_error "K3s airgap 이미지 파일을 찾을 수 없습니다: $BINARIES_DIR"
    exit 1
  fi

  local dest_file="$K3S_IMAGES_DEST/$(basename "$airgap_file")"
  if [[ -f "$dest_file" ]]; then
    log_info "이미 배치됨: $dest_file"
  else
    cp "$airgap_file" "$dest_file"
    log_success "airgap 이미지 배치: $dest_file"
  fi

  # 2. k3s 바이너리 설치
  log_step "k3s 바이너리 설치"
  local k3s_src="$BINARIES_DIR/k3s"
  if [[ ! -f "$k3s_src" ]]; then
    log_error "k3s 바이너리가 없습니다: $k3s_src"
    exit 1
  fi

  if [[ -f "$K3S_BIN_DEST" ]]; then
    log_info "이미 설치됨: $K3S_BIN_DEST"
  else
    cp "$k3s_src" "$K3S_BIN_DEST"
    chmod +x "$K3S_BIN_DEST"
    log_success "k3s 바이너리 설치: $K3S_BIN_DEST"
  fi

  # kubectl, crictl 심볼릭 링크 생성 (k3s가 내장)
  for link in kubectl crictl ctr; do
    if [[ ! -f "/usr/local/bin/$link" ]]; then
      ln -sf "$K3S_BIN_DEST" "/usr/local/bin/$link"
      log_info "심볼릭 링크 생성: /usr/local/bin/$link → $K3S_BIN_DEST"
    fi
  done

  # kubectl 바이너리가 번들에 있으면 내장 심볼릭 링크보다 우선 적용
  if [[ -f "$BINARIES_DIR/kubectl" ]]; then
    cp "$BINARIES_DIR/kubectl" /usr/local/bin/kubectl
    log_info "번들 kubectl 사용"
  fi

  # 3. K3s 서비스 설치 (오프라인)
  log_step "K3s 서비스 설치"

  if systemctl is-active --quiet k3s 2>/dev/null; then
    log_info "K3s가 이미 실행 중입니다. 건너뜁니다."
  else
    local install_sh="$BINARIES_DIR/k3s-install.sh"
    if [[ ! -f "$install_sh" ]]; then
      log_error "k3s-install.sh 가 없습니다: $install_sh"
      exit 1
    fi

    # INSTALL_K3S_SKIP_DOWNLOAD=true : 이미 설치한 바이너리 사용
    INSTALL_K3S_SKIP_DOWNLOAD=true \
    INSTALL_K3S_EXEC="server --disable traefik" \
      bash "$install_sh"
    log_success "K3s 서비스 설치 완료"
  fi

  # 4. 서비스 시작 및 활성화
  log_step "K3s 서비스 시작"
  systemctl enable k3s
  systemctl start k3s
  log_success "k3s 서비스 시작됨"

  # 5. kubeconfig 복사
  log_step "kubeconfig 설정"
  mkdir -p "$(dirname "$USER_KUBECONFIG")"
  cp "$K3S_KUBECONFIG" "$USER_KUBECONFIG"
  chmod 600 "$USER_KUBECONFIG"
  # SUDO_USER가 있으면 해당 사용자 홈에도 복사
  if [[ -n "${SUDO_USER:-}" ]]; then
    local sudo_home
    sudo_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$sudo_home/.kube"
    cp "$K3S_KUBECONFIG" "$sudo_home/.kube/config"
    chmod 600 "$sudo_home/.kube/config"
    chown "$SUDO_USER:$(id -gn "$SUDO_USER")" "$sudo_home/.kube/config"
    log_info "kubeconfig 복사: $sudo_home/.kube/config"
  fi
  log_success "kubeconfig 설정 완료"

  # 6. 노드 Ready 대기
  log_step "노드 Ready 대기 (최대 3분)"
  local timeout=180
  local interval=5
  local elapsed=0

  export KUBECONFIG="$K3S_KUBECONFIG"
  while true; do
    local status
    status=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1) || true
    if [[ "$status" == "Ready" ]]; then
      log_success "노드가 Ready 상태입니다!"
      break
    fi
    if [[ $elapsed -ge $timeout ]]; then
      log_error "타임아웃: 노드가 ${timeout}초 내에 Ready 상태가 되지 않았습니다."
      kubectl get nodes
      exit 1
    fi
    log_info "  대기 중... (${elapsed}s / ${timeout}s) 현재 상태: ${status:-unknown}"
    sleep $interval
    elapsed=$(( elapsed + interval ))
  done

  kubectl get nodes
  log_success "K3s 설치 완료!"
  log_info "버전: $(k3s --version)"
}

main "$@"
