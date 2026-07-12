#!/system/bin/sh
# ================================================================
# ColorOS16 优化模块 - service.sh (late_start service)
# 执行时机：系统服务启动后
# 读取 WebUI 设置的 persist.sys.coloros16_optimize_gui.* 属性
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

# 辅助函数
disable_pkg() {
    local pkg="$1"
    pm disable-user --user 0 "$pkg" 2>/dev/null
    am force-stop "$pkg" 2>/dev/null
    log "  禁用: $pkg"
}

enable_pkg() {
    local pkg="$1"
    pm enable "$pkg" 2>/dev/null
    log "  启用: $pkg"
}

# ===================== 1. Logd（补充杀进程 + 再次覆盖） =====================
if [ "$(getprop ${PROP_PREFIX}disable_logd)" = "true" ]; then
    log "[Logd] 补充执行：杀进程 + 再次覆盖..."

    DUMMY="$WORK_DIR/dummy"

    for bin in logd logcat logpersist.start logpersist.stop logtagd; do
        TARGET="/system/bin/$bin"
        if [ -f "$TARGET" ]; then
            SIZE=$(stat -c %s "$TARGET" 2>/dev/null)
            if [ "$SIZE" != "0" ] && [ -n "$SIZE" ]; then
                mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
                log "  重新覆盖: $TARGET (原大小: $SIZE)"
            fi
        fi
    done

    stop logd 2>/dev/null
    pkill -9 -x logd 2>/dev/null
    pkill -9 -f "logd" 2>/dev/null
    pkill -9 -x logcat 2>/dev/null
    pkill -9 -x logtagd 2>/dev/null
    pkill -9 -x logpersist.start 2>/dev/null

    setprop ctl.stop logd 2>/dev/null
    setprop logd.logpersistd "" 2>/dev/null
    setprop logd.logpersistd.enable false 2>/dev/null

    sleep 1
    if pgrep -x logd >/dev/null 2>&1; then
        log "  ⚠️ logd 仍在运行，尝试更强手段"
        killall -9 logd 2>/dev/null
    else
        log "  ✅ logd 已停止"
    fi

    log "[Logd] 完成"
else
    log "[Logd] 未启用，跳过"
fi

# ===================== 2. OTA 阻断（补充杀进程） =====================
if [ "$(getprop ${PROP_PREFIX}block_ota)" = "true" ]; then
    log "[OTA] 补充执行：杀进程 + 禁用包..."

    stop update_engine 2>/dev/null
    pkill -9 -x update_engine 2>/dev/null
    pkill -9 -f "update_engine" 2>/dev/null
    setprop ctl.stop update_engine 2>/dev/null

    disable_pkg "com.oplus.ota"
    disable_pkg "com.oplus.sau"
    disable_pkg "com.coloros.ota"
    disable_pkg "com.oplus.otaex"

    setprop persist.ota.auto_download 0
    setprop persist.sys.recovery_update 0
    setprop persist.sys.ota.disabled 1

    sleep 1
    if pgrep -x update_engine >/dev/null 2>&1; then
        log "  ⚠️ update_engine 仍在运行"
        killall -9 update_engine 2>/dev/null
    else
        log "  ✅ update_engine 已停止"
    fi

    log "[OTA] 完成"
else
    log "[OTA] 未启用，跳过"
fi

# ===================== 3. 开发者选项锁定 =====================
if [ "$(getprop ${PROP_PREFIX}lock_developer_options)" = "true" ]; then
    log "[DevLock] 锁定开发者选项..."
    settings put global development_settings_enabled 0 2>/dev/null
    settings put secure show_touches 0 2>/dev/null
    setprop persist.dev.option.lock 1
    log "[DevLock] 完成"
else
    log "[DevLock] 未启用，跳过"
fi

