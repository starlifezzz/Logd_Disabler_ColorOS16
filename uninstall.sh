#!/system/bin/sh
# ============================================================
# Logd_Disabler_ColorOS16 卸载回滚脚本（uninstall.sh）
# - 恢复所有被禁用的包（pm enable / install-existing）
# - 恢复被修改的系统属性与内核参数
# - 卸载 bind mount 覆盖（logd/update_engine/OTA 目录/WiFi conf/蓝牙日志 tmpfs）
# - 清理 config.json 数据目录与日志
# 说明：KernelSU 卸载模块时自动执行本脚本（存在即调用）
# ============================================================

MODDIR=${0%/*}
WORK_DIR="/data/adb/logd_disabler"
CONFIG_DIR="/data/adb/Logd_Disabler_ColorOS16"

ui_print "======================================"
ui_print "  Logd_Disabler_ColorOS16 回滚中..."
ui_print "======================================"

log() { echo "$@" >> "$WORK_DIR/uninstall.log" 2>/dev/null; }
mkdir -p "$WORK_DIR" 2>/dev/null
log "========== uninstall.sh 开始 =========="
log "时间: $(date)"

# 静默执行 pm（与 service.sh 一致的 su 提升策略）
PMX_USE_SU=0
if command -v su >/dev/null 2>&1 && su -c "id" 2>&1 | grep -qE "uid=0|root"; then
    PMX_USE_SU=1
fi
pmx() {
    if [ "$PMX_USE_SU" = "1" ]; then su -c "$*" 2>/dev/null; else "$@" 2>/dev/null; fi
}

# ===================== 1. 恢复全部包 =====================
# 汇总 service.sh 中所有可能被禁用的包（PKG_TABLE + 特殊块 + 总开关）
ui_print "- 恢复被禁用的包..."
ALL_PKGS="
com.oplus.healthservice
com.oplus.trafficmonitor
com.oplus.dmp
com.oplus.games
com.oplus.cosa
com.oplus.pay
com.coloros.securepay
com.oplus.wifibackuprestore
com.heytap.cloud
com.oplus.aimemory
com.oplus.aiunit
com.oplus.aiwidgets
com.oplus.aiwriter
com.oplus.metis
com.oplus.obrain
com.oplus.deepthinker
com.coloros.colordirectservice
com.oplus.ovoicemanager
com.oplus.ovoicemanager.wakeup
com.heytap.speechassist
com.oplus.ttsaccessibilityengine
com.oplus.themestore
com.heytap.themestore
com.oplus.keyguard.clock.magazine
com.oplus.keyguard.clock.gallery
com.oplus.keyguard.clock.graffiti
com.oplus.keyguard.personality.clocks
com.oplus.keyguard.style.widgets
com.heytap.pictorial
com.oplus.wallpapers
com.android.wallpaper.livepicker
com.oplus.networksense
com.oplus.cellularqoe
com.oplus.tai.wifiqoe
com.oplus.tai.borderpresearch
com.oplus.nearcomm
com.oplus.securitykeyboard
com.coloros.securityguard
com.oplus.screenrecorder
com.coloros.karaoke
com.oplus.mediacontroller
com.oplus.mediaturbo
com.oplus.powermonitor
com.oplus.audiomonitor
com.oplus.logkit
com.oplus.engineermode
com.oplus.crashbox
com.oplus.contentportal
com.oplus.postmanservice
com.oplus.subsys
com.oplus.engineernetwork
com.coloros.ocs.opencapabilityservice
com.oplus.apprecover
com.oplus.exsystemservice
com.oplus.notificationmanager
com.heytap.accessory
com.oplus.linker
com.oplus.remotecontrol
com.oplus.travelengine
com.oplus.nearcomm
com.oplus.mediaturbo
com.coloros.colordirectservice
com.oplus.deepthinker
com.oplus.engineernetwork
com.oplus.ota
com.oplus.sau
com.oplus.cota
com.oplus.romupdate
com.oplus.upgradeguide
com.oplus.statistics.rom
com.coloros.assistantscreen
com.coloros.sceneservice
"
RESTORED=0
SKIPPED=0
for pkg in $ALL_PKGS; do
    # 恢复策略：先尝试 pm enable；若包对 user0 不可见（曾 uninstall -k），走 install-existing
    if pmx pm list packages -d --user 0 2>/dev/null | grep -qF "package:$pkg"; then
        if pmx pm enable --user 0 "$pkg" >/dev/null 2>&1; then
            RESTORED=$((RESTORED + 1))
        fi
    elif ! pmx pm list packages --user 0 2>/dev/null | grep -qF "package:$pkg"; then
        # 包存在但 user0 不可见 → install-existing 恢复
        if pmx pm list packages 2>/dev/null | grep -qF "package:$pkg"; then
            pmx cmd package install-existing "$pkg" >/dev/null 2>&1
            RESTORED=$((RESTORED + 1))
        else
            SKIPPED=$((SKIPPED + 1))  # 设备上不存在此包
        fi
    else
        SKIPPED=$((SKIPPED + 1))  # 包正常运行中，无需恢复
    fi
done
log "包恢复完成: 恢复 $RESTORED 个, 跳过 $SKIPPED 个"
ui_print "  已恢复 $RESTORED 个包"

# ===================== 2. 卸载 bind mount =====================
# 【v2.3.7】范围补全：原版只覆盖 /system/bin 的 logd/update_engine + OTA 目录，
#   漏了 /system/xbin，也完全没覆盖 v2.3.7 新增的 WiFi/蓝牙日志挂载。
#   漏 umount 的后果：卸载模块后挂载依然存在，配置看似"没恢复"。
ui_print "- 卸载挂载覆盖..."
for bin in logd logcat logpersist.start logpersist.stop logtagd update_engine update_engine_client; do
    umount "/system/bin/$bin" 2>/dev/null
    umount "/system/xbin/$bin" 2>/dev/null
done
for apk_dir in /system/app/OTA /system/priv-app/OTA /system/app/OplusOTA /system/priv-app/OplusOTA; do
    umount "$apk_dir" 2>/dev/null
done
# --- WiFi 日志：卸载对 /odm 源 conf 的 bind，恢复原始 LOG_PATH_FLAG = 1 ---
umount /odm/etc/wifi/cnss_diag.conf 2>/dev/null
umount /odm/etc/wifi/cnss_diag_always_on.conf 2>/dev/null
# --- WiFi 日志：卸载对 persist 副本的 bind（v2.3.7 新增，wifiserver 的 cp 目标）---
umount /mnt/vendor/persist/wlan/cnss_diag.conf 2>/dev/null
umount /mnt/vendor/persist/wlan/cnss_diag_always_on.conf 2>/dev/null
# --- WiFi 日志：卸载路径3 的 tmpfs 覆盖与 fallback 配置（纵深防御层）---
#   三个写入目录 umount 后露出底层真实空目录，写入恢复落盘行为。
umount /data/vendor/wifi/logs 2>/dev/null
umount /data/vendor/wifi/wlan_logs 2>/dev/null
umount /data/vendor/wifi/buffered_wlan_logs 2>/dev/null
umount /data/vendor/wifi/cnss_diag.conf 2>/dev/null
# --- 蓝牙日志：卸载 tmpfs overlay ---
#   tmpfs 内容随 umount 一并消失；磁盘上原有的 bluetooth_*.log 因此重新可见
#   （本模块从不删除它们，只是被遮蔽）。
umount /data/misc/bluetooth/logs 2>/dev/null
log "挂载卸载完成（含 WiFi conf / WiFi 写入目录 tmpfs / 蓝牙日志 tmpfs）"

# ===================== 3. 恢复系统属性 =====================
ui_print "- 恢复系统属性..."
# Logd
setprop logd.logpersistd.enable true 2>/dev/null
setprop persist.logd.disabled 0 2>/dev/null
setprop logd.logpersistd "" 2>/dev/null
# OTA
setprop persist.ota.auto_download 1 2>/dev/null
setprop persist.sys.recovery_update 1 2>/dev/null
setprop persist.sys.ota.disabled 0 2>/dev/null
# DevLock
setprop persist.dev.option.lock 0 2>/dev/null
# Ads
setprop persist.sys.oplus.ad_enable 1 2>/dev/null
setprop persist.sys.oplus.personalized_ad 1 2>/dev/null
setprop persist.ad.track 1 2>/dev/null
setprop persist.sys.usage_stat_enable 1 2>/dev/null
setprop persist.oppo.collect 1 2>/dev/null
# Procs / SysProps
setprop persist.sys.preload 1 2>/dev/null
setprop persist.sys.monitor 1 2>/dev/null
setprop persist.sys.hotstart 1 2>/dev/null
setprop persist.sys.assert.panic 1 2>/dev/null
setprop persist.debug.kept 1 2>/dev/null
setprop persist.sys.profiler_ms 1 2>/dev/null
setprop persist.sys.strictmode.disable 0 2>/dev/null
setprop persist.sys.strictmode.visual 1 2>/dev/null
setprop persist.traced.enable 1 2>/dev/null
setprop persist.traced_perf.enable 1 2>/dev/null
# 主题
setprop persist.sys.lockscreen_magazine 1 2>/dev/null
# 重启 logd（若有）
start logd 2>/dev/null
start update_engine 2>/dev/null

# ===================== 4. 恢复内核参数 =====================
ui_print "- 恢复内核参数..."
echo 1 > /proc/sys/kernel/sched_schedstats 2>/dev/null
echo 255 > /sys/module/binder/parameters/debug_mask 2>/dev/null
echo 1 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
echo 100 > /proc/sys/vm/swappiness 2>/dev/null
echo 20 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 10 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
echo 100 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
echo "4 4 1 7" > /proc/sys/kernel/printk 2>/dev/null
echo 4 > /proc/sys/kernel/printk_console_loglevel 2>/dev/null
echo always > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo always > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
echo always > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null

# ===================== 5. 清理配置与日志 =====================
ui_print "- 清理配置数据..."
rm -rf "$CONFIG_DIR" 2>/dev/null
rm -f "$WORK_DIR/dummy" 2>/dev/null
# v2.3.7：清理 WiFi persist 副本临时文件
rm -f "$WORK_DIR/cnss_diag.persist.conf" 2>/dev/null
rm -f "$WORK_DIR/cnss_diag_always_on.persist.conf" 2>/dev/null
# 【警告】fallback 配置仅在【本模块创建】时删除（靠 marker 判定），
#   系统原本就有该文件的情况一律保留，绝不误删。
if [ -f "$WORK_DIR/.wifi_fb_conf_created" ]; then
    rm -f /data/vendor/wifi/cnss_diag.conf 2>/dev/null
    rm -f "$WORK_DIR/.wifi_fb_conf_created" 2>/dev/null
fi
# 【警告】回收写入目录（umount 已在第 2 节完成）。用 rmdir 而非 rm -rf：
#   非空说明系统正在使用，一律保留不删。
if [ -f "$WORK_DIR/.wifi_dirs_created" ]; then
    # v2.3.7+：marker 精确记录本模块新建的目录
    while IFS= read -r _d; do
        [ -n "$_d" ] && rmdir "$_d" 2>/dev/null
    done < "$WORK_DIR/.wifi_dirs_created"
    rm -f "$WORK_DIR/.wifi_dirs_created" 2>/dev/null
else
    # 【兼容 ≤v2.3.6】那两个目录由旧版创建，当时还没有 marker 机制。
    # 只回退这两个【实测确认模块新建】的路径；/data/vendor/wifi/logs 是系统原生目录，
    # 任何情况下都不碰。仍只用 rmdir（空才删），非空即保留。
    rmdir /data/vendor/wifi/wlan_logs 2>/dev/null
    rmdir /data/vendor/wifi/buffered_wlan_logs 2>/dev/null
fi
# 清理 bootloop 保护文件
rm -f /data/adb/coloros16_boot_count 2>/dev/null
rm -f /data/adb/coloros16_bootloop_flag 2>/dev/null
log "已删除配置目录: $CONFIG_DIR"
# 清理 WORK_DIR 日志与临时文件
rm -f "$WORK_DIR/service.log" 2>/dev/null
rm -f "$WORK_DIR/service_status.log" 2>/dev/null
rm -f "$WORK_DIR/post-fs-data.log" 2>/dev/null
rm -f "$WORK_DIR/uninstall.log" 2>/dev/null
rm -f "$WORK_DIR/debug_info.txt" 2>/dev/null
log "已清理 WORK_DIR 日志文件"
log "========== uninstall.sh 完成 =========="

ui_print "✅ 回滚完成！所有被禁用的包、属性、内核参数已恢复。"
ui_print "   建议重启一次设备以彻底恢复系统服务（logd/update_engine）。"
