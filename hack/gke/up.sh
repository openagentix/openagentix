#!/usr/bin/env bash
# Make a NEW, throwaway Google Cloud project with one small GKE Standard cluster and the four quick start images, the way
# the first GKE run of issue 31 was done (docs/diary/guide/install-gke.md). Then run hack/gke/install.sh, and at the end
# hack/gke/down.sh, which deletes the whole project.
#
# It never uses an existing project: the project id is generated (<PROJECT_PREFIX>-<MMDD>-<4 hex>), it stops if that id
# exists, and every later call names the new project. It prints the teardown command before it creates anything.
# It prints no credential, no billing account and no organisation id.
#
# Required (it refuses to start without them):
#   PROJECT_PREFIX    3 to 20 lowercase letters, digits or hyphens, starting with a letter (for example oa-test)
#   ORG_ID            the numeric id of the organisation the project goes under
#   BILLING_ACCOUNT   the billing account to link (XXXXXX-XXXXXX-XXXXXX)
#   MAX_HOURS         1 to 24: the deadline written in the state file and the project label; install.sh refuses after it.
#                     Nothing deletes the project for you at the deadline. Run down.sh.
#   AUTHORIZED_CIDR   the only address range that may reach the cluster's control plane, for example <your IP>/32
# Optional (defaults are those of the first run):
#   REGION=us-central1 ZONE=us-central1-a CLUSTER=oa-gke MACHINE_TYPE=c3-standard-4 SPOT=1 DISK_GB=60 BUDGET_USD=10
#   IMAGE_TAG=gke1 CLUSTER_VERSION=(empty: the rapid channel default) STATE_ROOT=$HOME/.openagentix/gke
#
# Needs: gcloud (logged in, allowed to create projects in the organisation and to link the billing account), git, jq.
# A budget only sends alerts. It does not stop spending. Only down.sh stops it.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=hack/gke/lib.sh
. hack/gke/lib.sh

[ -z "${PROJECT:-}" ] || die "PROJECT is not an input. up.sh always makes a new project and never touches an existing one; unset PROJECT."
for v in PROJECT_PREFIX ORG_ID BILLING_ACCOUNT MAX_HOURS AUTHORIZED_CIDR; do
  [ -n "${!v:-}" ] || die "$v is required (see the header of hack/gke/up.sh). Nothing was changed."
