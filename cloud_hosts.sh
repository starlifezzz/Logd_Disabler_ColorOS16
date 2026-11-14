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
    # ① 云控配置下发
    #    v2.3.28：删掉 icosa-service-cn-01.allawntech.com —— 481 个已安装包全量 dex 扫描
    #    0 命中（连 "icosa-service" 拆分形态都 0 命中），COSA.apk 1478 条目也 0 命中，
    #    原注释「cosa 提供该域名」已被证伪 → 判为无效域名，不再拦截。
    if is_on "block_cloud_hosts"; then
        echo "andesbrain-ai-cn.heytapmobi.com"
        echo "htms.heytapmobi.com"
        # 同一上报通道的备用/旧域名：主域被拦后 SDK 回退到这里（实测 4 个 App 同时引用两个域）
        echo "htms.heytapmobile.com"
    fi
    # ② 场景卡片与短信推广：有取舍（卡片不刷新），单独一个开关
    if is_on "block_scene_hosts"; then
        echo "scene.dc.oppomobile.com"
        echo "sms.ads.heytapmobi.com"
        # v2.3.28：运营位 / Tips 下发（NOIR 0.4.3 全量重扫：traffic-operation 19 包、oms-forward 9 包、tips 系 3 包）
        #   与场景卡片同类取舍：拦掉后运营入口/角标/Tips 不再刷新，功能本身可用
        echo "traffic-operation-cn.allawntech.com"
        echo "tips-h5.coloros.com"
        echo "oms-forward-cn.heytapmobi.com"
        echo "tips.apps.oppomobile.com"
        echo "tipsfs.oppomobile.com"
    fi
    # ③ 第三方 SDK 遥测：纯日志/统计/广告上报，与 ColorOS 云控不是一类，故独立开关
    #    【证据等级】域名来自 NOIR 静态扫描（unzip+strings 提取 dex 内 URL）+ 域名语义判断，
    #      未逐个实测；与 ① 那 3 个（有实证依据）不同，单列一项便于用户自行取舍。
    #    【例外】aspect-upush / offmsg 是友盟推送的统计端点，拦掉不影响推送通道本身
    #      （通道是 *.umeng.com 的 msg 域名），但可能影响推送到达率统计。
    if is_on "block_sdk_telemetry"; then
        # 友盟 Umeng：错误日志 4 个 + 离线消息统计 + 推送统计 + 广告消息统计
        #   msg.umengcloud.com 必须显式列：hosts 是精确匹配，bindhosts 的
        #   `umengcloud.com` 整域条目【不覆盖】子域（实测 apex→127.0.0.1 但本域→真实 IP）
        echo "errlog.umeng.com"
        echo "errlogos.umeng.com"
        echo "errnewlog.umeng.com"
        echo "errnewlogos.umeng.com"
        echo "offmsg.umeng.com"
        echo "aspect-upush.umeng.com"
        echo "msg.umengcloud.com"
        # 字节跳动：APM 与日志上报（不含 aweme/ecom，那是抖音功能域名）
        echo "apmlog.snssdk.com"
        echo "rtapplog.snssdk.com"
        echo "rtlog.snssdk.com"
        echo "cgp.snssdk.com"
        # OPPO 广告投放
        echo "adx.ads.oppomobile.com"
        # 巨量引擎广告
        echo "ad.oceanengine.com"
        echo "athena-api.oceanengine.com"
        # OPPO 审计 / 日志上报
        echo "api-audit.heytapmobi.com"
        echo "ilogkit-service-cn.allawntech.com"
        echo "u.bot.heytapmobi.com"
        # 腾讯 Bugly 崩溃上报 / 虎扑统计
        echo "bugtrace.3g.qq.com"
        echo "stat.huluxia.com"
        # 腾讯：广告归因（kv?attaid=）/ 灯塔分析（/analytics/v2_upload）/ Bugly 崩溃上报（/rqd/async）
        echo "h.trace.qq.com"
        echo "otheve.beacon.qq.com"
        echo "astat.bugly.qcloud.com"
        echo "astat.bugly.cros.wr.pvp.net"
        # 腾讯 QPlus 统计（/report/report）
        echo "cgi.qplus.com"
        # 腾讯地图 SDK 的 GPS 上报（/report?type=sdk）；定位查询走 loc.map.qq，不在此列
        echo "rttgpsreport.map.qq.com"
        # 阿里系：mPaaS 移动分析 / MAS 日志上传（/loggw/logUpload.do）
        echo "mdap.alipaylog.com"
        echo "cn-hangzhou-mas-log.cloud.alipay.com"
        # 友盟统计族（与 errlog 同源）
        echo "alogus.umeng.com"
        echo "alogsus.umeng.com"
        # HeyTap 浏览器内核日志 / 万联 xlog 日志服务
        echo "kernellog.browser.heytapmobi.com"
        echo "dev-xlog-service.wanyol.com"
        # 乐播投屏日志上报（8855/8856/8865/8868）；投屏功能通道是
        # gslb/imdns/devicemgr/pin.hpplay.cn，不在本清单内，故不影响投屏
        echo "logu.hpplay.cn"
        # 21CN 统计（云闪付 com.unionpay.tsmservice 上报；NOIR 0.2.5 归类 trackers）
        echo "collect.ux.21cn.com"
        # ================= v2.3.27：第三轮 NOIR 全量补齐（22 条）=================
        # 【选入标准】① 与已拦域同后端/同服务（同 IP 或同族路径）——拦主不拦备等于没拦；
        #   ② 路径是纯日志/统计/归因；③ 公共 DNS 有 A 记录（NXDOMAIN 的加了也是装饰）。
        # 【证据】NOIR 0.2.6 全量扫描（240 App / 3869 端点）+ AliDNS DoH 逐条查 A 记录。
        # 阿里 MDAP 日志网关族（mdap.alipay 与已拦 mdap.alipaylog 同为 110.76.24.162）
        echo "mdap.alipay.com"
        echo "mdap.mpaas.cn-hangzhou.aliyuncs.com"
        echo "loggw-extiny.alipay.com"
        # 字节 AppLog / 归因族（与已拦 rtlog.snssdk 同族；ctobsnssdk 走的是归因数据）
        echo "rtlog.zijieapi.com"
        echo "toblog-alink.ctobsnssdk.com"
        echo "tobapplog.volceapplog.com"
        echo "toblog.volceapplog.com"
        # 友盟日志族补充（cnlogs 与已拦 alogus.umeng 同为 58.221.74.137）
        echo "cnlogs.umeng.com"
        echo "ulogs.umeng.com"
        echo "ulogs.umengcloud.com"
        echo "plbslog.umeng.com"
        echo "pslog.umeng.com"
        echo "preulogs.umeng.com"
        # 高德 SDK 日志初始化（/v3/log/init）；log.qchannel03.cn 路径 /n/dpz/，用途未验证
        echo "apiinit.amap.com"
        echo "log.qchannel03.cn"
        # OPPO/HeyTap 自家埋点：epoch = H5 事件采集（/soporcollect），usertrace = 场景服务用户轨迹
        echo "epoch-cn.cdo.heytapmobi.com"
        echo "epoch.cdo.oppomobile.com"
        echo "nearby.dc.oppomobile.com"
        echo "cort-report-cn.heytapmobi.com"
        echo "ocloud-webdata-cn.heytapmobi.com"
        echo "mdp-usertrace-cn.wanyol.com"
        echo "usertrace-inter-cn.wanyol.com"
        # ============ v2.3.28：NOIR 0.4.3 全量重扫补全（ColorOS 一手上报 + 广告 16 条）============
        # 【证据】359 个启用包（系统 321 + 用户 38）：NOIR 扫描 157 + 设备端 dex 补抽 202；
        #   字符串常量 ≠ 运行时连接，未抓包、未看 DNS 日志 —— 与既有诚实标注同等级。
        # 【取舍·必读】rest-cn-feedback / static-cn-feedback 是用户反馈 SDK：拦掉后系统 App 里
        #   「意见反馈」「问题上报」提交会失败（52 个 App 共用该 SDK），功能入口仍在、只是发不出去。
        # 【与既有条目】adx.ads.oppomobile 已拦，这里补 heytapmobi 变体；
        #   stg-data.ads 的 /monitor/stat/err 与 /proxy/strategy/ 路径在 com.android.mms dex 实测存在。
        echo "rest-cn-feedback.heytapmobi.com"
        echo "static-cn-feedback.heytapmobi.com"
        echo "mdp-usertrace-cn.heytapmobi.com"
        echo "screen-report-cn.allawntech.com"
        echo "ua.prof.oppo.com"
        echo "stg-data.ads.heytapmobi.com"
        echo "adx.ads.heytapmobi.com"
        echo "adsfs.oppomobile.com"
        echo "uapi.ads.heytapmobi.com"
        echo "ssp-adx.ads.heytapmobi.com"
        echo "cl-data.ads.heytapmobi.com"
        echo "push-ads-cn.heytapmobi.com"
        echo "bact.cpc.heytapmobi.com"
        echo "u.cpc.heytapmobi.com"
        echo "cpc-assets-cn.heytapmobi.com"
        echo "cpc-message-cn.heytapmobi.com"
        # 【诚实标注】cgi.qplus.com 与 dev-xlog-service.wanyol.com 经 AliDNS 双节点复核为
        #   NXDOMAIN（公共 DNS 无 A 记录）→ hosts 拦截大概率无效，保留仅为覆盖运营商/HTTPDNS
        #   另有解析的可能，不计入有效拦截数。
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
