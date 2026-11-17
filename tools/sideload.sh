#!/bin/bash
# Copy a Connect IQ .prg into GARMIN/APPS on a Garmin watch over USB (MTP), from macOS.
#
# macOS's camera daemon (ptpcamerad) grabs MTP devices as soon as they're plugged in, which stops
# libmtp opening a session. This pauses it (SIGSTOP; launchd would just restart it if killed) while
# copying, and resumes it on exit. If this script is ever killed hard: `pkill -CONT ptpcamerad`.
#
# Usage: tools/sideload.sh bin/Buff.prg     (needs `brew install libmtp`; `make sideload` runs it)
set -u
PRG="${1:?usage: tools/sideload.sh path/to/App.prg}"
DEST="/GARMIN/APPS"
WAIT_SECS="${WAIT_SECS:-240}"
SETTLE_SECS="${SETTLE_SECS:-15}"  # after the watch appears in MTP mode, before copying (6 was too short)
# Installs into a watch that was plugged in before this script started failed every
# time ("failed to open session"); plugging in while this waits (camera daemon already paused) works. So by default a
# watch that's already connected must be unplugged and plugged back in first. REPLUG=0 skips that.
REPLUG="${REPLUG:-1}"
GARMIN_VID=2334 # 0x091E

command -v mtp-sendfile >/dev/null || { echo "libmtp missing: brew install libmtp"; exit 1; }
[ -f "$PRG" ] || { echo "No such file: $PRG"; exit 1; }

limit() { perl -e 'alarm shift; exec @ARGV' "$@"; } # macOS has no `timeout`
pause() { perl -e 'select(undef, undef, undef, shift)' "$1"; }
# USB product ID of the attached Garmin, or empty. 3 = Garmin's own protocol (watch off/charging,
# or USB Mode set to "Garmin"); anything else is the watch's MTP mode (fēnix 8: 0x51B8).
garmin_pid() {
    ioreg -p IOUSB -l -w0 | grep -E '"idVendor"|"idProduct"' | paste - - |
        awk -v vid="$GARMIN_VID" '$NF == vid { print $4; exit }'
}

# A sideloaded app's System.println output goes to GARMIN/APPS/LOGS/<PRG name>.TXT, but only if that file exists.
# Best effort, after a successful copy: fetch the last run's log (the face's on-watch timings) next to the .prg,
# then remove it, or leave a fresh one with LOG=1.
collect_log() {
    local name dir
    name="$(basename "$PRG" .prg | tr '[:lower:]' '[:upper:]').TXT"
    dir="$(dirname "$PRG")"
    rm -f "$dir/watch-$name"
    # mtp-getfile only takes a file ID, so look it up in the watch's file list
    local id
    id=$(limit 120 mtp-files 2>/dev/null | awk -v n="$name" '/File ID:/ { id = $3 } $1 == "Filename:" && $2 == n { print id; exit }')
    [ -n "$id" ] && limit 30 mtp-getfile "$id" "$dir/watch-$name" >/dev/null 2>&1
    if [ -s "$dir/watch-$name" ]; then
        echo "  watch log from the last run: $dir/watch-$name ($(wc -l <"$dir/watch-$name" | tr -d ' ') lines)"
    fi
    limit 30 mtp-delfile -f "/GARMIN/APPS/LOGS/$name" >/dev/null 2>&1
    if [ "${LOG:-0}" = "1" ]; then   # logging costs a storage write per redraw: only on request
        printf 'log start\n' >"$dir/$name"
        if limit 30 mtp-sendfile "$dir/$name" /GARMIN/APPS/LOGS >/dev/null 2>&1; then
            echo "  timing log enabled: GARMIN/APPS/LOGS/$name (LOG=1)"
        fi
        rm -f "$dir/$name"
    else
        echo "  timing log off (LOG=1 make sideload to turn it on)"
    fi
}

trap 'pkill -CONT -x ptpcamerad 2>/dev/null' EXIT
trap 'exit 130' INT TERM HUP

log=$(mktemp -t sideload)
deadline=$((SECONDS + WAIT_SECS))
last_pid=""
need_unplug=0     # set after a failed session: don't retry (each retry resets the watch's USB) until it's replugged
echo "Copying $PRG -> $DEST"
pkill -STOP -x ptpcamerad 2>/dev/null
if [ -n "$(garmin_pid)" ] && [ "$REPLUG" = "1" ]; then
    echo "  >>> the watch is already plugged in: unplug it, wait 5 seconds, plug it back in (REPLUG=0 to skip)"
    need_unplug=1
else
    echo "  >>> plug the watch in now"
fi
while [ $SECONDS -lt $deadline ]; do
    pkill -STOP -x ptpcamerad 2>/dev/null
    pid=$(garmin_pid)
    if [ -z "$pid" ]; then
        if [ "$need_unplug" = "1" ]; then
            echo "  watch unplugged: plug it back in"
            need_unplug=0
        fi
        echo "  waiting for the watch on USB..."
        last_pid=""
        pause 2
        continue
    fi
    if [ "$need_unplug" = "1" ]; then   # still connected since before the replug was asked for
        pause 2
        continue
    fi
    if [ "$pid" = "3" ]; then
        [ "$last_pid" = "3" ] || echo "  watch is connected but not in MTP mode (switched off/charging, or USB Mode = Garmin)"
        last_pid=3
        pause 2
        continue
    fi
    if [ "$pid" != "$last_pid" ]; then
        echo "  watch connected in MTP mode (product $pid), letting it settle (${SETTLE_SECS}s)..."
        last_pid=$pid
        pause "$SETTLE_SECS"
        continue
    fi
    # Replace any earlier copy (nothing to delete on the first install, which is fine).
    limit 45 mtp-delfile -f "$DEST/$(basename "$PRG")" >/dev/null 2>&1
    limit 45 mtp-sendfile "$PRG" "$DEST" >"$log" 2>&1
    if grep -q "New file ID" "$log"; then
        echo "  done: $(grep 'New file ID' "$log")"
        rm -f "$log"
        collect_log
        exit 0
    fi
    echo "  attempt failed: $(grep -v -i serial "$log" | grep -i -E 'error|could not|no devices|unable' | head -1)"
    # Once the watch refuses a session it keeps refusing until it's replugged, and each retry resets its
    # USB, which can leave it stuck in charge-only mode. So wait for a replug instead of retrying.
    if grep -q "failed to open session" "$log"; then
        echo "  >>> unplug the watch, wait 5 seconds, plug it back in (if that fails too: restart the watch)"
        need_unplug=1
        last_pid=""
    fi
    pause 3
done
echo "Gave up after ${WAIT_SECS}s. Last output:"
grep -v -i serial "$log"
rm -f "$log"
exit 1
