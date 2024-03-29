# Cilium Testing

I love cilium.

That repo contains some files and resources frequently used to test feastures around cilium. Expect it to be a chaos and unstructured, but that's the nature of tinkering, isn't it?

## Kind

Kind is awesome to test many feature of cilium in a generic way.

To create a new kind cluster I just do:

```
kind create cluster --config clusters/kind/kind.yaml
helm upgrade -i cilium --repo https://helm.cilium.io -n kube-system cilium/cilium -f configs/kind-default.yaml

# Ingress (optional)
helm upgrade -i metallb --repo https://metallb.github.io/metallb --create-namespace -n metallb metallb/metallb
docker network inspect -f '{{.IPAM.Config}}' kind # grab a subrange of that
cat <<EOF | kubectl apply -f-
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb
spec:
  addresses:
  - 172.18.0.100-172.18.0.200
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb
EOF
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

## EKS

EKS is a unicorn when it comes to Kubernetes Networking. That's why I usually test Cilium on EKS specifically.

To spin up a cluster, I use Terraform:

```
aws configure # use either assume-role or aws creds
cd clusters/eks
terraform init # uses local file backends
terraform apply -auto-approve
aws eks update-kubeconfig --name cilium-testing --alias cilium-testing
```

## Egress Gateway

To test the egress gateway feature do the following:

0. Spin up a cluster (either clusters/kind or clusters/eks-egress)
1. Spin up a service that produces access logs and is not behind a NAT
  - For kind this is as easy as:
    - `docker run --name echoserver -d --rm --network kind cilium/echoserver` 
    - `kubectl create svc externalname external-example-service -n default --external-name echoserver`
  - For EKS: spin up another EC2 instance in the private subnet, install docker and run the same container as above (or look at clusters/eks-egress/eks.tf at the bottom)
3. Deploy the `workload/egress-app.yaml`
4. Label one of your nodes with `technat.dev/egress-node=true` (or maybe they are already labeled)
5. Check the logs using `kubectl logs -n egress deploy/curl` and analyze the IPs seen 