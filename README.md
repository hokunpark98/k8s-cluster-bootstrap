**한글 문서** | **[English Document](./README-en.md)**

# k8s-cluster-bootstrap

control-plane 한 대에서 고정된 5노드 Kubernetes GPU 클러스터 기반을 자동 구축합니다. GPU worker 네 대는 SSH를 통해 설치하고 가입시키므로 worker에서 별도 명령을 실행할 필요가 없습니다.

## 고정 토폴로지

| 역할 | 수량 | 용도 |
| --- | ---: | --- |
| platform/control-plane | 1 | Kubernetes 및 플랫폼 컴포넌트 |
| GPU backend worker | 4 | RTX 3090 한 개와 향후 vLLM replica 한 개씩 |

스크립트는 platform과 GPU backend 역할 label 및 고정 backend index를 적용합니다. 각 GPU worker에서 RTX 3090 24 GiB와 NVIDIA Driver를 검사하고 Toolkit/CDI를 구성합니다.

## 고정 버전

| 구성 요소 | 정확한 버전 |
| --- | --- |
| Kubernetes | **1.35.6** |
| containerd | **2.2.6** |
| Calico | **3.32.1** |
| Helm | **3.20.0** |
| Metrics Server | **0.8.1** |
| NVIDIA Driver | 기존 **580.173.02** 검사 및 사용 |
| NVIDIA Container Toolkit | **1.19.1** |
| GPU Operator | **26.3.3** |
| Model-serving platform | **1.3.0** |
| vLLM runtime | image **1.3.0**, vLLM **0.23.0**, CUDA **13.0** |
| Gateway API | **1.5.1** |
| Gateway API Inference Extension | **1.2.1** |
| agentgateway | **1.0.0** |

버전과 노드 정보는 Git에서 제외된 `cluster.env`에서 관리합니다.

## 설치 범위

스크립트는 변경을 시작하기 전에 Ubuntu 24.04/amd64, NTP 동기화, IP 소유권, 고유 hostname, SSH/sudo 및 GPU 조건을 검사합니다. Kubernetes, Calico, Metrics Server를 설치하고 GPU worker 네 대를 가입시킨 뒤 총 5개 Node가 `Ready`인지 확인합니다.

GPU backend에만 host Toolkit/CDI를 적용하고, 정확히 네 대가 각각 `nvidia.com/gpu=1`을 제공하는지 검사합니다. containerd의 기본 runtime은 `runc`로 유지하며 native CDI와 명시적 `RuntimeClass/nvidia` 경로를 모두 실행 검증합니다.

Platform 노드에는 cluster-wide model-serving operator와 단일 NATS JetStream을 설치하고 Kubernetes-native discovery를 사용합니다. 이어서 Gateway API, Inference Extension, agentgateway controller 및 `GatewayClass`를 설치합니다. 마지막으로 platform과 각 GPU backend 사이의 cluster DNS 및 Pod TCP 경로를 검사하고, 네 GPU backend에서 동일한 vLLM runtime image, vLLM 0.23.0 및 CUDA 13.0을 확인합니다.

부트스트랩은 다음 자원을 만들지 않습니다.

- Gateway 인스턴스와 외부 NodePort/LoadBalancer
- HTTPRoute 및 serving routing resource
- endpoint-selection data plane
- 모델 배포, Frontend 및 vLLM serving Pod
- planner, autoscaling, GPU sharing, P/D disaggregation, service mesh

이 자원들은 클러스터 구축 후 별도의 workload manifest에서 생성합니다.

## 사전 조건

- 모든 노드는 NTP가 동기화된 Ubuntu 24.04 amd64
- control-plane에서 GPU worker 네 대로 SSH 및 root/sudo 실행 가능
- 서로 다른 hostname과 노드 간 통신 가능
- GPU backend마다 RTX 3090 1개(24576 MiB), NVIDIA Driver 580.173.02 설치 완료
- Kubernetes, GitHub, NVIDIA, NGC 및 agentgateway registry 접근 가능
- 기존 Kubernetes 클러스터가 없는 깨끗한 노드
- control-plane에 기존 Helm binary가 없음

