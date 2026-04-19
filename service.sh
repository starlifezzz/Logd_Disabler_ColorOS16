#!/system/bin/sh
# Test service script
echo "Test module loaded" >&2
# ColorOS 16 优化模块 - 后期服务脚本
# 在late_start阶段执行，用于处理需要完整系统环境的功能

MODDIR=${0%/*}
CONFIG_FILE="$MODDIR/config.yaml"
CONFIG_DEFAULT="$MODDIR/system/etc/coloros16_optimize_config.yaml"

# 日志函数
log_info() {
    echo "[ColorOS16-Optimize] $1" >&2
}

# 从KernelSU UI设置读取配置值（通过系统属性）
get_ksu_setting() {
    local key="$1"
    local default="$2"
    # KernelSU UI设置存储为系统属性 persist.sys.<module_id>.<key>
    local prop_key="persist.sys.coloros16_optimize_gui.$key"
    local value=$(getprop "$prop_key")
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
}

# 更新YAML配置文件中的单个配置项
update_yaml_config_item() {
    local section="$1"
    local new_value="$2"
    local config_file="$3"
    
    # 创建临时文件
    local temp_file="${config_file}.tmp"
    
    # 复制原文件到临时文件
    cp "$config_file" "$temp_file"
    
    # 使用更可靠的sed命令更新配置项
    # 先删除原有的enabled行，再插入新的
    sed -i "/^[[:space:]]*$section:/,/^[[:space:]]*[^[:space:]]/{
        /^[[:space:]]*enabled:/d
    }" "$temp_file"
    
    # 在section后插入新的enabled行
    sed -i "/^[[:space:]]*$section:/a \    enabled: $new_value" "$temp_file"
    
    # 验证临时文件是否有效，然后替换原文件
    if [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
        mv "$temp_file" "$config_file"
        chmod 644 "$config_file"
        log_info "Updated $section to $new_value"
    else
        log_info "Failed to update $section, keeping original config"
        rm -f "$temp_file"
    fi
}

# 从KernelSU UI设置更新YAML配置
update_config_from_ksu_ui() {
    log_info "Updating config from KernelSU UI settings"
    
    # 读取UI设置并更新YAML配置
    local disable_logd=$(get_ksu_setting "disable_logd" "true")
    local block_ota=$(get_ksu_setting "block_ota" "true")
    local lock_dev_options=$(get_ksu_setting "lock_developer_options" "true")
    local block_ads=$(get_ksu_setting "block_ads_and_tracking" "true")
    local mem_io_opt=$(get_ksu_setting "memory_io_optimization" "true")
    local extra_kernel=$(get_ksu_setting "extra_kernel_optimization" "true")
    local kill_procs=$(get_ksu_setting "kill_redundant_processes" "true")
    local sys_props=$(get_ksu_setting "system_prop_toggles" "true")
    local health_services=$(get_ksu_setting "disable_health_services" "false")
    local net_monitor=$(get_ksu_setting "disable_network_monitoring" "false")
    local lockscreen_mag=$(get_ksu_setting "disable_lockscreen_magazine" "false")
    local gamespace=$(get_ksu_setting "disable_gamespace" "false")
    local wallet_services=$(get_ksu_setting "disable_wallet_services" "false")
    local backup_services=$(get_ksu_setting "disable_backup_services" "false")
    
    # 更新YAML配置文件 - 使用更可靠的方法
    update_yaml_config_item "disable_logd" "$disable_logd" "$CONFIG_FILE"
    update_yaml_config_item "block_ota" "$block_ota" "$CONFIG_FILE"
    update_yaml_config_item "lock_developer_options" "$lock_dev_options" "$CONFIG_FILE"
    update_yaml_config_item "block_ads_and_tracking" "$block_ads" "$CONFIG_FILE"
    update_yaml_config_item "memory_io_optimization" "$mem_io_opt" "$CONFIG_FILE"
    update_yaml_config_item "extra_kernel_optimization" "$extra_kernel" "$CONFIG_FILE"
    update_yaml_config_item "kill_redundant_processes" "$kill_procs" "$CONFIG_FILE"
    update_yaml_config_item "system_prop_toggles" "$sys_props" "$CONFIG_FILE"
    update_yaml_config_item "disable_health_services" "$health_services" "$CONFIG_FILE"
    update_yaml_config_item "disable_network_monitoring" "$net_monitor" "$CONFIG_FILE"
    update_yaml_config_item "disable_lockscreen_magazine" "$lockscreen_mag" "$CONFIG_FILE"
    update_yaml_config_item "disable_gamespace" "$gamespace" "$CONFIG_FILE"
    update_yaml_config_item "disable_wallet_services" "$wallet_services" "$CONFIG_FILE"
    update_yaml_config_item "disable_backup_services" "$backup_services" "$CONFIG_FILE"
}

# 创建或使用配置文件，并从UI设置更新
create_config_with_ui_sync() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_info "Creating configuration file: $CONFIG_FILE"
        cp "$CONFIG_DEFAULT" "$CONFIG_FILE" 2>/dev/null
        if [ $? -eq 0 ]; then
            log_info "Configuration created successfully"
            chmod 644 "$CONFIG_FILE" 2>/dev/null
        else
            log_info "Failed to create configuration"
            return 1
        fi
    else
        log_info "Using existing configuration: $CONFIG_FILE"
    fi
    
    # 从KernelSU UI设置更新YAML配置
    update_config_from_ksu_ui
}

# 主执行逻辑
main() {
    log_info "Starting ColorOS16 optimization service"
    
    # 创建或使用配置文件，并同步UI设置
    create_config_with_ui_sync
    
    # 应用配置
    "$MODDIR/apply_yaml_config.sh"
    
    log_info "Service completed"
}

# 执行主函数
main "$@"