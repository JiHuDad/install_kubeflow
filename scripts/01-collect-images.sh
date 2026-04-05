#!/usr/bin/env bash
# scripts/01-collect-images.sh
# [준비 머신 — 인터넷 환경] KFP 컨테이너 이미지 수집
#
# 동작 흐름:
#   1. kubeflow/pipelines 리포지토리 클론
#   2. kustomize build 로 KFP manifest 렌더링
#   3. YAML에서 image: 필드 파싱 → config/image-list.txt
#   4. 각 이미지 docker pull (최대 3회 재시도, 지수 백오프)
#      실패 시 skopeo copy 폴백 (설치된 경우)
#   5. 성공 이미지 docker save → airgap-bundle/images/<name>.tar
#   6. 최종 요약 출력
#
# 사전 요구사항: docker, git, kustomize
# 선택 요구사항: skopeo

set -euo pipefail
trap 'log_error "예상치 못한 오류가 발생했습니다 (line $LINENO). 종료합니다."; exit 1' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# ─── 설정 ────────────────────────────────────────────────────────────────────

KFP_MANIFEST_REPO="${KFP_MANIFEST_REPO:-https://github.com/kubeflow/pipelines.git}"
KFP_MANIFEST_BRANCH="${KFP_MANIFEST_BRANCH:-$KFP_VERSION}"
KFP_KUSTOMIZE_PATH="${KFP_KUSTOMIZE_PATH:-manifests/kustomize/env/platform-agnostic}"

WORK_DIR="${WORK_DIR:-/tmp/kfp-collect-$$}"
IMAGE_LIST_FILE="$CONFIG_DIR/image-list.txt"
SUCCESS_LIST_FILE="$CONFIG_DIR/image-list-success.txt"
FAILED_LIST_FILE="$CONFIG_DIR/failed-images.txt"

# ─── 필수 이미지 목록 (PRD §8.2) ─────────────────────────────────────────────
# 이미지 이름에 아래 패턴이 포함되면 critical로 분류
CRITICAL_PATTERNS=(
  "kfp-api-server"
  "kfp-frontend"
  "kfp-persistence-agent"
  "kfp-scheduled-workflow"
  "metadata-grpc"
  "metadata-envoy"
  "minio"
  "mysql"
  "workflow-controller"
  "argoexec"
)

# ─── 함수 ────────────────────────────────────────────────────────────────────

is_critical() {
  local image="$1"
  for pattern in "${CRITICAL_PATTERNS[@]}"; do
    if [[ "$image" == *"$pattern"* ]]; then
      return 0
    fi
  done
  return 1
}

pull_image() {
  local image="$1"
  log_info "  docker pull $image"
  docker pull --platform linux/amd64 "$image"
}

pull_with_skopeo() {
  local image="$1"
  local dest_dir="$IMAGES_DIR"
  local tarname
  tarname="$(sanitize_image_name "$image").tar"

  log_warn "  skopeo copy 시도: $image"
  skopeo copy \
    --override-arch amd64 \
    --override-os linux \
    "docker://$image" \
    "docker-archive:$dest_dir/$tarname:$image"
}

save_image() {
  local image="$1"
  local tarname
  tarname="$(sanitize_image_name "$image").tar"
  local tarpath="$IMAGES_DIR/$tarname"

  if [[ -f "$tarpath" ]]; then
    log_info "  이미 존재함, 건너뜀: $tarname"
    return 0
  fi

  log_info "  docker save → $tarname"
  docker save "$image" -o "$tarpath"
}

# ─── 메인 ────────────────────────────────────────────────────────────────────

