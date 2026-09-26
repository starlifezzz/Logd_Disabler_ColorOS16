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

# 【C 改造】时间戳改用开机秒数：
#   本阶段系统时钟尚未同步，date 返回接近 epoch 的值（实测日志首行
#   = 1971-05-28 05:00:16），导致日志里 1971/2026 乱序混排，
#   按时间排序定位故障会得出错误结论。/proc/uptime 单调递增，永远可靠。
# 【C 改造】每次开机清空重写：本文件历史价值低，清空避免无限累积。
ts() {
    printf '[+%05ss]' "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
}
log() {
    echo "$(ts) $1" >> "$LOG_FILE"
}
: > "$LOG_FILE"
log "========== post-fs-data.sh 开始执行 =========="

# ===================== Bootloop 保护 =====================
# 原理：每次开机 post-fs-data.sh 执行时计数器+1；
#       boot-completed.sh 在系统成功启动后将计数器归零；
#       若连续3次开机计数器未被归零（bootloop）→ 自动禁用模块。
BOOT_COUNT_FILE="/data/adb/coloros16_boot_count"
BOOTLOOP_FLAG="/data/adb/coloros16_bootloop_flag"
CURRENT_COUNT=$(cat "$BOOT_COUNT_FILE" 2>/dev/null || echo 0)
CURRENT_COUNT=$((CURRENT_COUNT + 1))
echo "$CURRENT_COUNT" > "$BOOT_COUNT_FILE"
log "[Bootloop] 开机计数: $CURRENT_COUNT"
if [ "$CURRENT_COUNT" -ge 3 ]; then
    log "[Bootloop] ⚠️ 连续 $CURRENT_COUNT 次未完成启动，自动禁用模块！"
    touch "$MODDIR/disable"
    echo "$CURRENT_COUNT" > "$BOOTLOOP_FLAG"
    # 紧急恢复：卸载所有 bind mount
    # 【修复】原列表只覆盖 /system/bin，漏了 /system/xbin、漏了 OTA 目录，
    #         且必然会漏掉后续新增的挂载目标 → 补全并追加新目标
    for bin in logd logcat logpersist.start logpersist.stop logtagd update_engine update_engine_client; do
        umount "/system/bin/$bin" 2>/dev/null
        umount "/system/xbin/$bin" 2>/dev/null
    done
    for apk_dir in /system/app/OTA /system/priv-app/OTA /system/app/OplusOTA /system/priv-app/OplusOTA; do
        umount "$apk_dir" 2>/dev/null
    done
    umount /odm/etc/wifi/cnss_diag.conf 2>/dev/null
    umount /odm/etc/wifi/cnss_diag_always_on.conf 2>/dev/null
    umount /mnt/vendor/persist/wlan/cnss_diag.conf 2>/dev/null
    umount /mnt/vendor/persist/wlan/cnss_diag_always_on.conf 2>/dev/null
    umount /data/vendor/wifi/logs 2>/dev/null
    umount /data/vendor/wifi/wlan_logs 2>/dev/null
    umount /data/vendor/wifi/buffered_wlan_logs 2>/dev/null
    umount /data/vendor/wifi/cnss_diag.conf 2>/dev/null
    umount /data/misc/bluetooth/logs 2>/dev/null
    log "[Bootloop] 已创建 disable 文件，下次重启模块将被禁用"
fi

# 创建 dummy 文件（用于 mount bind 覆盖二进制）
DUMMY="$WORK_DIR/dummy"
if [ ! -f "$DUMMY" ]; then
    touch "$DUMMY"
    chmod 755 "$DUMMY"
    log "创建 dummy 文件"
fi

# ===================== SELinux 规则注入 =====================
# 【关键修复】允许 late_start service 执行 pm disable-user / pm uninstall
# 注意：正确做法是使用模块自带的 sepolicy.rule 文件（KernelSU 在
#       post-fs-data 阶段自动加载，无需手动调用 ksud sepolicy）。
#       KernelSU v3.2.4 的 ksud sepolicy 子命令没有 --live 参数！
#       （CLI 只有 Patch/Apply/Check，Patch 即实时生效）
#       旧版此处写 "ksud sepolicy --live ..." 会导致参数解析失败，
#       所有规则静默注入失败 → service.sh 中 pm 全部报 "Can't find service: package"
log "[SELinux] 规则由模块 sepolicy.rule 自动注入（KernelSU 官方机制）"

