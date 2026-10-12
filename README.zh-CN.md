# Pixel‑Magisk‑IMS

[English](README.md) | **简体中文**

一个自包含的 **Magisk 模块**,在**每次开机时**自动重新下发**中国电信**的
VoLTE / VoNR / 视频通话 运营商配置(carrier‑config),让已 root 的 Pixel
插中国电信卡时持续可用 5G‑SA 语音和视频 —— 运行时**无需任何 App、也不依赖 Shizuku**。

> 在 **Pixel 10 Pro Fold**(Android 16)上构建并测试。该思路对其它已 root 的 Pixel 同样适用;
> 中国电信卡是按**物理 SIM 槽 0、`mcc=460`** 匹配的。

## 适用场景:电信 + T‑Mobile 同时使用,**无需连 Wi‑Fi**

在一台已 root 的 Pixel 上**同时使用一张中国电信卡 + 一张 T‑Mobile eSIM**:

- **中国电信** —— 你的数据卡:5G‑SA 移动流量,**外加它自己的 VoLTE / VoNR 语音和视频**
  (本模块修复并保证重启后持续可用)。
- **T‑Mobile** —— 通过**走中国电信流量的 Wi‑Fi 通话**(跨 SIM 通话,即 *Call over other SIM* /
  「备用通话」)保持本号可用。**无需连接任何 Wi‑Fi** —— T‑Mobile 的 IMS 直接借用电信的移动数据通路,
  于是你只靠蜂窝流量就能用 T‑Mobile 打电话,而不必让 T‑Mobile 漫游到本地网络。

自 v2.4 起每次开机自动完成:T‑Mobile 打开跨 SIM + Wi‑Fi 通话,并且在中国境内时把选网固定为
T‑Mobile 自己的本网 PLMN(手动选网),因此绝不会漫游到移动/联通。有 Wi‑Fi 时显示 **「T‑Mobile WLAN 通话」**,
没有 Wi‑Fi 时走电信数据显示 **「T‑Mobile 备用通话」**。详见「说明与限制」。

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
   下发电信配置包(VoLTE、VoNR 及其可见性、视频通话、关闭 VoWiFi、UT 补充业务、5G‑SA NR 可用性、
   5G 图标、`sim_country_iso=cn` 等)。
4. 通过 `ImsMmTelManager` **打开**「高级通话(VoLTE)」与「视频通话」用户开关,让电话 App 显示视频按钮。
5. 重启 IMS 注册并**校验**确实注册成功(`status` 模式;90 秒内没注册上就再重启一次),然后重启电话 App,
   使语音/视频能力干净地注册上来。

6. T‑Mobile eSIM(`carrierId=1`,在 `service.sh` 里设 `TMO_MODE=0` 可跳过):
   - 开机后立即:若可见 `460` 网络**且 T‑Mobile 正驻留在中国网络上**,后台把选网固定为本网 PLMN
     (`homeonly`,手动 + 持久化);已经固定过则什么都不做;不在中国则恢复自动选网(`netauto`);
   - 等待稳定后:打开跨 SIM + Wi‑Fi 通话、仅用 LTE/NR,并打开 T‑Mobile 的「自动切换移动数据」(`crosssim`),
     然后重启其 IMS。

每一步都带时间戳写入 `/data/local/tmp/ct-ims-inject.log`,正常开机约 75 秒跑完。随时查看 IMS 状态:
`CLASSPATH=…/injector.dex app_process /system/bin com.ifchy.ctims.CarrierConfigInjector <subId> status`
(输出 `ims=REGISTERED tech=NR|LTE|IWLAN|CROSS_SIM`;退出码 0 = 已注册)。

**作用范围 / 安全性**:运营商配置包**只**作用于中国电信卡(槽 0、`mcc=460`)。T‑Mobile 这一步只改它的
跨 SIM / Wi‑Fi 通话开关和选网模式;不会动任何其它 eSIM。

即使是 root,`cmd phone cc` 也会被拒绝,所以才改用 `app_process` + 借用 shell 身份这条路径来下发 override。

## 安装

1. 在 Magisk 中刷入 `ct_ims_autoinject-v2.4.zip`(*模块 → 从本地安装*)。
2. 重启。中国电信会自动恢复 5G‑SA + VoLTE/VoNR + 视频。

Magisk **Action** 按钮:立即重新执行 T‑Mobile 这一步(跨 SIM + Wi‑Fi 通话,在中国时固定本网选网),
并重启其 IMS。

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

- **T‑Mobile 跨 SIM(「备用通话」)** 只有在 T‑Mobile 没有蜂窝服务时才会挂上。在 CP3A 上,
  `force_home_network_bool`、允许网络类型设为 `0`、写 EF_FPLMN(基带会用内存里的列表覆盖回去)都拦不住
  移动/联通漫游;**手动选网到本网 PLMN** 可以,且立即生效(CS = DENIED / 仅紧急呼叫)。撤销:
  `app_process … CarrierConfigInjector <subId> cellon`(恢复自动选网 + 全部制式)。
- **手动选本网 vs 双卡单通**:`setNetworkSelectionModeManual` 要等基带搜不到本网 PLMN 才返回
  —— 全制式约 120 秒,仅 LTE/NR 约 85 秒 —— 搜网期间占用共享射频,会推迟电信 IMS 注册。所以它放在后台跑,
  且只在 T‑Mobile 真的漫游在中国网络上时才触发。固定之后电信保持注册(10 分钟监测 59/59 次均在 NR)。
  也试过直接关 T‑Mobile 射频:QNS 在该卡射频关闭时不会走跨 SIM,因此放弃。
- **打开「设置 > SIM 卡」会关掉备用通话的问题**:设置里的 `CrossSimCallingViewModel`
  (`config_auto_data_switch_enables_cross_sim_calling`)每次打开该页面,都会把各卡的「备用通话」开关同步成
  **非数据卡**的「自动切换移动数据」策略(日志 `CrossSimCallingVM: updatableSubIds: [1] newEnabled: false`)。
  所以 `crosssim` 也会打开 T‑Mobile 的这个策略;在国内 T‑Mobile 没有蜂窝,数据不会切过去。
- **电信 VoWiFi 已关闭**(`carrier_wfc_ims_available_bool=false`):电信不提供 Wi‑Fi 通话(其 ePDG 域名只能用
  电信 DNS 解析,加静态地址后 EAP‑AKA 鉴权也被拒)。保持开启只会让 QNS 在连 Wi‑Fi 时每隔几分钟尝试把电信 IMS
  切到 IWLAN 并失败。电信 IMS 始终走蜂窝(5G‑SA 下即 VoNR)。
- **经代理网关的 Wi‑Fi 通话**:如果路由器跑 Surge/Clash 的 fake‑IP 模式,需把 `*.3gppnetwork.org`
  加入 `always-real-ip` / `fake-ip-filter`,并让 UDP 500/4500 走 `DIRECT`,否则 ePDG 的 IKE 握手会超时
  (`IKE_INIT_TIMEOUT`)。
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
