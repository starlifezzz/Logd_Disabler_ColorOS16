#!/system/bin/sh
# ColorOS 16 优化模块 - 系统启动完成脚本
# 在BOOT_COMPLETED广播后执行

MODDIR=${0%/*}

# 最终应用配置，确保所有优化都已生效
"$MODDIR/apply_yaml_config.sh"