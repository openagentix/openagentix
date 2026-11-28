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
exec python3 -I hack/ci/event_live.py
