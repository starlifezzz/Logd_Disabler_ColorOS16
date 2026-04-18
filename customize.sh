#!/system/bin/sh
# KernelSU customize.sh - 必需的模块入口文件
# 此脚本在模块安装时执行，用于提取webroot目录

MODDIR=${0%/*}

# 提取Web UI文件
unzip -o "$ZIPFILE" 'webroot/*' -d "$MODDIR" >&2

# 设置Web UI文件权限
chmod 644 "$MODDIR/webroot/index.html"
chmod 644 "$MODDIR/webroot/assets/style.css"
chmod 644 "$MODDIR/webroot/assets/script.js"