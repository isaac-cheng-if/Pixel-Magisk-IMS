# Pixel‑Magisk‑IMS

[English](README.md) | **简体中文**

一个自包含的 **Magisk 模块**,在**每次开机时**自动重新下发**中国电信**的
VoLTE / VoNR / VoWiFi / 视频通话 运营商配置(carrier‑config),让已 root 的 Pixel
插中国电信卡时持续可用 5G‑SA 语音和视频 —— 运行时**无需任何 App、也不依赖 Shizuku**。

> 在 **Pixel 10 Pro Fold**(Android 16)上构建并测试。该思路对其它已 root 的 Pixel 同样适用;
> 中国电信卡是按**物理 SIM 槽 0、`mcc=460`** 匹配的。

## 为什么需要它

常见的修复方式([carrier‑ims‑for‑pixel](https://github.com/ryfineZ/carrier-ims-for-pixel) /
`io.github.vvb2060.ims.mod`)是一个普通的 `/data` 应用,只能调用
`CarrierConfigManager.overrideConfig(..., persistent = false)` —— 这个 override **每次重启都会被清掉**,
于是你每次开机都得重新打开 App 点一下「应用」。

本模块用一个 root 服务在**开机时自动**下发同样的 override,修复**重启后依然有效**,无需任何手动操作。

## 开机时它做了什么

`service.sh`(Magisk `late_start` 服务):

1. 等开机完成 + 开机动画结束(界面已起来),再静置一小会儿 —— 这样重载运营商配置时绝不会卡住界面。
2. **只**识别中国电信卡(物理槽 0、`mcc=460`)。
3. 以 root 通过 `app_process` 运行 `injector.dex` → 取得 shell 权限身份
   (`startDelegateShellPermissionIdentity`)→ 直接调用 `ICarrierConfigLoader.overrideConfig`
   下发电信配置包(VoLTE、VoNR 及其可见性、视频通话、VoWiFi、UT 补充业务、5G‑SA NR 可用性、
   5G 图标、`sim_country_iso=cn` 等)。
4. 通过 `ImsMmTelManager` **打开**「高级通话(VoLTE)」与「视频通话」用户开关,让电话 App 显示视频按钮。
5. 重启 IMS 注册和电话 App,使语音/视频能力干净地注册上来。

**作用范围 / 安全性**:它**只**会动中国电信卡(槽 0、`mcc=460`),**绝不**自动修改 T‑Mobile 或任何其它 eSIM。

即使是 root,`cmd phone cc` 也会被拒绝,所以才改用 `app_process` + 借用 shell 身份这条路径来下发 override。

## 安装

1. 在 Magisk 中刷入 `ct_ims_autoinject-v2.3.zip`(*模块 → 从本地安装*)。
2. 重启。中国电信会自动恢复 5G‑SA + VoLTE/VoNR + 视频。

Magisk **Action** 按钮:手动启用 T‑Mobile 跨 SIM 通话(「备用通话」)走电信数据
(设置 `crossSimCallingEnabled` + Wi‑Fi 通话;不封蜂窝)。可选 / 尽力而为 —— 见「说明」。

## 编译注入器

主机只需 Docker(无需本地 JDK/Android SDK):

```sh
docker run --rm -v ctims-sdk:/sdk \
  -v "$PWD/build":/work -w /work \
  eclipse-temurin:17-jdk bash /work/build_in_docker.sh
# -> build/classes.dex （复制到 module/injector.dex,再重新打包 module/ 为 zip）
```

注入器源码:[`build/CarrierConfigInjector.java`](build/CarrierConfigInjector.java)。

## 说明与限制

- **T‑Mobile 跨 SIM(「备用通话」)** 通过 Action 按钮手动启用,且为*尽力而为*:本设备的 QNS
  只有在 T‑Mobile 没有蜂窝服务时(例如刚开机那会儿)才会挂上;运行时无法把已驻留的漫游网络踢下来。
- **主叫运营商视频**:原生 Google 电话的视频按钮会走 Google Meet(能力受限 + 电信不应答 RCS presence),
  因而黑屏。可行的方式:**通话中「升级到视频」**,或用 Telecom 视频 intent
  (`am start -a android.intent.action.CALL -d tel:号码 --ei android.telecom.extra.START_CALL_WITH_VIDEO_STATE 3`)。
- **VoNR vs VoLTE**:VoNR 已启用并注册(小区 `VOPS=1`),但中国电信对实际呼叫会做 **EPS Fallback**
  (NR→LTE),所以通话媒体实际跑在 VoLTE 上。这是网络侧策略,运营商配置改不了。
- **请勿同时运行旧的 carrier‑ims App** —— 它通过 Shizuku 下发自己的配置,会与本模块冲突。

## 致谢

灵感来自 [carrier‑ims‑for‑pixel](https://github.com/ryfineZ/carrier-ims-for-pixel) /
`io.github.vvb2060.ims.mod`。本仓库的注入器为独立实现。

## 免责声明

按「现状」提供,仅供在你自己已 root 的设备上使用。修改运营商/IMS 配置风险自负。
以 [MIT 协议](LICENSE) 授权。
