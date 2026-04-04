# PRD: 폐쇄망 Kubeflow Pipelines Standalone 설치 자동화

## 1. 개요

폐쇄망(Air-Gapped) x86 Linux 환경에 **Kubeflow Pipelines (KFP) Standalone v2**를 설치하는 전 과정을 자동화한다.
인터넷 접속 가능한 준비 머신에서 필요한 바이너리와 컨테이너 이미지를 수집하고,
물리 매체(USB 등)를 통해 폐쇄망으로 이동한 뒤, 단일 스크립트로 설치를 완료하는 것이 목표이다.

## 2. 목표

| 항목 | 설명 |
|------|------|
| **핵심 목표** | 폐쇄망 Linux 서버에서 KFP 웹 UI 및 파이프라인 실행 환경 구축 |
| **사용자** | MLOps 엔지니어, 데이터 사이언티스트 |
| **성공 기준** | 웹 브라우저에서 `http://<서버IP>:<NodePort>`로 KFP UI 접속 가능, 샘플 파이프라인 실행 성공 |

## 3. 타겟 환경

### 3.1 준비 머신 (인터넷 접속 가능)

- OS: Linux (Ubuntu 20.04+ 또는 RHEL 8+) 또는 macOS
- Docker 또는 Podman 설치 필수
- 디스크 여유: 최소 20GB (이미지 tar 저장용)
- 인터넷 접속 가능 (ghcr.io, docker.io, quay.io, github.com)

### 3.2 타겟 머신 (폐쇄망)

- **아키텍처**: x86_64 (amd64)
- **OS**: Ubuntu 22.04 LTS 또는 RHEL 8/9
- **CPU**: 4코어 이상 권장
- **RAM**: 16GB 이상 권장 (최소 8GB, KFP Pod 전체 약 4~6GB 사용)
- **디스크**: 50GB 이상 여유 (이미지 로드 + PV 스토리지)
- **네트워크**: 폐쇄망 내 다른 PC에서 TCP 접근 가능 (방화벽 오픈 필요)
- **사전 설치**: Docker (또는 containerd), kubectl

## 4. 기술 스택 및 버전

| 컴포넌트 | 버전 | 비고 |
|----------|------|------|
| **KFP** | 2.15.0 (또는 최신 stable) | `ghcr.io/kubeflow/kfp-*` |
| **Kubernetes** | K3s v1.29+ 또는 Kind v0.23+ | 단일 노드 클러스터 |
| **컨테이너 런타임** | Docker CE 24+ 또는 containerd | K3s는 containerd 내장 |
| **로컬 레지스트리** | registry:2 | 폐쇄망 내 이미지 서빙 |
| **Argo Workflows** | KFP 번들 포함 버전 | KFP manifest에 포함 |
| **kustomize** | v5.0+ | manifest 빌드 및 이미지 치환 |

## 5. 아키텍처

```
┌─────────────────────────────────────────────────────────────┐
│                   폐쇄망 (Air-Gapped Network)               │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              타겟 서버 (x86 Linux)                   │    │
│  │                                                     │    │
│  │  ┌──────────────┐   ┌──────────────────────────┐    │    │
│  │  │ Local        │   │  K3s / Kind Cluster       │    │    │
│  │  │ Registry     │◄──┤                           │    │    │
│  │  │ (registry:2) │   │  ┌─────────────────────┐  │    │    │
│  │  │ :5000        │   │  │ kubeflow namespace   │  │    │    │
│  │  └──────────────┘   │  │                     │  │    │    │
│  │                     │  │  ml-pipeline-ui     │  │    │    │
│  │                     │  │  ml-pipeline        │  │    │    │
│  │                     │  │  metadata-grpc      │  │    │    │
│  │                     │  │  minio              │  │    │    │
│  │                     │  │  mysql               │  │    │    │
│  │                     │  │  argo-server         │  │    │    │
│  │                     │  │  cache-server        │  │    │    │
│  │                     │  │  ...                 │  │    │    │
│  │                     │  └─────────────────────┘  │    │    │
│  │                     │       NodePort :3xxxx     │    │    │
│  │                     └──────────┬───────────────┘    │    │
│  └────────────────────────────────┼────────────────────┘    │
│                                   │                         │
│  ┌────────────┐  ┌────────────┐   │                         │
│  │ 개발자 PC  │  │ 다른 PC    │───┘  ← http://서버IP:3xxxx │
│  │ (브라우저) │  │ (브라우저) │                              │
│  └────────────┘  └────────────┘                             │
└─────────────────────────────────────────────────────────────┘
```

