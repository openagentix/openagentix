#!/usr/bin/env bash
# Live check of event callers (ADR 0027, issue #229), run after
#   PROFILE=quickstart VALUES_FILE=hack/ci/event-ci-values.yaml ./install.sh
# on a throwaway kind cluster of a hosted runner (the stub model: no key, no token, no paid call). It refuses to run anywhere else, because it patches the
# A2A gate Deployment (a recording stand-in as a second container) and makes ServiceAccounts. See hack/ci/event_live.py for what it proves.
#   EVENT_LIVE=1   required, so that a stray run does nothing
#   EVENT_OUT      directory for report.json (default event-out)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
[ "${EVENT_LIVE:-}" = 1 ] || { echo "event-live: set EVENT_LIVE=1 (this patches the A2A gate of the current kind cluster; GitHub Actions only)" >&2; exit 2; }
command -v kubectl >/dev/null || { echo "event-live: kubectl is required" >&2; exit 2; }
command -v helm >/dev/null || { echo "event-live: helm is required (the render refusals are checked offline)" >&2; exit 2; }
# the one guard of the live CI scripts (issue #212): kind or k3d only, a CI run or the named context, never kind-openagentix by hand; it reads the kubeconfig and nothing else
. hack/ci/lib/require-ci-context.sh   # the script has changed to the repository root
require_ci_context event-live EVENT_LIVE_CI_CONTEXT
exec python3 -I hack/ci/event_live.py
