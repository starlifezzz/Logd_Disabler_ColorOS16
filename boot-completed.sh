#!/system/bin/sh
MODDIR=${0%/*}

# 系统完全启动，证明没有发生 Bootloop，重置计数器
echo "0" > /data/adb/coloros16_boot_count
rm -f /data/adb/coloros16_safemode_flag
rm -f /data/adb/coloros16_bootloop_flag

# 健康校验：检查核心系统服务
sleep 10 # 等待系统完全稳定
if ! pidof system_server >/dev/null 2>&1; then
    echo "[HealthCheck] 严重错误：system_server 未运行！正在紧急回滚..." > "$MODDIR/health_error.log"
    umount /system/bin/logd 2>/dev/null
    # 重新启用被禁用的包
    pm enable com.oplus.ota 2>/dev/null
fi          