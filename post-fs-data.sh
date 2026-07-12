#!/system/bin/sh
# ================================================================
# ColorOS16 优化模块 - post-fs-data 阶段脚本
# 执行时机：data 分区挂载后、系统服务启动前
# 注意：此阶段只有 logd/OTA 的 mount 覆盖需要在这里做
#       内核参数统一由 service.sh 处理（受 WebUI 开关控制）
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

# ===================== Logd 禁用 =====================
# 必须在 post-fs-data 阶段做 mount 覆盖，因为 service 阶段 logd 已经在跑了
if [ "$(getprop ${PROP_PREFIX}disable_logd)" = "true" ]; then
    log "[Logd] 开始 mount 覆盖..."

    # 覆盖 logd 相关二进制文件
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

    # 同样覆盖 /system/xbin 下的（某些 ColorOS 版本放在这里）
    for bin in logd logcat; do
        TARGET="/system/xbin/$bin"
        if [ -f "$TARGET" ]; then
            mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
            log "  覆盖 xbin: $TARGET"
        fi
    done

    # 禁用 logpersist（ColorOS16 的持久化日志）
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

    # 覆盖 OTA 相关 APK 的 odex（防止 dex2oat 后仍能运行）
    for apk_dir in /system/app/OTA /system/priv-app/OTA /system/app/OplusOTA /system/priv-app/OplusOTA; do
        if [ -d "$apk_dir" ]; then
            mount -o bind "$DUMMY" "$apk_dir" 2>/dev/null
            log "  覆盖 OTA 目录: $apk_dir"
        fi
    done

    # 清除 OTA 缓存
    rm -rf /data/data/com.oplus.ota/cache/* 2>/dev/null
    rm -rf /data/data/com.coloros.ota/cache/* 2>/dev/null
    rm -rf /data/ota_package/* 2>/dev/null

    setprop persist.sys.ota.disabled 1
    setprop persist.ota.auto_download 0

    log "[OTA] 覆盖完成"
else
    log "[OTA] 未启用，跳过"
fi

# ===================== 内核参数优化（已移至 service.sh）=====================
# 不再在此阶段无条件写入内核参数
# 所有内核参数（schedstats, binder, printk, THP, swappiness 等）
# 统一由 service.sh 根据 WebUI 开关状态决定是否写入
# 这样可以确保：开 → 优化，关 → 不优化（保持系统默认值）
log "[Kernel] 内核参数已移至 service.sh 处理（受 WebUI 开关控制）"

log "========== post-fs-data.sh 执行完毕 =========="