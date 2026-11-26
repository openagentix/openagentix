#!/usr/bin/env bash
# Offline tests of hack/gke/up.sh, install.sh and down.sh with a fake `gcloud` and `kubectl` (no cloud call, no cluster).
# They check what each script refuses, the order (teardown printed before anything is created), the exact gcloud calls,
# the files written, and that no billing account or organisation id is printed.
set -u
cd "$(dirname "$0")/../../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
# gcloud: every call is recorded in calls and echoed as "FAKE gcloud ..." on stderr, so the output shows the order.
# `projects describe` fails until `projects create` ran (FAKE_EXISTS=1: it exists from the start); it then answers the
# number, the label and the state that the --format asks for. FAKE_LABEL overrides the label, FAKE_CLUSTER_FAIL=1 fails the create.
cat > "$D/bin/gcloud" <<EOS
#!/usr/bin/env bash
echo "gcloud \$*" >> "$D/calls"
echo "FAKE gcloud \$1 \$2" >&2
case "\$*" in
  "projects describe "*)
    [ -f "$D/created" ] || [ "\${FAKE_EXISTS:-0}" = 1 ] || exit 1
    case "\$*" in
      *projectNumber*) echo 123456789012;;
      *labels.created-by*) echo "\${FAKE_LABEL-openagentix-gke-up}";;
      *lifecycleState*) if [ -f "$D/deleted" ]; then echo DELETE_REQUESTED; else echo ACTIVE; fi;;
    esac;;
  "projects create "*) touch "$D/created";;
  "projects delete "*) [ "\${FAKE_DELETE_NOOP:-0}" = 1 ] || touch "$D/deleted";;
  "container clusters create "*) [ "\${FAKE_CLUSTER_FAIL:-0}" = 1 ] && exit 1;;
  "container clusters get-credentials "*) [ -n "\${KUBECONFIG:-}" ] && touch "\$KUBECONFIG";;
esac
exit 0
EOS
# kubectl: storage classes from FAKE_SC (a JSON file); patch is recorded
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
case "\$*" in *"get storageclass"*) cat "\${FAKE_SC:-/dev/null}";; esac
exit 0
EOS
cat > "$D/fake-install.sh" <<EOS
#!/usr/bin/env bash
env | grep -E '^(CLUSTER_TYPE|PROFILE|KUBE_CONTEXT|KUBECONFIG|NODE_SETTINGS|SKIP_[A-Z0-9_]+|VALUES_FILE)=' | sort > "$D/install-env"
EOS
chmod +x "$D/bin/"* "$D/fake-install.sh"
calls(){ cat "$D/calls" 2>/dev/null; }
mode(){ stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }   # GNU stat first, then BSD stat
reset(){ : > "$D/calls"; rm -f "$D/created" "$D/deleted"; }
BA=0A0A0A-1B1B1B-2C2C2C; ORG=987654321098
OK_ENV=(PROJECT_PREFIX=oa-test "ORG_ID=$ORG" "BILLING_ACCOUNT=$BA" MAX_HOURS=2 AUTHORIZED_CIDR=192.0.2.10/32)
# up <VAR=value>...: up.sh with only these variables and the fakes first on PATH; prints its output and exit=<code>
up(){ reset; env -i PATH="$D/bin:$PATH" HOME="$D/home" STATE_ROOT="$D/state" "$@" bash hack/gke/up.sh 2>&1; echo "exit=$?"; }

echo "# up.sh refuses without the four required inputs and the CIDR, before any call"
for v in PROJECT_PREFIX ORG_ID BILLING_ACCOUNT MAX_HOURS AUTHORIZED_CIDR; do
  args=(); for a in "${OK_ENV[@]}"; do [ "${a%%=*}" = "$v" ] || args+=("$a"); done
  OUT=$(up "${args[@]}")
  t "no $v: refused, names it" "$(grep -c "ERROR: .*$v" <<<"$OUT")/$(grep -c '^exit=1$' <<<"$OUT")" 1/1
  t "no $v: no gcloud call" "$(calls)" ""
