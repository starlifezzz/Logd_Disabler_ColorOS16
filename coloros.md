# ColorOS16 避坑铁律与事故记录

> 本文每一条都是实机踩出来的。**违反过的后果见原文，2026-10-02 差点变砖。**

---

## 🚨 P0 铁律：系统包只能 `pm disable-user`，绝不能 `pm uninstall`

### 事故经过（2026-10-02）
- 按教程手动执行 `pm uninstall --user 0 com.oplus.thirdkit`（以为只是"禁用"）
- **连续不开机**：00:34、00:36 两次卡死，PMS 75 秒等不到（`service check: not found`），
  system_server 崩溃循环，连 DropBox 都没活到写第一条日志
- 抢救：**把所有禁用项删掉、让系统重建包数据库才进得系统**
  （484 个包 firstInstallTime 全部重置为 01:40:31-33，thirdkit 回到已安装态 → 01:40 立刻开机）

### 根因（同机同版本，唯一变量是 disable vs uninstall）
| 操作 | 包状态 | 结果 |
|---|---|---|
| `pm disable-user --user 0` | 仍在 PMS，仅停用 | ✅ 09-29 模块三连开机实证安全 |
| `pm uninstall --user 0`（含 `-k`） | 从 user0 消失 | ❌ ColorOS16 启动早期代码硬依赖其"安装存在" → system_server 起不来 → bootloop |

### 铁律清单
1. **一切"禁用"只允许**：`pm disable-user --user 0 <pkg>`
   （回滚：`pm enable --user 0 <pkg>`，uninstall.sh 自动执行）
2. **所有教程里的 `pm uninstall --user 0 <系统包>` 一律无视**——包括带 `-k` 的：
   `-k` 只保留数据，包照样从 user0 消失，效果与翻车命令完全相同
3. **不可禁黑名单**：`system_server` / `zygote` / `zygote64` / `surfaceflinger` /
   `android.hardware.*` / **`android`** / **`oplus`** /
   `oplus.security.server` / `oplus.sensor`
   （`android` = framework-res 宿主，`oplus` = ColorOS 框架资源包，禁即 bootloop；
   `.ci/audit_module.sh` 已钉死精确包名匹配）
4. **onservices.txt（开机自启表）中的进程一律不禁**
5. 关键词只初筛，最终判定对照 `reference/disabletable.txt` 中文标注

### 抢救手册（本次实证有效）
1. 卡开机 → 删禁用记录让包库重建 → 进系统
2. 重建的后果（要知情）：
   - 所有包 firstInstallTime 重置为重建时刻
     （`dumpsys package <pkg> | grep -i firstInstallTime` 全是今天 = 重建过）
   - 所有 `enabled=2` 禁用态被洗掉（模块 09-29 实禁的 **56 项**系统禁用全丢）
   - **模块配置 `/data/adb/Logd_Disabler_ColorOS16/config.json` 不受影响** →
     重启后 service.sh 自动重放全部禁用。**禁用状态易失、配置持久，模块就靠这个自愈**
   - ota/sau 被洗回启用 + post-fs-data 已把 update_engine bind 成 1 字节哑包 →
     `Failed to find update_engine` 每 2 秒崩（本次 ×20）→
     `pm disable-user --user 0 com.oplus.ota com.oplus.sau` 止血
3. 包库重建副作用：权限/默认态回到出厂一轮，遇到个别应用通知/权限异常重开一下即可

### ✅ 模块内同款雷区（2026-10-02 当日发现、当日已修）
- `service.sh` disable_pkg 曾有 **方法2 fallback = `pm uninstall -k --user 0`**（原 L265-266）——
  与事故命令同族。若某次 `pm disable-user` 瞬时失败走到它、目标恰是启动关键包
  （如遥测组里的 thirdkit）→ 会复刻本次不开机
  - 历史触发：**0 次**（service.log 无任何 uninstall 记录），未流血
  - **已修**：fallback 整段移除，失败直接走 `pm disable --user 0` 全局停用——
    永不做减法（不卸载），只允许停用
  - 【v2.3.19-fix 2026-10-12】**恢复侧 install-existing 也已移除**（原以为"救用户手动卸载的包"，
    实为事故源：见下节误复活记录）。恢复只走 `pm enable`，且按归属基线判定。
- **CI 已补**：`.ci/audit_module.sh` 红线——任何 `*.sh` 出现执行 `pm uninstall`
  （`pm ` / `cmd package ` / 带 `-k` 变体）**或 `install-existing`** 即判红；
  注释行排除，坏样本验证通过

