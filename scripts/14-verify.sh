#!/usr/bin/env bash
# scripts/14-verify.sh
# [폐쇄망] KFP 설치 검증
#
# 동작 흐름:
#   1. 모든 Pod 상태 출력
#   2. KFP UI HTTP 응답 확인
#   3. KFP API 헬스 체크 (/apis/v2beta1/healthz)
#   4. 접속 정보 출력
#
# 실행 권한: kubectl 접근 가능한 사용자

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

KFP_NAMESPACE="kubeflow"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# ─── 함수 ────────────────────────────────────────────────────────────────────

check_pods() {
  log_step "Pod 상태"
  kubectl get pods -n "$KFP_NAMESPACE" -o wide

  local not_running
  not_running=$(kubectl get pods -n "$KFP_NAMESPACE" --no-headers 2>/dev/null \
    | grep -v -E " Running | Completed " | grep -v "^$" | wc -l || echo 0)

  if [[ "$not_running" -eq 0 ]]; then
    log_success "모든 Pod가 정상 상태입니다."
    return 0
  else
    log_warn "비정상 Pod ${not_running}개:"
    kubectl get pods -n "$KFP_NAMESPACE" --no-headers \
      | grep -v -E " Running | Completed " || true
    return 1
  fi
}

check_ui() {
  log_step "KFP UI 응답 확인"
  local url="http://localhost:${KFP_NODEPORT}"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || echo "000")

  if [[ "$http_code" == "200" ]]; then
    log_success "UI 응답 정상: $url (HTTP $http_code)"
    return 0
  else
    log_error "UI 응답 실패: $url (HTTP $http_code)"
    return 1
  fi
}

check_api_health() {
  log_step "KFP API 헬스 체크"
  local url="http://localhost:${KFP_NODEPORT}/apis/v2beta1/healthz"
  local response
  response=$(curl -sf --max-time 10 "$url" 2>/dev/null || echo "")

  if echo "$response" | grep -q "commit_sha\|status"; then
    log_success "API 헬스 체크 통과"
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    return 0
  else
    log_error "API 헬스 체크 실패"
    log_error "응답: $response"
    return 1
  fi
}

print_access_info() {
  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  KFP UI 접속 정보"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  로컬(서버):   http://localhost:${KFP_NODEPORT}"
  echo "  폐쇄망 내:    http://${server_ip}:${KFP_NODEPORT}"
  echo ""
  echo "  방화벽 설정 (필요한 경우):"
  echo "    Ubuntu: sudo ufw allow ${KFP_NODEPORT}/tcp"
  echo "    RHEL:   sudo firewall-cmd --add-port=${KFP_NODEPORT}/tcp --permanent && sudo firewall-cmd --reload"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/14-verify.log"
  log_step "KFP 설치 검증 시작"

  require_cmd kubectl curl

  local all_ok=true

  # 1. Pod 상태
  check_pods || all_ok=false

  # 2. UI 응답
  check_ui || all_ok=false

  # 3. API 헬스
  check_api_health || all_ok=false

  # 4. 서비스 정보
  log_step "Service 정보"
  kubectl get svc -n "$KFP_NAMESPACE"

  # 5. 접속 정보 출력
  print_access_info

  # 최종 결과
  if $all_ok; then
    log_success "모든 검증 항목 통과! KFP가 정상적으로 설치되었습니다."
    exit 0
  else
    log_warn "일부 검증 항목이 실패했습니다. 위의 오류를 확인하세요."
    log_info "문제 해결: docs/TROUBLESHOOTING.md"
    exit 1
  fi
}

main "$@"