done
OUT=$(up PROJECT_PREFIX=Bad_Prefix ORG_ID=$ORG BILLING_ACCOUNT=$BA MAX_HOURS=2 AUTHORIZED_CIDR=192.0.2.10/32)
t "bad prefix refused" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0
OUT=$(up PROJECT_PREFIX=oa-test ORG_ID=$ORG BILLING_ACCOUNT=$BA MAX_HOURS=48 AUTHORIZED_CIDR=192.0.2.10/32)
t "MAX_HOURS over 24 refused" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0
OUT=$(up PROJECT_PREFIX=oa-test ORG_ID=$ORG BILLING_ACCOUNT=$BA MAX_HOURS=2 AUTHORIZED_CIDR=0.0.0.0/0)
t "an open control plane (0.0.0.0/0) refused" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0
OUT=$(up PROJECT_PREFIX=oa-test ORG_ID=12ab BILLING_ACCOUNT=$BA MAX_HOURS=2 AUTHORIZED_CIDR=192.0.2.10/32)
t "non-numeric ORG_ID refused" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0
OUT=$(up PROJECT=existing-one "${OK_ENV[@]}")
t "PROJECT is not an input (never an existing project)" "$(grep -c 'ERROR: .*PROJECT is not an input' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0

echo "# up.sh never touches a project that exists"
OUT=$(up FAKE_EXISTS=1 "${OK_ENV[@]}")
t "existing project id: refused" "$(grep -c 'already exists' <<<"$OUT")/$(grep -c '^exit=1$' <<<"$OUT")" 1/1
t "existing project id: nothing created or changed" "$(calls | grep -cvE '^gcloud projects describe ')" 0
t "existing project id: no state file left" "$(find "$D/state" -name state.env 2>/dev/null | wc -l | tr -d " ")" 0

echo "# up.sh: the whole run"
OUT=$(up "${OK_ENV[@]}")
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
STATE=$(find "$D/state" -name state.env | head -1)
t "state file written" "$([ -f "$STATE" ] && echo yes)" yes
P=$(sed -n 's/^PROJECT=//p' "$STATE")
t "project id: prefix, date, random part, at most 30 characters" "$(grep -cE '^oa-test-[0-9]{4}-[0-9a-f]{4}$' <<<"$P")/$([ ${#P} -le 30 ] && echo short)" 1/short
td=$(grep -n "hack/gke/down.sh $STATE" <<<"$OUT" | head -1 | cut -d: -f1)
first=$(grep -n '^FAKE gcloud projects create' <<<"$OUT" | head -1 | cut -d: -f1)
t "teardown command printed before anything is created" "$([ -n "$td" ] && [ "$td" -lt "$first" ] && echo yes)" yes
t "no billing account in the output" "$(grep -c "$BA" <<<"$OUT")" 0
t "no organisation id in the output" "$(grep -c "$ORG" <<<"$OUT")" 0
t "no billing account in the state file" "$(grep -c "$BA" "$STATE")" 0
t "state directory is private (700)" "$(mode "$(dirname "$STATE")")" 700
c(){ calls | grep -c -- "$1"; }
t "project created under the organisation, with the label" "$(c "^gcloud projects create $P --organization=$ORG --labels=created-by=openagentix-gke-up,delete-after=")" 1
t "billing linked" "$(c "^gcloud billing projects link $P --billing-account=$BA")" 1
t "APIs enabled" "$(c "^gcloud services enable container.googleapis.com compute.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com billingbudgets.googleapis.com --project=$P")" 1
t "budget on this project, quota billed to it" "$(calls | grep '^gcloud billing budgets create ' | grep -- "--filter-projects=projects/$P" | grep -- "--billing-project=$P" | grep -c -- '--budget-amount=10USD')" 1
for r in roles/storage.objectViewer roles/artifactregistry.writer roles/logging.logWriter roles/container.defaultNodeServiceAccount; do
  t "grant $r to the default compute service account" "$(c "^gcloud projects add-iam-policy-binding $P --member=serviceAccount:123456789012-compute@developer.gserviceaccount.com --role=$r ")" 1
