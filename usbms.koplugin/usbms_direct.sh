#!/bin/sh
# usbms.koplugin direct helper: exports the userstore without the Amazon framework.
#
# PW5 (Kindle Paperwhite 11th gen, MediaTek, kernel 4.9.77-lab126) port. Does what volumd does:
# g_mass_storage is loaded at boot with removable=Y, so exporting is writing the userstore device to
# the LUN after unmounting the vfat on /mnt/base-us. The userstore is /dev/mmcblk0p10 here, reached
# through /dev/loop/0 with an 8192-byte offset; the helper reads that from sysfs instead of assuming
# it. The fuse proxy on /mnt/us stays mounted throughout (as traced on the PW2; unverified on PW5:
# if umount is refused, the helper logs the holders and hands control back untouched).
#
# main.lua copies this to /var/tmp, starts it detached, waits for the ready file and quits KOReader
# with 85. We SIGSTOP koreader.sh first, so it cannot restart KOReader while the drive is exported,
# and SIGCONT it after safe recovery: its loop restarts KOReader, with the framework still down.
#
# Safety rules, in order of importance:
#   - No module, upstart job or rootfs file is changed. Host writes and filesystem repair can
#     change user data; a reboot does not undo those changes.
#   - Nothing changes until every pre-flight check passes: a mismatch means "not the firmware this
#     was written for", and we hand control back untouched.
#   - The vfat is never unmounted lazily. If anything still uses it, we give up.
#   - Export requires the supported mount layout; remount requires confirmed gadget release.
#
# Usage: usbms_direct.sh READER_PID KOSH_PID TOKEN HOST_TIMEOUT FSCK(auto|always)

READER_PID=$1
KOSH_PID=$2
TOKEN=$3
HOST_TIMEOUT=${4:-30}
FSCK_MODE=${5:-auto}

WORK=/var/tmp/usbms-koplugin
# /var/local is persistent (ext3), so the log survives the reboot that a stuck session needs.
LOG=/var/local/usbms-koplugin.log
LOCK="$WORK/lock"
PIDFILE="$WORK/helper.pid"
READY="$WORK/ready"
RESULT="$WORK/result"
FBINK="$WORK/fbink"
FONT="$WORK/NotoSans-Regular.ttf"
# Screen texts in KOReader's language, written by main.lua (key=value lines).
SCREEN_TEXTS="$WORK/screen.txt"
HAL_EVENTS="$WORK/hal.events"

LOOP_DEV=/dev/loop/0
LOOP_SYS=/sys/block/loop0/loop
BASE_MP=/mnt/base-us

