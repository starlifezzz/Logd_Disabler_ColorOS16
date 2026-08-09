#!/system/bin/sh
# ================================================================
# ColorOS16 优化模块 - post-fs-data 阶段脚本
# 执行时机：data 分区挂载后、系统服务启动前
# ================================================================

MODDIR=${0%/*}
PROP_PREFIX="persist.sys.coloros16_optimize_gui."
WORK_DIR="/data/adb/logd_disabler"
LOG_FILE="$WORK_DIR/post-fs-data.log"

mkdir -p "$WORK_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "========== post-fs-data.sh 开始执行 =========="

# 创建 dummy 文件（用于 mount bind 覆盖二进制）
DUMMY="$WORK_DIR/dummy"
if [ ! -f "$DUMMY" ]; then
    touch "$DUMMY"
    chmod 755 "$DUMMY"
    log "创建 dummy 文件"
fi

# ===================== SELinux 规则注入 =====================
# 【关键修复】允许 late_start service 执行 pm disable-user / pm uninstall
# 这些规则在 post-fs-data 阶段注入，确保 service.sh 阶段有权限
log "[SELinux] 注入包管理相关规则..."

# 允许 system_server 和 system_app 执行包管理操作
# 使用 magiskpolicy 或直接写入 sepolicy（KernelSU 环境）
MAGISK_POLICY=""
if [ -f "/data/adb/ksu/bin/ksud" ]; then
    MAGISK_POLICY="/data/adb/ksu/bin/ksud sepolicy"
elif [ -f "/data/adb/magisk/magiskpolicy" ]; then
    MAGISK_POLICY="/data/adb/magisk/magiskpolicy --live"
fi

if [ -n "$MAGISK_POLICY" ]; then
    # 允许 init shell 执行 pm 命令
    $MAGISK_POLICY "allow init package_manager_service binder { call transfer }" 2>/dev/null
    $MAGISK_POLICY "allow system_server package_manager_service binder { call transfer }" 2>/dev/null
    $MAGISK_POLICY "allow system_app package_manager_service binder { call transfer }" 2>/dev/null
    # 允许 late_start service 的 shell context 调用 PMS
    $MAGISK_POLICY "allow u:r:su:s0 package_manager_service binder { call transfer }" 2>/dev/null
    $MAGISK_POLICY "allow u:r:magisk:s0 package_manager_service binder { call transfer }" 2>/dev/null
    log "[SELinux] 规则注入完成"
else
    log "[SELinux] 未找到 sepolicy 工具，跳过"
fi

# ===================== Logd 禁用 =====================
if [ "$(getprop ${PROP_PREFIX}disable_logd)" = "true" ]; then
    log "[Logd] 开始 mount 覆盖..."
    for bin in logd logcat logpersist.start logpersist.stop logtagd; do
        TARGET="/system/bin/$bin"
        if [ -f "$TARGET" ]; then
            mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
            if [ $? -eq 0 ]; then
                log "  ✅ 覆盖成功: $TARGET"
            else
                log "  ❌ 覆盖失败: $TARGET (尝试其他方法)"
                cp "$DUMMY" "$TARGET" 2>/dev/null
            fi
        fi
    done
    for bin in logd logcat; do
        TARGET="/system/xbin/$bin"
        if [ -f "$TARGET" ]; then
            mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
            log "  覆盖 xbin: $TARGET"
        fi
    done
    setprop logd.logpersistd "" 2>/dev/null
    setprop logd.logpersistd.enable false 2>/dev/null
    setprop persist.logd.disabled 1
    log "[Logd] mount 覆盖完成"
else
    log "[Logd] 未启用，跳过"
fi

# ===================== OTA 阻断 =====================
if [ "$(getprop ${PROP_PREFIX}block_ota)" = "true" ]; then
    log "[OTA] 开始 mount 覆盖..."
    for bin in update_engine update_engine_client; do
        TARGET="/system/bin/$bin"
        if [ -f "$TARGET" ]; then
            mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
            if [ $? -eq 0 ]; then
                log "  ✅ 覆盖成功: $TARGET"
            else
                log "  ❌ 覆盖失败: $TARGET"
            fi
        fi
    done
    for apk_dir in /system/app/OTA /system/priv-app/OTA /system/app/OplusOTA /system/priv-app/OplusOTA; do
        if [ -d "$apk_dir" ]; then
            mount -o bind "$DUMMY" "$apk_dir" 2>/dev/null
            log "  覆盖 OTA 目录: $apk_dir"
        fi
    done
    rm -rf /data/data/com.oplus.ota/cache/* 2>/dev/null
    rm -rf /data/data/com.coloros.ota/cache/* 2>/dev/null
    rm -rf /data/ota_package/* 2>/dev/null
    setprop persist.sys.ota.disabled 1
    setprop persist.ota.auto_download 0
    log "[OTA] 覆盖完成"
else
    log "[OTA] 未启用，跳过"
fi

log "[Kernel] 内核参数已移至 service.sh 处理（受 WebUI 开关控制）"
log "========== post-fs-data.sh 执行完毕 =========="