# Hướng dẫn bật cluster k3d + Argo CD

Tài liệu này có 2 luồng:

- **Bật lại cluster đã có** (dùng hằng ngày, sau khi tắt máy / tắt Docker) → [mục 1](#1-bật-lại-cluster-đã-có).
- **Dựng mới từ đầu** (máy mới, hoặc đã xoá cluster) → làm lần lượt [mục 2](#2-tạo-cluster-mới) đến [mục 6](#6-deploy-các-hệ-thống).

## Tổng quan

| Thành phần | Giá trị |
|---|---|
| Cluster | k3d `dev-cluster` (1 server + 2 agent), k3s `v1.35.5+k3s1`, kubectl context `k3d-dev-cluster` |
| Ingress controller | NGINX Ingress Controller (bản F5/NGINX), IngressClass `nginx`. Traefik mặc định của k3s đã bị gỡ |
| Argo CD | `v3.5.7`, namespace `argocd` |
| Argo CD Applications | `nginx-ingress` (Helm chart từ `helm.nginx.com/stable`) và một Application cho mỗi hệ thống trong `apps/` (`v3m`, `hr-backend`, `questlab`), do ApplicationSet `apps` sinh ra |
| Argo CD UI | <http://argocd.localhost:8080> |
| Cửa vào các hệ thống | `v3m`: <http://gateway.localhost:8080>, `hr-backend`: <http://hr.localhost:8080>, `questlab`: <http://questlab.localhost:8080> |

Cấu trúc repo:

```
deloyment-k3s/
├── charts/spring-service/      # chart chung cho mọi service (Spring Boot, .NET...)
├── apps/                       # mỗi thư mục = 1 hệ thống = 1 Application = 1 namespace
│   ├── v3m/                    #   Chart.yaml (danh sách service) + values.yaml (cấu hình)
│   ├── hr-backend/
│   └── questlab/
├── argocd/
│   ├── apps-appset.yaml        # ApplicationSet: sinh Application cho mỗi thư mục apps/*
│   ├── nginx-ingress-application.yaml
│   └── argocd-server-ingress.yaml
└── docs/
```

Đường đi của request:

```
Trình duyệt :8080
  -> k3d-dev-cluster-serverlb :80        (container Docker, map cổng ra máy)
  -> nginx-ingress-controller            (namespace nginx-ingress)
       Host argocd.localhost   -> svc/argocd-server:443      (namespace argocd)
       Host gateway.localhost  -> svc/gateway-server:80      (namespace v3m)
       Host hr.localhost       -> svc/hr-be:80               (namespace hr-backend)
       Host questlab.localhost -> svc/questlab-service:80    (namespace questlab)
```

Các service còn lại (`app-customer-service`, `sync-data-crm`…) không có Ingress, chỉ gọi được từ trong cluster.

Argo CD đọc manifest từ GitHub (`https://github.com/DucHiep2517/deloyment-k3s.git`, nhánh `main`), không đọc từ máy local. Sửa chart hoặc values xong phải **commit + push** thì cluster mới đổi.

## 0. Chuẩn bị (một lần)

```bash
brew install k3d kubectl helm
```

Cài và mở Docker Desktop. Vào *Settings → Resources* cấp RAM cho đủ mọi hệ thống: riêng `v3m` đã dùng khoảng 4.5 GiB (Argo CD, NGINX, 4 pod Spring). Chạy thêm `hr-backend` và `questlab` thì nên cấp **10–12 GiB** (máy có 16 GiB).

Kiểm tra:

```bash
docker info --format '{{.ServerVersion}}'
k3d version
kubectl version --client
```

## 1. Bật lại cluster đã có

Dấu hiệu cluster đang tắt:

```
The connection to the server 0.0.0.0:61808 was refused - did you specify the right host or port?
```

hoặc

```
Cannot connect to the Docker daemon at unix:///Users/<user>/.docker/run/docker.sock
```

Nguyên nhân thường là Docker Desktop đang tắt. Các bước:

```bash
# 1. Mở Docker Desktop và chờ daemon sẵn sàng
open -a Docker
until docker info >/dev/null 2>&1; do sleep 2; done

# 2. Xem cluster. Nếu cột SERVERS là 0/1 thì start
k3d cluster list
k3d cluster start dev-cluster

# 3. Trỏ kubectl vào đúng cluster và chờ node Ready
kubectl config use-context k3d-dev-cluster
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# 4. Chờ pod chạy lại
kubectl get pods -A
```

Container của k3d có restart policy `unless-stopped`, nên mở Docker Desktop là cluster tự chạy lại. Cluster chỉ đứng yên nếu trước đó đã tắt bằng `k3d cluster stop`, khi đó cần chạy `k3d cluster start` ở bước 2.

Nếu Docker bị tắt đột ngột, ngay sau khi bật lại sẽ thấy nhiều pod ở trạng thái `Unknown` hoặc `0/1`. Pod sẽ tự về `Running` sau 1–2 phút, không cần xoá. Có thể theo dõi bằng:

```bash
kubectl get pods -A -w
```

Kiểm tra Argo CD đã chạy lại:

```bash
kubectl get applications -n argocd
# NAME            SYNC STATUS   HEALTH STATUS
# hr-backend      Synced        Healthy
# nginx-ingress   Synced        Healthy
# questlab        Synced        Healthy
# v3m             Synced        Healthy

curl -s -o /dev/null -w '%{http_code}\n' http://argocd.localhost:8080/   # 200
```

Tắt cluster khi không dùng (giải phóng RAM, dữ liệu vẫn giữ):

```bash
k3d cluster stop dev-cluster
```

## 2. Tạo cluster mới

```bash
k3d cluster create dev-cluster \
  --servers 1 \
  --agents 2 \
  -p "8080:80@loadbalancer" \
  -p "8443:443@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"
```

| Tham số | Ý nghĩa |
|---|---|
| `--servers 1 --agents 2` | 1 node control-plane, 2 node worker |
| `-p "8080:80@loadbalancer"` | Cổng 8080 của máy → cổng 80 trong cluster (nơi NGINX Ingress lắng nghe) |
| `-p "8443:443@loadbalancer"` | Tương tự cho HTTPS |
| `--k3s-arg "--disable=traefik@server:0"` | Không cài Traefik vì cluster dùng NGINX Ingress Controller |

k3d tự thêm context `k3d-dev-cluster` vào `~/.kube/config` và chuyển sang context đó. Kiểm tra:

```bash
kubectl get nodes                  # 3 node Ready
kubectl get pods -n kube-system    # không có pod traefik
```

> Cluster hiện tại được tạo khi chưa có cờ `--disable=traefik`, Traefik được gỡ thủ công sau đó (tạo file `traefik.yaml.skip` trong thư mục manifests của k3s server rồi xoá HelmChart `traefik`, `traefik-crd`). Cluster này còn map thêm cổng `9098 -> 80`, chạy song song với 8080. Khi tạo mới thì dùng lệnh ở trên là đủ.

## 3. Cài Argo CD

```bash
kubectl create namespace argocd

kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.7/manifests/install.yaml

# Chờ các thành phần chính sẵn sàng
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
```

`--server-side` là cần thiết vì CRD của Argo CD quá lớn, apply kiểu client-side có thể lỗi `metadata.annotations: Too long`.

Lấy mật khẩu `admin`:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Lúc này chưa có Ingress, nên vào UI tạm bằng port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8081:443
```

Mở <https://localhost:8081> (cert tự ký, bấm bỏ qua cảnh báo), đăng nhập `admin` / mật khẩu ở trên.

Repo `deloyment-k3s` đang public nên Argo CD đọc được mà không cần khai báo credentials.

## 4. Cài NGINX Ingress Controller (qua Argo CD)

```bash
kubectl apply -f argocd/nginx-ingress-application.yaml
```

Argo CD sẽ cài Helm chart `nginx-ingress` 2.8.0 vào namespace `nginx-ingress` và tạo IngressClass `nginx` (đặt làm mặc định). Kiểm tra:

```bash
kubectl get applications -n argocd nginx-ingress   # Synced / Healthy
kubectl get ingressclass                           # nginx
kubectl get svc -n nginx-ingress                   # nginx-ingress-controller, TYPE LoadBalancer
```

## 5. Mở Argo CD UI qua Ingress

```bash
kubectl apply -f argocd/argocd-server-ingress.yaml
```

Sau đó vào <http://argocd.localhost:8080>. Tên miền `*.localhost` tự trỏ về `127.0.0.1` nên không cần sửa `/etc/hosts`.

`argocd-server` chỉ phục vụ HTTPS, nên Ingress có annotation `nginx.org/ssl-services: "argocd-server"` để NGINX gọi vào bằng HTTPS. Thiếu annotation này sẽ bị lỗi redirect hoặc 502. Cách port-forward ở mục 3 vẫn dùng được song song.

## 6. Deploy các hệ thống

### Mô hình

Mỗi **hệ thống** là một thư mục trong `apps/`, và là một umbrella chart gồm 2 file:

- `Chart.yaml`: danh sách service của hệ thống. Mỗi service là một dependency tới chart chung `charts/spring-service`, **alias = tên service**.
- `values.yaml`: cấu hình của từng service, mỗi service một mục trùng alias. Chỉ ghi những gì khác mặc định của chart.

ApplicationSet `apps` (`argocd/apps-appset.yaml`) quét `apps/*` trên nhánh `main` và sinh cho mỗi thư mục một Argo CD Application (`kind: Application`):

```
apps/<hệ thống>/  ->  Application <hệ thống>  ->  namespace <hệ thống>
```

Argo CD tự chạy `helm dependency build` để lấy `charts/spring-service`, rồi render mọi service của hệ thống một lượt.

| Hệ thống | Service (alias) | Công nghệ | Cổng app | Ingress |
|---|---|---|---|---|
| `v3m` | `gateway-server` | Spring Boot (Zuul) | `9095` | `gateway.localhost` |
| | `app-customer-service` | Spring Boot | `9092` | không (nội bộ) |
| | `sync-data-crm` | Spring Boot | `8084` | không (nội bộ) |
| `hr-backend` | `hr-be` | ASP.NET Core 8 | `8080` | `hr.localhost` |
| `questlab` | `questlab-service` | Spring Boot (Java 17) | `8080` | `questlab.localhost` |

Mặc định service là **nội bộ**: chỉ có Deployment + Service. Chỉ cửa vào của mỗi hệ thống mới bật Ingress.

Gọi giữa các service:

- Cùng hệ thống (cùng namespace): `http://<tên service>`, ví dụ `http://sync-data-crm`.
- Khác hệ thống: thêm namespace, `http://<tên service>.<hệ thống>`, ví dụ `http://app-customer-service.v3m`.
- Service lắng nghe cổng 80 (Service chuyển vào `containerPort` của app).

### Tạo ApplicationSet (một lần)

Image được build local, không nằm trên registry nào, nên phải nạp vào các node của k3d trước. Chi tiết cách build xem [build-docker-image.md](build-docker-image.md).

```bash
kubectl apply -f argocd/apps-appset.yaml
```

Các Application được sinh ra có sync policy `automated` + `prune` + `selfHeal`:

- Push lên `main` → Argo CD tự sync (mặc định kiểm tra khoảng 3 phút một lần).
- Sửa tay bằng `kubectl edit/scale/delete` → Argo CD tự trả về như trong Git.

ApplicationSet bật `preserveResourcesOnDeletion: true`: lỡ xoá ApplicationSet (hoặc một thư mục trong `apps/`) thì Application bị xoá nhưng Deployment/Service của hệ thống **vẫn chạy**, phải tự dọn bằng `kubectl delete namespace <hệ thống>` nếu muốn gỡ hẳn.

Kiểm tra:

```bash
kubectl get applicationset -n argocd apps
kubectl get applications -n argocd             # mỗi hệ thống một dòng, Synced / Healthy
kubectl get pods,svc,ingress -n v3m

# Cửa vào của hệ thống (qua Ingress)
curl -i http://gateway.localhost:8080/actuator/health

# Service nội bộ: port-forward Service về máy rồi gọi
kubectl -n v3m port-forward svc/app-customer-service 9092:80
curl -i http://localhost:9092/actuator/health          # ở terminal khác
```

`curl` trả về response của app là đã thông. Gọi host mà nhận `404` từ nginx thì Ingress chưa khớp host.

### Chuyển cluster từ cấu trúc cũ (`spring-app`) sang `apps/`

Trước kiến trúc này, hệ thống v3m chạy dưới Application `spring-app` (umbrella chart `services/`, namespace `spring-app`). Sau khi push kiến trúc mới, thư mục `services/` không còn trên `main`, nên Application `spring-app` báo lỗi `app path does not exist` nhưng **các pod cũ vẫn chạy** (Argo CD không render được thì không sync, không xoá gì).

Chuyển sang Application `v3m` (namespace `v3m`, pod được tạo mới):

```bash
# 1. Gỡ Application cũ. Nó không có finalizer nên các service vẫn chạy
kubectl -n argocd get application spring-app -o jsonpath='{.metadata.finalizers}'   # phải trống
kubectl -n argocd delete application spring-app

# 2. Gỡ service cũ (giải phóng RAM và host gateway.localhost)
kubectl delete namespace spring-app

# 3. Tạo ApplicationSet: sinh Application v3m, hr-backend, questlab
kubectl apply -f argocd/apps-appset.yaml
```

Gateway mất kết nối khoảng 30 giây, trong lúc Spring Boot khởi động trong namespace `v3m`. Không đảo bước 2 và 3: chạy song song 2 bản thì tốn gấp đôi RAM và có 2 Ingress cùng host `gateway.localhost`, NGINX chỉ dùng cái cũ.

`hr-backend` và `questlab` sẽ báo `ImagePullBackOff` cho tới khi build và import image (xem [build-docker-image.md](build-docker-image.md)).

### Thêm service vào một hệ thống

Ví dụ thêm `order-service` vào `v3m`:

1. Build và import image:

   ```bash
   docker build -t order-service:1.0.0 .
   k3d image import order-service:1.0.0 -c dev-cluster
   ```

2. Thêm một dependency vào `apps/v3m/Chart.yaml` (alias = tên service):

   ```yaml
     - name: spring-service
       alias: order-service
       version: ">=0.1.0"
       repository: file://../../charts/spring-service
   ```

3. Thêm một mục cùng tên vào `apps/v3m/values.yaml`. Tối thiểu chỉ cần:

   ```yaml
   order-service:
     image:
       repository: order-service
       tag: "1.0.0"
     containerPort: 8080   # server.port của app
   ```

4. Commit + push lên `main`. Khoảng 3 phút sau Argo CD sync Application `v3m` và tạo thêm `order-service`. Muốn có ngay thì xem lệnh ép refresh ở [mục 7](#7-kiểm-tra-nhanh).

Thiếu một trong hai bước 2 và 3 thì service không được tạo. Có mục trong `values.yaml` mà không có dependency thì Helm bỏ qua mục đó, không báo lỗi. Có dependency mà không có mục values thì chart báo lỗi `image.repository là bắt buộc`.

Xem trước YAML sẽ được tạo ra:

```bash
helm dependency build apps/v3m && helm template v3m apps/v3m --namespace v3m
```

Service mới là nội bộ. Chỉ khi nó là cửa vào của hệ thống mới thêm Ingress vào mục của nó:

```yaml
order-service:
  ingress:
    enabled: true
    host: order.localhost   # -> http://order.localhost:8080 ; bỏ trống = order-service.localhost
```

Host Ingress phải **khác nhau giữa mọi hệ thống**, vì cả cluster dùng chung một NGINX trên cổng 8080. Tên service thì được trùng nếu khác hệ thống (khác namespace).

### Thêm hệ thống mới

Ví dụ thêm hệ thống `crm`:

1. Tạo `apps/crm/Chart.yaml`:

   ```yaml
   apiVersion: v2
   name: crm
   type: application
   version: 0.1.0
   dependencies:
     - name: spring-service
       alias: crm-service
       version: ">=0.1.0"
       repository: file://../../charts/spring-service
   ```

2. Tạo `apps/crm/values.yaml` với một mục `crm-service:` như ở trên.
3. Commit + push. ApplicationSet tự tạo Application `crm` và namespace `crm`, không cần `kubectl apply` thêm gì. Muốn có ngay thì ép ApplicationSet đọc lại Git:

   ```bash
   kubectl -n argocd annotate applicationset apps \
     argocd.argoproj.io/application-set-refresh=true --overwrite
   ```

Tên thư mục là tên Application và namespace, nên chỉ dùng chữ thường, số và dấu `-`.

### Service không phải Java (ví dụ .NET)

Chart chung chỉ có một chỗ dành riêng cho Java: biến `JAVA_TOOL_OPTIONS` trong `env` mặc định. Service .NET ghi đè `env` để bỏ biến đó (Helm **thay hẳn** list chứ không ghép), như `hr-be` trong `apps/hr-backend/values.yaml`:

```yaml
hr-be:
  containerPort: 8080          # ASP.NET Core 8 mặc định lắng nghe 8080
  env:
    - name: ASPNETCORE_ENVIRONMENT
      value: Development
```

Tương tự, service Java nào ghi đè `env` thì phải ghi lại `JAVA_TOOL_OPTIONS`, nếu không JVM chỉ dùng 25% RAM limit làm heap.

### Giá trị mặc định của chart

Ghi đè trong mục của service trong `apps/<hệ thống>/values.yaml` nếu cần:

| Key | Mặc định |
|---|---|
| `replicaCount` | `1` |
| `containerPort` | `8080` |
| `resources` | request `100m / 512Mi`, limit `1 CPU / 1Gi` |
| `env` | `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=60.0` |
| `startupProbe` / `readinessProbe` / `livenessProbe` | Tắt. Ví dụ bật với Actuator có sẵn trong `charts/spring-service/values.yaml` |
| `ingress.enabled` | `false` (nội bộ). Bật lên thì `ingress.host` mặc định là `<tên service>.localhost` |

Lưu ý:

- Alias là tên của mọi resource, nên chỉ dùng chữ thường, số và dấu `-`. Đổi alias nghĩa là xoá service cũ và tạo service mới.
- Xoá dependency (và mục values) rồi push thì Argo CD xoá service đó khỏi cluster.
- Các service trong cùng hệ thống chung một Application: một service cấu hình sai (không render được) thì cả hệ thống đó báo lỗi và **không service nào** của nó được sync cho tới khi sửa xong. Các hệ thống khác không bị ảnh hưởng.
- 3 node k3d dùng chung RAM của Docker Desktop, dù mỗi node báo có 8 GiB riêng. Kubernetes không chặn khi tổng RAM vượt quá, nên phải tự theo dõi bằng `kubectl top nodes`.

### Ra phiên bản mới cho một service

1. Build image với tag mới, ví dụ `app-customer-service:1.0.1`.
2. `k3d image import app-customer-service:1.0.1 -c dev-cluster`
3. Sửa `image.tag` trong mục của service đó, ví dụ mục `app-customer-service` trong `apps/v3m/values.yaml`.
4. Commit + push lên `main`. Argo CD sẽ rollout.

Không ghi đè cùng một tag: `pullPolicy` là `IfNotPresent`, node đã có tag cũ sẽ không lấy image mới.

## 7. Kiểm tra nhanh

```bash
kubectl config current-context                  # k3d-dev-cluster
kubectl get nodes                               # 3 node Ready
kubectl get pods -A | grep -vE 'Running|Completed'   # không còn dòng nào
kubectl get applications -n argocd              # tất cả Synced / Healthy
curl -s -o /dev/null -w '%{http_code}\n' http://argocd.localhost:8080/   # 200
```

Ép Argo CD đọc lại Git ngay (không chờ chu kỳ 3 phút):

```bash
# Sửa service trong một hệ thống đã có
kubectl -n argocd annotate application v3m \
  argocd.argoproj.io/refresh=hard --overwrite

# Thêm hoặc xoá thư mục hệ thống trong apps/
kubectl -n argocd annotate applicationset apps \
  argocd.argoproj.io/application-set-refresh=true --overwrite
```

## 8. Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `connection to the server 0.0.0.0:61808 was refused` | Docker Desktop hoặc cluster đang tắt | Làm theo [mục 1](#1-bật-lại-cluster-đã-có) |
| `Cannot connect to the Docker daemon` | Docker Desktop chưa chạy | `open -a Docker`, chờ vài giây |
| Bấm mở Docker Desktop không hiện cửa sổ, nhưng `docker info` vẫn chạy | Giao diện đã tắt, engine vẫn chạy ngầm, nên `open -a Docker` không mở lại được | `docker desktop restart` (cluster dừng khoảng 1 phút rồi tự chạy lại) |
| kubectl trỏ nhầm cluster | Context khác đang được chọn | `kubectl config use-context k3d-dev-cluster` |
| Pod `Unknown` / `0/1` ngay sau khi bật lại | Node vừa khởi động, kubelet đang dựng lại pod | Chờ 1–2 phút |
| Pod `ErrImagePull` / `ImagePullBackOff` | Image chưa được import vào node, nên k8s đi kéo từ Docker Hub và không thấy | `k3d image import <image>:<tag> -c dev-cluster` |
| Pod restart liên tục, `OOMKilled` | Thiếu RAM | Tăng RAM cho Docker Desktop; xem `resources` và `JAVA_TOOL_OPTIONS` trong `values.yaml` |
| Application báo `image.repository là bắt buộc` | Có dependency trong `Chart.yaml` mà thiếu mục cùng tên trong `values.yaml` (thường do gõ sai alias) | Đối chiếu alias với tên mục trong `values.yaml` |
| Application `spring-app` báo `app path does not exist` | Cấu trúc cũ, thư mục `services/` đã bị xoá | Làm theo mục [Chuyển cluster từ cấu trúc cũ](#chuyển-cluster-từ-cấu-trúc-cũ-spring-app-sang-apps) |
| `argocd.localhost:8080` trả 404 | Chưa apply Ingress của Argo CD, hoặc `nginx-ingress` chưa Healthy | Làm lại [mục 4](#4-cài-nginx-ingress-controller-qua-argo-cd) và [mục 5](#5-mở-argo-cd-ui-qua-ingress) |
| `argocd.localhost:8080` trả 502 | `argocd-server` chưa Ready, hoặc thiếu annotation `nginx.org/ssl-services` | `kubectl -n argocd get pods`; kiểm tra file `argocd/argocd-server-ingress.yaml` |
| Application `OutOfSync` mãi không đổi | Commit chưa push lên GitHub | `git push`, rồi ép refresh (mục 7) |
| Cổng 8080 bị chiếm khi tạo cluster | Có tiến trình khác dùng 8080 | `lsof -i :8080`, tắt tiến trình đó hoặc đổi `-p "<cổng khác>:80@loadbalancer"` |

## 9. Xoá cluster

```bash
k3d cluster delete dev-cluster
```

Lệnh này xoá toàn bộ cluster: Argo CD, các app, dữ liệu, cả image đã import. Muốn dùng lại thì làm từ [mục 2](#2-tạo-cluster-mới).
