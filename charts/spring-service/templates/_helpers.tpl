{{/*
Tên chung cho mọi tài nguyên. Cố ý không dùng .Release.Name để tên luôn là "v3m-service"
dù Argo CD đặt release name là gì -> không đổi tên Service (DNS) và selector của Deployment.
*/}}
{{- define "v3m-service.fullname" -}}
{{- default .Chart.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Label dùng để chọn pod (selector của Deployment và Service).
Selector của Deployment không sửa được sau khi tạo, nên chỉ giữ đúng một label "app".
*/}}
{{- define "v3m-service.selectorLabels" -}}
app: {{ include "v3m-service.fullname" . }}
{{- end }}

{{/*
Label gắn vào metadata của Deployment, Service, Ingress.
*/}}
{{- define "v3m-service.labels" -}}
{{ include "v3m-service.selectorLabels" . }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
