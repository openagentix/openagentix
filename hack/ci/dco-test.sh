#!/usr/bin/env bash
# Offline test of hack/ci/dco-check.sh: a temporary repository and a stubbed API (no network). Needs git, jq.
set -u
CHECK="$(cd "$(dirname "$0")" && pwd)/dco-check.sh"
F=0; t() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cd "$D" && git init -q . && git config user.name "Dev One" && git config user.email dev@example.org && git config commit.gpgsign false
git commit -q --allow-empty -m base; BASE=$(git rev-parse HEAD)
# run <label-less>: result of the check from BASE to HEAD with the stub API
run() { GITHUB_STEP_SUMMARY=/dev/null REPO=o/r GH_API="$D/api.sh" bash "$CHECK" "$BASE" HEAD >/dev/null 2>&1; echo $?; }
# stub: pulls/7 is merged as $MERGED_SHA; its commits are in $D/commits.json; anything else is a 404
cat > "$D/api.sh" <<'E'
#!/usr/bin/env bash
D=$(dirname "$0")
for a in "$@"; do case "$a" in
  repos/o/r/pulls/7)         jq -n --arg s "$(cat "$D/merged_sha")" '{merged:true,merge_commit_sha:$s}'; exit 0 ;;
  repos/o/r/pulls/7/commits) cat "$D/commits.json"; exit 0 ;;
esac; done
exit 1
E
chmod +x "$D/api.sh"
signed_commits='[{"commit":{"message":"feat: x\n\nSigned-off-by: Dev One <dev@example.org>","author":{"name":"Dev One","email":"dev@example.org"}},"parents":[{}]}]'
unsigned_commits='[{"commit":{"message":"feat: x","author":{"name":"Dev One","email":"dev@example.org"}},"parents":[{}]}]'
# GitHub-made squash commit: committer noreply@github.com, no trailer
squash() { GIT_COMMITTER_NAME=GitHub GIT_COMMITTER_EMAIL=noreply@github.com git commit -q --allow-empty -m "$1"; }

git commit -q --allow-empty -s -m "signed"
t "(a) a matching sign-off passes" "$(run)" 0
git commit -q --allow-empty -m "unsigned"
t "an unsigned commit fails" "$(run)" 1
git reset -q --hard HEAD~1
git commit -q --allow-empty --author="Other <other@example.org>" -s -m "wrong-author sign-off"  # signs as Dev One, author is Other
t "a sign-off that does not match the author fails" "$(run)" 1
git reset -q --hard HEAD~1
git commit -q --allow-empty --author="dependabot[bot] <49699333+dependabot[bot]@users.noreply.github.com>" -m "bump"
t "(c) a bot commit passes" "$(run)" 0
git reset -q --hard HEAD~1

squash "feat: thing (#7)"; echo "$signed_commits" > "$D/commits.json"; git rev-parse HEAD > "$D/merged_sha"
t "(d) a web-flow squash of a merged PR with signed commits passes" "$(run)" 0
echo "$unsigned_commits" > "$D/commits.json"
t "(d) fails when a commit inside the PR is unsigned" "$(run)" 1
echo "$signed_commits" > "$D/commits.json"; echo deadbeef > "$D/merged_sha"
t "(d) fails when the PR was merged as another commit" "$(run)" 1
git rev-parse HEAD > "$D/merged_sha"
t "(d) fails when the API is unreachable" "$(GITHUB_STEP_SUMMARY=/dev/null REPO=o/r GH_API=false bash "$CHECK" "$BASE" HEAD >/dev/null 2>&1; echo $?)" 1
git reset -q --hard HEAD~1
squash "feat: thing (#8)"
t "(d) fails for a PR number the API does not know" "$(run)" 1
git reset -q --hard HEAD~1
squash "feat: thing without a number"
t "(d) fails without a PR number in the title" "$(run)" 1
git reset -q --hard HEAD~1
git commit -q --allow-empty -m "feat: thing (#7)"   # committer is Dev One, not GitHub
git rev-parse HEAD > "$D/merged_sha"
t "(d) is only for commits GitHub made: a typed '(#7)' is not enough" "$(run)" 1
git reset -q --hard HEAD~1

git checkout -q -b side; git commit -q --allow-empty -s -m s1; git checkout -q -; git commit -q --allow-empty -s -m m1
git merge -q --no-ff -m "Merge side" side
t "(b) a merge commit needs no sign-off" "$(run)" 0
exit $F
