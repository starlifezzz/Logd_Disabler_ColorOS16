#!/system/bin/sh
# ================================================================
# ColorOS16 优化模块 - service.sh (late_start service)
# 执行时机：系统服务启动后
# 配置来源：/data/adb/Logd_Disabler_ColorOS16/config.json
#           （由 WebUI 写入，service.sh 只读执行）
# 支持双向操作：开启时优化，关闭时恢复原状
# v2.0 架构：30 个手写 if 块重构为"数据表 + 通用循环"，
#           新增禁用项只需在 PKG_TABLE 加一行，无需新增逻辑块
# ================================================================

MODDIR=${0%/*}
PROP_PREFIX="persist.sys.coloros16_optimize_gui."   # 仅用于旧属性迁移（v1.x 兼容）
CONFIG="/data/adb/Logd_Disabler_ColorOS16/config.json"
WORK_DIR="/data/adb/logd_disabler"
LOG_FILE="$WORK_DIR/service.log"

mkdir -p "$WORK_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "========== service.sh 开始执行 =========="

# ===================== 配置读取 =====================
# 【v2.0】所有开关状态统一从 config.json 读取（WebUI 唯一写入者）
is_on() {
    # 匹配形如 "  "key": true," 或 "  "key": true } 的行
    grep -qE "[\"']${1}[\"'][[:space:]]*:[[:space:]]*true" "$CONFIG" 2>/dev/null
}

# 读取 keep 白名单（逗号分隔字符串），无则返回空
get_keep() {
    grep -E "[\"']${1}_keep[\"'][[:space:]]*:[[:space:]]*" "$CONFIG" 2>/dev/null \
        | sed -E 's/.*: *"([^"]*)".*/\1/' | head -1
}

# ===================== 旧属性迁移（v1.x → v2.0） =====================
# 首次运行：若 config.json 不存在，则从旧 persist.sys.coloros16_optimize_gui.*
# 属性一次性迁移生成，保证升级不丢用户配置。
MIGRATED=0
if [ ! -f "$CONFIG" ]; then
    log "[迁移] 未找到 config.json，尝试从旧 persist 属性迁移..."
    CONFIG_DIR="$(dirname "$CONFIG")"
    mkdir -p "$CONFIG_DIR"
    # 全部 30 个开关 key（含 2 个总开关），与 WebUI FEATURES 一一对应
    ALL_KEYS="disable_logd block_ota lock_developer_options block_ads_and_tracking kill_redundant_processes system_prop_toggles memory_io_optimization extra_kernel_optimization disable_health_services disable_network_monitoring disable_gamespace disable_wallet_services disable_backup_services disable_ai_assistants disable_voice_assistants disable_theme_services disable_network_optimization disable_security_services disable_media_services disable_system_tools disable_speedview disable_app_recover disable_double_tap disable_notification_mgr disable_device_link disable_device_connect disable_remote_control disable_travel_engine disable_settings_related disable_screen_services"
    # keep 白名单 key（有子包的功能）
    KEEP_KEYS="block_ota_keep block_ads_and_tracking_keep disable_health_services_keep disable_network_monitoring_keep disable_gamespace_keep disable_wallet_services_keep disable_backup_services_keep disable_ai_assistants_keep disable_voice_assistants_keep disable_theme_services_keep disable_network_optimization_keep disable_security_services_keep disable_media_services_keep disable_system_tools_keep disable_speedview_keep disable_app_recover_keep disable_double_tap_keep disable_notification_mgr_keep disable_device_link_keep disable_device_connect_keep disable_remote_control_keep disable_travel_engine_keep"
    {
        echo "{"
        echo "  \"version\": 2,"
        first=1
        for key in $ALL_KEYS; do
            val=$(getprop "${PROP_PREFIX}${key}" 2>/dev/null)
            [ "$val" = "true" ] && v=true || v=false
            [ $first -eq 0 ] && echo ","
            printf '  "%s": %s' "$key" "$v"
            first=0
        done
        for kkey in $KEEP_KEYS; do
            kval=$(getprop "${PROP_PREFIX}${kkey}" 2>/dev/null)
            echo ","
            printf '  "%s": "%s"' "$kkey" "$kval"
        done
        echo ""
        echo "}"
    } > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
    MIGRATED=1
    log "[迁移] 完成：已生成 config.json"
