#!/usr/bin/env bash
# Spikes for ADR 0029 (model gateway, budget classes) and ADR 0027 (the runtime behind the A2A gate, event triggers). Issue #229, PRs #262 and #260.
# Run by .github/workflows/spike-adr-0027-0029.yml on a throwaway kind cluster that `PROFILE=quickstart ./install.sh` made, in GitHub Actions only.
#
#   SPIKES=a|b|both   which spike (default both)
#   SPIKE_OUT=dir     where results-adr0029.md, results-adr0027.md, their json and the dumps go (default ./spike-out)
#
# It changes the cluster it runs on (the one gateway policy's rate limit, a ConfigMap of test keys, the model's base URL, a stand-in pod). It refuses to run
# elsewhere. It sets no secret on a command line and prints none. No paid model call: the only model is the stub.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ "${GITHUB_ACTIONS:-}" = true ] || { echo "adr-spikes: refusing to run outside GitHub Actions: it changes the cluster it runs on" >&2; exit 2; }
case "$(kubectl config current-context 2>/dev/null)" in kind-*) ;; *) echo "adr-spikes: the current kube context is not a kind context" >&2; exit 2;; esac
OUT=${SPIKE_OUT:-$PWD/spike-out}; mkdir -p "$OUT"; export SPIKE_OUT="$OUT"
which=${SPIKES:-both}
rc=0
say() { printf '\n==> %s\n' "$*"; }

if [ "$which" = a ] || [ "$which" = both ]; then
  say "spike A (ADR 0029): the model gateway"
  python3 -I "$here/adr0029_gateway_spike.py" || rc=$?
  kubectl logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=model-gateway --tail=3000 --all-containers > "$OUT/log-gateway-proxy.txt" 2>&1 || true
fi
if [ "$which" = b ] || [ "$which" = both ]; then
  say "spike B (ADR 0027): the runtime behind the gate"
  python3 -I "$here/adr0027_gate_spike.py" || rc=$?
  kubectl logs -n openagentix-gateway deploy/a2a-gate --tail=3000 > "$OUT/log-a2a-gate.txt" 2>&1 || true
  kubectl logs -n kagent deploy/kagent-controller --tail=2000 > "$OUT/log-kagent-controller.txt" 2>&1 || true
  kubectl logs -n spike-adr deploy/slow-model --tail=500 > "$OUT/log-stand-in.txt" 2>&1 || true
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  for f in "$OUT"/results-adr0029.md "$OUT"/results-adr0027.md; do [ -f "$f" ] && cat "$f" >> "$GITHUB_STEP_SUMMARY"; done
fi
for f in "$OUT"/results-adr0029.md "$OUT"/results-adr0027.md; do [ -f "$f" ] && cat "$f"; done
exit "$rc"
