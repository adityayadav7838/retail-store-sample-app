# =============================================================================
# EKS ADD-ONS AND EXTENSIONS
# =============================================================================

# Stage 1: AWS Load Balancer Controller only
# Must be fully ready before other addons deploy, because LBC installs a
# MutatingWebhookConfiguration that intercepts Service creation cluster-wide.
module "eks_addons_lbc" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.retail_app_eks.cluster_name
  cluster_endpoint  = module.retail_app_eks.cluster_endpoint
  cluster_version   = module.retail_app_eks.cluster_version
  oidc_provider_arn = module.retail_app_eks.oidc_provider_arn

  enable_aws_load_balancer_controller = true
  aws_load_balancer_controller = {
    most_recent = true
    namespace   = "kube-system"
    wait        = true
    timeout     = 300

    set = [
      {
        name  = "clusterName"
        value = module.retail_app_eks.cluster_name
      },
      {
        name  = "vpcId"
        value = module.vpc.vpc_id
      },
      {
        name  = "region"
        value = var.aws_region
      }
    ]
  }

  depends_on = [module.retail_app_eks]
}

# Stage 2: All remaining addons — deployed only after LBC is fully healthy
module "eks_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.16"

  cluster_name      = module.retail_app_eks.cluster_name
  cluster_endpoint  = module.retail_app_eks.cluster_endpoint
  cluster_version   = module.retail_app_eks.cluster_version
  oidc_provider_arn = module.retail_app_eks.oidc_provider_arn

  # =============================================================================
  # CERT-MANAGER
  # =============================================================================
  enable_cert_manager = true
  cert_manager = {
    most_recent = true
    namespace   = "cert-manager"
    wait        = true
    timeout     = 300
  }

  # =============================================================================
  # NGINX INGRESS CONTROLLER
  # =============================================================================
  enable_ingress_nginx = true
  ingress_nginx = {
    most_recent = true
    namespace   = "ingress-nginx"
    wait        = true
    timeout     = 600

    set = [
      {
        name  = "controller.service.type"
        value = "LoadBalancer"
      },
      {
        name  = "controller.service.externalTrafficPolicy"
        value = "Local"
      },
      {
        name  = "controller.resources.requests.cpu"
        value = "100m"
      },
      {
        name  = "controller.resources.requests.memory"
        value = "128Mi"
      },
      {
        name  = "controller.resources.limits.cpu"
        value = "200m"
      },
      {
        name  = "controller.resources.limits.memory"
        value = "256Mi"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
        value = "external"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-nlb-target-type"
        value = "instance"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
        value = "internet-facing"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-healthcheck-path"
        value = "/healthz"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-healthcheck-port"
        value = "10254"
      },
      {
        name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-healthcheck-protocol"
        value = "HTTP"
      }
    ]
  }

  # =============================================================================
  # MONITORING STACK (PROMETHEUS + GRAFANA)
  # =============================================================================
  enable_kube_prometheus_stack = true
  kube_prometheus_stack = {
    namespace        = "monitoring"
    create_namespace = true
    wait             = true
    timeout          = 600

    set = [
      {
        name  = "grafana.enabled"
        value = "true"
      },
      {
        name  = "prometheus.enabled"
        value = "true"
      }
    ]
  }

  # Wait for LBC to be fully ready before deploying anything that creates Services
  depends_on = [module.eks_addons_lbc]
}