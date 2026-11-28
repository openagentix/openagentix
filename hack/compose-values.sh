#!/usr/bin/env bash
# compose-values.sh: merge Helm values files into one values file, by entry name (ADR 0026, E).
#
#   hack/compose-values.sh [--later-wins] [-o OUTPUT] [--] FILE [FILE...]
#   hack/compose-values.sh -o /tmp/bank-values.yaml components/quickstart/values.yaml examples/use-cases/bank/values.yaml
#   PROFILE=quickstart VALUES_FILE=/tmp/bank-values.yaml ./install.sh
#
# Helm replaces lists, so a values file that adds an agent has to restate every agent of the file before it. This helper does that merge
# for you and tells you what it did. It is a helper, not a chart contract: the chart and Helm do not change, and install.sh takes the
# output through VALUES_FILE as before. A later file wins, as with several -f flags. Without -o the composed file goes to standard
# output. With -o FILE it is written to FILE in one step (a temporary file, then a rename), and nothing is written when the compose is
# refused. The report always goes to standard error.
#
# The rules:
#   - Maps merge as Helm merges them. A scalar that a later file changes is reported on standard error with its path, the old and the
#     new value. The value under a key that names a Secret or a key (secret, token, password, credential, apiKey, ... *Key), or under
#     a parent with such a name, is never shown: only the path is. Numbers and labels such as tokenBudget.tokens and apiKeyLabel are shown.
#   - These lists are merged by the `name` of their entries: agents, schedules, governance.a2a.callers, gateway.models, mcp.servers,
#     mcp.endpoints, mcp.profiles; and networkPolicy.extraA2ACallers, whose entries are named by `namespace` (the namespaces that may call the
#     A2A gate: two use cases that send events each add their own). Entries keep the order of first appearance. Every entry that a later file adds is reported. The same
#     name with the same content is kept once. The same name with different content is REFUSED, with both file names, unless
#     --later-wins is given (then the later entry replaces it and each changed value is reported).
#   - Security keys: a later file may not change these without --later-wins: the allow lists of controlPlane.policy (allowedModels,
#     allowedProfiles, allowedSkills, egress, requireToolProfile, allowKnowledge, allowNotify, memory, allowedRuntimes, runtimes),
#     controlPlane.containerAgents.toolProfiles, networkPolicy.*, governance.a2a.enabled, mcp.virtual.incomingAuth.*,
#     mcp.virtual.codeMode.enabled, mcp.egress.allow, observability.capture.content, gateway.policy.* and the egress of every agent.
#     "Change" is measured against what the files before it give. When no earlier file sets the key, the base is the chart default
#     (charts/openagentix/values.yaml, read as an implicit first file): a later file that sets a security key to anything else is refused.
#     The first file is taken as it is. Allow lists are never joined: a union would widen access without anyone writing it down. With
#     --later-wins the later value replaces the earlier one, and the change is reported.
#   - Called out in the report as SECURITY-RELEVANT (not refused, because the key list above does not cover them): a caller rule
#     (governance.a2a.callers) or a namespace for the A2A gate (networkPolicy.extraA2ACallers) added by a later file, and a profile (mcp.profiles) with codeMode: true that a later file adds or turns on.
#   - Every other list is replaced by the later file, as Helm does, and reported. An explicit empty list (`agents: []`) is kept in the
#     output, and a later `[]` replaces an earlier list.
#   - The output starts with a comment that lists the input files. It needs jq and the Python yq (pip install yq==3.4.3), the same
#     as `make test-chart`.
#
# Exit codes: 0 composed; 1 refused (nothing is written); 2 usage error or a file that cannot be read or written.
# Environment: COMPOSE_CHART_VALUES names another chart values file as the base of the security key check (for tests).
#
# This script is not security relevant on its own. One note: a composed file can turn on what neither input shows alone.
# Read the report and the output before installing it.
set -euo pipefail

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die2() { echo "compose-values.sh: $*" >&2; exit 2; }
SELF=$(cd "$(dirname "$0")" && pwd)

LATER_WINS=false
OUT=""
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --later-wins) LATER_WINS=true ;;
    -o|--output) [ $# -ge 2 ] || die2 "$1 needs a file name (usage: compose-values.sh [--later-wins] [-o OUTPUT] [--] FILE [FILE...])"; OUT=$2; shift ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done; break ;;
    -*) die2 "unknown option: $1 (usage: compose-values.sh [--later-wins] [-o OUTPUT] [--] FILE [FILE...]; -h for help)" ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
