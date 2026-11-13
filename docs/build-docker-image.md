# Build Docker image local và đưa vào cluster k3d

Hướng dẫn build image cho một service Spring Boot trên máy, rồi nạp vào cluster k3d `dev-cluster` để Argo CD deploy. Ví dụ dùng `customer-service` (image `app-customer-service`, chạy trong cluster dưới tên `v3m-service`).

## Tổng quan

```
source code (customer-service)
  │  mvn clean package
  ▼
target/app-customer-service-1.0.0.jar
  │  docker build
  ▼
image trong Docker Desktop        (docker images thấy được)
  │  k3d image import
  ▼
containerd của 3 node k3d          (pod chỉ dùng được image ở đây)
  │  sửa image.tag + git push
  ▼
Argo CD rollout pod mới
```

Docker Desktop và cluster k3d giữ image **ở hai nơi khác nhau**. Build xong image mới chỉ nằm trong Docker Desktop. Node k3d có containerd riêng nên không thấy image đó, phải `k3d image import` thì pod mới dùng được.

## 0. Chuẩn bị

| Công cụ | Trên máy này | Kiểm tra |
|---|---|---|
| Docker Desktop | đang dùng | `docker info --format '{{.ServerVersion}}'` |
| Maven | 3.6.3 (`~/Documents/apache-maven-3.6.3`) | `mvn -v` |
| JDK | 17 (build được project Java 11) | `mvn -v` (dòng `Java version`) |
| k3d | v5.9.0 | `k3d version` |

Cần biết thêm:

- **Maven repo công ty:** project kế thừa parent `com.ttt:core:0.0.5`, lấy từ Maven repo của công ty. Bản này đã có trong `~/.m2/repository/com/ttt/core/` nên build được khi không có mạng công ty. Nếu thêm dependency nội bộ mới chưa có trong `~/.m2` thì phải vào mạng công ty (hoặc VPN).
- **Kiến trúc chip:** máy là Apple Silicon (`arm64`), node k3d cũng là `arm64`. Docker Desktop mặc định build ra `linux/arm64`, khớp với cluster.

## 1. Build file jar

```bash
cd ~/Documents/Git3T/BE/customer-service
mvn clean package -DskipTests

ls target/*.jar
# target/app-customer-service-1.0.0.jar
```

Tên jar là `<artifactId>-<version>.jar`, lấy từ `pom.xml`. Dòng `COPY` trong `Dockerfile` ghi cứng tên `app-customer-service-1.0.0.jar`, nên **đổi `<version>` trong pom thì phải sửa cả dòng `COPY`**, không thì bước build image báo không tìm thấy file.

## 2. Build image

`Dockerfile` của `customer-service`:

```dockerfile
FROM registry.3tit.vn/base/base-docker-image/images/openjdk:11.0.6-jre
WORKDIR /app
COPY ./target/app-customer-service-1.0.0.jar /app/app-customer-service.jar
ENV TZ="Asia/Ho_Chi_Minh"
ENTRYPOINT ["sh", "-c", "exec java ${JAVA_OPTS} -jar /app/app-customer-service.jar"]
```

Base image nằm trên registry của công ty (`registry.3tit.vn`). Ngoài mạng công ty, registry này không truy cập được (kết nối bị timeout), nên build sẽ lỗi ngay ở dòng `FROM`. Image đang chạy trong cluster được build bằng base image công khai `eclipse-temurin:11-jre` thay thế.

### Cách A: thay base image lúc build, không sửa Dockerfile (khuyên dùng)

```bash
cd ~/Documents/Git3T/BE/customer-service

sed 's#^FROM .*#FROM eclipse-temurin:11-jre#' Dockerfile \
  | docker build -f - -t app-customer-service:1.0.1 .
```

- Lưu ý chạy docker cần thêm dấu . cuối câu

- `sed` đổi dòng `FROM` rồi đưa Dockerfile đã sửa vào `docker build` qua stdin (`-f -`).
- Dấu `.` cuối lệnh vẫn là thư mục project, nên `COPY ./target/...` vẫn tìm thấy file jar.
- File `Dockerfile` trong repo giữ nguyên, không có nguy cơ lỡ commit bản đã sửa.

### Cách B: dùng đúng Dockerfile gốc (khi ở mạng công ty hoặc có VPN)

```bash
docker login registry.3tit.vn
docker build -t app-customer-service:1.0.1 .
```

Chưa kiểm tra được base image của công ty có bản `arm64` hay không, vì registry không truy cập được lúc viết doc. Nếu nó chỉ có bản `amd64` thì app vẫn chạy được nhờ giả lập, nhưng chậm hơn.

### Kiểm tra image

```bash
docker images app-customer-service
docker image inspect app-customer-service:1.0.1 --format '{{.Os}}/{{.Architecture}}'
# linux/arm64
```

Image cũng hiện trong Docker Desktop, tab **Images**. Lịch sử các lần build xem ở tab **Builds** hoặc bằng `docker buildx history ls`.

## 3. Chạy thử bằng Docker (tuỳ chọn)