done
t "Artifact Registry repository" "$(c "^gcloud artifacts repositories create oa --repository-format=docker --location=us-central1 --project=$P")" 1
CC=$(calls | grep '^gcloud container clusters create ')
for f in "--project=$P" --zone=us-central1-a --release-channel=rapid --machine-type=c3-standard-4 --num-nodes=1 --spot --image-type=COS_CONTAINERD \
         --enable-dataplane-v2 --disk-type=pd-balanced --disk-size=60 --enable-master-authorized-networks --master-authorized-networks=192.0.2.10/32 \
         --no-enable-managed-prometheus; do
  t "cluster create has $f" "$(grep -c -- " $f\( \|$\)" <<<"$CC")" 1
done
t "Cloud Build with the recipe and the repository path" "$(calls | grep '^gcloud builds submit ' | grep -- '--config=hack/gke/cloudbuild.yaml' | grep -c -- "--substitutions=_REPO=us-central1-docker.pkg.dev/$P/oa,_TAG=gke1")" 1
t "Cloud Build starts before the cluster create returns (both started)" "$(c '^gcloud builds submit ')/$(c '^gcloud container clusters create ')" 1/1
t "credentials fetched into the separate kubeconfig" "$(c "^gcloud container clusters get-credentials oa-gke --zone=us-central1-a --project=$P")" 1
t "kubeconfig is private (600)" "$(mode "$(dirname "$STATE")/kubeconfig")" 600
V=$(sed -n 's/^VALUES_FILE=//p' "$STATE")
for k in .governance.a2a.image .gateway.stubModel.image .controlPlane.image .console.image; do
  t "values: $k from Artifact Registry, tag gke1" "$(yq -r "$k | .repository + \":\" + .tag" "$V" | grep -cE "^us-central1-docker.pkg.dev/$P/oa/[a-z0-9-]+:gke1$")" 1
done
t "next step printed" "$(grep -c "hack/gke/install.sh $STATE" <<<"$OUT")" 1
OUT=$(up FAKE_CLUSTER_FAIL=1 "${OK_ENV[@]}")
t "cluster create fails: exit 1 and the teardown is printed again" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'hack/gke/down.sh' <<<"$OUT")" 1/2

echo "# install.sh: wraps ./install.sh with the values of the run"
inst(){ : > "$D/calls"; rm -f "$D/install-env"; env -i PATH="$D/bin:$PATH" HOME="$D/home" OA_INSTALL_SH="$D/fake-install.sh" "$@" bash hack/gke/install.sh "$STATE" 2>&1; echo "exit=$?"; }
echo '{"items":[{"metadata":{"name":"premium-rwo"}},{"metadata":{"name":"standard-rwo"}}]}' > "$D/sc-none.json"
echo '{"items":[{"metadata":{"name":"standard-rwo","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}' > "$D/sc-ok.json"
OUT=$(inst FAKE_SC="$D/sc-none.json")
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "no default StorageClass: marks standard-rwo" "$(calls | grep -c '^kubectl --context=gke_.* patch storageclass standard-rwo ')" 1
CTX="gke_${P}_us-central1-a_oa-gke"
for kv in CLUSTER_TYPE=remote PROFILE=quickstart "KUBE_CONTEXT=$CTX" NODE_SETTINGS=daemonset SKIP_SKILL=1 SKIP_A2A_GATE_IMAGE=1 SKIP_STUB_MODEL_IMAGE=1 \
          SKIP_CONTROL_PLANE_IMAGE=1 SKIP_CONSOLE_IMAGE=1 "VALUES_FILE=$V" "KUBECONFIG=$(dirname "$STATE")/kubeconfig"; do
  t "install env $kv" "$(grep -cx -- "$kv" "$D/install-env")" 1
