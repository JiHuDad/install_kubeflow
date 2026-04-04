# 문제 해결 가이드

## 준비 단계 (인터넷 환경)

### 이미지 Pull 실패

**증상**: `docker pull` 실패, `failed-images.txt` 에 항목이 쌓임

**해결책**:
1. 네트워크 연결 확인: `curl -I https://ghcr.io`
2. Docker Hub rate limit: `docker login` 후 재시도
3. 특정 이미지 수동 pull:
   ```bash
   docker pull --platform linux/amd64 <image>
   docker save <image> -o airgap-bundle/images/<name>.tar
   ```
4. skopeo 설치 후 재시도 (대체 수단):
   ```bash
   # Ubuntu
   sudo apt-get install -y skopeo
   bash scripts/01-collect-images.sh
   ```

### kustomize build 실패

**증상**: `kustomize build` 명령어 오류

**해결책**:
```bash
# kustomize 버전 확인
kustomize version

# 수동으로 manifest 클론
git clone --depth 1 --branch 2.15.0 \
  https://github.com/kubeflow/pipelines.git /tmp/pipelines

# 올바른 경로로 빌드
kustomize build /tmp/pipelines/manifests/kustomize/env/platform-agnostic-pns
```

---

## 폐쇄망 설치 단계

### K3s 설치 실패

**증상**: `10-install-k3s.sh` 에서 systemd 서비스 시작 실패

**해결책**:
```bash
# K3s 로그 확인
journalctl -u k3s -n 50 --no-pager

# airgap 이미지 위치 확인
ls /var/lib/rancher/k3s/agent/images/

# 수동 재시작
systemctl restart k3s
```

### 노드가 NotReady 상태

**증상**: `kubectl get nodes` 에서 NotReady

**해결책**:
```bash
# K3s 로그에서 원인 파악
journalctl -u k3s -f

# containerd 상태 확인
systemctl status containerd

# airgap 이미지 로드 확인
ctr images ls | grep "k3s\|pause"
```

### 레지스트리 접근 불가

**증상**: `curl http://localhost:5000/v2/` 실패

**해결책**:
```bash
# 레지스트리 컨테이너 상태 확인
nerdctl ps -a | grep registry
# 또는
docker ps -a | grep registry

# 로그 확인
nerdctl logs kfp-registry

# 재시작
nerdctl restart kfp-registry
```

### Pod가 ImagePullBackOff

**증상**: `kubectl get pods -n kubeflow` 에서 `ImagePullBackOff`

**해결책**:
```bash
# Pod 이벤트 확인
kubectl describe pod <pod-name> -n kubeflow

# 이미지명 확인
kubectl get pod <pod-name> -n kubeflow -o jsonpath='{.spec.containers[*].image}'

# 레지스트리 카탈로그 확인
curl http://localhost:5000/v2/_catalog

# registries.yaml 확인
cat /etc/rancher/k3s/registries.yaml

# K3s 재시작 후 확인
systemctl restart k3s
```

### ml-pipeline-ui Pod CrashLoopBackOff

**증상**: 프론트엔드 Pod가 계속 재시작

**해결책**:
```bash
# 로그 확인
kubectl logs -n kubeflow deployment/ml-pipeline-ui

# 백엔드(ml-pipeline) 상태 확인
kubectl get pods -n kubeflow -l app=ml-pipeline
kubectl logs -n kubeflow deployment/ml-pipeline
```

### KFP UI에서 502/503 오류

**증상**: 브라우저에서 502 또는 503

**해결책**:
```bash
# 모든 Pod 상태 확인
kubectl get pods -n kubeflow

# ml-pipeline (API 서버) 준비 대기
kubectl wait --for=condition=Ready pod \
  -l app=ml-pipeline -n kubeflow --timeout=300s

# 서비스 엔드포인트 확인
kubectl get endpoints -n kubeflow
```

---

## 네트워크 접근 문제

### 폐쇄망 내 다른 PC에서 접근 불가

**증상**: `http://<서버IP>:31380` 접속 실패

**해결책**:
1. 서버 방화벽 확인:
   ```bash
   # Ubuntu
   sudo ufw status
   sudo ufw allow 31380/tcp

   # RHEL/CentOS
   sudo firewall-cmd --list-ports
   sudo firewall-cmd --add-port=31380/tcp --permanent
   sudo firewall-cmd --reload
   ```
2. NodePort 확인:
   ```bash
   kubectl get svc ml-pipeline-ui -n kubeflow
   ```
3. 서버 IP 확인:
   ```bash
   hostname -I
   ip addr show
   ```

---

## 로그 파일 위치

모든 스크립트는 `logs/` 디렉터리에 로그를 저장합니다:

```
logs/
├── 01-collect-images.log
├── 02-download-binaries.log
├── 10-install-k3s.log
├── 11-setup-registry.log
├── 12-load-and-push-images.log
├── 13-install-kfp.log
└── 14-verify.log
```