### 🚨 P1 事故：装模块后用户自己卸载的 App 被"复活"（2026-10-12 修复）
- **现象**：用户先用爱玩机卸载 App（子系统/数据基础/互联/乐划等，= `pm uninstall --user 0`），
  安装本模块后这些 App 全部自行回来，且每次开机都重现
- **根因**：恢复路径只认 config 开关，无法区分"本模块禁的包"与"用户自己禁/卸的包"：
  - 可见但被禁用 → 无条件 `pm enable`（覆盖用户自己的禁用）
  - 对 user0 不可见 → `cmd package install-existing`（把用户卸载的包复活）
  - 新装默认 config 全 false → 每次开机全走恢复分支 → 表内每个被卸/禁包每次复活
- **修复**：新增**包归属基线** `pkg_orig_state.txt`（首次触碰前登记真实状态，只记一次）：
  - 禁用：基线非 `enabled`（用户既存状态）→ 不接管、不 disable
  - 恢复：仅 基线=`enabled` 且当前被禁用 → `pm enable`；基线 `disabled/missing` 一律不动
  - 自举 `bootstrap_orig_states` 幂等合并（旧版升级按 config 认领，全新安装按真实状态登记）
  - 三处同源：`service.sh`(disable_pkg/enable_pkg/bootfix) · `uninstall.sh`(按基线回滚) ·
    `webroot/index.html`(onPkgSwitch 恢复只发 pm enable)
- **教训**：模块不得假设"config 就是全部真相"——设备上存在**模块之外的既存状态**
  （用户自己禁/卸的包），必须用"基线"显式区分归属，禁用前先取证。

### keep 白名单语义（WebUI `<key>_keep`，本次实测确认）
- keep = **保留启用**：disable_pkg 跳过该包；若它处于禁用态，还会被**反向 `pm enable` 拉回**
  （service.sh L229-241；09-29 日志 `⏭️ 跳过（WebUI 白名单保留）: com.heytap.mcs` ×2）
- 想让某包被模块**持久禁用** → 必须把它**移出**对应 `_keep`，手动禁一次会在下次开机被拉回

---

## 同日抓到的检查器假 0（写检查器前必读）
- dropbox 文件名是 **epoch 毫秒** → 日期 glob `*26-10-02*` 匹配 0 个 ≠ 零崩溃
  （真实 20 个，内容匹配才拿到）
- 本机 `grep -E` **不认 `\b`** → 眼前明摆着的 `Process: com.oplus.sau` 计数为 0
- **规则：任何"0 命中"结论，先用已知阳性样本验证模式本身有效，再采信**

---

## 事故时间线（2026-10-02）
| 时间 | 事件 |
|---|---|
| 00:34 / 00:36 | 两次卡开机（PMS not found 75s+，system_server 崩溃循环） |
| ~01:39 | 抢救操作（config.json mtime 01:39） |
| 01:40:31-33 | 删禁用项 → 包库重建，thirdkit 回到已安装 → SYSTEM_BOOT 恢复 |
| 01:40-01:43 | 模块处于 KSU disable 态：service/boot-completed 被 skip×3，post-fs-data 照跑 → 半瘫 |
| 01:42:28-01:53:58 | ota/sau `Failed to find update_engine` 崩溃 ×20 |
| 01:44 | 模块在 KSU 管理器重新启用（disable 标记消失） |
| 02:06 | 手动 `pm disable-user` ota+sau 止血（enabled=3，进程清零） |
| 03:47 | 刷入含全部修复的 zip（模块文件 mtime 全 03:47） |
| 03:55:31 | **二次事故开始·开机失败①**（SYSTEM_SERVER 无栈重启，prev pid 3972=全新 system_server） |
| 04:18:34 / 04:33:04 / 04:36:50 / 04:40:59 | 开机失败②③④⑤（均无栈标记，prev pid 全在 4000 段=每次都是整机新开机） |
| 04:42:21 | 开机⑥ → 04:43:31/49、04:44:06 **有栈三连崩**（USER_UNLOCKED→SyncManager→bind masterkey，uptime 69/87/104s 同 boot 累加）→ 整机重启 |
| 04:45:43 | 开机⑦ → 04:46:45/04:47:02 有栈两崩 → 整机重启 |
| 04:47:3x | 开机⑧ → 04:47:50-52 service 执行完毕 → 进桌面（**第 8 次尝试才逃逸**） |
| 10:19-10:41 | 早间复发：10:37:06/10:37:38/10:46:40 有栈三崩（同栈）+ camera provider tombstone |
| 11:18 | 设备侧手写 `[BootFix]` 块植入 service.sh（43428 字节版） |
| 11:21-11:25 | WebUI 白名单三轮试调（5→2→3 包，逐次开机复核行实证）终定 mcs,thirdkit,pantanal.ums → thirdkit 回启用 |
| 11:21-11:36 | 三连开机 BootFix 生效 `[BootFix] ✅`；11:25:47 SYSTEM_RESTART + 11:26:01 一次无栈重启（BootFix 后唯一，原因不明，包已禁不可能是 masterkey） |
| 11:36 | 该次开机 → **至 16:12 重启前零新增崩溃**（其间输密码解锁多次、跑完全套门禁；14:01 复核 dropbox 最新仍是该次 SYSTEM_BOOT，16:19 复核 11:36→16:15 全零） |
| ~12:10 | BootFix 移植回源码（md5 与装机版一致）+ uninstall.sh 补录 masterkey |
| 16:13 | **单变量复测通过**：用户将 thirdkit 移出白名单（回模块默认禁用态），BootFix 钉住万能钥匙 → 开机零崩溃（16:15:54 SYSTEM_BOOT 后 dropbox 零增量）；与 10:46:40 崩（当时 thirdkit 恰在禁用态）合成 **2×2 正交证据：唯一变量=万能钥匙** |

