#!/bin/sh
# Prepares an update of the programs FiveT bundles, without touching this working copy:
#   a separate worktree (../fiveT-cores) on branch cores-update, reset to main, then
#   1. Tools/cores.py bump       pins the newest release inside each core's line, verified by its signature/digests
#   2. builds the changed programs (the build scripts check versions, linkage and options themselves)
#   3. Xray only: Tools/test-xray-compat.py, every config shape FiveT writes, old Xray against the new
#   4. commits on cores-update
# Nothing is released: a real tunnel test and ./release.sh stay a human step (merge with
# `git merge --ff-only cores-update`). Run by cores-watch.sh; safe to run by hand. No AI.
# Exit 0 = prepared (the last line says what), 1 = a step failed, 4 = nothing to update.
set -eu -o pipefail
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
REPO=$(cd "$(dirname "$0")/.." && pwd)
WT=$(dirname "$REPO")/fiveT-cores
BR=cores-update

cd "$REPO"
git worktree prune
if [ -e "$WT/.git" ]; then
  git -C "$WT" reset -q --hard
  git -C "$WT" checkout -q -B "$BR" main
else
  git worktree add -q -B "$BR" "$WT" main
fi
cd "$WT"

echo "▸ pinning the newest releases"
python3 -I Tools/cores.py bump | tee build-bump.txt
if git diff --quiet; then
  rm -f build-bump.txt
  echo "nothing to update"
  exit 4
fi
CHANGED=$(git diff --name-only)

# Each script rebuilds only what its pins changed; OpenVPN links the OpenSSL pinned in the openfortivpn script.
case "$CHANGED" in *fetch-xray.sh*) echo "▸ Xray"; Tools/fetch-xray.sh;; esac
case "$CHANGED" in *build-openfortivpn.sh*) echo "▸ openfortivpn + OpenSSL"; Tools/build-openfortivpn.sh;; esac
case "$CHANGED" in *build-openvpn.sh*|*build-openfortivpn.sh*) echo "▸ OpenVPN"; Tools/build-openvpn.sh;; esac

# The Xray in this folder's main copy is the old one: the same config shapes must still be accepted.
if grep -q '^Xray.* -> ' build-bump.txt && [ -x "$REPO/build/xray/xray" ]; then
  echo "▸ Xray: every config shape FiveT writes, old against new"
  python3 -I Tools/test-xray-compat.py "$REPO/build/xray/xray" "$WT/build/xray/xray" "$WT/build/xray" | tail -3
fi

SUMMARY=$(grep -E ' -> ' build-bump.txt | sed 's/  verified by.*//' | tr -s ' ' | paste -sd, - | sed 's/,/, /g')
rm -f build-bump.txt
git add -A Tools
git commit -q -m "Update bundled programs: $SUMMARY

Prepared and built by Tools/cores-prepare.sh; versions pinned only after the project's own signature or
digests matched the download. Not yet tested with a real tunnel."
echo "PREPARED: $SUMMARY (branch $BR in $WT)"