## 6. 스코프

### 6.1 Phase 1: 이미지 수집 (인터넷 환경)

#### `scripts/01-collect-images.sh`

- KFP manifest를 clone 후 `kustomize build`로 렌더링
- 렌더링된 YAML에서 모든 `image:` 참조를 grep/파싱하여 이미지 목록 생성
- 이미지 목록 파일: `image-list.txt`
- 각 이미지를 `docker pull` 시도
- **pull 실패 처리** (핵심 요구사항):
  - 재시도 로직: 최대 3회, 지수 백오프 (5s, 15s, 45s)
  - 실패 시 대체 수단: `skopeo copy` 시도 (skopeo가 설치된 경우)
  - 최종 실패 이미지는 `failed-images.txt`에 기록
  - 부분 성공 허용: 실패 이미지가 있어도 나머지는 계속 진행
  - 최종 summary 출력: 성공/실패/전체 개수
- 성공한 이미지를 `docker save`로 tar 파일로 저장
  - 개별 tar: `images/<sanitized-image-name>.tar`
  - (선택) 단일 tar: `docker save $(cat image-list-success.txt) -o kfp-images-all.tar`
- K3s/Kind 바이너리, kubectl, kustomize 바이너리도 함께 다운로드

#### `scripts/02-download-binaries.sh`

- K3s airgap 이미지 번들 (`k3s-airgap-images-amd64.tar.zst`)
- K3s 바이너리 (`k3s`)
- kubectl 바이너리
- kustomize 바이너리
- (선택) registry:2 이미지 tar
- KFP manifests git repo tarball

#### 산출물

```
airgap-bundle/
├── images/                    # KFP 컨테이너 이미지 tar 파일들
│   ├── kfp-api-server.tar
│   ├── kfp-frontend.tar
│   ├── kfp-persistence-agent.tar
│   ├── ...
│   └── registry-2.tar         # 로컬 레지스트리 이미지
├── binaries/
│   ├── k3s                    # K3s 바이너리
│   ├── k3s-airgap-images-amd64.tar.zst
│   ├── kubectl
│   └── kustomize
├── manifests/                 # KFP kustomize manifests
│   └── pipelines/             # kubeflow/pipelines repo의 manifests/kustomize/
├── image-list.txt             # 전체 이미지 목록
├── image-list-success.txt     # pull 성공 이미지 목록
├── failed-images.txt          # pull 실패 이미지 목록 (있는 경우)
└── checksums.sha256           # 모든 파일의 체크섬
```

### 6.2 Phase 2: 폐쇄망 설치

#### `scripts/10-install-k3s.sh`

- K3s를 airgap 모드로 설치
- `/var/lib/rancher/k3s/agent/images/`에 airgap 이미지 배치
- K3s systemd 서비스 시작
- kubeconfig 설정 (`/etc/rancher/k3s/k3s.yaml`)

#### `scripts/11-setup-registry.sh`

- 로컬 레지스트리 (registry:2)를 컨테이너로 기동
- `localhost:5000`에서 서비스
- K3s의 registries.yaml 설정 (`/etc/rancher/k3s/registries.yaml`)
  - 미러 설정: `ghcr.io` → `localhost:5000`, `docker.io` → `localhost:5000`

#### `scripts/12-load-and-push-images.sh`

- `docker load` 또는 `ctr images import`로 이미지 로드
- 로드된 이미지를 로컬 레지스트리로 re-tag & push
  - 예: `ghcr.io/kubeflow/kfp-api-server:2.15.0` → `localhost:5000/kubeflow/kfp-api-server:2.15.0`
- 진행률 표시 (n/total)
- 실패 시 재시도 (로컬이므로 보통 성공)