---

## 🚨 P1 事故：SyncManager 绑 WiFi万能钥匙 lite 崩溃循环（2026-10-02 03:55 起，**与 thirdkit 无关**）

### 现象与取证（dropbox 实证，二次深挖 03:55 窗口全量提取）
- **用户体感 = 无限重启不进桌面、输完密码就重启** → 与根因咬合到秒级：
  `USER_UNLOCKED` 广播**只在输完锁屏密码、CE 存储解锁那一瞬间发出**；崩溃 100% 挂在该广播上
- **凌晨至少 8 次开机失败**：03:55/04:18/04:33/04:36/04:41 五条 `SYSTEM_SERVER@` 无栈重启
  （`can not get efficacious log`，prev pid 全在 4000 段=每次整机新开机即崩）+
  04:42 开机三连崩、04:45 开机两连崩（uptime 反推开机时刻逐毫秒重合）→ 04:47 第 8 次才进系统
- **有栈崩溃现存 8 条（11:18 时点统计 9 条，1 条被 dropbox 轮转）同一堆栈、零条提及 thirdkit**：
  `USER_UNLOCKED` 广播 → `SyncManager.sendOnUnsyncableAccount()` →
  bind `com.wifi.masterkey.lite/com.lantern.daemon.farmore.syncnew.AccountSyncV5Service` →
  `SecurityException: Not allowed to bind to service` → system_server 死 → 整机重启 → 再输密码 → 再崩
- 崩溃账号实存：`Account {name=万能钥匙, type=com.wifi.masterkey.lite2.sync.new}`；
  该 app 是 **lantern 保活全家桶**（双进程守护/PersistentService/一堆 wakeup receiver，
  自定义权限 `FARMORE_EXPORT_BROADCAST` 等）——SyncAdapter 是其拉活组件
- 该包 firstInstall/lastUpdate=01:40:33（包库重建同分钟重建态）；在 `services.txt:195`
  但**不在 disabletable** → 模块从未禁过它（service.log 全量零 masterkey 行，BootFix 前）
  → **模块无辜、thirdkit 无辜**（9/8 有栈崩溃零 thirdkit 引用）
- ⚠️ 诚实边界：① 5 条无栈标记没有堆栈，凭时间窗+pid 模式**推定同因**非实证；
  ② "雷何时埋的"无法完全还原（01:40-03:55 的 dropbox 已被轮转，最可能解释是
  01:40 包库重建把该包状态洗活）；③ 5 条无栈里 system_server 死得太快连日志都没写下

### 修复（设备侧手写 `[BootFix]` 块，11:18 植入）
- PMS 就绪即 `pm disable-user` 该包（实测首崩前 ~47s 完成），硬编码、不受 config 开关控制
- 禁用后 SyncAdapter 不再进 SyncManager 枚举 → 不再 bind → 不再崩；
  `package-restrictions.xml` 持久，一次成功永久生效
- 实测四连生效（11:21/11:23/11:25/11:36 日志 `[BootFix] ✅`），此后零崩溃
- ⚠️ 注释声称"uninstall.sh 收录"当时**为假** → 2026-10-02 ~12:10 已补录
  （源码+装机两侧），回滚语义闭环：`pm enable` 或卸载模块会把该包 `pm enable` 恢复——
  **但"恢复"= 把雷重新埋回去**，复发条件与根治路线见下节

### 复活陷阱与根治路线（2026-10-02 14:01 终验）
- **复发条件仍在**：账号 `万能钥匙` 留在系统里；包禁用 → SyncManager 不枚举 → 当前安全。
  任何把它重新启用的动作（手动 `pm enable`、**卸载模块触发 uninstall.sh 恢复清单**）→
  下次输密码解锁可能复刻崩溃循环
