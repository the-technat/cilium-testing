terraform {
  backend "s3" {} # github actions will configure the rest
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.31.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.24.0"
    }
  }
}

provider "aws" {}
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
  }
}
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
    }
  }
}

locals {
  region = "eu-west-1"
  eks_version = "1.28"
  name = "cilium-testing"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr = "10.123.0.0/16"
  tags = {
    cluster    = local.name
    repo       = "github.com/the-technat/grapes"
    managed-by = "terraform"
  }
}
data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_ami" "eks_default" { 
# use pre-build images by AWS
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amazon-eks-node-${local.eks_version}-v*"]
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.4.0"

  name = local.name
  cidr = local.cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k + 10)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # https://kubernetes-sigs.github.io/aws-load-balancer-controller/v2.6/deploy/subnet_discovery/
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"
  cluster_name     = local.name
  cluster_version  = local.eks_version
  prefix_separator = "" # prevents recreation of the cluster because IAM roles and SGs would otherwise be renamed which triggers a cluster recreation
  cluster_addons = {
    coredns = {
      addon_version = "v1.9.3-eksbuild.10"
    }
  }
  # Networking
  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_service_ipv4_cidr      = "10.127.0.0/16"
  cluster_endpoint_public_access = true
  # KMS
  attach_cluster_encryption_policy = false
  create_kms_key                   = false
  cluster_encryption_config        = {}
  # IAM
  manage_aws_auth_configmap = true
  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${local.name}"
      username = local.name
      groups   = ["system:masters"]
    },
  ]
  // settings in this block apply to all nodes groups
  eks_managed_node_group_defaults = {
    # Compute
    capacity_type  = "SPOT"
    ami_type       = "AL2_x86_64"
    instance_types = ["t3a.medium", "t3.medium", "t2.medium"]
    ami_id         = data.aws_ami.eks_default.image_id
    desired_size   = loal.worker_count

    # IAM
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    }

    // required since we specify the AMI to use
    // otherwise the nodes don't join
    // setting also assume the default eks image is used
    enable_bootstrap_user_data = true

  }

  eks_managed_node_groups = {
    workers-a = {
      name       = "${local.name}-cilium-a"
      subnet_ids = [module.vpc.private_subnets[0]]
    }
    workers-b = {
      name       = "${local.name}-cilium-b"
      subnet_ids = [module.vpc.private_subnets[1]]
    }
  }
  tags = local.tags
}

resource "null_resource" "purge_aws_networking" {
  triggers = {
    eks = module.eks.cluster_endpoint # only do this when the cluster changes (e.g create/recreate)
  }
  provisioner "local-exec" {
    command = <<EOT
      aws eks --region ${local.region} update-kubeconfig --name ${local.name}
      curl -LO https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl
      chmod 0755 ./kubectl
      ./kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found 
      ./kubectl -n kube-system delete daemonset aws-node --ignore-not-found
      rm ./kubectl
    EOT
  }
  # Note: we don't deploy the addons using TF, but the resources are still there on cluster creation
  # That's why it's enough to delete them once as soon as the control-plane is ready
  depends_on = [ module.eks.aws_eks_cluster, ] 
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.14.6"
  namespace  = "kube-system"
  wait       = false
  timeout    = 3600

  values = [
    <<EOT
        hubble:
          relay: 
            enabled: true
        eni:
          enabled: true
        ipam:
          mode: eni
        tunnel: disabled
        enableIPv4Masquerade: false
        kubeProxyReplacement: strict
        k8sServicePort: 6443  
    EOT
  ]
  
  set {
    name  = "k8sServiceHost"
    value = trim(module.eks.cluster_endpoint, "https://")
    type  = "string"
  }
 

  depends_on = [
    null_resource.purge_aws_networking,
  ]
}

