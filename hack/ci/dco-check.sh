#!/usr/bin/env bash
# DCO check for a pull request: dco-check.sh BASE HEAD   (env: REPO=owner/name; GH_API="gh api" or a test stub)
# A commit is accepted when
#   (a) it carries "Signed-off-by: <author name> <author email>" (case-insensitive), or
#   (b) it is a merge commit, or
#   (c) its author is a bot ("...[bot]@users.noreply.github.com"), or
#   (d) GitHub itself made it (committer noreply@github.com, i.e. a web-flow squash merge) and it is the merge commit of a
#       pull request of THIS repository, referenced as "(#N)" at the end of its title, whose own commits all pass (a), (b)
#       or (c). A squash commit made by GitHub may carry no sign-off line, but every commit inside the merged pull request
#       was checked when that pull request ran. (d) is verified read-only through the API (pulls/N: merged, and
#       merge_commit_sha equal to this commit; pulls/N/commits: each one signed off). If the API cannot answer, the commit
#       is NOT accepted. A message that merely says "(#N)" is not enough.
set -uo pipefail
BASE=$1; HEAD=$2
REPO=${REPO:-}
GH_API=${GH_API:-gh api}
bad=0; checked=0; report=$(mktemp)

# signed_off <message> <name> <email>: is there a matching Signed-off-by trailer in the message?
signed_off() {
  printf '%s\n' "$1" | git interpret-trailers --parse 2>/dev/null | tr 'A-Z' 'a-z' \
    | grep -Fqx -e "signed-off-by: $(printf '%s <%s>' "$2" "$3" | tr 'A-Z' 'a-z')"
}

# pr_verified <sha> <number>: rule (d), the whole check against the API
pr_verified() {
  local sha=$1 n=$2 pr commits i cnt msg an ae np
  [ -n "$REPO" ] || return 1
  pr=$($GH_API "repos/$REPO/pulls/$n" 2>/dev/null) || return 1
  [ "$(jq -r '.merged' <<<"$pr" 2>/dev/null)" = true ] || return 1
  [ "$(jq -r '.merge_commit_sha' <<<"$pr")" = "$sha" ] || return 1
  commits=$($GH_API --paginate "repos/$REPO/pulls/$n/commits" 2>/dev/null | jq -s 'add // empty' 2>/dev/null) || return 1
  cnt=$(jq 'length' <<<"$commits" 2>/dev/null) || return 1
  [ "${cnt:-0}" -gt 0 ] || return 1
  for ((i = 0; i < cnt; i++)); do
    msg=$(jq -r ".[$i].commit.message" <<<"$commits")
    an=$(jq -r ".[$i].commit.author.name" <<<"$commits")
    ae=$(jq -r ".[$i].commit.author.email" <<<"$commits")
    np=$(jq -r ".[$i].parents | length" <<<"$commits")
    [ "$np" -gt 1 ] && continue
    case "$ae" in *"[bot]@users.noreply.github.com") continue ;; esac
    signed_off "$msg" "$an" "$ae" || return 1
  done
}

while read -r sha; do
  email=$(git log -1 --format='%ae' "$sha"); name=$(git log -1 --format='%an' "$sha")
  subject=$(git log -1 --format='%s' "$sha"); cemail=$(git log -1 --format='%ce' "$sha")
  case "$email" in *"[bot]@users.noreply.github.com") continue ;; esac            # (c)
  checked=$((checked + 1))
  signed_off "$(git log -1 --format='%B' "$sha")" "$name" "$email" && continue    # (a)
  if [ "$cemail" = noreply@github.com ]; then                                     # (d)
    n=$(sed -nE 's/.*\(#([0-9]+)\)[[:space:]]*$/\1/p' <<<"$subject")
    if [ -n "$n" ] && pr_verified "$sha" "$n"; then continue; fi
  fi
  bad=$((bad + 1))
  echo "::error::Commit ${sha:0:12} (${subject}) has no 'Signed-off-by: ${name} <${email}>' line"
  printf -- '- `%s` %s (author: %s <%s>)\n' "${sha:0:12}" "${subject//\`/}" "$name" "$email" >> "$report"
done < <(git log --no-merges --format='%H' "${BASE}..${HEAD}")                  # (b): --no-merges

{
  echo "## DCO check"; echo
  if [ "$bad" -eq 0 ]; then
    echo "All ${checked} commit(s) are signed off, or are squash merges of pull requests whose commits were."
  else
    echo "${bad} of ${checked} commit(s) are missing a sign-off that matches the author:"; echo
    cat "$report"; echo
    echo "### How to fix"; echo
    echo "A sign-off says you wrote the change, or have the right to send it, under the project licence (Developer Certificate of Origin 1.1, https://developercertificate.org/). The line must be \`Signed-off-by: Your Name <your-address>\` and must match the commit author."; echo
    echo "- Last commit only: \`git commit --amend -s --no-edit\` then \`git push --force-with-lease\`"
    echo "- Every commit of the branch: \`git rebase --signoff main\` then \`git push --force-with-lease\`"
    echo "- Check your identity first: \`git config user.name\` and \`git config user.email\`"
    echo "- For the next commits, use \`git commit -s\`"; echo
    echo "See docs/contributing/workflow.md."
  fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
[ "$bad" -eq 0 ]