# 验证 ksud 存在（仅记录，不再手动注入）
if [ -f "/data/adb/ksu/bin/ksud" ]; then
    log "[SELinux] 检测到 ksud，sepolicy.rule 将由 ksud 在 post-fs-data 自动加载"
elif [ -f "/data/adb/ksu/ksud" ]; then
    log "[SELinux] 检测到 ksud(备用路径)，sepolicy.rule 将由 ksud 在 post-fs-data 自动加载"
else
    log "[SELinux] 未找到 ksud，请确认 KernelSU 安装正常"
fi

# ===================== Logd 禁用 =====================
# 【v2.0】配置读取：优先 config.json，旧属性作为升级迁移 fallback
is_on() {
    local key="$1"
    local CONFIG_FILE="/data/adb/Logd_Disabler_ColorOS16/config.json"
    if [ -f "$CONFIG_FILE" ]; then
        grep -qE "\"${key}\"[[:space:]]*:[[:space:]]*true" "$CONFIG_FILE" 2>/dev/null && return 0
        return 1
    fi
    [ "$(getprop ${PROP_PREFIX}${key})" = "true" ] && return 0
    return 1
}

if is_on "disable_logd"; then
    log "[Logd] 开始 mount 覆盖..."
    for bin in logd logcat logpersist.start logpersist.stop logtagd; do
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
    for bin in logd logcat; do
        TARGET="/system/xbin/$bin"
        if [ -f "$TARGET" ]; then
            mount -o bind "$DUMMY" "$TARGET" 2>/dev/null
            log "  覆盖 xbin: $TARGET"
        fi
    done
    setprop logd.logpersistd "" 2>/dev/null
    setprop logd.logpersistd.enable false 2>/dev/null
    setprop persist.logd.disabled 1
    log "[Logd] mount 覆盖完成"
else
    log "[Logd] 未启用，跳过"
fi