first_existing() {
    for f in "$@"; do
        [ -e "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}
# PW5 (mtu3): /sys/devices/platform/11211000.usb/gadget/lun0/file. PW2 (fsl): .../gadget-lun0/file.
LUN=$(first_existing /sys/devices/platform/*/gadget/lun0/file /sys/devices/platform/*/gadget/gadget-lun0/file)
# UDC state: not attached / powered / default / addressed / configured / suspended.
UDC_STATE=$(first_existing /sys/class/udc/*/state)
# The userstore partition is whatever backs the loop device volumd/mntus set up (mmcblk0p10 on PW5).
USERSTORE_DEV=$(cat "$LOOP_SYS/backing_file" 2>/dev/null)
LOOP_OFFSET=$(cat "$LOOP_SYS/offset" 2>/dev/null)
# What goes to the LUN; decided in pre-flight.
EXPORT_DEV=""

cd / || exit 1
trap '' HUP

# Drop every descriptor inherited from KOReader, so none of them pins a file on the userstore.
for fd in $(ls /proc/$$/fd 2>/dev/null); do
    [ "$fd" -gt 2 ] 2>/dev/null && eval "exec $fd>&-" 2>/dev/null
done

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

usb_state() { cat "$UDC_STATE" 2>/dev/null; }

# A computer has enumerated and configured the gadget (a plain charger never gets that far).
host_connected() {
    [ "$(usb_state)" = "configured" ] &&
        [ "$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)" = "1" ]
}

# Full-screen status in a ZenOS-like style: clean white page, one large round icon (ring or filled
# disc with a pictogram), a title and one quiet line of text, all centred. The PW2 version blitted raw
# 758x1024 framebuffer dumps; those do not fit the PW5 (1236x1648), and KOReader's fbink has no image
# support. So the artwork ships as vector outlines in usbms_art.ttf (made by tools/make_usbms_art.py),
# which fbink draws like a glyph: the same picture at any size, whatever the framebuffer format.
# Without that font the icon becomes a short word; without Noto Sans the text falls back to fbink's
# built-in font.
FB_W=1236
FB_H=1648
if [ -x "$FBINK" ]; then
    fb_info=$("$FBINK" -e 2>/dev/null)
    w=$(echo "$fb_info" | sed -n 's/.*viewWidth=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    h=$(echo "$fb_info" | sed -n 's/.*viewHeight=\([0-9][0-9]*\).*/\1/p' | head -n 1)
    [ -n "$w" ] && [ "$w" -ge 400 ] 2>/dev/null && FB_W=$w
    [ -n "$h" ] && [ "$h" -ge 400 ] 2>/dev/null && FB_H=$h
fi
ICON_FONT="$WORK/usbms_art.ttf"

# Icon per screen: name -> the font's private-use glyph (UTF-8).
icon_glyph() {
    case "$1" in
        usb-waiting)   printf '\356\200\200' ;;     # U+E000 ring + USB
        usb-active)    printf '\356\200\201' ;;     # U+E001 disc + USB
        usb-returning) printf '\356\200\202' ;;     # U+E002 ring + arrows
        usb-recovery)  printf '\356\200\203' ;;     # U+E003 ring + exclamation mark
    esac
}
icon_word() {
    case "$1" in
        usb-waiting)   echo "USB" ;;
        usb-active)    echo "USB" ;;
        usb-returning) echo "..." ;;
        usb-recovery)  echo "!" ;;
    esac
}

screen() {
    name=$1; title=$2; text=$3
    log "screen $name (${FB_W}x${FB_H})"
    if [ -x "$FBINK" ]; then "$FBINK" -q -c -f > /dev/null 2>&1; else eips -c; fi
    if [ ! -x "$FBINK" ]; then
        eips 2 20 "$title" > /dev/null 2>&1
        eips 2 22 "$text" > /dev/null 2>&1
        return 0
    fi
    margin=$((FB_W / 12))
    # 1. The icon, in the upper part of the page.
    icon_px=$((FB_W * 32 / 100))
    icon_top=$((FB_H * 20 / 100))
    glyph=$(icon_glyph "$name")
    if [ -n "$glyph" ] && [ -f "$ICON_FONT" ] && \
        "$FBINK" -q -O -m -t "regular=$ICON_FONT,px=$icon_px,top=$icon_top,left=$margin,right=$margin" -- "$glyph" > /dev/null 2>&1; then
        :
    elif [ -f "$FONT" ]; then
        "$FBINK" -q -O -m -t "regular=$FONT,px=$((icon_px / 2)),top=$((icon_top + icon_px / 4)),left=$margin,right=$margin" -- "$(icon_word "$name")" > /dev/null 2>&1
    fi
    # 2. Title, then one line of text, below the icon.
    title_px=$((FB_W / 13))
    text_px=$((FB_W / 24))
    title_top=$((FB_H * 52 / 100))
    text_top=$((title_top + title_px * 2))
    if [ -f "$FONT" ]; then
        "$FBINK" -q -O -m -t "regular=$FONT,px=$title_px,top=$title_top,left=$margin,right=$margin" -- "$title" > /dev/null 2>&1
        "$FBINK" -q -O -m -t "regular=$FONT,px=$text_px,top=$text_top,left=$margin,right=$margin" -- "$text" > /dev/null 2>&1
    else
        "$FBINK" -q -m -S 3 -y 20 -- "$title" > /dev/null 2>&1
        "$FBINK" -q -m -S 2 -y 24 -- "$text" > /dev/null 2>&1
    fi
}

