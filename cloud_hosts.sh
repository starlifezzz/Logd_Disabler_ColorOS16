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
# 【为什么还要一个私有副本】实测 bindhosts 会把【它自己的】hosts bind 到本模块的
#   hosts.cloud 路径上（mountinfo 实锤，2026-11-01）：
#       /adb/modules/bindhosts/system/etc/hosts  →  /data/adb/logd_disabler/hosts.cloud
#   于是「写 hosts.cloud」实际是写进 bindhosts 的文件；而 bindhosts 每天 10:00 的 cron
#   会重新生成它自己的 hosts → 本模块标记段被整段抹掉 → 域名拦截静默失效。
#   实测：11-01 10:00:03 文件被重写（尾部出现 "# bindhosts v215"），标记段 1 → 0，
#         sms.ads.heytapmobi.com 恢复解析到真实 IP 111.206.136.11。
#   私有副本只被本模块写入，不会被对方重写；检测到覆盖时自动切过来。
CLOUD_HOSTS_OWN_FILE="$CLOUD_HOSTS_FILE.own"

# 判断路径是否被别的模块 bind 覆盖（此时写它 = 写别人的文件）
# 【判据】/proc/self/mountinfo 第 5 字段是挂载点，命中即被覆盖
# 【为什么不比 inode】inode 相同也可能来自 bind（nlink 仍为 1），比挂载表更直接
cloud_hosts_shadowed() {
    [ -r /proc/self/mountinfo ] || return 1
    awk -v p="$1" '$5 == p { f=1 } END { exit(f ? 0 : 1) }' /proc/self/mountinfo 2>/dev/null
}

# 卸掉「别人挂在本模块路径上的影子层」
# 【为什么必须卸】实测存在挂载传播（shared peer group）：一旦 hosts.cloud 上被挂了
#   一个 /system/etc/hosts 的 bind，两者就成为 peer —— 此后任一侧的新挂载都会复制到
#   另一侧。后果：我们写自己的文件 = 写 bindhosts 的文件，而 bindhosts 每天 10:00 的
#   cron 会重写它的文件 → 本模块标记段被抹掉 → 域名拦截静默失效。
#   实测（2026-11-01）：挂载 .own 后 inode 扩散到 hosts.cloud 与 bindhosts 路径
#   （三处同为 1358455），随后 cron 一跑三处标记段全没。
#   卸掉影子层后探针不再传播到 bindhosts 路径 → 断开链路。
# 【安全性】卸的只是「挂在我们路径上的 bind」，露出的是我们自己的真实文件，内容不变；
#   不影响 /system/etc/hosts 的现有层，也不动对方文件。
cloud_hosts_unshadow() {
    _cu_n=0
    while [ "$_cu_n" -lt 4 ] && cloud_hosts_shadowed "$CLOUD_HOSTS_FILE"; do
        umount "$CLOUD_HOSTS_FILE" 2>/dev/null || break
        _cu_n=$((_cu_n + 1))
    done
    if [ "$_cu_n" -gt 0 ]; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] 已卸掉 $CLOUD_HOSTS_FILE 上的影子挂载层（$_cu_n 层）——断开挂载传播，恢复本模块自有文件"
    fi
    return 0
}