[ "${#FILES[@]}" -gt 0 ] || die2 "usage: compose-values.sh [--later-wins] [-o OUTPUT] [--] FILE [FILE...]  (-h for help)"
for f in "${FILES[@]}" ${OUT:+"$OUT"}; do
  case "$f" in *$'\n'*) die2 "a file name with a newline is refused (it would break the header comment of the output)" ;; esac
done
command -v jq >/dev/null || die2 "jq is required"
command -v yq >/dev/null || die2 "yq is required (the Python jq wrapper: pip install yq==3.4.3)"
yq --version 2>&1 | grep -q '^yq 3\.' || die2 "yq must be the Python wrapper (kislyuk/yq 3.x), not another yq"
if [ -n "$OUT" ]; then
  [ -d "$(dirname "$OUT")" ] || die2 "the directory of the output file $OUT does not exist"
  [ ! -d "$OUT" ] || die2 "the output $OUT is a directory"
  for f in "${FILES[@]}"; do [ ! "$f" -ef "$OUT" ] || die2 "the output file $OUT is also an input file ($f); name another output"; done
fi

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# The chart defaults are the implicit base for the security keys that no earlier file sets.
BASE=${COMPOSE_CHART_VALUES:-$SELF/../charts/openagentix/values.yaml}
[ -f "$BASE" ] || die2 "cannot find the chart values $BASE: the chart defaults are the base that the security keys of a later file are compared with. Run the script from a checkout, or set COMPOSE_CHART_VALUES."
yq -c . "$BASE" > "$TMPD/base.json" 2> "$TMPD/yq.err" || die2 "cannot read the chart values $BASE: $(head -1 "$TMPD/yq.err")"

# Read every file as JSON: one {file, doc} line each. The stderr of yq stays out of the data.
INPUT=""
for f in "${FILES[@]}"; do
  [ -f "$f" ] || die2 "cannot read $f (no such file)"
  YF=$f; case "$f" in -*) YF=./$f ;; esac   # a name that starts with a dash is not an option of yq
  if ! DOCS=$(yq -c . "$YF" 2> "$TMPD/yq.err"); then die2 "$f is not valid YAML: $(head -1 "$TMPD/yq.err")"; fi
  [ "$(printf '%s\n' "$DOCS" | grep -c .)" -le 1 ] || die2 "$f has more than one YAML document"
  if [ -z "$DOCS" ]; then LINE=$(jq -cn --arg f "$f" '{file:$f, doc:null}'); else LINE=$(printf '%s\n' "$DOCS" | jq -c --arg f "$f" '{file:$f, doc:.}'); fi
  INPUT+="$LINE"$'\n'
done

read -r -d '' PROGRAM <<'JQ' || true
def namelists: ["agents","schedules","governance.a2a.callers","gateway.models","mcp.servers","mcp.endpoints","mcp.profiles","networkPolicy.extraA2ACallers"];
# the key that names an entry of a list: `name`, except for the namespaces that may call the A2A gate
def lkey($p): if $p == "networkPolicy.extraA2ACallers" then "namespace" else "name" end;
def secpfx: [
  "controlPlane.policy.allowedModels","controlPlane.policy.allowedProfiles","controlPlane.policy.allowedSkills",
  "controlPlane.policy.egress","controlPlane.policy.requireToolProfile","controlPlane.policy.allowKnowledge",
  "controlPlane.policy.allowNotify","controlPlane.policy.memory","controlPlane.policy.allowedRuntimes","controlPlane.policy.runtimes",
  "controlPlane.containerAgents.toolProfiles","networkPolicy","governance.a2a.enabled","mcp.virtual.incomingAuth",
  "mcp.virtual.codeMode.enabled","mcp.egress.allow","observability.capture.content","gateway.policy","agents[].egress"];
