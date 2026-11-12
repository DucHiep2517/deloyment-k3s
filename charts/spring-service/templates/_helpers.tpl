{{/*
Tên chung cho mọi tài nguyên của một service. Mặc định là release name,
ApplicationSet đặt release name = tên thư mục trong services/ -> tên service = tên thư mục.
*/}}
{{- define "spring-service.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Label dùng để chọn pod (selector của Deployment và Service).
Selector của Deployment không sửa được sau khi tạo, nên chỉ giữ đúng một label "app".
*/}}
{{- define "spring-service.selectorLabels" -}}
app: {{ include "spring-service.fullname" . }}
{{- end }}

{{/*
Label gắn vào metadata của Deployment, Service, Ingress.
*/}}
{{- define "spring-service.labels" -}}
{{ include "spring-service.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Host của Ingress: ingress.host nếu có, không thì <tên service>.localhost.
*/}}
{{- define "spring-service.host" -}}
{{- .Values.ingress.host | default (printf "%s.localhost" (include "spring-service.fullname" .)) }}
{{- end }}
