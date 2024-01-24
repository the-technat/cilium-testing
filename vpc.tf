# https://github.com/terraform-aws-modules/terraform-aws-eks/blob/master/examples/complete/main.tf#L411-L435
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

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