스크립트는 swap과 UFW를 비활성화하고 충돌하는 Docker 및 배포판 containerd 패키지를 제거한 뒤 upstream containerd를 설치합니다. NVIDIA Driver를 설치하거나 변경하지 않으며 자동 reboot도 하지 않습니다.

## 설정

```bash
cp cluster.env.example cluster.env
chmod 600 cluster.env
```

`cluster.env`의 indexed `GPU_WORKER_*` 항목에 GPU worker 네 대의 연결 정보를 설정합니다. 빈 필수 값은 실행 중 입력을 요청하고 권한 `600`을 유지한 채 같은 파일에 저장합니다. 설치, 재개 및 cleanup은 이 파일의 노드 정보를 그대로 신뢰하므로 실행 전에 모든 주소와 계정을 확인해야 합니다.

`cluster.env`는 SSH credential을 포함할 수 있으므로 Git에서 제외되며, 권한이 `600`보다 열려 있으면 실행을 거부합니다.

## 실행

control-plane에서만 실행합니다.

```bash
chmod +x k8s-cluster-bootstrap.sh
sudo ./k8s-cluster-bootstrap.sh
```

설치 중 reboot할 필요가 없습니다. 새 NVIDIA Driver가 아직 커널에 반영되지 않은 경우에만 모든 노드를 먼저 reboot합니다.

사전검사는 네 worker 모두에 대해 먼저 완료합니다. 실제 설치와 `kubeadm join`은 최대 4대까지 병렬 실행하며, 한 대라도 실패하면 모든 worker의 종료 상태를 회수한 뒤 후속 플랫폼 설치 전에 중단합니다. worker별 root 전용 로그 위치는 실행 중 출력됩니다. 대용량 vLLM runtime image pull은 네트워크 포화를 줄이기 위해 최대 2대만 동시에 실행합니다.

중단된 설치는 같은 설정으로 재개합니다.

```bash
sudo ./k8s-cluster-bootstrap.sh --resume
```

재개 모드는 현재 Kubernetes 상태와 설정된 노드 정보를 대조합니다. 정확한 버전과 GPU runtime 상태로 `Ready`인 worker는 보존하고, 가입이 중단됐거나 상태가 맞지 않는 worker만 reset한 뒤 재설치·재가입합니다.

## 완료 상태

성공 시 다음 상태를 검증합니다.

- Node 5개: platform 1대, GPU backend 4대 모두 `Ready`
- 모든 노드: Kubernetes 1.35.6, containerd 2.2.6
- GPU backend: Toolkit 1.19.1, CDI spec, `RuntimeClass/nvidia`, RTX 3090 각 1개
- Calico 주소와 각 Node의 설정된 Kubernetes `InternalIP` 일치
- Platform 및 각 GPU backend에서 모든 GPU backend로 향하는 Pod IP TCP와 cluster DNS 통과
- Model-serving operator 1.3.0과 NATS JetStream PVC `Bound`
- Gateway API/Inference Extension CRD, agentgateway controller 및 `GatewayClass`
- 네 GPU backend의 vLLM runtime image, vLLM 0.23.0, CUDA 13.0 및 동일 image digest
- credential을 포함하지 않은 설치 요약 보고서 생성

## 전체 제거

동일한 `cluster.env`를 사용합니다.

```bash
sudo ./k8s-cluster-cleanup.sh
```

cleanup은 확인 질문에 `y`를 입력한 뒤 Gateway 기반, model-serving platform과 NATS 데이터, GPU Operator, Kubernetes/Calico, containerd 이미지 및 GPU backend의 Toolkit을 제거합니다. NVIDIA Driver와 무관한 사용자 kubeconfig/Helm 데이터는 보존합니다.

GPU worker 네 대는 병렬로 정리하며 모든 작업이 성공한 경우에만 control-plane을 마지막으로 정리합니다. 실패한 worker의 root 전용 로그 위치는 실행 결과에 표시됩니다. 완료 후 각 worker와 control-plane을 수동 reboot하고 GPU backend에서 `nvidia-smi`를 확인합니다. swap과 UFW 상태는 자동 복구하지 않습니다.

## 기여 가이드라인

[기여 가이드라인](.github/CONTRIBUTING.md)을 참고하세요.
