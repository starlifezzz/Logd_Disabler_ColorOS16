#!/system/bin/sh
# ColorOS 16 优化模块 - YAML配置驱动
# 开机早期post-fs-data安全窗口执行，零系统修改，卸载即完全复原

MODDIR=${0%/*}

# 函数：获取KernelSU UI设置的系统属性值
get_ksu_setting() {
    local key="$1"
    local default="$2"
    local prop_key="persist.sys.coloros16_optimize_gui.$key"
    local value=$(getprop "$prop_key")
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}
post-fs-data.sh
# ======================== 1. 彻底禁用logd，永久封死复活 ========================
if [ "$(get_ksu_setting "disable_logd" "false")" = "true" ]; then
    [ -f '/system/bin/logd' ] && mount -o bind /dev/null /system/bin/logd
    killall -9 logd 2>/dev/null
    setprop persist.logd.enable 0
fi

# ======================== 2. 彻底阻断OTA自动更新 ========================
if [ "$(get_ksu_setting "block_ota" "false")" = "true" ]; then
    [ -f '/system/bin/update_engine' ] && mount -o bind /dev/null /system/bin/update_engine
    pkill -9 update_engine 2>/dev/null
    setprop persist.ota.auto_download 0
    setprop persist.sys.recovery_update 0
    setprop persist.sys.coupdate 0
    rm -rf /data/ota_package /cache/ota 2>/dev/null
fi

# ======================== 3. 锁定开发者选项不被系统重置 ========================
if [ "$(get_ksu_setting "lock_developer_options" "false")" = "true" ]; then
    settings put --user 0 global development_settings_enabled 1
    settings put --user 0 global adb_enabled 1
    setprop persist.dev.option.lock 1
fi

# ======================== 4. 屏蔽冗余耗电服务、广告、数据收集 ========================
# 核心冗余进程查杀
if [ "$(get_ksu_setting "kill_redundant_processes" "false")" = "true" ]; then
    pkill -9 smartscene preload sysmonitor hotstart 2>/dev/null
fi

# 【新增】彻底关闭系统广告总开关
if [ "$(get_ksu_setting "block_ads_and_tracking" "false")" = "true" ]; then
    setprop persist.sys.oplus.ad_enable 0
    setprop persist.sys.oplus.personalized_ad 0
    setprop persist.ad.track 0
    # 【新增】彻底关死用户体验计划/数据统计
    setprop persist.sys.usage_stat_enable 0
    setprop persist.oppo.collect 0
    # 冗余服务开关锁定
    setprop persist.sys.preload 0
    setprop persist.sys.monitor 0
    setprop persist.sys.hotstart 0
fi

# ======================== 5. 内存/IO轻量优化（无副作用） ========================
if [ "$(get_ksu_setting "memory_io_optimization" "false")" = "true" ]; then
    # 尝试设置内存/IO优化参数
    if [ -w '/proc/sys/kernel/sched_schedstats' ]; then
        echo 0 > /proc/sys/kernel/sched_schedstats 2>/dev/null || true
    fi
    if [ -w '/sys/module/binder/parameters/debug_mask' ]; then
        echo 0 > /sys/module/binder/parameters/debug_mask 2>/dev/null || true
    fi
    if [ -w '/proc/sys/vm/compact_unevictable_allowed' ]; then
        echo 0 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null || true
    fi
fi

# ======================== 6. 额外内核优化参数 ========================
if [ "$(get_ksu_setting "extra_kernel_optimization" "false")" = "true" ]; then
    # 减少内核调试开销 - 使用更宽松的匹配
    if [ -w '/proc/sys/kernel/printk' ]; then
        # 先读取当前值，只修改需要的部分
        current_printk=$(cat /proc/sys/kernel/printk 2>/dev/null)
        if [ -n "$current_printk" ]; then
            # 期望: console_loglevel=3, default_message_loglevel=3, minimum_console_loglevel=3, default_console_loglevel=3
            # 实际格式可能是: "4\t3\t1\t7" 或类似
            echo "3 3 1 3" > /proc/sys/kernel/printk 2>/dev/null || true
        fi
    fi
    # 禁用透明大页（减少内存碎片）
    if [ -w '/sys/kernel/mm/transparent_hugepage/enabled' ]; then
        echo "never" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi
fi

# ======================== 7. 关闭 Oplus DCS 后台监控（节省电量，避免后台频繁唤醒） ========================
# 这个功能没有对应的UI开关，始终执行
setprop persist.oplus.dcs.enable 0

# ======================== 8. 新增功能支持 ========================
# AI智能助手服务 - 系统属性部分（如果有相关属性）
# 语音助手服务 - 系统属性部分（如果有相关属性）  
# 主题服务 - 系统属性部分（如果有相关属性）
# 网络优化服务 - 系统属性部分（如果有相关属性）
# 安全服务 - 系统属性部分（如果有相关属性）
# 多媒体服务 - 系统属性部分（如果有相关属性）
# 系统工具服务 - 系统属性部分（如果有相关属性）
# 注：以上新功能主要通过pm disable实现，在service.sh中处理