# Screen texts: main.lua's translation when there is one, English otherwise.
msg() {
    v=$(sed -n "s/^$1=//p" "$SCREEN_TEXTS" 2>/dev/null | head -n 1)
    if [ -n "$v" ]; then echo "$v"; return; fi
    case "$1" in
        waiting_title)   echo "USB mode" ;;
        waiting_text)    echo "Connect the cable to a computer." ;;
        active_title)    echo "USB storage active" ;;
        active_text)     echo "Eject the Kindle on the computer to return to KOReader." ;;
        returning_title) echo "USB mode" ;;
        returning_text)  echo "Returning to KOReader..." ;;
        recovery_title)  echo "USB recovery required" ;;
        recovery_text)   echo "Unplug USB and hold power for 40 s." ;;
    esac
}

base_mounted() { grep -q " $BASE_MP " /proc/mounts; }
userstore_mounted_anywhere() {
    mount_table=$(cat /proc/mounts) || return 0
    printf '%s\n' "$mount_table" | grep -q -E "^($LOOP_DEV|$USERSTORE_DEV) |^[^ ]+ [^ ]+ vfat "
}

reader_accessible() { [ -r /mnt/us/koreader/reader.lua ]; }

lun_empty() {
    lun_value=$(cat "$LUN" 2>/dev/null) || return 1
    [ -z "$lun_value" ]
}

release_lun() {
    printf '\n' > "$LUN" || return 1
    lun_empty
}

EXPORT_ATTEMPTED=0
NEEDS_FSCK=0
RECOVERY_BLOCKED=0
RECOVERY_RESULT=fail

restore_userstore() {
    if [ "$EXPORT_ATTEMPTED" = 1 ]; then
        release_lun || { log "cannot confirm LUN release"; return 1; }
        EXPORT_ATTEMPTED=0
    fi
    [ "$RECOVERY_BLOCKED" = 0 ] || return 1
    RECOVERY_BLOCKED=1
    sync
    if [ "$NEEDS_FSCK" = 1 ]; then
        RECOVERY_RESULT=fsckfail
        mntus --fsck mount >> "$LOG" 2>&1 || return 1
        NEEDS_FSCK=0
        RECOVERY_RESULT=fail
    fi
    mount_attempt=0
    while ! base_mounted && [ "$mount_attempt" -lt 3 ]; do
        if ! mntus mount >> "$LOG" 2>&1; then
            base_mounted && return 1
        fi
        mount_attempt=$((mount_attempt + 1))
        base_mounted || sleep 2
    done
    base_mounted && reader_accessible || return 1
    RECOVERY_BLOCKED=0
}

# "pid starttime" for every process under PID, from /proc/*/stat in one pass. comm can hold
# spaces, so fields are counted from the last ") ". starttime lets us tell a reused pid apart.
descendants() {
    cat /proc/[0-9]*/stat 2>/dev/null | awk -v root="$1" '
        { s = $0; sub(/.*\) /, "", s); split(s, f, " "); parent[$1] = f[2]; start[$1] = f[20] }
        END {
            for (p in parent) {
                q = parent[p]
                while (q != "" && q != 0 && q != 1) {
                    if (q == root) { print p, start[p]; break }
                    q = parent[q]
                }
            }
        }'
}

