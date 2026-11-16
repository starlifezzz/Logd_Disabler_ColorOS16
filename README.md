# ColorOS 16 优化模块

> 一加 Ace5 亲测的 KernelSU 模块 —— 日志、广告、OTA、冗余服务，图形界面点点开关就能关。

![KernelSU](https://img.shields.io/badge/KernelSU-Compatible-green?logo=android)
![ColorOS 16](https://img.shields.io/badge/ColorOS-16-blue)
![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-blue)

## 这是什么

专为 ColorOS 16 写的系统优化模块。装好后在 **KernelSU 管理器里直接打开图形界面**，38 个优化项想开就开、想关就关，不用碰任何配置文件。

- 配置存在模块外面，**覆盖升级不丢设置**
- 所有修改都是"软"的（挂载 + 禁用命令），**卸载模块一键全部还原**
- 界面、图标、字体全部打包在模块里，**不联网、不依赖 CDN**

## 界面长什么样

打开界面先看到一段复古 POST 自检动画，跑完进入主界面，底部五个标签：

| 标签 | 干什么 |
|------|--------|
| **优化** | 38 个开关，按分组排列，每个都能点进详情看说明 |
| **性能** | 内存 / IO / 负载一目了然 |
| **日志** | 操作日志实时看，不用连电脑 |
| **关于** | 版本与说明 |
| **GitHub** | 项目主页 |

开关覆盖范围：

- **核心**：logd 日志禁用、OTA 拦截、系统广告与数据收集屏蔽、开机崩溃修复
- **网络**：云控域名拦截、场景卡片域名、第三方 SDK 遥测域名（走 hosts 合并覆盖，不依赖 bindhosts）
- **性能**：内存 / IO 调优、内核参数、冗余进程清理
- **可选服务**：健康、钱包、备份、游戏空间、锁屏杂志、语音助手、AI 助手、多媒体……（含子开关，共 38 项）
- **不会碰的**：WiFi、蓝牙、音频、相机、传感器等核心功能，模块自动跳过，不会误伤

> 禁用某个服务 = 对应功能停用（比如关了健康服务就不同步健康数据），详情页里都写了，按需取舍。

## 快速开始

1. KernelSU 管理器 → 模块 → 安装 `Logd_Disabler_ColorOS16.zip` → **重启**
2. 管理器里点「ColorOS 16 优化」打开界面
3. 按需开关 → **再重启一次**，设置全部生效

装完不想折腾？默认配置开箱即用。

## 配置和日志在哪

```text
配置  /data/adb/Logd_Disabler_ColorOS16/config.json   # 模块外目录，升级不覆盖
日志  /data/adb/logd_disabler/service.log             # 界面「日志」页可直接看
      /data/adb/logd_disabler/post-fs-data.log
```

高级用户也可以直接改 `config.json`，重启后生效。

## 恢复与排错

| 情况 | 怎么办 |
|------|--------|
| 想恢复原样 | 界面里把开关全关 + 重启；或者直接**卸载模块**（自动回滚，被禁的服务全部还原） |
| 改了没生效 | 改完开关要**重启**才生效 |
| 出问题了 | 先看界面「日志」页，再提 [Issue](https://github.com/starlifezzz/Logd_Disabler_ColorOS16/issues) |

## 兼容性

- **主测机型**：一加 Ace5（ColorOS 16.0.2）
- 其他 ColorOS 16 一加 / OPPO 机型理论可用，欢迎反馈
- KernelSU 3.x 管理器自带 WebUI；WebUI-X、MMRL 等容器也能打开

## ⚠️ 风险与副作用（装之前先读）

这个模块做的是"关掉系统干的事"，其中两项需要你明确知道后果。

### 1. 去温控：机身会真的更烫

「性能优化 → 去温控」会把 31 个 CPU / GPU / 表面温感 zone 置为 `disabled`，并把限频、降亮阀门清零。开启后：

- 机器**不再主动降温**：长时间游戏、录像、导航，尤其边充边玩，机背与电池会比平时明显更热；
- 电池长期工作在高温下会**加速老化**，长期高温存在鼓包风险；
- 温度到芯片临界点时，硬件保护仍会**强制降频甚至关机**——不是"不会热"，而是"最后一刻才管"。

所以这一项**默认关闭**，只有在你明确知道自己要什么、并能接受上述后果时才手动打开。日常使用、夏天户外、边充边玩都不建议开。

### 2. 开机崩溃修复：会禁用「WiFi 万能钥匙极速版」

「系统控制与日志 → 开机崩溃修复」对应包 `com.wifi.masterkey.lite`，**默认开启**。它不是一个"优化"，而是一个踩过的坑的补丁：

- 2026-10-02 实测：`system_server` 在 `SyncManager.sendOnUnsyncableAccount()` 里向该 App 的 `AccountSyncV5Service` 发起 `bindService`，抛 `SecurityException: Not allowed to bind to service`，导致 system_server 崩溃循环（单次开机连崩 3 次），机器卡在开机动画进不去系统。
- 禁用该包后，它的 SyncAdapter 不再被枚举，`bindService` 不再发生，开机恢复正常。

**影响**：装有该 App 的设备，「WiFi 万能钥匙极速版」会被禁用（应用不可用）。**没装这个 App 的设备上，本项什么都不做**（脚本先查包是否存在，不存在直接跳过）。

**为什么默认开**：它防的是"进不去系统"，默认开比默认关安全。若你确定不需要，可在界面里关掉——关掉后模块**完全不碰**这个包，既不禁用也不改它的状态。卸载模块时无论开或关，都会按安装前记录的归属基线还原。

## 更新日志

见 [Releases](https://github.com/starlifezzz/Logd_Disabler_ColorOS16/releases) 与提交记录。

## 许可

本项目采用 **CC BY-NC-ND 4.0**（署名-非商业-禁止演绎 4.0 国际协议，全文见 [LICENSE](LICENSE)），CC 家族最严格的一档：

- ❌ **禁止二次修改**：任何魔改、衍生、改造都需事先获得作者授权（获准时也必须署名并声明改动）
- ❌ **禁止商业化**：不得用于任何商业用途
- ✅ 允许非商业目的的原样分享与个人使用：转发须署名原作者并附协议链接
- ❌ 不得移除、隐藏原有版权与协议声明

Copyright © 2026 zhangchongjie

---

## ❤️ 打赏

用得顺手的话，请作者喝杯奶茶 ☕ —— 每一份支持都是继续更新的动力。

<p align="center">
  <img src=".github/sponsor/alipay.jpg" width="260" alt="支付宝收款码">
  &nbsp;&nbsp;&nbsp;&nbsp;
  <img src=".github/sponsor/wechat.png" width="260" alt="微信支付收款码">
</p>
<p align="center">
  <sub>支付宝 · 微信支付（扫码即达，感谢支持 🙏）</sub>
</p>
