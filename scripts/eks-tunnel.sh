#!/usr/bin/env bash
# Opens a Session Manager tunnel through the bastion to a cluster's private Kubernetes API, in the background,
# and writes a kubeconfig that uses it. Used by the ArgoCD install pipeline; works the same on a laptop.
#
#   scripts/eks-tunnel.sh <env> <region> [local-port]    # default port 8443
#
# Prints shell assignments for KUBECONFIG and TUNNEL_PID on stdout (eval them); progress goes to stderr.
# Stop the tunnel with: kill "$TUNNEL_PID"
set -euo pipefail

env="${1:?usage: eks-tunnel.sh <env> <region> [local-port]}"
region="${2:?usage: eks-tunnel.sh <env> <region> [local-port]}"
port="${3:-8443}"
cluster="${env}-${region}"
export AWS_REGION="$region"

param() { aws ssm get-parameter --name "/${env}/${region}/$1" --query Parameter.Value --output text; }

endpoint="$(param eks/cluster_endpoint)"
host="${endpoint#https://}"
bastion="$(param bastion/instance_id)"

status="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${bastion}" \
  --query 'InstanceInformationList[0].PingStatus' --output text)"
[[ "$status" == "Online" ]] || { echo "bastion ${bastion} is not Online in Session Manager (${status})" >&2; exit 1; }

log="$(mktemp)"
open_tunnel() {
  aws ssm start-session --target "$bastion" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=${host},portNumber=443,localPortNumber=${port}" >"$log" 2>&1 &
  pid=$!
  for _ in $(seq 1 30); do
    if grep -q "Waiting for connections" "$log"; then return 0; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  return 1
}

# The tunnel occasionally fails to open on the first try; retry once.
open_tunnel || { echo "tunnel did not open, retrying" >&2; sleep 5; open_tunnel; } || { cat "$log" >&2; exit 1; }
echo "tunnel: localhost:${port} -> ${host}:443 via ${bastion} (pid ${pid})" >&2

kubeconfig="$(mktemp)"
KUBECONFIG="$kubeconfig" aws eks update-kubeconfig --name "$cluster" --alias "$cluster" >/dev/null
KUBECONFIG="$kubeconfig" kubectl config set-cluster "$(KUBECONFIG="$kubeconfig" kubectl config view -o jsonpath='{.clusters[0].name}')" \
  --server "https://localhost:${port}" --tls-server-name "$host" >/dev/null

# The API answers through the tunnel before we hand it over.
for _ in $(seq 1 10); do
  if KUBECONFIG="$kubeconfig" kubectl --request-timeout=10s get --raw /readyz >/dev/null 2>&1; then
    printf 'export KUBECONFIG=%q\nTUNNEL_PID=%q\n' "$kubeconfig" "$pid"
    exit 0
  fi
  sleep 3
done
echo "Kubernetes API not reachable through the tunnel" >&2
cat "$log" >&2
kill "$pid" 2>/dev/null || true
exit 1
