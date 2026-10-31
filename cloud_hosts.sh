#!/system/bin/sh
# ================================================================
# 云控域名阻断 —— hosts 合并覆盖（供 post-fs-data / service / boot-completed 共用）
# ----------------------------------------------------------------
# 【为什么放在模块内】社区用户大多没装 bindhosts 之类的 hosts 模块，
#   若把域名拦截交给外部模块，等于这条能力对多数人不存在。
#   本文件让模块自带 hosts 覆盖，开箱即用。
#
# 【做法】把要拦截的域名写进 /data/adb/logd_disabler/hosts.cloud，
#   再用 bind mount 覆盖 /system/etc/hosts。
#   - 合并而非替换：先读【当前生效】的 hosts（可能已被 bindhosts 等模块挂载），
#     剥掉本模块旧标记段后再追加 → 不会丢掉用户已有的广告拦截规则。
#   - 只挂载、不改写系统分区文件：卸载挂载层即完全还原（KSU 红线允许 bind）。
#
# 【警告】被拦域名解析到 0.0.0.0 后，对应云控/场景数据拉取会失败：
#   - scene.dc / sms.ads：智能场景卡片（出行/快递/日程）可能不再刷新，
#     短信内的推广内容不再加载。其余功能不受影响。
# 【可还原】WebUI 关闭开关 → 下次开机自动卸载挂载层；
#   卸载模块 → uninstall.sh 循环卸载挂载层并删除 hosts.cloud。
# ================================================================

CLOUD_HOSTS_TAG_BEGIN='# >>> ColorOS16 云控域名（本模块添加，删除本段即还原） >>>'
CLOUD_HOSTS_TAG_END='# <<< ColorOS16 云控域名 <<<'
CLOUD_HOSTS_FILE="/data/adb/logd_disabler/hosts.cloud"

# 输出当前配置要拦截的域名（每行一个）；无输出 = 两个开关都关
# 依赖调用方已定义 is_on()
cloud_hosts_domains() {
    # ① 云控配置下发：cosa 已由 disable_gamespace 禁用，这里属"零成本"兜底
    if is_on "block_cloud_hosts"; then
        echo "icosa-service-cn-01.allawntech.com"
        echo "andesbrain-ai-cn.heytapmobi.com"
        echo "htms.heytapmobi.com"
    fi
    # ② 场景卡片与短信推广：有取舍（卡片不刷新），单独一个开关
    if is_on "block_scene_hosts"; then
        echo "scene.dc.oppomobile.com"
        echo "sms.ads.heytapmobi.com"
    fi
}

# 当前生效的 hosts 里是否有本模块标记段
cloud_hosts_active() {
    grep -qF "$CLOUD_HOSTS_TAG_BEGIN" /system/etc/hosts 2>/dev/null
}

