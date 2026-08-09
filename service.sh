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

# 禁用包：优先 pm disable-user，失败则 fallback 到 pm uninstall
disable_pkg() {
    local pkg="$1"
    # 检查包是否存在
    if ! pm list packages 2>/dev/null | grep -qF "$pkg"; then
        log "  ⏭️ 跳过（包不存在）: $pkg"
        return 0
    fi
    # 检查包是否已经被禁用或卸载
    if ! pm list packages --user 0 2>/dev/null | grep -qF "$pkg"; then
        log "  ⏭️ 已禁用/卸载（跳过）: $pkg"
        return 0
    fi
    # 方法1：pm disable-user --user 0（SELinux 权限要求较低）
    result=$(pm disable-user --user 0 "$pkg" 2>&1)
    if echo "$result" | grep -qiE "new state: disabled|Success"; then
        log "  ✅ disable-user 成功: $pkg"
        return 0
    fi
    log "  ⚠️ disable-user 失败: $pkg ($result)"
    # 方法2：pm uninstall -k --user 0（fallback）
    result2=$(pm uninstall -k --user 0 "$pkg" 2>&1)
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
    if pm list packages --user 0 2>/dev/null | grep -qF "$pkg"; then
        # 还需检查是否在 disabled 列表中
        if ! pm list packages -d --user 0 2>/dev/null | grep -qF "$pkg"; then
            log "  ✅ 已启用（跳过）: $pkg"
            return 0
        fi
    fi
    # 方法1：pm enable --user 0
    result=$(pm enable --user 0 "$pkg" 2>&1)
    if echo "$result" | grep -qiE "new state: enabled|Success"; then
        log "  ✅ enable 成功: $pkg"
        return 0
    fi
    log "  ⚠️ enable 失败: $pkg ($result)"
    # 方法2：cmd package install-existing（fallback）
    result2=$(cmd package install-existing "$pkg" 2>&1)
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
    pkill -9 -f "logd" 2>/dev/null
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
    setprop logd.logpersistd.enable true 2>/dev/null
    start logd 2>/dev/null
    log "[Logd] 恢复完成"
fi

# ===================== 2. OTA 阻断 =====================
if [ "$(getprop ${PROP_PREFIX}block_ota)" = "true" ]; then
    log "[OTA] 启用：杀进程 + 禁用包..."
    stop update_engine 2>/dev/null
    pkill -9 -x update_engine 2>/dev/null
    setprop ctl.stop update_engine 2>/dev/null
    disable_pkg "com.oplus.ota"
    disable_pkg "com.oplus.sau"
    disable_pkg "com.coloros.ota"
    disable_pkg "com.oplus.otaex"
    setprop persist.ota.auto_download 0
    setprop persist.sys.recovery_update 0
    setprop persist.sys.ota.disabled 1
    log "[OTA] 完成"
else
    log "[OTA] 关闭：启用包 + 恢复属性..."
    enable_pkg "com.oplus.ota"
    enable_pkg "com.oplus.sau"
    enable_pkg "com.coloros.ota"
    enable_pkg "com.oplus.otaex"
    setprop persist.ota.auto_download 1
    setprop persist.sys.recovery_update 1
    setprop persist.sys.ota.disabled 0
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
    disable_pkg "com.oplus.statistics.rom"
    disable_pkg "com.coloros.assistantscreen"
    disable_pkg "com.coloros.sceneservice"
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
    disable_pkg "com.oplus.healthservice"
else
    log "[Health] 恢复..."
    enable_pkg "com.oplus.healthservice"
fi

# 10. 流量监控
if [ "$(getprop ${PROP_PREFIX}disable_network_monitoring)" = "true" ]; then
    log "[NetMon] 禁用..."
    disable_pkg "com.oplus.trafficmonitor"
    disable_pkg "com.oplus.dmp"
else
    log "[NetMon] 恢复..."
    enable_pkg "com.oplus.trafficmonitor"
    enable_pkg "com.oplus.dmp"
fi

# 11. 锁屏杂志
if [ "$(getprop ${PROP_PREFIX}disable_lockscreen_magazine)" = "true" ]; then
    log "[LockMag] 禁用..."
    disable_pkg "com.heytap.pictorial"
    setprop persist.sys.lockscreen_magazine 0
else
    log "[LockMag] 恢复..."
    enable_pkg "com.heytap.pictorial"
    setprop persist.sys.lockscreen_magazine 1
fi

# 12. 游戏空间
if [ "$(getprop ${PROP_PREFIX}disable_gamespace)" = "true" ]; then
    log "[GameSpace] 禁用..."
    disable_pkg "com.oplus.games"
else
    log "[GameSpace] 恢复..."
    enable_pkg "com.oplus.games"
fi

# 13. 钱包
if [ "$(getprop ${PROP_PREFIX}disable_wallet_services)" = "true" ]; then
    log "[Wallet] 禁用..."
    disable_pkg "com.oplus.pay"
    disable_pkg "com.coloros.securepay"
else
    log "[Wallet] 恢复..."
    enable_pkg "com.oplus.pay"
    enable_pkg "com.coloros.securepay"
fi

# 14. 备份
if [ "$(getprop ${PROP_PREFIX}disable_backup_services)" = "true" ]; then
    log "[Backup] 禁用..."
    disable_pkg "com.oplus.wifibackuprestore"
    disable_pkg "com.heytap.cloud"
else
    log "[Backup] 恢复..."
    enable_pkg "com.oplus.wifibackuprestore"
    enable_pkg "com.heytap.cloud"
fi

# 15. AI 助手
if [ "$(getprop ${PROP_PREFIX}disable_ai_assistants)" = "true" ]; then
    log "[AI] 禁用..."
    disable_pkg "com.oplus.aimemory"
    disable_pkg "com.oplus.aiunit"
    disable_pkg "com.oplus.aiwidgets"
    disable_pkg "com.oplus.aiwriter"
    disable_pkg "com.oplus.metis"
    disable_pkg "com.oplus.obrain"
else
    log "[AI] 恢复..."
    enable_pkg "com.oplus.aimemory"
    enable_pkg "com.oplus.aiunit"
    enable_pkg "com.oplus.aiwidgets"
    enable_pkg "com.oplus.aiwriter"
    enable_pkg "com.oplus.metis"
    enable_pkg "com.oplus.obrain"
fi

# 16. 语音助手
if [ "$(getprop ${PROP_PREFIX}disable_voice_assistants)" = "true" ]; then
    log "[Voice] 禁用..."
    disable_pkg "com.oplus.ovoicemanager"
    disable_pkg "com.oplus.ovoicemanager.wakeup"
    disable_pkg "com.heytap.speechassist"
    disable_pkg "com.oplus.ttsaccessibilityengine"
else
    log "[Voice] 恢复..."
    enable_pkg "com.oplus.ovoicemanager"
    enable_pkg "com.oplus.ovoicemanager.wakeup"
    enable_pkg "com.heytap.speechassist"
    enable_pkg "com.oplus.ttsaccessibilityengine"
fi

# 17. 主题
if [ "$(getprop ${PROP_PREFIX}disable_theme_services)" = "true" ]; then
    log "[Theme] 禁用..."
    disable_pkg "com.oplus.themestore"
    disable_pkg "com.heytap.themestore"
    disable_pkg "com.oplus.keyguard.clock.magazine"
    disable_pkg "com.oplus.keyguard.clock.gallery"
    disable_pkg "com.oplus.keyguard.clock.graffiti"
    disable_pkg "com.oplus.keyguard.personality.clocks"
    disable_pkg "com.oplus.keyguard.style.widgets"
else
    log "[Theme] 恢复..."
    enable_pkg "com.oplus.themestore"
    enable_pkg "com.heytap.themestore"
    enable_pkg "com.oplus.keyguard.clock.magazine"
    enable_pkg "com.oplus.keyguard.clock.gallery"
    enable_pkg "com.oplus.keyguard.clock.graffiti"
    enable_pkg "com.oplus.keyguard.personality.clocks"
    enable_pkg "com.oplus.keyguard.style.widgets"
fi

# 18. 网络优化
if [ "$(getprop ${PROP_PREFIX}disable_network_optimization)" = "true" ]; then
    log "[NetOpt] 禁用..."
    disable_pkg "com.oplus.networksense"
    disable_pkg "com.oplus.cellularqoe"
    disable_pkg "com.oplus.tai.wifiqoe"
    disable_pkg "com.oplus.tai.borderpresearch"
    disable_pkg "com.oplus.nearcomm"
else
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
    disable_pkg "com.oplus.securitykeyboard"
    disable_pkg "com.coloros.securityguard"
else
    log "[Security] 恢复..."
    enable_pkg "com.oplus.securitykeyboard"
    enable_pkg "com.coloros.securityguard"
fi

# 20. 多媒体
if [ "$(getprop ${PROP_PREFIX}disable_media_services)" = "true" ]; then
    log "[Media] 禁用..."
    disable_pkg "com.oplus.screenrecorder"
    disable_pkg "com.coloros.karaoke"
    disable_pkg "com.oplus.mediacontroller"
else
    log "[Media] 恢复..."
    enable_pkg "com.oplus.screenrecorder"
    enable_pkg "com.coloros.karaoke"
    enable_pkg "com.oplus.mediacontroller"
fi

# 21. 系统工具
if [ "$(getprop ${PROP_PREFIX}disable_system_tools)" = "true" ]; then
    log "[SysTools] 禁用..."
    disable_pkg "com.oplus.powermonitor"
    disable_pkg "com.oplus.audiomonitor"
    disable_pkg "com.oplus.logkit"
    disable_pkg "com.oplus.engineermode"
    disable_pkg "com.oplus.crashbox"
    disable_pkg "com.oplus.appplatform"
    disable_pkg "com.oplus.contentportal"
    disable_pkg "com.oplus.postmanservice"
    disable_pkg "com.oplus.subsys"
else
    log "[SysTools] 恢复..."
    enable_pkg "com.oplus.powermonitor"
    enable_pkg "com.oplus.audiomonitor"
    enable_pkg "com.oplus.logkit"
    enable_pkg "com.oplus.engineermode"
    enable_pkg "com.oplus.crashbox"
    enable_pkg "com.oplus.appplatform"
    enable_pkg "com.oplus.contentportal"
    enable_pkg "com.oplus.postmanservice"
    enable_pkg "com.oplus.subsys"
fi

# ===================== 写入状态 =====================
echo "last_run=$(date '+%Y-%m-%d %H:%M:%S')" > "$WORK_DIR/service_status.log"
echo "status=ok" >> "$WORK_DIR/service_status.log"
log "========== service.sh 执行完毕 =========="