main() {
  init_log "$LOG_DIR/01-collect-images.log"
  log_step "KFP 이미지 수집 시작"

  require_cmd docker git kustomize

  mkdir -p "$IMAGES_DIR" "$CONFIG_DIR" "$LOG_DIR"

  # 1. KFP manifest 클론
  log_step "KFP manifest 클론"
  if [[ -d "$WORK_DIR/pipelines" ]]; then
    log_info "이미 클론됨. 업데이트 생략 (삭제 후 재실행하면 갱신됩니다)."
  else
    mkdir -p "$WORK_DIR"
    log_info "클론 중: $KFP_MANIFEST_REPO (branch: $KFP_MANIFEST_BRANCH)"
    git clone --depth 1 --branch "$KFP_MANIFEST_BRANCH" \
      "$KFP_MANIFEST_REPO" "$WORK_DIR/pipelines"
  fi

  # manifests 디렉터리도 번들에 포함
  mkdir -p "$MANIFESTS_DIR"
  if [[ ! -d "$MANIFESTS_DIR/pipelines" ]]; then
    cp -r "$WORK_DIR/pipelines/manifests/kustomize" "$MANIFESTS_DIR/pipelines"
    log_success "manifests 복사 완료: $MANIFESTS_DIR/pipelines"
  fi

  # 2. kustomize build
  log_step "kustomize build"
  local kustomize_dir="$WORK_DIR/pipelines/$KFP_KUSTOMIZE_PATH"
  if [[ ! -d "$kustomize_dir" ]]; then
    log_error "kustomize 경로를 찾을 수 없습니다: $kustomize_dir"
    exit 1
  fi
  local rendered_yaml="$WORK_DIR/kfp-rendered.yaml"
  kustomize build "$kustomize_dir" > "$rendered_yaml"
  log_success "렌더링 완료: $rendered_yaml"

  # 3. 이미지 목록 추출
  log_step "이미지 목록 추출"
  grep -E '^\s+image:\s+' "$rendered_yaml" \
    | sed 's/.*image:\s*//' \
    | sed 's/[[:space:]]*$//' \
    | sed 's/^["'\'']//' \
    | sed 's/["'\'']$//' \
    | sort -u \
    > "$IMAGE_LIST_FILE"

  local total_images
  total_images=$(wc -l < "$IMAGE_LIST_FILE")
  log_success "총 이미지 수: $total_images"
  cat "$IMAGE_LIST_FILE"

  # 4. 이미지 pull + save
  log_step "이미지 Pull & Save"
  > "$SUCCESS_LIST_FILE"
  > "$FAILED_LIST_FILE"

  local success_count=0
  local failed_count=0
  local idx=0

  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    idx=$(( idx + 1 ))
    log_info "[$idx/$total_images] $image"

    local pulled=false

    # docker pull with retry
    if retry 3 5 pull_image "$image"; then
      pulled=true
    elif optional_cmd skopeo; then
      # skopeo 폴백: tar로 직접 저장 후 이미지 로드
      if pull_with_skopeo "$image"; then
        pulled=true
        # skopeo가 직접 tar 저장했으므로 docker save 스킵
        echo "$image" >> "$SUCCESS_LIST_FILE"
        success_count=$(( success_count + 1 ))
        log_success "  [$idx/$total_images] skopeo 성공: $image"
        continue
      fi
    fi

    if $pulled; then
      if save_image "$image"; then
        echo "$image" >> "$SUCCESS_LIST_FILE"
        success_count=$(( success_count + 1 ))
        log_success "  [$idx/$total_images] 완료: $image"
      else
        log_error "  docker save 실패: $image"
        echo "$image" >> "$FAILED_LIST_FILE"
        failed_count=$(( failed_count + 1 ))
      fi
    else
      echo "$image" >> "$FAILED_LIST_FILE"
      failed_count=$(( failed_count + 1 ))
      if is_critical "$image"; then
        log_error "  필수 이미지 수집 실패: $image"
      else
        log_warn "  선택 이미지 수집 실패 (계속 진행): $image"
      fi
    fi
  done < "$IMAGE_LIST_FILE"

  # 5. 요약 출력
  log_step "수집 결과 요약"
  echo "────────────────────────────────────────"
  echo "  전체:   $total_images"
  echo "  성공:   $success_count"
  echo "  실패:   $failed_count"
  echo "────────────────────────────────────────"

  if [[ $failed_count -gt 0 ]]; then
    log_warn "실패한 이미지 목록: $FAILED_LIST_FILE"
    cat "$FAILED_LIST_FILE"

    # 필수 이미지 실패 여부 확인
    local critical_failed=0
    while IFS= read -r img; do
      if is_critical "$img"; then
        critical_failed=$(( critical_failed + 1 ))
        log_error "필수 이미지 누락: $img"
      fi
    done < "$FAILED_LIST_FILE"

    if [[ $critical_failed -gt 0 ]]; then
      log_error "필수 이미지 $critical_failed 개가 누락되었습니다. 폐쇄망 설치가 불가능할 수 있습니다."
      exit 1
    else
      log_warn "선택 이미지만 누락되었습니다. 기본 기능은 동작합니다."
    fi
  else
    log_success "모든 이미지 수집 완료!"
  fi

  log_step "이미지 수집 완료"
  log_info "저장 경로: $IMAGES_DIR"
  log_info "이미지 목록: $SUCCESS_LIST_FILE"
}

main "$@"
