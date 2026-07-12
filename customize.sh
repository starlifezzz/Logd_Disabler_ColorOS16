#!/system/bin/sh
SKIPUNZIP=1

ui_print "- 正在解压模块文件..."
unzip -o "$ZIPFILE" -x 'META-INF/*' -d "$MODPATH" >&2

ui_print "- 设置脚本执行权限..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/boot-completed.sh" 0 0 0755
set_perm "$MODPATH/get_status_json.sh" 0 0 0755

ui_print "- 检测系统环境..."
if ! grep -qE "ColorOS|oplus|OnePlus" /system/build.prop /system_ext/build.prop /vendor/build.prop 2>/dev/null; then
    abort "❌ 错误：此模块仅适用于 ColorOS / OnePlus (OPPO) 设备！"
fi

ui_print "✅ 安装完成！重启后请在 KernelSU 管理器中打开 WebUI 进行配置。"