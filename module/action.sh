#!/system/bin/sh
# Magisk "Action" for this module = manually ENABLE T-Mobile cross-SIM calling ("备用通话"):
# turn on the cross-SIM / Wi-Fi-calling user settings so T-Mobile's IMS can register over
# China Telecom's mobile data when there is no Wi-Fi, then restart IMS.
#
# Boot stays CT-ONLY (service.sh never touches T-Mobile). This button is the ONLY place the
# module touches the T-Mobile eSIM, and only when you tap it. It does NOT block T-Mobile
# cellular (no persistent allowed-types change) — so nothing to undo for the US.
#
# REQUIREMENT: this must leave crossSimCallingEnabled=1 for the T-Mobile sub; we verify + retry.
# Cross-SIM ("备用通话") then engages only while T-Mobile has NO cellular service (e.g. right
# after boot, before it finds CMCC). If T-Mobile is camped on CMCC, this device won't drop it at
# runtime — reboot (or disable the eSIM's mobile data) so T-Mobile is service-less, then tap again.

MODDIR=${0%/*}
DEX="$MODDIR/injector.dex"
MAIN="com.ifchy.ctims.CarrierConfigInjector"

# Discover the T-Mobile eSIM sub (carrierId=1), whether or not it currently holds a radio slot.
TMO=$(dumpsys isub 2>/dev/null | grep 'carrierId=1 ' | grep -E 'simSlotIndex=[0-9]' \
        | grep -oE 'SubscriptionInfoInternal: id=[0-9]+' | grep -oE '[0-9]+$' | head -n1)
[ -z "$TMO" ] && TMO=$(dumpsys isub 2>/dev/null | grep 'carrierId=1 ' \
        | grep -oE 'SubscriptionInfoInternal: id=[0-9]+' | grep -oE '[0-9]+$' | head -n1)
if [ -z "$TMO" ]; then echo "X  T-Mobile (carrierId=1) not found / eSIM not present."; exit 1; fi

read_xsim() {
    dumpsys isub 2>/dev/null | tr ' ' '\n' \
        | grep -E "^crossSimCallingEnabled=" | head -1 | cut -d= -f2
}

apply_once() {
    echo ">> Enabling cross-SIM / Wi-Fi calling for T-Mobile subId=$TMO ..."
    CLASSPATH="$DEX" app_process /system/bin "$MAIN" "$TMO" crosssim
    sleep 3
    echo ">> Restarting IMS registration ..."
    CLASSPATH="$DEX" app_process /system/bin "$MAIN" "$TMO" resetims
    sleep 2
}

apply_once
# verify crossSimCallingEnabled actually stuck; retry once if not
val=$(dumpsys isub 2>/dev/null | grep "SubscriptionInfoInternal: id=$TMO " | grep -oE 'crossSimCallingEnabled=[0-9]' | head -1)
if echo "$val" | grep -q 'crossSimCallingEnabled=1'; then
    echo "OK  $val"
else
    echo "!! $val — not set, retrying once ..."
    apply_once
    val=$(dumpsys isub 2>/dev/null | grep "SubscriptionInfoInternal: id=$TMO " | grep -oE 'crossSimCallingEnabled=[0-9]' | head -1)
    echo ">> after retry: $val"
fi

am force-stop com.google.android.dialer 2>/dev/null
echo
echo "Done. crossSimCallingEnabled for T-Mobile = ${val:-unknown}."
echo "Open the Phone app; if T-Mobile has no cellular service, 备用通话 engages over CT data in ~30s."
