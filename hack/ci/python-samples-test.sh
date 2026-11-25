#!/usr/bin/env bash
# Tests of the Python sample agent: installs its pinned requirements with hash checking into a throwaway virtual
# environment, then runs pytest. The contract test against services/stub-model builds the stub with Go; it skips itself
# when Go is not installed. Needs python3 (3.10 or newer) and network access to PyPI. Writes nothing into the repository.
#   hack/ci/python-samples-test.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
dir=examples/agents/echo-a2a-python
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 -m venv "$tmp/venv"
"$tmp/venv/bin/pip" install --quiet --disable-pip-version-check --require-hashes --no-deps -r "$dir/requirements-dev.txt"
cd "$dir"
PYTHONDONTWRITEBYTECODE=1 "$tmp/venv/bin/python" -m pytest -q -p no:cacheprovider
