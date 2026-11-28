#!/usr/bin/env bash
# The one guard of the live CI scripts (issue #212). A live script installs, changes or restarts things on the cluster that the current kube context names, so it must
# not run by hand against a cluster somebody uses. Source this file and call, BEFORE any other call to kubectl, helm, kind or docker:
#
#   . "$(dirname "$0")/lib/require-ci-context.sh"
#   require_ci_context <script name> <NAME_OF_THE_CI_CONTEXT_VARIABLE> [allow-none]
#
# The rule (the same for every script that uses it):
#   1. the current context is read with `kubectl config current-context` and nothing else is called before the decision (only the kubeconfig is read);
#   2. it must be kind-* or k3d-*: a context of a cloud or of a person's cluster is refused;
#   3. on GitHub Actions (GITHUB_ACTIONS=true) the runner is a throwaway machine and the cluster it made is accepted whatever its name (the quick start jobs use the
#      default name kind-openagentix);
#   4. anywhere else the script runs only when the variable named by the second argument (for example SMOKE_CI_CONTEXT) holds the current context EXACTLY, and
#      kind-openagentix, the default cluster that people use by hand, is refused outright: no variable allows it.
# The third argument allow-none is for a script that makes its cluster itself (the upgrade test runs the installer of the old release): on GitHub Actions only, and
# only when there is no current context yet, it returns without a decision. By hand the rule above holds.
# A refusal prints why and "Nothing was changed." on standard error and exits 2. KUBECTL names another kubectl (a test sets a fake).
require_ci_context() {
  local name=$1 var=$2 none=${3:-} k ctx want
  k=${KUBECTL:-kubectl}
  ctx=$($k config current-context 2>/dev/null || true)
  if [ -z "$ctx" ] && [ "$none" = allow-none ] && [ "${GITHUB_ACTIONS:-}" = true ]; then return 0; fi
  case "$ctx" in
    kind-* | k3d-*) ;;
    *) echo "$name: refusing to run: the current kube context is '${ctx:-none}', not a kind or k3d context. This script changes the cluster; do not run it on a cluster you use. Nothing was changed." >&2; exit 2 ;;
  esac
  [ "${GITHUB_ACTIONS:-}" = true ] && return 0
  if [ "$ctx" = kind-openagentix ]; then
    echo "$name: refusing to run on kind-openagentix, the name of a full demo cluster that people use by hand: it is not a CI run (GITHUB_ACTIONS is not true) and no variable allows it. Nothing was changed." >&2
    exit 2
  fi
  want=${!var:-}
  if [ "$want" != "$ctx" ]; then
    echo "$name: refusing to run on '$ctx': it is not a CI run (GITHUB_ACTIONS is not true) and $var does not name this context exactly. This script changes the cluster; do not run it on a cluster you use. Nothing was changed." >&2
    exit 2
  fi
  return 0
}