starttime() {
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    s=${s##*) }
    echo "$s" | cut -d' ' -f20
}

holders() {
    for p in /proc/[0-9]*; do
        n=$(ls -l "$p/cwd" "$p/fd" 2>/dev/null | grep -c -E '/mnt/(us|base-us)')
        m=$(grep -c -E '/mnt/(us|base-us)' "$p/maps" 2>/dev/null)
        [ "${n:-0}" -gt 0 ] || [ "${m:-0}" -gt 0 ] || continue
        echo "${p#/proc/} $(tr '\0' ' ' < "$p/cmdline" | cut -c1-80) [fd/cwd:$n maps:$m]"
    done
}

fail() {
    # $1 result code for main.lua, rest: log message. Only used before anything changed, or after
    # finish() can undo it.
    code=$1; shift
    log "$*"
    # After a cancel, main.lua has already told the user; a result would come up again later.
    if cancelled; then rm -f "$RESULT"; else echo "$code" > "$RESULT"; fi
    exit 1
}

cancelled() {
    [ "$(cat "$LOCK/token" 2>/dev/null)" != "$TOKEN" ] || [ -f "$LOCK/cancel" ]
}

[ -n "$TOKEN" ] && [ "$(cat "$LOCK/token" 2>/dev/null)" = "$TOKEN" ] || exit 1
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$READER_PID" ] || exit 1
trap 'rm -rf "$LOCK"; rm -f "$PIDFILE"' EXIT
cancelled && exit 1
echo $$ > "$LOCK/pid" || exit 1
echo $$ > "$PIDFILE" || exit 1
: > "$LOG"
log "direct: reader=$READER_PID koreader.sh=$KOSH_PID host_timeout=${HOST_TIMEOUT}s fsck=$FSCK_MODE"
echo "fail" > "$RESULT"

# ---- Pre-flight: nothing has changed yet. Any surprise means hands off.
check() { # $1 message, rest: command
    m=$1; shift
    "$@" > /dev/null 2>&1 || fail precheck "precheck failed: $m"
}
kdb_is() { [ "$(kdb get "$1" 2>/dev/null)" = "$2" ]; }

check "parent $KOSH_PID is not koreader.sh" sh -c "tr '\0' ' ' < /proc/$KOSH_PID/cmdline | grep -q koreader.sh"
check "reader $READER_PID is not a child of $KOSH_PID" sh -c "[ \"\$(awk '/^PPid/{print \$2}' /proc/$READER_PID/status)\" = $KOSH_PID ]"
check "the Amazon framework is running" sh -c "status lab126_gui | grep -q 'stop/waiting'"
# koreader.sh SIGSTOPs volumd; a running volumd would react to the same USB events we do.
VOLUMD_PID=$(pidof volumd)
check "volumd is not stopped (state $(grep '^State' "/proc/$VOLUMD_PID/status" 2>/dev/null))" \
    sh -c "[ -z '$VOLUMD_PID' ] || grep -q '^State:.*T' /proc/$VOLUMD_PID/status"
# volumd's kdb keys differ between firmwares; they are logged for the record, not required.
log "kdb: MOUNTED_VOLUME_NAME=[$(kdb get system/daemon/volumd/MOUNTED_VOLUME_NAME 2>&1)] SYS_MOUNT_FILE_NAME=[$(kdb get system/daemon/volumd/SYS_MOUNT_FILE_NAME 2>&1)]"
check "no LUN file found under /sys/devices/platform/*/gadget" sh -c "[ -n '$LUN' ] && [ -w '$LUN' ]"
check "no UDC state file under /sys/class/udc" sh -c "[ -n '$UDC_STATE' ] && [ -r '$UDC_STATE' ]"
check "the LUN is unreadable or already exports a device" lun_empty
check "the gadget module is not removable" sh -c "grep -q Y /sys/module/g_mass_storage/parameters/removable || grep -q Y /sys/module/g_file_storage/parameters/removable"
check "$BASE_MP is not a vfat on $LOOP_DEV" grep -q "^$LOOP_DEV $BASE_MP vfat " /proc/mounts
check "$LOOP_DEV is not backed by an mmcblk partition (backing_file=[$USERSTORE_DEV])" \
    sh -c "case '$USERSTORE_DEV' in /dev/mmcblk[0-9]*p[0-9]*) exit 0 ;; esac; exit 1"
check "$USERSTORE_DEV is not a block device" test -b "$USERSTORE_DEV"
check "loop offset [$LOOP_OFFSET] is not a number" sh -c "case '$LOOP_OFFSET' in ''|*[!0-9]*) exit 1 ;; esac"
check "$USERSTORE_DEV is mounted directly" sh -c "! grep -q '^$USERSTORE_DEV ' /proc/mounts"
check "no mntus" test -x /usr/sbin/mntus
check "no dosfsck" sh -c "command -v dosfsck || [ -x /sbin/dosfsck ]"

# Which device goes to the LUN. The Kindle userstore partition normally holds an MBR (one FAT32
# entry at the loop offset) so a host sees a partitioned disk; volumd exports the partition. If the
# partition does not look like that, export the loop device (the FAT32 itself) instead, which every
# host mounts too. Either way the host never sees anything but the userstore.
mbr_matches_offset() {
    # Parsed from "hexdump -C" (the form known to work on this busybox): bytes 510-511 and the LBA
    # at 454-457 of the first entry sit on the lines at 0x1f0 and 0x1c0.
    mbr=$(hexdump -C -n 512 "$USERSTORE_DEV" 2>/dev/null | awk '
        $1 == "000001c0" { lba = $11 $10 $9 $8 }
        $1 == "000001f0" { sig = $16 $17 }
        END { print sig, lba }')
    sig=${mbr% *}
    lba_hex=${mbr#* }
    log "partition sector 0: signature=[$sig] first entry LBA=[0x$lba_hex]"
    [ "$sig" = "55aa" ] && [ -n "$lba_hex" ] && [ "$((0x$lba_hex * 512))" = "$LOOP_OFFSET" ]
}
if [ "$LOOP_OFFSET" = "0" ] || mbr_matches_offset; then
    EXPORT_DEV=$USERSTORE_DEV
else
    EXPORT_DEV=$LOOP_DEV
fi
log "export device: $EXPORT_DEV (partition=$USERSTORE_DEV loop_offset=$LOOP_OFFSET lun=$LUN udc_state=$UDC_STATE)"
log "mounts: $(grep -E '/mnt/(us|base-us)' /proc/mounts | tr '\n' ';')"
log "pre-flight ok"

# ---- Resume koreader.sh only after storage has been recovered.
finish() {
    [ -n "$HAL_PID" ] && kill "$HAL_PID" 2>/dev/null
    if ! restore_userstore; then
        echo "$RECOVERY_RESULT" > "$RESULT"
        log "RECOVERY STOPPED: unplug USB and reboot the Kindle (hold power 40 s)"
        screen usb-recovery "$(msg recovery_title)" "$(msg recovery_text)"
        rm -rf "$LOCK"
        rm -f "$PIDFILE"
        return 1
    fi
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    log "resuming koreader.sh"
    kill -CONT "$KOSH_PID" 2>/dev/null
    rm -rf "$LOCK"
    rm -f "$PIDFILE"
}
trap finish EXIT
trap 'exit 1' INT TERM

cancelled && fail fail "startup cancelled"
kill -STOP "$KOSH_PID" || fail fail "could not stop koreader.sh"
# Snapshot KOReader's children now: some (lipc-wait-event, subprocesses) outlive it.
OLD_TREE=$(descendants "$READER_PID")
# Tell main.lua it may quit now: koreader.sh cannot restart KOReader any more.
echo "$TOKEN" > "$READY" || fail fail "could not acknowledge startup"

# 1. Wait for KOReader to exit (zombie counts: its parent is stopped and cannot reap it yet).
n=0
while [ -d "/proc/$READER_PID" ] && ! grep -q '^State:.*Z' "/proc/$READER_PID/status" 2>/dev/null; do
    cancelled && fail fail "startup cancelled"
    [ "$n" -ge 120 ] && fail fail "KOReader did not exit within 60 s"
    usleep 500000
    n=$((n + 1))
done
log "KOReader exited"
# No suspend while the drive is exported: the host would see the Kindle vanish mid-write.
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null || fail fail "preventScreenSaver not set"

# 2. Stop what KOReader left behind, as long as each pid is still the process we saw.
echo "$OLD_TREE" | while read -r p st; do
    [ -n "$p" ] && [ "$p" != "$$" ] && [ "$(starttime "$p")" = "$st" ] && echo "$p $st"
done > "$WORK/leftovers"
leftovers=$(awk '{print $1}' "$WORK/leftovers" | tr '\n' ' ')
if [ -n "$leftovers" ]; then
    log "stopping leftovers: $leftovers"
    kill -TERM $leftovers 2>/dev/null
    sleep 2
    while read -r p st; do
        [ -n "$p" ] && [ "$(starttime "$p")" = "$st" ] && kill -KILL "$p" 2>/dev/null
    done < "$WORK/leftovers"
fi

# The waiting screen only makes sense when no computer is there yet; with the cable already in
# (the usual case, since the prompt appears on plug) it would be a pointless full-screen flash.
if ! host_connected; then
    screen usb-waiting "$(msg waiting_title)" "$(msg waiting_text)"
fi

# 3. Wait for a computer: the UDC reports a host once the cable carries data.
n=0
until host_connected; do
    if [ "$n" -ge "$HOST_TIMEOUT" ]; then
        log "no computer after ${HOST_TIMEOUT} s"
        echo "nohost" > "$RESULT"
        exit 0
    fi
    sleep 1
    n=$((n + 1))
done
log "computer connected"
lun_empty || fail fail "LUN is unreadable or no longer empty, refusing"

# 4. Unmount the vfat. Never lazily: if anything still holds it, give up and go back.
sync
if ! umount "$BASE_MP" 2>> "$LOG"; then
    log "userstore busy:"
    holders >> "$LOG"
    fail busy "unmount refused, nothing exported"
fi
# Belt and braces: the partition must not be reachable through any other mount before the host
# gets it. finish() remounts if we bail out here.
userstore_mounted_anywhere && fail busy "userstore still mounted elsewhere: $(grep -E "^($LOOP_DEV|$USERSTORE_DEV) " /proc/mounts | tr '\n' ';')"
log "userstore unmounted"

# 5. Export.
rm -f "$HAL_EVENTS"
lipc-wait-event -m com.lab126.hal usbPlugOut,usbUnconfigured > "$HAL_EVENTS" 2>/dev/null &
HAL_PID=$!
EXPORT_ATTEMPTED=1
NEEDS_FSCK=1
# The kernel may report the path it resolved (/dev/loop0 for /dev/loop/0), so only require non-empty.
if ! echo "$EXPORT_DEV" > "$LUN" || [ -z "$(cat "$LUN" 2>/dev/null)" ]; then
    fail fail "could not export $EXPORT_DEV"
fi
log "exported $EXPORT_DEV (LUN reads back: $(cat "$LUN" 2>/dev/null))"
screen usb-active "$(msg active_title)" "$(msg active_text)"

# 6. Wait for the end of the session. Only two things end it:
#    - the gadget closes the LUN: the host ejected (START STOP UNIT, or Lab126's idle-after-sync
#      heuristic for Windows "safely remove");
#    - the cable goes away: the UDC reads "not attached" twice in a row, or udev reports usbPlugOut.
#    usbUnconfigured alone is only logged: the gadget also sends it on bus suspend, when the host
#    may still hold the drive. A host that re-enumerates after an eject finds no medium, because
#    nothing exports it again.
reason=""
gone=0
noted=""
while [ -z "$reason" ]; do
    sleep 1
    state_value=$(cat "$UDC_STATE" 2>/dev/null) || fail fail "cannot read USB connection state"
    case "$state_value" in
        "not attached"|attached|powered) gone=$((gone + 1)) ;;
        "") fail fail "invalid USB connection state" ;;
        *) gone=0 ;;   # configured, suspended (host asleep), addressed, default, reconnecting
    esac
    lun_value=$(cat "$LUN" 2>/dev/null) || fail fail "cannot read LUN state"
    if [ "$gone" -ge 2 ] || grep -q 'usbPlugOut' "$HAL_EVENTS" 2>/dev/null; then
        reason=unplug
    elif [ -z "$lun_value" ] && [ "$gone" = "0" ]; then
        reason=eject
    elif [ -z "$noted" ] && grep -q 'usbUnconfigured' "$HAL_EVENTS" 2>/dev/null; then
        noted=1
        log "usbUnconfigured seen while the LUN is still exported, waiting on"
    fi
done
log "session ended: $reason ($(tr '\n' ' ' < "$HAL_EVENTS" 2>/dev/null))"

# 7. Take the medium away from the host before touching the filesystem again. Closing the backing
#    file makes the gadget fsync it.
release_lun || fail fail "could not release the USB medium"
EXPORT_ATTEMPTED=0
screen usb-returning "$(msg returning_title)" "$(msg returning_text)"
sync
echo 3 > /proc/sys/vm/drop_caches

# 8. Check (after an unclean end, or always if asked) and mount, as /usr/sbin/mntus does.
if [ "$reason" = "eject" ] && [ "$FSCK_MODE" != "always" ]; then NEEDS_FSCK=0; fi
restore_userstore || fail "$RECOVERY_RESULT" "could not safely recover the userstore"
log "userstore mounted"
echo "$reason" > "$RESULT"
exit 0
