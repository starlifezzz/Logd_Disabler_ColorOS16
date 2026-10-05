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

# ===================== 去温控·boot_completed 补刀（⚠️ 高风险 · 可还原） =====================
# 【实测 2026-10-05】service.sh 8c 开机禁 31 zone → 温控栈在 boot_completed 窗口把
#   19 个 CPU zone 一次性回写 enabled（31→12）；此后补禁稳定 120 秒以上 → 该回写是
#   开机一次性事件，非持续对抗。本节（自带 sleep 20）天然晚于 8c 与 boot_completed
#   触发，专治该窗口；白名单与 8c / uninstall 4b 完全同源。
# 【警告】⚠️ 高风险：解除温控后机身与电池持续高温（电池/充电安全保护仍保留）。
# 【回滚】WebUI 关闭本项重启即恢复；卸载模块由 uninstall.sh 4b 节立即回滚。
if grep -q '"disable_thermal_control": *true' "/data/adb/Logd_Disabler_ColorOS16/config.json" 2>/dev/null; then
    sleep 20
    _zn=0
    for z in /sys/class/thermal/thermal_zone*; do
        _t=$(cat "$z/type" 2>/dev/null) || continue
        case "$_t" in
            cpu-*|cpuss-*|gpuss-*|shell_front|shell_frame|shell_back|skin-msm-therm)
                echo disabled > "$z/mode" 2>/dev/null && _zn=$((_zn+1)) ;;
        esac
    done
    _cn=0
    for c in /sys/class/thermal/cooling_device*; do
        _t=$(cat "$c/type" 2>/dev/null) || continue
        case "$_t" in
            cpufreq-*|cpu-cluster*|cpu-hotplug*|pause-cpu*|thermal-pause-*|thermal-cluster-*|gpu|gpu-dump-skip-cdev|devfreq-*|panel0-backlight|display-fps|ddr-cdev)
                echo 0 > "$c/cur_state" 2>/dev/null && _cn=$((_cn+1)) ;;
        esac
    done
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [Thermal] boot_completed 补刀 zone=$_zn cooling=$_cn" >> /data/adb/logd_disabler/service.log
fi
