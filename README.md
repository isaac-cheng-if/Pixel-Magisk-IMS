# Pixel‑Magisk‑IMS

A self‑contained **Magisk module** that re‑applies the **China Telecom (中国电信)**
VoLTE / VoNR / VoWiFi / Video‑Telephony carrier‑config override on **every boot**, so a
rooted Pixel keeps working 5G‑SA voice and video on a China Telecom SIM — with **no app and
no Shizuku** needed at runtime.

> Built and tested on a **Pixel 10 Pro Fold** (Android 16). The same approach should work on
> other rooted Pixels; the China‑Telecom matching is by `mcc=460` on physical SIM slot 0.

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
   directly with the China‑Telecom bundle (VoLTE, VoNR + visibility, Video Telephony, VoWiFi,
   SS‑over‑UT, 5G‑SA NR availabilities, 5G icon, `sim_country_iso=cn`, …).
4. Turns **on** the *Advanced Calling (VoLTE)* and *Video Calling* user settings via
   `ImsMmTelManager`, so the Dialer exposes the video‑call button.
5. Restarts IMS registration and the Dialer so voice/video capabilities come up clean.

**Scope / safety:** it only ever touches the China Telecom SIM (slot 0, `mcc=460`). It never
auto‑modifies the T‑Mobile / any other eSIM.

`cmd phone cc` is denied even as root, which is why the override is applied through the
`app_process` + adopted‑shell‑identity path instead.

## Install

1. Flash `ct_ims_autoinject-v2.3.zip` in the Magisk app (*Modules → Install from storage*).
2. Reboot. China Telecom should come up with 5G‑SA + VoLTE/VoNR + video automatically.

Magisk **Action** button: manually enable T‑Mobile cross‑SIM calling ("备用通话") over China
Telecom data (sets `crossSimCallingEnabled` + Wi‑Fi calling; no cellular block). Optional /
best‑effort — see Notes.

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

- **T‑Mobile cross‑SIM ("备用通话")** is opt‑in via the Action button and *best‑effort*: this
  device's QNS only engages it while T‑Mobile has no cellular service (e.g. right after boot).
  It cannot dislodge an already‑camped roaming network at runtime.
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
