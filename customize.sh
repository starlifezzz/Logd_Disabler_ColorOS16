#!/system/bin/sh
# ============================================================
# Logd_Disabler_ColorOS16 安装脚本（customize.sh）
# - 解压模块文件、设权限、检测 ColorOS/OnePlus 环境
# - v2.0：预创建 config.json 数据目录（模块外，升级不覆盖）
# ============================================================
SKIPUNZIP=1

ui_print "- 正在解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

ui_print "- 设置脚本执行权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/boot-completed.sh" 0 0 0755
set_perm "$MODPATH/verify_status.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

ui_print "- 检测系统环境..."
if ! grep -qE "ColorOS|oplus|OnePlus" /system/build.prop /system_ext/build.prop /vendor/build.prop 2>/dev/null; then
    abort "❌ 错误：此模块仅适用于 ColorOS / OnePlus (OPPO) 设备！"
fi

# ============================================================
# 【v2.0】config.json 数据目录初始化
# 路径：/data/adb/Logd_Disabler_ColorOS16/config.json（模块外）
# 注意：这里【不】主动生成 config.json！
#   - 老用户升级：config.json 不存在但旧 persist 属性有值
#     → 交给 service.sh 首启时一次性迁移，避免配置丢失。
#   - 新用户首装：属性为空 → service.sh 兜底生成全 false。
# 本段仅预创建目录，保证 WebUI/脚本有可写位置。
# ============================================================
CONFIG_DIR="/data/adb/Logd_Disabler_ColorOS16"
mkdir -p "$CONFIG_DIR"
chmod 0755 "$CONFIG_DIR"
# 若目录本身无归属（极少数场景），避免覆盖已存在配置
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    ui_print "- 已预创建配置目录：$CONFIG_DIR"
    ui_print "  （config.json 将在首次开机由 service.sh 自动生成）"
fi

ui_print "✅ 安装完成！重启后请在 KernelSU 管理器中打开 WebUI 进行配置。"
