package com.ifchy.ctims;

import android.os.PersistableBundle;
import android.os.Process;
import android.util.Log;

import java.lang.reflect.Method;

/**
 * Headless replica of carrier-ims-for-pixel's ImsModifier.overrideConfig step.
 *
 * Runs as root via app_process. It:
 *   1. gets IActivityManager and adopts the shell UiAutomation permission identity
 *      (grants MODIFY_PHONE_STATE etc. to our root uid, exactly like the app does
 *       via Shizuku + startDelegateShellPermissionIdentity);
 *   2. gets the carrier_config binder (ICarrierConfigLoader) directly;
 *   3. calls overrideConfig(subId, <China Telecom IMS/VoLTE bundle>, persistent=false).
 *
 * Usage: app_process -Djava.class.path=injector.dex /system/bin \
 *            com.ifchy.ctims.CarrierConfigInjector <subId> [persistent]
 */
public final class CarrierConfigInjector {

    private static final String TAG = "ct-ims-inject";
    // Device's normal "all supported RATs" user bitmask (GPRS|EDGE|UMTS|HSDPA|HSUPA|HSPA|LTE|
    // HSPA+|GSM|LTE_CA|NR) — used to RESTORE T-Mobile cellular. Matches the value other subs use.
    private static final long ALL_RATS = 840583L;

    public static void main(String[] args) {
        int subId = 4;            // China Telecom physical SIM (slot 0) default; overridden by arg
        boolean persistent = false;
        String mode = "full";     // "full" = CT VoLTE/VoNR bundle; "crosssim" = enable cross-SIM only
        if (args != null) {
            for (String a : args) {
                if (a == null) continue;
                a = a.trim();
                if ("persistent".equalsIgnoreCase(a)) persistent = true;
                else if ("crosssim".equalsIgnoreCase(a)) mode = "crosssim";
                else if ("full".equalsIgnoreCase(a)) mode = "full";
                else if ("resetims".equalsIgnoreCase(a)) mode = "resetims";
                else if ("cellon".equalsIgnoreCase(a)) mode = "cellon";
                else { try { subId = Integer.parseInt(a); } catch (Exception ignore) {} }
            }
        }
        try {
            inject(subId, persistent, mode);
            log("DONE overrideConfig subId=" + subId + " mode=" + mode + " persistent=" + persistent);
        } catch (Throwable t) {
            err("FAILED: " + t);
            t.printStackTrace();
            System.exit(1);
        }
    }

    private static void inject(int subId, boolean persistent, String mode) throws Exception {
        Object am = service("activity", "android.app.IActivityManager");
        int uid = Process.myUid();
        log("uid=" + uid + " -> adopting shell permission identity");
        Method startDelegate = am.getClass().getMethod(
                "startDelegateShellPermissionIdentity", int.class, String[].class);
        startDelegate.invoke(am, uid, null);
        try {
            if ("cellon".equals(mode)) {
                // US restore: clear the force-home block (cellular allowed again) + restore RATs.
                Object loader = service("carrier_config",
                        "com.android.internal.telephony.ICarrierConfigLoader");
                PersistableBundle b = new PersistableBundle();
                b.putBoolean("force_home_network_bool", false);
                log("cellon: overrideConfig force_home_network_bool=false");
                overrideConfig(loader, subId, b, false);
                setUserAllowedNetworkTypes(subId, ALL_RATS);
            } else if ("resetims".equals(mode)) {
                resetIms(subId);
            } else {
                Object loader = service("carrier_config",
                        "com.android.internal.telephony.ICarrierConfigLoader");
                PersistableBundle values = "crosssim".equals(mode) ? buildCrossSimBundle() : buildBundle();
                log("calling overrideConfig (mode=" + mode + ") with " + values.size() + " keys");
                overrideConfig(loader, subId, values, persistent);
                if ("crosssim".equals(mode)) {
                    enableCrossSimUserSetting(subId);
                    // China block needs BOTH: force_home (in bundle) stops CMCC roaming, AND
                    // allowed-types=0 makes the modem stop treating cellular as "available" so
                    // QNS actually engages cross-SIM ("备用通话"). With allowed-types!=0 the modem
                    // keeps searching cellular and cross-SIM won't engage.
                    try {
                        setUserAllowedNetworkTypes(subId, 0L);
                    } catch (Throwable t) {
                        err("setUserAllowedNetworkTypes(0) failed: " + rootCause(t));
                    }
                } else {
                    // full (CT): also turn ON the Advanced Calling (VoLTE) + Video Calling USER
                    // settings so the Dialer actually shows the video-call button. carrier_vt_
                    // available_bool=true only makes the toggle AVAILABLE; until the user setting
                    // is enabled, IMS won't register VIDEO and the Dialer hides the button. Keep
                    // this LAST — the ImsMmTelManager init (ActivityThread.systemMain()) can
                    // swallow code that runs after it returns.
                    enableVtSetting(subId);
                }
            }
        } finally {
            try {
                am.getClass().getMethod("stopDelegateShellPermissionIdentity").invoke(am);
                log("released shell permission identity");
            } catch (Throwable t) {
                err("stopDelegateShellPermissionIdentity failed (non-fatal): " + t);
            }
        }
    }

