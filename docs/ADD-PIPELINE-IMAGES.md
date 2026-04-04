# 커스텀 파이프라인 이미지 추가 방법

KFP 파이프라인에서 사용하는 커스텀 Docker 이미지를 폐쇄망 환경에서 사용하려면,
로컬 레지스트리에 미리 push 해두어야 합니다.

---

## 방법 1: 준비 머신에서 이미지 수집 후 번들에 포함

준비 머신(인터넷 환경)에서 이미지를 pull 하여 번들에 포함합니다.

```bash
# 1. 이미지 pull
docker pull --platform linux/amd64 my-company/pipeline-component:v1.0

# 2. tar로 저장
docker save my-company/pipeline-component:v1.0 \
  -o airgap-bundle/images/my-company_pipeline-component_v1.0.tar

# 3. airgap-bundle/ 을 폐쇄망 서버에 복사 (USB 등)
```

폐쇄망 서버에서 12-load-and-push-images.sh 를 다시 실행하면 자동으로 로드/push 됩니다:

```bash
sudo bash scripts/12-load-and-push-images.sh
```

---

## 방법 2: 폐쇄망 서버에 직접 이미지 추가

이미 설치가 완료된 상태에서 새 이미지를 추가하는 경우:

```bash
# 1. 이미지 tar를 서버로 복사 (USB 등)
cp my-image.tar /tmp/

# 2. containerd에 로드
sudo ctr images import /tmp/my-image.tar

# 3. 로컬 레지스트리로 push
# 원본: my-company/pipeline-component:v1.0
sudo ctr images tag \
  my-company/pipeline-component:v1.0 \
  localhost:5000/my-company/pipeline-component:v1.0

sudo ctr images push \
  --plain-http \
  localhost:5000/my-company/pipeline-component:v1.0
```

---

## 파이프라인 코드에서 로컬 레지스트리 사용

KFP Python SDK로 파이프라인을 작성할 때, 이미지 주소를 로컬 레지스트리 주소로 지정합니다:

```python
from kfp import dsl

@dsl.component(
    base_image="localhost:5000/my-company/pipeline-component:v1.0"
)
def my_component(input: str) -> str:
    return input.upper()
```

또는 컴파일된 파이프라인 YAML에서 이미지 주소를 직접 수정할 수도 있습니다.

---

## KFP Python SDK 오프라인 설치

파이프라인을 작성하는 개발자 PC에도 kfp 패키지를 오프라인으로 설치해야 합니다.

### 준비 머신 (인터넷 환경)
```bash
# kfp 및 의존성 패키지 다운로드
pip download kfp==2.15.0 -d ./kfp-packages/

# 폴더를 USB로 복사
```

### 개발자 PC (폐쇄망)
```bash
# 오프라인 설치
pip install --no-index --find-links=./kfp-packages/ kfp
```

---

## 레지스트리 카탈로그 확인

현재 로컬 레지스트리에 저장된 이미지 목록을 확인합니다:

```bash
# 이미지 목록
curl -s http://localhost:5000/v2/_catalog | python3 -m json.tool

# 특정 이미지의 태그 목록
curl -s http://localhost:5000/v2/my-company/pipeline-component/tags/list | python3 -m json.tool
```
