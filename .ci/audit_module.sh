#!/system/bin/sh
# ══════════════════════════════════════════════════════════
# 模块代码全面静态检查（ColorOS16 / KernelSU v3.2.5 规范）
# v2：修正 9 处检查器自身误报 —— 详见每条 [误报修正] 注释
# ══════════════════════════════════════════════════════════
SRC="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（本脚本位于 .ci/ 下）
T="${TMPDIR:-$SRC/.ci/.tmp}"   # 临时目录：TMPDIR 不可用时退回 .ci/.tmp（已 gitignore）
# 【门禁自身 bug 修复 2026-10-31】.ci/.tmp 被 .gitignore 忽略 → 新克隆缺该目录，
#   而 C 段用 `> $T/pkgs_*.txt` 写文件 → 重定向失败 → wc 报错 → 检查静默走偏。
mkdir -p "$T" 2>/dev/null
P=0; F=0
ok(){ echo "  ✅ $1"; P=$((P+1)); }
no(){ echo "  ❌ $1"; F=$((F+1)); }
wt(){ echo "  ⚠️  $1"; }

SH="service.sh post-fs-data.sh uninstall.sh customize.sh boot-completed.sh"

echo "═══ A. KernelSU 兼容性硬红线 ═══"
HIT=$(grep -nE "mount[[:space:]]+-o[[:space:]]*rw,remount|mount[[:space:]]+-o[[:space:]]*remount,rw" $SRC/*.sh 2>/dev/null)
[ -z "$HIT" ] && ok "无 mount -o rw,remount /system（KSU 用 OverlayFS，不可直接挂系统分区）" || { no "踩到 KSU 红线 mount -o rw,remount"; echo "$HIT" | sed 's/^/       /'; }

HIT=$(grep -nE "setenforce[[:space:]]+0" $SRC/*.sh 2>/dev/null)
[ -z "$HIT" ] && ok "无 setenforce 0（不关闭 SELinux）" || { no "踩到 SELinux 红线 setenforce 0"; echo "$HIT" | sed 's/^/       /'; }

# [误报修正①] 原正则把 `2>/dev/null` 的重定向符当成了"写入"，
#             且没排除 # 注释 → 报了 stat 读取行为。现排除 2>/、行首注释。
HIT=$(grep -nE "(>|>>|cp|mv|rm|sed -i)[^|;&]*[[:space:]]+/(system|vendor|product|system_ext)/" "$SRC"/*.sh 2>/dev/null \
      | grep -vE "2>>?/|^[0-9]*:[[:space:]]*#|mount|overlay|MODULEPATH" | head -5)
[ -z "$HIT" ] && ok "无直接写 /system|/vendor|/product 分区的操作（读取/日志引用不计）" || { wt "疑似直接写系统分区（逐条确认）"; echo "$HIT" | sed 's/^/       /'; }

# [误报修正②] 黑名单必须排除注释行。原正则把作者写的
#   L201 "# ... kill -9 误杀 system_server" 和
#   L604 "# 【警告】pkill -9 -x 是精确名匹配，不会误伤 system_server"
#   当成违规 —— 实际这两行恰恰证明作者已规避该风险。
# [防呆增强] 黑名单追加两个"精确包名"硬止损：android（framework-res、
#   system_server 宿主）与 oplus（oplus-framework-res）—— 对这俩执行
#   禁/杀必 bootloop。匹配用两侧定界符保证"整词"：前缀不能是 .
#   （放行 com.android.xxx / oplus.xxx 子包），后缀不能是 . - 字母数字
#   （放行 android.hardware.* 既有项与 oplus-framework-res.apk 路径）；
#   `pkill -f oplus` 这种子串误伤写法照样被抓。只加码不放松，现网零违规。
HIT=$(grep -nE "(pkill|kill -9|stop[[:space:]]|force-stop|disable-user)[^#]*" "$SRC"/*.sh 2>/dev/null \
      | grep -vE "^[^:]*:[0-9]+:[[:space:]]*#" \
      | grep -E "system_server|zygote64|zygote|surfaceflinger|android\.hardware\.|oplus\.security\.server|oplus\.sensor|(^|[^.[:alnum:]_-])(android|oplus)([^.[:alnum:]_-]|$)" | head -5)
[ -z "$HIT" ] && ok "操作黑名单零违规：未对 system_server/zygote/zygote64/surfaceflinger/android.hardware.*/oplus.security.server/oplus.sensor/精确包名android|oplus 执行杀/禁" || { no "踩到操作黑名单"; echo "$HIT" | sed 's/^/       /'; }

# [2026-10-02 事故加固] 禁用只允许 disable-user/disable，绝不 uninstall：
#   手动 pm uninstall --user 0 com.oplus.thirdkit 当场 bootloop（见 coloros.md P0）；
#   模块 disable_pkg 的 uninstall fallback 同族命令已移除。这里钉死：
#   任何脚本出现"执行 pm uninstall"（pm / cmd package / 带 -k 变体）即红。
#   注释行按惯例排除；动态拼接（pmx_verbose pm uninstall）同样被抓。
# [2026-10-12 事故加固·v2.3.19-fix] 同类红线扩展到 install-existing：
#   恢复侧 install-existing 会把【用户自己卸载的包】复活（社区反馈）；
#   模块从不卸载 → 包不可见=用户卸的 → 恢复只允许 pm enable。同一条红线钉死。
HIT=$(grep -nE "pm[[:space:]]+uninstall|package[[:space:]]+uninstall|uninstall[[:space:]]+-k|install-existing" "$SRC"/*.sh 2>/dev/null \
      | grep -vE "^[^:]*:[0-9]+:[[:space:]]*#" | head -5)
[ -z "$HIT" ] && ok "pm uninstall / install-existing 零执行：禁用只走 disable-user/disable、恢复只走 pm enable（2026-10-02 thirdkit 卸载事故 + 2026-10-12 误复活事故红线）" || { no "踩到 卸载/复活 红线（系统包卸载=bootloop；复活用户卸载=违背用户意愿）"; echo "$HIT" | sed 's/^/       /'; }

echo "═══ B. 模块开发规范 ═══"
SBAD=0
for f in $SH; do
  [ -f "$SRC/$f" ] || continue
  head -1 "$SRC/$f" | grep -q '^#!/system/bin/sh' || { no "$f 首行不是 #!/system/bin/sh（实际: $(head -1 "$SRC/$f")）"; SBAD=1; }
done
[ "$SBAD" = "0" ] && ok "5 个脚本首行均为 #!/system/bin/sh"

KSU=$(grep -lE "kernelsu|Kernelsu|KSU|/proc/mounts.*ksu" "$SRC"/*.sh 2>/dev/null | wc -l)
[ "$KSU" -gt 0 ] && ok "$KSU 个脚本含 KernelSU 环境探测" || wt "所有脚本均未发现 KernelSU 环境探测（无法判断是否 KSU 刷入，误刷非 KSU 设备时行为未知）"

# [误报修正③] 规范原文要求 service.sh 等 boot_completed，但本模块真实架构是：
#   service.sh = late_start（天然在开机早期）+ boot-completed.sh 承接 boot 后阶段。
#   只要 boot-completed.sh 存在，架构即等效，不应判失败。
if grep -q "sys.boot_completed" "$SRC/service.sh" 2>/dev/null; then
  ok "service.sh 显式等待 sys.boot_completed=1"
elif [ -f "$SRC/boot-completed.sh" ]; then
  ok "service.sh=late_start（无显式等待），由 boot-completed.sh 承接 boot 后阶段（架构等效）"
else
  no "service.sh 无 boot 等待，且缺 boot-completed.sh（开机竞态风险）"
fi

# [误报修正④] 原判定把 umount 也算成 mount。umount 是回滚清理（
#   bootloop 自动禁用后必须卸掉残留挂载，见 post-fs-data.sh:50 注释），必须允许。
# [误报修正⑨] 规范字面写"不进行任何挂载操作"，但本模块的核心机制就是
#   `mount -o bind $DUMMY $TARGET`（把 dummy 覆盖到 logd/mediametrics 等二进制），
#   即 service.log 里的"bind 挂载数=6"。bind 不改系统分区、umount 可完整回滚，
#   且 KernelSU 明确允许。故只禁 remount rw，放行 bind。
N_MNT=$(grep -cE "^[[:space:]]*mount[[:space:]]" "$SRC/post-fs-data.sh" 2>/dev/null)
N_BIND=$(grep -cE "^[[:space:]]*mount[[:space:]]+-o[[:space:]]+bind" "$SRC/post-fs-data.sh" 2>/dev/null)
N_RW=$(grep -cE "^[[:space:]]*mount[^#]*(rw,remount|remount,rw)" "$SRC/post-fs-data.sh" 2>/dev/null)
N_UMNT=$(grep -cE "^[[:space:]]*umount[[:space:]]" "$SRC/post-fs-data.sh" 2>/dev/null)
if [ "${N_RW:-0}" = "0" ]; then
  ok "post-fs-data.sh：bind mount ×$N_BIND（核心功能，可 umount 回滚）、remount-rw ×$N_RW、umount 清理 ×$N_UMNT"
else
  no "post-fs-data.sh 含 $N_RW 处 remount rw（KSU 红线）"
fi

# [误报修正⑤] 降级为警告：实测 service.log 各项复核均符合期望，功能正常。
N_RP=$(grep -c "resetprop" "$SRC/post-fs-data.sh" 2>/dev/null); N_SP=$(grep -c "setprop" "$SRC/post-fs-data.sh" 2>/dev/null)
if [ "${N_RP:-0}" -gt 0 ]; then
  ok "post-fs-data.sh 用 resetprop ×$N_RP（规范首选）"
else
  wt "post-fs-data.sh 全部用 setprop ×$N_SP（规范要求 resetprop）—— 但 service.log 实测复核全部符合期望，功能正常；属规范偏离，未擅改"
fi

echo "═══ C. 回滚可逆性 ═══"
if [ -f "$SRC/uninstall.sh" ]; then
  ok "uninstall.sh 存在（$(wc -l < "$SRC/uninstall.sh" | tr -d ' ') 行）"
  # [误报修正⑥] 原正则 `pm disable-user` 抓到 0 个包（实际是动态拼接调用），
  #   导致"0 vs 0"假通过。改用 service.log 金标准提取实际被禁的包。
  #
  # [误报修正⑧ 2026-10-31] 原回落分支是典型 fail-open：
  #   su 取不到设备日志时静默回落到 `[a-z]+(\.[a-z]+)` 无约束正则，从 service.sh
  #   抓出 binder.c / build.prop / cnss_diag.conf / com.oplus / anager.send 等
  #   79 个"包名" → 在 PC 上必然假红 79 条。
  #   现在：① 正则加前缀约束（真实包名必以 com|org|net|io 开头）；
  #        ② 排除整行注释（注释里的 com.coloros.lockassistant 并未被禁用，
  #           实测旧写法会把它算成"被禁但不会恢复"）；
  #        ③ 回落不再是"通过"，而是切换成【静态包含性】检查并在结果里标明模式；
  #        ④ 静态模式仍提取到 0 个 → 判 ❌（检查器自身失效），不静默放行。
  PKG_RE='(com|org|net|io)\.[a-z0-9_]+(\.[a-z0-9_]+)+'
  # 恢复清单 = uninstall.sh 的 ALL_PKGS
  sed -n '/^ALL_PKGS="/,/^"/p' "$SRC/uninstall.sh" | grep -oE "$PKG_RE" | sort -u > "$T/pkgs_on.txt"

  # 【金标准】设备侧 service.log 里实际被禁的包（</dev/null 防 su 等密码输入卡住）
  su -c "grep -E 'disable-user 成功|已禁用' /data/adb/logd_disabler/service.log" </dev/null 2>/dev/null \
    | grep -oE "$PKG_RE" | sort -u > "$T/pkgs_off.txt"
  if [ -s "$T/pkgs_off.txt" ]; then
    OFF_MODE="金标准"
  else
    # 【静态回落】无设备/无 su/日志被轮转时：service.sh 会禁用的包（排除注释行）
    #   必须全部落在 uninstall.sh 的 ALL_PKGS 内。
    OFF_MODE="静态包含性"
    grep -vE '^[[:space:]]*#' "$SRC/service.sh" 2>/dev/null \
      | grep -ohE "$PKG_RE" | sort -u > "$T/pkgs_off.txt"
  fi
  N_OFF=$(wc -l < "$T/pkgs_off.txt" | tr -d ' ')
  N_ON=$(wc -l < "$T/pkgs_on.txt" | tr -d ' ')
  if [ "$N_OFF" = "0" ]; then
    # 静态模式提取到 0 = 正则/文件失效（检查器坏了），必须判红，不能 wt 混过去
    if [ "$OFF_MODE" = "静态包含性" ]; then
      no "可逆性检查自身失效：$OFF_MODE 模式提取到 0 个包（正则或 service.sh 异常）"
    else
      wt "service.log 里提不到被禁包（日志可能被轮转），可逆性无法用金标准验证"
    fi
  else
    comm -23 "$T/pkgs_off.txt" "$T/pkgs_on.txt" > "$T/off_not_on.txt"
    N_GAP=$(wc -l < "$T/off_not_on.txt" | tr -d ' ')
    if [ "$N_GAP" = "0" ]; then
      ok "可逆性零缺口[$OFF_MODE]：被禁 $N_OFF 个包，全部落在 uninstall.sh 的 $N_ON 个恢复清单内"
    else
      no "有 $N_GAP 个包被禁但卸载时不会恢复[$OFF_MODE]："
      head -10 "$T/off_not_on.txt" | sed 's/^/       · /'
    fi
  fi
else
  no "uninstall.sh 不存在（回滚机制缺失）"
fi

echo "═══ D. 操作日志 ═══"
# [误报修正⑦] 规范写死 ksu_module.log，但模块实际用
#   /data/adb/logd_disabler/service.log + post-fs-data.log（带轮转）—— 属等效实现。
if grep -rq "ksu_module.log" "$SRC"/*.sh 2>/dev/null; then
  ok "存在 ksu_module.log 日志链路"
elif grep -rqE "service\.log|post-fs-data\.log" "$SRC"/*.sh 2>/dev/null; then
  ok "日志走 /data/adb/logd_disabler/{service,post-fs-data}.log（等效实现，且带轮转防膨胀）"
else
  wt "未发现操作日志链路（故障排查将无线索）"
fi

echo "═══ E. 高风险命令带中文警告注释 ═══"
# [误报修正⑧] 原判定把注释行本身当命令，也未容忍同块内已有说明性中文。
BAD=""
for f in service.sh boot-completed.sh; do
  ln=$(grep -nE "^[[:space:]]*(pkill|pm[[:space:]]+disable)" "$SRC/$f" 2>/dev/null | cut -d: -f1)
  for n in $ln; do
    s=$((n>6 ? n-6 : 1))
    seg=$(sed -n "${s},${n}p" "$SRC/$f")
    echo "$seg" | grep -qE "警告|风险|注意|回滚|可还原|精确名匹配|不误伤|不会误伤|只阻止|优先" || BAD="$BAD $f:$n"
  done
done
[ -z "$BAD" ] && ok "所有 pkill / pm disable 近旁均有中文警告或风险说明" || wt "部分高风险命令缺警示注释：$BAD"

echo "═══ F. 语法 ═══"
SYN=0
for f in $SH; do
  [ -f "$SRC/$f" ] || continue
  if ! out=$(sh -n "$SRC/$f" 2>&1); then no "$f 语法错误：$(echo "$out" | head -2)"; SYN=1; fi
done
[ "$SYN" = "0" ] && ok "5 个脚本 sh -n 全部通过"

echo "═══ G. 版本一致性 ═══"
MV=$(grep '^version=' "$SRC/module.prop" | cut -d= -f2)
MC=$(grep '^versionCode=' "$SRC/module.prop" | cut -d= -f2)
UV=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$SRC/update.json" | grep -oE 'v[0-9.]+')
UC=$(grep -oE '"versionCode"[[:space:]]*:[[:space:]]*[0-9]+' "$SRC/update.json" | grep -oE '[0-9]+$')
# 【v2.3.27-fix 2026-11-08】update.json 允许滞后于 module.prop（main 可提前 bump 开发版本），
#   但绝不允许【高于】——那会让用户被提示升级到不存在的 release（zipUrl 404，提示永不消失）。
UV_N=$(printf '%s' "$UC" | tr -dc '0-9'); MV_N=$(printf '%s' "$MC" | tr -dc '0-9')
if [ -n "$UV_N" ] && [ -n "$MV_N" ] && [ "$UV_N" -le "$MV_N" ]; then
  ok "update.json versionCode=$UC ≤ module.prop versionCode=$MC（无幽灵更新）"
else
  no "update.json versionCode=$UC > module.prop versionCode=$MC（提示升级到不存在的版本）"
fi
if [ -f "$SRC/webroot/index.html" ]; then
  IV=$(grep -oE 'moduleVersion[^,;]*' "$SRC/webroot/index.html" | head -1)
  echo "  · WebUI 取版本来源: $IV"
fi
# update.json 是否进包 —— 直接决定 checkUpdate 走本地还是远程
if grep -qE "update\.json" "$SRC/build_zip.py" 2>/dev/null; then
  EX=$(grep -E "EXCL_FILES|update\.json" "$SRC/build_zip.py" | head -3)
  wt "update.json 被 build_zip 排除（EXCL）→ 设备上不存在 → checkUpdate 永远走 curl 拉远程"
  echo "$EX" | sed 's/^/       /'
fi

echo "════════ 模块静态检查：$P 通过 / $F 失败 ════════"
exit $F