    /**
     * Enable the per-subscription USER setting for Cross-SIM Calling (and VoWiFi) via the
     * proper IMS API, so the IMS stack actually registers Wi-Fi Calling over the other SIM's
     * mobile data. Runs under the adopted shell identity (grants MODIFY_PHONE_STATE).
     */
    private static void enableCrossSimUserSetting(int subId) {
        // A standalone app_process has no TelephonyServiceManager wired up, so ImsMmTelManager's
        // internal getITelephony() NPEs. Initialize it first (its registerers use ServiceManager).
        try {
            Class<?> tfi = Class.forName("android.telephony.TelephonyFrameworkInitializer");
            Object cur = tfi.getMethod("getTelephonyServiceManager").invoke(null);
            if (cur == null) {
                Class<?> tsmc = Class.forName("android.os.TelephonyServiceManager");
                Object tsm = tsmc.getDeclaredConstructor().newInstance();
                tfi.getMethod("setTelephonyServiceManager", tsmc).invoke(null, tsm);
                log("initialized TelephonyServiceManager");
            }
        } catch (Throwable t) {
            err("TelephonyServiceManager init failed (continuing): " + rootCause(t));
        }
        try { android.os.Looper.prepareMainLooper(); } catch (Throwable ignore) {}
        try {
            Class<?> atc = Class.forName("android.app.ActivityThread");
            Object at = atc.getMethod("systemMain").invoke(null);
            Object ctxObj = atc.getMethod("getSystemContext").invoke(at);
            android.content.Context ctx = (android.content.Context) ctxObj;
            Object imsManager = ctx.getSystemService("telephony_ims");
            if (imsManager == null) { err("telephony_ims service unavailable"); return; }
            Object mmTel = imsManager.getClass()
                    .getMethod("getImsMmTelManager", int.class).invoke(imsManager, subId);
            try {
                mmTel.getClass().getMethod("setVoWiFiSettingEnabled", boolean.class)
                        .invoke(mmTel, true);
                log("setVoWiFiSettingEnabled(true) subId=" + subId);
            } catch (Throwable t) {
                err("setVoWiFiSettingEnabled failed: " + rootCause(t));
            }
            try {
                mmTel.getClass().getMethod("setCrossSimCallingEnabled", boolean.class)
                        .invoke(mmTel, true);
                log("setCrossSimCallingEnabled(true) subId=" + subId);
            } catch (Throwable t) {
                err("setCrossSimCallingEnabled failed: " + rootCause(t));
            }
        } catch (Throwable t) {
            err("enableCrossSimUserSetting failed: " + rootCause(t));
        }
    }