fi

# 配置缺失或损坏时兜底：生成全 false 默认配置
if ! grep -q '"version"' "$CONFIG" 2>/dev/null; then
    log "[迁移] config.json 无效，生成默认配置（全部关闭）..."
    CONFIG_DIR="$(dirname "$CONFIG")"
    mkdir -p "$CONFIG_DIR"
    {
        echo "{"
        echo "  \"version\": 2,"
        ALL_KEYS="disable_logd block_ota lock_developer_options block_ads_and_tracking kill_redundant_processes system_prop_toggles memory_io_optimization extra_kernel_optimization disable_health_services disable_network_monitoring disable_gamespace disable_wallet_services disable_backup_services disable_ai_assistants disable_voice_assistants disable_theme_services disable_network_optimization disable_security_services disable_media_services disable_system_tools disable_speedview disable_app_recover disable_double_tap disable_notification_mgr disable_device_link disable_device_connect disable_remote_control disable_travel_engine disable_settings_related disable_screen_services"
        first=1
        for key in $ALL_KEYS; do
            [ $first -eq 0 ] && echo ","
            printf '  "%s": false' "$key"
            first=0
        done
        echo ""
        echo "}"
    } > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
fi

# ===================== 辅助函数 =====================

# ============================================================
# 【关键修复 2】pm 命令的访问路径
# 现象：service.sh 由 ksud 以 ksu 域执行，直接调用 pm 时
#       servicemanager 拒绝 ksu 域 find package 服务，导致
#       "cmd: Can't find service: package" 或 pm 输出为空
#       （被误判为"包不存在"）。
# 验证：WebUI 通过 ksu 的 root shell 执行 pm 是成功的
#       （系统完全启动后 PMS 就绪）。
# 方案：本模块内所有 pm/cmd 调用统一走 pmx()，优先用 su 提升，
#       无法提升时回退为直接调用（此时 sepolicy.rule 若已生效
#       也能工作）。
# ============================================================

# 一次性探测：su 是否可用（root 直连 ksud）
# 只要 su 能执行且输出包含 root uid 信息即认为可用。
PMX_USE_SU=0
if command -v su >/dev/null 2>&1; then
    SU_TEST=$(su -c "id" 2>&1)
    if echo "$SU_TEST" | grep -qE "uid=0|root"; then
        PMX_USE_SU=1
        log "[pmx] su 提升可用，pm 命令将通过 su 执行"
    else
        log "[pmx] ⚠️ su 存在但提升失败($SU_TEST)，将直接调用 pm"
    fi
else
    log "[pmx] ⚠️ 未找到 su 命令，将直接调用 pm"
fi

# 静默执行（丢弃 stderr，用于状态检查）
# 【修复 v2.0.1】函数内强制 IFS 为默认值再拼接 "$*"：
# 防止调用方残留的 IFS（如通用循环曾用 IFS=','）导致
# su -c 收到 "cmd,package,..." 形式的损坏命令。
pmx() {
    local OLDIFS=$IFS
    IFS=$(printf ' \t\n')
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
    IFS=$OLDIFS
}

# 详细执行（保留 stderr，用于采集 result 排错）
pmx_verbose() {
    local OLDIFS=$IFS
    IFS=$(printf ' \t\n')
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>&1
    else
        "$@" 2>&1
    fi
    IFS=$OLDIFS
}

