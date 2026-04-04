#!/usr/bin/env bash
# scripts/20-expose-ui.sh
# [폐쇄망] KFP UI NodePort 설정 확인 및 방화벽 안내

set -euo pipefail
trap 'log_error "오류 발생 (line $LINENO)"; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

KFP_NAMESPACE="kubeflow"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

main() {
  init_log "$LOG_DIR/20-expose-ui.log"
  log_step "KFP UI 노출 설정 확인"

  require_cmd kubectl

  # NodePort 확인
  log_step "ml-pipeline-ui Service 상태"
  kubectl get svc ml-pipeline-ui -n "$KFP_NAMESPACE" -o wide 2>/dev/null || {
    log_error "ml-pipeline-ui Service가 없습니다. 13-install-kfp.sh 를 먼저 실행하세요."
    exit 1
  }

  local svc_type node_port
  svc_type=$(kubectl get svc ml-pipeline-ui -n "$KFP_NAMESPACE" -o jsonpath='{.spec.type}')
  node_port=$(kubectl get svc ml-pipeline-ui -n "$KFP_NAMESPACE" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")

  if [[ "$svc_type" != "NodePort" ]]; then
    log_warn "Service 타입이 NodePort가 아닙니다: $svc_type"
    log_info "NodePort로 변경 중..."
    kubectl patch service ml-pipeline-ui \
      -n "$KFP_NAMESPACE" \
      --type='json' \
      -p="[
        {\"op\": \"replace\", \"path\": \"/spec/type\", \"value\": \"NodePort\"},
        {\"op\": \"add\", \"path\": \"/spec/ports/0/nodePort\", \"value\": $KFP_NODEPORT}
      ]"
    node_port="$KFP_NODEPORT"
    log_success "NodePort ${node_port} 설정 완료"
  else
    log_success "NodePort 설정 확인: 포트 ${node_port}"
  fi

  local server_ip
  server_ip=$(hostname -I | awk '{print $1}')

  # 방화벽 확인 및 안내
  log_step "방화벽 설정 안내"
  if command -v ufw &>/dev/null; then
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 || echo "unknown")
    log_info "ufw 상태: $ufw_status"
    if [[ "$ufw_status" == *"active"* ]]; then
      log_info "방화벽 규칙 추가:"
      echo "    sudo ufw allow ${node_port}/tcp"
      read -r -p "지금 바로 규칙을 추가하시겠습니까? [y/N] " answer
      if [[ "${answer,,}" == "y" ]]; then
        ufw allow "${node_port}/tcp"
        log_success "ufw 규칙 추가 완료"
      fi
    fi
  elif command -v firewall-cmd &>/dev/null; then
    log_info "firewall-cmd 규칙 추가 명령어:"
    echo "    sudo firewall-cmd --add-port=${node_port}/tcp --permanent"
    echo "    sudo firewall-cmd --reload"
  else
    log_info "방화벽 도구를 감지할 수 없습니다. 수동으로 포트 ${node_port}를 열어주세요."
  fi

  # 접속 정보 출력
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  ✅ KFP UI is accessible at:"
  echo ""
  echo "     http://localhost:${node_port}              (서버 로컬)"
  echo "     http://${server_ip}:${node_port}   (폐쇄망 내 다른 PC)"
  echo ""
  echo "  From any machine on the same network,"
  echo "  open a browser and navigate to the above URL."
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
