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
          # Read once from the real postgres-app secret by 04-appset.sh and passed
          # straight through, so every preview gets working DB access without any
          # per-namespace secret copying.
          - name: postgres.uri
            value: '${POSTGRES_URI}'
      destination:
        server: https://kubernetes.default.svc
        namespace: 'preview-{{.branch | slugify}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
