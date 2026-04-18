#!/system/bin/sh
# ColorOS 16 YAML配置解析和应用脚本
# 符合KernelSU规范
# Copyright (c) 2026 zhangchongjie. All rights reserved.
# 未经授权禁止商业使用和二次分发

MODDIR=${0%/*}
CONFIG_FILE="$MODDIR/config.yaml"
CONFIG_DEFAULT="$MODDIR/system/etc/coloros16_optimize_config.yaml"

# 全局变量
EARLY_STAGE=false

# 日志函数
log_info() {
    echo "[ColorOS16-Optimize] $1" >&2
}

log_warn() {
    echo "[ColorOS16-Optimize] WARN: $1" >&2
}

log_error() {
    echo "[ColorOS16-Optimize] ERROR: $1" >&2
}

# 检查文件是否存在
file_exists() {
    [ -f "$1" ] && [ -r "$1" ]
}

# 简单YAML解析函数 - 提取布尔值
yaml_get_bool() {
    local section="$1"
    local key="$2"
    local file="$3"
    
    if ! file_exists "$file"; then
        return 1
    fi
    
    # 查找section下的enabled字段
    if [ "$key" = "enabled" ]; then
        local pattern="^ *$section:"
        local enabled_line=$(grep -A 10 "$pattern" "$file" | grep -m 1 "^[[:space:]]*enabled:")
        if [ -n "$enabled_line" ]; then
            local value=$(echo "$enabled_line" | sed 's/.*:[[:space:]]*//')
            case "$(echo "$value" | tr '[:upper:]' '[:lower:]')" in
                "true"|"yes"|"1"|"on")
                    return 0  # true
                    ;;
                *)
                    return 1  # false
                    ;;
            esac
        fi
    fi
    return 1
}

# 应用系统属性
apply_system_props() {
    local props="$1"
    local value="$2"
    
    for prop in $props; do
        if setprop "$prop" "$value" 2>/dev/null; then
            log_info "Set property: $prop = $value"
        else
            log_warn "Failed to set property: $prop"
        fi
    done
}

# 禁用系统包
disable_packages() {
    local packages="$1"
    
    for pkg in $packages; do
        if pm disable --user 0 "$pkg" 2>/dev/null; then
            log_info "Disabled package: $pkg"
        else
            log_warn "Failed to disable package: $pkg (may not exist)"
        fi
    done
}

# 杀死进程
kill_processes() {
    local processes="$1"
    
    for proc in $processes; do
        if pkill -9 "$proc" 2>/dev/null; then
            log_info "Killed process: $proc"
        fi
    done
}

# 设置内核参数
set_kernel_param() {
    local path="$1"
    local value="$2"
    
    if [ -w "$path" ]; then
        echo "$value" > "$path" 2>/dev/null
        if [ $? -eq 0 ]; then
            log_info "Set kernel param: $path = $value"
        else
            log_warn "Failed to set kernel param: $path"
        fi
    else
        log_warn "Kernel param not writable: $path"
    fi
}

# 早期阶段应用（只执行核心功能，不依赖配置文件）
apply_early_stage() {
    log_info "Applying early-stage optimizations (no config file access)"
    
    # 1. 日志系统优化（核心功能）
    [ -f '/system/bin/logd' ] && mount -o bind /dev/null /system/bin/logd
    killall -9 logd 2>/dev/null
    apply_system_props "persist.logd.enable" "0"
    
    # 2. OTA更新阻断（核心功能）
    [ -f '/system/bin/update_engine' ] && mount -o bind /dev/null /system/bin/update_engine
    pkill -9 update_engine 2>/dev/null
    apply_system_props "persist.ota.auto_download persist.sys.recovery_update persist.sys.coupdate" "0"
    rm -rf /data/ota_package /cache/ota 2>/dev/null
    
    # 3. 内存/IO优化（核心功能）
    set_kernel_param "/proc/sys/kernel/sched_schedstats" "0"
    set_kernel_param "/sys/module/binder/parameters/debug_mask" "0"
    set_kernel_param "/proc/sys/vm/compact_unevictable_allowed" "0"
    
    # 4. 进程查杀（核心功能）
    kill_processes "smartscene preload sysmonitor hotstart"
    
    log_info "Early-stage optimizations applied"
}

