# One ArgoCD Application per branch of ${GITHUB_OWNER}/${GITHUB_REPO}.
# The hostname is computed automatically from the branch name (slugify: lowercase,
# non-alphanumeric -> '-', truncated to a safe DNS label length) - no per-branch
# changes required in the application repo.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: branch-previews
  namespace: ${ARGOCD_NAMESPACE}
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
  - scmProvider:
      cloneProtocol: https
      requeueAfterSeconds: 180
      github:
        organization: ${GITHUB_OWNER}
        allBranches: true
        ${GITHUB_TOKEN_REF_BLOCK}
      filters:
      - repositoryMatch: "^${GITHUB_REPO}$"
  template:
    metadata:
      name: 'preview-{{.branch | slugify}}'
      labels:
        branch: '{{.branch | slugify}}'
      finalizers:
      - resources-finalizer.argocd.argoproj.io
    spec:
      project: default
      source:
        repoURL: '{{.url}}'
        targetRevision: '{{.branch}}'
        path: ${APP_CHART_PATH}
        helm:
          parameters:
          - name: hostname
            value: '{{.branch | slugify}}.${DOMAIN_SUFFIX}'
          # Matches the image tag pushed by .github/workflows/example-app.yml for
          # this branch (computed there with the same slugify rules), so each
          # preview runs the build produced for its own branch.
          - name: image.tag
            value: '{{.branch | slugify}}'
          # Read once by 04-appset.sh and passed straight through. The chart uses
          # these to create/drop a dedicated per-branch database (PreSync/PreDelete
          # hooks) instead of sharing one database across every preview.
          - name: postgres.host
            value: '${POSTGRES_HOST}'
          - name: postgres.appUser
            value: '${POSTGRES_APP_USER}'
          - name: postgres.appPassword
            value: '${POSTGRES_APP_PASSWORD}'
          - name: postgres.adminPassword
            value: '${POSTGRES_ADMIN_PASSWORD}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'preview-{{.branch | slugify}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