# ===================== OTA 阻断 =====================
if is_on "block_ota"; then
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
    for apk_dir in /system/app/OTA /system/priv-app/OTA /system/app/OplusOTA /system/priv-app/OplusOTA; do
        if [ -d "$apk_dir" ]; then
            mount -o bind "$DUMMY" "$apk_dir" 2>/dev/null
            log "  覆盖 OTA 目录: $apk_dir"
        fi
    done
    rm -rf /data/data/com.oplus.ota/cache/* 2>/dev/null
    rm -rf /data/data/com.coloros.ota/cache/* 2>/dev/null
    rm -rf /data/ota_package/* 2>/dev/null
    setprop persist.sys.ota.disabled 1
    setprop persist.ota.auto_download 0
    log "[OTA] 覆盖完成"
else
    log "[OTA] 未启用，跳过"
fi

# ===================== WiFi 日志关闭（纯 bind-mount，零 pm/pkill） =====================
# 【原因】cnss_diag 按 LOG_PATH_FLAG 决定是否写日志，写入目录为
#        /data/vendor/wifi/logs/（实测当前为空），单次触发约 6×70MB。
# 【真实数据流】wifiserver(/odm/bin/init.oplus.wifi.sh L22) 每次开机把
#        /odm/etc/wifi/cnss_diag.conf  cp 到 /mnt/vendor/persist/wlan/ 同名文件，
#        两份实测 md5 完全一致 → 两个路径都是候选配置源。
# 【警告】bind 挂载后 SELinux 检查的是【源文件】上下文，必须 chcon 对齐
#        （/odm 用 vendor_configs_file，persist 用 mnt_vendor_file，均为实测值），
#        否则读方进程会被 AVC 拒 → 静默失效。
# 【回滚】uninstall.sh 与下方 else 分支均执行 umount，恢复原始 conf。
#
# ===== 首次刷入实测修正（v2.3.7）=====
# 【原假设错误】原先以为时序是 post-fs-data → on boot → class_start core → wifiserver。
# 【实测】KernelSU 在本机执行 post-fs-data.sh 是【开机 +71 秒】，
#         而 wifiserver(class core, oneshot) 在【开机 +10 秒】就已经
#         执行完 cp（/odm/bin/init.oplus.wifi.sh L22: cp /odm/... → persist/）。
#         → 我们的 bind 晚了 61 秒，cp 读到的仍是原始 /odm（=1），
#           实测 persist 副本 = LOG_PATH_FLAG = 1（挂载数=2 但副本没变）。
# 【对策】同时覆盖【/odm 源】与【persist 副本】两条路径，
#         无论 cnss_diag 读哪个都拿到 0。
# 【关键】bind 后路径的 SELinux 上下文跟【源文件】走：
#           /odm 路径        → vendor_configs_file（实测原值）
#           persist 路径     → mnt_vendor_file（实测原值）
#         同一 inode 只能有一个上下文 → 必须为 persist 单独生成一份副本再 chcon。
WIFI_CONF_A="/odm/etc/wifi/cnss_diag.conf"
WIFI_CONF_B="/odm/etc/wifi/cnss_diag_always_on.conf"
WIFI_PERSIST_A="/mnt/vendor/persist/wlan/cnss_diag.conf"
WIFI_PERSIST_B="/mnt/vendor/persist/wlan/cnss_diag_always_on.conf"
if is_on "disable_wifi_log"; then
    SRC_A="$MODDIR/cnss_diag_off.conf"
    SRC_B="$MODDIR/cnss_diag_always_on_off.conf"
    if [ ! -f "$SRC_A" ] || [ ! -f "$SRC_B" ]; then
        log "[WiFiLog] ❌ 模块内缺 conf 文件，跳过（$SRC_A / $SRC_B）"
    else
        # --- 路径 1：覆盖 /odm 源（对未来任何重新 cp 生效）---
        chcon u:object_r:vendor_configs_file:s0 "$SRC_A" "$SRC_B" 2>/dev/null
        if [ -f "$WIFI_CONF_A" ]; then
            if mount -o bind "$SRC_A" "$WIFI_CONF_A" 2>/dev/null; then
                log "  ✅ WiFi日志关闭(/odm): $WIFI_CONF_A"
            else
                log "  ❌ WiFi bind 失败: $WIFI_CONF_A"
            fi
        fi
        if [ -f "$WIFI_CONF_B" ]; then
            if mount -o bind "$SRC_B" "$WIFI_CONF_B" 2>/dev/null; then
                log "  ✅ WiFi日志关闭(/odm): $WIFI_CONF_B"
            else
                log "  ❌ WiFi bind 失败: $WIFI_CONF_B"
            fi
        fi

        # --- 路径 2：覆盖 persist 副本（cnss_diag 实际读取的那份）---
        # wifiserver 已在 +10s cp 完成，这里把结果再盖成 0。
        # 副本单独放 WORK_DIR 以便与 /odm 用的源区分 inode（不同 SELinux 上下文）。
        SRC_P_A="$WORK_DIR/cnss_diag.persist.conf"
        SRC_P_B="$WORK_DIR/cnss_diag_always_on.persist.conf"
        if cp -f "$SRC_A" "$SRC_P_A" 2>/dev/null && cp -f "$SRC_B" "$SRC_P_B" 2>/dev/null; then
            chcon u:object_r:mnt_vendor_file:s0 "$SRC_P_A" "$SRC_P_B" 2>/dev/null
            if [ -f "$WIFI_PERSIST_A" ]; then
                if mount -o bind "$SRC_P_A" "$WIFI_PERSIST_A" 2>/dev/null; then
                    log "  ✅ WiFi日志关闭(persist): $WIFI_PERSIST_A"
                else
                    log "  ❌ persist bind 失败: $WIFI_PERSIST_A"
                fi
            else
                log "  ⚠️ persist 副本不存在，跳过: $WIFI_PERSIST_A"
            fi
            if [ -f "$WIFI_PERSIST_B" ]; then
                if mount -o bind "$SRC_P_B" "$WIFI_PERSIST_B" 2>/dev/null; then
                    log "  ✅ WiFi日志关闭(persist): $WIFI_PERSIST_B"
                else
                    log "  ❌ persist bind 失败: $WIFI_PERSIST_B"
                fi
            else
                log "  ⚠️ persist 副本不存在，跳过: $WIFI_PERSIST_B"
            fi
        else
            log "  ❌ 生成 persist 副本失败，persist 路径未覆盖"
        fi

        # --- 路径 3：二进制内硬编码的 fallback 出口（纵深防御）---
        # strings /vendor/bin/cnss_diag 挖出三个备选出口：
        #   /data/vendor/wifi/cnss_diag.conf      ← -m 文件缺失时的备选配置
        #   /data/vendor/wifi/wlan_logs/          ← 硬编码默认 LOG_STORAGE_PATH
        #   /data/vendor/wifi/buffered_wlan_logs/ ← conf 内 HOST/FIRMWARE_LOG_FILE
        # 【为什么还要这层】路径 1/2 只在"配置被正确读取"时有效。
        #   若 -m 指向的 persist 文件意外缺失，cnss_diag 会回落到上面三处。
        #   这一层【不依赖配置】，纯目录级封堵 → 纵深防御。
        # 【已知放弃】/mnt/media_rw/sdcard1/wlan_logs/ 是"配置完全缺失"时的
        #   最后 fallback，挂在 FUSE/sdcard 上，overlay 风险大于收益。
        # 3a) fallback 配置：系统本无此文件，缺失则写入 LOG_PATH_FLAG=0 版本
        WIFI_FB_CONF="/data/vendor/wifi/cnss_diag.conf"
        WIFI_FB_MARKER="$WORK_DIR/.wifi_fb_conf_created"
        if [ -f "$WIFI_FB_CONF" ]; then
            if grep -qE '^LOG_PATH_FLAG[[:space:]]*=[[:space:]]*0' "$WIFI_FB_CONF" 2>/dev/null; then
                log "  ✅ fallback 配置已是 0: $WIFI_FB_CONF"
            elif mount -o bind "$SRC_A" "$WIFI_FB_CONF" 2>/dev/null; then
                log "  ✅ fallback 配置已 bind 覆盖为 0: $WIFI_FB_CONF"
            else
                log "  ⚠️ fallback 配置覆盖失败: $WIFI_FB_CONF"
            fi
        else
            if cp "$SRC_A" "$WIFI_FB_CONF" 2>/dev/null; then
                # 属主对齐父目录 /data/vendor/wifi(1010) 与运行者 cnss_diag(uid 1000, system)
                chown 1000:1010 "$WIFI_FB_CONF" 2>/dev/null
                chmod 666 "$WIFI_FB_CONF" 2>/dev/null
                touch "$WIFI_FB_MARKER" 2>/dev/null
                log "  ✅ fallback 配置已创建(LOG_PATH_FLAG=0): $WIFI_FB_CONF"
            else
                log "  ⚠️ fallback 配置创建失败: $WIFI_FB_CONF"
            fi
        fi

        # 3b) 三个写入目录 → tmpfs（写入成功不报错，但零落盘、重启即清）
        # 属主/上下文均按实测 file_contexts 对齐：
        #   /data/vendor/wifi/logs      = 770 1000:1000, vendor_wifi_vendor_data_file
        #   /data/vendor/wifi/wlan_logs = 专属类型 vendor_wifi_vendor_log_data_file
        for entry in \
            "/data/vendor/wifi/logs:vendor_wifi_vendor_data_file" \
            "/data/vendor/wifi/wlan_logs:vendor_wifi_vendor_log_data_file" \
            "/data/vendor/wifi/buffered_wlan_logs:vendor_wifi_vendor_data_file"; do
            _dir="${entry%%:*}"
            _ctx="${entry##*:}"
            # 【回收凭证】只记录【本模块亲手创建】的目录。
            #   原生就存在的（如 /data/vendor/wifi/logs）永不记录 → 永不被回收。
            #   [ ! -d ] 守卫天然去重：创建后下次开机不再追加。
            if [ ! -d "$_dir" ]; then
                mkdir -p "$_dir" 2>/dev/null
                echo "$_dir" >> "$WORK_DIR/.wifi_dirs_created" 2>/dev/null
            fi
            # 先给【底层真实目录】设好属主与上下文：umount 后它会重新露出
            chown 1000:1010 "$_dir" 2>/dev/null
            chmod 770 "$_dir" 2>/dev/null
            chcon "u:object_r:${_ctx}:s0" "$_dir" 2>/dev/null
            if mount -t tmpfs -o "size=64m,uid=1000,gid=1000,mode=770" tmpfs "$_dir" 2>/dev/null; then
                # tmpfs 新根 inode 上下文也会被重置，需再对齐一次
                chcon "u:object_r:${_ctx}:s0" "$_dir" 2>/dev/null
                log "  ✅ 写入目录已 tmpfs 化: $_dir"
            else
                log "  ⚠️ tmpfs 挂载失败: $_dir"
            fi
        done
    fi
else
    umount "$WIFI_CONF_A" 2>/dev/null
    umount "$WIFI_CONF_B" 2>/dev/null
    umount "$WIFI_PERSIST_A" 2>/dev/null
    umount "$WIFI_PERSIST_B" 2>/dev/null
    umount /data/vendor/wifi/logs 2>/dev/null
    umount /data/vendor/wifi/wlan_logs 2>/dev/null
    umount /data/vendor/wifi/buffered_wlan_logs 2>/dev/null
    umount /data/vendor/wifi/cnss_diag.conf 2>/dev/null
    # 【警告】只删除【本模块创建】的 fallback 配置，绝不误删系统原生文件
    if [ -f "$WORK_DIR/.wifi_fb_conf_created" ]; then
        rm -f /data/vendor/wifi/cnss_diag.conf 2>/dev/null
        rm -f "$WORK_DIR/.wifi_fb_conf_created" 2>/dev/null
        log "[WiFiLog] 已移除本模块创建的 fallback 配置"
    fi
    # 【警告】回收本模块创建的写入目录。用 rmdir 而非 rm -rf：
    #   非空说明系统已在使用，一律保留不删。
    if [ -f "$WORK_DIR/.wifi_dirs_created" ]; then
        while IFS= read -r _d; do
            [ -n "$_d" ] && rmdir "$_d" 2>/dev/null
        done < "$WORK_DIR/.wifi_dirs_created"
        rm -f "$WORK_DIR/.wifi_dirs_created" 2>/dev/null
        log "[WiFiLog] 已回收本模块创建的写入目录（仅空目录）"
    else
        # 【兼容 ≤v2.3.6】那两个目录由旧版创建，当时还没有 marker 机制。
        # 只回退这两个实测确认模块新建的路径；/data/vendor/wifi/logs 是系统原生目录，
        # 任何情况下都不碰。仍只用 rmdir（空才删），非空即保留。
        rmdir /data/vendor/wifi/wlan_logs 2>/dev/null
        rmdir /data/vendor/wifi/buffered_wlan_logs 2>/dev/null
        log "[WiFiLog] 已回收兼容目录（仅空目录）"
    fi
    log "[WiFiLog] 未启用，跳过"
fi

# ===================== 蓝牙日志关闭（tmpfs overlay，零 pm/pkill） =====================
# 【原因】com.android.bluetooth 持续写 /data/misc/bluetooth/logs/，
#        实测 50MB / 3 文件（封顶 10 文件 ≈141MB），≈16MB/h，持续增长。
#        属性开关全空或无效（实测 persist.sys.oplus.bt.log_off_bt=true 仍写；
#        bluetoothlog_manager.sh 是空壳 stub）。
#        → 用 tmpfs overlay：BT stack 写入成功不报错，但零落盘、重启即消失。
# 【不删已有日志】磁盘上原有文件保留，仅被 tmpfs 遮蔽；
#        卸载模块 umount 后原文件自然恢复可见。
# 【警告】tmpfs 挂载后新根 inode 默认 root:root 0755，bluetooth 进程进不去
#        → 必须在 mount 参数里直接指定 uid/gid/mode（实测 bluetooth = 1002:1002，
#        原目录 stat = 770 1002:1002）。
# 【警告】挂载后必须对齐 SELinux 上下文。实测真实类型是
#        u:object_r:bluetooth_logs_data_file:s0（【带 _logs】，
#        不是 bluetooth_data_file），用错类型 bluetooth 域写入会被 AVC 拒。
# 【回滚】uninstall.sh 与下方 else 分支均执行 umount。
BTLOG="/data/misc/bluetooth/logs"
if is_on "disable_bluetooth_log"; then
    mkdir -p "$BTLOG" 2>/dev/null
    if mount -t tmpfs -o "size=128m,uid=1002,gid=1002,mode=770" tmpfs "$BTLOG" 2>/dev/null; then
        chcon -R u:object_r:bluetooth_logs_data_file:s0 "$BTLOG" 2>/dev/null
        log "  ✅ 蓝牙日志已 overlay 为 tmpfs: $BTLOG"
    else
        log "  ❌ tmpfs 挂载失败: $BTLOG"
    fi
else
    umount "$BTLOG" 2>/dev/null
    log "[BtLog] 未启用，跳过"
fi

# ===================== 挂载自检（模块自己记录，不依赖外部手动验证） =====================
# 说明：这些都是【只读】观察（grep /proc/mounts、读文件、ls -Z），
#       不产生任何副作用。结果写入本日志 + service.sh 开机复核。
log "[自检][WiFi] /proc/mounts 中 cnss_diag 挂载数: $(grep -c cnss_diag /proc/mounts 2>/dev/null || true) (期望 4 = /odm 2 条 + persist 2 条)"
log "[自检][WiFi] /odm 源 LOG_PATH_FLAG: $(grep -E 'LOG_PATH_FLAG' "$WIFI_CONF_A" 2>/dev/null | tr -d '\r') (期望 = 0)"
log "[自检][WiFi] persist 副本 LOG_PATH_FLAG: $(grep -E 'LOG_PATH_FLAG' "$WIFI_PERSIST_A" 2>/dev/null | tr -d '\r') (期望 = 0，wifiserver 在 +10s 已 cp 完，此处应为覆盖后结果)"
log "[自检][WiFi] 源A SELinux 上下文: $(ls -Z "$WIFI_CONF_A" 2>/dev/null || echo 读取失败)"
FB_VAL=$(grep -E 'LOG_PATH_FLAG' /data/vendor/wifi/cnss_diag.conf 2>/dev/null | tr -d '\r')
log "[自检][WiFi] 路径3 fallback 配置 /data/vendor/wifi/cnss_diag.conf: ${FB_VAL:-未创建（系统本无此文件）}"
log "[自检][WiFi] 写入目录 tmpfs 化: logs=$(grep -c ' /data/vendor/wifi/logs ' /proc/mounts 2>/dev/null || true) wlan_logs=$(grep -c ' /data/vendor/wifi/wlan_logs ' /proc/mounts 2>/dev/null || true) buffered=$(grep -c ' /data/vendor/wifi/buffered_wlan_logs ' /proc/mounts 2>/dev/null || true) (期望 1/1/1 = 写入只进内存)"
log "[自检][WiFi] 写入目录 /data/vendor/wifi/logs 文件数(tmpfs 内): $(ls -A /data/vendor/wifi/logs 2>/dev/null | wc -l)"
log "[自检][WiFi] 启动状态 wifidriverlog_on=[$(getprop init.svc.wifidriverlog_on 2>/dev/null)] always_on=[$(getprop init.svc.wifidriverlog_always_on 2>/dev/null)] (期望 空或 stopped，绝不能是 running。注：空 = init.svc 属性尚未创建，该 service 从未被 start/stop 引用过，不代表未注册)"
log "[自检][WiFi] 触发条件 qms_setting=$(getprop persist.sys.oplus.wifi.qms_setting 2>/dev/null) assert_panic=$(getprop persist.sys.assert.panic 2>/dev/null) firmware_log=$(getprop sys.oplus.wifi.connect.firmware_log 2>/dev/null) (期望 0/0/空 = 未触发)"
log "[自检][BtLog] /proc/mounts 中 bluetooth/logs 挂载数: $(grep -c 'bluetooth/logs' /proc/mounts 2>/dev/null || true) (期望 1)"
log "[自检][BtLog] 目录上下文: $(ls -Zd "$BTLOG" 2>/dev/null || echo 读取失败)"
log "[自检][BtLog] 目录属主权限: $(stat -c '%a %u:%g' "$BTLOG" 2>/dev/null || echo 读取失败)"
log "[自检][BtLog] tmpfs 内文件数: $(ls -A "$BTLOG" 2>/dev/null | wc -l) （>0 属正常：BT 在 tmpfs 内新建文件，磁盘旧日志已被遮蔽）"

log "[Kernel] 内核参数已移至 service.sh 处理（受 WebUI 开关控制）"
log "========== post-fs-data.sh 执行完毕 =========="
