#!/system/bin/sh
# 添加执行权限检查
if [ ! -x "$0" ]; then
    chmod +x "$0"
fi
# ColorOS 16 优化模块 - 后期服务脚本
# 在late_start阶段执行，用于处理需要完整系统环境的功能（如包禁用）

MODDIR=${0%/*}

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

# 禁用指定的包（带错误处理和重试）
disable_package_if_enabled() {
    local package="$1"
    local config_key="$2"
    local enabled=$(get_ksu_setting "$config_key" "false")
    
    if [ "$enabled" = "true" ]; then
        log_info "Disabling package: $package"
        # 尝试禁用包，最多重试3次
        for i in 1 2 3; do
            if pm disable-user --user 0 "$package" 2>/dev/null; then
                log_info "Successfully disabled $package on attempt $i"
                break
            else
                log_info "Failed to disable $package on attempt $i, retrying..."
                sleep 1
            fi
        done
    else
        log_info "Enabling package: $package (user disabled the feature)"
        # 尝试启用包，最多重试3次
        for i in 1 2 3; do
            if pm enable --user 0 "$package" 2>/dev/null; then
                log_info "Successfully enabled $package on attempt $i"
                break
            else
                log_info "Failed to enable $package on attempt $i, retrying..."
                sleep 1
            fi
        done
    fi
}

# 主要执行逻辑
log_info "Starting ColorOS16 optimization service script"

# 等待PackageManager服务完全启动
sleep 5

# 处理主题和个性化服务
disable_package_if_enabled "com.oplus.themestore" "disable_theme_services"
disable_package_if_enabled "com.heytap.themestore" "disable_theme_services"
disable_package_if_enabled "com.oplus.keyguard.clock.magazine" "disable_theme_services"
disable_package_if_enabled "com.oplus.keyguard.clock.gallery" "disable_theme_services"
disable_package_if_enabled "com.oplus.keyguard.clock.graffiti" "disable_theme_services"
disable_package_if_enabled "com.oplus.keyguard.personality.clocks" "disable_theme_services"
disable_package_if_enabled "com.oplus.keyguard.style.widgets" "disable_theme_services"

# 处理网络优化服务
disable_package_if_enabled "com.oplus.networksense" "disable_network_optimization"
disable_package_if_enabled "com.oplus.cellularqoe" "disable_network_optimization"
disable_package_if_enabled "com.oplus.tai.wifiqoe" "disable_network_optimization"
disable_package_if_enabled "com.oplus.tai.borderpresearch" "disable_network_optimization"
disable_package_if_enabled "com.oplus.nearcomm" "disable_network_optimization"

# 处理安全和权限服务
disable_package_if_enabled "com.oplus.securitypermission" "disable_security_services"
disable_package_if_enabled "com.oplus.securitykeyboard" "disable_security_services"
disable_package_if_enabled "com.coloros.securityguard" "disable_security_services"
disable_package_if_enabled "com.coloros.remoteguardservice" "disable_security_services"

# 处理多媒体和娱乐服务
disable_package_if_enabled "com.oplus.games" "disable_media_services"
disable_package_if_enabled "com.oplus.screenrecorder" "disable_media_services"
disable_package_if_enabled "com.coloros.karaoke" "disable_media_services"
disable_package_if_enabled "com.oplus.mediacontroller" "disable_media_services"

# 处理系统工具和监控服务
disable_package_if_enabled "com.oplus.powermonitor" "disable_system_tools"
disable_package_if_enabled "com.oplus.audiomonitor" "disable_system_tools"
disable_package_if_enabled "com.oplus.logkit" "disable_system_tools"
disable_package_if_enabled "com.oplus.engineermode" "disable_system_tools"
disable_package_if_enabled "com.oplus.crashbox" "disable_system_tools"
disable_package_if_enabled "com.oplus.appplatform" "disable_system_tools"
disable_package_if_enabled "com.oplus.contentportal" "disable_system_tools"
disable_package_if_enabled "com.oplus.postmanservice" "disable_system_tools"
disable_package_if_enabled "com.oplus.subsys" "disable_system_tools"

# 处理AI智能助手服务
disable_package_if_enabled "com.oplus.aimemory" "disable_ai_assistants"
disable_package_if_enabled "com.oplus.aiunit" "disable_ai_assistants"
disable_package_if_enabled "com.oplus.aiwidgets" "disable_ai_assistants"
disable_package_if_enabled "com.oplus.aiwriter" "disable_ai_assistants"
disable_package_if_enabled "com.oplus.metis" "disable_ai_assistants"
disable_package_if_enabled "com.oplus.obrain" "disable_ai_assistants"

# 处理语音助手服务
disable_package_if_enabled "com.oplus.ovoicemanager" "disable_voice_assistants"
disable_package_if_enabled "com.oplus.ovoicemanager.wakeup" "disable_voice_assistants"
disable_package_if_enabled "com.heytap.speechassist" "disable_voice_assistants"
disable_package_if_enabled "com.oplus.ttsaccessibilityengine" "disable_voice_assistants"

# 处理流量监控与网络服务
disable_package_if_enabled "com.oplus.trafficmonitor" "disable_network_monitoring"
disable_package_if_enabled "com.oplus.dmp" "disable_network_monitoring"

# 处理健康服务（修正）
disable_package_if_enabled "com.oplus.healthservice" "disable_health_services"
disable_package_if_enabled "com.heytap.health" "disable_health_services"

# 处理游戏空间服务（修正）
disable_package_if_enabled "com.oplus.games" "disable_gamespace"

# 处理钱包服务（修正）
disable_package_if_enabled "com.oplus.pay" "disable_wallet_services"
disable_package_if_enabled "com.coloros.securepay" "disable_wallet_services"
disable_package_if_enabled "com.finshell.wallet" "disable_wallet_services"

# 处理备份服务（修正）
disable_package_if_enabled "com.oplus.wifibackuprestore" "disable_backup_services"
disable_package_if_enabled "com.heytap.cloud" "disable_backup_services"

# 处理锁屏杂志服务（修正）
disable_package_if_enabled "com.heytap.pictorial" "disable_lockscreen_magazine"

# 系统属性开关已在post-fs-data.sh中处理，此处无需重复

log_info "ColorOS16 optimization service script completed"