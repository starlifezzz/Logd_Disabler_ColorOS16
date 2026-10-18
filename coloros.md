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
