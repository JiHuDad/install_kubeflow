#!/usr/bin/env bash
# scripts/02-download-binaries.sh
# [준비 머신 — 인터넷 환경] 바이너리 및 K3s 관련 파일 다운로드
#
# 동작 흐름:
#   1. K3s 바이너리 + airgap 이미지 번들 다운로드
#   2. kubectl 바이너리 다운로드
#   3. kustomize 바이너리 다운로드
#   4. registry:2 이미지 tar 저장
#   5. checksums.sha256 생성
#
# 사전 요구사항: curl, docker

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

# K3s
K3S_ARCH="amd64"
K3S_BASE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"

# kubectl — K3s 버전과 맞춤 (v1.29.x)
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.29.14}"
KUBECTL_URL="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"

# kustomize
KUSTOMIZE_VERSION="${KUSTOMIZE_VERSION:-v5.3.0}"
KUSTOMIZE_URL="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz"

# registry:2
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2}"

# ─── 함수 ────────────────────────────────────────────────────────────────────

download_file() {
  local url="$1"
  local dest="$2"
  local desc="${3:-$dest}"

  if [[ -f "$dest" ]]; then
    log_info "이미 존재함, 건너뜀: $desc"
    return 0
  fi

  log_info "다운로드: $desc"
  log_info "  URL: $url"
  retry 3 5 curl -fsSL --progress-bar -o "$dest" "$url"
  log_success "완료: $dest"
}

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/02-download-binaries.log"
  log_step "바이너리 다운로드 시작"

  require_cmd curl docker

  mkdir -p "$BINARIES_DIR" "$IMAGES_DIR" "$LOG_DIR"

  # 1. K3s 바이너리
  log_step "K3s 바이너리"
  # K3s release URL 형식: k3s-airgap-images-amd64.tar.zst 또는 .tar.gz
  local k3s_binary="$BINARIES_DIR/k3s"
  local k3s_airgap_zst="$BINARIES_DIR/k3s-airgap-images-amd64.tar.zst"
  local k3s_install_sh="$BINARIES_DIR/k3s-install.sh"

  download_file \
    "${K3S_BASE_URL}/k3s" \
    "$k3s_binary" \
    "k3s binary (${K3S_VERSION})"
  chmod +x "$k3s_binary"

  # airgap 이미지 번들 (.tar.zst 우선, 없으면 .tar.gz)
  if ! download_file \
    "${K3S_BASE_URL}/k3s-airgap-images-${K3S_ARCH}.tar.zst" \
    "$k3s_airgap_zst" \
    "k3s airgap images (zst)"; then
    log_warn ".tar.zst 다운로드 실패, .tar.gz 시도..."
    download_file \
      "${K3S_BASE_URL}/k3s-airgap-images-${K3S_ARCH}.tar.gz" \
      "$BINARIES_DIR/k3s-airgap-images-amd64.tar.gz" \
      "k3s airgap images (gz)"
  fi

  # K3s 설치 스크립트 (오프라인 설치용)
  download_file \
    "https://get.k3s.io" \
    "$k3s_install_sh" \
    "k3s install script"
  chmod +x "$k3s_install_sh"

  # 2. kubectl
  log_step "kubectl"
  local kubectl_bin="$BINARIES_DIR/kubectl"
  download_file "$KUBECTL_URL" "$kubectl_bin" "kubectl (${KUBECTL_VERSION})"
  chmod +x "$kubectl_bin"

  # kubectl 체크섬 검증
  local kubectl_sha_url="${KUBECTL_URL}.sha256"
  local kubectl_sha_file="$BINARIES_DIR/kubectl.sha256"
  download_file "$kubectl_sha_url" "$kubectl_sha_file" "kubectl.sha256"
  log_info "kubectl 체크섬 검증..."
  (cd "$BINARIES_DIR" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check)
  log_success "kubectl 체크섬 OK"

  # 3. kustomize
  log_step "kustomize"
  local kustomize_tgz="$BINARIES_DIR/kustomize.tar.gz"
  download_file "$KUSTOMIZE_URL" "$kustomize_tgz" "kustomize (${KUSTOMIZE_VERSION})"
  if [[ ! -f "$BINARIES_DIR/kustomize" ]]; then
    log_info "kustomize 압축 해제..."
    tar -xzf "$kustomize_tgz" -C "$BINARIES_DIR"
    chmod +x "$BINARIES_DIR/kustomize"
  fi
  log_success "kustomize 준비 완료"

  # 4. registry:2 이미지
  log_step "registry:2 이미지"
  local registry_tar="$IMAGES_DIR/registry-2.tar"
  if [[ -f "$registry_tar" ]]; then
    log_info "이미 존재함: $registry_tar"
  else
    log_info "docker pull $REGISTRY_IMAGE"
    retry 3 5 docker pull --platform linux/amd64 "$REGISTRY_IMAGE"
    log_info "docker save → registry-2.tar"
    docker save "$REGISTRY_IMAGE" -o "$registry_tar"
    log_success "registry:2 저장 완료"
  fi

  # 5. checksums.sha256 생성
  log_step "체크섬 생성"
  compute_checksums "$BUNDLE_DIR/checksums.sha256" "$BUNDLE_DIR"

  # 6. 번들 구조 출력
  log_step "번들 구조"
  find "$BUNDLE_DIR" -type f | sort | sed "s|$BUNDLE_DIR/||"

  log_success "바이너리 다운로드 완료!"
  log_info "번들 경로: $BUNDLE_DIR"
}

main "$@"
