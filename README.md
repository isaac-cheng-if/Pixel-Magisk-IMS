# Pixel‑Magisk‑IMS

**English** | [简体中文](README.zh-CN.md)

A self‑contained **Magisk module** that re‑applies the **China Telecom (中国电信)**
VoLTE / VoNR / Video‑Telephony carrier‑config override on **every boot**, so a
rooted Pixel keeps working 5G‑SA voice and video on a China Telecom SIM — with **no app and
no Shizuku** needed at runtime.

> Built and tested on a **Pixel 10 Pro Fold** (Android 16). The same approach should work on
> other rooted Pixels; the China‑Telecom matching is by `mcc=460` on physical SIM slot 0.

## Use case: China Telecom + T‑Mobile together, **no Wi‑Fi needed**

Run a **China Telecom SIM and a T‑Mobile eSIM at the same time** on one rooted Pixel:

- **China Telecom** — your data SIM: 5G‑SA mobile data **plus its own VoLTE / VoNR voice &
  video** (the part this module fixes and keeps working across reboots).
- **T‑Mobile** — kept reachable on its own number via **Wi‑Fi Calling carried over China
  Telecom's mobile data** (cross‑SIM calling, a.k.a. *Call over other SIM* / "备用通话").
  **No Wi‑Fi network is required** — T‑Mobile's IMS rides China Telecom's data path, so you can
  use T‑Mobile calling on cellular data alone, instead of T‑Mobile roaming on a local network.

Since v2.4 this is automatic on every boot: T‑Mobile gets cross‑SIM + Wi‑Fi calling, and while
in China it is pinned to its own home PLMN (manual network selection) so it never roams on
CMCC/CU. With Wi‑Fi it shows **"T‑Mobile Wi‑Fi Calling"**; without Wi‑Fi, **"T‑Mobile Backup
calling" (备用通话)** over China Telecom data. See [Notes & limitations](#notes--limitations).

## Why this exists

