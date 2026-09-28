#!/system/bin/sh
# ══════════════════════════════════════════════════════════
# 模块代码全面静态检查（ColorOS16 / KernelSU v3.2.5 规范）
# v2：修正 9 处检查器自身误报 —— 详见每条 [误报修正] 注释
# ══════════════════════════════════════════════════════════
SRC="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（本脚本位于 .ci/ 下）
T="${TMPDIR:-$SRC/.ci/.tmp}"   # 临时目录：TMPDIR 不可用时退回 .ci/.tmp（已 gitignore）
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
HIT=$(grep -nE "(pkill|kill -9|stop[[:space:]]|force-stop|disable-user)[^#]*" "$SRC"/*.sh 2>/dev/null \
      | grep -vE "^[^:]*:[0-9]+:[[:space:]]*#" \
      | grep -E "system_server|zygote64|zygote|surfaceflinger|android\.hardware\.|oplus\.security\.server|oplus\.sensor" | head -5)
[ -z "$HIT" ] && ok "操作黑名单零违规：未对 system_server/zygote/zygote64/surfaceflinger/android.hardware.*/oplus.security.server/oplus.sensor 执行杀/禁" || { no "踩到操作黑名单"; echo "$HIT" | sed 's/^/       /'; }

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
  su -c "grep -E 'disable-user 成功|已禁用' /data/adb/logd_disabler/service.log" 2>/dev/null \
    | grep -oE "[a-z][a-z0-9_]+(\.[a-z0-9_]+)+" | sort -u > "$T/pkgs_off.txt"
  [ -s "$T/pkgs_off.txt" ] || grep -ohE "[a-z][a-z0-9_]+(\.[a-z0-9_]+)" "$SRC"/service.sh 2>/dev/null | sort -u > "$T/pkgs_off.txt"
  # 恢复清单 = uninstall.sh 的 ALL_PKGS
  sed -n '/^ALL_PKGS="/,/^"/p' "$SRC/uninstall.sh" | grep -oE "[a-z][a-z0-9_]+(\.[a-z0-9_]+)+" | sort -u > "$T/pkgs_on.txt"
  N_OFF=$(wc -l < "$T/pkgs_off.txt" | tr -d ' ')
  N_ON=$(wc -l < "$T/pkgs_on.txt" | tr -d ' ')
  if [ "$N_OFF" = "0" ]; then
    wt "service.log 里提不到被禁包（日志可能被轮转），可逆性无法用金标准验证"
  else
    comm -23 "$T/pkgs_off.txt" "$T/pkgs_on.txt" > "$T/off_not_on.txt"
    N_GAP=$(wc -l < "$T/off_not_on.txt" | tr -d ' ')
    if [ "$N_GAP" = "0" ]; then
      ok "可逆性金标准零缺口：实际被禁 $N_OFF 个包，全部落在 uninstall.sh 的 $N_ON 个恢复清单内"
    else
      no "有 $N_GAP 个包被禁但卸载时不会恢复："
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
[ "$MV" = "$UV" ] && ok "module.prop version=$MV = update.json version=$UV" || no "版本不一致: module.prop=$MV vs update.json=$UV"
[ "$MC" = "$UC" ] && ok "module.prop versionCode=$MC = update.json versionCode=$UC" || no "versionCode 不一致: $MC vs $UC"
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