# ===================== 等待 PackageManager 真正就绪 =====================
# 【关键修复 3】service.sh 在 late_start 阶段执行时，PackageManagerService
# 可能尚未注册完成，此时 pm 命令会报 "cmd: Can't find service: package"
# 并导致 disable_pkg 误判"包不存在"（pm list 输出为空）。
# 之前用 service check 只验证 binder 服务注册，不代表 PMS 内部已就绪
# （systemReady 前 pm list packages 仍返回空）。
# 现在改为：轮询 pm list packages --user 0 直到真正能列出包，最多 120 秒。
log "[PMS] 等待 PackageManager 内部就绪（pm 可列出包）..."
PMS_READY=0
for i in $(seq 1 120); do
    if pmx pm list packages --user 0 2>/dev/null | grep -q "package:"; then
        PMS_READY=1
        log "[PMS] PackageManager 就绪（等待 ${i}s，pm 可列出包）"
        break
    fi
    # 每 15 秒记录一次诊断信息
    if [ $((i % 15)) -eq 0 ]; then
        SVCCK=$(service check package 2>/dev/null | grep -oE "found|running|not found" | head -1)
        log "[PMS] 仍在等待... (${i}s, service check: ${SVCCK:-unknown})"
    fi
    sleep 1
done
if [ "$PMS_READY" != "1" ]; then
    log "[PMS] ⚠️ 120 秒内 pm 仍无法列出包，pm 操作可能失败"
fi

# 【v2.0.2】杀进程：禁用成功后立即清理该包残留进程
# 原因：pm disable-user 只阻止包再次启动，不会杀掉已运行进程
# （实测 exsystemservice/subsys 禁用后进程仍存活，直到重启）。
# 此处补一刀 pkill，让禁用立即生效、立刻释放内存。
# 警告：pkill 会终止该包全部进程（含 :service 子进程），
#       仅作用于刚被禁用的包——keep 白名单保留的包不会走到这里。
# 循环 2 次（间隔 2 秒）：部分常驻系统组件被杀后可能被系统短暂拉起。
kill_pkg_procs() {
    local pkg="$1"
    local i
    # 【v2.0.3】先 am force-stop（对 persistent 进程有效，会连同其所有服务/广播一起终止）
    am force-stop "$pkg" 2>/dev/null
    for i in 1 2 3; do
        if pkill -f "$pkg" 2>/dev/null; then
            log "  🔪 已终止残留进程: $pkg (第${i}次)"
            sleep 2
        else
            [ "$i" = "1" ] && log "  📭 无残留进程: $pkg"
            return 0
        fi
    done
    # 3 轮后仍存活（persistent 被系统拉起），尝试按 UID 清理
    local uid
    uid=$(pmx pm list packages --user 0 2>/dev/null | grep -qF "$pkg" && dumpsys package "$pkg" 2>/dev/null | grep -E "^ *userId=" | head -1 | grep -oE "[0-9]+")
    if [ -n "$uid" ]; then
        am force-stop --user 0 "$pkg" 2>/dev/null
        log "  ⚠️ $pkg 持续存活（persistent），已按 UID=$uid 尝试强杀"
    fi
}

