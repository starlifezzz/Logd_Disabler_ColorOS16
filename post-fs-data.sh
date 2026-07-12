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
                # 备用方案：直接清空文件内容（如果 /system 可写）
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

# ===================== 内核参数优化 =====================
# post-fs-data 阶段写入内核参数（此时不会被系统服务覆盖）

# 内存/IO 优化（始终执行）
log "[Kernel] 写入内核参数..."

# sched_schedstats: 关闭调度统计，减少内核开销
echo 0 > /proc/sys/kernel/sched_schedstats 2>/dev/null
log "  sched_schedstats=$(cat /proc/sys/kernel/sched_schedstats 2>/dev/null)"

# binder debug_mask: 关闭 binder 调试
echo 0 > /sys/module/binder/parameters/debug_mask 2>/dev/null
log "  binder debug_mask=$(cat /sys/module/binder/parameters/debug_mask 2>/dev/null)"

# compact_unevictable_allowed: 禁止压缩不可回收页
echo 0 > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
log "  compact_unevictable=$(cat /proc/sys/vm/compact_unevictable_allowed 2>/dev/null)"

# printk: 强制写入，多次写入确保第一个值也生效
echo "3 3 3 3" > /proc/sys/kernel/printk 2>/dev/null
# 单独写 console_loglevel（第一个值）
echo 3 > /proc/sys/kernel/printk_console_loglevel 2>/dev/null
# 通过 sysctl 方式再写一次
setprop persist.sys.kernel.printk "3 3 3 3" 2>/dev/null
# 最终验证
CURRENT_PRINTK=$(cat /proc/sys/kernel/printk 2>/dev/null)
log "  printk=$CURRENT_PRINTK"

# 透明大页: 禁用（某些内核需要写多次或用不同路径）
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null
# 备用路径（某些 ColorOS 内核用这个）
echo never > /sys/kernel/mm/transparent_hugepage/khugepaged/defrag 2>/dev/null
# 通过内核 cmdline 属性备份
setprop persist.sys.thp.enabled never 2>/dev/null
CURRENT_THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)
log "  thp=$CURRENT_THP"

# swappiness
echo 30 > /proc/sys/vm/swappiness 2>/dev/null
log "  swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)"

# dirty ratio
echo 10 > /proc/sys/vm/dirty_ratio 2>/dev/null
echo 5 > /proc/sys/vm/dirty_background_ratio 2>/dev/null
log "  dirty_ratio=$(cat /proc/sys/vm/dirty_ratio 2>/dev/null)"

# vfs_cache_pressure
echo 50 > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
log "  vfs_cache_pressure=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)"

# IO 调度器
for queue in /sys/block/sd*/queue/scheduler /sys/block/ufs*/queue/scheduler /sys/block/dm-*/queue/scheduler; do
    if [ -f "$queue" ]; then
        if grep -q "mq-deadline" "$queue" 2>/dev/null; then
            echo "mq-deadline" > "$queue" 2>/dev/null
        elif grep -q "none" "$queue" 2>/dev/null; then
            echo "none" > "$queue" 2>/dev/null
        fi
    fi
done
log "  IO scheduler done"

log "========== post-fs-data.sh 执行完毕 =========="