- **根治 = 卸载 app 本身**（推荐）：设置 → 应用 → 万能钥匙极速版 → 卸载。
  它是普通第三方 app（`pkgFlags` 无 SYSTEM、codePath=/data/app）→ 卸载**不触 P0 红线**
  （P0 针对"启动依赖其安装存在"的系统包——thirdkit 是、它不是）；
  账号 + 5 个 SyncAdapter 随包消失 → 复发条件归零；
  此后 uninstall.sh ALL_PKGS 恢复清单找不到它 → 自动 SKIPPED，无害
- **毒瘤判定**（行为级实锤、法律级不够——无偷盗/劫持实证）：**5 个 SyncAdapter**
  （正常 app 0-1 个，拿系统同步框架当免费闹钟）+ 双进程守护 `doubleprocess` +
  `abdh/bobm/mcwm/ovdb/qbdm` 混淆唤醒 receiver + 穿山甲/JPush/Mob 夹带；
  来源 `installerPackageName=com.android.vending`（Play 商店安装）、/data/app 目录
  mtime 2026-04-14（至少 4-14 就落盘，非灾难期装入）；实授 22 项权限含 `GET_TASKS`，
  无障碍/通知使用权**未开**（未到劫持层）
- 14:01 终验：包 disabled ✓、相关进程 0、模块 disable 标记无、
  dropbox 最新 = 11:36 SYSTEM_BOOT → **11:36 至 14:01 零新增崩溃**

### 教训
1. **开不了机 ≠ 我们禁的包**：先读 dropbox 堆栈定罪，8/8 有栈崩溃零 thirdkit 引用
2. 第三方 app 的坏 SyncAdapter 能把 system_server 绑崩——**用户应用账号同步是 ColorOS16 盲区**；
   app 只是雷管，炸药桶是系统 SyncManager 自己（bind 异常未被 catch、直接杀 system_server）
3. **取证要把 dropbox 全部标签扫一遍**：同一现场有 `system_server_crash`（有栈）、
   `SYSTEM_SERVER@`（无栈重启标记）、`SYSTEM_BOOT`、`SYSTEM_RESTART` 四种标签——
   第一轮只 grep crash 标签漏掉了 03:55-04:41 的 5 条无栈标记，"4 点前证据已失"结论**是错的**；
   且 dropbox 环形缓冲会被洪峰冲掉 → **事故后取证要趁早**
4. 设备侧手改的修复**必须回流源码**，否则下次打包即丢失（本次已用字节级断言移植：装机=源码+30行块）
5. **门禁"卡死"先查环境、再怀疑代码**：2026-10-02 verify 三次假死 = 息屏冻结
   （连 `sleep 20` 都停 13 分钟）+ FUSE 存储抖动（连读 10 次 index.html 耗时 **6m17s**，
   verify 几百次小读被放大成 5 分钟跑不完）；跑门禁前先 `termux-wake-lock`，
   正常 verify 仅 10-60s；CPU 全程 idle 的"卡死"是存储层，不是死锁

## ColorOS16 后台管控与网络入站实测（2026-10-31）

排查对象：KDE Connect（`org.kde.kdeconnect_tp`，uid 10410）在熄屏/重启后 PC 连不上。
**与本模块无关**（v2.3.21 时代同样不通，且对照机 mi2s / MoKee Android 10 同网络同 PC 正常）。
结论落在 ColorOS 的两套独立机制上，记录于此，避免下次重走弯路。

### 一、`o-kill(N)` 编号（实测）

| 编号 | 后缀（仅 logcat 可见） | 语义 | 实测 |
|---|---|---|---|
| 2 | `with oneclick` | 一键清理 / 内存优化 | 15:00:23 发生，1 秒后自动重启 |
| 35 | `with boot_clear` | **开机批量清扫** | 15:02:19、15:40:39 各一次 |
| 72 | — | **语义未验证** | 11:55:29 出现 |

- `with oneclick` / `with boot_clear` 后缀**只出现在 logcat 的 `am_kill` 行**；
  logd 关掉后只剩 `exit-info` 里的 `o-kill(N)` → **编号对照表是必需品**
- `boot_clear` 是**批量**：15:40:39.128 杀 KDE Connect，.130 杀 uid 10314 等，
  同一时刻多包齐杀，非针对单个 app
- 击杀后约 1 秒 `am_schedule_service_restart` 拉起（FGS `START_STICKY`），
  用户侧表现为**约 30 秒断连窗口**（15:40:39 被杀 → 15:41:11 恢复）

