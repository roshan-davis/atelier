#!/bin/bash
# Post screenshots on a PR without using GitHub Actions storage (AGENTS.md "Screenshots in PRs").
#   Scripts/attach_screenshots.sh <pr-number> <head-sha> <image>...
# Copies the images to the pr-screenshots branch under pr-<n>/, pushes, and comments them on the
# PR. The images use blob ?raw=true links, which render for anyone who can see the repo. Creates
# the pr-screenshots branch (an orphan with no shared history) the first time. Run from any
# worktree of this repository; it uses a temporary worktree of its own and never touches the
# current checkout.
set -euo pipefail
[ $# -ge 3 ] || { echo "usage: $0 <pr> <head-sha> <image>..." >&2; exit 2; }
PR=$1; SHA=$2; shift 2
REPO=${ATELIER_REPO:-roshan-davis/atelier}
BRANCH=pr-screenshots
TOP=$(git rev-parse --show-toplevel)
WT=$(mktemp -d "${TMPDIR:-/tmp}/pr-screenshots.XXXXXX")
cleanup() { git -C "$TOP" worktree remove --force "$WT" 2>/dev/null || true; }
trap cleanup EXIT
for f in "$@"; do
  size=$(wc -c < "$f")
  [ "$size" -le 1048576 ] || echo "warning: $f is $((size / 1024)) KB; crop or scale it (AGENTS.md)" >&2
done
if git -C "$TOP" fetch -q origin "$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null; then
  git -C "$TOP" worktree add -q --detach "$WT" "origin/$BRANCH"
else
  git -C "$TOP" worktree add -q --detach "$WT"
  git -C "$WT" checkout -q --orphan "$BRANCH"
  git -C "$WT" rm -rq --cached . && git -C "$WT" clean -fdxq
fi
mkdir -p "$WT/pr-$PR"
for f in "$@"; do cp "$f" "$WT/pr-$PR/"; done
git -C "$WT" add "pr-$PR"
git -C "$WT" commit -q -m "Screenshots for PR #$PR at ${SHA:0:7}" || true
for i in 1 2 3 4; do
  git -C "$WT" push -q origin "HEAD:refs/heads/$BRANCH" && break
  sleep $((i * 2)); git -C "$WT" fetch -q origin "$BRANCH"; git -C "$WT" rebase -q FETCH_HEAD
done
BODY="**Screenshots** (head ${SHA:0:7}):"$'\n'
for f in "$@"; do
  n=$(basename "$f"); BODY+=$'\n'"**${n%.*}**"$'\n'"![${n%.*}](https://github.com/$REPO/blob/$BRANCH/pr-$PR/$n?raw=true)"$'\n'
done
gh pr comment "$PR" --repo "$REPO" --body "$BODY"
