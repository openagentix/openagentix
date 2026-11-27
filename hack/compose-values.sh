#!/usr/bin/env bash
# compose-values.sh: merge Helm values files into one values file, by entry name (ADR 0026, E).
#
#   hack/compose-values.sh [--later-wins] FILE [FILE...] > composed.yaml
#   hack/compose-values.sh components/quickstart/values.yaml examples/use-cases/bank/values.yaml > /tmp/bank-values.yaml
#   PROFILE=quickstart VALUES_FILE=/tmp/bank-values.yaml ./install.sh
#
# Helm replaces lists, so a values file that adds an agent has to restate every agent of the file before it. This helper does that merge
# for you and tells you what it did. It is a helper, not a chart contract: the chart and Helm do not change, and install.sh takes the
# output through VALUES_FILE as before. A later file wins, as with several -f flags.
#
# The rules:
#   - Maps merge as Helm merges them. A scalar that a later file changes is reported on standard error with its path, the old and the
#     new value. The value of a key that names a Secret or a key (secret, token, password, credential, apiKey, ... *Key) is never shown:
#     only the path is.
#   - These lists are merged by the `name` of their entries: agents, schedules, governance.a2a.callers, gateway.models, mcp.servers,
#     mcp.endpoints, mcp.profiles. Entries keep the order of first appearance. Every entry that a later file adds is reported. The same
#     name with the same content is kept once. The same name with different content is REFUSED, with both file names, unless
#     --later-wins is given (then the later entry replaces it and each changed value is reported).
#   - Security keys: a later file may not change these without --later-wins: the allow lists of controlPlane.policy (allowedModels,
#     allowedProfiles, allowedSkills, egress, requireToolProfile, allowKnowledge, allowNotify, memory, allowedRuntimes, runtimes),
#     controlPlane.containerAgents.toolProfiles, networkPolicy.*, governance.a2a.enabled, mcp.virtual.incomingAuth.*,
#     mcp.virtual.codeMode.enabled, mcp.egress.allow, observability.capture.content, gateway.policy.* and the egress of every agent.
#     Allow lists are never joined: a union would widen access without anyone writing it down. With --later-wins the later value
#     replaces the earlier one, and the change is reported. A security key that only a later file sets is kept, and noted.
#   - Every other list is replaced by the later file, as Helm does, and reported. An explicit empty list (`agents: []`) is kept in the
#     output, and a later `[]` replaces an earlier list.
#   - The output starts with a comment that lists the input files. It needs jq and the Python yq (pip install yq==3.4.3), the same
#     as `make test-chart`.
#
# Exit codes: 0 composed; 1 refused (nothing is written to standard output); 2 usage error or a file that cannot be read.
#
# This script is not security relevant on its own. One note: a composed file can turn on what neither input shows alone.
# Read the report and the output before installing it.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die2() { echo "compose-values.sh: $*" >&2; exit 2; }

LATER_WINS=false
FILES=()
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --later-wins) LATER_WINS=true ;;
    -*) die2 "unknown option: $arg (usage: compose-values.sh [--later-wins] FILE [FILE...]; -h for help)" ;;
    *) FILES+=("$arg") ;;
  esac
done
[ "${#FILES[@]}" -gt 0 ] || die2 "usage: compose-values.sh [--later-wins] FILE [FILE...]  (-h for help)"
command -v jq >/dev/null || die2 "jq is required"
command -v yq >/dev/null || die2 "yq is required (the Python jq wrapper: pip install yq==3.4.3)"
yq --version 2>&1 | grep -q '^yq 3\.' || die2 "yq must be the Python wrapper (kislyuk/yq 3.x), not another yq"

# Read every file as JSON: one {file, doc} line each.
INPUT=""
for f in "${FILES[@]}"; do
  [ -f "$f" ] || die2 "cannot read $f (no such file)"
  if ! DOCS=$(yq -c . "$f" 2>&1); then die2 "$f is not valid YAML: $(printf '%s' "$DOCS" | head -1)"; fi
  [ "$(printf '%s\n' "$DOCS" | grep -c .)" -le 1 ] || die2 "$f has more than one YAML document"
  if [ -z "$DOCS" ]; then LINE=$(jq -cn --arg f "$f" '{file:$f, doc:null}'); else LINE=$(printf '%s\n' "$DOCS" | jq -c --arg f "$f" '{file:$f, doc:.}'); fi
  INPUT+="$LINE"$'\n'
done

