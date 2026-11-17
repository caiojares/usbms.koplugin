#!/bin/sh
# Read-only PW5 pre-check for usbms.koplugin: changes nothing, mounts nothing, writes nothing but
# stdout. Run it from a terminal/KUAL while KOReader is running with the framework stopped, and send
# the output if "USB storage" fails. Usage: sh usbms_check.sh
LOOP_SYS=/sys/block/loop0/loop
echo "== gadget"
for f in /sys/devices/platform/*/gadget/lun0/file /sys/devices/platform/*/gadget/gadget-lun0/file; do
    [ -e "$f" ] && echo "LUN: $f = [$(cat "$f" 2>&1)]"
done
for f in /sys/class/udc/*/state; do [ -e "$f" ] && echo "UDC state: $f = [$(cat "$f" 2>&1)]"; done
echo "removable: $(cat /sys/module/g_mass_storage/parameters/removable /sys/module/g_file_storage/parameters/removable 2>/dev/null | tr '\n' ' ')"
echo "== userstore"
dev=$(cat "$LOOP_SYS/backing_file" 2>/dev/null)
off=$(cat "$LOOP_SYS/offset" 2>/dev/null)
echo "loop0 backing_file=[$dev] offset=[$off]"
grep -E '/mnt/(us|base-us)|loop' /proc/mounts
echo "== first sector of $dev (MBR expected: 55 aa at 0x1f0, LBA at 0x1c0)"
[ -n "$dev" ] && hexdump -C -n 512 "$dev" 2>&1 | sed -n '28,33p'
echo "== first sector of /dev/loop/0 (FAT32 expected)"
hexdump -C -n 96 /dev/loop/0 2>&1 | head -6
echo "== powerd"
echo "isCharging=$(lipc-get-prop com.lab126.powerd isCharging 2>&1)"
echo "framework: $(status lab126_gui 2>&1)"
echo "volumd: $(grep '^State' /proc/$(pidof volumd | cut -d' ' -f1)/status 2>&1)"
echo "== kdb"
kdb get system/daemon/volumd/MOUNTED_VOLUME_NAME 2>&1
kdb get system/daemon/volumd/SYS_MOUNT_FILE_NAME 2>&1
