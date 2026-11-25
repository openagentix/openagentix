#!/usr/bin/env python3
"""Checks every AgentDefinition example in docs/diary/reference/*.md and the repo's own example files against the CRD schema.

jsonschema checks the structure (types, required, limits, patterns, enums). A schema validator does not evaluate the CEL rules of the
CRD, so the three that exist are repeated here: name length, name pattern and exactly one of instructions and instructionsFrom.
"""
import glob
import os
import re
import sys

import yaml
from jsonschema import Draft202012Validator

root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
crd = yaml.safe_load(open(os.path.join(root, "services/control-plane/crd/agentdefinition.yaml")))
schema = crd["spec"]["versions"][0]["schema"]["openAPIV3Schema"]


def clean(node):
    """Drop the Kubernetes-only keywords so that the rest is plain JSON Schema."""
    if isinstance(node, dict):
        return {k: clean(v) for k, v in node.items() if not k.startswith("x-kubernetes")}
    if isinstance(node, list):
        return [clean(v) for v in node]
    return node


validator = Draft202012Validator(clean(schema))
fence = re.compile(r"```yaml\n(.*?)\n```", re.S)
docs = []  # (source, object)
for f in sorted(glob.glob(os.path.join(root, "docs/diary/reference/*.md"))):
    for i, block in enumerate(fence.findall(open(f).read()), 1):
        for obj in yaml.safe_load_all(block):
            if isinstance(obj, dict) and obj.get("kind") == "AgentDefinition":
                docs.append((f"{os.path.relpath(f, root)} block {i}", obj))
for extra in ["components/control-plane/researcher.yaml", "components/quickstart/agent.yaml"]:
    for obj in yaml.safe_load_all(open(os.path.join(root, extra))):
        if obj:
            docs.append((extra, obj))

errors = []
for src, obj in docs:
    for e in validator.iter_errors(obj):
        errors.append(f"{src}: {'/'.join(map(str, e.path))}: {e.message}")
    name = obj.get("metadata", {}).get("name", "")
    if obj.get("apiVersion") != "openagentix.io/v1alpha1":
        errors.append(f"{src}: apiVersion must be openagentix.io/v1alpha1")
    if len(name) > 40 or not re.fullmatch(r"[a-z]([-a-z0-9]*[a-z0-9])?", name):
        errors.append(f"{src}: name {name!r} breaks the name rules")
    spec = obj.get("spec", {})
    if ("instructions" in spec) == ("instructionsFrom" in spec):
        errors.append(f"{src}: set exactly one of instructions and instructionsFrom")
    if len(spec.get("instructions", "").encode()) > 16384:
        errors.append(f"{src}: instructions are longer than 16384 bytes")

if not any(s.startswith("docs/") for s, _ in docs):
    errors.append("no AgentDefinition example found in the reference pages")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"{len(docs)} AgentDefinition examples match the CRD schema")