### 二、后台锁定不跨重启（实测）

| 状态 | `oom_score_adj` | AMS 标记 |
|---|---|---|
| 最近任务加锁 | **50** | `fg +50 F/S/FGS`，cpuset/cpu 均 `/foreground` |
| 未加锁 | **200** | `F/S/FGS` |
| **加锁后重启** | **200** | 锁已丢 |

→ 锁定只对**当次开机**有效，**挡不住开机清理**。重启后想让它不被 `boot_clear` 扫掉，
只能靠 FGS 自动重启兜底。

### 三、竞速现象：启动早晚决定死活

| 重启 | KDE Connect 启动时刻 | 结果 |
|---|---|---|
| 15:08 | 开机后 **296 秒** | 晚于 `boot_clear` 窗口 → **躲过**（`exit-info` 无新条目） |
| 15:38 | 开机后 **32 秒** | 撞上 15:40:39 `o-kill(35)` → **被杀** |

**教训：别把"这次没被杀"当"配置生效"** —— 可能只是启动得晚。
判定必须看 `/proc/<pid>/stat` 反算的启动时刻，不能只看"现在活着"。

### 四、网络入站按 UID 过滤（BPF，最隐蔽的一个）

现象：进程活着、`[::]:1716` 状态 `0A`(LISTEN)、uid 正确，但**连手机自己的 loopback 都超时**。

物件：

```
/sys/fs/bpf/prog_oplus-netd_skfilter_accept_wlan_uid                  # 入站 accept 的 UID 过滤程序
/sys/fs/bpf/map_oplus-netd_app_accept_wlan_socket_uid_limit_map       # accept 白名单
/sys/fs/bpf/map_oplus-netd_app_drop_wlan_socket_uid_limit_map         # drop 名单
iptables -S INPUT | grep bpf                                          # 规则挂在 INPUT（IPv4/IPv6 都有）
```

**判定顺序（缺一不可，跳步会误判成"app 没启动"）**：

1. `/proc/net/tcp6` 有 `0A` 且 uid 正确 → 进程与 bind 都正常，别再从"没启动"方向查
2. 手机本机 `nc 127.0.0.1 <port>` **也超时** → 丢包在 socket 层，不是网卡/路由/防火墙
3. root(uid 0) 临时监听任意端口能被外部连 + 系统端口（24021/24022）能连 → **按 UID 过滤**，不是全局封锁
4. `iptables -I INPUT 1 -p tcp --dport <port> -j ACCEPT` **无效** → 确认不在 iptables 层
5. 解药：设置 → 电池 → 应用耗电管理 → 该应用 → **「允许完全后台行为」**
   （实测改完 **5~10 秒内生效，无需重启**；TCP 从 `SYN_RECV` 卡死立刻变 `ESTABLISHED`）

排除项（都试过无效，别重复）：Doze 白名单、`cmd netpolicy add restrict-background-whitelist`、
`fw_dozable`/`fw_standby` 链（不存在）、`dumpsys netd` 里的 `NETWORK` 权限列表
（那是**出站**权限，与入站 accept 白名单是两回事）。

**诚实边界**：设备无 `bpftool`，`cat` 该 pin 文件报 `I/O error`，**读不出 map 内容**；
"该 uid 不在白名单"由命名 + 第 3 步行为推定，**非直接读取**。
**不要把这套机制写进模块**：绕过厂商网络管控、且 ColorOS 会在 app 状态变化时重写 map，不持久。

### 五、logd 关闭时的取证手段（本模块 `disable_logd` 生效时必读）

`logcat -d` 返回 0 行，但**排查不需要为此打开 logd**（关/开都要重启，反而重置现场）。

| 需求 | 命令 | 关键点 |
|---|---|---|
| 进程死亡原因 + 时刻（**首选**） | `dumpsys activity exit-info <pkg>` | `#0` 最新；含 `reason=13 (OTHER KILLS BY SYSTEM)`、`description=o-kill(35)`、`FORCE STOP` |
| 存活与优先级 | `cat /proc/<pid>/oom_score_adj`；`dumpsys activity processes \| grep -A3 <pkg>` | `200`=普通 FGS `50`=已加锁 |
| 启动时刻（判是否被杀后重启） | `/proc/<pid>/stat` 第 22 列 ÷ `CLK_TCK`(100)，与 `/proc/uptime` 相减 | PID 变了 + 启动时刻后移 = 中途死过 |
| 端口 | `grep -i :<hex端口> /proc/net/tcp6` | `0A`=LISTEN `01`=ESTABLISHED `06`=TIME_WAIT |
| 接口使用时间戳 | `cmd appops get <pkg> <OP>` | 例 `WRITE_CLIPBOARD: allow; time=+4s ago` 证明写入发生过（读不到内容） |
| 服务/屏幕/Doze | `getprop init.svc.<name>`、`dumpsys power`、`dumpsys deviceidle` | |
| 崩溃/重启标记 | `/data/system/dropbox/`（`SYSTEM_BOOT@<epoch_ms>`） | 文件名是 **epoch 毫秒**，别按日期 glob |