# 禁用包：优先 pm disable-user，失败则 fallback 到 pm uninstall
# 第二个参数为可选 keep 键名（如 disable_ai_assistants），
# 若该包在 config.json 的 <key>_keep（逗号分隔）中则跳过禁用——
# 用于支持 WebUI 单独启用子包。
# 【v2.0.2】成功后自动调用 kill_pkg_procs 清理残留进程。
disable_pkg() {
    local pkg="$1"
    local keep_key="$2"
    # 【子包白名单】用户在 WebUI 单独启用（不禁用）的包
    if [ -n "$keep_key" ]; then
        local keep_val
        keep_val=$(get_keep "$keep_key")
        if [ -n "$keep_val" ]; then
            local k
            for k in $(echo "$keep_val" | tr ',' ' '); do
                if [ "$k" = "$pkg" ]; then
                    # 【修复】白名单包=用户在 WebUI 保留启用：
                    # 不仅“跳过禁用”，还必须确保其处于启用态——
                    # 若此前被 UI 总开关即时路径禁掉（pm disabled），
                    # 此处重新 pm enable 拉回，保证重启后与配置一一对应。
                    if pmx pm list packages -d --user 0 | grep -qF "package:$pkg"; then
                        log "  🔄 白名单包被禁用，恢复启用: $pkg"
                        result=$(pmx_verbose pm enable "$pkg")
                        log "  $result"
                    else
                        log "  ⏭️ 跳过（WebUI 白名单保留）: $pkg"
                    fi
                    return 0
                fi
            done
        fi
    fi
    # 检查包是否存在（对 user 0 可见；已禁用/卸载的也会被 pm list --user 0 过滤掉）
    if ! pmx pm list packages --user 0 | grep -qF "$pkg"; then
        log "  ⏭️ 跳过（不存在或已禁用/卸载）: $pkg"
        return 0
    fi
    # 方法1：pm disable-user --user 0
    result=$(pmx_verbose pm disable-user --user 0 "$pkg")
    if echo "$result" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ disable-user 成功: $pkg"
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ⚠️ disable-user 失败: $pkg ($result)"
    # 方法2：pm uninstall -k --user 0（fallback）
    result2=$(pmx_verbose pm uninstall -k --user 0 "$pkg")
    if echo "$result2" | grep -q "Success"; then
        log "  ✅ uninstall fallback 成功: $pkg"
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ⚠️ uninstall fallback 失败: $pkg ($result2)"
    # 方法3：pm disable --user 0（全局禁用，persistent 应用专用兜底）
    # 【v2.0.3】com.coloros.lockassistant 等 persistent 应用无法被 disable-user
    # 禁用（系统立即重新拉起），改用全局 disable + 强杀进程组合。
    result3=$(pmx_verbose pm disable --user 0 "$pkg" 2>&1)
    if echo "$result3" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ pm disable 成功（persistent 兜底）: $pkg"
        # persistent 应用禁用后系统会尝试重启，需多轮强杀
        kill_pkg_procs "$pkg"
        sleep 2
        kill_pkg_procs "$pkg"
        return 0
    fi
    log "  ❌ 三种方法均失败: $pkg ($result3)"
    return 1
}

# 恢复包：优先 pm enable，失败则 fallback 到 cmd package install-existing
enable_pkg() {
    local pkg="$1"
    # 检查包是否已经对用户可见且未被禁用
    if pmx pm list packages --user 0 | grep -qF "$pkg"; then
        # 还需检查是否在 disabled 列表中
        if ! pmx pm list packages -d --user 0 | grep -qF "$pkg"; then
            log "  ✅ 已启用（跳过）: $pkg"
            return 0
        fi
    else
        # 包对 user 0 不可见（可能被卸载），走 install-existing 恢复
        log "  ⚠️ 包对 user 0 不可见，尝试 install-existing 恢复: $pkg"
        result2=$(pmx_verbose cmd package install-existing "$pkg")
        if echo "$result2" | grep -q "installed for user"; then
            log "  ✅ install-existing 成功: $pkg"
            return 0
        fi
        log "  ❌ install-existing 失败: $pkg ($result2)"
        return 1
    fi
    # 方法1：pm enable --user 0
    result=$(pmx_verbose pm enable --user 0 "$pkg")
    if echo "$result" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ enable 成功: $pkg"
        return 0
    fi
    log "  ⚠️ enable 失败: $pkg ($result)"
    # 方法2：cmd package install-existing（fallback）
    result2=$(pmx_verbose cmd package install-existing "$pkg")
    if echo "$result2" | grep -q "installed for user"; then
        log "  ✅ install-existing fallback 成功: $pkg"
        return 0
    fi
    log "  ⚠️ install-existing fallback 失败: $pkg ($result2)"
    # 方法3：pm enable（全局恢复，对应 disable_pkg 方法3 的 persistent 兜底）
    result3=$(pmx_verbose pm enable "$pkg" 2>&1)
    if echo "$result3" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ pm enable 成功（persistent 恢复）: $pkg"
        return 0
    fi
    log "  ❌ 三种恢复方法均失败: $pkg ($result3)"
    return 1
}

