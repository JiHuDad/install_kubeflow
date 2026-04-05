#!/usr/bin/env bash
# scripts/22-uninstall.sh
# [폐쇄망] KFP 및 K3s 언인스톨
#
# 경고: 이 작업은 되돌릴 수 없습니다. 실행 전 21-backup.sh 로 백업하세요.

set -euo pipefail
trap 'log_error "오류 발생 (line $LINENO)"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

KFP_NAMESPACE="kubeflow"
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config" ]]; then
    KUBECONFIG="${HOME}/.kube/config"
  else
    KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  fi
fi
REGISTRY_CONTAINER_NAME="kfp-registry"
export KUBECONFIG

main() {
  init_log "$LOG_DIR/22-uninstall.log"
  log_step "KFP 언인스톨"

  # 확인 프롬프트
  log_warn "이 작업은 KFP 및 K3s를 완전히 제거합니다."
  log_warn "모든 파이프라인 데이터와 설정이 삭제됩니다."
  echo ""
  read -r -p "계속하시겠습니까? 'yes'를 입력하세요: " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_info "언인스톨을 취소했습니다."
    exit 0
  fi

  # 1. KFP namespace 삭제
  log_step "KFP namespace 삭제"
  if kubectl get namespace "$KFP_NAMESPACE" &>/dev/null 2>&1; then
    kubectl delete namespace "$KFP_NAMESPACE" --timeout=120s || \
      log_warn "namespace 삭제 타임아웃 — 강제 정리될 수 있습니다."
    log_success "KFP namespace 삭제 완료"
  else
    log_info "KFP namespace가 없습니다. 건너뜁니다."
  fi

  # 2. 레지스트리 컨테이너 제거
  log_step "로컬 레지스트리 컨테이너 제거"
  if optional_cmd nerdctl; then
    nerdctl stop "$REGISTRY_CONTAINER_NAME" 2>/dev/null || true
    nerdctl rm "$REGISTRY_CONTAINER_NAME" 2>/dev/null || true
    log_success "레지스트리 컨테이너 제거 (nerdctl)"
  elif optional_cmd docker; then
    docker stop "$REGISTRY_CONTAINER_NAME" 2>/dev/null || true
    docker rm "$REGISTRY_CONTAINER_NAME" 2>/dev/null || true
    log_success "레지스트리 컨테이너 제거 (docker)"
  fi

  # 3. K3s 언인스톨
  log_step "K3s 언인스톨"
  if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
    bash /usr/local/bin/k3s-uninstall.sh
    log_success "K3s 언인스톨 완료"
  else
    log_warn "k3s-uninstall.sh 를 찾을 수 없습니다. 수동으로 K3s를 제거하세요."
  fi

  # 4. registries.yaml 제거
  rm -f /etc/rancher/k3s/registries.yaml 2>/dev/null || true

  log_success "언인스톨 완료!"
  log_info "레지스트리 데이터 디렉터리(/var/lib/kfp-registry)는 수동으로 삭제하세요."
}

main "$@"