**exit-info 边界**：`Last Timestamp of Persistence Into Persistent Storage` 是落盘时刻，
之后的条目只在内存里，**重启即丢**。取证要趁早；判断"零击杀"前先看 `#0` 时间戳。

**logcat 唯一不可替代的场景**：需要毫秒级先后顺序。

### 六、环形缓冲的坑（本次实踩）

logd 默认 events 缓冲 **64 KiB**，重启后 5 分钟就可能被冲掉：
15:08 开机，15:13:30 缓冲起点已滚到 15:13:30 —— **15:09~15:13 的 `boot_clear` 窗口整段丢失**。
当时差点据此得出"本次零击杀"的错误结论，实际是**证据不存在 ≠ 事件未发生**。

→ 要抓开机清理，必须在**开机后 60 秒内**连上 adb 持续抓，或直接用 `exit-info`（持久化）。

### 七、bind 源文件不能 mv：EBUSY 被 `2>/dev/null` 吞掉 → 功能静默空转（2026-10-31 修复）

**这是本项目踩过的最隐蔽的一类 bug：代码语法没错、门禁全绿、日志还打「✅ 已生效」，
但核心逻辑整整空转了 11 次开机。**

#### 现象

`hosts.cloud` 里本模块的标记段累积到 **13 段重复**（241804 行），每开机固定 +7 行：

| 开机时刻 | 日志行 |
|---|---|
| 13:50:07 | `hosts 共 241769 行` |
| 14:10:55 | `hosts 共 241776 行` |
| 14:30:32 | `hosts 共 241783 行` |
| 14:59:45 | `hosts 共 241790 行` |
| 15:08:51 | `hosts 共 241797 行` |
| 15:38:04 | `hosts 共 241804 行` |

11 段 × 7 行 = 77 行，正好等于 241804 − 241727。

#### 根因（实锤）

`cloud_hosts_apply` 的落盘步骤是「`sed` 剥掉旧标记段 → `mv` 覆盖 `hosts.cloud` → `>>` 追加新段」。
但 `hosts.cloud` **一旦成为 bind 挂载的源文件**，`mv` 就被内核拒绝：

```sh
$ mv -f /data/adb/logd_disabler/probe.chk /data/adb/logd_disabler/hosts.cloud
mv: bad '/data/adb/logd_disabler/probe.chk': Device or resource busy
$ echo $?
1
```

而代码写的是 `mv -f ... 2>/dev/null` —— **错误被吞掉，`mv` 失败后脚本继续执行**：

- 「剥离旧段」的结果（临时文件）没被搬过去 → **剥离永久失效**
- 紧接着的 `>>` 追加照常执行 → 每次 apply 净增 7 行
- 最后的 `cloud_hosts_active`（`grep 标记段`）当然命中 → 日志打「✅ 已生效」

#### 连带发现：本模块文件与 bindhosts 是同一个 inode

```
stat: /data/adb/logd_disabler/hosts.cloud               dev=65101 inode=568928
stat: /data/adb/modules/bindhosts/system/etc/hosts      dev=65101 inode=568928
```

`/proc/mounts` 里 bindhosts 的 hosts 路径本身也是挂载点，谁挂谁**未验证**。
后果：本模块写一次，bindhosts 视图同步变，反之亦然。

#### 影响分级（诚实）

| 维度 | 影响 |
|---|---|
| DNS 解析 | **无影响** —— 重复的是同样 5 个域名，解析结果一致 |
| 开关语义 | **有影响** —— 只关 `block_scene_hosts` 时旧域名剥不掉，必须重启才生效 |
| 挂载层 | **有影响** —— 每次 apply 多挂一层，实测叠到 9 层（重启清零） |
| 开机/系统稳定性 | 无影响 |

#### 修复

1. 先把「最终内容」完整算进临时文件，再做**幂等短路**：`cmp -s tmp /system/etc/hosts` 相同则跳过挂载
2. 落盘：`mv` 优先（原子）；**失败则 `cat tmp > file` 原地覆盖同一 inode**（挂载视图立即同步，不触发 EBUSY）
3. 两条路径都失败 → 写日志 + `return 1`，不再静默
4. `localhost` 安全闸提前到落盘之前（防空 hosts 断解析）