# ================================================================
# 【v2.0 核心】标准包禁用项数据表
# 格式：key|pkg1,pkg2,...
# 通用循环遍历：is_on(key) 为 true → 禁用全部包（keep 白名单跳过）；
#               否则 → 恢复全部包。
# 【新增禁用项】只需在此表加一行，并在 WebUI FEATURES 加对应条目，
#               无需新增任何逻辑块！
# ================================================================
PKG_TABLE='
disable_health_services|com.oplus.healthservice
disable_network_monitoring|com.oplus.trafficmonitor,com.oplus.dmp
disable_gamespace|com.oplus.games,com.oplus.cosa
disable_wallet_services|com.oplus.pay,com.coloros.securepay
disable_backup_services|com.oplus.wifibackuprestore,com.heytap.cloud
disable_ai_assistants|com.oplus.aimemory,com.oplus.aiunit,com.oplus.aiwidgets,com.oplus.aiwriter,com.oplus.metis,com.oplus.obrain,com.oplus.deepthinker,com.coloros.colordirectservice
disable_voice_assistants|com.oplus.ovoicemanager,com.oplus.ovoicemanager.wakeup,com.heytap.speechassist,com.oplus.ttsaccessibilityengine
disable_theme_services|com.oplus.themestore,com.heytap.themestore,com.oplus.keyguard.clock.magazine,com.oplus.keyguard.clock.gallery,com.oplus.keyguard.clock.graffiti,com.oplus.keyguard.personality.clocks,com.oplus.keyguard.style.widgets,com.heytap.pictorial,com.oplus.wallpapers,com.android.wallpaper.livepicker
disable_network_optimization|com.oplus.networksense,com.oplus.cellularqoe,com.oplus.tai.wifiqoe,com.oplus.tai.borderpresearch,com.oplus.nearcomm
disable_security_services|com.oplus.securitykeyboard,com.coloros.securityguard
disable_media_services|com.oplus.screenrecorder,com.coloros.karaoke,com.oplus.mediacontroller,com.oplus.mediaturbo
disable_system_tools|com.oplus.powermonitor,com.oplus.audiomonitor,com.oplus.logkit,com.oplus.engineermode,com.oplus.crashbox,com.oplus.contentportal,com.oplus.postmanservice,com.oplus.subsys,com.oplus.engineernetwork
disable_speedview|com.coloros.ocs.opencapabilityservice,com.coloros.assistantscreen
disable_app_recover|com.oplus.apprecover
disable_double_tap|com.oplus.exsystemservice
disable_notification_mgr|com.oplus.notificationmanager
disable_device_link|com.heytap.accessory
disable_device_connect|com.oplus.linker
disable_remote_control|com.oplus.remotecontrol
disable_travel_engine|com.oplus.travelengine
'

# 通用循环：处理标准包禁用项
# 【修复 v2.0.1】不能用 IFS=',' 后再调用 disable_pkg/enable_pkg！
# 原因：pmx/pmx_verbose 内部用 su -c "$*" 传参，"$*" 会以当前 IFS 的
# 第一个字符连接参数。IFS=',' 时 su 收到的命令变成
# "cmd,package,install-existing,pkg" → 全部执行失败，包被误判"跳过"。
# 改用 tr 展开，保持 IFS 为默认值，函数内 "$*" 正常空格连接。
echo "$PKG_TABLE" | while IFS='|' read -r key pkgs; do
    [ -z "$key" ] && continue
    if is_on "$key"; then
        log "[$key] 禁用..."
        for p in $(echo "$pkgs" | tr ',' ' '); do
            disable_pkg "$p" "$key"
        done
    else
        log "[$key] 恢复..."
        for p in $(echo "$pkgs" | tr ',' ' '); do
            enable_pkg "$p"
        done
    fi
done

# ================================================================
# 特殊块 1-8（mount / 进程 / 系统属性，无法数据化，保留手写逻辑）
# 条件统一从 config.json 读取
# ================================================================

