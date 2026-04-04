#!/usr/bin/env bash
# scripts/lib/common.sh — 공통 헬퍼 라이브러리
# 모든 스크립트에서 source 하여 사용한다.
# Usage: source "$(dirname "$0")/lib/common.sh"

# ─── 컬러 출력 ───────────────────────────────────────────────────────────────

# TTY가 아닌 경우(파이프/리다이렉트) 컬러 비활성화
if [ -t 1 ]; then
  _RED='\033[0;31m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[1;33m'
  _BLUE='\033[0;34m'
  _CYAN='\033[0;36m'
  _BOLD='\033[1m'
  _RESET='\033[0m'
else
  _RED='' _GREEN='' _YELLOW='' _BLUE='' _CYAN='' _BOLD='' _RESET=''
fi

# 타임스탬프
_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()    { echo -e "${_BLUE}[INFO ]${_RESET} $(_ts) $*"; }
log_success() { echo -e "${_GREEN}[OK   ]${_RESET} $(_ts) $*"; }
log_warn()    { echo -e "${_YELLOW}[WARN ]${_RESET} $(_ts) $*" >&2; }
log_error()   { echo -e "${_RED}[ERROR]${_RESET} $(_ts) $*" >&2; }
log_step()    { echo -e "\n${_BOLD}${_CYAN}━━━ $* ━━━${_RESET}"; }

# ─── 의존성 검사 ─────────────────────────────────────────────────────────────

# require_cmd cmd1 cmd2 ...
# 하나라도 없으면 에러 출력 후 exit 1
require_cmd() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "필수 명령어를 찾을 수 없습니다: $cmd"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1
}

# optional_cmd cmd — 있으면 0, 없으면 1 반환 (exit 없음)
optional_cmd() { command -v "$1" &>/dev/null; }

# ─── 로그 파일 ───────────────────────────────────────────────────────────────

# init_log <log_file>
# 이후 exec을 통해 stdout/stderr를 파일에도 동시 기록한다.
init_log() {
  local log_file="$1"
  mkdir -p "$(dirname "$log_file")"
  exec > >(tee -a "$log_file") 2>&1
  log_info "로그 파일: $log_file"
}

# ─── 재시도 로직 ─────────────────────────────────────────────────────────────

# retry <max_attempts> <delay_seconds> <cmd> [args...]
# 지수 백오프: delay, delay*3, delay*9 ...
retry() {
  local max="$1"; shift
  local delay="$1"; shift
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if [[ $attempt -ge $max ]]; then
      log_error "최대 재시도 횟수($max) 초과: $*"
      return 1
    fi
    log_warn "재시도 $attempt/$max — ${delay}초 후 다시 시도합니다..."
    sleep "$delay"
    delay=$(( delay * 3 ))
    attempt=$(( attempt + 1 ))
  done
}

# ─── 체크섬 ──────────────────────────────────────────────────────────────────

# compute_checksums <output_file> <dir>
# dir 아래 모든 파일의 sha256 체크섬을 output_file에 기록한다.
compute_checksums() {
  local output="$1"
  local dir="$2"
  log_info "체크섬 계산 중: $dir"
  (cd "$dir" && find . -type f | sort | xargs sha256sum) > "$output"
  log_success "체크섬 저장: $output"
}

# verify_checksums <checksum_file> <dir>
verify_checksums() {
  local checksum_file="$1"
  local dir="$2"
  log_info "체크섬 검증 중: $dir"
  (cd "$dir" && sha256sum --check "$checksum_file")
}

# ─── 이미지 이름 정규화 ──────────────────────────────────────────────────────

# sanitize_image_name "ghcr.io/foo/bar:tag" → "ghcr.io_foo_bar_tag"
sanitize_image_name() {
  echo "$1" | sed 's|[/:@]|_|g'
}

# ─── 공통 변수 ───────────────────────────────────────────────────────────────

# 스크립트를 source 하는 쪽에서 BUNDLE_DIR을 덮어쓸 수 있다.
BUNDLE_DIR="${BUNDLE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/airgap-bundle}"
IMAGES_DIR="${IMAGES_DIR:-$BUNDLE_DIR/images}"
BINARIES_DIR="${BINARIES_DIR:-$BUNDLE_DIR/binaries}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$BUNDLE_DIR/manifests}"
CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/config}"
LOG_DIR="${LOG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/logs}"

KFP_VERSION="${KFP_VERSION:-2.15.0}"
K3S_VERSION="${K3S_VERSION:-v1.29.14+k3s1}"
REGISTRY_HOST="${REGISTRY_HOST:-localhost:5000}"
KFP_NODEPORT="${KFP_NODEPORT:-31380}"
