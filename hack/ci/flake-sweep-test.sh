#!/usr/bin/env bash
# Offline test of hack/ci/flake-sweep.sh (issue #194): a throwaway Go module with a test that fails 2 times in 20 must make the sweep
# fail and name the test; a module with steady tests must pass; a module that does not build must fail with a clear line.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
[ -x hack/ci/flake-sweep.sh ] || { echo "  FAIL hack/ci/flake-sweep.sh is missing or not executable"; exit 1; }
command -v go >/dev/null || { echo "  skip go is not installed"; exit 0; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

mod() { mkdir -p "$D/$1"; printf 'module example.test/%s\n\ngo 1.21\n' "$1" > "$D/$1/go.mod"; }

mod flaky
cat > "$D/flaky/flaky_test.go" <<'G'
package flaky

import "testing"

var n int

// fails on the 10th and the 20th run of a -count=20 sweep, so the failure is the same every time
func TestSometimes(t *testing.T) {
	n++
	if n%10 == 0 {
		t.Fatalf("run %d failed", n)
	}
}

func TestSteady(t *testing.T) {}
G

mod steady
cat > "$D/steady/steady_test.go" <<'G'
package steady

import "testing"

func TestOne(t *testing.T) {}
G

mod broken
printf 'package broken\n\nfunc F() int { return "x" }\n' > "$D/broken/broken.go"
printf 'package broken\n\nimport "testing"\n\nfunc TestF(t *testing.T) { F() }\n' > "$D/broken/broken_test.go"

out=$(hack/ci/flake-sweep.sh "$D/flaky" --count 20 --summary "$D/sum-flaky.md" 2>&1); rc=$?
t "flaky module: exit 1" "$rc" "1"
case "$out" in *"TestSometimes"*"2 of 20"*) t "flaky module: names the test and 2 of 20" ok ok;; *) t "flaky module: names the test and 2 of 20" "$out" "TestSometimes ... 2 of 20";; esac
case "$out" in *"TestSteady"*) t "flaky module: does not list the steady test" "listed" "not listed";; *) t "flaky module: does not list the steady test" ok ok;; esac
t "flaky module: summary file has the test" "$(grep -c TestSometimes "$D/sum-flaky.md")" "1"

out=$(hack/ci/flake-sweep.sh "$D/steady" --count 20 --summary "$D/sum-steady.md" 2>&1); rc=$?
t "steady module: exit 0" "$rc" "0"
case "$out" in *"no failing test"*) t "steady module: says no failing test" ok ok;; *) t "steady module: says no failing test" "$out" "no failing test";; esac

out=$(hack/ci/flake-sweep.sh "$D/broken" --count 2 --summary "$D/sum-broken.md" 2>&1); rc=$?
t "broken module: exit 1" "$rc" "1"
case "$out" in *"without a failing test"*) t "broken module: explains it" ok ok;; *) t "broken module: explains it" "$out" "go test failed without a failing test";; esac

hack/ci/flake-sweep.sh "$D/does-not-exist" >/dev/null 2>&1; t "missing module: exit 2" "$?" "2"
hack/ci/flake-sweep.sh --bogus >/dev/null 2>&1; t "unknown flag: exit 2" "$?" "2"
exit $F