# 合并 + bind 覆盖（幂等：内容已最新时直接跳过，不再叠加挂载层）
cloud_hosts_apply() {
    _ch_dom=$(cloud_hosts_domains)
    if [ -z "$_ch_dom" ]; then
        cloud_hosts_remove
        return 0
    fi
    mkdir -p /data/adb/logd_disabler 2>/dev/null
    if [ ! -r /system/etc/hosts ]; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ /system/etc/hosts 不可读，跳过"
        return 1
    fi
    # 剥掉本模块旧标记段（含上次挂载留下的），其余内容原样保留
    # 【为什么先写临时文件】先把"最终内容"完整算出来，才能做幂等短路与落盘方式选择
    _ch_tmp="$CLOUD_HOSTS_FILE.chk"
    sed '/^# >>> ColorOS16 云控域名/,/^# <<< ColorOS16 云控域名/d' /system/etc/hosts > "$_ch_tmp" 2>/dev/null
    if [ ! -s "$_ch_tmp" ]; then
        rm -f "$_ch_tmp" 2>/dev/null
        printf '127.0.0.1 localhost\n::1 localhost\n' > "$_ch_tmp"
    fi
    {
        echo "$CLOUD_HOSTS_TAG_BEGIN"
        for _ch_d in $_ch_dom; do echo "0.0.0.0 $_ch_d"; done
        echo "$CLOUD_HOSTS_TAG_END"
    } >> "$_ch_tmp"
    # 二次安全闸（提前到落盘之前）：合并结果必须仍带 localhost，否则拒绝挂载
    # （空 hosts 会断掉全部域名解析）
    if ! grep -q "localhost" "$_ch_tmp" 2>/dev/null; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ 合并结果异常（缺 localhost），放弃挂载"
        rm -f "$_ch_tmp" 2>/dev/null
        return 1
    fi
    # 幂等短路：挂载视图已是目标内容 → 不重复挂载
    # 【为什么需要】旧实现每次都无条件重挂，实测 /system/etc/hosts 叠到 9 层
    # （每次开机 +2 层，重启才清零）
    if cmp -s "$_ch_tmp" /system/etc/hosts 2>/dev/null; then
        rm -f "$_ch_tmp" 2>/dev/null
        command -v log >/dev/null 2>&1 && log "[CloudHosts] 内容已是最新，跳过重复挂载"
        return 0
    fi
    # 落盘：优先 mv（原子替换）；但文件一旦被 bind 引用，mv 会返回 EBUSY
    # 【实测 2026-10-31】hosts.cloud 被挂载后，toybox mv 报 "Device or resource busy"（rc=1）；
    #   旧实现用 2>/dev/null 吞掉该错误 → 剥离从未生效 → 只有 >> 追加生效 →
    #   每次 apply 追加 7 行，累积 13 段重复标记（hosts 241804 行）
    # 【兜底】原地覆盖同一 inode：挂载视图立即同步，且不触发 EBUSY
    if ! mv -f "$_ch_tmp" "$CLOUD_HOSTS_FILE" 2>/dev/null; then
        if cat "$_ch_tmp" > "$CLOUD_HOSTS_FILE" 2>/dev/null; then
            rm -f "$_ch_tmp" 2>/dev/null
        else
            command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ 写入 $CLOUD_HOSTS_FILE 失败（mv 与原地覆盖均失败）"
            rm -f "$_ch_tmp" 2>/dev/null
            return 1
        fi
    fi
    chmod 644 "$CLOUD_HOSTS_FILE" 2>/dev/null
    mount -o bind "$CLOUD_HOSTS_FILE" /system/etc/hosts 2>/dev/null \
        || mount --bind "$CLOUD_HOSTS_FILE" /system/etc/hosts 2>/dev/null
    if cloud_hosts_active; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ✅ 已生效：$(echo "$_ch_dom" | wc -l | tr -d ' ') 个域名，hosts 共 $(wc -l < /system/etc/hosts 2>/dev/null | tr -d ' ') 行"
        return 0
    fi
    command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ bind 挂载失败（/system/etc/hosts 仍为原内容）"
    return 1
}

# 卸载本模块挂载层（关闭开关 / 卸载模块时调用）
# 只卸"带本模块标记段"的顶层，别的 hosts 模块的挂载层保持不动
cloud_hosts_remove() {
    _ch_n=0
    while [ "$_ch_n" -lt 4 ] && cloud_hosts_active; do
        umount /system/etc/hosts 2>/dev/null || break
        _ch_n=$((_ch_n + 1))
    done
    if cloud_hosts_active; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ⚠️ 仍有本模块挂载层（被其它 hosts 模块压在上层），重启后自动消失"
    elif [ "$_ch_n" -gt 0 ]; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] 已卸载挂载层（$_ch_n 层），hosts 恢复原状"
    fi
    # 挂载还活着时不删源文件（bind 持有 inode，删了会留下指向已删文件的挂载）
    if ! cloud_hosts_active; then
        rm -f "$CLOUD_HOSTS_FILE" "$CLOUD_HOSTS_FILE.chk" 2>/dev/null
    fi
    return 0
}
