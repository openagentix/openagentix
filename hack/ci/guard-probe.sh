#!/usr/bin/env bash
# Diagnostics: what does the control plane's admission guard say about a key Secret of the shape the controller creates?
# A server-side dry run as the controller's ServiceAccount; prints the API server's answer (the message of the refused rule). Creates nothing.
set -uo pipefail
K=${KUBECTL:-kubectl}
UID_=$($K get agentdefinition quickstart -n kagent -o jsonpath='{.metadata.uid}' 2>/dev/null)
$K create --dry-run=server -f - --as=system:serviceaccount:openagentix-system:openagentix-control-plane 2>&1 <<EOF || true
apiVersion: v1
kind: Secret
type: Opaque
immutable: true
metadata:
  name: quickstart-virtual-key-4a5caddf
  namespace: kagent
  labels: {app.kubernetes.io/managed-by: openagentix-control-plane, openagentix.io/agent-definition: quickstart}
  annotations: {openagentix.io/key-fingerprint: abcdef01}
  ownerReferences: [{apiVersion: openagentix.io/v1alpha1, kind: AgentDefinition, name: quickstart, uid: "$UID_", controller: true}]
data: {OPENAI_API_KEY: dmstMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA=}
EOF
