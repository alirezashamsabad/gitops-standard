#!/usr/bin/env bash
# Every chart and every image is pinned to an exact version.
#
# A floating tag is a different render on every sync, and the failure it causes
# arrives on a day nobody changed anything -- which is the hardest kind to
# attribute. This is a separate gate from validate.py because it is the one an
# operator runs before a release, not on every edit.
set -uo pipefail
cd "$(dirname "$0")/.."
bad=0

note() { printf '  %-52s %s\n' "$1" "$2"; }

# The tag is what follows the LAST colon, and a colon is not always a tag
# separator: `host:5000/x` has one and no tag, which shows up as a `/` in what
# follows it.
tag_of() {
  case "$1" in
    *:*) t="${1##*:}"; case "$t" in */*) printf '' ;; *) printf '%s' "$t" ;; esac ;;
    *) printf '' ;;
  esac
}

echo "charts:"
while IFS= read -r f; do
  v=$(python3 -c "
import yaml,sys
d=yaml.safe_load(open('$f')) or {}
c=d.get('chart') or {}
print(c.get('version','') if isinstance(c,dict) else '')")
  [ -z "$v" ] && continue
  case "$v" in
    *[\*\^\~]*|latest|main|master|stable|"")
      note "$f" "NOT PINNED: $v"; bad=1 ;;
    *) note "$f" "$v" ;;
  esac
# The directories are listed only if they exist, rather than letting find fail
# and hiding the failure. A missing platform/ and an unreadable one are
# different things and only one of them is normal.
done < <(for d in platform tenants shared; do [ -d "$d" ] && find "$d" \( -name component.yaml -o -name config.yaml \) ; done | sort)

echo "images:"
while IFS= read -r f; do
  while IFS= read -r img; do
    case "$img" in
      *:latest|*:main|*:master|*:stable) note "$f" "NOT PINNED: $img"; bad=1 ;;
      # A placeholder is not a version. It reaches a cluster as ImagePullBackOff
      # and reads as a registry problem rather than an unfilled file.
      *SET-*) note "$f" "PLACEHOLDER, NOT FILLED IN: $img"; bad=1 ;;
      # v0.0.0 is an exact version and pinned is exactly what it is, which is
      # why this gate passed it. It is also the conventional "no build yet"
      # placeholder, and a workload set to sync one goes to ImagePullBackOff and
      # stays there. Pinned and real are different questions.
      *:v0.0.0*|*:0.0.0*) note "$f" "PLACEHOLDER VERSION: $img"; bad=1 ;;
      # A TAG WITH NO DIGIT IN IT IS A NAME, NOT A VERSION, and the list above
      # will always be one name short. `develop` is exactly as mutable as
      # `main` and was not on it; so are `alpine`, `edge`, `release` and every
      # other channel. A digest pin survives this -- the hex after sha256: is
      # full of digits.
      *:*) case "$(tag_of "$img")" in
             *[0-9]*) note "$f" "$img" ;;
             *) note "$f" "NOT A VERSION, A MOVING NAME: $img"; bad=1 ;;
           esac ;;
      *)   note "$f" "NO TAG: $img"; bad=1 ;;
    esac
  done < <(python3 -c "
import yaml
d=yaml.safe_load(open('$f')) or {}
for i in (d.get('images') if isinstance(d,dict) else d) or []:
    print(i)")
# platform ONLY, until now. A tenant workload that ships raw manifests carries
# an images.yaml for the same reason a component does, and this loop never
# opened one -- so the two redis folders' mirror lists were unchecked by the
# gate whose whole subject is whether an image is pinned.
done < <(for d in platform tenants shared; do
           [ -d "$d" ] && find "$d" -name images.yaml
         done | sort)

while IFS= read -r f; do
  t=$(python3 -c "
import yaml
d=yaml.safe_load(open('$f')) or {}
print((d.get('image') or {}).get('tag',''))")
  [ -z "$t" ] && continue
  case "$t" in
    latest|main|master|stable) note "$f" "NOT PINNED: $t"; bad=1 ;;
    v0.0.0*|0.0.0*) note "$f" "PLACEHOLDER VERSION: $t"; bad=1 ;;
    # Same rule as the images above, and this is the loop that matters most: it
    # reads the one line a pipeline writes. A branch tag here means the running
    # image changes without a commit, which is the one thing a GitOps repository
    # exists to prevent, and it would have arrived with the next service --
    # whose only tag in the registry today is `develop`.
    *[0-9]*) note "$f" "$t" ;;
    *) note "$f" "NOT A VERSION, A MOVING NAME: $t"; bad=1 ;;
  esac
done < <(for d in tenants shared; do [ -d "$d" ] && find "$d" -name config.yaml ; done | sort)

echo
[ "$bad" -eq 0 ] && echo "all pinned" || echo "SOMETHING IS NOT PINNED"
exit "$bad"
