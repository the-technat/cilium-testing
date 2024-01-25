terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
provider "aws" {
  profile = "cilium-testing"
}
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["--profile=cilium-testing", "eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
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
      args = ["--profile=cilium-testing", "eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
    }
  }
}
locals {
  region = "eu-west-1"
  eks_version = "1.28"
  name = "cilium-testing"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr = "10.10.0.0/16"
  tags = {
    cluster    = local.name
    repo       = "github.com/the-technat/cilium-testing"
    managed-by = "terraform"
  }
}
data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_ami" "eks_default" { 
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
      most_recent = true
    }
  }
  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_service_ipv4_cidr      = "10.127.0.0/16"
  cluster_endpoint_public_access = true
  node_security_group_additional_rules = {
    ingress_self_all = { # cilium requires many ports to be open node-by-node
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
  cloudwatch_log_group_retention_in_days = 1
  attach_cluster_encryption_policy = false
  create_kms_key                   = false
  cluster_encryption_config        = {}
  manage_aws_auth_configmap = true
  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${local.name}"
      username = local.name
      groups   = ["system:masters"]
    },
  ]
  eks_managed_node_group_defaults = {
    # Compute
    capacity_type  = "SPOT"
    ami_type       = "AL2_x86_64"
    instance_types = ["t3a.medium", "t3.medium", "t2.medium"]
    ami_id         = data.aws_ami.eks_default.image_id
    desired_size   = 1
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    }
    enable_bootstrap_user_data = true
  }

  eks_managed_node_groups = {
    workers-a = {
      name       = "${local.name}-a"
      subnet_ids = [module.vpc.private_subnets[0]]
      labels = {
        "technat.dev/egress-node": "true"
      }
    }
    workers-b = {
      name       = "${local.name}-b"
      subnet_ids = [module.vpc.private_subnets[1]]
    }
    workers-c = {
      name       = "${local.name}-c"
      subnet_ids = [module.vpc.private_subnets[2]]
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
      aws --profile cilium-testing eks --region ${local.region} update-kubeconfig --name ${local.name} --alias ${local.name}
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
  repository = "https://helm.isovalent.com"
  # repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.14.x"
  namespace  = "kube-system"
  wait       = true
  timeout    = 3600
  values = [
    # templatefile("${path.module}/../../configs/cilium-on-eks.yaml", {
    templatefile("${path.module}/../../configs/cilium-ee-on-eks.yaml", {
      cluster_endpoint = trim(module.eks.cluster_endpoint, "https://") # used for kube-proxy replacement
      cluster_name = local.name
    })
  ]
  depends_on = [
    null_resource.purge_aws_networking,
  ]
}

### Egress gateway "external resource" to query 
module "ec2_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  name = "salami"
  ami = data.aws_ami.ubuntu.image_id
  create_spot_instance = true
  create_iam_instance_profile = true
  iam_role_policies = {
     AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  }
  instance_type          = "t2.micro"
  monitoring             = true
  vpc_security_group_ids = [module.eks.node_security_group_id]
  subnet_id              = module.vpc.private_subnets[0] # should be AZ1
  user_data = <<EOF
    #!/bin/bash
    sudo apt install nginx -y
  EOF
  tags = local.tags
}
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}