# gitops

Desired state of every Kubernetes cluster, reconciled by ArgoCD, and the pipeline that installs ArgoCD itself.

Infrastructure (VPC, EKS, RDS, IAM roles, ...) lives in [infra](https://github.com/gabrielguernik/infra); the
application and its Helm chart live in [realworld-app](https://github.com/gabrielguernik/realworld-app).

The layout is built for **managing long-lived environments**: each cluster's configuration is explicit and
self-contained in its own folder, so changes and upgrades go one environment at a time, and a diff shows exactly
what changes where. Creating a new environment means copying a folder and adjusting it; that is deliberately
less automated, because environments change far more often than new ones are created.

## Layout

```
.github/workflows/
  argocd.yml                 # installs/upgrades ArgoCD: one job per cluster
  _install-argocd.yml        # reusable job: tunnel → repo credentials → helm upgrade → root Applications
  checks.yml                 # PRs and main: lint + "do the AWS resources this folder references exist?"
charts/
  db-bootstrap/              # platform-owned charts, each released as git tags <chart>-v<version>
  monitoring-config/         #   secrets plumbing of the monitoring namespace (Grafana admin)
  grafana-dashboards/        #   dashboards/<Folder>/<name>.json → ConfigMaps for Grafana's sidecar
clusters/
  sandbox-us-east-1/         # one folder per cluster; cluster = environment (+ region)
    argocd/
      values.yaml            # ArgoCD Helm values (input of the pipeline)
      roots.yaml             # the two root Applications: platform and apps
    platform/                # one hand-written Application per platform component
      _projects.yaml         # AppProjects "platform" and "apps"
      cert-manager.yaml      # webhook certificates (the Load Balancer Controller's)
      external-secrets.yaml
      aws-load-balancer-controller.yaml
      external-dns.yaml
      reloader.yaml
      db-bootstrap.yaml
      monitoring-config.yaml # observability: secrets for Grafana
      alloy.yaml             #   scrapes annotated pods + the API's ALB metrics → Amazon Managed Prometheus
      grafana.yaml           #   dashboards over AMP, CloudWatch and CloudWatch Logs (private)
      fluent-bit.yaml        #   container logs → CloudWatch Logs
      grafana-dashboards.yaml
    apps/
      applicationset.yaml    # app-of-apps: one Application per file in config/
      config/
        realworld.yaml       # repo, chart path, revision, namespace, values
scripts/
  eks-tunnel.sh              # tunnel to a cluster's private API through the bastion, plus a kubeconfig
  check-cluster-config.sh    # verifies every hardcoded AWS reference of a cluster folder
  diff-clusters.sh           # compares two clusters' folders, names normalized
```

## How it fits together

```
infra (Terraform)          gitops pipeline (GitHub Actions)        ArgoCD (in the cluster)
─────────────────          ─────────────────────────────────       ───────────────────────
EKS, RDS, IAM roles   ──▶  helm upgrade argocd                ──▶  root "platform" → clusters/<c>/platform/*.yaml
(fixed names)              kubectl apply roots.yaml                root "apps"     → ApplicationSet → config/*.yaml
                           (through the bastion tunnel)                                   │
                                                                   realworld-app CI ──────┘ bumps revision
```

1. **ArgoCD is installed by a pipeline, not by Terraform and not by itself.** `argocd.yml` has one job per cluster.
   Each job assumes the role `ci/argocd-<cluster>` (GitHub OIDC; the job runs in a GitHub environment named after
   the cluster, and that role trusts only this environment), opens a Session Manager tunnel through the bastion to
   the private Kubernetes API, writes the repository credentials from Secrets Manager, runs `helm upgrade --install`,
   and applies `roots.yaml`. It runs when a cluster's `argocd/` folder changes, weekly (to undo manual changes:
   ArgoCD doesn't manage its own release), and on demand.
2. **The `platform` root** syncs `clusters/<cluster>/platform/`. Every component is an explicit Application with
   its chart version and its configuration written out in the file. Sync waves order them: projects (-10), cert-manager
   (-6), then the controllers (-5), observability (`monitoring-config` -3; Alloy, Grafana, Fluent Bit -2), then dashboards and `db-bootstrap`
   together (-1). ArgoCD's values add the Application health check so each wave waits
   for the previous one to be healthy.
3. **The `apps` root** syncs only `apps/applicationset.yaml`. The ApplicationSet's git files generator turns each
   `apps/config/<app>.yaml` into an Application named `<app>`, in the AppProject `apps`.

## Configuration is hardcoded, by stable name

Platform Applications contain their configuration directly, with no templating. AWS resources are referenced by
names that survive rebuilding the infrastructure, never by generated IDs:

| Needed by | Reference |
|---|---|
| Load Balancer Controller | VPC by tag `Name=sandbox-us-east-1-vpc` (not the VPC ID) |
| Controllers, ExternalSecrets | IRSA roles with fixed names: `arn:aws:iam::<account>:role/irsa/<cluster>-<component>` |
| Ingress | ALB security group by name, `sandbox-us-east-1-alb`; the ACM certificate is discovered from the host |
| ExternalDNS | Zone by domain, `sandbox.gg-incode.click` |
| SecretStores | Secrets by name, `sandbox/realworld/{app,db-app,db-migrator}`; the DB secrets include host, port and database |
| db-bootstrap | RDS instance ARN (deterministic); its RDS-managed master secret is found by its `aws:rds:primaryDBInstanceArn` tag |
| Fluent Bit | Log group by name, `/eks/sandbox-us-east-1/containers` |
| Alloy | The API's ALB by the tags the load balancer controller sets (`ingress.k8s.aws/stack`), not by its ARN |
| Alloy, Grafana | **The AMP workspace ID** (`ws-…`): the one generated ID. It changes when the infra `monitoring` stack is recreated; then update it in both files (`aws ssm get-parameter --name /<env>/<region>/monitoring/amp_workspace_id`) |

`scripts/check-cluster-config.sh <cluster>` resolves these in AWS: roles, VPC, security groups, secrets, the RDS
instance and its master secret, certificates for the ingress hosts, the workspace (it exists, it's the same ID in every
file, and its alias is the cluster name) and the log group. It also checks that Alloy's ALB filter names the app's
namespace. It doesn't check the ExternalDNS zone, the access-log bucket, or that each role trusts the right
ServiceAccount. CI runs it on every PR and on
`main` with the read-only role `ci/gitops-check`, so a reference that no longer exists fails a PR instead of a sync.

## Applications and how to deploy

`clusters/<cluster>/apps/config/<app>.yaml`:

| Key | Meaning |
|---|---|
| `repoURL` | Git repo with the app's Helm chart |
| `chartPath` | Chart path in that repo |
| `revision` | Git revision of the chart; also passed to the chart as `.Values.revision` (the image tag) |
| `namespace` | Destination namespace; ArgoCD creates it with Pod Security Standard `restricted` and ALB readiness gates |
| `values` | Helm values for this cluster |

**Deploying `realworld`:** realworld-app CI sets `revision` to the merged commit after publishing its images, and
pushes here. Rollback: revert that commit. The `realworld` chart runs migrations (as `realworld_migrator`) before
rolling the pods (as `realworld_app`).

**Adding an app:** add a config file. Its repo must be in the `apps` project's `sourceRepos` and its namespace in
the project's `destinations`, and ArgoCD needs a
read deploy key for it (Secrets Manager `<env>/argocd/repo-<name>`, written by the pipeline: add the name to the
loop in `_install-argocd.yml`). **Removing an app:** delete the file; ArgoCD deletes the Application and its resources.

**What the `apps` project allows:** source `realworld-app` only; destination namespace `realworld` only (an
allowlist, so a platform namespace added later is never reachable); no cluster-scoped resources except Namespaces.
An app can't install CRDs, cluster roles or webhooks.

## Database roles (`db-bootstrap`)

Workloads never use the RDS master user. `charts/db-bootstrap` runs as a Job in namespace `db-admin`, as the master
user, on every sync of its Application (idempotent):

| Role | Used by | Privileges |
|---|---|---|
| `realworld_migrator` | migration Job | Owns database `realworld` (so it can create in schema `public`) and every table |
| `realworld_app` | API pods | `CONNECT`; `SELECT, INSERT, UPDATE, DELETE` on all tables and sequences, including future ones; no DDL; 20 connections max |

`CONNECT` is revoked from `PUBLIC`. The passwords are generated by the infra `data` stack and stored in Secrets
Manager. The master secret is only readable from `db-admin` (its IRSA role); the app namespace's role can't read it.

The chart is shared by clusters and pinned per cluster by git tag. To change it: bump `version` in `Chart.yaml`, tag
`db-bootstrap-v<version>`, then update `targetRevision` in each cluster's `platform/db-bootstrap.yaml`, one cluster
at a time.

## Common tasks

**Upgrade a platform component in one cluster:** change `targetRevision` (and values if needed) in
`clusters/<cluster>/platform/<component>.yaml`. For the Load Balancer Controller, also update the vendored IAM
policy in `infra/modules/platform/policies/` to the same release. Promote to the next cluster by copying the change;
`scripts/diff-clusters.sh <from> <to>` shows what still differs.

**Upgrade ArgoCD:** change `argocd_chart_version` in the cluster's job in `argocd.yml` (and `argocd/values.yaml` if
needed). The pipeline runs on merge.

**Add a cluster:**
1. infra: apply the environment stacks for it, add it to `argocd_clusters` in `bootstrap`, and add
   `ci/argocd-<cluster>` to the cluster's admin access entries in its `eks` stack.
2. Store its ArgoCD read deploy keys in Secrets Manager (`<env>/argocd/repo-<repo>`).
3. Create a GitHub environment named after the cluster (deployment branches: `main`; reviewers for prod).
4. Copy a cluster folder, rename, and adjust names, versions and values; add it to the `references` matrix in
   `checks.yml`; `scripts/check-cluster-config.sh <cluster>` must pass.
5. Add a job to `argocd.yml`.

**Change a dashboard:** edit a copy in Grafana, export it (Share → Export, keeping the data source UIDs `amp` and
`cloudwatch`), save it as `charts/grafana-dashboards/dashboards/<Folder>/<name>.json`, bump the chart `version`, tag
`grafana-dashboards-v<version>`, then update `targetRevision` in each cluster's `platform/grafana-dashboards.yaml`. Use
`__CLUSTER__` where the JSON names the cluster (log group, RDS instance, Valkey nodes); the chart fills it in.

**Make an app's metrics collected:** annotate its pods with `prometheus.io/scrape: "true"`, `prometheus.io/port` and
`prometheus.io/path`. Alloy scrapes them into the cluster's AMP workspace.

**Open Grafana** (private, like ArgoCD; the 3am runbook is in the infra README, "Observability"):

```bash
eval "$(scripts/eks-tunnel.sh sandbox us-east-1)"
kubectl -n monitoring port-forward svc/grafana 3000:80 &
aws secretsmanager get-secret-value --secret-id sandbox/monitoring/grafana --query SecretString --output text | jq -r '."admin-password"'
open http://localhost:3000                              # user admin
```

**Open the ArgoCD UI** (the API is private; see the infra README for the tunnel prerequisites):

```bash
eval "$(scripts/eks-tunnel.sh sandbox us-east-1)"      # tunnel + KUBECONFIG
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
aws secretsmanager get-secret-value --secret-id sandbox/argocd/sandbox-us-east-1/admin --query SecretString --output text; echo
open https://localhost:8080                             # user admin
kill "$TUNNEL_PID"                                      # when done
```

## Removing an environment

Controllers create AWS resources that Terraform doesn't know about (the ALB, its target groups, DNS records). Remove
the apps first so the controllers delete them, then destroy the infrastructure (infra README, "Destroy order"):

```bash
eval "$(scripts/eks-tunnel.sh sandbox us-east-1)"
kubectl -n argocd delete application apps          # the root first (no finalizer), or it would recreate the ApplicationSet
kubectl -n argocd delete applicationset apps        # its Applications go, and their finalizers delete Ingress → ALB, DNS records
kubectl -n argocd wait --for=delete application/realworld --timeout=5m   # one per app in apps/config/
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName, 'k8s-')].LoadBalancerName"  # must be []
kill "$TUNNEL_PID"
```

## Trade-offs and prod upgrades

- **The ArgoCD install depends on the bastion tunnel.** Prod: a self-hosted runner inside the VPC (Actions Runner
  Controller or CodeBuild), which takes the bastion out of CI.
- **Deploy keys are long-lived.** Prod: a GitHub App with short-lived tokens for ArgoCD and for CI.
- **The sandbox deploys by pushing to `main`.** Prod: CI opens a PR against the prod cluster's config file, and the
  environment's reviewers approve it.
- **Per-cluster files are duplicated.** Intentional, so upgrades go one environment at a time;
  `diff-clusters.sh` shows the differences between environments.
- **One repo for every cluster.** Prod may move prod clusters to a repo with stricter branch protection.
- **Grafana runs in the cluster it watches,** and dashboards are managed as exported JSON. Prod: Grafana in a separate
  management cluster, and a friendlier dashboard workflow (Grafana Operator, or dashboards as code). See the infra
  README, "Observability" → "Production".
