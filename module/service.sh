#!/system/bin/sh
# China Telecom IMS Auto-Inject — late_start service script.
#
# Re-applies the China Telecom SIM1 (physical slot 0, mcc=460) VoLTE/VoNR/VT (VoWiFi off)
# carrier-config override on every boot — GENTLY, so it never stalls the UI:
#   * waits for boot to finish AND the boot animation to end (UI/launcher up),
#   * waits for the SIM to be recognized, then an extra settle so the system is idle
#     (this mimics tapping "apply" in the app after boot, which never stalls),
#   * applies the override ONCE at low priority (single carrier-config reload),
#     retrying only if the injector actually failed,
#   * restarts CT's IMS registration and VERIFIES it registered (one more restart if not).
#
# T-Mobile eSIM (carrierId=1) "Wi-Fi Calling / 备用通话 only" mode (v2.4+):
#   * right after boot — only while in China (a 460 network is visible) — pins T-Mobile's
#     network selection to its own home PLMN (manual), so it can't roam on CMCC/CU/CT; outside
#     China it restores automatic selection. No carrier-config reload, so safe to do early;
#   * after the settle: cross-SIM + Wi-Fi calling enabled, then its IMS is restarted.
# With Wi-Fi it uses VoWiFi; without Wi-Fi its IMS registers over China Telecom's mobile data.
# Set TMO_MODE=0 to leave T-Mobile alone.

