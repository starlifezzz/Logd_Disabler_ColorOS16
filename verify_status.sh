#!/system/bin/sh
# ColorOS 16 优化模块状态验证脚本
# 【修复】同时检查 pm list packages --user 0 和 pm list packages -d --user 0
# 因为 pm disable-user 的包仍在列表中，但会出现在 -d 列表中

MODDIR=${0%/*}

echo "========================================"
echo "ColorOS16 优化模块状态验证报告"
echo "========================================"
echo "当前时间: $(date)"
echo "模块目录: $MODDIR"
echo ""

# 函数：获取KernelSU UI设置的系统属性值
get_ksu_setting() {
    local key="$1"
    local default="$2"
    local value=$(getprop "persist.sys.coloros16_optimize_gui.$key")
    if [ -z "$value" ]; then
        echo "$default"
    else
        if [ "$value" = "true" ] || [ "$value" = "1" ]; then
            echo "true"
        elif [ "$value" = "false" ] || [ "$value" = "0" ]; then
            echo "false"
        else
            echo "$value"
        fi
    fi
}

# 函数：检查进程是否运行
check_process() {
    process_name="$1"
    if pgrep -f "$process_name" > /dev/null 2>&1; then
        echo "  🔴 正在运行"
        return 0
    fi
    if pidof "$process_name" > /dev/null 2>&1; then
        echo "  🔴 正在运行"
        return 0
    fi
    if [ "$process_name" = "logd" ]; then
        if ps -A | grep -v grep | grep -q 'logd'; then
            echo "  🔴 正在运行"
            return 0
        fi
    fi
    echo "  🟢 已停止"
    return 1
}

# 函数：检查包状态并对比用户配置
# 【核心修复】同时检查三种情况：
# 1. 包不在 pm list packages --user 0 中 → 已被 uninstall → 已优化
# 2. 包在 pm list packages -d --user 0 中 → 已被 disable-user → 已优化
# 3. 包在列表中且不在 -d 列表中 → 正常运行 → 未优化
check_package_with_config() {
    local package="$1"
    local config_key="$2"
    local user_enabled=$(get_ksu_setting "$config_key" "false")

    # 检查包是否存在于系统中（任何用户）
    if ! pm list packages 2>/dev/null | grep -qF "package:$package"; then
        # 包完全不存在（可能是设备不包含此包）
        if [ "$user_enabled" = "true" ]; then
            echo "  ⚠️ 包不存在于此设备"
        else
            echo "  ⚠️ 包不存在于此设备"
        fi
        return
    fi

    # 检查包是否对用户可见
    local in_user_list=false
    if pm list packages --user 0 2>/dev/null | grep -qF "package:$package"; then
        in_user_list=true
    fi

    # 检查包是否在 disabled 列表中
    local in_disabled_list=false
    if pm list packages -d --user 0 2>/dev/null | grep -qF "package:$package"; then
        in_disabled_list=true
    fi

    # 判断包的实际状态
    if [ "$in_user_list" = "false" ]; then
        # 包已被 uninstall
        if [ "$user_enabled" = "true" ]; then
            echo "  🟢 已卸载（已优化）"
        else
            echo "  ⚠️ 已卸载（但用户未要求禁用）"
        fi
    elif [ "$in_disabled_list" = "true" ]; then
        # 包已被 disable-user
        if [ "$user_enabled" = "true" ]; then
            echo "  🟢 已禁用（已优化）"
        else
            echo "  ⚠️ 已禁用（但用户未要求禁用）"
        fi
    else
        # 包正常运行中
        if [ "$user_enabled" = "true" ]; then
            echo "  🔴 未优化（包仍在运行，与用户设置冲突）"
        else
            echo "  🟢 正常运行（符合预期）"
        fi
    fi
}

# 函数：检查系统属性状态并对比用户配置
check_system_prop_with_config() {
    local prop="$1"
    local expected_value="$2"
    local config_key="$3"
    local user_enabled=$(get_ksu_setting "$config_key" "false")

    actual_value=$(getprop "$prop")

    if [ "$actual_value" = "$expected_value" ]; then
        if [ "$user_enabled" = "true" ]; then
            echo "  🟢 已优化"
        else
            echo "  🔴 已优化（应为未优化）"
        fi
    else
        if [ "$user_enabled" = "true" ]; then
            echo "  🔴 未优化（期望: $expected_value, 实际: $actual_value）"
        else
            echo "  🟢 未优化"
        fi
    fi
}

# 函数：检查内核参数状态并对比用户配置（严格匹配）
check_kernel_param_with_config() {
    local param_path="$1"
    local expected_value="$2"
    local config_key="$3"
    local user_enabled=$(get_ksu_setting "$config_key" "false")

    if [ -f "$param_path" ]; then
        actual_value=$(cat "$param_path" 2>/dev/null)
        if [ "$actual_value" = "$expected_value" ]; then
            if [ "$user_enabled" = "true" ]; then
                echo "  🟢 已优化"
            else
                echo "  🔴 已优化（应为未优化）"
            fi
        else
            if [ "$user_enabled" = "true" ]; then
                echo "  🔴 未优化（期望: $expected_value, 实际: $actual_value）"
            else
                echo "  🟢 未优化"
            fi
        fi
    else
        if [ "$user_enabled" = "true" ]; then
            echo "  ⚠️ 未优化（参数文件不存在）"
        else
            echo "  🟢 未优化（参数文件不存在）"
        fi
    fi
}

# 1. 日志系统优化状态
echo "1. 日志系统优化:"
disable_logd_enabled=$(get_ksu_setting "disable_logd" "false")
if [ "$disable_logd_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用日志）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   logd 进程状态:"
check_process "logd"
echo "   logd 文件状态:"
if [ -f "/system/bin/logd" ]; then
    if [ -L "/system/bin/logd" ] || [ ! -x "/system/bin/logd" ]; then
        echo "  🟢 已被挂载覆盖或禁用"
    else
        file_size=$(stat -c %s "/system/bin/logd" 2>/dev/null)
        if [ "$file_size" = "0" ]; then
            echo "  🟢 文件已被清空或挂载覆盖"
        else
            file_perms=$(stat -c %a "/system/bin/logd" 2>/dev/null)
            if [ "$file_perms" = "000" ]; then
                echo "  🟢 文件权限已被禁用"
            else
                echo "  🔴 仍可执行"
            fi
        fi
    fi
else
    echo "  ⚠️ logd 文件不存在"
fi
echo ""

# 2. OTA更新阻断状态
echo "2. OTA更新阻断:"
block_ota_enabled=$(get_ksu_setting "block_ota" "false")
if [ "$block_ota_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（阻断更新）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   update_engine 进程状态:"
check_process "update_engine"
echo "   OTA相关包状态:"
check_package_with_config "com.oplus.ota" "block_ota"
check_package_with_config "com.oplus.sau" "block_ota"
echo "   系统属性状态:"
check_system_prop_with_config "persist.ota.auto_download" "0" "block_ota"
check_system_prop_with_config "persist.sys.recovery_update" "0" "block_ota"
echo ""

# 3. 开发者选项锁定状态
echo "3. 开发者选项锁定:"
lock_dev_options_enabled=$(get_ksu_setting "lock_developer_options" "false")
if [ "$lock_dev_options_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（锁定选项）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   系统属性状态:"
check_system_prop_with_config "persist.dev.option.lock" "1" "lock_developer_options"
echo ""

# 4. 广告与数据收集屏蔽状态
echo "4. 广告与数据收集屏蔽:"
block_ads_enabled=$(get_ksu_setting "block_ads_and_tracking" "false")
if [ "$block_ads_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（屏蔽广告）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   相关包状态:"
check_package_with_config "com.oplus.statistics.rom" "block_ads_and_tracking"
check_package_with_config "com.coloros.assistantscreen" "block_ads_and_tracking"
check_package_with_config "com.coloros.sceneservice" "block_ads_and_tracking"
echo "   系统属性状态:"
check_system_prop_with_config "persist.sys.oplus.ad_enable" "0" "block_ads_and_tracking"
check_system_prop_with_config "persist.sys.oplus.personalized_ad" "0" "block_ads_and_tracking"
check_system_prop_with_config "persist.ad.track" "0" "block_ads_and_tracking"
check_system_prop_with_config "persist.sys.usage_stat_enable" "0" "block_ads_and_tracking"
check_system_prop_with_config "persist.oppo.collect" "0" "block_ads_and_tracking"
echo ""

# 5. 内存/IO优化状态
echo "5. 内存/IO优化:"
mem_io_opt_enabled=$(get_ksu_setting "memory_io_optimization" "false")
if [ "$mem_io_opt_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   内核参数状态:"
check_kernel_param_with_config "/proc/sys/kernel/sched_schedstats" "0" "memory_io_optimization"
check_kernel_param_with_config "/sys/module/binder/parameters/debug_mask" "0" "memory_io_optimization"
check_kernel_param_with_config "/proc/sys/vm/compact_unevictable_allowed" "0" "memory_io_optimization"
echo ""

# 6. 额外内核优化状态
echo "6. 额外内核优化:"
extra_kernel_enabled=$(get_ksu_setting "extra_kernel_optimization" "false")
if [ "$extra_kernel_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   内核参数状态:"

# printk 专用检测
printk_path="/proc/sys/kernel/printk"
if [ -f "$printk_path" ]; then
    actual_printk=$(cat "$printk_path" 2>/dev/null)
    normalized_printk=$(echo "$actual_printk" | tr '\t' ' ' | tr -s ' ')
    printk_v2=$(echo "$normalized_printk" | awk '{print $2}')
    printk_v3=$(echo "$normalized_printk" | awk '{print $3}')
    printk_v4=$(echo "$normalized_printk" | awk '{print $4}')
    if [ "$extra_kernel_enabled" = "true" ]; then
        if [ "$printk_v2" = "3" ] && [ "$printk_v3" = "3" ] && [ "$printk_v4" = "3" ]; then
            echo "  🟢 已优化 (printk=$normalized_printk)"
        else
            echo "  🔴 未优化（期望: x 3 3 3, 实际: $normalized_printk）"
        fi
    else
        echo "  🟢 未优化 (printk=$normalized_printk)"
    fi
else
    if [ "$extra_kernel_enabled" = "true" ]; then
        echo "  ⚠️ 未优化（参数文件不存在）"
    else
        echo "  🟢 未优化（参数文件不存在）"
    fi
fi

# THP 专用检测
thp_path="/sys/kernel/mm/transparent_hugepage/enabled"
if [ -f "$thp_path" ]; then
    actual_thp=$(cat "$thp_path" 2>/dev/null)
    if [ "$extra_kernel_enabled" = "true" ]; then
        if echo "$actual_thp" | grep -q '\[never\]'; then
            echo "  🟢 已优化 (THP=$actual_thp)"
        else
            echo "  🔴 未优化（期望: [never], 实际: $actual_thp）"
        fi
    else
        echo "  🟢 未优化 (THP=$actual_thp)"
    fi
else
    if [ "$extra_kernel_enabled" = "true" ]; then
        echo "  ⚠️ 未优化（参数文件不存在）"
    else
        echo "  🟢 未优化（参数文件不存在）"
    fi
fi
echo ""

# 8. 流量监控与网络服务状态
echo "8. 流量监控与网络服务:"
net_monitor_enabled=$(get_ksu_setting "disable_network_monitoring" "false")
if [ "$net_monitor_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用监控）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   网络服务包状态:"
check_package_with_config "com.oplus.trafficmonitor" "disable_network_monitoring"
check_package_with_config "com.oplus.dmp" "disable_network_monitoring"
echo ""

# 9. 锁屏杂志与壁纸服务状态
echo "9. 锁屏杂志与壁纸服务:"
lockscreen_mag_enabled=$(get_ksu_setting "disable_lockscreen_magazine" "false")
if [ "$lockscreen_mag_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用杂志）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   锁屏杂志包状态:"
check_package_with_config "com.heytap.pictorial" "disable_lockscreen_magazine"
echo "   系统属性状态:"
check_system_prop_with_config "persist.sys.lockscreen_magazine" "0" "disable_lockscreen_magazine"
echo ""

# 10. 游戏空间与性能监控状态
echo "10. 游戏空间与性能监控:"
gamespace_enabled=$(get_ksu_setting "disable_gamespace" "false")
if [ "$gamespace_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用游戏空间）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   游戏空间包状态:"
check_package_with_config "com.oplus.games" "disable_gamespace"
echo ""

# 12. 备份与云服务状态
echo "12. 备份与云服务:"
backup_services_enabled=$(get_ksu_setting "disable_backup_services" "false")
if [ "$backup_services_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用备份）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   备份服务包状态:"
check_package_with_config "com.oplus.wifibackuprestore" "disable_backup_services"
check_package_with_config "com.heytap.cloud" "disable_backup_services"
echo ""

# 13. AI智能助手服务状态
echo "13. AI智能助手服务:"
ai_assistants_enabled=$(get_ksu_setting "disable_ai_assistants" "false")
if [ "$ai_assistants_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用AI）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   AI助手包状态:"
check_package_with_config "com.oplus.aimemory" "disable_ai_assistants"
check_package_with_config "com.oplus.aiunit" "disable_ai_assistants"
check_package_with_config "com.oplus.aiwidgets" "disable_ai_assistants"
check_package_with_config "com.oplus.aiwriter" "disable_ai_assistants"
check_package_with_config "com.oplus.metis" "disable_ai_assistants"
check_package_with_config "com.oplus.obrain" "disable_ai_assistants"
echo ""

# 14. 语音助手服务状态
echo "14. 语音助手服务:"
voice_assistant_enabled=$(get_ksu_setting "disable_voice_assistants" "false")
if [ "$voice_assistant_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用语音）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   语音助手包状态:"
check_package_with_config "com.oplus.ovoicemanager" "disable_voice_assistants"
check_package_with_config "com.oplus.ovoicemanager.wakeup" "disable_voice_assistants"
check_package_with_config "com.heytap.speechassist" "disable_voice_assistants"
check_package_with_config "com.oplus.ttsaccessibilityengine" "disable_voice_assistants"
echo ""

# 15. 主题和个性化服务状态
echo "15. 主题和个性化服务:"
theme_service_enabled=$(get_ksu_setting "disable_theme_services" "false")
if [ "$theme_service_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用主题）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   主题服务包状态:"
check_package_with_config "com.oplus.themestore" "disable_theme_services"
check_package_with_config "com.heytap.themestore" "disable_theme_services"
check_package_with_config "com.oplus.keyguard.clock.magazine" "disable_theme_services"
check_package_with_config "com.oplus.keyguard.clock.gallery" "disable_theme_services"
check_package_with_config "com.oplus.keyguard.clock.graffiti" "disable_theme_services"
check_package_with_config "com.oplus.keyguard.personality.clocks" "disable_theme_services"
check_package_with_config "com.oplus.keyguard.style.widgets" "disable_theme_services"
echo ""

# 16. 网络优化服务状态
echo "16. 网络优化服务:"
network_optimization_enabled=$(get_ksu_setting "disable_network_optimization" "false")
if [ "$network_optimization_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用网络优化）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   网络优化包状态:"
check_package_with_config "com.oplus.networksense" "disable_network_optimization"
check_package_with_config "com.oplus.cellularqoe" "disable_network_optimization"
check_package_with_config "com.oplus.tai.wifiqoe" "disable_network_optimization"
check_package_with_config "com.oplus.tai.borderpresearch" "disable_network_optimization"
check_package_with_config "com.oplus.nearcomm" "disable_network_optimization"
echo ""

# 17. 安全和权限服务状态
echo "17. 安全和权限服务:"
security_service_enabled=$(get_ksu_setting "disable_security_services" "false")
if [ "$security_service_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用安全服务）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   安全服务包状态:"
check_package_with_config "com.oplus.securitykeyboard" "disable_security_services"
check_package_with_config "com.coloros.securityguard" "disable_security_services"
echo ""

# 18. 多媒体和娱乐服务状态
echo "18. 多媒体和娱乐服务:"
media_services_enabled=$(get_ksu_setting "disable_media_services" "false")
if [ "$media_services_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用多媒体）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   多媒体服务包状态:"
check_package_with_config "com.oplus.screenrecorder" "disable_media_services"
check_package_with_config "com.coloros.karaoke" "disable_media_services"
check_package_with_config "com.oplus.mediacontroller" "disable_media_services"
echo ""

# 19. 系统工具和监控服务状态
echo "19. 系统工具和监控服务:"
system_tools_enabled=$(get_ksu_setting "disable_system_tools" "false")
if [ "$system_tools_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用（禁用系统工具）"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   系统工具包状态:"
check_package_with_config "com.oplus.powermonitor" "disable_system_tools"
check_package_with_config "com.oplus.audiomonitor" "disable_system_tools"
check_package_with_config "com.oplus.logkit" "disable_system_tools"
check_package_with_config "com.oplus.engineermode" "disable_system_tools"
check_package_with_config "com.oplus.crashbox" "disable_system_tools"
check_package_with_config "com.oplus.appplatform" "disable_system_tools"
check_package_with_config "com.oplus.contentportal" "disable_system_tools"
check_package_with_config "com.oplus.postmanservice" "disable_system_tools"
check_package_with_config "com.oplus.subsys" "disable_system_tools"
echo ""

# 20. 进程查杀优化状态
echo "20. 进程查杀优化:"
kill_procs_enabled=$(get_ksu_setting "kill_redundant_processes" "false")
if [ "$kill_procs_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   冗余进程状态:"
echo "   smartscene:"
check_process "smartscene"
echo "   preload:"
check_process "preload"
echo "   sysmonitor:"
check_process "sysmonitor"
echo "   hotstart:"
check_process "hotstart"
echo ""

# 21. 系统属性开关状态
echo "21. 系统属性开关:"
system_props_enabled=$(get_ksu_setting "system_prop_toggles" "false")
if [ "$system_props_enabled" = "true" ]; then
    echo "   用户设置: 🟢 已启用"
else
    echo "   用户设置: 🔴 未启用"
fi
echo "   系统属性状态:"
check_system_prop_with_config "persist.sys.preload" "0" "system_prop_toggles"
check_system_prop_with_config "persist.sys.monitor" "0" "system_prop_toggles"
check_system_prop_with_config "persist.sys.hotstart" "0" "system_prop_toggles"
echo ""

# 22. SELinux 状态
echo "22. SELinux 状态:"
selinux_status=$(getenforce)
if [ "$selinux_status" = "Permissive" ]; then
    echo "  🟢 当前为 Permissive (宽容模式)"
elif [ "$selinux_status" = "Enforcing" ]; then
    echo "  🔴 当前为 Enforcing (强制模式) - 可能影响部分优化生效"
else
    echo "  ⚠️ 未知状态: $selinux_status"
fi
echo ""

# 23. ZRAM/Swap 状态
echo "23. ZRAM/Swap 状态:"
if [ -f "/sys/block/zram0/disksize" ]; then
    zram_size=$(cat /sys/block/zram0/disksize 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$zram_size" ] && [ "$zram_size" != "0" ]; then
        if echo "$zram_size" | grep -qE '^[0-9]+$'; then
            echo "  🟢 ZRAM 已启用 (大小: $((zram_size / 1024 / 1024)) MB)"
        else
            echo "  ⚠️ ZRAM 大小格式异常: $zram_size"
        fi
    else
        echo "  🔴 ZRAM 未正确配置或已禁用"
    fi
else
    if ls /sys/block/zram* >/dev/null 2>&1; then
        echo "  ⚠️ ZRAM 设备存在但 disksize 文件不可访问"
    else
        echo "  ⚠️ 未检测到 ZRAM 设备"
    fi
fi
echo ""

# 24. 模块加载状态
echo "24. 模块管理器状态:"
if [ -d "/data/adb/ksu" ]; then
    echo "  🟢 检测到 KernelSU 环境"
elif [ -d "/data/adb/magisk" ]; then
    echo "  🟢 检测到 Magisk 环境"
else
    echo "  ⚠️ 未检测到常见的 Root 管理器目录"
fi
echo ""

echo "========================================"
echo "验证完成！"
echo ""
echo "使用说明:"
echo "- 🟢 表示功能正常工作（已优化/已禁用）"
echo "- 🔴 表示功能未生效或有问题"
echo "- ⚠️ 表示配置或环境异常"
echo ""
echo "如果发现配置已启用但功能未生效，请检查:"
echo "1. 是否已重启设备"
echo "2. KernelSU模块是否已正确安装并启用"
echo "3. SELinux策略是否阻止了相关操作"
echo "========================================"