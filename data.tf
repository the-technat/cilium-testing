# locals that hold data from datasources
locals {
  tags = {
    cluster    = local.name
    repo       = "github.com/the-technat/grapes"
    managed-by = "terraform"
  }
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  cidr = "10.123.0.0/16"
}

data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

# use pre-build images by AWS
data "aws_ami" "eks_default" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amazon-eks-node-${local.eks_version}-v*"]
  }
}

locals {
  region       = "eu-west-1"
  eks_version  = "1.28"
  worker_count = 1
  name         = "salami"
}