#!/usr/bin/env bash
# Carry the machine into a cluster repository, or start one from scratch.
#
# THE WHOLE DESIGN RESTS ON THIS AND IT WAS DONE BY HAND. Four paths are written
# once here and copied one way into every cluster repository; a cluster repository
# never edits them. That was the rule from the first day and the mechanism for it
# was `cp`, typed from memory, with nothing checking that the two copies actually
# matched afterwards. Two trees compared by eye diverge quietly.
#
#   ./hack/sync-machine.sh ../gitops-config-<cluster>            what would change
#   ./hack/sync-machine.sh ../gitops-config-<cluster> --write     change it
#   ./hack/sync-machine.sh ../gitops-config-<cluster> --genesis   create it
#
# It never commits. The commit is a human decision and its subject line has to be
# `Machine merge: <the same subject as the Machine commit>`, which is a sentence
# only the person who wrote the original can produce.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=$(pwd)

# The machine, as one list. docs/ is NOT here and that is the point: it is
# machine, it is checked by the gates, and it stays with the standard because it
# names incidents and internal process. docs/00-orientation.md says so.
MACHINE=(charts hack bootstrap README.md .gitlab-ci.yml .gitignore)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

DST=${1:-}
MODE=${2:-}
[ -n "$DST" ] || die "usage: $0 <path-to-cluster-repo> [--write|--genesis]"
case "$MODE" in ""|--write|--genesis) ;; *) die "unknown mode \`$MODE\`" ;; esac

command -v rsync >/dev/null || die "rsync is not installed, and this copies trees"

if [ "$MODE" = --genesis ]; then
  [ -e "$DST" ] && die "$DST already exists. --genesis creates a repository; use
  --write to update one that is there"
  mkdir -p "$DST" || die "could not create $DST"
  git -C "$DST" init -q || die "git init failed in $DST"
else
  [ -d "$DST/.git" ] || die "$DST is not a git repository. A machine merge is a
  commit in the cluster repository, so there has to be one. Use --genesis to
  create it"
  # A dirty target is the one case where copying destroys work. The product half
  # may be dirty -- that is the operator's own business -- but a dirty MACHINE
  # path means somebody edited the machine in the wrong repository, which is the
  # exact mistake this script exists to make unnecessary.
  # NOT `2>/dev/null`. A git that fails here and a machine that is clean both
  # produce an empty answer, and the script would then go on to overwrite files
  # whose state it never established. The gate in validate.py refused the first
  # version of this line for exactly that.
  if ! dirty=$(cd "$DST" && git status --porcelain -- "${MACHINE[@]}"); then
    die "git status failed in $DST, so whether the machine there has been edited
  is unknown. Nothing has been copied."
  fi
  if [ -n "$dirty" ]; then
    printf 'ERROR: the machine is modified in %s:\n\n' "$DST" >&2
    sed 's/^/  /' <<<"$dirty" >&2
    printf '\n  Those edits belong in the standard, not here: this script would\n'  >&2
    printf '  overwrite them and the change would be lost with no record of it.\n' >&2
    printf '  Commit or discard them there first.\n'                               >&2
    exit 1
  fi
fi

printf 'from  %s\n' "$SRC"
printf 'to    %s\n' "$DST"
[ "$MODE" = --write ] || [ "$MODE" = --genesis ] || printf '\nDRY RUN — nothing is written. Add --write.\n'
printf '\n'

# -c: compare by CONTENT, not by size and modification time. Without it the
# first run reported every file in hack/ as changed -- `>f..t......`, which means
# the timestamp differs and the bytes do not. A tool that lists six unchanged
# files as changed teaches its reader to skim the list, and the list is the only
# thing standing between a merge and an overwrite.
rsync_flags=(-a -c --omit-dir-times --itemize-changes)
[ "$MODE" = --write ] || [ "$MODE" = --genesis ] || rsync_flags+=(--dry-run)

# An itemize line beginning with a dot is rsync saying it is adjusting an
# attribute and transferring nothing. Those are not changes to report; a
# transfer (>f, <f), a new directory (cd) and a deletion are.
real_change() { grep -E '^(\*deleting|[<>c][fdLDS])' ; }

changed=0
for path in "${MACHINE[@]}"; do
  [ -e "$SRC/$path" ] || { printf '  --      %s is not in the standard\n' "$path"; continue; }
  if [ -d "$SRC/$path" ]; then
    raw=$(rsync "${rsync_flags[@]}" --delete "$SRC/$path/" "$DST/$path/")
  else
    # --delete is meaningless for a single file and would be read as a request to
    # delete whatever else is beside it.
    raw=$(rsync "${rsync_flags[@]}" "$SRC/$path" "$DST/$path")
  fi
  rc=$?
  [ "$rc" -eq 0 ] || die "rsync failed on $path (exit $rc)"
  # Prefixed with the top-level path. Without it `bootstrap` and the repository
  # root both reported a bare `README.md` and the two were indistinguishable.
  out=$(real_change <<<"$raw" | awk -v p="$path" \
        '{ code=$1; $1=""; sub(/^ /,""); if ($0 == "." || $0 == "./") next;
           printf "  %-11s %s\n", code, (p ~ /\./ ? p : p "/" $0) }')
  if [ -n "$out" ]; then
    changed=1
    printf '%s\n' "$out"
  else
    printf '  =           %s\n' "$path"
  fi
done

printf '\n'
if [ "$changed" -eq 0 ]; then
  echo "the machine in $DST is already identical to this one"
  exit 0
fi

if [ "$MODE" != --write ] && [ "$MODE" != --genesis ]; then
  echo "nothing was written. Run again with --write."
  exit 0
fi

cat <<'NEXT'
Written. Now, in the cluster repository:

  1. Run all four gates there. A machine change that is green here can still be
     refused there, because the gates read the product files this repository does
     not have. That has happened: eight refusals on one merge, from a check that
     was correct and a rule that was too narrow.

  2. Commit with the subject `Machine merge: ` followed by the SAME subject as
     the Machine commit here. The CI refuses a commit that mixes the two classes,
     and one subject per class is how the two halves stay traceable to each other.

  3. Nothing here is committed for you. That is deliberate.
NEXT
