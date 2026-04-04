#!/usr/bin/env bash
# scripts/11-setup-registry.sh
# [폐쇄망] 로컬 컨테이너 레지스트리(registry:2) 구성
#
# 동작 흐름:
#   1. registry:2 이미지 로드 (containerd)
#   2. 레지스트리 컨테이너 기동 (localhost:5000)
#   3. K3s registries.yaml 작성 (미러 설정)
#   4. K3s 재시작 (registries.yaml 반영)
#
# 실행 권한: sudo (또는 root)

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-$ROOT_DIR/airgap-bundle}"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_CONTAINER_NAME="kfp-registry"
REGISTRY_DATA_DIR="/var/lib/kfp-registry"
K3S_REGISTRIES_YAML="/etc/rancher/k3s/registries.yaml"

# ─── 함수 ────────────────────────────────────────────────────────────────────

load_registry_image_containerd() {
  local tar="$IMAGES_DIR/registry-2.tar"
  if [[ ! -f "$tar" ]]; then
    log_error "registry-2.tar 를 찾을 수 없습니다: $tar"
    exit 1
  fi
  log_info "containerd로 이미지 로드: $tar"
  ctr images import "$tar"
  log_success "registry:2 이미지 로드 완료"
}

start_registry_nerdctl() {
  # nerdctl(K3s 내장 containerd 클라이언트)로 컨테이너 실행
  if nerdctl ps --filter "name=$REGISTRY_CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null \
      | grep -q "$REGISTRY_CONTAINER_NAME"; then
    log_info "레지스트리가 이미 실행 중입니다."
    return 0
  fi
  mkdir -p "$REGISTRY_DATA_DIR"
  nerdctl run -d \
    --name "$REGISTRY_CONTAINER_NAME" \
    --restart always \
    -p "${REGISTRY_PORT}:5000" \
    -v "$REGISTRY_DATA_DIR:/var/lib/registry" \
    registry:2
}

start_registry_docker() {
  # docker가 있는 경우 사용
  if docker ps --filter "name=$REGISTRY_CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null \
      | grep -q "$REGISTRY_CONTAINER_NAME"; then
    log_info "레지스트리가 이미 실행 중입니다."
    return 0
  fi
  # 중지된 컨테이너 재시작
  if docker ps -a --filter "name=$REGISTRY_CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null \
      | grep -q "$REGISTRY_CONTAINER_NAME"; then
    docker start "$REGISTRY_CONTAINER_NAME"
    log_success "기존 레지스트리 컨테이너 재시작"
    return 0
  fi

  mkdir -p "$REGISTRY_DATA_DIR"
  docker run -d \
    --name "$REGISTRY_CONTAINER_NAME" \
    --restart always \
    -p "${REGISTRY_PORT}:5000" \
    -v "$REGISTRY_DATA_DIR:/var/lib/registry" \
    registry:2
}

write_k3s_registries() {
  log_info "K3s registries.yaml 작성: $K3S_REGISTRIES_YAML"
  mkdir -p "$(dirname "$K3S_REGISTRIES_YAML")"

  cat > "$K3S_REGISTRIES_YAML" <<EOF
# K3s 레지스트리 미러 설정 — 폐쇄망용
# 외부 레지스트리를 localhost:${REGISTRY_PORT} 로 미러링한다.
mirrors:
  "ghcr.io":
    endpoint:
      - "http://localhost:${REGISTRY_PORT}"
  "docker.io":
    endpoint:
      - "http://localhost:${REGISTRY_PORT}"
  "quay.io":
    endpoint:
      - "http://localhost:${REGISTRY_PORT}"
  "registry.k8s.io":
    endpoint:
      - "http://localhost:${REGISTRY_PORT}"
  "k8s.gcr.io":
    endpoint:
      - "http://localhost:${REGISTRY_PORT}"

configs:
  "localhost:${REGISTRY_PORT}":
    tls:
      insecure_skip_verify: true
EOF

  log_success "registries.yaml 작성 완료"
}

wait_registry_ready() {
  log_info "레지스트리 응답 대기..."
  local retries=20
  local i=0
  while [[ $i -lt $retries ]]; do
    if curl -sf "http://localhost:${REGISTRY_PORT}/v2/" &>/dev/null; then
      log_success "레지스트리가 준비되었습니다: http://localhost:${REGISTRY_PORT}"
      return 0
    fi
    sleep 2
    i=$(( i + 1 ))
  done
  log_error "레지스트리가 ${retries}회 시도 후에도 응답하지 않습니다."
  return 1
}

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/11-setup-registry.log"
  log_step "로컬 레지스트리 설정 시작"

  if [[ $EUID -ne 0 ]]; then
    log_error "이 스크립트는 root 권한이 필요합니다. sudo 로 실행하세요."
    exit 1
  fi

  # 1. 이미지 로드
  log_step "registry:2 이미지 로드"
  load_registry_image_containerd

  # 2. 레지스트리 컨테이너 기동
  log_step "레지스트리 컨테이너 기동"
  if optional_cmd nerdctl; then
    log_info "nerdctl로 레지스트리 기동"
    start_registry_nerdctl
  elif optional_cmd docker; then
    log_info "docker로 레지스트리 기동"
    load_registry_image_containerd  # docker에도 로드 필요
    docker load -i "$IMAGES_DIR/registry-2.tar"
    start_registry_docker
  else
    log_error "nerdctl 또는 docker 가 필요합니다."
    exit 1
  fi

  # 3. registries.yaml 작성
  log_step "K3s registries.yaml 작성"
  # 프로젝트 config/registries.yaml도 업데이트
  cp_target="$CONFIG_DIR/registries.yaml"
  write_k3s_registries
  mkdir -p "$CONFIG_DIR"
  cp "$K3S_REGISTRIES_YAML" "$cp_target" 2>/dev/null || true

  # 4. K3s 재시작
  log_step "K3s 재시작 (registries.yaml 반영)"
  systemctl restart k3s
  log_info "K3s 재시작 중... 30초 대기"
  sleep 10

  # K3s 복구 대기
  local timeout=120
  local elapsed=0
  while ! kubectl get nodes &>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then
      log_error "K3s 재시작 후 응답 없음 (${timeout}s 초과)"
      exit 1
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  log_success "K3s 재시작 완료"

  # 5. 레지스트리 응답 확인
  log_step "레지스트리 준비 확인"
  wait_registry_ready

  log_success "로컬 레지스트리 설정 완료!"
  log_info "레지스트리: http://localhost:${REGISTRY_PORT}"
  log_info "데이터 경로: $REGISTRY_DATA_DIR"
}

main "$@"
