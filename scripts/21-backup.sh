#!/usr/bin/env bash
# scripts/21-backup.sh
# [폐쇄망] KFP 데이터 백업 (PV 데이터, MySQL dump)

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
export KUBECONFIG

BACKUP_DIR="${BACKUP_DIR:-$ROOT_DIR/backup/$(date +%Y%m%d-%H%M%S)}"

main() {
  init_log "$LOG_DIR/21-backup.log"
  log_step "KFP 백업 시작"

  require_cmd kubectl

  mkdir -p "$BACKUP_DIR"
  log_info "백업 경로: $BACKUP_DIR"

  # 1. KFP 리소스 YAML 덤프
  log_step "KFP 리소스 YAML 덤프"
  kubectl get all -n "$KFP_NAMESPACE" -o yaml > "$BACKUP_DIR/kfp-resources.yaml"
  kubectl get pvc -n "$KFP_NAMESPACE" -o yaml > "$BACKUP_DIR/kfp-pvc.yaml"
  kubectl get configmap -n "$KFP_NAMESPACE" -o yaml > "$BACKUP_DIR/kfp-configmaps.yaml"
  log_success "리소스 YAML 저장 완료"

  # 2. MySQL 덤프
  log_step "MySQL 덤프"
  local mysql_pod
  mysql_pod=$(kubectl get pods -n "$KFP_NAMESPACE" \
    -l app=mysql --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || echo "")

  if [[ -z "$mysql_pod" ]]; then
    log_warn "MySQL Pod를 찾을 수 없습니다. 건너뜁니다."
  else
    log_info "MySQL Pod: $mysql_pod"
    kubectl exec -n "$KFP_NAMESPACE" "$mysql_pod" -- \
      mysqldump -u root --all-databases 2>/dev/null \
      > "$BACKUP_DIR/mysql-dump.sql"
    log_success "MySQL 덤프 저장: $BACKUP_DIR/mysql-dump.sql"
  fi

  # 3. MinIO 데이터 백업 (kubectl cp)
  log_step "MinIO 데이터 백업"
  local minio_pod
  minio_pod=$(kubectl get pods -n "$KFP_NAMESPACE" \
    -l app=minio --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1 || echo "")

  if [[ -z "$minio_pod" ]]; then
    log_warn "MinIO Pod를 찾을 수 없습니다. 건너뜁니다."
  else
    log_info "MinIO Pod: $minio_pod"
    mkdir -p "$BACKUP_DIR/minio"
    kubectl cp "${KFP_NAMESPACE}/${minio_pod}:/data" "$BACKUP_DIR/minio/" 2>/dev/null || \
      log_warn "MinIO 데이터 복사 실패 (데이터가 없거나 경로가 다를 수 있습니다)"
    log_success "MinIO 데이터 백업 완료"
  fi

  # 4. 백업 체크섬
  log_step "체크섬 생성"
  compute_checksums "$BACKUP_DIR/checksums.sha256" "$BACKUP_DIR"

  log_success "백업 완료: $BACKUP_DIR"
  du -sh "$BACKUP_DIR"
}

main "$@"