# ===================== 4. 广告与数据收集屏蔽 =====================
if [ "$(getprop ${PROP_PREFIX}block_ads_and_tracking)" = "true" ]; then
    log "[Ads] 关闭广告与数据收集..."

    settings put global oppo_ad_enabled 0 2>/dev/null
    settings put secure oppo_ad_personalization 0 2>/dev/null
    settings put global oppo_experience_plan 0 2>/dev/null
    settings put global oppo_data_collection 0 2>/dev/null
    settings put global device_experience_enabled 0 2>/dev/null

    # 对齐 verify_status.sh 检查的 5 个属性
    setprop persist.sys.oplus.ad_enable 0
    setprop persist.sys.oplus.personalized_ad 0
    setprop persist.ad.track 0
    setprop persist.sys.usage_stat_enable 0
    setprop persist.oppo.collect 0

    # 对齐 verify_status.sh 检查的 3 个包
    disable_pkg "com.oplus.statistics.rom"
    disable_pkg "com.coloros.assistantscreen"
    disable_pkg "com.coloros.sceneservice"

    log "[Ads] 完成"
else
    log "[Ads] 未启用，跳过"
fi

# ===================== 5. 进程查杀 =====================
if [ "$(getprop ${PROP_PREFIX}kill_redundant_processes)" = "true" ]; then
    log "[Procs] 查杀冗余进程..."

    KILL_LIST="smartscene preload sysmonitor hotstart daemondaemon oplusmemchecker"
    for proc in $KILL_LIST; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            pkill -9 -x "$proc" 2>/dev/null
            log "  杀死: $proc"
        fi
    done

    setprop persist.sys.preload 0
    setprop persist.sys.monitor 0
    setprop persist.sys.hotstart 0

    log "[Procs] 完成"
else
    log "[Procs] 未启用，跳过"
fi

# ===================== 6. 系统属性开关 =====================
if [ "$(getprop ${PROP_PREFIX}system_prop_toggles)" = "true" ]; then
    log "[SysProps] 设置系统属性..."

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
    log "[SysProps] 未启用，跳过"
fi

# ===================== 7. 内核参数二次写入 =====================
log "[Kernel] 二次写入内核参数..."

echo 0 > /proc/sys/kernel/sched_schedstats 2>/dev/null
echo 0 > /sys/module/binder/parameters/debug_mask 2>/dev/null
echo 0 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null
echo 3 > /proc/sys/kernel/printk_console_loglevel 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null
echo 30 > /proc/sys/vm/swappiness 2>/dev/null
echo 10 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null

log "  sched_schedstats=$(cat /proc/sys/kernel/sched_schedstats 2>/dev/null)"
log "  binder_mask=$(cat /sys/module/binder/parameters/debug_mask 2>/dev/null)"
log "  compact=$(cat /proc/sys/vm/compact_unevictable_allowed 2>/dev/null)"
log "  printk=$(cat /proc/sys/kernel/printk 2>/dev/null)"
log "  thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
log "  swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"

log "[Kernel] 完成"

# ===================== 8. 健康服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_health_services)" = "true" ]; then
    log "[Health] 禁用健康服务..."
    disable_pkg "com.oplus.healthservice"
    disable_pkg "com.heytap.health"
fi

# ===================== 9. 流量监控与网络服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_network_monitoring)" = "true" ]; then
    log "[NetMon] 禁用流量监控..."
    disable_pkg "com.oplus.trafficmonitor"
    disable_pkg "com.oplus.dmp"
fi

# ===================== 10. 锁屏杂志与壁纸服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_lockscreen_magazine)" = "true" ]; then
    log "[LockMag] 禁用锁屏杂志..."
    disable_pkg "com.heytap.pictorial"
    setprop persist.sys.lockscreen_magazine 0
fi

# ===================== 11. 游戏空间与性能监控 =====================
if [ "$(getprop ${PROP_PREFIX}disable_gamespace)" = "true" ]; then
    log "[GameSpace] 禁用游戏空间..."
    disable_pkg "com.oplus.games"
fi

