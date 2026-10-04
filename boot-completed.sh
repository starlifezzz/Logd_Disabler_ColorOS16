#!/system/bin/sh
MODDIR=${0%/*}

# 系统完全启动，证明没有发生 Bootloop，重置计数器
BOOT_COUNT_FILE="/data/adb/coloros16_boot_count"
BOOTLOOP_FLAG="/data/adb/coloros16_bootloop_flag"
echo "0" > "$BOOT_COUNT_FILE"
# 【修复 2026-10-03】disable 标记只在 bootloop 自动禁用时恢复，禁止无条件自删：
#   flag 由 post-fs-data 计数≥3 时与 disable 同时创建 → 启动成功即两者一起恢复（保留原自动治愈语义）；
#   手动 touch disable（实验布防/人工停用）不带 flag → 必须保留。
#   教训：原无条件 rm -f "$MODDIR/disable" 会把手动布防标记在开机后抹掉 → 模块照跑（A/B 实验第一轮实锤）。
if [ -f "$BOOTLOOP_FLAG" ]; then
    rm -f "$BOOTLOOP_FLAG"
    rm -f "$MODDIR/disable"
fi

# 健康校验：检查核心系统服务
sleep 10 # 等待系统完全稳定
if ! pidof system_server >/dev/null 2>&1; then
    echo "[HealthCheck] 严重错误：system_server 未运行！正在紧急回滚..." > "$MODDIR/health_error.log"
    umount /system/bin/logd 2>/dev/null
    # 重新启用被禁用的包（走 su 提升，与 service.sh 保持一致）
    if command -v su >/dev/null 2>&1 && su -c "id" 2>&1 | grep -qE "uid=0|root"; then
        su -c "pm enable com.oplus.ota" 2>/dev/null
        su -c "pm enable com.oplus.sau" 2>/dev/null
        su -c "pm enable com.oplus.cota" 2>/dev/null
        su -c "pm enable com.oplus.romupdate" 2>/dev/null
        su -c "pm enable com.oplus.upgradeguide" 2>/dev/null
    else
        pm enable com.oplus.ota 2>/dev/null
        pm enable com.oplus.sau 2>/dev/null
        pm enable com.oplus.cota 2>/dev/null
        pm enable com.oplus.romupdate 2>/dev/null
        pm enable com.oplus.upgradeguide 2>/dev/null
    fi
    start logd 2>/dev/null
    start update_engine 2>/dev/null
fi