done
inst FAKE_SC="$D/sc-ok.json" >/dev/null
t "a default StorageClass exists: no patch" "$(calls | grep -c ' patch ')" 0
inst FAKE_SC="$D/sc-none.json" GKE_KEEP_STORAGECLASS=1 >/dev/null
t "GKE_KEEP_STORAGECLASS=1: no patch" "$(calls | grep -c ' patch ')" 0
inst FAKE_SC="$D/sc-ok.json" NODE_SETTINGS=none >/dev/null
t "NODE_SETTINGS can be changed (for the A/B run)" "$(grep -cx NODE_SETTINGS=none "$D/install-env")" 1
cp "$STATE" "$D/past.env"; sed -i.bak 's/^DEADLINE=.*/DEADLINE=1000/' "$D/past.env"
OUT=$(: > "$D/calls"; rm -f "$D/install-env"; env -i PATH="$D/bin:$PATH" HOME="$D/home" OA_INSTALL_SH="$D/fake-install.sh" bash hack/gke/install.sh "$D/past.env" 2>&1; echo "exit=$?")
t "past the deadline: refused, teardown printed, install not run" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'hack/gke/down.sh' <<<"$OUT")/$([ -f "$D/install-env" ] && echo ran || echo no)" 1/1/no
printf 'PROJECT=x; rm -rf /\n' > "$D/evil.env"
OUT=$(: > "$D/calls"; env -i PATH="$D/bin:$PATH" HOME="$D/home" OA_INSTALL_SH="$D/fake-install.sh" bash hack/gke/install.sh "$D/evil.env" 2>&1; echo "exit=$?")
t "a state file with a bad value is refused" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0

echo "# down.sh: deletes only the project that up.sh made"
dn(){ : > "$D/calls"; env -i PATH="$D/bin:$PATH" HOME="$D/home" "$@" bash hack/gke/down.sh "${STATE_ARG:-$STATE}" 2>&1; echo "exit=$?"; }
OUT=$(dn FAKE_LABEL=something-else)
t "project without the up.sh label: refused, not deleted" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | grep -c '^gcloud projects delete ')" 1/0
OUT=$(STATE_ARG="$D/evil.env" dn)
t "bad state file: refused, no call" "$(grep -c '^exit=1$' <<<"$OUT")/$(calls | wc -l | tr -d ' ')" 1/0
OUT=$(dn FAKE_DELETE_NOOP=1)
t "delete not confirmed by the project state: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'not DELETE_REQUESTED' <<<"$OUT")" 1/1
rm -f "$D/deleted"; touch "$(dirname "$STATE")/kubeconfig"
OUT=$(dn FAKE_NONE=1)
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "project deleted, quietly, by id" "$(calls | grep -cx "gcloud projects delete $P --quiet")" 1
t "state checked after the delete" "$(grep -c 'DELETE_REQUESTED' <<<"$OUT")" 1
t "the separate kubeconfig removed" "$([ -e "$(dirname "$STATE")/kubeconfig" ] && echo still || echo gone)" gone
t "state file records the deletion" "$(grep -c '^DELETED_AT=' "$STATE")" 1
t "no kubectl call (only the project is deleted)" "$(calls | grep -c '^kubectl ')" 0
OUT=$(dn FAKE_NONE=1)
t "second run: already deleted, exit 0, no second delete" "$(grep -c '^exit=0$' <<<"$OUT")/$(calls | grep -c '^gcloud projects delete ')" 1/0

echo "# shellcheck"
if command -v shellcheck >/dev/null; then
  t "shellcheck clean" "$(shellcheck -x hack/gke/*.sh hack/gke/tests/run.sh >/dev/null 2>&1 && echo clean || echo findings)" clean
else echo "  skip shellcheck (not installed)"; fi

if [ "$F" = 0 ]; then echo "hack/gke tests passed"; else echo "hack/gke tests FAILED"; exit 1; fi