The usual fix ([carrier‑ims‑for‑pixel](https://github.com/ryfineZ/carrier-ims-for-pixel) /
`io.github.vvb2060.ims.mod`) is an ordinary `/data` app, so it can only call
`CarrierConfigManager.overrideConfig(..., persistent = false)` — the override is **wiped on
every reboot**, forcing you to re‑open the app and tap *apply* after each boot.

This module does the same override **automatically at boot** from a root service, so the fix
survives reboots without any manual step.

## What it does on boot

`service.sh` (Magisk `late_start` service):

1. Waits for boot + the boot animation to finish (UI up), then a short settle — so reloading
   carrier config never stalls the UI.
2. Discovers **only** the China Telecom sub (physical slot 0, `mcc=460`).
3. Runs `injector.dex` via `app_process` as root → adopts the shell permission identity
   (`startDelegateShellPermissionIdentity`) → calls `ICarrierConfigLoader.overrideConfig`
   directly with the China‑Telecom bundle (VoLTE, VoNR + visibility, Video Telephony, VoWiFi off,
   SS‑over‑UT, 5G‑SA NR availabilities, 5G icon, `sim_country_iso=cn`, …).
4. Turns **on** the *Advanced Calling (VoLTE)* and *Video Calling* user settings via
   `ImsMmTelManager`, so the Dialer exposes the video‑call button.
5. Restarts IMS registration and **verifies** it registered (`status` mode; one more restart if
   not within 90 s), then restarts the Dialer so voice/video capabilities come up clean.

6. T‑Mobile eSIM (`carrierId=1`, set `TMO_MODE=0` in `service.sh` to skip):
   - right after boot: if a `460` network is visible **and T‑Mobile is camped on one**, pins its
     network selection to the home PLMN (`homeonly`, manual + persisted, run in the background);
     if already pinned it does nothing; outside China it restores automatic selection (`netauto`);
   - after the settle: cross‑SIM + Wi‑Fi calling, LTE/NR‑only and "Switch mobile data
     automatically" on T‑Mobile (`crosssim`), IMS restart.

Every step is timestamped in `/data/local/tmp/ct-ims-inject.log`; a normal boot finishes in
~75 s. Check IMS at any time with
`CLASSPATH=…/injector.dex app_process /system/bin com.ifchy.ctims.CarrierConfigInjector <subId> status`
(prints `ims=REGISTERED tech=NR|LTE|IWLAN|CROSS_SIM`; exit 0 = registered).

**Scope / safety:** the carrier‑config bundle only touches the China Telecom SIM (slot 0,
`mcc=460`). The T‑Mobile step only changes its cross‑SIM / Wi‑Fi‑calling settings and network
selection mode; no other eSIM is touched.

`cmd phone cc` is denied even as root, which is why the override is applied through the
`app_process` + adopted‑shell‑identity path instead.

## Install

1. Flash `ct_ims_autoinject-v2.4.zip` in the Magisk app (*Modules → Install from storage*).
2. Reboot. China Telecom should come up with 5G‑SA + VoLTE/VoNR + video automatically.

Magisk **Action** button: re‑apply the T‑Mobile step right now (cross‑SIM + Wi‑Fi calling, and
home‑PLMN pinning while in China), then restart its IMS.

## Build the injector

The Mac/host needs only Docker (no local JDK/Android SDK):

```sh
docker run --rm -v ctims-sdk:/sdk \
  -v "$PWD/build":/work -w /work \
  eclipse-temurin:17-jdk bash /work/build_in_docker.sh
# -> build/classes.dex  (copy to module/injector.dex, then re-zip module/)
```

The injector source is [`build/CarrierConfigInjector.java`](build/CarrierConfigInjector.java).

## Notes & limitations

- **T‑Mobile cross‑SIM ("备用通话")** only engages while T‑Mobile has no cellular service. On
  CP3A, `force_home_network_bool`, allowed‑network‑types `0` and writing EF_FPLMN (the modem
  rewrites it from RAM) all fail to stop CMCC/CU roaming; **manual selection of the home PLMN**
  does, immediately (CS = DENIED / emergency‑only). Undo with
  `app_process … CarrierConfigInjector <subId> cellon` (restores automatic selection + all RATs).
- **Manual home‑PLMN search vs. DSDS:** `setNetworkSelectionModeManual` only returns after the
  modem's search for the (absent) home PLMN fails — ~120 s with all RATs, ~85 s with LTE/NR — and
  that search holds the shared radio, delaying China Telecom's IMS registration. Hence it runs in
  the background and only when T‑Mobile is actually roaming in China. Once pinned, CT stays
  registered (10‑min monitor: 59/59 samples on NR). Turning T‑Mobile's radio off instead was
  tested and rejected: QNS won't use cross‑SIM with the slot's radio off.
- **Opening Settings > SIMs used to turn 备用通话 off:** Settings' `CrossSimCallingViewModel`
  (`config_auto_data_switch_enables_cross_sim_calling`) re‑syncs every cross‑SIM‑capable sub's
  "Backup calling" setting to the **non‑data SIM's** "Switch mobile data automatically" policy
  each time the page opens (`CrossSimCallingVM: updatableSubIds: [1] newEnabled: false`). So
  `crosssim` also enables that policy on T‑Mobile; in China data can't switch to it anyway.
- **China Telecom VoWiFi is disabled** (`carrier_wfc_ims_available_bool=false`): CT doesn't offer
  Wi‑Fi calling (its ePDG FQDN only resolves via CT DNS, and with a static address EAP‑AKA is
  rejected). Leaving it available only made QNS retry an IWLAN handover of CT's IMS every few
  minutes on Wi‑Fi. CT IMS always stays on cellular (VoNR on 5G‑SA).
- **Wi‑Fi Calling through a proxy gateway:** if the Wi‑Fi router runs Surge/Clash in fake‑IP mode,
  add `*.3gppnetwork.org` to `always-real-ip` / `fake-ip-filter` and route UDP 500/4500 `DIRECT`,
  otherwise the ePDG IKE handshake times out (`IKE_INIT_TIMEOUT`).
- **Outgoing carrier video calls:** the stock Google Dialer routes its video button to Google
  Meet (capability‑gated; China Telecom doesn't answer RCS presence), so it black‑screens.
  Working paths: **mid‑call "upgrade to video"**, or a Telecom video intent
  (`am start -a android.intent.action.CALL -d tel:NUMBER --ei android.telecom.extra.START_CALL_WITH_VIDEO_STATE 3`).
- **VoNR vs VoLTE:** VoNR is enabled and registered (cell `VOPS=1`), but China Telecom performs
  **EPS Fallback** on actual calls (NR→LTE), so call media runs as VoLTE. This is network policy
  and is not changeable from carrier config.
- Do **not** also run the old carrier‑ims app — its Shizuku injection conflicts with this module.

## Credits

Inspired by [carrier‑ims‑for‑pixel](https://github.com/ryfineZ/carrier-ims-for-pixel) /
`io.github.vvb2060.ims.mod`. The injector here is an independent implementation.

## Disclaimer

Provided as‑is, for use on your own rooted device. Modifying carrier/IMS configuration is at
your own risk. Licensed under the [MIT License](LICENSE).
