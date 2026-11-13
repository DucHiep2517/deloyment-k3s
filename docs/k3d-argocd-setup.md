# Hướng dẫn bật cluster k3d + Argo CD

Tài liệu này có 2 luồng:

- **Bật lại cluster đã có** (dùng hằng ngày, sau khi tắt máy / tắt Docker) → [mục 1](#1-bật-lại-cluster-đã-có).
- **Dựng mới từ đầu** (máy mới, hoặc đã xoá cluster) → làm lần lượt [mục 2](#2-tạo-cluster-mới) đến [mục 6](#6-deploy-các-service).

## Tổng quan

| Thành phần | Giá trị |
|---|---|
| Cluster | k3d `dev-cluster` (1 server + 2 agent), k3s `v1.35.5+k3s1`, kubectl context `k3d-dev-cluster` |
| Ingress controller | NGINX Ingress Controller (bản F5/NGINX), IngressClass `nginx`. Traefik mặc định của k3s đã bị gỡ |
| Argo CD | `v3.5.7`, namespace `argocd` |
| Argo CD Applications | `nginx-ingress` (Helm chart từ `helm.nginx.com/stable`) và một Application cho mỗi thư mục `services/*`, do ApplicationSet `services` sinh ra (hiện có `v3m-service`, `sync-data-crm`, `gateway-server`, dùng chart chung `charts/spring-service` → namespace `spring-app`) |
| Argo CD UI | <http://argocd.localhost:8080> |
| Gateway | <http://gateway.localhost:8080>. Đây là service duy nhất mở ra ngoài, các service còn lại là nội bộ |

Đường đi của request:

```
Trình duyệt :8080
  -> k3d-dev-cluster-serverlb :80        (container Docker, map cổng ra máy)
  -> nginx-ingress-controller            (namespace nginx-ingress)
       Host argocd.localhost  -> svc/argocd-server:443   (namespace argocd)
       Host gateway.localhost -> svc/gateway-server:80   (namespace spring-app)
```

Các service khác (`v3m-service`, `sync-data-crm`…) không có Ingress, chỉ gọi được từ trong cluster qua `http://<tên service>`, ví dụ gateway gọi vào.

Argo CD đọc manifest từ GitHub (`https://github.com/DucHiep2517/deloyment-k3s.git`, nhánh `main`), không đọc từ máy local. Sửa chart xong phải **commit + push** thì cluster mới đổi.

## 0. Chuẩn bị (một lần)

```bash
brew install k3d kubectl helm
```

Cài và mở Docker Desktop. Vào *Settings → Resources* cấp tối thiểu **8 GB RAM**: app chạy 2 pod, mỗi pod request 1 GiB, limit 2 GiB, cộng thêm Argo CD và NGINX.

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
# NAME                   SYNC STATUS   HEALTH STATUS
# v3m-service            Synced        Healthy
# nginx-ingress          Synced        Healthy

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

## 6. Deploy các service

Mọi service Spring Boot dùng chung chart `charts/spring-service`. Mỗi service là một thư mục trong `services/`, trong đó có `values.yaml` chỉ ghi những gì khác với mặc định của chart.

ApplicationSet `services` (`argocd/services-appset.yaml`) quét `services/*` trên nhánh `main` và sinh một Argo CD Application cho mỗi thư mục:

| Thư mục | Application / Deployment / Service | Cổng app | Ingress |
|---|---|---|---|
| `services/gateway-server/` | `gateway-server` | `9095` | `gateway.localhost` |
| `services/v3m-service/` | `v3m-service` | `9092` | không (nội bộ) |
| `services/sync-data-crm/` | `sync-data-crm` | `8084` | không (nội bộ) |
| `services/<tên>/` | `<tên>` | `containerPort` | mặc định không |

Tất cả service nằm chung namespace `spring-app`. Mặc định service là **nội bộ**: chỉ có Deployment + Service, gọi được từ trong cluster qua `http://<tên service>` (cổng 80). Chỉ `gateway-server` bật Ingress để mở ra ngoài.

Image được build local, không nằm trên registry nào, nên phải nạp thẳng vào các node của k3d trước. Chi tiết cách build (jar, base image, đặt tag) xem [build-docker-image.md](build-docker-image.md).

```bash
# Build trong thư mục source code của service (repo khác)
docker build -t app-customer-service:1.0.0 .

# Nạp image vào tất cả node của cluster
k3d image import app-customer-service:1.0.0 -c dev-cluster
```

Tạo ApplicationSet (một lần):

```bash
kubectl apply -f argocd/services-appset.yaml
```

Các Application được sinh ra có sync policy `automated` + `prune` + `selfHeal`, nghĩa là:

- Push lên `main` → Argo CD tự sync (mặc định kiểm tra khoảng 3 phút một lần).
- Sửa tay bằng `kubectl edit/scale/delete` → Argo CD tự trả về như trong Git.

Kiểm tra:

```bash
kubectl get applicationset -n argocd services
kubectl get applications -n argocd            # mọi service: Synced / Healthy
kubectl get pods,svc,ingress -n spring-app    # chỉ có Ingress gateway-server

# Service mở ra ngoài (qua Ingress)
curl -i http://gateway.localhost:8080/actuator/health

# Service nội bộ: port-forward Service về máy rồi gọi
kubectl -n spring-app port-forward svc/v3m-service 9092:80
curl -i http://localhost:9092/actuator/health          # ở terminal khác
```

`curl` trả về response của app là đã thông. Gọi `gateway.localhost` mà nhận `404` từ nginx thì Ingress chưa khớp host.

### Thêm service mới

1. Build và import image:

   ```bash
   docker build -t order-service:1.0.0 .
   k3d image import order-service:1.0.0 -c dev-cluster
   ```

2. Tạo `services/order-service/values.yaml`. Tối thiểu chỉ cần:

   ```yaml
   image:
     repository: order-service
     tag: "1.0.0"
   containerPort: 8080   # server.port của app
   ```

3. Commit + push lên `main`. Khoảng 3 phút sau Argo CD tạo Application `order-service`. Muốn có ngay thì ép ApplicationSet đọc lại Git:

   ```bash
   kubectl -n argocd annotate applicationset services \
     argocd.argoproj.io/application-set-refresh=true --overwrite
   ```

Service mới là nội bộ, các service khác gọi nó qua `http://order-service`. Chỉ khi thật sự cần mở ra ngoài mới thêm vào values:

```yaml
ingress:
  enabled: true
  host: order.localhost   # -> http://order.localhost:8080 ; bỏ trống = order-service.localhost
```

Giá trị mặc định của chart (ghi đè trong `values.yaml` của service nếu cần):

| Key | Mặc định |
|---|---|
| `replicaCount` | `1` |
| `containerPort` | `8080` |
| `resources` | request `100m / 512Mi`, limit `1 CPU / 1Gi` |
| `env` | `JAVA_TOOL_OPTIONS=-XX:MaxRAMPercentage=60.0` |
| `startupProbe` / `readinessProbe` / `livenessProbe` | Tắt. Ví dụ bật với Actuator có sẵn trong `charts/spring-service/values.yaml` |
| `ingress.enabled` | `false` (nội bộ). Bật lên thì `ingress.host` mặc định là `<tên service>.localhost` |

Lưu ý:

- Tên thư mục là tên của mọi resource, nên chỉ dùng chữ thường, số và dấu `-`. Đổi tên thư mục nghĩa là xoá service cũ và tạo service mới.
- Các service gọi nhau qua `http://<tên service>` (cổng 80, cùng namespace `spring-app`).
- Xoá thư mục rồi push thì Argo CD xoá service đó khỏi cluster. Xoá ApplicationSet `services` thì **mọi** service bị xoá.
- 3 node k3d dùng chung RAM của Docker Desktop, dù mỗi node báo có 8 GiB riêng. Kubernetes không chặn khi tổng RAM vượt quá, nên phải tự theo dõi bằng `kubectl top nodes`.

### Ra phiên bản mới cho một service

1. Build image với tag mới, ví dụ `app-customer-service:1.0.1`.
2. `k3d image import app-customer-service:1.0.1 -c dev-cluster`
3. Sửa `image.tag` trong `services/<tên>/values.yaml`.
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
kubectl -n argocd annotate application v3m-service \
  argocd.argoproj.io/refresh=hard --overwrite
```

## 8. Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `connection to the server 0.0.0.0:61808 was refused` | Docker Desktop hoặc cluster đang tắt | Làm theo [mục 1](#1-bật-lại-cluster-đã-có) |
| `Cannot connect to the Docker daemon` | Docker Desktop chưa chạy | `open -a Docker`, chờ vài giây |
| Bấm mở Docker Desktop không hiện cửa sổ, nhưng `docker info` vẫn chạy | Giao diện đã tắt, engine vẫn chạy ngầm, nên `open -a Docker` không mở lại được | `docker desktop restart` (cluster dừng khoảng 1 phút rồi tự chạy lại) |
| kubectl trỏ nhầm cluster | Context khác đang được chọn | `kubectl config use-context k3d-dev-cluster` |
| Pod `Unknown` / `0/1` ngay sau khi bật lại | Node vừa khởi động, kubelet đang dựng lại pod | Chờ 1–2 phút |
| Pod app `ErrImagePull` / `ImagePullBackOff` | Image chưa được import vào node, nên k8s đi kéo từ Docker Hub và không thấy | `k3d image import app-customer-service:<tag> -c dev-cluster` |
| Pod app restart liên tục, `OOMKilled` | Thiếu RAM | Tăng RAM cho Docker Desktop; xem `resources` và `JAVA_TOOL_OPTIONS` trong `values.yaml` |
| `argocd.localhost:8080` trả 404 | Chưa apply Ingress của Argo CD, hoặc `nginx-ingress` chưa Healthy | Làm lại [mục 4](#4-cài-nginx-ingress-controller-qua-argo-cd) và [mục 5](#5-mở-argo-cd-ui-qua-ingress) |
| `argocd.localhost:8080` trả 502 | `argocd-server` chưa Ready, hoặc thiếu annotation `nginx.org/ssl-services` | `kubectl -n argocd get pods`; kiểm tra file `argocd/argocd-server-ingress.yaml` |
| Application `OutOfSync` mãi không đổi | Commit chưa push lên GitHub | `git push`, rồi ép refresh (mục 7) |
| Cổng 8080 bị chiếm khi tạo cluster | Có tiến trình khác dùng 8080 | `lsof -i :8080`, tắt tiến trình đó hoặc đổi `-p "<cổng khác>:80@loadbalancer"` |

## 9. Xoá cluster

```bash
k3d cluster delete dev-cluster
```

Lệnh này xoá toàn bộ cluster: Argo CD, các app, dữ liệu, cả image đã import. Muốn dùng lại thì làm từ [mục 2](#2-tạo-cluster-mới).
