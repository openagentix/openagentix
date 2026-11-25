def typ: if .type == "array" then "array of " + (.items | typ) else (.type // "any") end;
def esc: gsub("\\|"; "\\|") | gsub("(?<u>https?://[^ )]+)"; "`" + .u + "`") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\n"; " ") | gsub(" +"; " ");
def limits: [
  (if .minLength != null then "min length \(.minLength)" else empty end),
  (if .maxLength != null then "max length \(.maxLength)" else empty end),
  (if .minimum != null then "min \(.minimum)" else empty end),
  (if .maximum != null then "max \(.maximum)" else empty end),
  (if .maxItems != null then "max \(.maxItems) items" else empty end),
  (if .pattern then "pattern `\(.pattern)`" else empty end),
  (if .enum then "one of " + (.enum | map("`\(.)`") | join(", ")) else empty end),
  (if .format then "format \(.format)" else empty end),
  (if .["x-kubernetes-list-type"] then "list type \(.["x-kubernetes-list-type"])" else empty end),
  ((.["x-kubernetes-validations"] // [])[] | "rule refuses with: \"\(.message)\"")
] | join("; ");
def rows($p; $req):
  (.properties // {}) | to_entries[] | . as $e | $e.value as $v | ($p + "." + $e.key) as $path
  | "| `\($path)` | \($v | typ) | \(if ($req | index($e.key)) then "yes" else "no" end) | \($v | limits | esc) | \($v.description // "" | esc) |",
    ($v | if .type == "array" and ((.items.properties // null) != null) then (.items | rows($path + "[]"; (.required // [])))
          elif .properties then rows($path; (.required // [])) else empty end);
