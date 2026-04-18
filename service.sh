#!/system/bin/sh
# ColorOS 16 优化模块 - 后期服务脚本
# 在late_start阶段执行，用于处理需要完整系统环境的功能

MODDIR=${0%/*}
CONFIG_FILE="$MODDIR/config.yaml"
CONFIG_DEFAULT="$MODDIR/system/etc/coloros16_optimize_config.yaml"

# 日志函数
log_info() {
    echo "[ColorOS16-Optimize] $1" >&2
}

# 从KernelSU UI设置读取配置值
get_ksu_setting() {
    local key="$1"
    local default="$2"
    local value=$(grep "^$key=" "$MODDIR/module.prop" | cut -d'=' -f2)
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
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