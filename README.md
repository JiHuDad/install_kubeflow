# 폐쇄망 Kubeflow Pipelines 설치 자동화

폐쇄망(Air-Gapped) x86 Linux 환경에 **Kubeflow Pipelines (KFP) Standalone v2**를 자동으로 설치합니다.

## 요구사항

### 준비 머신 (인터넷 접속 가능)
- docker, git, kustomize, curl 설치
- 디스크 여유 20GB 이상

### 타겟 머신 (폐쇄망)
- Ubuntu 22.04 LTS 또는 RHEL 8/9 (x86_64)
- RAM 16GB 이상 권장, 디스크 50GB 이상
- 인터넷 차단 환경

---

## 빠른 시작

### 1단계: 준비 머신 (인터넷 환경)

```bash
# 1. 이 리포지토리를 준비 머신에 클론
git clone <this-repo> kubeflow-airgap
cd kubeflow-airgap

# 2. KFP 컨테이너 이미지 수집
bash scripts/01-collect-images.sh

# 3. K3s/kubectl/kustomize 바이너리 다운로드
bash scripts/02-download-binaries.sh

# 4. airgap-bundle/ 디렉터리를 USB 등으로 폐쇄망 서버에 복사
#    (리포지토리 전체를 복사하는 것을 권장)
```

### 2단계: 폐쇄망 타겟 서버

```bash
cd kubeflow-airgap

# 5. K3s 설치 (airgap 모드)
sudo bash scripts/10-install-k3s.sh

# 6. 로컬 레지스트리 구성
sudo bash scripts/11-setup-registry.sh

# 7. 이미지 로드 및 레지스트리 push
sudo bash scripts/12-load-and-push-images.sh

# 8. KFP 설치
bash scripts/13-install-kfp.sh

# 9. 설치 검증
bash scripts/14-verify.sh
```

---

## 접속 확인

설치 완료 후 브라우저에서 접속:

- **서버 로컬**: `http://localhost:31380`
- **폐쇄망 내 다른 PC**: `http://<서버IP>:31380`

---

## 환경변수 커스터마이징

```bash
# 예: KFP 버전 변경
export KFP_VERSION=2.14.0

# 예: NodePort 변경
export KFP_NODEPORT=32000

# 예: 번들 디렉터리 변경
export BUNDLE_DIR=/data/airgap-bundle
```

---

## 주요 파일 구조

```
├── scripts/
│   ├── lib/common.sh              # 공통 헬퍼 (로그, retry 등)
│   ├── 01-collect-images.sh       # [인터넷] 이미지 수집
│   ├── 02-download-binaries.sh    # [인터넷] 바이너리 다운로드
│   ├── 10-install-k3s.sh          # [폐쇄망] K3s 설치
│   ├── 11-setup-registry.sh       # [폐쇄망] 로컬 레지스트리
│   ├── 12-load-and-push-images.sh # [폐쇄망] 이미지 로드/push
│   ├── 13-install-kfp.sh          # [폐쇄망] KFP 설치
│   ├── 14-verify.sh               # [폐쇄망] 설치 검증
│   ├── 20-expose-ui.sh            # [폐쇄망] UI 노출
│   ├── 21-backup.sh               # [폐쇄망] 백업
│   └── 22-uninstall.sh            # [폐쇄망] 언인스톨
├── config/
│   ├── registries.yaml            # K3s 레지스트리 미러 설정
│   └── kfp-nodeport-patch.yaml    # NodePort 서비스 패치
├── kustomize/overlays/airgap/     # 이미지 치환 kustomize overlay
├── docs/
│   ├── TROUBLESHOOTING.md         # 문제 해결 가이드
│   └── ADD-PIPELINE-IMAGES.md     # 커스텀 이미지 추가 방법
└── airgap-bundle/                 # 수집된 이미지/바이너리 (자동 생성)
    ├── images/                    # 컨테이너 이미지 tar
    ├── binaries/                  # K3s, kubectl, kustomize
    └── manifests/                 # KFP kustomize manifests
```

---

## 문제 해결

→ [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## 커스텀 파이프라인 이미지 추가

→ [docs/ADD-PIPELINE-IMAGES.md](docs/ADD-PIPELINE-IMAGES.md)
