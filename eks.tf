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
    desired_size   = local.worker_count

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
      name       = "${local.name}-a"
      subnet_ids = [module.vpc.private_subnets[0]]
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