    /**
     * Turn ON the per-subscription USER settings for Advanced Calling (VoLTE/Enhanced 4G) and
     * Video Calling (VT) via ImsMmTelManager, so the IMS stack registers the VIDEO MmTel
     * capability and the Dialer shows the video-call button. carrier_vt_available_bool in the
     * carrier-config bundle only makes the toggle AVAILABLE; this flips it ON. Runs under the
     * adopted shell identity (grants MODIFY_PHONE_STATE). Mirrors enableCrossSimUserSetting().
     */
    private static void enableVtSetting(int subId) {
        try {
            Class<?> tfi = Class.forName("android.telephony.TelephonyFrameworkInitializer");
            Object cur = tfi.getMethod("getTelephonyServiceManager").invoke(null);
            if (cur == null) {
                Class<?> tsmc = Class.forName("android.os.TelephonyServiceManager");
                Object tsm = tsmc.getDeclaredConstructor().newInstance();
                tfi.getMethod("setTelephonyServiceManager", tsmc).invoke(null, tsm);
                log("initialized TelephonyServiceManager");
            }
        } catch (Throwable t) {
            err("TelephonyServiceManager init failed (continuing): " + rootCause(t));
        }
        try { android.os.Looper.prepareMainLooper(); } catch (Throwable ignore) {}
        try {
            Class<?> atc = Class.forName("android.app.ActivityThread");
            Object at = atc.getMethod("systemMain").invoke(null);
            Object ctxObj = atc.getMethod("getSystemContext").invoke(at);
            android.content.Context ctx = (android.content.Context) ctxObj;
            Object imsManager = ctx.getSystemService("telephony_ims");
            if (imsManager == null) { err("telephony_ims service unavailable"); return; }
            Object mmTel = imsManager.getClass()
                    .getMethod("getImsMmTelManager", int.class).invoke(imsManager, subId);
            try {
                mmTel.getClass().getMethod("setAdvancedCallingSettingEnabled", boolean.class)
                        .invoke(mmTel, true);
                log("setAdvancedCallingSettingEnabled(true) subId=" + subId);
            } catch (Throwable t) {
                err("setAdvancedCallingSettingEnabled failed: " + rootCause(t));
            }
            try {
                mmTel.getClass().getMethod("setVtSettingEnabled", boolean.class)
                        .invoke(mmTel, true);
                log("setVtSettingEnabled(true) subId=" + subId);
            } catch (Throwable t) {
                err("setVtSettingEnabled failed: " + rootCause(t));
            }
        } catch (Throwable t) {
            err("enableVtSetting failed: " + rootCause(t));
        }
    }

    /**
     * Restart IMS registration for the given subscription's slot via ITelephony.resetIms(),
     * exactly like the app's "Restart IMS registration" (ImsResetter). This forces the IMS
     * stack to re-register and re-advertise capabilities (voice/video/UT) after the override,
     * so the Dialer doesn't show a stale "video calling not supported".
     */
    private static void resetIms(int subId) throws Exception {
        Object iTel = getTelephony();
        int slot = getSlotIndex(subId);
        log("resetIms subId=" + subId + " slot=" + slot);
        iTel.getClass().getMethod("resetIms", int.class).invoke(iTel, slot);
        log("resetIms done");
    }

    /**
     * Set the USER-reason allowed cellular network types for a sub.
     * 0 = no RAT (T-Mobile cellular OFF); ALL_RATS = restore normal cellular.
     * Signature on this device: setAllowedNetworkTypesForReason(subId, reason, bitmask, callingPkg).
     */
    private static void setUserAllowedNetworkTypes(int subId, long bitmask) throws Exception {
        Object iTel = getTelephony();
        iTel.getClass().getMethod("setAllowedNetworkTypesForReason",
                int.class, int.class, long.class, String.class)
                .invoke(iTel, subId, 0 /* ALLOWED_NETWORK_TYPES_REASON_USER */, bitmask,
                        "com.android.shell");
        log("setAllowedNetworkTypesForReason subId=" + subId + " user-bitmask=" + bitmask);
    }