def isobj: type == "object";
def isarr: type == "array";
def pj($ps): $ps | join(".");
def cp($p; $k): if $p == "" then $k else $p + "." + $k end;
def norm: gsub("\\[[^\\]]*\\]"; "[]");
def namelist($p): any(namelists[]; . == $p);
def issec($p): ($p | norm) as $n | any(secpfx[]; . as $s | $n == $s or ($n | startswith($s + ".")) or ($n | startswith($s + "[")));
def issecanc($p): ($p | norm) as $n | any(secpfx[]; startswith($n + "."));
def parent: if test("(\\.[^.\\[]*|\\[[^\\]]*\\])$") then sub("(\\.[^.\\[]*|\\[[^\\]]*\\])$"; "") else "" end;
def findsrc($src; $p): if $src[$p] != null then $src[$p] elif $p == "" then ($src[""] // "?") else findsrc($src; ($p | parent)) end;
# A key that names a Secret or a key hides its value and the values below it. Budgets and labels are not secrets.
def hidekey($k): ($k | test("secret|token|password|passwd|credential|apikey|api[-_]key|private[-_]?key|key$"; "i")) and ((["tokenBudget","tokens","apiKeyLabel"] | index($k)) == null);
def showv($h; $v): if $h then "(value not shown)" else ($v | tojson) end;
def leaves($p; $v): if ($v | isobj) and ($v | length) > 0 then ($v | to_entries[] | leaves(cp($p; .key); .value)) else [$p, $v] end;
def leavesS($ps; $v): if ($v | isobj) and ($v | length) > 0 then ($v | to_entries[] | leavesS($ps + [.key]; .value)) else [$ps, $v] end;
def secflag($p): if issec($p) or issecanc($p) then " [security key]" else "" end;

def leafline($p; $a; $b; $fa; $fb; $h):
  (issec($p) or issecanc($p)) as $s
  | if ($a | isarr) and ($b | isarr) then
      if $s then "changed security key " + $p + ": " + showv($h; $a) + " -> " + showv($h; $b) + " (" + $fa + " -> " + $fb + ")"
      else "replaced list " + $p + " (" + ($a | length | tostring) + " -> " + ($b | length | tostring) + " entries" + (if ($b | length) == 0 then ", now empty" else "" end) + ") (" + $fa + " -> " + $fb + ")" end
    elif ($a | type) != ($b | type) then
      "replaced " + $p + ": " + ($a | type) + " -> " + ($b | type) + secflag($p) + " (" + $fa + " -> " + $fb + ")"
    else
      (if $s then "changed security key " else "changed " end) + $p + ": " + showv($h; $a) + " -> " + showv($h; $b) + " (" + $fa + " -> " + $fb + ")"
    end;

def diffrep($p; $a; $b; $fa; $fb; $h):
  if ($a | isobj) and ($b | isobj) then
    ([$a, $b | keys[]] | unique)[] as $k
    | cp($p; $k) as $c
    | ($h or hidekey($k)) as $h2
    | if ($a | has($k) | not) then "added " + $c + " (from " + $fb + ")" + secflag($c)
      elif ($b | has($k) | not) then "removed " + $c + " (by " + $fb + ")" + secflag($c)
      else diffrep($c; $a[$k]; $b[$k]; $fa; $fb; $h2) end
  elif $a == $b then empty
  else leafline($p; $a; $b; $fa; $fb; $h)
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
          if ($e | isobj | not) or (($e[lkey($lp)]?) | type) != "string" or $e[lkey($lp)] == "" then
            .err += [$f + ": an entry of " + $lp + " has no " + lkey($lp) + " (every entry of " + $lp + " needs a " + lkey($lp) + ", because the entries are merged by " + lkey($lp) + ")"]
          else
            $e[lkey($lp)] as $n
            | (.l | map(.[lkey($lp)]) | index($n)) as $i
            | if $i == null then .l += [$e]
              elif .l[$i] == $e then .
              else .err += [$f + ": refused: " + $lp + "[" + $n + "] appears twice in this file with different content. Remove one."] end
          end)) as $r
        | .err += $r.err | .v = (.v | setpath($path; $r.l))
      end);

# The namespaces an entry of networkPolicy.extraA2ACallers may not name: default, kube-*, openagentix-*, and every namespace value of the chart's own values
# (the platform namespaces, the same walk that the chart's endpoint check makes over its values; the chart defaults are the base here).
def platns: ([$base[0] | .. | objects | to_entries[] | select((.key | ascii_downcase | endswith("namespace")) and ((.value | type) == "string")) | (if .value == "" then "openagentix-system" else .value end)]
  + ["default", "kube-system", "kube-public", "kube-node-lease"]) | unique;
