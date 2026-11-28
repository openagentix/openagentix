#!/usr/bin/env bash
# Chart tests of ADR 0030, slice 5: knowledge.kb.graph.schemas. Sourced by run.sh (it shares eq, q, count, docs, render_err, and the variables CHART, REPO).
echo "# kb graph schemas (ADR 0030, slice 5): the flag, the env value, the tool name, off by default"
SK=(--set knowledge.kb.graph.enabled=true)
ssha() { helm template openagentix "$CHART" -n openagentix-system "$@" 2>&1 | shasum -a 256; }
S0=$(ssha)
eq "default: schemas are off" "$(yq -c '.knowledge.kb.graph.schemas' "$CHART/values.yaml")" '{"enabled":false}'
eq "schemas.enabled=false renders byte-identical to the default" "$(ssha --set knowledge.kb.graph.schemas.enabled=false)" "$S0"
eq "knowledge.kb.graph.schemas=null renders byte-identical to the default" "$(ssha --set knowledge.kb.graph.schemas=null)" "$S0"
G0=$(ssha "${SK[@]}")
eq "graph on, schemas off: byte-identical to the graph render without the setting" "$(ssha "${SK[@]}" --set knowledge.kb.graph.schemas.enabled=false)" "$G0"
D=$(docs "${SK[@]}")
KBE='.[]|select(.kind=="Deployment" and .metadata.name=="kb")|.spec.template.spec.containers[0].env[]'
eq "graph on, schemas off: no KB_GRAPH_SCHEMAS_ENABLED" "$(q "$D" "[$KBE|select(.name==\"KB_GRAPH_SCHEMAS_ENABLED\")]|length")" 0
D=$(docs "${SK[@]}" --set knowledge.kb.graph.schemas.enabled=true)
eq "schemas on: the kb gets KB_GRAPH_SCHEMAS_ENABLED=true" "$(q "$D" "$KBE|select(.name==\"KB_GRAPH_SCHEMAS_ENABLED\")|.value")" true
eq "schemas on: the graph variables are the same ten and one more" "$(q "$D" "[$KBE|select(.name|startswith(\"KB_GRAPH\"))]|length")" 11
eq "schemas on: the chart renders no Secret and no value for it" "$(count "$D" '.kind=="Secret"')" 0

echo "# kb graph schemas: refused without the graph"
eq "schemas on and the graph off is refused, and the sentence names the fix" "$(render_err --set knowledge.kb.graph.schemas.enabled=true | /usr/bin/grep -c 'knowledge.kb.graph.schemas.enabled needs knowledge.kb.graph.enabled=true')" 1
eq "schemas on and the knowledge base off is refused too (the value would mean nothing)" "$(render_err --set knowledge.enabled=false --set knowledge.kb.graph.schemas.enabled=true | /usr/bin/grep -c 'knowledge.kb.graph.schemas.enabled needs knowledge.kb.graph.enabled=true')" 1
eq "a value that is not true or false is refused" "$(render_err "${SK[@]}" --set-string knowledge.kb.graph.schemas.enabled=yes | /usr/bin/grep -c 'knowledge.kb.graph.schemas.enabled must be true or false')" 1

echo "# kb graph schemas: the tool name an agent sees"
AT='.[]|select(.kind=="AgentTemplate" and .metadata.name=="assistant-template")'
DA=$(docs "${SK[@]}" --set knowledge.kb.graph.schemas.enabled=true)
eq "schemas on: oa.knowledgeTools adds knowledge_kb_graph_schema for an agent with knowledge: true" "$(q "$DA" "$AT|[.spec.tools[0].mcp.tools[]|select(test(\"kb_graph_schema\"))]|join(\",\")")" knowledge_kb_graph_schema
eq "schemas on: the other graph tools are still there" "$(q "$DA" "$AT|[.spec.tools[0].mcp.tools[]|select(test(\"kb_graph_(search|entity|paths)\"))]|length")" 3
DB=$(docs "${SK[@]}")
eq "schemas off: the agent has no schema tool" "$(q "$DB" "$AT|[.spec.tools[0].mcp.tools[]|select(test(\"kb_graph_schema\"))]|length")" 0