# 清理「根已失效」的挂载层（mountinfo 里 root 以 "//deleted" 结尾）
# 【来历】旧实现用 mv 替换源文件，被 bind 引用的旧 inode 变成 deleted，
#   挂载根的路径随之变成 "...//deleted"。此后任何一次 bind 挂载都会因
#   传播目标不存在而报 ENOENT（实测 2026-11-01，mount 明明源和目标都在却失败）。
# 【安全性】只卸 root 带 //deleted 的层；正常层（对方模块的 hosts）不动。
cloud_hosts_drop_stale() {
    _cs_n=0
    while [ "$_cs_n" -lt 4 ]; do
        awk '$5 == "/system/etc/hosts" && $4 ~ /\/\/deleted$/ { f=1 } END { exit(f ? 0 : 1) }' \
            /proc/self/mountinfo 2>/dev/null || break
        umount /system/etc/hosts 2>/dev/null || break
        _cs_n=$((_cs_n + 1))
    done
    if [ "$_cs_n" -gt 0 ]; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] 已清理 $_cs_n 层失效挂载（root 指向已删除文件，会导致后续挂载 ENOENT）"
    fi
    return 0
}

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
    # 【顺序关键：先读后断】必须先从【当前生效】的 /system/etc/hosts 算出合并结果，
    #   再卸影子层。反过来会踩坑：umount 在 shared peer group 里会传播，
    #   卸 hosts.cloud 的影子层会连带把 /system/etc/hosts 上的 bindhosts 层一起带走
    #   （实测 2026-11-01：先卸后读 → 只读到本模块自己的 341 字节旧文件，
    #    bindhosts 的 241727 行广告拦截基线被整份丢弃）。
    #   先读 = 把用户既有规则完整抄进合并结果，再断开传播，两边都不丢。
    _ch_tmp="$CLOUD_HOSTS_FILE.chk"
    # 剥掉本模块旧标记段（含上次挂载留下的），其余内容原样保留
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
    # 【断传播】影子层在位时，写我们的文件等于写对方的文件 → 读完之后再卸掉
    cloud_hosts_unshadow
    # 清掉「根已失效」的挂载层，否则后面的 bind 会报 ENOENT
    cloud_hosts_drop_stale
    # 【选落盘目标】仍被覆盖（卸不掉）时改用私有副本 —— 绝不写别人的文件
    _ch_file="$CLOUD_HOSTS_FILE"
    if cloud_hosts_shadowed "$_ch_file"; then
        _ch_file="$CLOUD_HOSTS_OWN_FILE"
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ⚠️ $CLOUD_HOSTS_FILE 仍被其它 hosts 模块 bind 覆盖（影子层卸不掉）→ 改用私有副本 hosts.cloud.own"
    fi
    # 幂等短路：生效层就是我们的文件、且内容一致 → 不重复挂载
    # 【为什么需要】旧实现每次都无条件重挂，实测 /system/etc/hosts 叠到 9 层
    # （每次开机 +2 层，重启才清零）
    # 【为什么还要比 inode】只比内容会漏掉「内容恰好相同、但生效层是别人的文件」：
    #   实测 2026-11-01 开机，bindhosts 的 hosts 恰好带着本模块上次写进去的标记段，
    #   内容比对相等 → 短路跳过 → 私有副本从未创建 → 对方 10:00 重写后照样失效。
    #   比 inode 才能确认"看得见的内容确实来自我们自己的文件"。
    _ch_top=$(stat -c%i /system/etc/hosts 2>/dev/null)
    _ch_own=$(stat -c%i "$_ch_file" 2>/dev/null)
    if [ -n "$_ch_top" ] && [ "$_ch_top" = "$_ch_own" ] && cmp -s "$_ch_tmp" /system/etc/hosts 2>/dev/null; then
        rm -f "$_ch_tmp" 2>/dev/null
        command -v log >/dev/null 2>&1 && log "[CloudHosts] 内容已是最新，跳过重复挂载"
        return 0
    fi
    # 落盘：一律原地覆盖，绝不用 mv
    # 【为什么不能 mv】mv 是「建新 inode + 改名」，而 hosts.cloud 可能已被 bind 引用；
    #   改名后旧挂载的 root 变成 "...//deleted"（mountinfo 实锤 2026-11-01），
    #   之后任何一次 bind 挂载都会因传播目标不存在而报 ENOENT（"No such file or directory"）。
    #   原地覆盖保持 inode 不变：挂载视图立即同步，也不产生 deleted 根。
    # 【历史】旧实现 mv 遇 EBUSY 才回退 cat；但 unshadow 之后 mv 会成功 → 正是踩坑路径。
    if ! cat "$_ch_tmp" > "$_ch_file" 2>/dev/null; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ 写入 $_ch_file 失败（原地覆盖失败）"
        rm -f "$_ch_tmp" 2>/dev/null
        return 1
    fi
    rm -f "$_ch_tmp" 2>/dev/null
    chmod 644 "$_ch_file" 2>/dev/null
    # 【必须改 SELinux 标签】/data/adb 下的文件默认是 adb_data_file，普通 app 读不了
    #   → 整个 hosts 被忽略：文件内容完全正确，域名却照常解析到真实 IP（2026-11-01 实锤）。
    #   KernelSU 会自动给 modules/*/system/** 打 system_file，但本模块的
    #   /data/adb/logd_disabler/ 不在其列，必须手动 chcon。
    #   实测：chcon 后同一文件立即生效（sms.ads.heytapmobi.com → 127.0.0.1）。
    chcon u:object_r:system_file:s0 "$_ch_file" 2>/dev/null
    # 回读校验：确认内容真的落到了我们选定的文件
    # 【为什么需要】若路径仍被别的模块覆盖，写入会静默落到对方文件里，
    #   表面"已生效"、对方一重写就消失。这里直接回读，读不到就拒绝挂载。
    if ! grep -qF "$CLOUD_HOSTS_TAG_BEGIN" "$_ch_file" 2>/dev/null; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ 写入后回读不到标记段（$_ch_file），放弃挂载"
        rm -f "$_ch_tmp" 2>/dev/null
        return 1
    fi
    # 标签校验：不是 system_file 就等于白挂（app 读不到，解析照旧走 DNS）
    _ch_ctx=$(ls -lZ "$_ch_file" 2>/dev/null | awk '{print $5}')
    case "$_ch_ctx" in
        *system_file*|*"u:object_r:system_file"*) : ;;
        *)
            command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ $_ch_file 的 SELinux 标签是 [$_ch_ctx]（期望 system_file），app 读不到 → 放弃挂载"
            rm -f "$_ch_tmp" 2>/dev/null
            return 1
            ;;
    esac
    mount -o bind "$_ch_file" /system/etc/hosts 2>/dev/null \
        || mount --bind "$_ch_file" /system/etc/hosts 2>/dev/null
    # 生效判定：必须「生效层 inode == 源文件 inode」且标记段在位
    # 【为什么不只看标记段】旧内容也可能带着上次留下的标记段 → 挂载其实没成功却判成功
    #   （实测 2026-11-01：mv 换掉 inode 后 mount 报 ENOENT，但末尾只查标记段 → 假绿）
    _ch_top=$(stat -c%i /system/etc/hosts 2>/dev/null)
    _ch_own=$(stat -c%i "$_ch_file" 2>/dev/null)
    if [ -n "$_ch_top" ] && [ "$_ch_top" = "$_ch_own" ] \
        && grep -qF "$CLOUD_HOSTS_TAG_BEGIN" /system/etc/hosts 2>/dev/null; then
        command -v log >/dev/null 2>&1 && log "[CloudHosts] ✅ 已生效：$(echo "$_ch_dom" | wc -l | tr -d ' ') 个域名，hosts 共 $(wc -l < /system/etc/hosts 2>/dev/null | tr -d ' ') 行"
        return 0
    fi
    command -v log >/dev/null 2>&1 && log "[CloudHosts] ❌ bind 未生效（生效层 inode=$_ch_top，源文件 inode=$_ch_own）"
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
        # 【不碰别人的文件】若 hosts.cloud 已被其它模块 bind 覆盖，它指向的是对方的
        # 真实文件；rm 该路径会 EBUSY（无副作用），但这里显式跳过，语义更清楚
        cloud_hosts_shadowed "$CLOUD_HOSTS_FILE" || rm -f "$CLOUD_HOSTS_FILE" "$CLOUD_HOSTS_FILE.chk" 2>/dev/null
        rm -f "$CLOUD_HOSTS_OWN_FILE" "$CLOUD_HOSTS_OWN_FILE.chk" 2>/dev/null
    fi
    return 0
}