# A new entry of networkPolicy.extraA2ACallers is refused unless it is narrow (the chart admits the namespace's pods to the gate's ingress).
def xaerrs($e; $fb):
  ($e.namespace) as $n
  | ("refused: " + $fb + ": networkPolicy.extraA2ACallers[" + $n + "] ") as $w
  | ((($e | keys) - ["namespace", "podLabels"]) as $x | if ($x | length) > 0 then [$w + "has keys other than namespace and podLabels (" + ($x | join(", ")) + ")"] else [] end)
  + (if (($e.podLabels | type) != "object") or (($e.podLabels | length) == 0) then [$w + "needs podLabels that are a non-empty map: without them every pod of the namespace may call the gate"] else [] end)
  + (if $n == "default" or ($n | startswith("kube-")) or ($n | startswith("openagentix-")) or ((platns | index($n)) != null) then [$w + "names a platform or system namespace (default, kube-*, openagentix-* and the namespaces of the chart's values are refused)"] else [] end);

# Additions that the key list does not refuse but that a reader must see.
def addnotes($p; $e; $old; $fb):
  (if $p == "governance.a2a.callers" and $old == null then ["SECURITY-RELEVANT: " + $fb + " adds the caller rule " + $e.name + " (a caller rule decides who may ask which agent)"] else [] end)
  + (if $p == "networkPolicy.extraA2ACallers" and $old == null then ["SECURITY-RELEVANT: " + $fb + " admits the namespace " + $e.namespace + " to the A2A gate (a caller rule for it decides what it may ask)"] else [] end)
  + (if $p == "mcp.profiles" and ($e.codeMode == true) and (($old | .codeMode?) != true) then ["SECURITY-RELEVANT: " + $fb + " gives the profile " + $e.name + " code mode (codeMode: true), so a script can call its tools"] else [] end);

def mergelist($p; $a; $b; $fb; $lw; $st; $h):
  reduce $b[] as $e ({v: $a, st: $st};
    $e[lkey($p)] as $n
    | ($p + "[" + $n + "]") as $ep
    | ($h or hidekey($n)) as $h2
    | (.v | map(.[lkey($p)]) | index($n)) as $i
    | if $i == null then
        .v += [$e]
        | (if $p == "networkPolicy.extraA2ACallers" then (.st.err += xaerrs($e; $fb)) | (.st.xa += [$e.namespace]) else . end)
        | .st.src[$ep] = $fb
        | .st.rep += ["added " + $ep + " (from " + $fb + ")"]
        | .st.rep += addnotes($p; $e; null; $fb)
        | .st.rep += [leaves($ep; $e) | select(issec(.[0])) | "note: " + $fb + " sets security key " + .[0]]
      elif .v[$i] == $e then .
      else
        findsrc(.st.src; $ep) as $fa
        | if $lw then
            .st.rep += [diffrep($ep; .v[$i]; $e; $fa; $fb; $h2)]
            | .st.rep += addnotes($p; $e; .v[$i]; $fb)
            | .v[$i] = $e
            | .st.src[$ep] = $fb
          else
            .st.err += ["refused: " + $ep + " is in " + $fa + " and in " + $fb + " with different content (differs at: " + ([difflist($ep; .v[$i]; $e)] | join(", ")) + "). Give --later-wins to take the later one, or make the two the same."]
          end
      end);

def merge($ps; $a; $b; $fb; $lw; $st; $h):
  pj($ps) as $p
  | if ($a | isobj) and ($b | isobj) then
      reduce ($b | keys_unsorted[]) as $k ({v: $a, st: $st};
        ($ps + [$k]) as $cps
        | pj($cps) as $c
        | ($h or hidekey($k)) as $h2
        # networkPolicy is merged key by key even when no earlier file has it, so that extraA2ACallers (a list of namespaces, joined by namespace) is not
        # compared with the chart default as a whole; every other networkPolicy key is still a security key
        | if (.v | has($k)) or ($c == "networkPolicy" and ($b[$k] | isobj) and ($b[$k] | has("extraA2ACallers"))) then
            merge($cps; (if (.v | has($k)) then .v[$k] else {} end); $b[$k]; $fb; $lw; .st; $h2) as $r | .v[$k] = $r.v | .st = $r.st
          elif namelist($c) and ($b[$k] | isarr) then
            mergelist($c; []; $b[$k]; $fb; $lw; .st; $h2) as $r | .v[$k] = $r.v | .st = $r.st
          else
            .v[$k] = $b[$k]
            | .st.src[$c] = $fb
            | .st.rep += ["added " + $c + " (from " + $fb + ")"]
            # a security key that no earlier file sets: the base is the chart default
            | reduce leavesS($cps; $b[$k]) as [$lps, $lv] (.;
                pj($lps) as $lp
                | if issec($lp) and ($lp | contains("[") | not) then
                    (try ($base[0] | getpath($lps)) catch null) as $d
                    | if $d == $lv then .
                      else ($h2 or any($lps[]; hidekey(.))) as $hh
                        | (if $d == null then "(not set in the chart)" else showv($hh; $d) end) as $ds
                        | if $lw then .st.rep += ["changed security key " + $lp + ": " + $ds + " -> " + showv($hh; $lv) + " (chart default -> " + $fb + ")"]
                          else .st.err += ["refused: " + $fb + " sets security key " + $lp + " to " + showv($hh; $lv) + "; no earlier file sets it and the chart default is " + $ds + ". Give --later-wins to take the later value."] end
                      end
                  else . end)
          end)
    elif $a == $b then {v: $a, st: $st}
    elif namelist($p) and ($a | isarr) and ($b | isarr) and ($b | length) > 0 then
      mergelist($p; $a; $b; $fb; $lw; $st; $h)
    else
      findsrc($st.src; $p) as $fa
      | (issec($p) or issecanc($p)) as $s
      | if $s and ($lw | not) then
          {v: $a, st: ($st | .err += ["refused: " + $fb + " changes security key " + $p + " (" + $fa + ": " + showv($h; $a) + "; " + $fb + ": " + showv($h; $b) + "). Give --later-wins to take the later value."])}
        else
          {v: $b, st: ($st | .src[$p] = $fb | .rep += [leafline($p; $a; $b; $fa; $fb; $h)])}
        end
    end;

