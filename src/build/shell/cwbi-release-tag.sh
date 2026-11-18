#!/usr/bin/env bash
#
# Creates a CWBI release tag for an upstream GeoPrism Registry release.
#
# Upstream's release tag (e.g. 2.0.0) has the right version number but none of
# the CWBI changes, and the fork's master usually already contains upstream's
# "prepare for next development iteration" commit (e.g. 2.0.1-SNAPSHOT). This
# script builds the commit that's actually needed: the upstream release tag
# merged into the newest fork commit that doesn't yet contain any upstream
# commits from after that release. That commit is then tagged (e.g.
# 2.0.0-cwbi) and only the tag is pushed, so no branch is moved.
#
# Usage:
#   cwbi-release-tag.sh <upstream-version> [options]
#
# Options:
#   --base <commit>        Fork commit to merge into, instead of finding it automatically
#   --tag <name>           Tag to create (default: <upstream-version>-cwbi)
#   --dry-run              Do everything except push; the tag is left local only
#   --yes                  Push without asking for confirmation
#   --keep-on-conflict     On a merge conflict, leave the worktree in place to resolve by hand
#
# Environment overrides:
#   UPSTREAM_REMOTE (default: upstream)  remote for terraframe/geoprism-registry
#   FORK_REMOTE     (default: origin)    remote for the CWBI fork
#   FORK_BRANCH     (default: master)    fork branch to take CWBI changes from
#   UPSTREAM_BRANCH (default: master)    upstream branch releases are cut from
#

set -euo pipefail

UPSTREAM_REMOTE=${UPSTREAM_REMOTE:-upstream}
FORK_REMOTE=${FORK_REMOTE:-origin}
FORK_BRANCH=${FORK_BRANCH:-master}
UPSTREAM_BRANCH=${UPSTREAM_BRANCH:-master}

usage() { sed -n '3,/^$/s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }
die() { echo "ERROR: $*" >&2; exit 1; }

VERSION=""
BASE=""
TAG=""
DRY_RUN=false
ASSUME_YES=false
KEEP_ON_CONFLICT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE=${2:?--base needs a commit}; shift 2 ;;
    --tag) TAG=${2:?--tag needs a name}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --keep-on-conflict) KEEP_ON_CONFLICT=true; shift ;;
    -h|--help) usage 0 ;;
    -*) die "Unknown option: $1" ;;
    *) [ -z "$VERSION" ] || die "Unexpected argument: $1"; VERSION=$1; shift ;;
  esac
done

[ -n "$VERSION" ] || usage 1
TAG=${TAG:-$VERSION-cwbi}

cd "$(git rev-parse --show-toplevel)"

git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 || die "No '$UPSTREAM_REMOTE' remote. Add it with: git remote add $UPSTREAM_REMOTE git@github.com:terraframe/geoprism-registry.git"
git remote get-url "$FORK_REMOTE" >/dev/null 2>&1 || die "No '$FORK_REMOTE' remote."

echo "==> Fetching $FORK_REMOTE/$FORK_BRANCH and $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git fetch --quiet "$FORK_REMOTE" "$FORK_BRANCH"
git fetch --quiet --no-tags "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

# Fetch the upstream tag into its own namespace so it never collides with a
# local tag of the same name.
UPSTREAM_REF="refs/upstream-tags/$VERSION"
git fetch --quiet --no-tags "$UPSTREAM_REMOTE" "+refs/tags/$VERSION:$UPSTREAM_REF" \
  || die "Upstream tag '$VERSION' not found on $UPSTREAM_REMOTE."
RELEASE=$(git rev-parse "$UPSTREAM_REF^{commit}")

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "Tag '$TAG' already exists locally. Delete it first if you mean to recreate it: git tag -d $TAG"
fi
if git ls-remote --exit-code --tags "$FORK_REMOTE" "refs/tags/$TAG" >/dev/null 2>&1; then
  die "Tag '$TAG' already exists on $FORK_REMOTE."
fi