#### `scripts/13-install-kfp.sh`

- kustomize로 manifest 빌드
- (선택) 이미지 참조를 로컬 레지스트리로 치환
  - K3s registries.yaml 미러를 사용하면 manifest 수정 없이도 가능
  - 또는 kustomize overlay로 이미지 prefix 변경
- `kubectl apply` 실행
- Pod Ready 대기 (`kubectl wait --for=condition=Ready`)
- 설치 완료 후 서비스 노출:
  - `ml-pipeline-ui` Service를 **NodePort**로 변경
  - NodePort 번호 고정 (예: 31380)

#### `scripts/14-verify.sh`

- 모든 Pod 상태 확인
- KFP UI HTTP 응답 확인 (`curl http://localhost:31380`)
- KFP API 헬스 체크 (`/apis/v2beta1/healthz`)
- (선택) 샘플 파이프라인 업로드 및 실행 테스트
- 네트워크 접근 확인: 서버 IP + NodePort

### 6.3 Phase 3: 운영 지원 (선택)

#### `scripts/20-expose-ui.sh`

- NodePort 설정 확인 및 방화벽 규칙 안내
- 폐쇄망 내 다른 PC에서 접근하는 방법 출력
  ```
  ✅ KFP UI is accessible at:
     http://<SERVER_IP>:31380
     
  From any machine on the same network, open a browser and navigate to the above URL.
  ```

#### `scripts/21-backup.sh` / `scripts/22-uninstall.sh`

- PV 데이터 백업/복구
- 클린 삭제

## 7. 폐쇄망 웹 접근 상세

### 7.1 NodePort 방식 (기본)

`ml-pipeline-ui` Service의 `type`을 `NodePort`로 변경하면,
K3s 노드(= 타겟 서버)의 IP와 지정된 포트로 **폐쇄망 내 모든 PC**에서 접근 가능하다.

```yaml
# kustomize patch 예시
apiVersion: v1
kind: Service
metadata:
  name: ml-pipeline-ui
  namespace: kubeflow
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 3000
      nodePort: 31380
```

### 7.2 접근 조건

- 타겟 서버와 클라이언트 PC가 **같은 L2/L3 네트워크**에 있어야 함
- 타겟 서버의 방화벽에서 해당 NodePort(31380) **인바운드 허용** 필요
  - `sudo ufw allow 31380/tcp` 또는 `sudo firewall-cmd --add-port=31380/tcp`
- 별도 인증 없음 (KFP Standalone에는 Istio/Dex 미포함)

## 8. Docker Pull 실패 대응 전략

폐쇄망 설치의 가장 큰 리스크는 준비 단계에서 이미지 수집이 불완전한 경우이다.

### 8.1 Pull 실패 원인 및 대응

| 원인 | 대응 |
|------|------|
| 일시적 네트워크 오류 | 재시도 (3회, 지수 백오프) |
| Rate limit (ghcr.io, docker.io) | 대기 후 재시도, `--retry-delay` 옵션 |
| 이미지 존재하지 않음 | `failed-images.txt`에 기록, 대체 태그 검색 시도 |
| 인증 필요 | `docker login` 안내 메시지 출력 |
| 아키텍처 미지원 | `--platform linux/amd64` 강제 지정 |

### 8.2 부분 실패 시 설치 가능 여부 판단

스크립트가 이미지를 **필수(critical)** / **선택(optional)** 으로 분류한다.

**필수 이미지** (하나라도 없으면 설치 불가):
- `kfp-api-server`
- `kfp-frontend`
- `kfp-persistence-agent`
- `kfp-scheduled-workflow-controller`
- `metadata-grpc-server` (ml-metadata)
- `metadata-envoy`
- `minio`
- `mysql`
- `argo workflow-controller`
- `argo executor (emissary)`

**선택 이미지** (없어도 기본 동작 가능):
- `kfp-cache-server`
- `kfp-cache-deployer`
- `kfp-viewer-crd-controller`
- `kfp-visualization-server`

## 9. 제약 조건 및 주의사항

