#!/bin/sh
# usbms.koplugin framework helper (alternative method). main.lua copies it to /var/tmp and starts it detached, then quits KOReader.
#
# KOReader's koreader.sh SIGSTOPs volumd while KOReader runs, and on any exit code other than 85 it
# resumes volumd and restarts the Amazon framework. With the cable plugged into a computer, volumd
# then exports the userstore as usual (NiLuJe, koreader PR #3955, tested on a PW2). This helper
# waits for that USB session to start and end, then starts KOReader again.
#
# It must never touch /mnt/us while it waits: it runs from /var/tmp with / as its working directory,
# and holds no file under /mnt/us open, or volumd could not unmount the userstore.
#
# Usage: usbms_framework.sh READER_PID LAUNCH_FLAG AUTO_RETURN PLUG_TIMEOUT TOKEN

READER_PID=$1
LAUNCH_FLAG=${2:---framework_stop}
AUTO_RETURN=${3:-1}
PLUG_TIMEOUT=${4:-120}
TOKEN=$5

WORK=/var/tmp/usbms-koplugin
# /var/local is persistent (ext3), so the log survives the reboot that a stuck session needs.
LOG=/var/local/usbms-koplugin.log
PIDFILE="$WORK/helper.pid"
LOCK="$WORK/lock"
READY="$WORK/ready"
KOREADER_SH=/mnt/us/koreader/koreader.sh
# PW5 (mtu3) has no "connected" file next to the LUN; its UDC state says the same thing. The old
# fsl file (PW2) stays as a fallback.
CONNECTED=/sys/devices/platform/fsl-usb2-udc/gadget/connected
UDC_STATE=""
for f in /sys/class/udc/*/state; do
    [ -e "$f" ] && { UDC_STATE=$f; break; }
done
CLEAN_PATH=${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}

cd / || exit 1
trap '' HUP

# Drop every descriptor inherited from KOReader, so none of them pins a file on the userstore.
for fd in $(ls /proc/$$/fd 2>/dev/null); do
    [ "$fd" -gt 2 ] 2>/dev/null && eval "exec $fd>&-" 2>/dev/null
done

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

# Frontlight: read once KOReader has been told to quit, set to 0 while the drive is exported, put back
# when the session ends. Intensity only, raw powerd value. Every lipc call runs in the background so
# a slow or stuck powerd can never delay the helper or the USB session; failures only reach the log.
LIGHT_SAVED="$WORK/light.saved"
LIGHT_DIMMED=0
light_number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
light_save() {
    rm -f "$LIGHT_SAVED"
    li=$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null)
    light_number "$li" || { log "frontlight: flIntensity unavailable, leaving it alone"; return 0; }
    echo "$li" > "$LIGHT_SAVED"
    log "frontlight: saved intensity=$li"
}
light_off() {
    [ -s "$LIGHT_SAVED" ] || return 0
    LIGHT_DIMMED=1
    ( lipc-set-prop com.lab126.powerd flIntensity 0 > /dev/null 2>&1 & )
    log "frontlight: off"
}
light_restore() {
    [ "$LIGHT_DIMMED" = 1 ] || return 0
    LIGHT_DIMMED=0
    li=$(cat "$LIGHT_SAVED" 2>/dev/null)
    light_number "$li" || return 0
    ( lipc-set-prop com.lab126.powerd flIntensity "$li" > /dev/null 2>&1 & )
    log "frontlight: restored intensity=$li"
}

# volumd only unmounts the vfat on /mnt/base-us while exporting; the fuse proxy on /mnt/us stays
# mounted (traced on a PW2, FW 5.12.2.2), so that is the mount to watch.
userstore_mounted() { grep -q ' /mnt/base-us ' /proc/mounts; }

# The UDC's view of the cable: 1 with a computer, 0 without. Kindles whose UDC is not the fsl one
# have no such file and print "none": there, nothing tells a pulled cable from an idle host.
usb_state() {
    if [ -n "$UDC_STATE" ]; then
        # 1 once a computer has configured the gadget (or is asleep on it); 0 for no cable or a charger.
        case "$(cat "$UDC_STATE" 2>/dev/null)" in
            configured|suspended|addressed|default|reconnecting) echo 1 ;;
            *) echo 0 ;;
        esac
        return
    fi
    [ -e "$CONNECTED" ] || { echo none; return; }
    cat "$CONNECTED" 2>/dev/null
}

# Only reached with "none" when no USB session ever started, so no host is holding the drive.
safe_to_launch() {
    case "$(usb_state)" in 0|none) ;; *) return 1 ;; esac
    userstore_mounted && [ "$(lipc-get-prop com.lab126.volumd userstoreIsAvailable 2>/dev/null)" = "1" ]
}

# Any KOReader but the one we replaced, which may linger as a zombie for a moment.
koreader_running() {
    for p in $(pidof reader.lua 2>/dev/null); do
        [ "$p" != "$READER_PID" ] && return 0
    done
    return 1
}

cancelled() {
    [ "$(cat "$LOCK/token" 2>/dev/null)" != "$TOKEN" ] || [ -f "$LOCK/cancel" ]
}

# Once KOReader is gone, someone starting it by hand (from KUAL, say) makes this helper pointless,
# and launching it again would run a second copy.
superseded() {
    if koreader_running; then
        log "KOReader was started meanwhile, nothing left to do"
        exit 0
    fi
}

[ -n "$TOKEN" ] && [ "$(cat "$LOCK/token" 2>/dev/null)" = "$TOKEN" ] || exit 1
[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$READER_PID" ] || exit 1
trap 'light_restore; rm -rf "$LOCK"; rm -f "$PIDFILE"' EXIT
trap 'exit 1' INT TERM
cancelled && exit 1
echo $$ > "$LOCK/pid" || exit 1
echo $$ > "$PIDFILE" || exit 1
echo "$TOKEN" > "$READY" || exit 1

: > "$LOG"
log "start: reader=$READER_PID flag=$LAUNCH_FLAG auto_return=$AUTO_RETURN plug_timeout=${PLUG_TIMEOUT}s"
light_save
leaks=$(ls -l /proc/$$/fd 2>/dev/null | grep -c '/mnt/')
[ "$leaks" -gt 0 ] && log "warning: $leaks descriptors still point into /mnt"

launch_koreader() {
    if koreader_running; then
        log "KOReader is already running, not starting another one"
        return 0
    fi
    if ! safe_to_launch; then
        log "storage or USB state is not safe, staying in the Amazon UI"
        return 1
    fi
    if [ ! -x "$KOREADER_SH" ]; then
        log "no $KOREADER_SH, staying in the Amazon UI"
        return 1
    fi
    log "starting KOReader ($LAUNCH_FLAG)"
    # Clean environment: the one inherited from the old KOReader carries its launcher state.
    setsid=$(command -v setsid)
    ( env -i PATH="$CLEAN_PATH" $setsid "$KOREADER_SH" "$LAUNCH_FLAG" < /dev/null > /dev/null 2>&1 & )

    # If KOReader does not come up and nothing else owns the screen, bring the framework back.
    n=0
    while [ "$n" -lt 90 ]; do
        koreader_running && { log "KOReader is running"; return 0; }
        sleep 1
        n=$((n + 1))
    done
    if ! status lab126_gui 2>/dev/null | grep -q 'start/running'; then
        log "KOReader did not start, restarting the framework"
        start lab126_gui
    else
        log "KOReader did not start, the framework is up"
    fi
    return 1
}

# 1. Wait for KOReader to exit (main.lua quits right after starting us).
n=0
while [ -n "$READER_PID" ] && [ -d "/proc/$READER_PID" ] && ! grep -q '^State:.*Z' "/proc/$READER_PID/status" 2>/dev/null; do
    cancelled && exit 1
    if [ "$n" -ge 60 ]; then
        log "KOReader did not exit within 60 s, giving up"
        exit 1
    fi
    sleep 1
    n=$((n + 1))
done
log "KOReader exited; the launcher now resumes volumd and starts the framework"

# 2. Wait for volumd to unmount the userstore, which means the computer has the drive.
n=0
while userstore_mounted; do
    superseded
    if [ "$n" -ge "$PLUG_TIMEOUT" ]; then
        log "no USB session after ${PLUG_TIMEOUT} s (no computer connected?)"
        [ "$AUTO_RETURN" = "1" ] && launch_koreader
        exit 0
    fi
    sleep 1
    n=$((n + 1))
done
log "USB drive mode started after ${n} s"
[ "$AUTO_RETURN" = "1" ] || exit 0
if [ "$(usb_state)" = "none" ]; then
    log "this Kindle does not report the USB cable state, staying in the Amazon UI"
    exit 0
fi
# Only here: with auto-return off this helper leaves now and could never put the light back.
light_off

# 3. Wait for the session to end: eject or unplug makes volumd mount the userstore again. With the
#    cable still in, the host re-enumerates and volumd exports again a few seconds later, so
#    KOReader must not start until the cable is physically out. The UDC reports that. A copy can
#    take as long as it likes, so there is no timeout; KOReader started by hand ends the wait.
while ! userstore_mounted; do
    superseded
    sleep 2
done
log "userstore mounted again, waiting for the cable to be unplugged"
light_restore
while [ "$(usb_state)" != "0" ] || ! userstore_mounted; do
    superseded
    sleep 2
done
log "cable unplugged"

# 4. Let volumd and the framework finish with the userstore before stopping the framework again.
n=0
until [ "$(lipc-get-prop com.lab126.volumd userstoreIsAvailable 2>/dev/null)" = "1" ]; do
    [ "$n" -ge 30 ] && { log "userstore availability timed out, staying in the Amazon UI"; exit 1; }
    sleep 1
    n=$((n + 1))
done
sleep 5
# Last look: still mounted and still no host.
if ! userstore_mounted || [ "$(usb_state)" != "0" ]; then
    log "userstore or cable state changed again, staying in the Amazon UI"
    exit 0
fi
launch_koreader
