#!/system/bin/sh
# ================================================================
# ColorOS16 优化模块 - service.sh (late_start service)
# 执行时机：系统服务启动后
# 读取 WebUI 设置的 persist.sys.coloros16_optimize_gui.* 属性
# 支持双向操作：开启时优化，关闭时恢复原状
# ================================================================

MODDIR=${0%/*}
PROP_PREFIX="persist.sys.coloros16_optimize_gui."
WORK_DIR="/data/adb/logd_disabler"
LOG_FILE="$WORK_DIR/service.log"

mkdir -p "$WORK_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "========== service.sh 开始执行 =========="

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
pmx() {
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>/dev/null
    else
        "$@" 2>/dev/null
    fi
}

# 详细执行（保留 stderr，用于采集 result 排错）
pmx_verbose() {
    if [ "$PMX_USE_SU" = "1" ]; then
        su -c "$*" 2>&1
    else
        "$@" 2>&1
    fi
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

# 禁用包：优先 pm disable-user，失败则 fallback 到 pm uninstall
# 第二个参数为可选白名单属性名（如 disable_ai_assistants_keep），
# 若该包在属性值（逗号分隔）中则跳过禁用——用于支持 WebUI 单独启用子包。
disable_pkg() {
    local pkg="$1"
    local keep_prop="$2"
    # 【子包白名单】用户在 WebUI 单独启用（不禁用）的包
    if [ -n "$keep_prop" ]; then
        local keep_val
        keep_val=$(getprop "${PROP_PREFIX}${keep_prop}" 2>/dev/null)
        if [ -n "$keep_val" ]; then
            local k
            for k in $(echo "$keep_val" | tr ',' ' '); do
                if [ "$k" = "$pkg" ]; then
                    log "  ⏭️ 跳过（WebUI 白名单保留）: $pkg"
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
        return 0
    fi
    log "  ⚠️ disable-user 失败: $pkg ($result)"
    # 方法2：pm uninstall -k --user 0（fallback）
    result2=$(pmx_verbose pm uninstall -k --user 0 "$pkg")
    if echo "$result2" | grep -q "Success"; then
        log "  ✅ uninstall fallback 成功: $pkg"
        return 0
    fi
    log "  ❌ 两种方法均失败: $pkg"
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
    log "  ❌ 两种恢复方法均失败: $pkg"
    return 1
}

# ===================== 1. Logd =====================
if [ "$(getprop ${PROP_PREFIX}disable_logd)" = "true" ]; then
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
if [ "$(getprop ${PROP_PREFIX}block_ota)" = "true" ]; then
    log "[OTA] 启用：杀进程 + 禁用包..."
    stop update_engine 2>/dev/null
    pkill -9 -x update_engine 2>/dev/null
    setprop ctl.stop update_engine 2>/dev/null
    # 依据 services.txt：一加Ace5 真实存在的 OTA 相关包
    disable_pkg "com.oplus.ota" "block_ota_keep"
    disable_pkg "com.oplus.sau" "block_ota_keep"
    disable_pkg "com.oplus.cota" "block_ota_keep"
    disable_pkg "com.oplus.romupdate" "block_ota_keep"
    disable_pkg "com.oplus.upgradeguide" "block_ota_keep"
    setprop persist.ota.auto_download 0
    setprop persist.sys.recovery_update 0
    setprop persist.sys.ota.disabled 1
    log "[OTA] 完成"
else
    setprop ${PROP_PREFIX}block_ota_keep ""
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
if [ "$(getprop ${PROP_PREFIX}lock_developer_options)" = "true" ]; then
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
if [ "$(getprop ${PROP_PREFIX}block_ads_and_tracking)" = "true" ]; then
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
    disable_pkg "com.oplus.statistics.rom" "block_ads_and_tracking_keep"
    disable_pkg "com.coloros.assistantscreen" "block_ads_and_tracking_keep"
    disable_pkg "com.coloros.sceneservice" "block_ads_and_tracking_keep"
    log "[Ads] 完成"
else
    setprop ${PROP_PREFIX}block_ads_and_tracking_keep ""
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
    enable_pkg "com.coloros.assistantscreen"
    enable_pkg "com.coloros.sceneservice"
    log "[Ads] 恢复完成"
fi

# ===================== 5. 进程查杀 =====================
if [ "$(getprop ${PROP_PREFIX}kill_redundant_processes)" = "true" ]; then
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
if [ "$(getprop ${PROP_PREFIX}system_prop_toggles)" = "true" ]; then
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
if [ "$(getprop ${PROP_PREFIX}memory_io_optimization)" = "true" ]; then
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
if [ "$(getprop ${PROP_PREFIX}extra_kernel_optimization)" = "true" ]; then
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

# ===================== 9-21. 可选禁用服务 =====================

# 9. 健康服务
if [ "$(getprop ${PROP_PREFIX}disable_health_services)" = "true" ]; then
    log "[Health] 禁用..."
    disable_pkg "com.oplus.healthservice" "disable_health_services_keep"
else
    setprop ${PROP_PREFIX}disable_health_services_keep ""
    log "[Health] 恢复..."
    enable_pkg "com.oplus.healthservice"
fi

# 10. 流量监控
if [ "$(getprop ${PROP_PREFIX}disable_network_monitoring)" = "true" ]; then
    log "[NetMon] 禁用..."
    disable_pkg "com.oplus.trafficmonitor" "disable_network_monitoring_keep"
    disable_pkg "com.oplus.dmp" "disable_network_monitoring_keep"
else
    setprop ${PROP_PREFIX}disable_network_monitoring_keep ""
    log "[NetMon] 恢复..."
    enable_pkg "com.oplus.trafficmonitor"
    enable_pkg "com.oplus.dmp"
fi

# 12. 游戏空间
if [ "$(getprop ${PROP_PREFIX}disable_gamespace)" = "true" ]; then
    log "[GameSpace] 禁用..."
    disable_pkg "com.oplus.games" "disable_gamespace_keep"
    disable_pkg "com.oplus.cosa" "disable_gamespace_keep"
else
    setprop ${PROP_PREFIX}disable_gamespace_keep ""
    log "[GameSpace] 恢复..."
    enable_pkg "com.oplus.games"
    enable_pkg "com.oplus.cosa"
fi

# 13. 钱包
if [ "$(getprop ${PROP_PREFIX}disable_wallet_services)" = "true" ]; then
    log "[Wallet] 禁用..."
    disable_pkg "com.oplus.pay" "disable_wallet_services_keep"
    disable_pkg "com.coloros.securepay" "disable_wallet_services_keep"
else
    setprop ${PROP_PREFIX}disable_wallet_services_keep ""
    log "[Wallet] 恢复..."
    enable_pkg "com.oplus.pay"
    enable_pkg "com.coloros.securepay"
fi

# 14. 备份
if [ "$(getprop ${PROP_PREFIX}disable_backup_services)" = "true" ]; then
    log "[Backup] 禁用..."
    disable_pkg "com.oplus.wifibackuprestore" "disable_backup_services_keep"
    disable_pkg "com.heytap.cloud" "disable_backup_services_keep"
else
    setprop ${PROP_PREFIX}disable_backup_services_keep ""
    log "[Backup] 恢复..."
    enable_pkg "com.oplus.wifibackuprestore"
    enable_pkg "com.heytap.cloud"
fi

# 15. AI 助手（含小布识屏）
if [ "$(getprop ${PROP_PREFIX}disable_ai_assistants)" = "true" ]; then
    log "[AI] 禁用..."
    disable_pkg "com.oplus.aimemory" "disable_ai_assistants_keep"
    disable_pkg "com.oplus.aiunit" "disable_ai_assistants_keep"
    disable_pkg "com.oplus.aiwidgets" "disable_ai_assistants_keep"
    disable_pkg "com.oplus.aiwriter" "disable_ai_assistants_keep"
    disable_pkg "com.oplus.metis" "disable_ai_assistants_keep"
    disable_pkg "com.oplus.obrain" "disable_ai_assistants_keep"
    disable_pkg "com.oplus.deepthinker" "disable_ai_assistants_keep"
    # 小布识屏（colordirectservice）并入 AI 助手
    disable_pkg "com.coloros.colordirectservice" "disable_ai_assistants_keep"
else
    log "[AI] 恢复..."
    # 恢复全部时清除子包白名单，避免下次开启时残留保留项
    setprop ${PROP_PREFIX}disable_ai_assistants_keep ""
    enable_pkg "com.oplus.aimemory"
    enable_pkg "com.oplus.aiunit"
    enable_pkg "com.oplus.aiwidgets"
    enable_pkg "com.oplus.aiwriter"
    enable_pkg "com.oplus.metis"
    enable_pkg "com.oplus.obrain"
    enable_pkg "com.oplus.deepthinker"
    enable_pkg "com.coloros.colordirectservice"
fi

# 16. 语音助手
if [ "$(getprop ${PROP_PREFIX}disable_voice_assistants)" = "true" ]; then
    log "[Voice] 禁用..."
    disable_pkg "com.oplus.ovoicemanager" "disable_voice_assistants_keep"
    disable_pkg "com.oplus.ovoicemanager.wakeup" "disable_voice_assistants_keep"
    disable_pkg "com.heytap.speechassist" "disable_voice_assistants_keep"
    disable_pkg "com.oplus.ttsaccessibilityengine" "disable_voice_assistants_keep"
else
    setprop ${PROP_PREFIX}disable_voice_assistants_keep ""
    log "[Voice] 恢复..."
    enable_pkg "com.oplus.ovoicemanager"
    enable_pkg "com.oplus.ovoicemanager.wakeup"
    enable_pkg "com.heytap.speechassist"
    enable_pkg "com.oplus.ttsaccessibilityengine"
fi

# 17. 主题（含锁屏杂志）
if [ "$(getprop ${PROP_PREFIX}disable_theme_services)" = "true" ]; then
    log "[Theme] 禁用..."
    disable_pkg "com.oplus.themestore" "disable_theme_services_keep"
    disable_pkg "com.heytap.themestore" "disable_theme_services_keep"
    disable_pkg "com.oplus.keyguard.clock.magazine" "disable_theme_services_keep"
    disable_pkg "com.oplus.keyguard.clock.gallery" "disable_theme_services_keep"
    disable_pkg "com.oplus.keyguard.clock.graffiti" "disable_theme_services_keep"
    disable_pkg "com.oplus.keyguard.personality.clocks" "disable_theme_services_keep"
    disable_pkg "com.oplus.keyguard.style.widgets" "disable_theme_services_keep"
    # 锁屏杂志（乐划锁屏）并入主题服务
    disable_pkg "com.heytap.pictorial" "disable_theme_services_keep"
    setprop persist.sys.lockscreen_magazine 0
else
    setprop ${PROP_PREFIX}disable_theme_services_keep ""
    log "[Theme] 恢复..."
    enable_pkg "com.oplus.themestore"
    enable_pkg "com.heytap.themestore"
    enable_pkg "com.oplus.keyguard.clock.magazine"
    enable_pkg "com.oplus.keyguard.clock.gallery"
    enable_pkg "com.oplus.keyguard.clock.graffiti"
    enable_pkg "com.oplus.keyguard.personality.clocks"
    enable_pkg "com.oplus.keyguard.style.widgets"
    enable_pkg "com.heytap.pictorial"
    setprop persist.sys.lockscreen_magazine 1
fi

# 18. 网络优化
if [ "$(getprop ${PROP_PREFIX}disable_network_optimization)" = "true" ]; then
    log "[NetOpt] 禁用..."
    disable_pkg "com.oplus.networksense" "disable_network_optimization_keep"
    disable_pkg "com.oplus.cellularqoe" "disable_network_optimization_keep"
    disable_pkg "com.oplus.tai.wifiqoe" "disable_network_optimization_keep"
    disable_pkg "com.oplus.tai.borderpresearch" "disable_network_optimization_keep"
    disable_pkg "com.oplus.nearcomm" "disable_network_optimization_keep"
else
    setprop ${PROP_PREFIX}disable_network_optimization_keep ""
    log "[NetOpt] 恢复..."
    enable_pkg "com.oplus.networksense"
    enable_pkg "com.oplus.cellularqoe"
    enable_pkg "com.oplus.tai.wifiqoe"
    enable_pkg "com.oplus.tai.borderpresearch"
    enable_pkg "com.oplus.nearcomm"
fi

# 19. 安全
if [ "$(getprop ${PROP_PREFIX}disable_security_services)" = "true" ]; then
    log "[Security] 禁用..."
    disable_pkg "com.oplus.securitykeyboard" "disable_security_services_keep"
    disable_pkg "com.coloros.securityguard" "disable_security_services_keep"
else
    setprop ${PROP_PREFIX}disable_security_services_keep ""
    log "[Security] 恢复..."
    enable_pkg "com.oplus.securitykeyboard"
    enable_pkg "com.coloros.securityguard"
fi

# 20. 多媒体
if [ "$(getprop ${PROP_PREFIX}disable_media_services)" = "true" ]; then
    log "[Media] 禁用..."
    disable_pkg "com.oplus.screenrecorder" "disable_media_services_keep"
    disable_pkg "com.coloros.karaoke" "disable_media_services_keep"
    disable_pkg "com.oplus.mediacontroller" "disable_media_services_keep"
    disable_pkg "com.oplus.mediaturbo" "disable_media_services_keep"
else
    setprop ${PROP_PREFIX}disable_media_services_keep ""
    log "[Media] 恢复..."
    enable_pkg "com.oplus.screenrecorder"
    enable_pkg "com.coloros.karaoke"
    enable_pkg "com.oplus.mediacontroller"
    enable_pkg "com.oplus.mediaturbo"
fi

# 21. 系统工具
# 注意：com.oplus.appplatform（应用服务）涉及短信收发，永不禁用（v1.6 移除）
if [ "$(getprop ${PROP_PREFIX}disable_system_tools)" = "true" ]; then
    log "[SysTools] 禁用..."
    disable_pkg "com.oplus.powermonitor" "disable_system_tools_keep"
    disable_pkg "com.oplus.audiomonitor" "disable_system_tools_keep"
    disable_pkg "com.oplus.logkit" "disable_system_tools_keep"
    disable_pkg "com.oplus.engineermode" "disable_system_tools_keep"
    disable_pkg "com.oplus.crashbox" "disable_system_tools_keep"
    disable_pkg "com.oplus.contentportal" "disable_system_tools_keep"
    disable_pkg "com.oplus.postmanservice" "disable_system_tools_keep"
    disable_pkg "com.oplus.subsys" "disable_system_tools_keep"
    disable_pkg "com.oplus.engineernetwork" "disable_system_tools_keep"
else
    setprop ${PROP_PREFIX}disable_system_tools_keep ""
    log "[SysTools] 恢复..."
    enable_pkg "com.oplus.powermonitor"
    enable_pkg "com.oplus.audiomonitor"
    enable_pkg "com.oplus.logkit"
    enable_pkg "com.oplus.engineermode"
    enable_pkg "com.oplus.crashbox"
    enable_pkg "com.oplus.contentportal"
    enable_pkg "com.oplus.postmanservice"
    enable_pkg "com.oplus.subsys"
    enable_pkg "com.oplus.engineernetwork"
fi

# ===================== 22-30. 第一梯队新增服务 =====================
# 依据：onservices.txt 运行进程排查，均为当前自启占用后台的组件
# 由用户审核后加入，注意保持与 WebUI FEATURES 一一对应
# 注：小布识屏(com.coloros.colordirectservice)已并入 15.AI助手

# 23. 速览/负一屏支持组件
if [ "$(getprop ${PROP_PREFIX}disable_speedview)" = "true" ]; then
    log "[SpeedView] 禁用..."
    disable_pkg "com.coloros.ocs.opencapabilityservice" "disable_speedview_keep"
else
    setprop ${PROP_PREFIX}disable_speedview_keep ""
    log "[SpeedView] 恢复..."
    enable_pkg "com.coloros.ocs.opencapabilityservice"
fi

# 24. 应用恢复服务
if [ "$(getprop ${PROP_PREFIX}disable_app_recover)" = "true" ]; then
    log "[AppRecover] 禁用..."
    disable_pkg "com.oplus.apprecover" "disable_app_recover_keep"
else
    setprop ${PROP_PREFIX}disable_app_recover_keep ""
    log "[AppRecover] 恢复..."
    enable_pkg "com.oplus.apprecover"
fi

# 25. 双击亮屏支持组件
if [ "$(getprop ${PROP_PREFIX}disable_double_tap)" = "true" ]; then
    log "[DoubleTap] 禁用..."
    disable_pkg "com.oplus.exsystemservice" "disable_double_tap_keep"
else
    setprop ${PROP_PREFIX}disable_double_tap_keep ""
    log "[DoubleTap] 恢复..."
    enable_pkg "com.oplus.exsystemservice"
fi

# 26. 通知管理服务
if [ "$(getprop ${PROP_PREFIX}disable_notification_mgr)" = "true" ]; then
    log "[NotifMgr] 禁用..."
    disable_pkg "com.oplus.notificationmanager" "disable_notification_mgr_keep"
else
    setprop ${PROP_PREFIX}disable_notification_mgr_keep ""
    log "[NotifMgr] 恢复..."
    enable_pkg "com.oplus.notificationmanager"
fi

# 27. 设备快连服务
if [ "$(getprop ${PROP_PREFIX}disable_device_link)" = "true" ]; then
    log "[DevLink] 禁用..."
    disable_pkg "com.heytap.accessory" "disable_device_link_keep"
else
    setprop ${PROP_PREFIX}disable_device_link_keep ""
    log "[DevLink] 恢复..."
    enable_pkg "com.heytap.accessory"
fi

# 28. 设备互联服务
if [ "$(getprop ${PROP_PREFIX}disable_device_connect)" = "true" ]; then
    log "[DevConnect] 禁用..."
    disable_pkg "com.oplus.linker" "disable_device_connect_keep"
else
    setprop ${PROP_PREFIX}disable_device_connect_keep ""
    log "[DevConnect] 恢复..."
    enable_pkg "com.oplus.linker"
fi

# 29. 远程控制服务
if [ "$(getprop ${PROP_PREFIX}disable_remote_control)" = "true" ]; then
    log "[RemoteCtrl] 禁用..."
    disable_pkg "com.oplus.remotecontrol" "disable_remote_control_keep"
else
    setprop ${PROP_PREFIX}disable_remote_control_keep ""
    log "[RemoteCtrl] 恢复..."
    enable_pkg "com.oplus.remotecontrol"
fi

# 30. 出行引擎
if [ "$(getprop ${PROP_PREFIX}disable_travel_engine)" = "true" ]; then
    log "[TravelEngine] 禁用..."
    disable_pkg "com.oplus.travelengine" "disable_travel_engine_keep"
else
    setprop ${PROP_PREFIX}disable_travel_engine_keep ""
    log "[TravelEngine] 恢复..."
    enable_pkg "com.oplus.travelengine"
fi

# ===================== 31-32. 二级分组总开关 =====================
# 设置相关（二级折叠组总开关：一键禁用组内 6 个子项）
if [ "$(getprop ${PROP_PREFIX}disable_settings_related)" = "true" ]; then
    log "[SettingsRelated] 禁用..."
    disable_pkg "com.oplus.apprecover" "disable_settings_related_keep"
    disable_pkg "com.oplus.notificationmanager" "disable_settings_related_keep"
    disable_pkg "com.oplus.remotecontrol" "disable_settings_related_keep"
    disable_pkg "com.oplus.travelengine" "disable_settings_related_keep"
    disable_pkg "com.heytap.accessory" "disable_settings_related_keep"
    disable_pkg "com.oplus.linker" "disable_settings_related_keep"
else
    setprop ${PROP_PREFIX}disable_settings_related_keep ""
    log "[SettingsRelated] 恢复..."
    enable_pkg "com.oplus.apprecover"
    enable_pkg "com.oplus.notificationmanager"
    enable_pkg "com.oplus.remotecontrol"
    enable_pkg "com.oplus.travelengine"
    enable_pkg "com.heytap.accessory"
    enable_pkg "com.oplus.linker"
fi

# 屏幕服务（二级折叠组总开关：一键禁用组内 2 个子项）
if [ "$(getprop ${PROP_PREFIX}disable_screen_services)" = "true" ]; then
    log "[ScreenServices] 禁用..."
    disable_pkg "com.oplus.exsystemservice" "disable_screen_services_keep"
    disable_pkg "com.coloros.ocs.opencapabilityservice" "disable_screen_services_keep"
else
    setprop ${PROP_PREFIX}disable_screen_services_keep ""
    log "[ScreenServices] 恢复..."
    enable_pkg "com.oplus.exsystemservice"
    enable_pkg "com.coloros.ocs.opencapabilityservice"
fi

# ===================== 写入状态 =====================
echo "last_run=$(date '+%Y-%m-%d %H:%M:%S')" > "$WORK_DIR/service_status.log"
echo "status=ok" >> "$WORK_DIR/service_status.log"
log "========== service.sh 执行完毕 =========="