# ===================== 1. Logd =====================
if is_on "disable_logd"; then
    log "[Logd] 启用：覆盖文件 + 杀进程..."
    DUMMY="$WORK_DIR/dummy"
    for bin in logd logcat logpersist.start logpersist.stop logtagd; do
        TARGET="/system/bin/$bin"
        if [ -f "$TARGET" ]; then
            SIZE=$(stat -c %s "$TARGET" 2>/dev/null)
            if [ "$SIZE" != "0" ] && [ -n "$SIZE" ]; then
                mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
            fi
        fi
    done
    stop logd 2>/dev/null
    pkill -9 -x logd 2>/dev/null
    pkill -9 -x logpersistd 2>/dev/null
    pkill -9 -x logcat 2>/dev/null
    pkill -9 -x logtagd 2>/dev/null
    setprop ctl.stop logd 2>/dev/null
    setprop logd.logpersistd "" 2>/dev/null
    setprop logd.logpersistd.enable false 2>/dev/null
    log "[Logd] 完成"
else
    log "[Logd] 关闭：恢复文件 + 启动进程..."
    for bin in logd logcat logpersist.start logpersist.stop logtagd; do
        TARGET="/system/bin/$bin"
        umount "$TARGET" 2>/dev/null
    done
    for bin in logd logcat; do
        TARGET="/system/xbin/$bin"
        umount "$TARGET" 2>/dev/null
    done
    setprop logd.logpersistd.enable true 2>/dev/null
    setprop persist.logd.disabled 0 2>/dev/null
    start logd 2>/dev/null
    log "[Logd] 恢复完成"
fi

# ===================== 2. OTA 阻断 =====================
if is_on "block_ota"; then
    log "[OTA] 启用：杀进程 + 禁用包..."
    stop update_engine 2>/dev/null
    pkill -9 -x update_engine 2>/dev/null
    setprop ctl.stop update_engine 2>/dev/null
    # 依据 services.txt：一加Ace5 真实存在的 OTA 相关包
    disable_pkg "com.oplus.ota" "block_ota"
    disable_pkg "com.oplus.sau" "block_ota"
    disable_pkg "com.oplus.cota" "block_ota"
    disable_pkg "com.oplus.romupdate" "block_ota"
    disable_pkg "com.oplus.upgradeguide" "block_ota"
    setprop persist.ota.auto_download 0
    setprop persist.sys.recovery_update 0
    setprop persist.sys.ota.disabled 1
    log "[OTA] 完成"
else
    log "[OTA] 关闭：启用包 + 恢复属性..."
    enable_pkg "com.oplus.ota"
    enable_pkg "com.oplus.sau"
    enable_pkg "com.oplus.cota"
    enable_pkg "com.oplus.romupdate"
    enable_pkg "com.oplus.upgradeguide"
    setprop persist.ota.auto_download 1
    setprop persist.sys.recovery_update 1
    setprop persist.sys.ota.disabled 0
    setprop persist.ota.auto_download 1 2>/dev/null
    # 解除 post-fs-data.sh 中挂载覆盖的二进制与 OTA 目录
    for bin in update_engine update_engine_client; do
        TARGET="/system/bin/$bin"
        umount "$TARGET" 2>/dev/null
    done
    for apk_dir in /system/app/OTA /system/priv-app/OTA /system/app/OplusOTA /system/priv-app/OplusOTA; do
        umount "$apk_dir" 2>/dev/null
    done
    start update_engine 2>/dev/null
    log "[OTA] 恢复完成"
fi

# ===================== 3. 开发者选项锁定 =====================
if is_on "lock_developer_options"; then
    log "[DevLock] 启用：锁定开发者选项..."
    settings put global development_settings_enabled 0 2>/dev/null
    setprop persist.dev.option.lock 1
    log "[DevLock] 完成"
else
    log "[DevLock] 关闭：解锁开发者选项..."
    settings put global development_settings_enabled 1 2>/dev/null
    setprop persist.dev.option.lock 0
    log "[DevLock] 恢复完成"
fi