    private static void ensureTelephonyServiceManager() throws Exception {
        Class<?> tfi = Class.forName("android.telephony.TelephonyFrameworkInitializer");
        Object tsm = tfi.getMethod("getTelephonyServiceManager").invoke(null);
        if (tsm == null) {
            Class<?> tsmc = Class.forName("android.os.TelephonyServiceManager");
            tsm = tsmc.getDeclaredConstructor().newInstance();
            tfi.getMethod("setTelephonyServiceManager", tsmc).invoke(null, tsm);
            log("initialized TelephonyServiceManager");
        }
    }

    private static Object getTelephony() throws Exception {
        ensureTelephonyServiceManager();
        Class<?> tfi = Class.forName("android.telephony.TelephonyFrameworkInitializer");
        Object tsm = tfi.getMethod("getTelephonyServiceManager").invoke(null);
        Class<?> iBinder = Class.forName("android.os.IBinder");
        Object telReg = tsm.getClass().getMethod("getTelephonyServiceRegisterer").invoke(tsm);
        Object telBinder = telReg.getClass().getMethod("get").invoke(telReg);
        return Class.forName("com.android.internal.telephony.ITelephony$Stub")
                .getMethod("asInterface", iBinder).invoke(null, telBinder);
    }

    private static int getSlotIndex(int subId) throws Exception {
        ensureTelephonyServiceManager();
        Class<?> tfi = Class.forName("android.telephony.TelephonyFrameworkInitializer");
        Object tsm = tfi.getMethod("getTelephonyServiceManager").invoke(null);
        Class<?> iBinder = Class.forName("android.os.IBinder");
        Object subReg = tsm.getClass().getMethod("getSubscriptionServiceRegisterer").invoke(tsm);
        Object subBinder = subReg.getClass().getMethod("get").invoke(subReg);
        Object iSub = Class.forName("com.android.internal.telephony.ISub$Stub")
                .getMethod("asInterface", iBinder).invoke(null, subBinder);
        return (int) iSub.getClass().getMethod("getSlotIndex", int.class).invoke(iSub, subId);
    }

    private static String rootCause(Throwable t) {
        Throwable c = t;
        while (c.getCause() != null) c = c.getCause();
        return c.getClass().getName() + ": " + c.getMessage();
    }

