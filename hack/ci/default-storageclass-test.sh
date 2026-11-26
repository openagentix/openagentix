#!/usr/bin/env bash
# Tests for hack/default-storageclass.sh (SET_DEFAULT_STORAGECLASS, part of #31) with a fake `kubectl` (no cluster).
# The fake answers `get storageclass -o json` from a fixture, records every call with its context, and records a patch.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "\$*" >> "$D/calls"
case "\$*" in
  *"get storageclass -o json") [ -f "$D/sc.json" ] || exit 1; cat "$D/sc.json";;
  *" patch storageclass "*) [ ! -f "$D/patch-fails" ] || exit 1; echo patched;;
  *) echo "unexpected call: \$*" >&2; exit 1;;
esac
EOS
chmod +x "$D/bin/kubectl"
export KUBECTL="$D/bin/kubectl"
sc(){ printf '%s\n' "$1" > "$D/sc.json"; : > "$D/calls"; rm -f "$D/patch-fails"; }
run(){ KUBE_CONTEXT=${CTX-gke_p_z_c} bash hack/default-storageclass.sh "$@" 2>&1; }
writes(){ grep -c ' patch ' "$D/calls"; }
NONE='{"items":[{"metadata":{"name":"standard-rwo"}},{"metadata":{"name":"premium-rwo"}}]}'
STD_DEFAULT='{"items":[{"metadata":{"name":"standard-rwo","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}},{"metadata":{"name":"premium-rwo"}}]}'
BETA_DEFAULT='{"items":[{"metadata":{"name":"standard-rwo"}},{"metadata":{"name":"premium-rwo","annotations":{"storageclass.beta.kubernetes.io/is-default-class":"true"}}}]}'
PATCH="--context gke_p_z_c patch storageclass standard-rwo --type merge -p {\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}"

echo "# marks the class when none is default"
sc "$NONE"; OUT=$(run standard-rwo); RC=$?
t "exit 0" "$RC" 0
t "one patch, with the named context, merge type, the GA annotation" "$(grep ' patch ' "$D/calls")" "$PATCH"
t "every call names the context" "$(grep -vc '^--context gke_p_z_c ' "$D/calls")" 0
t "prints what it changed and how to undo it" "$OUT" "default StorageClass: marked standard-rwo as the default (annotation storageclass.kubernetes.io/is-default-class=true) in context gke_p_z_c. To undo: kubectl --context gke_p_z_c annotate storageclass standard-rwo storageclass.kubernetes.io/is-default-class-"

echo "# idempotent"
sc "$STD_DEFAULT"; OUT=$(run standard-rwo); RC=$?
t "already default: exit 0" "$RC" 0
t "already default: no write" "$(writes)" 0
t "already default: says so" "$OUT" "default StorageClass: standard-rwo is already the default in context gke_p_z_c. Nothing was changed."

echo "# refusals (nothing is changed)"
sc "$STD_DEFAULT"; OUT=$(run premium-rwo); RC=$?
t "another class is default: exit 1" "$RC" 1
t "another class is default: no write" "$(writes)" 0
t "another class is default: message" "$OUT" "ERROR: standard-rwo is already the default StorageClass in context gke_p_z_c; marking premium-rwo too would make two defaults. Nothing was changed. Leave SET_DEFAULT_STORAGECLASS unset, or remove the default mark from standard-rwo yourself first."
sc "$BETA_DEFAULT"; run standard-rwo >/dev/null; RC=$?
t "the beta annotation counts as a default" "$RC $(writes)" "1 0"
sc "$NONE"; OUT=$(run nope); RC=$?
t "a missing class: exit 1, no write" "$RC $(writes)" "1 0"
t "a missing class: message names the classes" "$OUT" "ERROR: no StorageClass nope in context gke_p_z_c (found: standard-rwo premium-rwo). Nothing was changed."
sc '{"items":[]}'; OUT=$(run nope)
t "no class at all" "$OUT" "ERROR: no StorageClass nope in context gke_p_z_c (found: none). Nothing was changed."
sc "$NONE"; rm -f "$D/sc.json"; OUT=$(run standard-rwo); RC=$?
t "storage classes cannot be read: exit 1, no write" "$RC $(writes)" "1 0"
t "with the message" "$OUT" "ERROR: cannot list the StorageClasses of context gke_p_z_c (kubectl --context gke_p_z_c get storageclass). Nothing was changed."
sc "$NONE"; touch "$D/patch-fails"; OUT=$(run standard-rwo); RC=$?
t "a failed patch: exit 1" "$RC" 1
t "with the message" "$OUT" "ERROR: kubectl could not mark standard-rwo as the default StorageClass in context gke_p_z_c."
for bad in 'Bad' 'a;b' '-x' 'a b' "\$(id)" "$(printf 'a%.0s' $(seq 1 254))"; do
  sc "$NONE"; OUT=$(run "$bad"); RC=$?
  t "an invalid name is refused before any call: '${bad:0:12}'" "$RC $(wc -l < "$D/calls" | tr -d ' ')" "2 0"
done
t "the invalid-name message" "$OUT" "ERROR: '$bad' is not a valid StorageClass name. Nothing was changed."
sc "$NONE"; OUT=$(CTX='' run standard-rwo); RC=$?
t "no KUBE_CONTEXT: exit 2, no call" "$RC $(wc -l < "$D/calls" | tr -d ' ')" "2 0"
t "with the message" "$OUT" "ERROR: hack/default-storageclass.sh needs KUBE_CONTEXT, the kubectl context of the cluster"
OUT=$(run); RC=$?
t "no name: exit 2" "$RC" 2
t "usage" "$OUT" "usage: KUBE_CONTEXT=<context> hack/default-storageclass.sh [--check] <storageclass>"

echo "# --check reads only and says what it would do"
sc "$NONE"; OUT=$(run --check standard-rwo); RC=$?
t "would mark: exit 0, no write" "$RC $(writes)" "0 0"
t "would mark: message" "$OUT" "default StorageClass: standard-rwo will be marked as the default in context gke_p_z_c (SET_DEFAULT_STORAGECLASS)."
sc "$STD_DEFAULT"; run --check premium-rwo >/dev/null; t "--check refuses the same way" "$? $(writes)" "1 0"
sc "$NONE"; run --check nope >/dev/null; t "--check refuses a missing class" "$? $(writes)" "1 0"

echo "# install.sh"
t "the opt-in is never implicit: only with SET_DEFAULT_STORAGECLASS set" "$(grep 'hack/default-storageclass.sh' install.sh | grep -vc 'SET_DEFAULT_STORAGECLASS:-')" 0
exit $F