[.[] | if .doc == null then .doc = {} else . end] as $fs
| [$fs[] | select(.doc | isobj | not) | .file + ": the top level of a values file must be a mapping"] as $e0
| if ($e0 | length) > 0 then {result: null, report: [], errors: $e0}
  else
    ($fs | map(prep(.doc; .file) as $p | {file: .file, doc: $p.v, err: $p.err})) as $ps
    | ([$ps[].err[]]) as $e1
    | (reduce $ps[1:][] as $nx ({v: $ps[0].doc, st: {src: {"": $ps[0].file}, rep: [], err: []}};
        merge([]; .v; $nx.doc; $nx.file; $lw; .st; false) as $r | .v = $r.v | .st = $r.st))
    | . as $f
    # every namespace that a file admitted to the gate needs a caller rule for a ServiceAccount of that namespace in the composed result
    | ([($f.st.xa // [])[] | . as $n | select(((($f.v.governance.a2a.callers // []) | map(.serviceAccount.namespace?)) | index($n)) == null)
        | "refused: networkPolicy.extraA2ACallers[" + . + "] has no caller rule for a ServiceAccount of that namespace in the composed result (governance.a2a.callers): an admitted namespace that no rule names would only open the gate's ingress"]) as $e2
    | {result: $f.v, report: $f.st.rep, errors: ($e1 + $f.st.err + $e2)}
  end
JQ

RESULT=$(printf '%s' "$INPUT" | jq -s -c --argjson lw "$LATER_WINS" --slurpfile base "$TMPD/base.json" "$PROGRAM") || die2 "internal error while merging (jq failed)"

printf '%s' "$RESULT" | jq -r '.report[] | "compose: " + .' >&2
if [ "$(printf '%s' "$RESULT" | jq '.errors | length')" -gt 0 ]; then
  printf '%s' "$RESULT" | jq -r '.errors[] | "compose: " + .' >&2
  echo "compose: refused, nothing was written. Fix the files, or give --later-wins where you mean the later file to win." >&2
  exit 1
fi

{
  echo "# Composed by hack/compose-values.sh. Input files, in order (a later file wins):"
  n=0; for f in "${FILES[@]}"; do n=$((n+1)); echo "#   $n. $f"; done
  echo "# Read the report (it went to standard error) and this file before you install it."
  printf '%s' "$RESULT" | jq -c '.result' | yq -y .
} > "$TMPD/composed.yaml"

if [ -z "$OUT" ]; then
  cat "$TMPD/composed.yaml"
else
  # Written in one step: a temporary file next to the output, then a rename. A refusal never gets here.
  FINAL=$(mktemp "$(dirname "$OUT")/.compose.XXXXXX") || die2 "cannot write next to $OUT"
  if ! { cp "$TMPD/composed.yaml" "$FINAL" && chmod 644 "$FINAL" && mv -f "$FINAL" "$OUT"; }; then rm -f "$FINAL"; die2 "cannot write $OUT"; fi
  echo "compose: wrote $OUT" >&2
fi