# ===================== 4. 广告与数据收集屏蔽 =====================
if is_on "block_ads_and_tracking"; then
    log "[Ads] 启用：关闭广告与数据收集..."
    settings put global oppo_ad_enabled 0 2>/dev/null
    settings put secure oppo_ad_personalization 0 2>/dev/null
    settings put global oppo_experience_plan 0 2>/dev/null
    settings put global oppo_data_collection 0 2>/dev/null
    settings put global device_experience_enabled 0 2>/dev/null
    setprop persist.sys.oplus.ad_enable 0
    setprop persist.sys.oplus.personalized_ad 0
    setprop persist.ad.track 0
    setprop persist.sys.usage_stat_enable 0
    setprop persist.oppo.collect 0
    disable_pkg "com.oplus.statistics.rom" "block_ads_and_tracking"
    disable_pkg "com.coloros.sceneservice" "block_ads_and_tracking"
    log "[Ads] 完成"
else
    log "[Ads] 关闭：恢复广告与数据收集..."
    settings put global oppo_ad_enabled 1 2>/dev/null
    settings put secure oppo_ad_personalization 1 2>/dev/null
    settings put global oppo_experience_plan 1 2>/dev/null
    settings put global oppo_data_collection 1 2>/dev/null
    settings put global device_experience_enabled 1 2>/dev/null
    setprop persist.sys.oplus.ad_enable 1
    setprop persist.sys.oplus.personalized_ad 1
    setprop persist.ad.track 1
    setprop persist.sys.usage_stat_enable 1
    setprop persist.oppo.collect 1
    enable_pkg "com.oplus.statistics.rom"
    enable_pkg "com.coloros.sceneservice"
    log "[Ads] 恢复完成"
fi

# ===================== 5. 进程查杀 =====================
if is_on "kill_redundant_processes"; then
    log "[Procs] 启用：查杀冗余进程..."
    KILL_LIST="smartscene preload sysmonitor hotstart daemondaemon oplusmemchecker"
    for proc in $KILL_LIST; do
        pkill -9 -x "$proc" 2>/dev/null
    done
    setprop persist.sys.preload 0
    setprop persist.sys.monitor 0
    setprop persist.sys.hotstart 0
    log "[Procs] 完成"
else
    log "[Procs] 关闭：恢复属性..."
    setprop persist.sys.preload 1
    setprop persist.sys.monitor 1
    setprop persist.sys.hotstart 1
    log "[Procs] 恢复完成"
fi

# ===================== 6. 系统属性开关 =====================
if is_on "system_prop_toggles"; then
    log "[SysProps] 启用：设置系统属性..."
    setprop persist.sys.preload 0
    setprop persist.sys.monitor 0
    setprop persist.sys.hotstart 0
    setprop persist.sys.assert.panic 0
    setprop persist.debug.kept 0
    setprop persist.sys.profiler_ms 0
    setprop persist.sys.strictmode.disable 1
    setprop persist.sys.strictmode.visual 0
    setprop persist.traced.enable 0
    setprop persist.traced_perf.enable 0
    log "[SysProps] 完成"
else
    log "[SysProps] 关闭：恢复系统属性..."
    setprop persist.sys.preload 1
    setprop persist.sys.monitor 1
    setprop persist.sys.hotstart 1
    setprop persist.sys.assert.panic 1
    setprop persist.debug.kept 1
    setprop persist.sys.profiler_ms 1
    setprop persist.sys.strictmode.disable 0
    setprop persist.sys.strictmode.visual 1
    setprop persist.traced.enable 1
    setprop persist.traced_perf.enable 1
    log "[SysProps] 恢复完成"
fi

# ===================== 7. 内存/IO 优化 =====================
if is_on "memory_io_optimization"; then
    log "[MemIO] 启用：写入优化参数..."
    echo 0 > /proc/sys/kernel/sched_schedstats 2>/dev/null
    echo 0 > /sys/module/binder/parameters/debug_mask 2>/dev/null
    echo 0 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
    echo 30 > /proc/sys/vm/swappiness 2>/dev/null
    echo 10 > /proc/sys/vm/dirty_ratio 2>/dev/null
    echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
    echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
    log "[MemIO] 完成"
