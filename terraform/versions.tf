# =============================================================================
# TERRAFORM AND PROVIDER VERSIONS
# =============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# =============================================================================
<<<<<<< HEAD
# DATA SOURCES FOR EKS AUTHENTICATION
# =============================================================================

data "aws_eks_cluster" "cluster" {
  name = module.retail_app_eks.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.retail_app_eks.cluster_name
}

# =============================================================================
=======
>>>>>>> c0f37e18f096d97fa4e901b628548f32e78cde61
# PROVIDER CONFIGURATIONS
# =============================================================================

provider "aws" {
  region = var.aws_region
}

<<<<<<< HEAD
# Helm Provider configured using dynamic cluster authentication data
provider "helm" {
  kubernetes= {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Kubectl Provider configured using dynamic cluster authentication data
provider "kubectl" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  load_config_file       = false
}
=======
provider "helm" {
  kubernetes {
    host                   = module.retail_app_eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.retail_app_eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.retail_app_eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.retail_app_eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.retail_app_eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.retail_app_eks.cluster_name]
  }
}
>>>>>>> c0f37e18f096d97fa4e901b628548f32e78cde61
