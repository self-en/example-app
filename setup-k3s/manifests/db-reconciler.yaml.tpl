# Drops orphaned per-branch databases (preview_<slug>) whose ArgoCD Application
# no longer exists. NOT a PreDelete hook in example-app/chart: ArgoCD can't
# render PreDelete hook manifests once the source branch is already gone from
# git (tested - "unable to resolve '<branch>' to a commit SHA"), so cleanup on
# branch deletion has to be reconciled from outside the deleted branch instead.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: db-reconciler
  namespace: ${POSTGRES_NAMESPACE}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: db-reconciler-applications-reader
rules:
- apiGroups: ["argoproj.io"]
  resources: ["applications"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: db-reconciler-applications-reader
  namespace: ${ARGOCD_NAMESPACE}
subjects:
- kind: ServiceAccount
  name: db-reconciler
  namespace: ${POSTGRES_NAMESPACE}
roleRef:
  kind: ClusterRole
  name: db-reconciler-applications-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: db-reconciler
  namespace: ${POSTGRES_NAMESPACE}
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 1
      template:
        spec:
          serviceAccountName: db-reconciler
          restartPolicy: Never
          containers:
          - name: reconcile
            image: postgres:16-alpine
            env:
            - name: PGHOST
              value: ${POSTGRES_CLUSTER_NAME}-rw.${POSTGRES_NAMESPACE}.svc.cluster.local
            - name: PGPORT
              value: "5432"
            - name: PGUSER
              value: postgres
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${POSTGRES_CLUSTER_NAME}-superuser
                  key: password
            - name: ARGOCD_NAMESPACE
              value: ${ARGOCD_NAMESPACE}
            command:
            - sh
            - -c
            - |
              set -e
              apk add --no-cache curl jq >/dev/null
              api=https://kubernetes.default.svc
              token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              cacert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              expected=$(curl -sf --cacert "$cacert" -H "Authorization: Bearer $token" \
                "$api/apis/argoproj.io/v1alpha1/namespaces/$ARGOCD_NAMESPACE/applications?labelSelector=branch" \
                | jq -r '.items[].metadata.labels.branch' | sed 's/^/preview_/' | tr '-' '_')
              actual=$(psql -d postgres -tA -c "SELECT datname FROM pg_database WHERE datname LIKE 'preview\_%'")
              for db in $actual; do
                if ! printf '%s\n' "$expected" | grep -qx "$db"; then
                  echo "[db-reconciler] dropping orphaned database: $db"
                  psql -d postgres -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)"
                fi
              done
              echo "[db-reconciler] done. expected=[$expected] actual=[$actual]"
