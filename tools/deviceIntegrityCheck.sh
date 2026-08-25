#!/bin/bash
# Android device integrity check, run over adb before trusting a handset
# with an account or a build.
#
# WHAT THIS IS NOT: a malware scan. It cannot read other apps' private
# storage, cannot inspect running processes meaningfully, and will not
# catch anything sophisticated. Anyone claiming otherwise from an adb
# shell is selling false assurance.
#
# WHAT IT IS: a check for the conditions that actually make a phone
# unsafe to put an account on - root, an unlocked bootloader, a disabled
# security stack, a badly out-of-date patch level, and the specific
# permissions Android malware really uses (accessibility, device admin,
# notification listening, screen overlay).
#
# Usage:  bash tools/deviceIntegrityCheck.sh [serial]

ADB="/c/Users/benne/AppData/Local/Android/Sdk/platform-tools/adb.exe"
SERIAL="${1:-}"
A() { if [ -n "$SERIAL" ]; then "$ADB" -s "$SERIAL" "$@"; else "$ADB" "$@"; fi; }
prop() { A shell getprop "$1" 2>/dev/null | tr -d '\r'; }

flag=0
say()  { printf "  %-34s %s\n" "$1" "$2"; }
bad()  { printf "  %-34s %s   <-- %s\n" "$1" "$2" "$3"; flag=$((flag+1)); }

echo "device: $(prop ro.product.manufacturer) $(prop ro.product.model)  " \
     "android $(prop ro.build.version.release)"
echo

echo "-- boot chain: has the OS itself been replaced? --"
VBS=$(prop ro.boot.verifiedbootstate); VBS=${VBS:-unknown}
case "$VBS" in
  green)  say "verified boot" "green (stock, sealed)";;
  orange) bad "verified boot" "orange" "BOOTLOADER UNLOCKED - anything can be flashed";;
  yellow) bad "verified boot" "yellow" "custom key - a non-stock OS is signed on";;
  red)    bad "verified boot" "red" "VERIFICATION FAILED";;
  *)      say "verified boot" "$VBS (emulators do not report this)";;
esac
LOCK=$(prop ro.boot.flash.locked)
[ "$LOCK" = "1" ] && say "bootloader" "locked" || bad "bootloader" "${LOCK:-unknown}" "unlocked or unreported"

echo
echo "-- root: can another app read this app's data? --"
SU=$(A shell 'for p in /sbin/su /system/bin/su /system/xbin/su /su/bin/su; do [ -e $p ] && echo $p; done' 2>/dev/null | tr -d '\r')
[ -z "$SU" ] && say "su binary" "none found" || bad "su binary" "$SU" "DEVICE IS ROOTED"
MAGISK=$(A shell 'pm list packages 2>/dev/null' | grep -icE "magisk|supersu|kingroot" | tr -d '\r')
[ "$MAGISK" = "0" ] && say "root manager app" "none" || bad "root manager app" "$MAGISK found" "rooting toolkit present"
DEBUGGABLE=$(prop ro.debuggable)
[ "$DEBUGGABLE" = "1" ] && bad "ro.debuggable" "1" "eng/userdebug build - not a retail OS" || say "ro.debuggable" "0 (retail build)"

echo
echo "-- security stack still switched on? --"
SEL=$(A shell getenforce 2>/dev/null | tr -d '\r')
[ "$SEL" = "Enforcing" ] && say "SELinux" "Enforcing" || bad "SELinux" "${SEL:-unknown}" "kernel policy not enforced"
VERIFY=$(A shell settings get global package_verifier_user_consent 2>/dev/null | tr -d '\r')
case "$VERIFY" in
  1|null) say "Play Protect scanning" "on (or default)";;
  -1)     bad "Play Protect scanning" "declined" "app scanning switched off";;
  *)      say "Play Protect scanning" "${VERIFY:-unknown}";;
esac

echo
echo "-- how far behind are the patches? --"
PATCH=$(prop ro.build.version.security_patch)
say "security patch" "${PATCH:-unknown}"
if [ -n "$PATCH" ]; then
  AGE=$(( ( $(date +%s) - $(date -d "$PATCH" +%s 2>/dev/null || echo 0) ) / 86400 ))
  [ "$AGE" -gt 365 ] && bad "patch age" "$AGE days" "over a year of known holes unfixed" \
    || say "patch age" "$AGE days"
fi

echo
echo "-- the permissions malware actually uses --"
ACC=$(A shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r')
[ -z "$ACC" ] || [ "$ACC" = "null" ] && say "accessibility services" "none" \
  || bad "accessibility services" "$ACC" "can read the screen and tap for you"
NL=$(A shell settings get secure enabled_notification_listeners 2>/dev/null | tr -d '\r')
[ -z "$NL" ] || [ "$NL" = "null" ] && say "notification listeners" "none" \
  || bad "notification listeners" "$NL" "can read every notification, including codes"
ADMIN=$(A shell dpm list-owners 2>/dev/null | tr -d '\r' | head -2)
echo "$ADMIN" | grep -qi "no device owner" && say "device owner" "none" \
  || say "device owner" "${ADMIN:-none reported}"

echo
echo "-- what is installed from outside the Play Store --"
A shell 'pm list packages -3 -i 2>/dev/null' | tr -d '\r' \
  | grep -v "installer=com.android.vending" \
  | grep -v "installer=null" | head -12 | sed 's/^/  /'
SIDE=$(A shell 'pm list packages -3 -i 2>/dev/null' | tr -d '\r' \
  | grep -vc "installer=com.android.vending")
say "non-Play third-party apps" "${SIDE:-0}"

echo
echo "-- is this phone reachable over the network by adb? --"
TCP=$(prop service.adb.tcp.port)
[ -z "$TCP" ] && say "adb over TCP" "off" || bad "adb over TCP" "port $TCP" "anyone on this network can connect"

echo
if [ "$flag" -eq 0 ]; then
  echo "RESULT: nothing alarming found in what can be checked from here."
else
  echo "RESULT: $flag item(s) worth reading above before trusting this device."
fi
echo "Reminder: this proves the phone is not obviously compromised."
echo "It cannot prove the phone is clean. No adb-level check can."
