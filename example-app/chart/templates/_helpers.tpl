{{/* Per-branch database name, derived from the release name (e.g. preview-main -> preview_main) since Postgres identifiers don't take hyphens without quoting. */}}
{{- define "example-app.dbName" -}}
{{- .Release.Name | replace "-" "_" -}}
{{- end -}}