1. **인터넷 완전 차단**: 설치 후 pip install, docker pull 등 일체 불가. 파이프라인 컴포넌트 이미지도 사전에 포함해야 함.
2. **파이프라인 컴포넌트 이미지**: 사용자가 파이프라인에서 사용할 커스텀 이미지도 동일한 방식으로 미리 로컬 레지스트리에 push 필요.
3. **KFP Python SDK**: 폐쇄망 내 개발자 PC에 `kfp` 패키지를 오프라인 설치해야 파이프라인 작성 가능 (`pip download` → 물리 이동 → `pip install --no-index`).
4. **단일 노드 한계**: K3s 단일 노드이므로 HA 불가. 노드 장애 = 서비스 중단.
5. **스토리지**: 기본 local-path provisioner 사용. 프로덕션에선 별도 스토리지 고려.
6. **보안**: KFP Standalone에는 인증/인가 미포함. 폐쇄망 내 네트워크 보안에 의존.

## 10. 산출물 요약

```
kubeflow-airgap/
├── PRD.md                           # 이 문서
├── README.md                        # 빠른 시작 가이드
├── scripts/
│   ├── 01-collect-images.sh         # [인터넷] 이미지 수집
│   ├── 02-download-binaries.sh      # [인터넷] 바이너리 다운로드
│   ├── 10-install-k3s.sh            # [폐쇄망] K3s 설치
│   ├── 11-setup-registry.sh         # [폐쇄망] 로컬 레지스트리 구성
│   ├── 12-load-and-push-images.sh   # [폐쇄망] 이미지 로드 & push
│   ├── 13-install-kfp.sh            # [폐쇄망] KFP 설치
│   ├── 14-verify.sh                 # [폐쇄망] 설치 검증
│   ├── 20-expose-ui.sh              # [폐쇄망] UI 외부 노출
│   ├── 21-backup.sh                 # [폐쇄망] 백업
│   └── 22-uninstall.sh              # [폐쇄망] 삭제
├── config/
│   ├── image-list.txt               # 수집할 이미지 목록 (자동 생성)
│   ├── registries.yaml              # K3s 레지스트리 미러 설정
│   └── kfp-nodeport-patch.yaml      # NodePort 서비스 패치
├── kustomize/
│   └── overlays/
│       └── airgap/
│           ├── kustomization.yaml   # 이미지 prefix 치환 등
│           └── patches/             # 추가 패치
└── docs/
    ├── TROUBLESHOOTING.md           # 문제 해결 가이드
    └── ADD-PIPELINE-IMAGES.md       # 커스텀 파이프라인 이미지 추가 방법
```

## 11. Claude Code 사용 가이드

이 PRD를 Claude Code의 프로젝트 루트에 배치한 뒤, 아래와 같이 요청한다:

```
# 1단계: 이미지 수집 스크립트 생성
"PRD.md를 참고해서 scripts/01-collect-images.sh를 만들어줘. 
 docker pull 실패 시 3회 재시도, 지수 백오프, skopeo 폴백을 포함해줘."

# 2단계: 바이너리 다운로드 스크립트
"scripts/02-download-binaries.sh를 만들어줘. K3s v1.29 airgap bundle 포함."

# 3단계: 폐쇄망 설치 스크립트
"scripts/10-install-k3s.sh 부터 14-verify.sh까지 만들어줘."

# 4단계: 통합 테스트
"전체 스크립트를 리뷰하고, 누락된 이미지나 설정이 없는지 확인해줘."
```

### CLAUDE.md에 추가할 컨텍스트 (권장)

```markdown
## Project Context
- 이 프로젝트는 폐쇄망(air-gapped) 환경에 KFP를 설치하는 자동화 스크립트 모음이다.
- 모든 스크립트는 bash로 작성하며, POSIX 호환을 유지한다.
- 에러 처리를 철저히 한다 (set -euo pipefail, trap).
- 각 스크립트는 독립 실행 가능해야 한다 (멱등성 보장).
- 로그는 stdout과 로그 파일에 동시 출력한다.
- 컬러 출력을 사용하되, 파이프/리다이렉트 시 자동 비활성화한다.
```