    /** ServiceManager.getService(name) -> <iface>.Stub.asInterface(binder), all via reflection. */
    private static Object service(String name, String iface) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Object binder = sm.getMethod("getService", String.class).invoke(null, name);
        if (binder == null) throw new IllegalStateException("service '" + name + "' unavailable");
        Class<?> stub = Class.forName(iface + "$Stub");
        Class<?> iBinder = Class.forName("android.os.IBinder");
        return stub.getMethod("asInterface", iBinder).invoke(null, binder);
    }

    private static void overrideConfig(Object loader, int subId, PersistableBundle values,
                                       boolean persistent) throws Exception {
        try {
            loader.getClass().getMethod("overrideConfig",
                    int.class, PersistableBundle.class, boolean.class)
                    .invoke(loader, subId, values, persistent);
        } catch (NoSuchMethodException e) {
            loader.getClass().getMethod("overrideConfig",
                    int.class, PersistableBundle.class)
                    .invoke(loader, subId, values);
        }
    }

    /**
     * Minimal override to make Cross-SIM Calling "supported" for a SIM (e.g. T-Mobile),
     * so its Wi-Fi Calling (ePDG) can register over the OTHER SIM's mobile data.
     * Only touches the cross-SIM / WFC availability gates — nothing else on that SIM.
     */
    private static PersistableBundle buildCrossSimBundle() {
        PersistableBundle b = new PersistableBundle();
        b.putBoolean("carrier_cross_sim_ims_available_bool", true);
        b.putBoolean("enable_cross_sim_calling_on_opportunistic_data_bool", true);
        b.putBoolean("carrier_wfc_ims_available_bool", true);
        // HARD cellular block for China mode: force home-PLMN-only so T-Mobile can't register on
        // any Chinese roaming network (CMCC). allowed-types=0 alone does NOT block this. The
        // "restore" path clears this (cellon mode) for US use.
        b.putBoolean("force_home_network_bool", true);
        return b;
    }

    /**
     * Exact override bundle captured live from the user's working apply
     * (logcat: ImsModifier "overrideConfig: subId=4 ... overrides=...").
     */
    private static PersistableBundle buildBundle() {
        PersistableBundle b = new PersistableBundle();
        // --- VoLTE / IMS voice (the keys that actually bring China Telecom voice up) ---
        b.putBoolean("carrier_volte_available_bool", true);
        b.putBoolean("editable_enhanced_4g_lte_bool", true);
        b.putBoolean("hide_enhanced_4g_lte_bool", false);
        b.putBoolean("hide_lte_plus_data_icon_bool", false);
        // --- VoNR (5G SA voice — this SIM is on NR_SA) ---
        b.putBoolean("vonr_enabled_bool", true);
        b.putBoolean("vonr_setting_visibility_bool", true);
        // --- Video telephony / supplementary services over UT ---
        b.putBoolean("carrier_vt_available_bool", true);
        b.putBoolean("carrier_supports_ss_over_ut_bool", true);
        // NOTE: RCS presence / UCE keys were tried (to make the Google Dialer's direct video
        // button place a carrier video call instead of Google Meet) but China Telecom does not
        // answer UCE capability queries, so they had no effect and were removed. Outgoing carrier
        // video works via mid-call "upgrade to video" or a Telecom video intent.
        // --- VoWiFi ---
        b.putBoolean("carrier_wfc_ims_available_bool", true);
        b.putBoolean("carrier_wfc_supports_wifi_only_bool", true);
        b.putBoolean("editable_wfc_mode_bool", true);
        b.putBoolean("editable_wfc_roaming_mode_bool", true);
        b.putBoolean("show_wifi_calling_icon_in_status_bar_bool", true);
        b.putInt("wfc_spn_format_idx_int", 6);
        // --- Cross-SIM calling ---
        b.putBoolean("carrier_cross_sim_ims_available_bool", true);
        b.putBoolean("enable_cross_sim_calling_on_opportunistic_data_bool", true);
        // --- 5G NR availability + 5G+/icon/threshold cosmetics ---
        b.putIntArray("carrier_nr_availabilities_int_array", new int[]{1, 2});
        b.putInt("nr_advanced_threshold_bandwidth_khz_int", 110000);
        b.putBoolean("include_lte_for_nr_advanced_threshold_bandwidth_bool", false);
        b.putIntArray("additional_nr_advanced_bands_int_array", new int[]{1, 3, 8, 28, 41, 78, 79});
        b.putString("5g_icon_configuration_string",
                "connected_mmwave:5G_Plus,connected:5G,connected_rrc_idle:5G,"
                        + "not_restricted_rrc_idle:5G,not_restricted_rrc_con:5G");
        b.putInt("nr_advanced_capable_pco_id_int", 0);
        b.putIntArray("5g_nr_ssrsrp_thresholds_int_array", new int[]{-128, -118, -108, -98});
        // --- China region (TikTok/network-fix ISO override) ---
        b.putString("sim_country_iso_override_string", "cn");
        return b;
    }

    private static void log(String m) {
        System.out.println("[" + TAG + "] " + m);
        try { Log.i(TAG, m); } catch (Throwable ignore) {}
    }

    private static void err(String m) {
        System.err.println("[" + TAG + "] " + m);
        try { Log.e(TAG, m); } catch (Throwable ignore) {}
    }
}
