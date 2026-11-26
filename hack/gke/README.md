# hack/gke: a throwaway GKE run of the quick start

Three scripts that repeat the first GKE run of [issue 31](https://github.com/openagentix/openagentix/issues/31) in a new Google Cloud project, and delete the whole project at the end. The run itself, its timings and its limits are on [Install on GKE](../../docs/diary/guide/install-gke.md).

**Status:** the first run was done by hand with the same commands. These scripts were written from it afterwards and are tested offline only, with a fake `gcloud` and `kubectl` (`hack/gke/tests/run.sh`). They have not been run against a real project yet.

| Script | What it does |
|---|---|
| `up.sh` | Makes a **new** project under your organisation, links billing, adds a budget alert, enables the APIs, grants the default compute service account what Cloud Build and the nodes need, makes an Artifact Registry repository, starts the cluster create in the background and builds the four images in Cloud Build at the same time. Writes a state file, a separate kubeconfig and a values file. Prints the teardown command before it creates anything. |
| `install.sh <state file>` | Sets `SET_DEFAULT_STORAGECLASS=standard-rwo` if the cluster has no default StorageClass (the installer then marks it), then runs `./install.sh` in remote mode with the stub model and the images from Artifact Registry. With `GKE_IMAGES=installer` (set it for `up.sh` too, which then skips Cloud Build) the installer builds and pushes the images itself (`IMAGE_REGISTRY`, ADR 0022; log in with `gcloud auth configure-docker <region>-docker.pkg.dev` first; not run on GKE yet). |
| `down.sh <state file>` | Deletes the project (only one with the label `created-by=openagentix-gke-up`), checks that it is `DELETE_REQUESTED`, removes the separate kubeconfig. |
| `cloudbuild.yaml` | The Cloud Build recipe: four parallel `docker build` steps on `E2_HIGHCPU_8`, pushed with one tag. |

## Use

```sh
export PROJECT_PREFIX=oa-test ORG_ID=<organisation id> BILLING_ACCOUNT=<billing account> MAX_HOURS=2 AUTHORIZED_CIDR=<your IP>/32
hack/gke/up.sh                                   # about 7 to 8 minutes; prints the state file path
hack/gke/install.sh ~/.openagentix/gke/<project>/state.env
KUBECONFIG=~/.openagentix/gke/<project>/kubeconfig hack/ci/smoke.sh
hack/gke/down.sh ~/.openagentix/gke/<project>/state.env
```

Run `hack/ci/smoke.sh`, `hack/ci/netpol-test.sh` and `hack/demo.sh` with the same `KUBECONFIG`. Its current context is the new cluster.

## Safety rules the scripts keep

- Never an existing project. The project id is made by the script (`<prefix>-<MMDD>-<4 hex>`), `PROJECT` is refused as an input, and the script stops if the id exists. `install.sh` and `down.sh` act only on a project with the label `created-by=openagentix-gke-up`. The kubeconfig and values paths are never read from the state file; they are always files in the state file's own directory.
- Refuses to start without `PROJECT_PREFIX`, `ORG_ID`, `BILLING_ACCOUNT`, `MAX_HOURS` (1 to 24) and `AUTHORIZED_CIDR` (an IPv4 range of /8 or narrower). Every other input is checked before the first call.
- Prints no credential, no billing account and no organisation id. The state file holds neither. Errors of the three calls that carry them go to `gcloud.log` in the state directory, not to the terminal.
- Your default kubeconfig is not touched. The cluster's credentials go to a separate file with mode 600, in a directory with mode 700.
- Only committed files travel to Cloud Build (`git archive HEAD` of the four images' directories).
- On a failure or Ctrl-C after the project exists, `up.sh` prints the teardown command again.
- `install.sh` refuses after the deadline. **Nothing deletes the project at the deadline. Only `down.sh` does.** A budget only sends alerts; it does not stop spending.

## Limits

- The four roles go to the default compute service account, which is also the node identity. So pods on the node can push to the project's Artifact Registry and read its buckets. That is acceptable for a throwaway project with only this install in it; do not reuse the project.
- The budget lives on the billing account and stays after `down.sh`.

## Optional settings

`REGION=us-central1`, `ZONE=us-central1-a`, `CLUSTER=oa-gke`, `MACHINE_TYPE=c3-standard-4`, `SPOT=1` (`0` for on-demand), `DISK_GB=60`, `BUDGET_USD=10`, `IMAGE_TAG=gke1`, `CLUSTER_VERSION` (empty: the rapid channel default), `STATE_ROOT=$HOME/.openagentix/gke`. For `install.sh`: `NODE_SETTINGS=none` skips the node settings DaemonSet (for the A/B run), `GKE_KEEP_STORAGECLASS=1` does not set `SET_DEFAULT_STORAGECLASS`, `VALUES_FILE` is added after the image values, `GKE_IMAGES=installer` lets `./install.sh` build and push the images (default `cloudbuild`: the images `up.sh` built).

## Test

```sh
hack/gke/tests/run.sh      # fake gcloud and kubectl, no cloud call; also runs shellcheck if it is installed
```
