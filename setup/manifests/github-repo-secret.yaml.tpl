apiVersion: v1
kind: Secret
metadata:
  name: github-repo-${GITHUB_OWNER}-${GITHUB_REPO}
  namespace: ${ARGOCD_NAMESPACE}
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git
  username: ${GITHUB_OWNER}
  password: ${GITHUB_TOKEN}
