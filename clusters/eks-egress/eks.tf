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
  region = local.region
}
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
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
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
    }
  }
}
locals {
  name        = "cilium-testing"
  region      = "eu-west-1"
  eks_version = "1.28"
  cidr        = "10.10.0.0/16"
  cilium_config = "egress-ee-eks.yaml"
  cilium_repo   = "https://helm.isovalent.com"
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
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
  source             = "terraform-aws-modules/vpc/aws"
  version            = "~> 5.0"
  name               = local.name
  cidr               = local.cidr
  azs                = local.azs
  public_subnets     = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k)]
  private_subnets    = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k + 10)]
  enable_nat_gateway = true
  single_nat_gateway = true
}
module "eks" {
  source           = "terraform-aws-modules/eks/aws"
  version          = "~> 19.0"
  cluster_name     = local.name
  cluster_version  = local.eks_version
  cluster_addons = { coredns = { most_recent = true } }
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
  attach_cluster_encryption_policy       = false # KMS only causes problems when destoryed regurarly
  create_kms_key                         = false # KMS only causes problems when destoryed regurarly
  cluster_encryption_config              = {} # KMS only causes problems when destoryed regurarly
  manage_aws_auth_configmap              = true
  aws_auth_users = [
    {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/technat"
      username = "technat"
      groups   = ["system:masters"]
    },
  ]
  eks_managed_node_group_defaults = {
    capacity_type  = "SPOT"
    ami_type       = "AL2_x86_64"
    instance_types = ["t3a.medium", "t3.medium", "t2.medium"]
    ami_id         = data.aws_ami.eks_default.image_id
    desired_size   = 1
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    }
    enable_bootstrap_user_data = true # required due to custom AMI (non-default EKS AMI)
    subnet_ids                 = module.vpc.private_subnets
  }
  eks_managed_node_groups = {
    workers = {
      name = "workers"
    }
    gateways = {
      name       = "gateways"
      desired_size = 2
      labels = {
        "technat.dev/egress-node" : "true"
      }
      taints = {
        egress-nodes = {
          key    = "technat.dev/egress-node"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }

  }
}
resource "null_resource" "purge_aws_networking" {
  triggers = {
    eks = module.eks.cluster_endpoint # only do this when the cluster changes (e.g create/recreate)
  }
  provisioner "local-exec" { # this is required as the manifests are there even if you don't deploy the addon
    command = <<EOT
      aws eks --region ${local.region} update-kubeconfig --name ${local.name} --alias ${local.name}
      curl -LO https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl
      chmod 0755 ./kubectl
      ./kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found 
      ./kubectl -n kube-system delete daemonset aws-node --ignore-not-found
      rm ./kubectl
    EOT
  }
  depends_on = [module.eks.aws_eks_cluster]
}
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = local.cilium_repo
  chart      = "cilium"
  version    = "1.14.6"
  namespace  = "kube-system"
  wait       = true
  timeout    = 3600
  values = [
    templatefile("${path.module}/../../configs/${local.cilium_config}", {
      cluster_endpoint = trim(module.eks.cluster_endpoint, "https://") # used for kube-proxy replacement
      cluster_name     = local.name # used for ENI tagging
    })
  ]
  depends_on = [
    null_resource.purge_aws_networking,
  ]
}
module "ec2_instance" { # EC2 instance with access logs to analyze
  source                      = "terraform-aws-modules/ec2-instance/aws"
  name                        = "salami"
  create_spot_instance        = true
  create_iam_instance_profile = true
  iam_role_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    AWSOpsWorksCloudWatchLogs = "arn:aws:iam::aws:policy/AWSOpsWorksCloudWatchLogs", # according to https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/EC2NewInstanceCWL.html this is enough
  }
  instance_type          = "t2.micro"
  monitoring             = true
  vpc_security_group_ids = [module.eks.node_security_group_id]
  subnet_id              = module.vpc.private_subnets[0] # should be AZ1
  user_data              = <<EOF
    #!/bin/bash
    sudo yum update -y
    sudo amazon-linux-extras install docker -y 
    sudo systemctl start --now docker
    sudo usermod -aG docker ssm-user
    docker run -d --name echoserver -p 80:80 cilium/echoserver
  EOF
}
resource "kubernetes_service_v1" "external_example_service" {
  metadata {
    name      = "external-example-service"
    namespace = "default"
  }
  spec {
    type          = "ExternalName"
    external_name = module.ec2_instance.private_dns
  }
  depends_on = [ module.eks, module.ec2_instance ]
}