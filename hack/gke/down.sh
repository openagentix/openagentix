#!/usr/bin/env bash
# Delete the whole project that hack/gke/up.sh made, check that Google Cloud accepted the deletion, and remove the
# separate kubeconfig of the run:
#   hack/gke/down.sh <state file>
# Deleting the project removes the cluster, the node, its disks, any load balancer, the images and the IAM grants at once,
# and disables billing for it. It deletes only a project with the label created-by=openagentix-gke-up.
# The budget alert stays on the billing account; delete it once the billing report shows no new charge for the project.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=hack/gke/lib.sh
. hack/gke/lib.sh
[ $# -eq 1 ] || die "usage: hack/gke/down.sh <state file written by hack/gke/up.sh>"
read_state "$1"
STATE=$STATE_DIR/$(basename "$1")
command -v gcloud >/dev/null || die "gcloud is not installed"

LIFE=$(gcloud projects describe "$PROJECT" --format='value(lifecycleState)' 2>/dev/null || true)
if [ "$LIFE" = DELETE_REQUESTED ]; then
  echo "project $PROJECT is already DELETE_REQUESTED; nothing to delete"
else
  [ -n "$LIFE" ] || die "cannot read project $PROJECT (deleted long ago, no access, or a passing error: retry). Nothing was deleted; check it in the console, it may still cost money."
  project_is_ours || die "project $PROJECT does not carry created-by=$GKE_LABEL; down.sh deletes only projects up.sh made. Nothing was deleted."
  T0=$(date +%s)
  gcloud projects delete "$PROJECT" --quiet
  LIFE=$(gcloud projects describe "$PROJECT" --format='value(lifecycleState)' 2>/dev/null || true)
  [ "$LIFE" = DELETE_REQUESTED ] || die "project $PROJECT is '$LIFE', not DELETE_REQUESTED. Check it in the console."
  echo "project $PROJECT: DELETE_REQUESTED after $(( $(date +%s) - T0 )) s (billing is disabled; Google keeps it recoverable for about 30 days)"
  CREATED_S=${CREATED:-0}
  [ "$CREATED_S" -gt 0 ] && echo "lifetime of the run: about $(( ($(date +%s) - CREATED_S) / 60 )) min from up.sh to the delete"
fi
rm -f "$KUBECONFIG_FILE" "$STATE_DIR/source.tgz"
grep -q '^DELETED_AT=' "$STATE" || echo "DELETED_AT=$(date -u +%s)" >> "$STATE"
echo "removed the separate kubeconfig ($KUBECONFIG_FILE). If you merged it into another kubeconfig, remove the context gke_${PROJECT}_${ZONE}_${CLUSTER} there."
echo "budget: delete it after the billing report shows no new charge: gcloud billing budgets list --billing-account=<billing account> --filter=displayName=$PROJECT"