# ===================== 12. 钱包与支付服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_wallet_services)" = "true" ]; then
    log "[Wallet] 禁用钱包..."
    disable_pkg "com.oplus.pay"
    disable_pkg "com.coloros.securepay"
    disable_pkg "com.finshell.wallet"
fi

# ===================== 13. 备份与云服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_backup_services)" = "true" ]; then
    log "[Backup] 禁用备份..."
    disable_pkg "com.oplus.wifibackuprestore"
    disable_pkg "com.heytap.cloud"
fi

# ===================== 14. AI 智能助手 =====================
if [ "$(getprop ${PROP_PREFIX}disable_ai_assistants)" = "true" ]; then
    log "[AI] 禁用 AI 助手..."
    disable_pkg "com.oplus.aimemory"
    disable_pkg "com.oplus.aiunit"
    disable_pkg "com.oplus.aiwidgets"
    disable_pkg "com.oplus.aiwriter"
    disable_pkg "com.oplus.metis"
    disable_pkg "com.oplus.obrain"
fi

# ===================== 15. 语音助手 =====================
if [ "$(getprop ${PROP_PREFIX}disable_voice_assistants)" = "true" ]; then
    log "[Voice] 禁用语音助手..."
    disable_pkg "com.oplus.ovoicemanager"
    disable_pkg "com.oplus.ovoicemanager.wakeup"
    disable_pkg "com.heytap.speechassist"
    disable_pkg "com.oplus.ttsaccessibilityengine"
fi

# ===================== 16. 主题和个性化服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_theme_services)" = "true" ]; then
    log "[Theme] 禁用主题服务..."
    disable_pkg "com.oplus.themestore"
    disable_pkg "com.heytap.themestore"
    disable_pkg "com.oplus.keyguard.clock.magazine"
    disable_pkg "com.oplus.keyguard.clock.gallery"
    disable_pkg "com.oplus.keyguard.clock.graffiti"
    disable_pkg "com.oplus.keyguard.personality.clocks"
    disable_pkg "com.oplus.keyguard.style.widgets"
fi

# ===================== 17. 网络优化服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_network_optimization)" = "true" ]; then
    log "[NetOpt] 禁用网络优化..."
    disable_pkg "com.oplus.networksense"
    disable_pkg "com.oplus.cellularqoe"
    disable_pkg "com.oplus.tai.wifiqoe"
    disable_pkg "com.oplus.tai.borderpresearch"
    disable_pkg "com.oplus.nearcomm"
fi

# ===================== 18. 安全和权限服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_security_services)" = "true" ]; then
    log "[Security] 禁用安全服务..."
    disable_pkg "com.oplus.securitykeyboard"
    disable_pkg "com.coloros.securityguard"
fi

# ===================== 19. 多媒体和娱乐服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_media_services)" = "true" ]; then
    log "[Media] 禁用多媒体..."
    disable_pkg "com.oplus.screenrecorder"
    disable_pkg "com.coloros.karaoke"
    disable_pkg "com.oplus.mediacontroller"
fi

# ===================== 20. 系统工具和监控服务 =====================
if [ "$(getprop ${PROP_PREFIX}disable_system_tools)" = "true" ]; then
    log "[SysTools] 禁用系统工具..."
    disable_pkg "com.oplus.powermonitor"
    disable_pkg "com.oplus.audiomonitor"
    disable_pkg "com.oplus.logkit"
    disable_pkg "com.oplus.engineermode"
    disable_pkg "com.oplus.crashbox"
    disable_pkg "com.oplus.appplatform"
    disable_pkg "com.oplus.contentportal"
    disable_pkg "com.oplus.postmanservice"
    disable_pkg "com.oplus.subsys"
fi

# ===================== 写入状态 =====================
log "写入状态..."
echo "last_run=$(date '+%Y-%m-%d %H:%M:%S')" > "$WORK_DIR/service_status.log"
echo "status=ok" >> "$WORK_DIR/service_status.log"

log "========== service.sh 执行完毕 =========="