#### 验证（修复后 17:11 开机实测）

```
标记段      13 段 → 1 段
行数        241818 → 241734，不再递增
挂载层      9 → 2
日志        17:11:15 [CloudHosts] 内容已是最新，跳过重复挂载
开机复核    标记段在位（5 条 0.0.0.0）      ← 修前是 55 条
开关语义    临时关 block_scene_hosts → 域名 5→3 且段数仍 1（旧版必须重启才生效）
DNS         localhost / 被拦域名→127.0.0.1 / 正常域名解析 全部正常
```

#### 教训（写挂载类逻辑前必读）

1. **`mv` / `rm` 打在 bind 挂载的源文件上会 EBUSY**；要么原地覆盖（同一 inode），要么先 `umount` 自己的层
2. **`2>/dev/null` + 不管返回值 = fail-open**。凡是「重命名/删除/挂载」这类可能失败的动作，
   必须 `if ! cmd; then 兜底或报错; fi`，**不许靠 `2>/dev/null` 让错误消失**
3. **「✅ 已生效」的判据不能只看「标记段在不在」** —— 追加也能让标记段存在。
   要判「内容是不是恰好一份」，得比对完整内容（`cmp`）而不是 `grep -c`（`grep -c` 还能给出 11）
4. **环形日志里「行数递增」是最强的 bug 指纹**：正常幂等操作的行数应该稳定，
   一旦出现 +7 / +N 的等差递增，几乎必然是「剥离失败 + 追加成功」
5. 同一个坑的变体：`sed -i`（内部就是 rename）同样会在 bind 源上失败，本项目统一改用
   `sed ... > tmp` + `cat tmp > file`

---

## 云控 hosts 三重失效：cron 覆盖 / 挂载传播 / SELinux 标签（2026-11-01）

上一节的修复（幂等 + 原地覆盖）让「每次 apply 净增 7 行」的问题消失，但真机 19 小时长跑后
发现**域名拦截仍然静默失效**：`hosts.cloud` 标记段 0 段 0 域名、`sms.ads.heytapmobi.com`
解析回真实 IP `111.206.136.11`。逐层挖出三个独立根因，全部实证。

### 根因一：bindhosts 每天 10:00 的 cron 会重写它自己的 hosts

```
hosts.cloud  mtime=2026-11-01 10:00:03  size=7005625  inode=568928
尾部内容     # bindhosts v215
crontab      0 10 * * * sh /data/adb/modules/bindhosts/bindhosts.sh --force-update
```

`bindhosts.sh --force-update` 重新生成 `$MODDIR/system/etc/hosts`（7 MB 广告拦截列表），
**把本模块写在同一个 inode 里的标记段整段覆盖掉**。所以不是「我们没写进去」，而是「写进去了，
被别人按天擦掉」。

### 根因二：`/data` 是 shared peer group，挂载会互相复制

```
372  55  254:77 /adb/logd_disabler/hosts.cloud            /system/etc/hosts              shared:60
606  372 254:77 /adb/modules/bindhosts/system/etc/hosts   /system/etc/hosts              shared:60
636  206 254:77 /adb/modules/bindhosts/system/etc/hosts   /data/adb/logd_disabler/hosts.cloud  shared:60
```

- `mount 636` 的语义是：**bindhosts 把它的 hosts bind 到了本模块的 `hosts.cloud` 路径上**
- 起因是 `/data`（id=206）本身 `shared:60`，任何「源在 `/data` 下」的 bind 都继承该组；
  在其上再挂载会按「同一相对路径」复制到其它成员 → 三个路径互为 peer
- 实测：挂载 `.own` 后 inode 同时变成 `1358455`（三处一致），随后 cron 一跑三处标记段全没
- **toybox `mount` 不支持 `--make-private`**：`mount --make-private /system/etc/hosts` 会把参数
  当未知选项去读 `/etc/fstab`，报 `bad /etc/fstab` 且 **rc=0（假成功）**
- 可行的断开方式：`umount` 掉挂在本模块路径上的影子层。实测卸掉后，在 `/system/etc/hosts`
  挂探针文件不再传播到 bindhosts 路径（`peer2.sh`：探针 inode 1358733 未扩散）

⚠️ `umount` 本身也**会传播**：卸 `hosts.cloud` 的影子层会连带移除 `/system/etc/hosts`
上对应的 bindhosts 层（实测 3 层 → 1 层）。这不是 bug，是必须利用/防范的特性。

### 根因三（最致命）：`/data/adb` 下文件的 SELinux 标签让整个 hosts 被忽略