else
    log "[MemIO] 关闭：恢复默认参数..."
    echo 1 > /proc/sys/kernel/sched_schedstats 2>/dev/null
    echo 255 > /sys/module/binder/parameters/debug_mask 2>/dev/null
    echo 1 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
    echo 100 > /proc/sys/vm/swappiness 2>/dev/null
    echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null
    echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
    echo 100 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
    log "[MemIO] 恢复完成"
fi

# ===================== 8. 额外内核优化 =====================
if is_on "extra_kernel_optimization"; then
    log "[Kernel] 启用：写入内核参数..."
    echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null
    echo 3 > /proc/sys/kernel/printk_console_loglevel 2>/dev/null
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
    echo never > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null
    log "[Kernel] 完成"
else
    log "[Kernel] 关闭：恢复默认参数..."
    echo "4 4 1 7" > /proc/sys/kernel/printk 2>/dev/null
    echo 4 > /proc/sys/kernel/printk_console_loglevel 2>/dev/null
    echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
    echo always > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
    echo always > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null
    log "[Kernel] 恢复完成"
fi

# ===================== 17. 主题（附加属性） =====================
# 主题服务的包已在 PKG_TABLE 处理，这里仅处理关联系统属性
if is_on "disable_theme_services"; then
    setprop persist.sys.lockscreen_magazine 0
else
    setprop persist.sys.lockscreen_magazine 1
fi

# ================================================================
# 二级分组总开关（31-32）
# 子项开关优先：总开关 on 时仅禁子项也为 on 的包；
#               总开关 off 时仅恢复子项也为 off 的包。
# ================================================================

# 设置相关（组内 6 个子项）
# 【v2.1.1】keep_key 传子项自身 key（如 disable_app_recover）而非总开关 key：
# WebUI 子包"恢复"操作写入的是子项 key 的 _keep 字段（如 disable_app_recover_keep），
# 若传 disable_settings_related 会导致服务端重启后读不到白名单，误禁用户保留的包。
if is_on "disable_settings_related"; then
    log "[SettingsRelated] 禁用..."
    is_on "disable_app_recover" && disable_pkg "com.oplus.apprecover" "disable_app_recover"
    is_on "disable_notification_mgr" && disable_pkg "com.oplus.notificationmanager" "disable_notification_mgr"
    is_on "disable_remote_control" && disable_pkg "com.oplus.remotecontrol" "disable_remote_control"
    is_on "disable_travel_engine" && disable_pkg "com.oplus.travelengine" "disable_travel_engine"
    is_on "disable_device_link" && disable_pkg "com.heytap.accessory" "disable_device_link"
    is_on "disable_device_connect" && disable_pkg "com.oplus.linker" "disable_device_connect"
else
    log "[SettingsRelated] 恢复..."
    ! is_on "disable_app_recover" && enable_pkg "com.oplus.apprecover"
    ! is_on "disable_notification_mgr" && enable_pkg "com.oplus.notificationmanager"
    ! is_on "disable_remote_control" && enable_pkg "com.oplus.remotecontrol"
    ! is_on "disable_travel_engine" && enable_pkg "com.oplus.travelengine"
    ! is_on "disable_device_link" && enable_pkg "com.heytap.accessory"
    ! is_on "disable_device_connect" && enable_pkg "com.oplus.linker"
fi

# 屏幕服务（组内 2 个子项）
if is_on "disable_screen_services"; then
    log "[ScreenServices] 禁用..."
    is_on "disable_double_tap" && disable_pkg "com.oplus.exsystemservice" "disable_double_tap"
    is_on "disable_speedview" && disable_pkg "com.coloros.ocs.opencapabilityservice" "disable_speedview"
else
    log "[ScreenServices] 恢复..."
    ! is_on "disable_double_tap" && enable_pkg "com.oplus.exsystemservice"
    ! is_on "disable_speedview" && enable_pkg "com.coloros.ocs.opencapabilityservice"
fi

# ===================== 写入状态 =====================
echo "last_run=$(date '+%Y-%m-%d %H:%M:%S')" > "$WORK_DIR/service_status.log"
echo "status=ok" >> "$WORK_DIR/service_status.log"
log "========== service.sh 执行完毕 =========="
