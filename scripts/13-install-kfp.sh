#!/usr/bin/env bash
# scripts/13-install-kfp.sh
# [폐쇄망] Kubeflow Pipelines Standalone v2를 K3s 클러스터에 설치한다.
#
# 동작 흐름:
#   1. kustomize/overlays/airgap 으로 manifest 빌드
#      (이미지 prefix를 localhost:5000 으로 치환)
#   2. kubeflow namespace 생성
#   3. kubectl apply
#   4. ml-pipeline-ui Service를 NodePort로 패치
#   5. 모든 Pod Ready 대기
#
# 실행 권한: kubectl 접근 가능한 사용자 (또는 root)

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-$ROOT_DIR/airgap-bundle}"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

KFP_NAMESPACE="kubeflow"
KUSTOMIZE_OVERLAY_DIR="$ROOT_DIR/kustomize/overlays/airgap"
NODEPORT_PATCH="$ROOT_DIR/config/kfp-nodeport-patch.yaml"
# kubectl 기본 경로(~/.kube/config) 우선, 없으면 k3s 경로 fallback
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f "${HOME}/.kube/config" ]]; then
    KUBECONFIG="${HOME}/.kube/config"
  else
    KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
  fi
fi

export KUBECONFIG

# ─── 함수 ────────────────────────────────────────────────────────────────────

ensure_namespace() {
  if kubectl get namespace "$KFP_NAMESPACE" &>/dev/null; then
    log_info "Namespace '$KFP_NAMESPACE' 이미 존재합니다."
  else
    kubectl create namespace "$KFP_NAMESPACE"
    log_success "Namespace '$KFP_NAMESPACE' 생성 완료"
  fi
}

setup_kustomize_overlay() {
  log_info "kustomize overlay 확인: $KUSTOMIZE_OVERLAY_DIR"
  if [[ ! -f "$KUSTOMIZE_OVERLAY_DIR/kustomization.yaml" ]]; then
    log_error "kustomization.yaml 이 없습니다: $KUSTOMIZE_OVERLAY_DIR"
    log_error "config/ 및 kustomize/ 디렉터리가 번들에 포함되어 있는지 확인하세요."
    exit 1
  fi
}

wait_pods_ready() {
  local namespace="$1"
  local timeout="${2:-600}"
  log_info "Pod Ready 대기 중 (namespace: $namespace, timeout: ${timeout}s)..."

  local end=$(( $(date +%s) + timeout ))
  while true; do
    local total ready
    total=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo 0)
    ready=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null \
      | awk '$2 ~ /^[0-9]+\/[0-9]+$/ { split($2, a, "/"); if(a[1]==a[2] && a[1]>0) count++ } END{print count+0}')
    not_ready=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null \
      | grep -v " Running \| Completed " | grep -v "^$" | wc -l || echo 0)

    log_info "  Pod 상태: ${ready}/${total} Ready, ${not_ready} Not Ready"

    if [[ "$not_ready" -eq 0 && "$total" -gt 0 ]]; then
      log_success "모든 Pod가 Ready 상태입니다!"
      return 0
    fi

    if [[ $(date +%s) -ge $end ]]; then
      log_error "타임아웃: ${timeout}s 내에 모든 Pod가 Ready 되지 않았습니다."
      kubectl get pods -n "$namespace"
      return 1
    fi

    sleep 15
  done
}

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/13-install-kfp.log"
  log_step "KFP 설치 시작"

  require_cmd kubectl kustomize

  # kubectl 연결 확인
  if [[ ! -f "$KUBECONFIG" ]]; then
    log_error "KUBECONFIG 파일이 없습니다: $KUBECONFIG"
    log_error "먼저 10-install-k3s.sh 를 실행하세요."
    exit 1
  fi
  if [[ ! -r "$KUBECONFIG" ]]; then
    log_error "KUBECONFIG 파일을 읽을 수 없습니다: $KUBECONFIG"
    log_error "sudo bash $0 으로 다시 실행하거나, 아래 명령으로 권한을 부여하세요:"
    log_error "  sudo chmod 644 $KUBECONFIG"
    exit 1
  fi
  if ! kubectl cluster-info &>/dev/null; then
    log_error "kubectl이 클러스터에 연결할 수 없습니다. (KUBECONFIG=$KUBECONFIG)"
    log_error "K3s가 실행 중인지 확인하세요: sudo systemctl status k3s"
    exit 1
  fi

  # 1. namespace 생성
  log_step "Namespace 생성"
  ensure_namespace

  # 2. kustomize overlay 확인
  log_step "kustomize overlay 확인"
  setup_kustomize_overlay

  # 3. manifest 빌드 및 적용
  log_step "manifest 빌드 및 적용"
  local rendered_manifest="/tmp/kfp-manifest-$$.yaml"
  kustomize build "$KUSTOMIZE_OVERLAY_DIR" > "$rendered_manifest"
  log_info "렌더링된 manifest: $rendered_manifest"

  # 이미지 참조 확인 (로컬 레지스트리 치환 여부)
  log_info "이미지 참조 확인:"
  grep -E '^\s+image:' "$rendered_manifest" | sort -u | head -20

  kubectl apply -f "$rendered_manifest"
  log_success "manifest 적용 완료"
  rm -f "$rendered_manifest"

  # 4. NodePort 패치
  log_step "ml-pipeline-ui NodePort 설정"
  if [[ -f "$NODEPORT_PATCH" ]]; then
    kubectl apply -f "$NODEPORT_PATCH"
    log_success "NodePort 패치 적용 (포트: $KFP_NODEPORT)"
  else
    log_warn "NodePort 패치 파일이 없습니다: $NODEPORT_PATCH"
    log_warn "수동으로 ml-pipeline-ui Service를 NodePort로 변경하세요."
    # 직접 patch 적용
    kubectl patch service ml-pipeline-ui \
      -n "$KFP_NAMESPACE" \
      --type='json' \
      -p="[
        {\"op\": \"replace\", \"path\": \"/spec/type\", \"value\": \"NodePort\"},
        {\"op\": \"add\", \"path\": \"/spec/ports/0/nodePort\", \"value\": $KFP_NODEPORT}
      ]" 2>/dev/null || log_warn "NodePort 패치 실패 — Service가 아직 생성되지 않았을 수 있습니다."
  fi

  # 5. Pod Ready 대기
  log_step "Pod Ready 대기 (최대 10분)"
  wait_pods_ready "$KFP_NAMESPACE" 600

  # 최종 상태 출력
  log_step "설치 결과"
  kubectl get pods -n "$KFP_NAMESPACE"
  kubectl get svc -n "$KFP_NAMESPACE"

  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')
  log_success "KFP 설치 완료!"
  echo ""
  echo "  KFP UI 접속 주소:"
  echo "    http://localhost:${KFP_NODEPORT}"
  echo "    http://${server_ip}:${KFP_NODEPORT}  (폐쇄망 내 다른 PC에서)"
  echo ""
}

main "$@"
