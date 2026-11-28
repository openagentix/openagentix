#!/usr/bin/env bash
# Tests for hack/key-entry.sh and for install.sh's use of it (ADR 0029): the entry of a chart agent in the gateway key ConfigMap llm-api-keys
# is byte for byte what it was when the agent names no budget class, and carries "budget_class" after "user_id" when it does.
set -u
cd "$(dirname "$0")/../.."
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
[ -f hack/key-entry.sh ] || { echo "  FAIL hack/key-entry.sh is missing"; exit 1; }
. hack/key-entry.sh
H=sha256:$(printf 'ab%.0s' $(seq 32))
OLD="{\"keyHash\":\"$H\",\"metadata\":{\"user_id\":\"assistant\"}}"
t "no class: the entry is the one the installer always wrote" "$(key_entry assistant "$H" "")" "$OLD"
t "no class argument: the same entry" "$(key_entry assistant "$H")" "$OLD"
t "a class: budget_class follows user_id" "$(key_entry assistant "$H" bank-agents)" "{\"keyHash\":\"$H\",\"metadata\":{\"user_id\":\"assistant\",\"budget_class\":\"bank-agents\"}}"
t "the entry with a class is valid JSON with the two members" "$(key_entry assistant "$H" bank-agents | jq -c '.metadata|[.user_id,.budget_class]')" '["assistant","bank-agents"]'
t "no whitespace in the entry" "$(key_entry assistant "$H" bank-agents | grep -c ' ')" 0
t "a class that is not a DNS label is refused (no JSON injection)" "$(key_entry assistant "$H" 'a","admin":"1' >/dev/null 2>&1; echo $?)" 1
t "a class in upper case is refused" "$(key_entry assistant "$H" 'Bank' >/dev/null 2>&1; echo $?)" 1
t "a class of 41 characters is refused" "$(key_entry assistant "$H" "$(printf 'a%.0s' $(seq 1 41))" >/dev/null 2>&1; echo $?)" 1
t "the reserved class default is refused" "$(key_entry assistant "$H" default >/dev/null 2>&1; echo $?)" 1
# install.sh wiring: the class comes from the annotation of the agent's ModelConfig, and the entry is built by key_entry
t "install.sh sources hack/key-entry.sh" "$(grep -c '^\. hack/key-entry.sh' install.sh)" 1
t "install.sh builds the entry with key_entry" "$(grep -c 'key_entry "\$agent" "\$h"' install.sh)" 1
t "install.sh reads the class from the openagentix.io/budget-class annotation of the ModelConfig" "$(grep -c 'annotations\["openagentix.io/budget-class"\]' install.sh)" 1
t "install.sh no longer writes the entry text itself" "$(grep -c 'keyHash\\":\\"\$h' install.sh)" 0
exit $F