# A fork commit is a valid base if every upstream commit it contains is also
# in the release, i.e. its merge-base(s) with upstream are ancestors of the
# release commit.
is_clean_base() {
  local c=$1 mb
  for mb in $(git merge-base --all "$c" "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"); do
    git merge-base --is-ancestor "$mb" "$RELEASE" || return 1
  done
}

if [ -z "$BASE" ]; then
  echo "==> Finding newest $FORK_REMOTE/$FORK_BRANCH commit without post-$VERSION upstream changes"
  for c in $(git rev-list --first-parent "$FORK_REMOTE/$FORK_BRANCH"); do
    if is_clean_base "$c"; then BASE=$c; break; fi
  done
  [ -n "$BASE" ] || die "No suitable base commit found on $FORK_REMOTE/$FORK_BRANCH. Pass one with --base."
else
  BASE=$(git rev-parse --verify "$BASE^{commit}") || die "Unknown base commit."
  is_clean_base "$BASE" || echo "WARNING: base $BASE contains upstream commits from after $VERSION."
fi

echo "    upstream $VERSION: $(git log -1 --format='%h %s' "$RELEASE")"
echo "    fork base:      $(git log -1 --format='%h %s' "$BASE")"

if git merge-base --is-ancestor "$RELEASE" "$BASE"; then
  die "Base already contains upstream $VERSION; nothing to merge. Tag it directly if its version is right."
fi

WORKTREE=$(mktemp -d "${TMPDIR:-/tmp}/cwbi-release-XXXXXX")
cleanup() { git worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true; rm -rf "$WORKTREE"; }
trap cleanup EXIT

git worktree add --quiet --detach "$WORKTREE" "$BASE"

echo "==> Merging upstream $VERSION"
if ! git -C "$WORKTREE" merge --quiet --no-ff --no-edit -m "Merge upstream $VERSION for CWBI release" "$RELEASE"; then
  echo
  echo "MERGE CONFLICT. Conflicting files:"
  git -C "$WORKTREE" diff --name-only --diff-filter=U | sed 's/^/    /'
  echo
  echo "Nothing was tagged or pushed."
  if $KEEP_ON_CONFLICT; then
    trap - EXIT
    cat <<EOF

The merge has been left in $WORKTREE. To finish by hand:
    cd $WORKTREE
    # fix the files above, then:
    git add <files> && git commit --no-edit
    git tag -a $TAG -m "CWBI release of upstream $VERSION"
    git push $FORK_REMOTE refs/tags/$TAG
    cd - && git worktree remove $WORKTREE
To give up instead:
    git worktree remove --force $WORKTREE
EOF
  else
    echo "Re-run with --keep-on-conflict to resolve it by hand."
  fi
  exit 2
fi

MERGED=$(git -C "$WORKTREE" rev-parse HEAD)

echo "==> Verifying $(git rev-parse --short "$MERGED")"
POM_VERSION=$(git show "$MERGED:pom.xml" | grep -m1 -oP '(?<=<version>)[^<]+' || true)
UPSTREAM_POM_VERSION=$(git show "$RELEASE:pom.xml" | grep -m1 -oP '(?<=<version>)[^<]+' || true)
echo "    pom version: $POM_VERSION"
[ "$POM_VERSION" = "$UPSTREAM_POM_VERSION" ] || die "pom version '$POM_VERSION' doesn't match upstream $VERSION's '$UPSTREAM_POM_VERSION'."

echo "    files that differ from upstream $VERSION:"
git diff --stat "$RELEASE" "$MERGED" | sed 's/^/      /'

git tag -a "$TAG" "$MERGED" -m "CWBI release of upstream $VERSION"
echo "==> Created tag $TAG -> $(git rev-parse --short "$MERGED")"

if $DRY_RUN; then
  echo "Dry run: not pushing. Remove the local tag with: git tag -d $TAG"
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Push $TAG to $FORK_REMOTE? [y/N] " answer
  case "$answer" in
    y|Y|yes) ;;
    *) echo "Not pushed. The tag is local only; remove it with: git tag -d $TAG"; exit 0 ;;
  esac
fi

git push "$FORK_REMOTE" "refs/tags/$TAG"
echo "==> Pushed $TAG. Deploy with ref: $TAG"