MODDIR=${0%/*}
DEX="$MODDIR/injector.dex"
MAIN="com.ifchy.ctims.CarrierConfigInjector"
LOG=/data/local/tmp/ct-ims-inject.log
MCC=460            # match the active SIM by MCC (China). Edit if needed.
FALLBACK_SUB=4     # used only if discovery fails AND it is verified to be mcc=$MCC
SETTLE=25          # extra calm time (s) after the UI is up, before touching carrier config
TMO_MODE=1         # 1 = T-Mobile Wi-Fi-Calling/cross-SIM only in China; 0 = never touch T-Mobile
CN_MCC=460         # a visible network with this MCC means "in China" -> block T-Mobile cellular
IMS_WAIT=90        # max seconds to wait for CT IMS to register after a restart

echo "===== ct-ims service start $(date 2>/dev/null) =====" > "$LOG"
exec >>"$LOG" 2>&1

log() { echo "$(date +%T) $*"; }

# low priority if available
NICE=""
command -v nice >/dev/null 2>&1 && NICE="nice -n 19"

inj() { CLASSPATH="$DEX" $NICE app_process /system/bin "$MAIN" "$@"; }

# wait_ims <subId> <maxSeconds>: poll until MmTel IMS is registered; prints the final status.
wait_ims() {
    w=0
    while [ $w -lt "$2" ]; do
        if ST=$(inj "$1" status 2>/dev/null); then
            log "$(echo "$ST" | grep status) after ${w}s"
            return 0
        fi
        sleep 3; w=$((w + 3))
    done
    log "$(echo "$ST" | grep status) after ${w}s (gave up)"
    return 1
}

# 1) wait for boot to finish
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ $i -lt 150 ]; do sleep 2; i=$((i + 1)); done
log "sys.boot_completed=$(getprop sys.boot_completed)"

# 2) wait until the boot animation has ended (SystemUI/launcher are up) so we
#    never reload carrier config while the UI is still starting.
i=0
while [ "$(getprop init.svc.bootanim)" = "running" ] && [ $i -lt 90 ]; do sleep 2; i=$((i + 1)); done
log "bootanim=$(getprop init.svc.bootanim) after $((i * 2))s"

# 3) T-Mobile: pin network selection EARLY so it spends as little time as possible camped on
#    a Chinese roaming network (cross-SIM can't engage while it is). Only network selection —
#    no carrier-config reload here, so this can't stall the UI.
TMO=""
if [ "$TMO_MODE" = "1" ]; then
    i=0
    while [ $i -lt 20 ]; do
        TMO=$(dumpsys isub 2>/dev/null | grep 'carrierId=1 ' | grep -E 'simSlotIndex=[0-9]' \
                | grep -oE 'SubscriptionInfoInternal: id=[0-9]+' | grep -oE '[0-9]+$' | head -n1)
        [ -n "$TMO" ] && break
        sleep 3; i=$((i + 1))
    done
    if [ -n "$TMO" ]; then
        # where are we? any SIM's registered PLMN (e.g. "46011,46001"); wait up to 60s for one
        i=0; OPS=""
        while [ $i -lt 20 ]; do
            OPS=$(getprop gsm.operator.numeric | tr -d ' ')
            echo "$OPS" | grep -qE '[0-9]{5}' && break
            sleep 3; i=$((i + 1))
        done
        # T-Mobile's own entry (gsm.operator.numeric is indexed by slot)
        TSLOT=$(dumpsys isub 2>/dev/null | grep "SubscriptionInfoInternal: id=$TMO " \
                | grep -oE 'simSlotIndex=[0-9]+' | head -n1 | cut -d= -f2)
        TOP=$(echo "$OPS" | cut -d, -f$((${TSLOT:-1} + 1)))
        log "[tmo] T-Mobile subId=$TMO slot=$TSLOT, gsm.operator.numeric=$OPS (T-Mobile: ${TOP:-none})"
        if echo ",$OPS" | grep -q ",$CN_MCC"; then
            if echo "$TOP" | grep -q "^$CN_MCC"; then
                log "[tmo] in China, camped on $TOP -> homeonly (no CMCC/CU roaming)"
                # Backgrounded: the binder call only returns once the modem's manual search for
                # the home PLMN fails (~2-3 min in China), but the pin takes effect immediately.
                # The search holds the shared (DSDS) radio, delaying CT's IMS meanwhile — which
                # is why it is only triggered when T-Mobile is actually roaming in China.
                inj "$TMO" homeonly &
            else
                log "[tmo] in China, T-Mobile not on a Chinese network (pin persisted) -> nothing to do"
            fi
        elif echo "$OPS" | grep -qE '[0-9]{5}'; then
            log "[tmo] outside China -> netauto"
            inj "$TMO" netauto
        else
            log "[tmo] no network visible yet; network selection left unchanged"
        fi
    else
        log "[tmo] no active T-Mobile (carrierId=1) sub; skipped"
    fi
fi

# 4) discover ONLY the physical SIM1 China Telecom sub (slot 0 + mcc=$MCC).
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
    log "SIM1 China Telecom (slot 0, mcc=$MCC) subId=$SUB found after $((i * 3))s"
    log "$(inj "$SUB" status 2>/dev/null | grep status) (before override)"
elif dumpsys isub 2>/dev/null | grep -E "SubscriptionInfoInternal: id=$FALLBACK_SUB " | grep -q "mcc=$MCC"; then
    SUB=$FALLBACK_SUB
    log "WARN: discovery failed; verified fallback subId=$SUB is mcc=$MCC, using it"
else
    log "ERROR: no SIM1 mcc=$MCC sub found; skipping China Telecom (no other SIM touched)."
fi

# 5) settle so we apply when the device is calm (avoids any boot-time UI stall)
log "settling ${SETTLE}s before applying..."
sleep "$SETTLE"

if [ -n "$SUB" ]; then
    INJ_EXIT=1
    do_inject() {
        log "[$1] injector full subId=$SUB"
        inj "$SUB"
        INJ_EXIT=$?
        log "[$1] injector exit=$INJ_EXIT"
    }

    # 6) apply ONCE; retry a single time only if the injector actually failed
    do_inject apply
    if [ "$INJ_EXIT" != "0" ]; then
        log "apply failed; one retry after 8s"
        sleep 8
        do_inject retry
    fi

    # 7) restart China Telecom's IMS registration so voice/video capabilities come up clean
    #    (otherwise the Dialer can show a stale "video calling not supported"), then VERIFY it
    #    registered; restart once more if it didn't.
    #    NOTE: the `full` injection above also turns ON the Advanced Calling (VoLTE) + Video
    #    Calling USER settings via ImsMmTelManager, so IMS registers the VIDEO capability.
    sleep 3
    log "[resetims] restarting IMS registration for subId=$SUB"
    inj "$SUB" resetims
    if ! wait_ims "$SUB" "$IMS_WAIT"; then
        log "[resetims] CT IMS not registered; restarting IMS once more"
        inj "$SUB" resetims
        wait_ims "$SUB" "$IMS_WAIT"
    fi
fi

# 8) T-Mobile: cross-SIM + Wi-Fi calling carrier-config override (non-persistent, so every
#    boot), then restart its IMS. Registration depends on Wi-Fi / CT data, so only logged.
if [ -n "$TMO" ]; then
    log "[tmo] crosssim subId=$TMO"
    inj "$TMO" crosssim
    log "[tmo] crosssim exit=$?"
    sleep 3
    inj "$TMO" resetims
    wait_ims "$TMO" 90
fi

# 9) restart the Dialer so it re-reads CT's refreshed capabilities and shows the
#    video-call button (it caches capabilities and won't update on its own at boot).
am force-stop com.google.android.dialer 2>/dev/null
log "[dialer] restarted to refresh video-call button"

echo "===== ct-ims service done $(date 2>/dev/null) ====="
