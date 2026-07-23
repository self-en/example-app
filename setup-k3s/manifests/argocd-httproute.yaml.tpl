apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd-server
  namespace: ${ARGOCD_NAMESPACE}
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${GATEWAY_NAMESPACE}
  hostnames:
  - "argocd.${DOMAIN_SUFFIX}"
  rules:
  - backendRefs:
    - name: argocd-server
      port: 80
