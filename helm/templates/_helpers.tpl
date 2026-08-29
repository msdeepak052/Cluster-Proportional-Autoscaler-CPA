{{/* Chart name (nameOverride wins). */}}
{{- define "coredns-autoscaler.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name. */}}
{{- define "coredns-autoscaler.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "coredns-autoscaler.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "coredns-autoscaler.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "coredns-autoscaler.selectorLabels" -}}
app.kubernetes.io/name: {{ include "coredns-autoscaler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "coredns-autoscaler.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "coredns-autoscaler.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "coredns-autoscaler.configMapName" -}}
{{- default (include "coredns-autoscaler.fullname" .) .Values.configMap.name -}}
{{- end -}}

{{/* Chosen policy key: the value of config.mode ("linear" or "ladder"). */}}
{{- define "coredns-autoscaler.paramsKey" -}}
{{- .Values.config.mode -}}
{{- end -}}

{{/* Compact JSON of config.<mode>. Also validates mode; both configmap.yaml
     and deployment.yaml call this, so the check always runs. */}}
{{- define "coredns-autoscaler.params" -}}
{{- $m := .Values.config.mode -}}
{{- if not (or (eq $m "linear") (eq $m "ladder")) -}}
{{- fail (printf "config.mode must be \"linear\" or \"ladder\", got %q" $m) -}}
{{- end -}}
{{- $block := get .Values.config $m -}}
{{- if empty $block -}}
{{- fail (printf "config.%s is empty but config.mode=%s" $m $m) -}}
{{- end -}}
{{- $block | toJson -}}
{{- end -}}
