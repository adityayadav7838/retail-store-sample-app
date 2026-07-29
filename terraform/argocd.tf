# =============================================================================
# ARGOCD INSTALLATION AND CONFIGURATION
# =============================================================================

# Wait for the cluster and add-ons to be ready before deploying ArgoCD
resource "time_sleep" "wait_for_cluster" {
  create_duration = "45s"

  depends_on = [
    module.retail_app_eks,
    module.eks_addons
  ]
}

# =============================================================================
# ARGOCD HELM INSTALLATION
# =============================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = var.argocd_namespace
  create_namespace = true

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  # ArgoCD configuration values
  values = [
    yamlencode({
      # Server configuration
      server = {
        service = {
          type = "ClusterIP"
        }
        ingress = {
          enabled = false # Access via port-forwarding or ingress
        }
        # Enable insecure mode for easier local TLS termination
        extraArgs = [
          "--insecure"
        ]
      }
      
      # Controller configuration
      controller = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }
      
      # Repo server configuration
      repoServer = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }
      
      # Redis configuration
      redis = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "128Mi"
          }
        }
      }
    })
  ]

  depends_on = [time_sleep.wait_for_cluster]
}

# =============================================================================
# ARGOCD PROJECTS AND APPLICATIONS DISCOVERY
# =============================================================================

# Automatically apply all project manifests if present in ../argocd/projects
resource "kubectl_manifest" "argocd_projects" {
  for_each  = fileset("${path.module}/../argocd/projects", "*.yaml")
  yaml_body = file("${path.module}/../argocd/projects/${each.value}")

  depends_on = [helm_release.argocd]
}

# Automatically apply all application manifests if present in ../argocd/applications
resource "kubectl_manifest" "argocd_apps" {
  for_each  = fileset("${path.module}/../argocd/applications", "*.yaml")
  yaml_body = file("${path.module}/../argocd/applications/${each.value}")

  depends_on = [kubectl_manifest.argocd_projects]
}