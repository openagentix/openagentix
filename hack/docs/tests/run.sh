#!/usr/bin/env bash
# Offline tests of the reference pages: generated blocks are current, YAML examples pass the CRD schema, the console OpenAPI file
# lists the console's routes. Needs jq, yq (Python wrapper), perl, python3 with PyYAML and jsonschema (pip install pyyaml jsonschema).
set -euo pipefail
cd "$(dirname "$0")/../../.."
hack/docs/gen-reference.sh --check
python3 -I hack/docs/tests/validate-examples.py
hack/docs/check-console-openapi.sh
echo "docs reference tests passed"
