#!/usr/bin/env bash
# Shows how two clusters' platform and app configuration differ, with each cluster's own name, account and domain
# normalized away, so what remains are real differences (versions, sizing, settings). Review before promoting.
#
#   scripts/diff-clusters.sh <from-cluster> <to-cluster>    # e.g. sandbox-us-east-1 prod-us-east-1
set -euo pipefail
from="${1:?usage: diff-clusters.sh <from> <to>}"
to="${2:?usage: diff-clusters.sh <from> <to>}"
normalize() {
  local cluster="$1" env="${1%%-*}"
  sed -e "s/${cluster}/<cluster>/g" -e "s/\b${env}\b/<env>/g" -e "s/arn:aws:\([a-z-]*\):\([a-z0-9-]*\):[0-9]\{12\}:/arn:aws:\1:\2:<account>:/g" \
      -e "s/[0-9]\{12\}\.dkr/<account>.dkr/g" -e "s/logs-[0-9]\{12\}-/logs-<account>-/g"
}
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
for c in "$from" "$to"; do
  mkdir -p "$tmp/$c"
  (cd "clusters/$c" && find . -name '*.yaml' | while read -r f; do
     mkdir -p "$tmp/$c/$(dirname "$f")"; normalize "$c" < "$f" > "$tmp/$c/$f"; done)
done
cd "$tmp" && diff -ru "$from" "$to" || true
