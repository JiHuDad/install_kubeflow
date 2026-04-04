# Project Context

이 프로젝트는 폐쇄망(air-gapped) 환경에 KFP(Kubeflow Pipelines) Standalone v2를 설치하는 자동화 스크립트 모음이다.

## 핵심 원칙

- 모든 스크립트는 bash로 작성하며, POSIX 호환을 유지한다.
- 에러 처리를 철저히 한다 (`set -euo pipefail`, `trap`).
- 각 스크립트는 독립 실행 가능해야 한다 (멱등성 보장).
- 로그는 stdout과 로그 파일에 동시 출력한다.
- 컬러 출력을 사용하되, 파이프/리다이렉트 시 자동 비활성화한다.
- 공통 함수는 `scripts/lib/common.sh` 에서 `source` 한다.

## 스크립트 번호 체계

| 번호 | 환경 | 역할 |
|------|------|------|
| 01-02 | 인터넷 환경 (준비 머신) | 이미지/바이너리 수집 |
| 10-14 | 폐쇄망 (타겟 서버) | K3s + KFP 설치 |
| 20-22 | 폐쇄망 (타겟 서버) | 운영 지원 |

## 주요 환경변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `BUNDLE_DIR` | `./airgap-bundle` | 이미지/바이너리 번들 경로 |
| `KFP_VERSION` | `2.15.0` | KFP 버전 |
| `K3S_VERSION` | `v1.29.14+k3s1` | K3s 버전 |
| `REGISTRY_HOST` | `localhost:5000` | 로컬 레지스트리 주소 |
| `KFP_NODEPORT` | `31380` | KFP UI NodePort |

## 기술 스택

- Kubernetes: K3s v1.29+
- KFP: v2.15.0 (또는 최신 stable)
- 로컬 레지스트리: registry:2
- manifest 도구: kustomize v5+