Trước khi đưa vào cluster, có thể chạy thử trực tiếp:

```bash
docker run --rm --name customer-service-test -p 9092:9092 app-customer-service:1.0.1
# terminal khác:
curl http://localhost:9092/actuator/health
```

`Ctrl+C` để dừng, `--rm` sẽ tự xoá container. App đọc cấu hình từ `application.yml` đóng gói trong jar (cổng `9092`), nên cũng cần kết nối được tới DB và các dịch vụ khác như khi chạy trong cluster.

## 4. Nạp image vào cluster k3d

```bash
k3d image import app-customer-service:1.0.1 -c dev-cluster
```

Lệnh này copy image vào containerd của cả 3 node (`server-0`, `agent-0`, `agent-1`). Kiểm tra:

```bash
docker exec k3d-dev-cluster-agent-0 crictl images | grep app-customer-service
docker exec k3d-dev-cluster-agent-1 crictl images | grep app-customer-service
```

## 5. Deploy bằng Argo CD

1. Sửa tag trong repo `deloyment-k3s`, file `services/values.yaml`, mục `v3m-service`:

   ```yaml
   v3m-service:
     image:
       repository: app-customer-service
       tag: "1.0.1"
   ```

2. Commit + push lên `main`.
3. Theo dõi rollout:

   ```bash
   kubectl -n argocd get application spring-app       # Synced / Healthy
   kubectl -n spring-app rollout status deploy/v3m-service
   kubectl -n spring-app get pods
   ```

Service mới làm tương tự, chỉ khác tên image và mục trong `services/values.yaml`. Xem mục "Thêm service mới" trong [k3d-argocd-setup.md](k3d-argocd-setup.md#thêm-service-mới).

## Quy tắc đặt tag

- **Mỗi lần build dùng một tag mới**, đừng build đè tag cũ. Chart đặt `imagePullPolicy: IfNotPresent`: node đã có `app-customer-service:1.0.0` thì sẽ không bao giờ lấy bản build lại cùng tag, kể cả khi đã `k3d image import`. Hơn nữa giá trị trong Git không đổi thì Argo CD cũng không rollout.
- Tag không bắt buộc trùng `<version>` trong pom. Gắn thêm mã commit giúp biết image được build từ code nào:

  ```bash
  TAG=1.0.0-$(git rev-parse --short HEAD)   # ví dụ 1.0.0-7d21e85
  ```

  Nếu working tree đang có thay đổi chưa commit thì mã này không phản ánh đúng code đã build.

## Gộp cả quy trình

```bash
cd ~/Documents/Git3T/BE/customer-service
TAG=1.0.0-$(git rev-parse --short HEAD)

mvn clean package -DskipTests \
  && sed 's#^FROM .*#FROM eclipse-temurin:11-jre#' Dockerfile \
     | docker build -f - -t app-customer-service:$TAG . \
  && k3d image import app-customer-service:$TAG -c dev-cluster \
  && echo "Xong. Đặt v3m-service.image.tag: \"$TAG\" trong services/values.yaml rồi push."
```

## Dọn image cũ

Mỗi bản build chiếm khoảng 700 MB trong Docker Desktop.

```bash
# Trong Docker Desktop
docker images app-customer-service
docker rmi app-customer-service:<tag-cũ>
docker image prune            # xoá image không còn tag (<none>)

# Trong node k3d (chỉ xoá tag không còn pod nào dùng)
for n in server-0 agent-0 agent-1; do
  docker exec k3d-dev-cluster-$n crictl rmi docker.io/library/app-customer-service:<tag-cũ>
done
```

## Lỗi thường gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `failed to resolve source metadata for registry.3tit.vn/...`, hoặc timeout ở bước `FROM` | Không vào được registry công ty | Dùng [Cách A](#cách-a-thay-base-image-lúc-build-không-sửa-dockerfile-khuyên-dùng), hoặc bật VPN |
| `"/target/app-customer-service-1.0.0.jar": not found` | Chưa chạy `mvn package`, hoặc `<version>` trong pom đã đổi | Chạy bước 1; sửa dòng `COPY` cho khớp tên jar |
| Maven báo `Could not resolve ... com.ttt:core` (hoặc dependency `com.ttt` khác) | Thiếu trong `~/.m2`, không vào được Maven repo công ty | Vào mạng công ty / VPN rồi build lại |
| `Cannot connect to the Docker daemon` | Docker Desktop đang tắt | `open -a Docker`, xem thêm [k3d-argocd-setup.md](k3d-argocd-setup.md#1-bật-lại-cluster-đã-có) |
| Pod `ErrImagePull` / `ImagePullBackOff` | Chưa `k3d image import`, hoặc tag trong `values.yaml` sai | Chạy bước 4, đối chiếu tag |
| Đã build lại nhưng pod vẫn chạy code cũ | Build đè cùng tag | Build với tag mới, sửa `image.tag`, push |
| Pod log báo `exec format error` | Image khác kiến trúc với node (vd. `amd64`) | Build lại trên máy này (ra `arm64`) hoặc dùng base image có bản `arm64` |
