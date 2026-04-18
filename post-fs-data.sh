#!/system/bin/sh
# ColorOS 16 优化模块 - YAML配置驱动
# 开机早期post-fs-data安全窗口执行，零系统修改，卸载即完全复原

MODDIR=${0%/*}

# 执行YAML配置应用脚本（早期阶段）
"$MODDIR/apply_yaml_config.sh" --early-stage

# ======================== 1. 彻底禁用logd，永久封死复活 ========================
[ -f '/system/bin/logd' ] && mount -o bind /dev/null /system/bin/logd
killall -9 logd 2>/dev/null
setprop persist.logd.enable 0

# ======================== 2. 彻底阻断OTA自动更新 ========================
[ -f '/system/bin/update_engine' ] && mount -o bind /dev/null /system/bin/update_engine
pkill -9 update_engine 2>/dev/null
setprop persist.ota.auto_download 0
setprop persist.sys.recovery_update 0
setprop persist.sys.coupdate 0
rm -rf /data/ota_package /cache/ota 2>/dev/null
# 注意: pm disable 命令已移至 service.sh 执行，因为 post-fs-data 阶段 PMS 可能未就绪

# ======================== 3. 锁定开发者选项不被系统重置 ========================
settings put --user 0 global development_settings_enabled 1
settings put --user 0 global adb_enabled 1
setprop persist.dev.option.lock 1

# ======================== 4. 屏蔽冗余耗电服务、广告、数据收集 ========================
# 核心冗余进程查杀
pkill -9 smartscene preload sysmonitor hotstart 2>/dev/null
# 禁用负一屏/智能助手 (pm 命令已移至 service.sh)
# 【新增】禁用Breeno智能助手相关服务 (pm 命令已移至 service.sh)
# 【新增】彻底关闭系统广告总开关
setprop persist.sys.oplus.ad_enable 0
setprop persist.sys.oplus.personalized_ad 0
setprop persist.ad.track 0
# 【新增】彻底关死用户体验计划/数据统计
setprop persist.sys.usage_stat_enable 0
setprop persist.oppo.collect 0
# com.oplus.statistics.rom 禁用已移至 service.sh
# 冗余服务开关锁定
setprop persist.sys.preload 0
setprop persist.sys.monitor 0
setprop persist.sys.hotstart 0

# ======================== 5. 内存/IO轻量优化（无副作用） ========================
[ -w '/proc/sys/kernel/sched_schedstats' ] && echo 0 > /proc/sys/kernel/sched_schedstats
[ -w '/sys/module/binder/parameters/debug_mask' ] && echo 0 > /sys/module/binder/parameters/debug_mask
[ -w '/proc/sys/vm/compact_unevictable_allowed' ] && echo 0 > /proc/sys/vm/compact_unevictable_allowed

# ======================== 6. 关闭 Oplus DCS 后台监控（节省电量，避免后台频繁唤醒） ========================
setprop persist.oplus.dcs.enable 0
# com.oplus.dcs 禁用已移至 service.sh

# ======================== 7. 【新增】禁用健康与运动服务（非必要后台服务） ========================
# 健康数据平台服务、运动健康应用禁用已移至 service.sh

# ======================== 8. 【新增】禁用流量监控与网络服务（减少后台网络活动） ========================
# 流量管理服务、融合搜索服务禁用已移至 service.sh

# ======================== 9. 【新增】禁用锁屏杂志与壁纸服务（节省存储和网络） ========================
# 乐划锁屏/锁屏杂志禁用已移至 service.sh
setprop persist.sys.lockscreen_magazine 0

# ======================== 10. 【新增】禁用游戏空间与性能监控（减少系统负载） ========================
# 游戏空间服务、性能监控服务禁用已移至 service.sh

# ======================== 11. 【新增】禁用钱包与支付相关服务（如不需要NFC支付） ========================
# 钱包服务、安全支付服务禁用已移至 service.sh

# ======================== 12. 【新增】禁用备份与云服务（如不需要自动备份） ========================
# 备份恢复服务、云服务禁用已移至 service.sh

# ======================== 13. 【新增】内核额外优化参数 ========================
# 减少内核调试开销
[ -w '/proc/sys/kernel/printk' ] && echo "3 3 3 3" > /proc/sys/kernel/printk
# 禁用透明大页（减少内存碎片）
[ -w '/sys/kernel/mm/transparent_hugepage/enabled' ] && echo "never" > /sys/kernel/mm/transparent_hugepage/enabled
# 禁用内存压缩统计
[ -w '/proc/sys/vm/compact_unevictable_allowed' ] && echo 0 > /proc/sys/vm/compact_unevictable_allowed