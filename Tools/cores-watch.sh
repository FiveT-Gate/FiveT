#!/bin/sh
# Once a day (a LaunchAgent, installed by Tools/cores-watch-install.sh): looks up the newest releases of the
# programs FiveT bundles, tells you in a macOS notification when one is newer than the pinned version, and
# prepares + builds the update on branch cores-update (Tools/cores-prepare.sh). It never releases anything.
# No AI is involved: python3 and git only, so it costs nothing to run. The log is ~/Library/Logs/fivet/cores-watch.log.
# A new release line (OpenVPN 2.7 while FiveT is on 2.6) is notified once and left for a manual test.
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
REPO=${FIVET_REPO:-$(cd "$(dirname "$0")/.." && pwd)}
STATE="$HOME/Library/Application Support/fivet-cores"
# From the LaunchAgent this runs as a copy in $STATE/bin: macOS refuses background jobs the Documents folder,
# so it checks from the mirrored pins ($STATE/pins.json) and only notifies; preparing the update needs the repo.
CORES=${FIVET_CORES_PY:-$REPO/Tools/cores.py}
LOG="$HOME/Library/Logs/fivet/cores-watch.log"
mkdir -p "$STATE" "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"FiveT bundled programs\"" >/dev/null 2>&1 || true; log "notify: $1"; }

mkdir "$STATE/lock" 2>/dev/null || { log "another run is still going"; exit 0; }
trap 'rmdir "$STATE/lock"' EXIT
cd "$STATE" || exit 1

JSON=$(python3 -I "$CORES" check --json 2>>"$LOG"); rc=$?
case $rc in
  0|10) ;;
  *) log "lookup failed for some program (exit $rc); trying again tomorrow"; [ -z "$JSON" ] && exit 0 ;;
esac

# One line per thing worth knowing: "UPDATE <name> <from> <to>" or "LINE <name> <new line>"; each is notified once.
printf '%s' "$JSON" | python3 -I -c '
import json, sys
for r in json.load(sys.stdin):
    if r["status"] == "UPDATE": print("UPDATE|%s|%s|%s" % (r["name"], r["pinned"], r["latest"]))
    if r.get("newer_line"): print("LINE|%s|%s|%s" % (r["name"], r["pinned"], r["newer_line"]))
' > "$STATE/now.txt"
touch "$STATE/notified"
UPDATES=""
while IFS='|' read -r kind name from to; do
  grep -qxF "$kind|$name|$to" "$STATE/notified" && { [ "$kind" = UPDATE ] && UPDATES="yes"; continue; }
  if [ "$kind" = UPDATE ]; then
    if [ -r "$REPO/Tools/cores-prepare.sh" ]; then notify "$name $to is out (FiveT has $from). Preparing the update."
    else notify "$name $to is out (FiveT has $from). Ask Claude: update the bundled programs."; fi
    UPDATES="yes"
  else
    notify "$name has a new release line, $to (FiveT has $from). It needs a manual test; nothing was changed."
  fi
  echo "$kind|$name|$to" >> "$STATE/notified"
done < "$STATE/now.txt"

[ -z "$UPDATES" ] && { log "all current"; exit 0; }
[ -r "$REPO/Tools/cores-prepare.sh" ] || { log "the repository is not readable from here (macOS blocks background jobs in Documents): notified only"; exit 0; }
git -C "$REPO" rev-parse -q --verify refs/heads/main >/dev/null || { log "no main branch: cannot prepare"; exit 0; }

# Each set of updates is prepared once: the same set already prepared (or already failed) is not rebuilt every day.
# Delete the two marker files in $STATE, or run Tools/cores-prepare.sh by hand, to try again.
SET=$(grep '^UPDATE|' "$STATE/now.txt" | sort | tr '\n' ' ')
[ "$(cat "$STATE/prepared" 2>/dev/null)" = "$SET" ] && { log "already prepared: $SET"; exit 0; }
[ "$(cat "$STATE/failed" 2>/dev/null)" = "$SET" ] && { log "preparing this set failed before; not retrying: $SET"; exit 0; }

OUT=$("$REPO/Tools/cores-prepare.sh" 2>&1); prc=$?
printf '%s\n' "$OUT" | tail -n 25 >> "$LOG"
if [ $prc -eq 0 ]; then
  printf '%s' "$SET" > "$STATE/prepared"
  notify "Update prepared and built on branch cores-update: $(printf '%s' "$OUT" | sed -n 's/^PREPARED: //p' | sed 's/ (branch.*//'). Next: a real tunnel test, then release (ask Claude)."
elif [ $prc -eq 4 ]; then
  log "nothing to prepare"
else
  printf '%s' "$SET" > "$STATE/failed"
  notify "Preparing the update FAILED (exit $prc). See ~/Library/Logs/fivet/cores-watch.log."
fi
