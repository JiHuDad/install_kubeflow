#!/usr/bin/env bash
# scripts/12-load-and-push-images.sh
# [폐쇄망] 이미지 tar를 containerd에 로드하고 로컬 레지스트리에 push한다.
#
# 동작 흐름:
#   1. airgap-bundle/images/*.tar 를 순회
#   2. ctr images import (K3s containerd)
#   3. 원본 이미지명을 파싱해 localhost:5000/... 으로 re-tag
#   4. 로컬 레지스트리로 push
#   5. 진행률 표시 (n/total)
#
# 실행 권한: root 권장 (ctr 명령어)

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_DIR="${BUNDLE_DIR:-$ROOT_DIR/airgap-bundle}"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

PUSH_LOG="$LOG_DIR/12-push-failures.txt"

# ─── 함수 ────────────────────────────────────────────────────────────────────

# tar 파일에서 이미지명 목록 추출
get_images_from_tar() {
  local tar_file="$1"
  # docker save 포맷의 manifest.json 에서 RepoTags 파싱
  tar -xOf "$tar_file" manifest.json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for entry in data:
    for tag in entry.get('RepoTags', []):
        print(tag)
" 2>/dev/null || true
}

# 이미지를 로컬 레지스트리 주소로 변환
# ghcr.io/kubeflow/kfp-api-server:2.15.0 → localhost:5000/kubeflow/kfp-api-server:2.15.0
# chrislusf/seaweedfs:4.00              → localhost:5000/chrislusf/seaweedfs:4.00
# mysql:8.4                             → localhost:5000/mysql:8.4
remap_to_local() {
  local image="$1"
  local first_component="${image%%/*}"
  local without_registry

  # 레지스트리 호스트 조건: 슬래시가 있고 첫 컴포넌트에 점(.) 또는 콜론(:)이 포함되거나 localhost인 경우
  if [[ "$image" == *"/"* ]] && \
     { [[ "$first_component" == *"."* ]] || \
       [[ "$first_component" == *":"* ]] || \
       [[ "$first_component" == "localhost" ]]; }; then
    without_registry="${image#*/}"
  else
    # 레지스트리 호스트 없음 (org/name 또는 단순 이미지명) — 그대로 유지
    without_registry="$image"
  fi

  echo "${REGISTRY_HOST}/${without_registry}"
}

# manifest.json의 이미지명을 containerd에 실제 저장된 이름으로 변환
# ctr import 시 Docker Hub 이미지에 docker.io/ prefix가 자동으로 붙음
resolve_ctr_name() {
  local image="$1"
  local first_component="${image%%/*}"

  # 이미 레지스트리 호스트가 있으면 그대로 반환
  if [[ "$image" == *"/"* ]] && \
     { [[ "$first_component" == *"."* ]] || \
       [[ "$first_component" == *":"* ]] || \
       [[ "$first_component" == "localhost" ]]; }; then
    echo "$image"
    return
  fi

  # Docker Hub 이미지: ctr는 docker.io/ prefix를 붙여 저장
  if [[ "$image" != *"/"* ]]; then
    # 단순 이미지명: mysql:8.4 → docker.io/library/mysql:8.4
    echo "docker.io/library/$image"
  else
    # org/name: chrislusf/seaweedfs:4.00 → docker.io/chrislusf/seaweedfs:4.00
    echo "docker.io/$image"
  fi
}

load_and_push_tar() {
  local tar_file="$1"
  local basename
  basename="$(basename "$tar_file")"

  log_info "로드: $basename"

  # ctr로 이미지 import
  if ! ctr images import "$tar_file" &>/dev/null; then
    log_warn "  ctr import 실패: $basename — 건너뜀"
    echo "LOAD_FAILED: $tar_file" >> "$PUSH_LOG"
    return 1
  fi

  # tar에서 이미지 태그 목록 파싱
  local images
  images=$(get_images_from_tar "$tar_file")

  if [[ -z "$images" ]]; then
    log_warn "  이미지명을 파싱할 수 없습니다: $basename"
    return 0
  fi

  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    local local_image
    local_image=$(remap_to_local "$image")

    local ctr_image
    ctr_image=$(resolve_ctr_name "$image")
    log_info "  re-tag: $ctr_image → $local_image"
    if ! ctr images tag "$ctr_image" "$local_image" 2>/dev/null; then
      log_warn "  re-tag 실패: $ctr_image — 건너뜀"
      echo "TAG_FAILED: $ctr_image" >> "$PUSH_LOG"
      continue
    fi

    log_info "  push: $local_image"
    if ! retry 3 3 ctr images push \
        --plain-http \
        "$local_image"; then
      log_warn "  push 실패: $local_image"
      echo "PUSH_FAILED: $local_image" >> "$PUSH_LOG"
    else
      log_success "  완료: $local_image"
    fi
  done <<< "$images"
}

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/12-load-and-push-images.log"
  log_step "이미지 로드 및 Push 시작"

  require_cmd ctr

  if [[ ! -d "$IMAGES_DIR" ]]; then
    log_error "이미지 디렉터리가 없습니다: $IMAGES_DIR"
    exit 1
  fi

  # 레지스트리 응답 확인
  if ! curl -sf "http://${REGISTRY_HOST}/v2/" &>/dev/null; then
    log_error "레지스트리에 접근할 수 없습니다: http://${REGISTRY_HOST}"
    log_error "먼저 11-setup-registry.sh 를 실행하세요."
    exit 1
  fi

  > "$PUSH_LOG"

  local tar_files=()
  while IFS= read -r -d '' f; do
    tar_files+=("$f")
  done < <(find "$IMAGES_DIR" -name "*.tar" -print0 | sort -z)

  local total="${#tar_files[@]}"
  if [[ $total -eq 0 ]]; then
    log_error "이미지 tar 파일이 없습니다: $IMAGES_DIR"
    exit 1
  fi

  log_info "총 $total 개의 이미지 파일 처리 시작"

  local idx=0
  local success=0
  local failed=0

  for tar_file in "${tar_files[@]}"; do
    idx=$(( idx + 1 ))
    log_step "[$idx/$total] $(basename "$tar_file")"
    if load_and_push_tar "$tar_file"; then
      success=$(( success + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
  done

  # 요약
  log_step "Push 결과 요약"
  echo "────────────────────────────────────────"
  echo "  전체:   $total"
  echo "  성공:   $success"
  echo "  실패:   $failed"
  echo "────────────────────────────────────────"

  if [[ $failed -gt 0 ]]; then
    log_warn "실패 목록: $PUSH_LOG"
    cat "$PUSH_LOG"
  fi

  # 레지스트리 카탈로그 확인
  log_info "레지스트리 카탈로그:"
  curl -sf "http://${REGISTRY_HOST}/v2/_catalog" | python3 -m json.tool 2>/dev/null || true

  log_success "이미지 로드 및 Push 완료!"
}

main "$@"
