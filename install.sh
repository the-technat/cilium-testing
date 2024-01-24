kind create cluster --config cluster-config.yaml

# Cilium
helm repo add cilium https://helm.cilium.io
helm upgrade -i cilium -n kube-system cilium/cilium -f cilium.yaml

# MetalLB
helm repo add metallb https://metallb.github.io/metallb
helm upgrade -i metallb --create-namespace -n metallb metallb/metallb

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

# Ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace

# goldpinger
kubectl apply -f goldpinger.yaml