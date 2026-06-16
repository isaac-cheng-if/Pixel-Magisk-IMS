#!/system/bin/sh
# China Telecom IMS Auto-Inject — late_start service script.
#
# Re-applies the China Telecom SIM1 (physical slot 0, mcc=460) VoLTE/VoNR/VoWiFi
# carrier-config override on every boot — GENTLY, so it never stalls the UI:
#   * waits for boot to finish AND the boot animation to end (UI/launcher up),
#   * waits for the SIM to be recognized, then an extra settle so the system is idle
#     (this mimics tapping "apply" in the app after boot, which never stalls),
#   * applies the override ONCE at low priority (single carrier-config reload),
#     retrying only if the injector actually failed,
#   * restarts CT's IMS registration so voice/video come up clean.
#
# SCOPE: this module ONLY ever touches the China Telecom SIM1. It never modifies
# the T-Mobile eSIM (or any other SIM) in any way. This is the original minimal fix.

MODDIR=${0%/*}
DEX="$MODDIR/injector.dex"
MAIN="com.ifchy.ctims.CarrierConfigInjector"
LOG=/data/local/tmp/ct-ims-inject.log
MCC=460            # match the active SIM by MCC (China). Edit if needed.
FALLBACK_SUB=4     # used only if discovery fails AND it is verified to be mcc=$MCC
SETTLE=25          # extra calm time (s) after the UI is up, before touching carrier config

echo "===== ct-ims service start $(date 2>/dev/null) =====" > "$LOG"
exec >>"$LOG" 2>&1

# 1) wait for boot to finish
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do sleep 2; i=$((i + 1)); done
echo "sys.boot_completed=$(getprop sys.boot_completed)"

# 2) wait until the boot animation has ended (SystemUI/launcher are up) so we
#    never reload carrier config while the UI is still starting.
i=0
while [ "$(getprop init.svc.bootanim)" = "running" ] && [ $i -lt 90 ]; do sleep 2; i=$((i + 1)); done
echo "bootanim=$(getprop init.svc.bootanim) after $((i * 2))s"

# 3) discover ONLY the physical SIM1 China Telecom sub (slot 0 + mcc=$MCC).
#    This can never match the T-Mobile eSIM (mcc=310, embedded) or any other SIM.
SUB=""
i=0
while [ $i -lt 100 ]; do
    SUB=$(dumpsys isub 2>/dev/null \
            | grep "mcc=$MCC" \
            | grep 'simSlotIndex=0 ' \
            | grep -oE 'SubscriptionInfoInternal: id=[0-9]+' \
            | grep -oE '[0-9]+$' | head -n1)
    [ -n "$SUB" ] && break
    sleep 3; i=$((i + 1))
done
if [ -n "$SUB" ]; then
    echo "SIM1 China Telecom (slot 0, mcc=$MCC) subId=$SUB found after $((i * 3))s"
elif dumpsys isub 2>/dev/null | grep -E "SubscriptionInfoInternal: id=$FALLBACK_SUB " | grep -q "mcc=$MCC"; then
    SUB=$FALLBACK_SUB
    echo "WARN: discovery failed; verified fallback subId=$SUB is mcc=$MCC, using it"
else
    echo "ERROR: no SIM1 mcc=$MCC sub found; aborting WITHOUT injecting (no other SIM touched)."
    echo "===== ct-ims service aborted $(date 2>/dev/null) ====="
    exit 0
fi

# 4) settle so we apply when the device is calm (avoids any boot-time UI stall)
echo "settling ${SETTLE}s before applying..."
sleep "$SETTLE"

# low priority if available
NICE=""
command -v nice >/dev/null 2>&1 && NICE="nice -n 19"

INJ_EXIT=1
do_inject() {
    echo "[$1] CLASSPATH=$DEX $NICE app_process /system/bin $MAIN $SUB"
    CLASSPATH="$DEX" $NICE app_process /system/bin "$MAIN" "$SUB"
    INJ_EXIT=$?
    echo "[$1] injector exit=$INJ_EXIT"
}

# 5) apply ONCE; retry a single time only if the injector actually failed
do_inject apply
if [ "$INJ_EXIT" != "0" ]; then
    echo "apply failed; one retry after 8s"
    sleep 8
    do_inject retry
fi

# 5b) restart China Telecom's IMS registration so voice/video capabilities come up
#     clean (otherwise the Dialer can show a stale "video calling not supported").
#     NOTE: the `full` injection above also turns ON the Advanced Calling (VoLTE) + Video
#     Calling USER settings via ImsMmTelManager, so IMS registers the VIDEO capability.
sleep 6
echo "[resetims] restarting IMS registration for subId=$SUB"
CLASSPATH="$DEX" $NICE app_process /system/bin "$MAIN" "$SUB" resetims
echo "[resetims] exit=$?"

# 5c) restart the Dialer so it re-reads CT's refreshed capabilities and shows the
#     video-call button (it caches capabilities and won't update on its own at boot).
sleep 3
am force-stop com.google.android.dialer 2>/dev/null
echo "[dialer] restarted to refresh video-call button"

echo "===== ct-ims service done $(date 2>/dev/null) ====="