# 主配置应用函数
apply_configuration() {
    local config_file="$1"
    
    log_info "Applying configuration from: $config_file"
    
    # 1. 日志系统优化
    if yaml_get_bool "disable_logd" "enabled" "$config_file"; then
        log_info "Applying: Disable logd"
        [ -f '/system/bin/logd' ] && mount -o bind /dev/null /system/bin/logd
        killall -9 logd 2>/dev/null
        apply_system_props "persist.logd.enable" "0"
    fi
    
    # 2. OTA更新阻断
    if yaml_get_bool "block_ota" "enabled" "$config_file"; then
        log_info "Applying: Block OTA updates"
        [ -f '/system/bin/update_engine' ] && mount -o bind /dev/null /system/bin/update_engine
        pkill -9 update_engine 2>/dev/null
        apply_system_props "persist.ota.auto_download persist.sys.recovery_update persist.sys.coupdate" "0"
        rm -rf /data/ota_package /cache/ota 2>/dev/null
        
        # 禁用OTA相关包
        disable_packages "com.oplus.ota com.oplus.sau com.coloros.ota com.coloros.sau"
    fi
    
    # 3. 开发者选项锁定
    if yaml_get_bool "lock_developer_options" "enabled" "$config_file"; then
        log_info "Applying: Lock developer options"
        settings put --user 0 global development_settings_enabled 1
        settings put --user 0 global adb_enabled 1
        apply_system_props "persist.dev.option.lock" "1"
    fi
    
    # 4. 广告与数据收集屏蔽
    if yaml_get_bool "block_ads_and_tracking" "enabled" "$config_file"; then
        log_info "Applying: Block ads and tracking"
        # 杀死冗余进程
        kill_processes "smartscene preload sysmonitor hotstart"
        
        # 禁用相关包
        disable_packages "com.oplus.statistics.rom com.coloros.assistant com.coloros.assistantscreen com.coloros.sceneservice com.oplus.breeno"
        
        # 设置系统属性
        apply_system_props "persist.sys.oplus.ad_enable persist.sys.oplus.personalized_ad persist.ad.track persist.sys.usage_stat_enable persist.oppo.collect" "0"
    fi
    
    # 5. 内存/IO优化
    if yaml_get_bool "memory_io_optimization" "enabled" "$config_file"; then
        log_info "Applying: Memory/IO optimization"
        set_kernel_param "/proc/sys/kernel/sched_schedstats" "0"
        set_kernel_param "/sys/module/binder/parameters/debug_mask" "0"
        set_kernel_param "/proc/sys/vm/compact_unevictable_allowed" "0"
    fi
    
    # 7. 健康服务
    if yaml_get_bool "disable_health_services" "enabled" "$config_file"; then
        log_info "Applying: Disable health services"
        disable_packages "com.oplus.healthservice com.oplus.sports"
    fi
    
    # 8. 网络监控
    if yaml_get_bool "disable_network_monitoring" "enabled" "$config_file"; then
        log_info "Applying: Disable network monitoring"
        disable_packages "com.oplus.trafficmonitor com.oplus.dmp com.oplus.search"
    fi
    
    # 9. 锁屏杂志
    if yaml_get_bool "disable_lockscreen_magazine" "enabled" "$config_file"; then
        log_info "Applying: Disable lockscreen magazine"
        disable_packages "com.coloros.pictorial com.oplus.wallpaper"
        apply_system_props "persist.sys.lockscreen_magazine" "0"
    fi
    
    # 10. 游戏空间
    if yaml_get_bool "disable_gamespace" "enabled" "$config_file"; then
        log_info "Applying: Disable gamespace"
        disable_packages "com.coloros.gamespace com.oplus.gamespace com.oplus.performance"
    fi
    
    # 11. 钱包服务
    if yaml_get_bool "disable_wallet_services" "enabled" "$config_file"; then
        log_info "Applying: Disable wallet services"
        disable_packages "com.coloros.wallet com.oplus.wallet com.nearme.atlas"
    fi
    
    # 12. 备份服务
    if yaml_get_bool "disable_backup_services" "enabled" "$config_file"; then
        log_info "Applying: Disable backup services"
        disable_packages "com.coloros.backuprestore com.heytap.cloud"
    fi
    
    # 13. 额外内核优化
    if yaml_get_bool "extra_kernel_optimization" "enabled" "$config_file"; then
        log_info "Applying: Extra kernel optimization"
        set_kernel_param "/proc/sys/kernel/printk" "3 3 3 3"
        set_kernel_param "/sys/kernel/mm/transparent_hugepage/enabled" "never"
    fi
    
    # 14. 进程查杀（如果未在广告屏蔽中处理）
    if yaml_get_bool "kill_redundant_processes" "enabled" "$config_file"; then
        if ! yaml_get_bool "block_ads_and_tracking" "enabled" "$config_file"; then
            log_info "Applying: Kill redundant processes"
            kill_processes "smartscene preload sysmonitor hotstart"
        fi
    fi
    
    # 15. 系统属性开关
    if yaml_get_bool "system_prop_toggles" "enabled" "$config_file"; then
        log_info "Applying: System property toggles"
        apply_system_props "persist.sys.preload persist.sys.monitor persist.sys.hotstart" "0"
    fi
}

# 主执行逻辑
main() {
    # 检查参数
    if [ "$1" = "--early-stage" ]; then
        EARLY_STAGE=true
    fi
    
    if [ "$EARLY_STAGE" = true ]; then
        apply_early_stage
        return 0
    fi
    
    log_info "Starting ColorOS16 optimization module"
    
    # 确定使用哪个配置文件
    if file_exists "$CONFIG_FILE"; then
        log_info "Using user configuration: $CONFIG_FILE"
        apply_configuration "$CONFIG_FILE"
    elif file_exists "$CONFIG_DEFAULT"; then
        log_info "Using default configuration: $CONFIG_DEFAULT"
        apply_configuration "$CONFIG_DEFAULT"
    else
        log_error "No configuration file found!"
        return 1
    fi
    
    log_info "Configuration applied successfully"
}

# 执行主函数
main "$@"