```
-rw-r--r-- 1 root root u:object_r:adb_data_file:s0  341  /system/etc/hosts   ← 源文件在 /data/adb 下
$ chcon u:object_r:system_file:s0 /data/adb/logd_disabler/hosts.cloud
$ ping -c1 sms.ads.heytapmobi.com
PING sms.ads.heytapmobi.com (127.0.0.1)     ← 立即生效
```

- 内容完全正确（5 条 `0.0.0.0` 都在），但普通 app 读不到 `adb_data_file` → **解析器直接忽略整份 hosts**
- 判定陷阱：`ping` 已知域名可能命中缓存；要用**从未解析过的域名**做探针，
  实测探针返回 `unknown host` = 解析器没读 hosts（不是缓存问题）
- **含义**：此前能用，只是因为顶层恰好是 bindhosts 的 `system_file` 文件。
  **没装 bindhosts 的用户，云控拦截一直是无效的** —— 这是长期存在的严重缺陷

### 修复过程中新踩的两个坑（都已修）

1. **`mv` 换掉 inode → 挂载根变 `//deleted` → 之后所有 bind 报 ENOENT**
   ```
   mountinfo: 372 55 254:77 /adb/logd_disabler/hosts.cloud//deleted  /system/etc/hosts
   mount -o bind /data/adb/logd_disabler/hosts.cloud /system/etc/hosts
   mount: ...: No such file or directory     ← 源和目标都存在，仍失败
   ```
   原因：`mv` = 建新 inode + 改名，旧 bind 仍引用已删除 inode；挂载传播到 `//deleted` 路径失败。
   → 落盘**一律 `cat tmp > file` 原地覆盖**，永不用 `mv`
2. **先 unshadow 再读 = 丢掉用户基线**
   先卸影子层会（经传播）连带移除 `/system/etc/hosts` 上的 bindhosts 层，
   于是读到的只是本模块自己的 341 字节旧文件 → **241727 行广告拦截基线被整份丢弃**。
   → 顺序必须是**先读生效 hosts、再断传播**

### 最终修复清单（`cloud_hosts.sh`）

| 步骤 | 做法 | 防的是 |
|---|---|---|
| ① 读 | `sed` 剥旧标记段，读的是**当前生效** `/system/etc/hosts` | 丢基线 |
| ② 断传播 | `cloud_hosts_unshadow`：卸掉挂在本模块路径上的影子层 | 写进对方文件 |
| ③ 清残 | `cloud_hosts_drop_stale`：卸掉 root 以 `//deleted` 结尾的层 | 后续 mount ENOENT |
| ④ 选目标 | 仍被覆盖 → 私有副本 `hosts.cloud.own` | 卸不掉时的兜底 |
| ⑤ 落盘 | `cat tmp > file`（原地覆盖，保 inode） | `//deleted` 挂载根 |
| ⑥ 打标 | `chcon u:object_r:system_file:s0` + 标签校验 | app 读不到 hosts |
| ⑦ 挂载 | `mount -o bind` | — |
| ⑧ 判活 | **生效层 inode == 源文件 inode** 且标记段在位 | 只看标记段的假绿 |
| ⑨ 幂等 | 同上条件成立则跳过，不再叠层 | 挂载层膨胀 |

### 验证（2026-11-01 12:44 真机开机后实测）

```
代码        cloud_hosts.sh 240 行 md5=6a06e2165e5ab250b74a998ff1a57479
hosts       241734 行  标记段=1  域名=5  标签=u:object_r:system_file:s0  层=2
//deleted   0 个
DNS         sms.ads / htms → 127.0.0.1    www.baidu.com 正常
cron 验收   手动跑 bindhosts --force-update 后：标记段仍 1、241734 行、域名 5、DNS 仍 127.0.0.1
            bindhosts/hosts 里标记段=0（证明没写进对方文件）
核心运行态  logd=stopped  mediametrics=running(18568)  config 41 键  WiFi/蓝牙/音频正常
```

### 教训

1. **别假设「文件内容对 = 功能生效」**：SELinux 标签能让整份文件被忽略，权限位看着全对
2. **`/data` 是 shared peer group**：源在 `/data` 下的 bind 会与其它挂载互相复制，
   `umount` 也会传播；断开链路只能卸影子层（toybox 无 `--make-private`）
3. **`mv` 永远不要用在可能被 bind 引用的文件上**：换 inode 会留下 `//deleted` 挂载根
4. **依赖顺序就是正确性**：「先读后断」与「先断后读」结果差 7 MB 数据
5. **第三方模块的定时任务要当环境事实对待**：每天 10:00 的一次 cron 足以让功能静默失效，
   验证不能只看「刚装完那一刻」
