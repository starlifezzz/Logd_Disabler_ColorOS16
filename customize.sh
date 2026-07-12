#!/system/bin/sh
# ColorOS16 优化模块 - 自定义脚本
# 在模块安装时自动设置脚本执行权限

MODDIR=${0%/*}

# 为所有脚本文件添加执行权限
chmod +x "$MODDIR"/*.sh

# 确保配置文件存在
if [ ! -f "$MODDIR/system/etc/coloros16_optimize_config.yaml" ]; then
    # 如果需要复制默认配置，可以在这里添加逻辑
    echo "Default config file not found, skipping..."
fi

echo "ColorOS16 optimization module permissions set successfully"