#!/system/bin/sh
# Magisk "Action" for this module = re-apply T-Mobile "Wi-Fi Calling / 备用通话 only" mode now
# (service.sh already does this on every boot since v2.4):
#   * enables cross-SIM calling + Wi-Fi calling for the T-Mobile sub;
#   * if a Chinese (460) network is visible: pins T-Mobile to manual selection of its own home
#     PLMN, so it drops CMCC/CU roaming immediately (limited service, emergency still works);
#     otherwise restores automatic network selection;
#   * restarts T-Mobile's IMS.
# Result: with Wi-Fi, T-Mobile uses VoWiFi; without Wi-Fi, its IMS registers over China
# Telecom's mobile data (备用通话).

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
    OPS=$(getprop gsm.operator.numeric | tr -d ' ')
    if echo ",$OPS" | grep -q ",460"; then
        echo ">> In China ($OPS): pinning T-Mobile to its home PLMN (no CMCC/CU roaming) ..."
        # backgrounded: returns only after the modem's ~2-3 min home-PLMN search fails
        CLASSPATH="$DEX" app_process /system/bin "$MAIN" "$TMO" homeonly >/dev/null 2>&1 &
    else
        echo ">> Not in China ($OPS): automatic network selection ..."
        CLASSPATH="$DEX" app_process /system/bin "$MAIN" "$TMO" netauto
    fi
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
sleep 5
CLASSPATH="$DEX" app_process /system/bin "$MAIN" "$TMO" status 2>/dev/null | grep status
echo "T-Mobile: Wi-Fi -> WLAN 通话; no Wi-Fi -> 备用通话 over China Telecom data (~10-30s)."
