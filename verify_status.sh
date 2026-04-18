#!/bin/sh
# ColorOS 16 优化模块状态验证脚本
# 用于检查各项配置和功能的实际状态

MODDIR=${0%/*}
CONFIG_FILE="$MODDIR/config.yaml"

echo "========================================"
echo "ColorOS16 优化模块状态验证报告"
echo "========================================"
echo "当前时间: $(date)"
echo "模块目录: $MODDIR"
echo ""

# 检查配置文件是否存在
if [ -f "$CONFIG_FILE" ]; then
    echo "✅ 配置文件存在: $CONFIG_FILE"
    echo "配置文件大小: $(wc -c < "$CONFIG_FILE") 字节"
else
    echo "❌ 配置文件不存在!"
    echo "请确保已重启设备以生成配置文件"
    exit 1
fi
echo ""

# 函数：检查YAML配置值（简化版）
check_yaml_config() {
    section="$1"
    # 使用更简单的grep方法，直接搜索 "section_name:" 后跟 "enabled:"
    enabled=$(grep -A 10 "^[[:space:]]*$section:" "$CONFIG_FILE" | grep "^[[:space:]]*enabled:" | head -n 1 | sed 's/.*:[[:space:]]*//')
    
    if [ "$enabled" = "true" ]; then
        echo "  🟢 已启用"
    elif [ "$enabled" = "false" ]; then
        echo "  🔴 已禁用"
    else
        # 如果第一种方法失败，尝试另一种模式
        enabled=$(grep -B 5 "^[[:space:]]*enabled:[[:space:]]*true" "$CONFIG_FILE" | grep "^[[:space:]]*$section:" | wc -l)
        if [ "$enabled" -gt 0 ]; then
            echo "  🟢 已启用"
        else
            enabled=$(grep -B 5 "^[[:space:]]*enabled:[[:space:]]*false" "$CONFIG_FILE" | grep "^[[:space:]]*$section:" | wc -l)
            if [ "$enabled" -gt 0 ]; then
                echo "  🔴 已禁用"
            else
                echo "  ⚠️  配置错误或未找到"
            fi
        fi
    fi
}

# 函数：检查进程是否运行
check_process() {
    process_name="$1"
    if pgrep -f "$process_name" > /dev/null 2>&1; then
        echo "  🔴 正在运行"
    else
        echo "  🟢 已停止"
    fi
}

# 函数：检查包是否被禁用
check_package_disabled() {
    local package="$1"
    # 首先检查包是否存在
    if pm list packages --user 0 | grep -q "$package"; then
        # 包存在，检查是否被禁用
        if pm list packages -d --user 0 | grep -q "$package"; then
            echo "  🟢 已禁用"
        else
            echo "  🔴 已启用"
        fi
    else
        # 包不存在，可能是不同设备的包名差异
        echo "  ⚠️  包不存在 (可能设备型号不同)"
    fi
}

# 函数：检查系统属性
check_system_prop() {
    prop="$1"
    expected_value="$2"
    actual_value=$(getprop "$prop")
    if [ "$actual_value" = "$expected_value" ]; then
        echo "  🟢 正确 ($actual_value)"
    else
        echo "  🔴 错误 (期望: $expected_value, 实际: $actual_value)"
    fi
}

# 函数：检查内核参数
check_kernel_param() {
    param_path="$1"
    expected_value="$2"
    if [ -f "$param_path" ]; then
        actual_value=$(cat "$param_path" 2>/dev/null)
        if [ "$actual_value" = "$expected_value" ]; then
            echo "  🟢 正确 ($actual_value)"
        else
            echo "  🔴 错误 (期望: $expected_value, 实际: $actual_value)"
        fi
    else
        echo "  ⚠️  参数文件不存在"
    fi
}

# 1. 日志系统优化状态
echo "1. 日志系统优化 (disable_logd):"
check_yaml_config "disable_logd"
echo "   logd 进程状态:"
check_process "logd"
echo "   logd 文件状态:"
if [ -f "/system/bin/logd" ]; then
    if [ -L "/system/bin/logd" ] || [ ! -x "/system/bin/logd" ]; then
        echo "  🟢 已被挂载覆盖或禁用"
    else
        echo "  🔴 仍可执行"
    fi
else
    echo "  ⚠️  logd 文件不存在"
fi
echo ""

# 2. OTA更新阻断状态
echo "2. OTA更新阻断 (block_ota):"
check_yaml_config "block_ota"
echo "   update_engine 进程状态:"
check_process "update_engine"
echo "   OTA相关包状态:"
check_package_disabled "com.oplus.ota"
check_package_disabled "com.oplus.sau"
echo "   系统属性状态:"
check_system_prop "persist.ota.auto_download" "0"
check_system_prop "persist.sys.recovery_update" "0"
echo ""