read -r -d '' PROGRAM <<'JQ' || true
def namelists: ["agents","schedules","governance.a2a.callers","gateway.models","mcp.servers","mcp.endpoints","mcp.profiles"];
def secpfx: [
  "controlPlane.policy.allowedModels","controlPlane.policy.allowedProfiles","controlPlane.policy.allowedSkills",
  "controlPlane.policy.egress","controlPlane.policy.requireToolProfile","controlPlane.policy.allowKnowledge",
  "controlPlane.policy.allowNotify","controlPlane.policy.memory","controlPlane.policy.allowedRuntimes","controlPlane.policy.runtimes",
  "controlPlane.containerAgents.toolProfiles","networkPolicy","governance.a2a.enabled","mcp.virtual.incomingAuth",
  "mcp.virtual.codeMode.enabled","mcp.egress.allow","observability.capture.content","gateway.policy","agents[].egress"];
def isobj: type == "object";
def isarr: type == "array";
def cp($p; $k): if $p == "" then $k else $p + "." + $k end;
def norm: gsub("\\[[^\\]]*\\]"; "[]");
def namelist($p): any(namelists[]; . == $p);
def issec($p): ($p | norm) as $n | any(secpfx[]; . as $s | $n == $s or ($n | startswith($s + ".")) or ($n | startswith($s + "[")));
def issecanc($p): ($p | norm) as $n | any(secpfx[]; startswith($n + "."));
def parent: if test("(\\.[^.\\[]*|\\[[^\\]]*\\])$") then sub("(\\.[^.\\[]*|\\[[^\\]]*\\])$"; "") else "" end;
def findsrc($src; $p): if $src[$p] != null then $src[$p] elif $p == "" then ($src[""] // "?") else findsrc($src; ($p | parent)) end;
def leafkey($p): $p | sub("\\[[^\\]]*\\]$"; "") | split(".") | last;
def secretish($p): leafkey($p) | test("secret|token|password|passwd|credential|apikey|api[-_]key|private[-_]?key|key$"; "i");
def showv($p; $v): if secretish($p) then "(value not shown)" else ($v | tojson) end;
def leaves($p; $v): if ($v | isobj) and ($v | length) > 0 then ($v | to_entries[] | leaves(cp($p; .key); .value)) else [$p, $v] end;
def secflag($p): if issec($p) or issecanc($p) then " [security key]" else "" end;

def leafline($p; $a; $b; $fa; $fb):
  (issec($p) or issecanc($p)) as $s
  | if ($a | isarr) and ($b | isarr) then
      if $s then "changed security key " + $p + ": " + showv($p; $a) + " -> " + showv($p; $b) + " (" + $fa + " -> " + $fb + ")"
      else "replaced list " + $p + " (" + ($a | length | tostring) + " -> " + ($b | length | tostring) + " entries" + (if ($b | length) == 0 then ", now empty" else "" end) + ") (" + $fa + " -> " + $fb + ")" end
    elif ($a | type) != ($b | type) then
      "replaced " + $p + ": " + ($a | type) + " -> " + ($b | type) + secflag($p) + " (" + $fa + " -> " + $fb + ")"
    else
      (if $s then "changed security key " else "changed " end) + $p + ": " + showv($p; $a) + " -> " + showv($p; $b) + " (" + $fa + " -> " + $fb + ")"
    end;

def diffrep($p; $a; $b; $fa; $fb):
  if ($a | isobj) and ($b | isobj) then
    ([$a, $b | keys[]] | unique)[] as $k
    | cp($p; $k) as $c
    | if ($a | has($k) | not) then "added " + $c + " (from " + $fb + ")" + secflag($c)
      elif ($b | has($k) | not) then "removed " + $c + " (by " + $fb + ")" + secflag($c)
      else diffrep($c; $a[$k]; $b[$k]; $fa; $fb) end
  elif $a == $b then empty
  else leafline($p; $a; $b; $fa; $fb)
  end;

def difflist($p; $a; $b):
  if ($a | isobj) and ($b | isobj) then
    ([$a, $b | keys[]] | unique)[] as $k | cp($p; $k) as $c
    | if ($a | has($k)) and ($b | has($k)) then difflist($c; $a[$k]; $b[$k]) else $c end
  elif $a == $b then empty
  else $p
  end;

# one file: check and tidy its by-name lists
def prep($doc; $f):
  reduce namelists[] as $lp ({v: $doc, err: []};
    ($lp | split(".")) as $path
    | (.v | getpath($path)) as $l
    | if $l == null then .
      elif ($l | isarr | not) then .err += [$f + ": " + $lp + " must be a list of entries that have a name"]
      else
        (reduce $l[] as $e ({l: [], err: []};
          if ($e | isobj | not) or (($e.name?) | type) != "string" or $e.name == "" then
            .err += [$f + ": an entry of " + $lp + " has no name (every entry of " + $lp + " needs a name, because the entries are merged by name)"]
          else
            $e.name as $n
            | (.l | map(.name) | index($n)) as $i
            | if $i == null then .l += [$e]
              elif .l[$i] == $e then .
              else .err += [$f + ": refused: " + $lp + "[" + $n + "] appears twice in this file with different content. Remove one."] end
          end)) as $r
        | .err += $r.err | .v = (.v | setpath($path; $r.l))
      end);

def mergelist($p; $a; $b; $fb; $lw; $st):
  reduce $b[] as $e ({v: $a, st: $st};
    $e.name as $n
    | ($p + "[" + $n + "]") as $ep
    | (.v | map(.name) | index($n)) as $i
    | if $i == null then
        .v += [$e]
        | .st.src[$ep] = $fb
        | .st.rep += ["added " + $ep + " (from " + $fb + ")"]
        | .st.rep += [leaves($ep; $e) | select(issec(.[0])) | "note: " + $fb + " sets security key " + .[0]]
      elif .v[$i] == $e then .
      else
        findsrc(.st.src; $ep) as $fa
        | if $lw then
            .st.rep += [diffrep($ep; .v[$i]; $e; $fa; $fb)]
            | .v[$i] = $e
            | .st.src[$ep] = $fb
          else
            .st.err += ["refused: " + $ep + " is in " + $fa + " and in " + $fb + " with different content (differs at: " + ([difflist($ep; .v[$i]; $e)] | join(", ")) + "). Give --later-wins to take the later one, or make the two the same."]
          end
      end);

def merge($p; $a; $b; $fb; $lw; $st):
  if ($a | isobj) and ($b | isobj) then
    reduce ($b | keys_unsorted[]) as $k ({v: $a, st: $st};
      cp($p; $k) as $c
      | if (.v | has($k)) then
          merge($c; .v[$k]; $b[$k]; $fb; $lw; .st) as $r | .v[$k] = $r.v | .st = $r.st
        elif namelist($c) and ($b[$k] | isarr) then
          mergelist($c; []; $b[$k]; $fb; $lw; .st) as $r | .v[$k] = $r.v | .st = $r.st
        else
          .v[$k] = $b[$k]
          | .st.src[$c] = $fb
          | .st.rep += ["added " + $c + " (from " + $fb + ")"]
          | .st.rep += [leaves($c; $b[$k]) | select(issec(.[0])) | "note: " + $fb + " sets security key " + .[0]]
        end)
  elif $a == $b then {v: $a, st: $st}
  elif namelist($p) and ($a | isarr) and ($b | isarr) and ($b | length) > 0 then
    mergelist($p; $a; $b; $fb; $lw; $st)
  else
    findsrc($st.src; $p) as $fa
    | (issec($p) or issecanc($p)) as $s
    | if $s and ($lw | not) then
        {v: $a, st: ($st | .err += ["refused: " + $fb + " changes security key " + $p + " (" + $fa + ": " + showv($p; $a) + "; " + $fb + ": " + showv($p; $b) + "). Give --later-wins to take the later value."])}
      else
        {v: $b, st: ($st | .src[$p] = $fb | .rep += [leafline($p; $a; $b; $fa; $fb)])}
      end
  end;

[.[] | if .doc == null then .doc = {} else . end] as $fs
| [$fs[] | select(.doc | isobj | not) | .file + ": the top level of a values file must be a mapping"] as $e0
| if ($e0 | length) > 0 then {result: null, report: [], errors: $e0}
  else
    ($fs | map(prep(.doc; .file) as $p | {file: .file, doc: $p.v, err: $p.err})) as $ps
    | ([$ps[].err[]]) as $e1
    | (reduce $ps[1:][] as $nx ({v: $ps[0].doc, st: {src: {"": $ps[0].file}, rep: [], err: []}};
        merge(""; .v; $nx.doc; $nx.file; $lw; .st) as $r | .v = $r.v | .st = $r.st))
    | {result: .v, report: .st.rep, errors: ($e1 + .st.err)}
  end
JQ

RESULT=$(printf '%s' "$INPUT" | jq -s -c --argjson lw "$LATER_WINS" "$PROGRAM") || die2 "internal error while merging (jq failed)"

printf '%s' "$RESULT" | jq -r '.report[] | "compose: " + .' >&2
if [ "$(printf '%s' "$RESULT" | jq '.errors | length')" -gt 0 ]; then
  printf '%s' "$RESULT" | jq -r '.errors[] | "compose: " + .' >&2
  echo "compose: refused, nothing was written. Fix the files, or give --later-wins where you mean the later file to win." >&2
  exit 1
fi

echo "# Composed by hack/compose-values.sh. Input files, in order (a later file wins):"
n=0; for f in "${FILES[@]}"; do n=$((n+1)); echo "#   $n. $f"; done
echo "# Read the report (it went to standard error) and this file before you install it."
printf '%s' "$RESULT" | jq -c '.result' | yq -y .
