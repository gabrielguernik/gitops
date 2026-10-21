#!/usr/bin/env bash
# Checks that every AWS resource a cluster folder hardcodes still exists, so a stale value fails a PR instead of
# a sync. The folder references resources by stable names (VPC tag, security group name, fixed IRSA role names,
# secret names, RDS instance ARN, ingress hosts, log group) rather than generated IDs; this verifies those names resolve.
# The one generated ID it hardcodes, the AMP workspace, is checked to exist, to be the same everywhere, and to
# carry the cluster's alias.
#
#   scripts/check-cluster-config.sh <cluster>     # e.g. sandbox-us-east-1; region = the cluster name minus <env>-
#
# Needs read-only AWS access (CI: role ci/gitops-check).
set -euo pipefail

cluster="${1:?usage: check-cluster-config.sh <cluster>}"
dir="clusters/${cluster}"
[[ -d "$dir" ]] || { echo "no folder $dir" >&2; exit 1; }
export AWS_REGION="${cluster#*-}"

failures=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else fail "$what"; fi; }

# All Application specs and app config values in the folder, as one YAML stream.
docs() { for f in "$dir"/platform/*.yaml "$dir"/apps/config/*.yaml; do echo "---"; cat "$f"; echo; done; }

echo "IRSA roles"
for arn in $(docs | grep -oE 'arn:aws:iam::[0-9]+:role/[A-Za-z0-9/_+=,.@-]+' | sort -u); do
  check "$arn" aws iam get-role --role-name "${arn##*/}"
done

echo "VPCs (by tag)"
for name in $(docs | yq -N '.spec.source.helm.valuesObject.vpcTags.Name // ""' | grep -v '^$' | sort -u); do
  check "vpc Name=$name" test "$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$name" --query 'length(Vpcs)')" = 1
done

echo "Security groups (by name)"
for name in $(docs | yq -N '.values.ingress.securityGroup // ""' | grep -v '^$' | sort -u); do
  check "sg $name" test "$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$name" --query 'length(SecurityGroups)')" = 1
done

echo "Secrets (by name)"
for name in $(docs | yq -N '((.values.secrets // {} | (.app, .db, .migrator)), (.spec.source.helm.valuesObject.roleSecrets // {} | (.app, .migrator)), .spec.source.helm.valuesObject.grafanaSecret) | select(. != null)' | sort -u); do
  check "secret $name" aws secretsmanager describe-secret --secret-id "$name"
done

echo "RDS instances and their managed master secret (by tag)"
for arn in $(docs | yq -N '.spec.source.helm.valuesObject.dbInstanceArn // ""' | grep -v '^$' | sort -u); do
  check "rds ${arn##*:}" aws rds describe-db-instances --db-instance-identifier "${arn##*:}"
  check "master secret tagged $arn" test "$(aws secretsmanager list-secrets \
    --filters "Key=tag-key,Values=aws:rds:primaryDBInstanceArn" "Key=tag-value,Values=$arn" --query 'length(SecretList)')" = 1
done

echo "ACM certificates for ingress hosts"
for host in $(docs | yq -N '.values.ingress.host // ""' | grep -v '^$' | sort -u); do
  wildcard="*.${host#*.}"
  check "certificate for $host" test -n "$(aws acm list-certificates --certificate-statuses ISSUED \
    --query "CertificateSummaryList[?DomainName=='${host}' || DomainName=='${wildcard}' || contains(SubjectAlternativeNameSummaries, '${wildcard}')].CertificateArn" --output text)"
done

echo "Amazon Managed Prometheus workspace (hardcoded ID)"
workspaces=$(docs | grep -oE 'workspaces/ws-[0-9a-f-]+' | sed 's#workspaces/##' | sort -u || true)
case "$(printf '%s' "$workspaces" | grep -c .)" in
  0) ;;
  1) check "workspace $workspaces has alias $cluster" \
       test "$(aws amp describe-workspace --workspace-id "$workspaces" --query workspace.alias --output text)" = "$cluster" ;;
  *) fail "files reference different workspaces: $(echo $workspaces)" ;;
esac

echo "Log groups"
for lg in $(docs | grep -oE '/eks/[A-Za-z0-9_.-]+/containers' | sort -u); do
  check "log group $lg" test "$(aws logs describe-log-groups --log-group-name-prefix "$lg" \
    --query "length(logGroups[?logGroupName=='$lg'])")" = 1
done

echo "Alloy's ALB filter matches the apps' namespaces (ingress.k8s.aws/stack = <namespace>/<ingress>)"
for stack in $(grep -ohE '"ingress.k8s.aws/stack" = "[^"]+"' "$dir"/platform/*.yaml | sed -E 's/.*= "([^"]+)"/\1/' | sort -u); do
  check "stack $stack" grep -qx "namespace: ${stack%%/*}" "$dir"/apps/config/*.yaml
done

if (( failures > 0 )); then echo "$failures reference(s) don't resolve in AWS"; exit 1; fi
echo "all references resolve"