# 3. 开发者选项锁定状态
echo "3. 开发者选项锁定 (lock_developer_options):"
check_yaml_config "lock_developer_options"
echo "   系统属性状态:"
check_system_prop "persist.dev.option.lock" "1"
echo ""

# 4. 广告与数据收集屏蔽状态
echo "4. 广告与数据收集屏蔽 (block_ads_and_tracking):"
check_yaml_config "block_ads_and_tracking"
echo "   相关包状态:"
check_package_disabled "com.oplus.statistics.rom"
check_package_disabled "com.coloros.assistant"  
check_package_disabled "com.coloros.assistantscreen"
echo "   系统属性状态:"
check_system_prop "persist.sys.oplus.ad_enable" "0"
check_system_prop "persist.sys.oplus.personalized_ad" "0"
check_system_prop "persist.ad.track" "0"
check_system_prop "persist.sys.usage_stat_enable" "0"
check_system_prop "persist.oppo.collect" "0"
echo ""

# 5. 内存/IO优化状态
echo "5. 内存/IO优化 (memory_io_optimization):"
check_yaml_config "memory_io_optimization"
echo "   内核参数状态:"
check_kernel_param "/proc/sys/kernel/sched_schedstats" "0"
check_kernel_param "/sys/module/binder/parameters/debug_mask" "0"
check_kernel_param "/proc/sys/vm/compact_unevictable_allowed" "0"
echo ""

# 7. 健康服务状态
echo "7. 健康服务 (disable_health_services):"
check_yaml_config "disable_health_services"
echo "   健康服务包状态:"
check_package_disabled "com.oplus.healthservice"
check_package_disabled "com.oplus.sports"
echo ""

# 8. 冗余进程状态
echo "8. 冗余进程状态:"
echo "   smartscene:"
check_process "smartscene"
echo "   preload:"
check_process "preload"
echo "   sysmonitor:"
check_process "sysmonitor"
echo "   hotstart:"
check_process "hotstart"
echo ""

# 9. SELinux 状态
echo "9. SELinux 状态:"
selinux_status=$(getenforce)
if [ "$selinux_status" = "Permissive" ]; then
    echo "  🟢 当前为 Permissive (宽容模式)"
elif [ "$selinux_status" = "Enforcing" ]; then
    echo "  🔴 当前为 Enforcing (强制模式) - 可能影响部分优化生效"
else
    echo "  ⚠️  未知状态: $selinux_status"
fi
echo ""

# 10. ZRAM/Swap 状态 (如果模块涉及内存优化)
echo "10. ZRAM/Swap 状态:"
if [ -f "/sys/block/zram0/disksize" ]; then
    zram_size=$(cat /sys/block/zram0/disksize 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$zram_size" ] && [ "$zram_size" != "0" ]; then
        # 检查是否为数字
        if echo "$zram_size" | grep -qE '^[0-9]+$'; then
            echo "  🟢 ZRAM 已启用 (大小: $((zram_size / 1024 / 1024)) MB)"
        else
            echo "  ⚠️  ZRAM 大小格式异常: $zram_size"
        fi
    else
        echo "  🔴 ZRAM 未正确配置或已禁用"
    fi
else
    # 检查其他可能的zram设备
    if ls /sys/block/zram* >/dev/null 2>&1; then
        echo "  ⚠️  ZRAM 设备存在但 disksize 文件不可访问"
    else
        echo "  ⚠️  未检测到 ZRAM 设备"
    fi
fi
echo ""

# 11. 关键服务禁用状态 (示例)
echo "11. 关键系统服务状态:"
echo "   检查是否有被禁用的优化相关服务..."
# 这里可以添加具体的服务检查，例如：
# pm list services | grep -i "oplus" | head -n 5
echo "  ℹ️  如需检查特定服务，请手动使用 'pm list services'"
echo ""

# 12. 模块加载状态 (KernelSU/Magisk)
echo "12. 模块管理器状态:"
if [ -d "/data/adb/ksu" ]; then
    echo "  🟢 检测到 KernelSU 环境"
elif [ -d "/data/adb/magisk" ]; then
    echo "  🟢 检测到 Magisk 环境"
else
    echo "  ⚠️  未检测到常见的 Root 管理器目录"
fi
echo ""

echo "========================================"
echo "验证完成！"
echo ""
echo "使用说明:"
echo "- 🟢 表示功能正常工作"
echo "- 🔴 表示功能未生效或有问题"
echo "- ⚠️ 表示配置或环境异常"
echo ""
echo "如果发现配置已启用但功能未生效，请检查:"
echo "1. 是否已重启设备"
echo "2. KernelSU模块是否已正确安装并启用"
echo "3. SELinux策略是否阻止了相关操作"
echo "========================================"