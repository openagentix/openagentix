#!/usr/bin/env bash
# Sourced by install.sh (and by hack/ci/key-entry-test.sh). One function: the entry of a chart agent in the gateway key ConfigMap llm-api-keys.
#
#   key_entry <agent> <keyHash> [budget class]
#
# Prints {"keyHash":"<hash>","metadata":{"user_id":"<agent>"}} (the text the installer has always written), and with a budget class
# (ADR 0029) {"keyHash":"<hash>","metadata":{"user_id":"<agent>","budget_class":"<class>"}}. The gateway policy reads the member as
# apiKey.budget_class. The class must be a DNS label of at most 40 characters and not "default" (the chart checks the same); anything else returns 1
# and prints nothing, so a value can never close the JSON string.

key_entry() {
  local agent=$1 hash=$2 class=${3:-}
  if [ -z "$class" ]; then
    printf '{"keyHash":"%s","metadata":{"user_id":"%s"}}\n' "$hash" "$agent"
    return 0
  fi
  if [ "${#class}" -gt 40 ] || [ "$class" = default ] || ! [[ "$class" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    echo "key_entry: the budget class '$class' is not a DNS label of at most 40 characters (or is the reserved name default)" >&2
    return 1
  fi
  printf '{"keyHash":"%s","metadata":{"user_id":"%s","budget_class":"%s"}}\n' "$hash" "$agent" "$class"
}