done
[[ "$PROJECT_PREFIX" =~ ^[a-z][a-z0-9-]{1,18}[a-z0-9]$ ]] || die "PROJECT_PREFIX must be 3 to 20 lowercase letters, digits or hyphens, starting with a letter"
[[ "$ORG_ID" =~ ^[0-9]{6,20}$ ]] || die "ORG_ID must be the numeric organisation id"
[[ "$BILLING_ACCOUNT" =~ ^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$ ]] || die "BILLING_ACCOUNT must look like XXXXXX-XXXXXX-XXXXXX"
[[ "$MAX_HOURS" =~ ^[0-9]+$ ]] && [ "$MAX_HOURS" -ge 1 ] && [ "$MAX_HOURS" -le 24 ] || die "MAX_HOURS must be a whole number from 1 to 24"
[[ "$AUTHORIZED_CIDR" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || die "AUTHORIZED_CIDR must be an IPv4 range like 192.0.2.10/32"
for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do [ "$o" -le 255 ] || die "AUTHORIZED_CIDR $AUTHORIZED_CIDR is not an IPv4 address"; done
PFX=${BASH_REMATCH[5]}
[ "$PFX" -le 32 ] || die "AUTHORIZED_CIDR $AUTHORIZED_CIDR has a prefix over 32"
[ "$PFX" -ge 8 ] || die "AUTHORIZED_CIDR $AUTHORIZED_CIDR is too wide (/0 to /7 open the control plane to most of the internet); use your own address, for example <your IP>/32"

REGION=${REGION:-us-central1} ZONE=${ZONE:-us-central1-a} CLUSTER=${CLUSTER:-oa-gke}
MACHINE_TYPE=${MACHINE_TYPE:-c3-standard-4} SPOT=${SPOT:-1} DISK_GB=${DISK_GB:-60} BUDGET_USD=${BUDGET_USD:-10}
IMAGE_TAG=${IMAGE_TAG:-gke1} CLUSTER_VERSION=${CLUSTER_VERSION:-} STATE_ROOT=${STATE_ROOT:-$HOME/.openagentix/gke}
[[ "$REGION" =~ $RE_REGION ]] || die "REGION must look like us-central1"
[[ "$ZONE" =~ $RE_ZONE ]] || die "ZONE must look like us-central1-a"
[[ "$CLUSTER" =~ $RE_CLUSTER ]] || die "CLUSTER must be 2 to 40 lowercase letters, digits or hyphens, starting with a letter"
[[ "$STATE_ROOT" =~ $RE_PATH ]] || die "STATE_ROOT must be an absolute path of letters, digits and . _ / - (no spaces)"
[[ "$MACHINE_TYPE" =~ ^[a-z0-9-]+$ ]] || die "MACHINE_TYPE has characters a machine type cannot have"
[[ "$SPOT" =~ ^[01]$ ]] || die "SPOT must be 0 or 1"
[[ -z "$CLUSTER_VERSION" || "$CLUSTER_VERSION" =~ ^[0-9a-z.-]+$ ]] || die "CLUSTER_VERSION has characters a version cannot have"
[[ "$BUDGET_USD" =~ ^[0-9]+$ ]] || die "BUDGET_USD must be a whole number"
[[ "$DISK_GB" =~ ^[0-9]+$ ]] || die "DISK_GB must be a whole number"
[[ "$IMAGE_TAG" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "IMAGE_TAG has characters a tag cannot have"
GKE_IMAGES=${GKE_IMAGES:-cloudbuild}
case "$GKE_IMAGES" in cloudbuild|installer) ;; *) die "GKE_IMAGES must be cloudbuild (default: up.sh builds the four images with Cloud Build) or installer (hack/gke/install.sh builds and pushes them)";; esac
for c in gcloud git jq; do command -v "$c" >/dev/null || die "$c is not installed"; done

RAND=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')
PROJECT="$PROJECT_PREFIX-$(date -u +%m%d)-$RAND"
NOW=$(date -u +%s); DEADLINE=$(( NOW + MAX_HOURS * 3600 ))
DELETE_AFTER=$(date -u -d "@$DEADLINE" +%Y%m%dt%H%Mz 2>/dev/null || date -u -r "$DEADLINE" +%Y%m%dt%H%Mz)
STATE_DIR="$STATE_ROOT/$PROJECT"
REPO="$REGION-docker.pkg.dev/$PROJECT/oa"
KCFG="$STATE_DIR/kubeconfig" VALUES="$STATE_DIR/gke-images.yaml" STATE="$STATE_DIR/state.env"

if gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
  die "project $PROJECT already exists; up.sh never touches an existing project. Run it again for a new id. Nothing was changed."
fi
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
cat > "$STATE" <<EOF
# written by hack/gke/up.sh; read by hack/gke/install.sh and hack/gke/down.sh
PROJECT=$PROJECT
REGION=$REGION
ZONE=$ZONE
CLUSTER=$CLUSTER
REPO=$REPO
CREATED=$NOW
DEADLINE=$DEADLINE
EOF
echo "new project: $PROJECT (state: $STATE)"
teardown_line "$STATE" "$DEADLINE"
on_fail(){ echo "up.sh stopped. The project may exist and may cost money:" >&2; teardown_line "$STATE" "$DEADLINE" >&2; }
fail(){ trap - ERR; on_fail; die "$*"; }
trap 'on_fail' ERR
trap 'echo "interrupted" >&2; on_fail; kill "${CPID:-}" 2>/dev/null; exit 130' INT TERM HUP
GLOG="$STATE_DIR/gcloud.log"   # the calls that carry the organisation or billing id write their errors here, not to the terminal


step(){ echo "== $*"; }
step "project (under the organisation, labelled created-by=$GKE_LABEL, delete-after=$DELETE_AFTER)"
gcloud projects create "$PROJECT" --organization="$ORG_ID" --labels="created-by=$GKE_LABEL,delete-after=$DELETE_AFTER" --quiet >/dev/null 2>>"$GLOG" \
  || fail "project create failed (see $GLOG)"
step "billing link"
gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT" >/dev/null 2>>"$GLOG" || fail "billing link failed (see $GLOG)"
step "APIs"
gcloud services enable container.googleapis.com compute.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com billingbudgets.googleapis.com --project="$PROJECT" >/dev/null
step "budget alert: $BUDGET_USD USD (alerts only; it does not stop spending)"
# --billing-project: without it gcloud bills the budget API call to whatever quota project is configured, often another project
gcloud billing budgets create --billing-account="$BILLING_ACCOUNT" --display-name="$PROJECT" --budget-amount="${BUDGET_USD}USD" \
  --filter-projects="projects/$PROJECT" --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.0,basis=forecasted-spend --billing-project="$PROJECT" >/dev/null 2>>"$GLOG" || fail "budget create failed (see $GLOG)"
step "IAM: grants for the default compute service account (Cloud Build and the nodes use it in a new project)"
NUM=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
[[ "$NUM" =~ ^[0-9]+$ ]] || fail "could not read the project number"
SA="$NUM-compute@developer.gserviceaccount.com"
# storage.objectViewer: Cloud Build reads its source bucket (403 without it); artifactregistry.writer: push the images;
# logging.logWriter: build logs; container.defaultNodeServiceAccount: what GKE nodes need (also pulls from the repository)
for role in roles/storage.objectViewer roles/artifactregistry.writer roles/logging.logWriter roles/container.defaultNodeServiceAccount; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" --role="$role" --condition=None --quiet >/dev/null
done
step "Artifact Registry repository oa in $REGION"
gcloud artifacts repositories create oa --repository-format=docker --location="$REGION" --project="$PROJECT" --quiet >/dev/null

step "cluster create in the background (log: $STATE_DIR/cluster-create.log)"
SPOT_FLAG=(); [ "$SPOT" = 1 ] && SPOT_FLAG=(--spot)
VER_FLAG=(); [ -n "$CLUSTER_VERSION" ] && VER_FLAG=(--cluster-version="$CLUSTER_VERSION")
( KUBECONFIG="$KCFG" gcloud container clusters create "$CLUSTER" --project="$PROJECT" --zone="$ZONE" --release-channel=rapid ${VER_FLAG[@]+"${VER_FLAG[@]}"} \
    --machine-type="$MACHINE_TYPE" --num-nodes=1 ${SPOT_FLAG[@]+"${SPOT_FLAG[@]}"} --image-type=COS_CONTAINERD --enable-dataplane-v2 \
    --disk-type=pd-balanced --disk-size="$DISK_GB" --enable-master-authorized-networks --master-authorized-networks="$AUTHORIZED_CIDR" \
    --no-enable-managed-prometheus --labels="created-by=$GKE_LABEL" --quiet > "$STATE_DIR/cluster-create.log" 2>&1 ) &
CPID=$!

if [ "$GKE_IMAGES" = cloudbuild ]; then
  step "Cloud Build: four images for linux/amd64, pushed to $REPO with tag $IMAGE_TAG (log: $STATE_DIR/build.log)"
  # Only the committed files the four images need travel (git archive of HEAD): no local .env, no uncommitted change.
  git archive --format=tar.gz -o "$STATE_DIR/source.tgz" HEAD -- services/a2a-gate services/stub-model services/control-plane services/console console .dockerignore
  B0=$(date +%s)
  if ! gcloud builds submit "$STATE_DIR/source.tgz" --project="$PROJECT" --config=hack/gke/cloudbuild.yaml \
        --substitutions="_REPO=$REPO,_TAG=$IMAGE_TAG" > "$STATE_DIR/build.log" 2>&1; then
    wait "$CPID" || true
    fail "Cloud Build failed (see $STATE_DIR/build.log)"
  fi
  echo "   images built and pushed in $(( $(date +%s) - B0 )) s"
  rm -f "$STATE_DIR/source.tgz"
else
  echo "== no Cloud Build (GKE_IMAGES=installer): hack/gke/install.sh builds and pushes the images with IMAGE_REGISTRY=$REPO"
fi

step "waiting for the cluster"
if ! wait "$CPID"; then fail "cluster create failed (see $STATE_DIR/cluster-create.log)"; fi
echo "   cluster ready $(( $(date +%s) - NOW )) s after the start"
KUBECONFIG="$KCFG" gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" --project="$PROJECT" >/dev/null 2>&1
chmod 600 "$KCFG" 2>/dev/null || true

cat > "$VALUES" <<EOF
# written by hack/gke/up.sh: the four images from Artifact Registry instead of local builds
governance:
  a2a:
    image: {repository: $REPO/a2a-gate, tag: "$IMAGE_TAG"}
gateway:
  stubModel:
    image: {repository: $REPO/stub-model, tag: "$IMAGE_TAG"}
controlPlane:
  image: {repository: $REPO/control-plane, tag: "$IMAGE_TAG"}
console:
  image: {repository: $REPO/console, tag: "$IMAGE_TAG"}
EOF
trap - ERR
echo
echo "next: hack/gke/install.sh $STATE"
teardown_line "$STATE" "$DEADLINE"
