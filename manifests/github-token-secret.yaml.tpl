apiVersion: v1
kind: Secret
metadata:
  name: github-token
  namespace: ${ARGOCD_NAMESPACE}
type: Opaque
stringData:
  token: "${GITHUB_TOKEN}"
