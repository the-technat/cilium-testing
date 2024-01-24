resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.14.6"
  namespace  = "kube-system"
  wait       = false
  timeout    = 3600

  values = [
    templatefile("${path.module}/cilium.yaml", {
      cluster_endpoint = trim(module.eks.cluster_endpoint, "https://") # would be used for kube-proxy replacement
    })
  ]

  depends_on = [
    module.eks.aws_eks_cluster,
    null_resource.purge_aws_node,
    null_resource.purge_kube_proxy,
  ]
}

resource "null_resource" "purge_kube_proxy" {
  triggers = {
    eks = module.eks.cluster_endpoint # only do this when the cluster changes (e.g create/recreate)
  }

  provisioner "local-exec" {
    command = <<EOT
      aws eks --region ${local.region} update-kubeconfig --name ${local.name} --alias ${local.name}
      kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found 
    EOT
  }

  depends_on = [module.eks.aws_eks_addon]
}


resource "null_resource" "purge_aws_node" {
  triggers = {
    eks = module.eks.cluster_endpoint # only do this when the cluster changes (e.g create/recreate)
  }

  provisioner "local-exec" {
    command = <<EOT
      aws eks --region ${local.region} update-kubeconfig --name ${local.name} --alias ${local.name}
      kubectl -n kube-system delete daemonset aws-node --ignore-not-found
    EOT
  }
}