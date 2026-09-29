#!/bin/bash
SRC="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（本脚本位于 .ci/ 下，自动定位）
T="${TMPDIR:-$SRC/.ci/.tmp}"   # 临时目录：Termux 的 TMPDIR 可写，否则退回 .ci/.tmp（已 gitignore）
CI="$(cd "$(dirname "$0")" && pwd)"   # 门禁脚本自身目录（.ci/），预置对拍脚本放这里
P=0; F=0
ok(){ P=$((P+1)); printf "  ✅ %s\n" "$1"; }
no(){ F=$((F+1)); printf "  ❌ %s\n" "$1"; }
chk(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

# ---- L2 分层后的应用自有 CSS 路径（加载顺序：tokens → base → components → pages → theme）----
AST="$SRC/webroot/assets"
CSS_TOK="$AST/app.tokens.css"
CSS_BASE="$AST/app.base.css"
CSS_COMP="$AST/app.components.css"
CSS_PAGES="$AST/app.pages.css"
CSS_THEME="$AST/app.theme.crt.css"
CSS_ALL="$CSS_TOK $CSS_BASE $CSS_COMP $CSS_PAGES $CSS_THEME"

echo "═══ A. 语法 ═══"
for f in service.sh uninstall.sh post-fs-data.sh customize.sh boot-completed.sh; do
  if sh -n "$SRC/$f" 2>/dev/null; then ok "sh -n $f"; else no "sh -n $f"; fi
done
python3 -c "
import re,subprocess
s=open('$SRC/webroot/index.html',encoding='utf-8').read()
open('$T/i.js','w',encoding='utf-8').write('\n'.join(re.findall(r'<script>(.*?)</script>',s,re.S)))
raise SystemExit(0 if subprocess.run(['node','--check','$T/i.js'],capture_output=True).returncode==0 else 1)" \
  && ok "node --check index.html" || no "node --check index.html"

echo "═══ B. enable_mglru / lru_gen 移除审计 ═══"
chk "service.sh 不再读开关 is_on enable_mglru" "! grep -q 'is_on \"enable_mglru\"' $SRC/service.sh"
chk "service.sh 不再写 lru_gen/enabled"      "! grep -q 'lru_gen/enabled' $SRC/service.sh"
chk "service.sh 无 [MGLRU] 运行日志"          "! grep -q '\[MGLRU\]' $SRC/service.sh"
chk "index.html 无 enable_mglru 条目"         "! grep -q 'enable_mglru' $SRC/webroot/index.html"
chk "post-fs-data 无 enable_mglru 引用"       "! grep -q 'enable_mglru' $SRC/post-fs-data.sh"
chk "uninstall.sh 仍保留兜底 echo 0x0003"     "grep -q 'echo 0x0003 > /sys/kernel/mm/lru_gen' $SRC/uninstall.sh"
chk "uninstall.sh 不写 0x0000"                "! grep -q 'echo 0x0000 > /sys/kernel/mm/lru_gen' $SRC/uninstall.sh"
# 只审计会被开机执行的脚本（post-fs-data/service/customize/boot-completed），排除 uninstall 的兜底
grep -n 'echo 0x' $SRC/service.sh $SRC/post-fs-data.sh $SRC/customize.sh $SRC/boot-completed.sh 2>/dev/null | grep -q 'lru_gen' \
  && no "开机脚本仍在写 lru_gen" || ok "开机脚本完全不写 lru_gen（仅 uninstall 兜底 0x0003）"

echo "═══ C. 开关数量与同步 ═══"
AK=$(grep -m1 'ALL_KEYS="' $SRC/service.sh | sed 's/.*ALL_KEYS="//;s/".*//')
N=$(echo $AK | wc -w)
[ "$N" = "34" ] && ok "ALL_KEYS 数量 = 34" || no "ALL_KEYS = $N (期望 34)"
AK2=$(grep -m1 -A0 'ALL_KEYS="' $SRC/service.sh | head -1)
C1=$(grep -c 'ALL_KEYS="' $SRC/service.sh); [ "$C1" = "2" ] && ok "ALL_KEYS 出现 2 处" || no "ALL_KEYS 出现 $C1 处"
grep -m1 'ALL_KEYS="' $SRC/service.sh | grep -q enable_mglru && no "ALL_KEYS 仍含 enable_mglru" || ok "ALL_KEYS 已无 enable_mglru"
grep -m1 -A0 '' /dev/null; sed -n '101p' $SRC/service.sh | grep -q enable_mglru && no "ALL_KEYS#2 仍含" || ok "ALL_KEYS#2 已无 enable_mglru"

echo "═══ D. FEATURES ↔ ALL_KEYS 一一对应 ═══"
python3 - "$SRC" "$T" <<'PY'
import re,sys,os
src,tmp=sys.argv[1],sys.argv[2]
s=open(f'{src}/webroot/index.html',encoding='utf-8').read()
i=s.find('var FEATURES'); j=s.find('\n];',i)
blk=s[i:j]
feats=re.findall(r"key: '([a-z_0-9]+)'",blk)+re.findall(r"subGroupKey: ['\"]([a-z_0-9]+)['\"]",blk)
feats=list(dict.fromkeys(feats))
svc=open(f'{src}/service.sh',encoding='utf-8').read()
ak=re.search(r'ALL_KEYS="([^"]+)"',svc).group(1).split()
extra=[k for k in feats if k not in ak]
missing=[k for k in ak if k not in feats]
open(f'{tmp}/feat.txt','w').write("%d\n%s\n%s\n" % (len(feats), ','.join(extra), ','.join(missing)))
print(f"  FEATURES keys = {len(feats)}")
if not extra and not missing and len(feats)==34:
    print(f"  ✅ FEATURES == ALL_KEYS == 34，无缺无多")
else:
    print(f"  ❌ extra={extra} missing={missing}")
PY
[ "$(sed -n 1p $T/feat.txt)" = "34" ] && [ -z "$(sed -n 2p $T/feat.txt)" ] && [ -z "$(sed -n 3p $T/feat.txt)" ] \
  && ok "FEATURES ↔ ALL_KEYS 一致(34)" || no "FEATURES ↔ ALL_KEYS 不一致"

echo "═══ E. 核心功能仍完整 ═══"
BINS="midasd ostatsd ostats_pullerd ostats_tpd criticallog subsystem_ramdump"
for b in $BINS; do
  n=$(grep -c "$b" $SRC/post-fs-data.sh); m=$(grep -c "$b" $SRC/service.sh); u=$(grep -c "$b" $SRC/uninstall.sh)
  [ "$n" -ge 1 ] && [ "$m" -ge 1 ] && [ "$u" -ge 1 ] && ok "6二进制 $b 三处齐全 (pfs=$n svc=$m un=$u)" || no "$b pfs=$n svc=$m un=$u"
done
# --- v2.3.10 回归：mediametrics 必须【不在】禁用清单，但仍需在三处出现（兜底/注释）---
DCBINS=$(grep -h '^DC_BINS=' $SRC/post-fs-data.sh)
case "$DCBINS" in
  *mediametrics*) no "DC_BINS 仍含 mediametrics（会导致 Oboe/AAudio 应用无声+ANR）";;
  *) ok "DC_BINS 已移除 mediametrics";;
esac
grep -q '完成 \$DC_OK/6' $SRC/post-fs-data.sh && ok "post-fs-data 完成计数 = /6" || no "完成计数不是 /6"
grep -q '期望 6' $SRC/post-fs-data.sh && ok "post-fs-data 自检期望 6" || no "自检未改期望 6"
grep -q '期望 6' $SRC/service.sh && ok "service.sh 复核期望 6" || no "复核未改期望 6"
grep -q 'for dcproc in midasd ostatsd ostats_pullerd ostats_tpd criticallog subsystem_ramdump; do' $SRC/service.sh \
  && ok "service.sh 杀进程清单已移除 mediametrics" || no "service.sh 杀进程清单仍含 mediametrics"
grep -q 'mediametrics 必须存活' $SRC/service.sh && ok "service.sh 增加 mediametrics 存活复核" || no "缺 mediametrics 存活复核"
grep -q 'mediametrics 必须正常' $SRC/post-fs-data.sh && ok "post-fs-data 增加 mediametrics 正常复核" || no "缺 mediametrics 正常复核"
grep -q 'mediametrics 必须' $SRC/webroot/index.html && ok "WebUI verifyCmd 含 mediametrics 回归项" || no "WebUI 缺 mediametrics 回归项"
PKGS="com.heytap.htms com.heytap.mcs com.heytap.mydevices com.oplus.pantanal.ums com.oppo.ctautoregist com.oplus.thirdkit"
T9=$(grep -c 'disable_telemetry_cloud|' $SRC/service.sh)
[ "$T9" = "1" ] && ok "PKG_TABLE 含 disable_telemetry_cloud" || no "PKG_TABLE 缺失"
for p in $PKGS; do
  grep -q "$p" $SRC/service.sh || { no "service.sh 缺 $p"; continue; }
  grep -q "$p" $SRC/uninstall.sh && ok "遥测包 $p 双处齐全" || no "$p uninstall 缺"
done
for p in com.coloros.note com.coloros.alarmclock com.oplus.blur com.oplus.gesture com.oplus.location; do
  grep -q "disable_telemetry_cloud|$p" $SRC/service.sh && no "保护名单 $p 被误入" || ok "保护名单未入 telemetry: $p"
done

echo "═══ F. checkCmd P1-B 修复 ═══"
NOLD=$(grep -c "checkCmd: 'pm list packages --user 0 2>/dev/null" $SRC/webroot/index.html)
[ "$NOLD" = "0" ] && ok "旧写法残留 = 0" || no "旧写法残留 = $NOLD"
NNEW=$(grep -c "checkCmd: 'pm list packages -d --user 0 2>/dev/null | grep -qF \"package:" $SRC/webroot/index.html)
[ "$NNEW" = "21" ] && ok "新写法 = 21" || no "新写法 = $NNEW (期望 21)"
NJS=$(grep -c "pm list packages -d --user 0 2>/dev/null | grep -qF \"package:\\\$p\"" $SRC/webroot/index.html)
[ "$NJS" -ge 1 ] && ok "动态生成器仍用 -d (=$NJS)" || no "动态生成器丢失"

echo "═══ F2. 遥测子项「检测中」修复（v2.3.14）═══"
grep -q 'pkgStateUnknown: function(key, pkg)' $SRC/webroot/index.html && ok "pkgStateUnknown 方法存在" || no "缺 pkgStateUnknown 方法"
NU=$(grep -c 'v-if="pkgStateUnknown(item.key, p)"' $SRC/webroot/index.html)
[ "$NU" = "2" ] && ok "两处子开关都走检测中分支 (=$NU)" || no "检测中分支 = $NU (期望 2)"
NOLD2=$(grep -c 'v-if="!pkgStateDisabled(item.key, p)"' $SRC/webroot/index.html)
[ "$NOLD2" = "0" ] && ok "旧的直判 未优化 分支 = 0" || no "仍有 $NOLD2 处旧的直判分支"
grep -q '.opt-hint.checking' $CSS_ALL && ok "checking 样式存在" || no "缺 .opt-hint.checking 样式"
grep -q '检测中' $SRC/webroot/index.html && ok "文案「检测中」已写入" || no "缺「检测中」文案"

echo "═══ F3. missing 态修复（父开子关真凶）═══"
grep -q 'pkgStateMissing: function(key, pkg)' $SRC/webroot/index.html && ok "pkgStateMissing 方法存在" || no "缺 pkgStateMissing 方法"
NM=$(grep -c 'v-else-if="pkgStateMissing(item.key, p)"' $SRC/webroot/index.html)
[ "$NM" = "2" ] && ok "两处子开关都有「未安装」分支 (=$NM)" || no "未安装分支 = $NM (期望 2)"
ND=$(grep -c ':disabled="pkgStateMissing(item.key, p)"' $SRC/webroot/index.html)
[ "$ND" = "2" ] && ok "两处子开关 missing 时禁用 (=$ND)" || no "missing 禁用 = $ND (期望 2)"
grep -q 'com.oplus.travelengine 在 PKG110 上不存在' $SRC/webroot/index.html && ok "注释记录了 travelengine 证据" || no "缺证据注释"
grep -q 'webui_state.json' $SRC/webroot/index.html && ok "UI 状态落盘诊断已加" || no "缺 webui_state.json 落盘"
grep -q '_tel_on=0; is_on "disable_telemetry_cloud"' $SRC/service.sh && ok "Telemetry 复核期望值已随开关动态" || no "复核期望值仍写死"
grep -q '关键包状态=\$(' $SRC/service.sh && no "复核行仍是内联 \$(...) 拼期望" || ok "复核行已改为读 \$_tel_now"

echo "═══ F4. 白名单「已保留」修复（父开子关主因）═══"
grep -q 'v-else-if="isKept(item.key, p)" class="opt-hint kept"' $SRC/webroot/index.html \
  && ok "子开关识别白名单" || no "子开关未识别白名单"
NK=$(grep -c 'class="opt-hint kept"' $SRC/webroot/index.html)
[ "$NK" = "2" ] && ok "两处子开关都有「已保留」分支 (=$NK)" || no "已保留分支 = $NK (期望 2)"
# 顺序：「已保留」那一行的下一行必须就是「未优化」分支，否则白名单包仍会被标未优化
NO=$(grep -A1 'class="opt-hint kept"' $SRC/webroot/index.html | grep -c 'v-else-if="!pkgStateDisabled(item.key, p)"')
[ "$NO" = "2" ] && ok "「已保留」正好排在「未优化」之前 (=$NO)" || no "「已保留」顺序错误 (= $NO，期望 2)"
grep -q '\.opt-hint\.kept{' $CSS_ALL && ok "kept 专用样式存在" || no "缺 .opt-hint.kept 样式"
grep -q 'v-else-if="isKept(item.key, p)" class="opt-hint kept">已保留' $SRC/webroot/index.html && ok "文案「已保留」已写入" || no "缺「已保留」文案"

echo "═══ F5. 1:1 联动模型（一/二级=编组按钮，三级=实际开关）═══"
# 病灶：聚合结果回写意图 —— 一个子包关掉就把整组 config 翻 false → 开机整组被恢复
# 注意：注释里会引用旧代码作反例，所以只查函数体本身
SP=$(sed -n "$(grep -n 'syncParentSwitch: function' $SRC/webroot/index.html | head -1 | cut -d: -f1),+22p" $SRC/webroot/index.html)
echo "$SP" | grep -q 'config\[item\.key\] *= *allDisabled' && no "syncParentSwitch 仍把聚合回写 config" || ok "syncParentSwitch 不再回写 config"
echo "$SP" | grep -q "delete this.config\[item.key + '_keep'\]" && no "syncParentSwitch 仍会清掉白名单" || ok "syncParentSwitch 不再清白名单"
echo "$SP" | grep -q "writeConfig()" && no "syncParentSwitch 仍在写盘" || ok "syncParentSwitch 只读显示、不写盘"
echo "$SP" | grep -q "if (!item.pkgs || !item.pkgs.length) return;" && ok "无 pkgs 的 item 不被聚合覆盖（规格4）" || no "缺无 pkgs 早返回"
# 一级(subGroup)同样只写显示
SS=$(sed -n "$(grep -n 'syncSubGroupSwitch: function' $SRC/webroot/index.html | head -1 | cut -d: -f1),+24p" $SRC/webroot/index.html)
echo "$SS" | grep -q "config\[ssk\] *= *allOn" && no "syncSubGroupSwitch 仍回写 config[subKey]" || ok "syncSubGroupSwitch 不回写 config[subKey]"
echo "$SS" | grep -q "writeConfig()" && no "syncSubGroupSwitch 仍在写盘" || ok "syncSubGroupSwitch 只读显示、不写盘"
# 三级=实际开关项：pm 成功后修意图，保证能活过重启
grep -q "组意图 .* → true，白名单锁定其余" $SRC/webroot/index.html && ok "三级开时修正组意图+白名单（重启 1:1）" || no "缺三级意图修正"
# 显示必须按【实际】聚合，而不是读 config
grep -q "self.syncParentSwitch(item);" $SRC/webroot/index.html && ok "level-2 按真实 pm 状态聚合父开关" || no "level-2 未按实际聚合"
grep -q "s.enabled = hasPkgs ? (cfgEnabled && keepList.length === 0) : cfgEnabled;" $SRC/webroot/index.html \
  && ok "level-1 显示 = config 且白名单为空（规格3）" || no "level-1 显示语义未改"

echo "═══ G. 硬止损违禁扫描 ═══"
for f in service.sh post-fs-data.sh customize.sh boot-completed.sh uninstall.sh; do
  c=$(grep -cE "mount -o rw,remount /system|setenforce 0|rm -rf /(system|vendor|odm|product)" $SRC/$f 2>/dev/null)
  [ "$c" = "0" ] && ok "违禁命令 0: $f" || no "违禁命令 $c: $f"
done
for b in system_server zygote zygote64 surfaceflinger oplus.security.server oplus.sensor; do
  grep -vE '^\s*#' $SRC/service.sh | grep -qE "(pkill|pm disable|am force-stop)[^\n]*\b$b\b" && no "黑名单命中 $b" || ok "黑名单未命中 $b"
done
grep -q '^#!/system/bin/sh' $SRC/service.sh && grep -q '^#!/system/bin/sh' $SRC/post-fs-data.sh && grep -q '^#!/system/bin/sh' $SRC/uninstall.sh \
  && ok "shebang 3/3" || no "shebang 缺失"

echo "═══ H. 版本一致性 ═══"
V=$(grep '^version=' $SRC/module.prop|cut -d= -f2); VC=$(grep '^versionCode=' $SRC/module.prop|cut -d= -f2)
JV=$(python3 -c "import json;print(json.load(open('$SRC/update.json'))['version'])")
JVC=$(python3 -c "import json;print(json.load(open('$SRC/update.json'))['versionCode'])")
[ "$V" = "v2.3.19" ] && ok "module.prop version=$V" || no "version=$V"
[ "$VC" = "53" ] && ok "module.prop versionCode=$VC" || no "versionCode=$VC"
[ "$JV" = "$V" ] && ok "update.json version=$JV 一致" || no "update.json $JV != $V"
[ "$JVC" = "$VC" ] && ok "update.json versionCode=$JVC 一致" || no "update.json $JVC != $VC"

echo
echo "═══ F6. 二级开关 → 一级实时联动（v2.3.15 实测 bug 回归）═══"
# 实测：打开「屏幕」一级 → 关「全局搜索」二级 → 一级仍显示开；直到关「速览」的三级才掉。
# 病因：onPkgSwitch(三级) 会调 syncSubGroupSwitch，onSwitchChange(二级) 从不调。
ON2=$(sed -n "$(grep -n 'onSwitchChange: function' $SRC/webroot/index.html|head -1|cut -d: -f1),+60p" $SRC/webroot/index.html)
echo "$ON2" | grep -q 'this\.syncSubGroupSwitch(item\.key);' && ok "onSwitchChange 会重算一级" || no "onSwitchChange 没调 syncSubGroupSwitch（旧 bug）"
echo "$ON2" | grep -q 'if (item\.synthetic && item\.subItems)' && ok "一级回滚会连带回滚其下二级（规格1）" || no "缺合成一级回滚联级"
echo "$ON2" | grep -q '属性写入失败：回滚所有 UI 状态' && ok "保留属性写入失败回滚分支" || no "误删回滚分支"
# 反向：不得在一级合成项上误把聚合值当意图
echo "$ON2" | grep -q 'delete self\.config\[item\.key + ._keep.\];' && ok "二级开/关会清掉该项白名单（意图纯净）" || no "二级未清白名单"
# 结构性确认：合成一级的 key 来自"组内第一个 item 的 subGroupKey"(1776 行)
# → 任何带 subGroup 的 item 都必须有 subGroupKey，否则一旦它排到首位，一级 key 会变空串
node -e "
const fs=require('fs');const h=fs.readFileSync('$SRC/webroot/index.html','utf8');
const s=h.indexOf('var FEATURES = ['),e=h.indexOf('\\n];',s);
const F=eval('('+h.slice(s,e+3).replace(/^var FEATURES = /,'').replace(/;\\s*$/,'')+')');
let g=0,m=0,scr=0,sp=0,union=new Set();
F.forEach(gr=>(gr.items||[]).forEach(i=>{ if(!i.subGroup)return; g++;
  if(!i.subGroupKey)m++;
  if(i.subGroup==='屏幕服务'){scr++; (i.pkgs||[]).forEach(p=>union.add(p));}
  if(i.key==='disable_speedview')sp+=(i.pkgs||[]).length; }));
process.exit(g>0&&m===0&&scr===2&&sp===2&&union.size===3?0:1);" && ok "所有带 subGroup 的 item 均有 subGroupKey；屏幕服务=2 项/3 包" || no "结构与实测不符"

echo "═══ F7. 命令 ↔ WebUI 全量对拍（脚本 xmap2 / xmap3）═══"
node "$CI/xmap2.js" >/dev/null 2>&1 && ok "PKG_TABLE+特殊块 23 个键逐包一致、keep 传参齐全" || { no "xmap2 对拍失败"; node "$CI/xmap2.js" 2>&1 | grep '❌' | sed 's/^/       /'; }
node "$CI/xmap3.js" >/dev/null 2>&1 && ok "32 键双向覆盖 / verifyCmd 可解析 / 方向同向 / 特殊块有实现" || { no "xmap3 对拍失败"; node "$CI/xmap3.js" 2>&1 | grep '❌' | sed 's/^/       /'; }
# 不变量：KEEP_KEYS 必须等于「所有 ≥2 包的功能」+「block_ota/block_ads 特殊块」
node -e "
const fs=require('fs');
const sh=fs.readFileSync('$SRC/service.sh','utf8');
const h=fs.readFileSync('$SRC/webroot/index.html','utf8');
const KEEP=new Set(((sh.match(/KEEP_KEYS=\"([^\"]+)\"/)||[])[1]||'').split(/\s+/).filter(Boolean).map(k=>k.replace(/_keep$/,'')));
const s=h.indexOf('var FEATURES = ['),e=h.indexOf('\n];',s);
const F=eval('('+h.slice(s,e+3).replace(/^var FEATURES = /,'').replace(/;\s*$/,'')+')');
const need=new Set();
F.forEach(g=>(g.items||[]).forEach(i=>{ if(i.pkgs&&i.pkgs.length>1) need.add(i.key); }));
const miss=[...need].filter(k=>!KEEP.has(k));
process.exit(miss.length?1:0);" && ok "KEEP_KEYS 覆盖全部多包功能（不变量成立）" || no "KEEP_KEYS 仍缺多包键"

echo "═══ F8. 服务端复核期望值必须扣除 WebUI 白名单（v2.3.15）═══"
grep -q '_tel_total=' $SRC/service.sh && ok "Telemetry 期望值改为「已安装总数」动态计算" || no "仍写死期望 8"
grep -q '_tel_exp=\$((_tel_exp-1))' $SRC/service.sh && ok "期望值会逐个扣减 _keep 白名单" || no "未扣除白名单"
grep -q 'WebUI白名单 $_tel_keep' $SRC/service.sh && ok "日志直接打印白名单内容便于排查" || no "日志未打印白名单"
! grep -q '期望 8 = 全部已禁用' $SRC/service.sh && ok "硬编码「期望 8」已清除" || no "仍残留硬编码期望 8"

echo "═══ F9. v2.3.17 四项需求回归（缺陷1/缺陷2/未安装提示/全局搜索）═══"
IDX=$SRC/webroot/index.html
# ---- 缺陷1：syncParentSwitch 对 missing 的判定必须与 checkItem 同源 ----
SP=$(sed -n '/syncParentSwitch: function/,/^    },/p' $IDX)
echo "$SP" | grep -q "v === 'missing'" && ok "syncParentSwitch 显式处理 'missing'" || no "仍只认 'disabled'"
echo "$SP" | grep -q "keepList.indexOf(p) < 0" && ok "missing 判定纳入本项 _keep（与 checkItem 同源）" || no "missing 未纳入白名单"
echo "$SP" | grep -q "item.synthetic && item.subItems" && ok "合成一级 missing 按子项 owner 意图推导" || no "合成一级 missing 推导缺失"
echo "$SP" | grep -q "ownerKeep.indexOf(p) < 0" && ok "合成一级 missing 也纳入子项白名单" || no "合成一级 missing 未纳入子项白名单"
echo "$SP" | grep -q "allDisabled" && no "残留 allDisabled（旧的只认 disabled 逻辑）" || ok "旧 allDisabled 逻辑已移除"
# 静态语义不变量：config=false + 包全 enabled → 必须落到 return false（显示关）
echo "$SP" | grep -q "return v === 'enabled';" && no "误把「实际已启用」当成达标" || ok "expected=启用 时仅 missing/其他不算达标"
# ---- 缺陷2：onPkgSwitch 必须有 install-existing 兜底 + 状态回读 ----
ON=$(sed -n '/onPkgSwitch: function/,/^    },/p' $IDX)
echo "$ON" | grep -q "cmd package install-existing" && ok "恢复路径有 install-existing 兜底（对齐 service.sh）" || no "缺 install-existing 兜底"
echo "$ON" | grep -q "var readState" && ok "pm 执行后回读真实状态" || no "无状态回读"
echo "$ON" | grep -q 'pm list packages --user 0' && ok "先探测包是否对 user0 可见" || no "无安装探测"
echo "$ON" | grep -q "real !== 'enabled'" && ok "禁用成功判定包含 missing 达标" || no "成功判定未含 missing"
echo "$ON" | grep -q "real === 'enabled'" && ok "恢复成功判定要求真实 enabled" || no "恢复成功判定过宽"
echo "$ON" | grep -q "knownMissing ? 'missing' : 'disabled'" && ok "乐观状态不把未安装包写成 disabled" || no "乐观状态仍会撒谎"
# ---- 需求3：「是否卸载」独立检查项 ----
grep -q "itemMissing: function" $IDX && ok "存在 itemMissing 计数 helper" || no "缺 itemMissing"
grep -q "itemMissingText: function" $IDX && ok "存在 itemMissingText 文案 helper" || no "缺 itemMissingText"
grep -q "subMissingText: function" $IDX && ok "存在 subMissingText（一级汇总）" || no "缺 subMissingText"
grep -q "itemHint: function" $IDX && ok "存在 itemHint（卸载态优先于未优化）" || no "缺 itemHint"
grep -q "subHint: function" $IDX && ok "存在 subHint（一级提示）" || no "缺 subHint"
HC=$(grep -c 'itemHint(item)' $IDX); [ "$HC" -ge 5 ] && ok "模板 $HC 处改用 itemHint（含二级/三级）" || no "itemHint 模板处数=$HC（应>=5）"
grep -q 'subHint(sub)' $IDX && ok "一级分组也改用 subHint" || no "一级未用 subHint"
! grep -q 'v-if="!state\[item.key\].enabled" class="opt-hint"' $IDX && ok "旧硬编码「未优化」span 已全部替换" || no "仍有旧硬编码未优化 span"
grep -q 'v-else-if="!pkgStateDisabled(item.key, p)" class="opt-hint">未优化' $IDX && ok "三级（逐包行）仍保留「未优化」提示" || no "三级未优化提示被误删"
# ---- 需求4：全局搜索加入 屏幕服务 ----
node -e "
const fs=require('fs');const h=fs.readFileSync('$IDX','utf8');
const s=h.indexOf('var FEATURES = ['),e=h.indexOf('\n];',s);
const F=eval('('+h.slice(s,e+3).replace(/^var FEATURES = /,'').replace(/;\s*$/,'')+')');
let it=null,grp=null;
F.forEach(g=>(g.items||[]).forEach(i=>{ if(i.key==='disable_quick_search'){it=i;grp=g;} }));
if(!it){console.error('缺 disable_quick_search');process.exit(1);}
const bad=[];
if(!it.pkgs||it.pkgs.length!==1||it.pkgs[0]!=='com.heytap.quicksearchbox')bad.push('pkgs');
if(it.subGroup!=='屏幕服务')bad.push('subGroup');
if(it.subGroupKey!=='disable_screen_services')bad.push('subGroupKey');
if(!/com\.heytap\.quicksearchbox:missing/.test(it.verifyCmd||''))bad.push('verifyCmd 缺 missing');
if(!/package:com\.heytap\.quicksearchbox/.test(it.checkCmd||''))bad.push('checkCmd');
if(bad.length){console.error(bad.join(','));process.exit(1);}
process.exit(0);" && ok "FEATURES 含 disable_quick_search（屏幕服务/同源 subGroupKey/三态 verifyCmd）" || no "FEATURES 新项结构不符"
grep -q "^disable_quick_search|com.heytap.quicksearchbox$" $SRC/service.sh && ok "service.sh PKG_TABLE 有 disable_quick_search 行" || no "PKG_TABLE 缺行"
[ "$(grep -c 'disable_quick_search' $SRC/service.sh)" -ge 3 ] && ok "disable_quick_search 已入 ALL_KEYS×2 + KEEP_KEYS" || no "service.sh 引用数=$(grep -c 'disable_quick_search' $SRC/service.sh)"
grep -q "com.heytap.quicksearchbox" $SRC/uninstall.sh && ok "uninstall.sh 回滚清单含新包" || no "uninstall.sh 缺新包"

# ---- 需求3 补充：调试面板/详情 的三态（启用/未启用/未安装）----
IDX2=$SRC/webroot/index.html
PST=$(sed -n '/pkgStateText: function/,/^    },/p' $IDX2)
echo "$PST" | grep -q "s === 'missing') return '未安装'" && ok "详情弹窗 pkgStateText 有「未安装」第三态" || no "pkgStateText 仍缺未安装"
echo "$PST" | grep -q "return '未知';" && ok "pkgStateText 保留未知兜底" || no "pkgStateText 丢了未知兜底"
grep -q "📥 已卸载（" $IDX2 && ok "调试面板有「已卸载」独立状态" || no "调试面板缺已卸载状态"
grep -q "另有未安装 " $IDX2 && ok "调试面板部分卸载显示 n/N" || no "缺部分卸载提示"
grep -q "INSTALL:" $IDX2 && ok "调试面板新增 INSTALL 逐包检查行" || no "缺 INSTALL 检查行"
grep -q "= 未安装'" $IDX2 && ok "INSTALL 行逐包标注未安装" || no "INSTALL 行未标未安装"
grep -q "| install: " $IDX2 && ok "copyDebugInfo 导出含安装态" || no "copyDebugInfo 未含安装态"
node -e "const h=require('fs').readFileSync('$IDX2','utf8');const a=h.indexOf('📥 已卸载');const b=h.indexOf('statusText = st.enabled ?');process.exit(a>0&&b>a?0:1);" && ok "三态判定顺序：卸载态先于二值兜底" || no "状态文案顺序错误";

echo "═══ F10. 加载进度条不动（v2.3.18）═══"
IDX3=$SRC/webroot/index.html
grep -q '<mdui-linear-progress :max="100" :value="progress"' $IDX3 && ok "linear-progress 显式声明 max=100" || no "缺 max=100"
grep -q '<mdui-linear-progress :value="progress"' $IDX3 && no "仍存在无 max 的 progress 绑定（会打满钉死）" || ok "无裸 :value=\"progress\" 绑定"
grep -q '<mdui-linear-progress' $IDX3 && ok "进度条元素存在" || no "进度条元素丢失"
# 公式复刻：mdui render = value / Math.max(max ?? value, value) * 100
node -e "
const w=(v,m)=>v/Math.max(m??v,v)*100;
const ok=[0,1,40,50,99,100].every(p=>Math.abs(w(p,100)-p)<1e-9);
const oldBuggy=w(40,1)===100;
process.exit((ok&&oldBuggy)?0:1);" && ok "公式复刻：max=100 时 width==progress；旧 max=1 确会打满" || no "进度条公式复刻不符"
grep -q '{{ progress }}%' $IDX3 && ok "百分比数字与条同量纲(progress 0..100)" || no "数字标签丢失"

echo "═══ F11. UI 四项修复（v2.3.18）═══"
IDX4=$SRC/webroot/index.html
# L2 之后：CSS 断言走 $CSS_ALL（分层文件），模板/JS 断言仍走 index.html

# ---- #2 守护进程1-7 / 性能优化2项 / 健康服务 的字体与折叠头(.agg-header)统一 ----
grep -q 'part(headline){font-size:15px;font-weight:500;line-height:1.3;color:rgb(var(--mdui-color-on-surface))}' $CSS_ALL \
  && ok "【#2】list-item headline 钉为 15px/500/on-surface" || no "【#2】list-item headline 排版未钉死"
grep -q '^\.agg-title-main{font-size:15px;font-weight:500;color:rgb(var(--mdui-color-on-surface))' $CSS_ALL \
  && ok "【#2】agg-title-main 同为 15px/500/on-surface（color 已包 rgb）" || no "【#2】agg-title-main 不匹配或 color 仍是裸 var"
grep -q 'part(description){font-size:12px;font-weight:400' $CSS_ALL \
  && ok "【#2】副标题 12px/400 显式钉死" || no "【#2】副标题未显式钉死"
node -e '
const fs=require("fs");
const h=process.argv.slice(1).map(f=>fs.readFileSync(f,"utf8")).join("\n");
const g=s=>{const a=(s||"").match(/font-size:[^;]+/),b=(s||"").match(/font-weight:[^;]+/),c=(s||"").match(/color:[^;]+/);
            return [a&&a[0],b&&b[0],c&&c[0]].map(x=>(x||"").replace(/\s/g,"")).join("|");};
const hl=(h.match(/part\(headline\)\{([^}]*)\}/)||[])[1];
const ag=(h.match(/\.agg-title-main\{([^}]*)\}/)||[])[1];
const A=g(hl),B=g(ag);
process.exit((hl&&ag&&A===B&&A.indexOf("rgb(var(")>=0)?0:1);' $CSS_ALL \
  && ok "【#2】两条路径标题的字号/字重/颜色三要素逐字相同" || no "【#2】标题三要素仍不一致"

# ---- #3 遥测警告文字顶出琥珀色框 ----
grep -q '^\.agg-dep-warn>span{[^}]*min-width:0' $CSS_ALL \
  && ok "【#3】警告 span 有 min-width:0（flex item 允许收缩）" || no "【#3】缺 min-width:0"
grep -q '^\.agg-dep-warn>span{[^}]*overflow-wrap:anywhere' $CSS_ALL \
  && ok "【#3】警告 span 强制断词 overflow-wrap:anywhere" || no "【#3】缺 overflow-wrap:anywhere"
grep -q '^\.agg-dep-warn{[^}]*white-space:normal' $CSS_ALL \
  && ok "【#3】警告容器 white-space:normal" || no "【#3】容器缺 white-space:normal"
node -e '
const fs=require("fs");
const h=process.argv.slice(1).map(f=>fs.readFileSync(f,"utf8")).join("\n");
const line=h.split("\n").filter(l=>l.indexOf("deps:")>=0&&l.indexOf("mydevices")>=0)[0];
const chain=line?(line.match(/[\w.\/-]{40,}/)||[]):[];
const css=(h.match(/\.agg-dep-warn>span\{[^}]*\}/)||[""])[0];
const fixed=/min-width:0/.test(css)&&/overflow-wrap:anywhere/.test(css);
process.exit((chain.length&&chain[0].length>=40&&fixed)?0:1);' "$IDX4" $CSS_ALL \
  && ok "【#3】deps 含 ≥40 字符连写 token，且 CSS 具备收缩+断词能力" || no "【#3】溢出根因或修复任一缺失"

# ---- #4a 【v2.3.20】"检查更新"已按需求整体移除 ----
#   理由：KernelSU 管理器自带更新检测（读 module.prop 的 updateJson），WebUI 不再重复实现，
#        多一份实现 = 多一个维护点。此断言防将来又加回来。
node -e '
const h=require("fs").readFileSync(process.argv[1],"utf8");
const btn=h.indexOf("@click=\"checkUpdate()\"")>=0;
const meth=/checkUpdate\s*:\s*function/.test(h);
// 只认真实拉取命令，忽略我写的说明性注释
const curl=/raw\.githubusercontent\.com[^\n]*update\.json/.test(h);
if(btn||meth||curl){process.stderr.write("残留 btn="+btn+" meth="+meth+" curl="+curl+"\n");process.exit(1);}
process.exit(0);' "$IDX4" \
  && ok "【#4a】检查更新已彻底移除（无按钮/无方法/无远程拉取）" \
  || no "【#4a】检查更新仍有残留"

# ---- #4a2 按钮区留白（承接原 #4a 的「贴标题」回归防护）----
node -e '
const h=require("fs").readFileSync(process.argv[1],"utf8");
const i=h.indexOf("@click=\"saveLog()\"");
if(i<0) process.exit(1);
const before=h.slice(Math.max(0,i-600),i);
const pad=(before.match(/perf-actions[^>]*style="padding:(\d+)px/)||[])[1];
const hdr=before.lastIndexOf("about-crt-header");
process.exit((pad!==undefined&&parseInt(pad,10)>0&&hdr>=0)?0:1);' "$IDX4" \
  && ok "【#4a2】按钮区上方留白 >0（不再贴标题条）" || no "【#4a2】按钮区仍贴标题"

# ---- #4b 更新提示框底色/文字色（裸 var() 整条声明被丢弃 → 透明） ----
node -e '
const fs=require("fs");
const h=process.argv.slice(1).map(f=>fs.readFileSync(f,"utf8")).join("\n");
const bad=[];
const t=(h.match(/\.toast\{[\s\S]*?\n\}/)||[])[0];
if(!t) bad.push("缺 .toast 规则");
else if(/background:\s*var\(--mdui-color-/.test(t)) bad.push(".toast 底色仍是裸 var");
else if(!/background:rgb\(var\(--mdui-color-surface-container-high\)\)/.test(t)) bad.push(".toast 底色未用 rgb()");
if(!/^\.toast-info\{background:rgb\(var\(--mdui-color-surface-container-high\)\)\}/m.test(h)) bad.push(".toast-info 底色未修");
if(!/\.toast-msg\{[^}]*color:rgb\(var\(--mdui-color-on-surface\)\)/.test(h)) bad.push(".toast-msg 文字色未修");
if(!/\.toast-sub\{[^}]*color:rgb\(var\(--mdui-color-on-surface-variant\)\)/.test(h)) bad.push(".toast-sub 文字色未修");
if(bad.length){console.error(bad.join("; "));process.exit(1);}
process.exit(0);' $CSS_ALL \
  && ok "【#4b】更新提示框底色 + 文字色全部 rgb(var())" || no "【#4b】提示框配色仍有裸 var"

echo "═══ F12. L2 CSS 分层拆分 ═══"
# 五个分层文件必须存在且非空
for f in app.tokens.css app.base.css app.components.css app.pages.css app.theme.crt.css; do
  [ -s "$AST/$f" ] && ok "分层文件存在且非空：$f" || no "缺分层文件：$f"
done
# index.html 不得再残留 <style>
grep -q '<style' $IDX4 && no "index.html 仍残留 <style> 块" || ok "index.html 已无 <style> 块"
# 5 条 <link> 必须齐全且顺序正确
node -e '
const h=require("fs").readFileSync(process.argv[1],"utf8");
const order=["app.tokens.css","app.base.css","app.components.css","app.pages.css","app.theme.crt.css"];
const idx=order.map(n=>h.indexOf("./assets/"+n));
if(idx.some(i=>i<0)){console.error("缺 link:",order.filter((n,i)=>idx[i]<0).join(","));process.exit(1);}
const sorted=[...idx].every((v,i)=>i===0||v>idx[i-1]);
if(!sorted){console.error("link 顺序错误:",idx.join(","));process.exit(1);}
process.exit(0);' "$IDX4" \
  && ok "5 条 <link> 齐全且顺序 tokens→base→components→pages→theme" || no "link 缺失或顺序错误"
# 分层后不得丢失任何类选择器（拆分时已做过一次逐字等价校验，L1/L3 会合法改写内容）
node -e '
const fs=require("fs");
const prev=fs.readFileSync(process.argv[1],"utf8");
const om=prev.match(/<style[^>]*>([\s\S]*?)<\/style>/);
if(!om){console.error("拿不到拆分前快照");process.exit(1);}
const origCls=new Set((om[1].match(/\.[a-z][\w-]*/gi)||[]));
let have=new Set();
for(const f of process.argv.slice(2)) have=have.union(new Set((fs.readFileSync(f,"utf8").match(/\.[a-z][\w-]*/gi)||[])));
const lost=[...origCls].filter(c=>!have.has(c));
if(lost.length){console.error("丢失类选择器("+lost.length+"):",lost.join(" "));process.exit(1);}
process.exit(0);' "$CI/prev_index.html" $CSS_BASE $CSS_COMP $CSS_PAGES $CSS_THEME \
  && ok "分层文件保留了拆分前的全部类选择器（无丢失）" || no "分层丢失了类选择器"
# 项目级 token 已落地
grep -q -- '--app-font-mono:' $CSS_TOK && ok "app.tokens.css 含 --app-font-mono" || no "tokens 缺 --app-font-mono"
grep -q -- '--app-font-ui:' $CSS_TOK && ok "app.tokens.css 含 --app-font-ui" || no "tokens 缺 --app-font-ui"
grep -q 'font-family:var(--app-font-ui)' $CSS_BASE && ok "body 字体栈已引用 token（不再硬编码）" || no "body 仍硬编码字体栈"

echo "═══ F13. L1 设计令牌落地 ═══"
# 裸 var(--mdui-color-*) 必须清零（token 值是三元组 → 裸用整条声明失效）
node -e '
const fs=require("fs");
let bad=0,cp=0;
for(const f of process.argv.slice(1)){
  let inC=false;
  fs.readFileSync(f,"utf8").split("\n").forEach((line,i)=>{
    let s=0,k=0,e=line.length;
    if(inC){const c=line.indexOf("*/"); if(c<0) return; inC=false; k=c+2; s=k;}
    while(k<=line.length-2){ if(line.slice(k,k+2)==="/*"){const c=line.indexOf("*/",k+2); if(c<0){e=k;inC=true;break;} k=c+2;continue;} k++; }
    if(e<=s) return;
    const code=line.slice(s,e);
    if(/^\s*--[a-z0-9-]+\s*:\s*var\(/.test(code)){cp++;return;}
    let m;const re=/([a-z-]+)(\s*:\s*)var\((--mdui-color-[a-z0-9-]+)\)/g;
    while((m=re.exec(code))){ if(!m[1].startsWith("--")){console.error("  ✗ "+f+" L"+(i+1)+" "+m[0]);bad++;} }
  });
}
console.error("  合法自定义属性赋值:",cp);
process.exit(bad?1:0);' $CSS_ALL $IDX4 \
  && ok "裸 var(--mdui-color-*) 残留 = 0（47 处已包 rgb()）" || no "仍有裸 var(--mdui-color-*)"
# 防回归：rgb(--mdui-color-x) 这种漏写 var() 的写法 —— rgb() 不接受标识符，同样整条失效
! grep -qE '(rgb|rgba)\(--mdui-color-' $CSS_ALL $IDX4 \
  && ok "无漏写 var() 的 rgb(--mdui-color-…)（该写法同样使声明失效）" || no "存在 rgb(--mdui-color-…) 漏写 var()"
# 字体栈字面量只能存在于 token 定义里
RAW=$(grep -l "JetBrains Mono" $CSS_ALL $IDX4 | grep -v "app.tokens.css" | tr '\n' ' ')
[ -z "$RAW" ] && ok "字体栈字面量只存在于 app.tokens.css 定义处" || no "别处仍硬编码字体栈：$RAW"
grep -q -- "--app-font-mono:" $CSS_TOK && grep -q -- "--app-font-mono-wide:" $CSS_TOK \
  && ok "tokens 含 mono / mono-wide 两个字体栈" || no "tokens 缺字体栈定义"
NC=$(grep -c "var(--app-font-" $CSS_ALL $IDX4 | awk -F: '{s+=$NF} END{print s}')
[ "$NC" -ge 20 ] && ok "token 引用点 $NC 处（>=20）" || no "token 引用点仅 $NC 处"

echo "═══ F14. CRT 主题可切换（v2.3.19）═══"
# 默认主题写在 <html> 上，历史观感零变化
grep -q '<html lang="zh-CN" data-theme="crt">' $IDX4 \
  && ok "html 默认 data-theme=\"crt\"（与历史版本观感一致）" || no "缺少默认 data-theme"
# 防 FOUC：主题脚本必须排在样式表之前
node -e '
const s=require("fs").readFileSync(process.argv[1],"utf8");
const a=s.indexOf("dataset.theme=localStorage.getItem");
const b=s.indexOf("app.tokens.css");
if(a<0){console.error("找不到主题预设脚本");process.exit(1);}
if(b<0){console.error("找不到样式表");process.exit(1);}
process.exit(a<b?0:1);' "$IDX4" \
  && ok "主题预设脚本位于样式表之前（无 FOUC）" || no "主题脚本未在样式表之前执行"
grep -q 'toggleTheme: function' "$IDX4" && ok "含 toggleTheme 方法" || no "缺 toggleTheme 方法"
grep -q "localStorage.setItem('logd_theme'" "$IDX4" && ok "主题写入 localStorage 持久化" || no "主题未持久化"
grep -q '@click="toggleTheme"' "$IDX4" && ok "顶栏有主题切换入口" || no "缺主题切换入口"
grep -q "catch(e){document.documentElement.dataset.theme='crt'}" "$IDX4" \
  && ok "localStorage 不可用时兜底 crt" || no "缺 localStorage 兜底"
# 主题层每条规则必须挂前缀（@keyframes 无选择器，豁免）
node -e '
const fs=require("fs");
let t=fs.readFileSync(process.argv[1],"utf8"),i=0,out="";
while(i<t.length){const k=t.indexOf("@keyframes",i);if(k<0){out+=t.slice(i);break;}out+=t.slice(i,k);
  let j=t.indexOf("{",k),d=1;j++;while(j<t.length&&d>0){if(t[j]==="{")d++;else if(t[j]==="}")d--;j++;}i=j;}
out=out.replace(/\/\*[\s\S]*?\*\//g,"");
const bad=[];
out.split("}").forEach(b=>{const s=b.split("{")[0].trim();if(s&&!/data-theme="crt"/.test(s))bad.push(s);});
if(bad.length){console.error("未挂前缀("+bad.length+"):",bad.join(" | "));process.exit(1);}
process.exit(0);' "$CSS_THEME" \
  && ok "主题层全部规则都带 [data-theme=\"crt\"] 前缀" || no "主题层存在未挂前缀的规则"
grep -q 'html:not(\[data-theme="crt"\]) .gh-crt-lights{display:none}' "$CSS_THEME" \
  && ok "关主题时显式隐藏机箱灯组（不留零宽占位）" || no "缺关主题兜底隐藏"
# 中性基线必须留在非主题层，否则关主题会退化成零样式
grep -q '^\.crt-scanlines{' "$CSS_COMP" && grep -q '^\.progress-crt{' "$CSS_COMP" && grep -q '^\.progress-pct{' "$CSS_COMP" \
  && ok "中性基线(.crt-scanlines/.progress-crt/.progress-pct) 在组件层" || no "中性基线缺失"
grep -q '^\.log-box{' "$CSS_PAGES" && grep -q '^\.perf-table{' "$CSS_PAGES" \
  && ok "日志框/性能表中性基线在页面层" || no "页面层基线缺失"
# 模板上 retro 类必须与基线类成对（成对才可回落）
grep -q 'class="log-box log-box-retro"' "$IDX4" && grep -q 'class="perf-table perf-table-retro"' "$IDX4" \
  && ok "模板 retro 类与基线类成对（log-box / perf-table）" || no "模板 retro 类未成对"

echo "═══ F15. CSS 可被解析器正常解析（防「吞尾」回归）═══"
# 背景：之前 3 处少写一个 )，浏览器在未闭合的函数里会把 } 当普通 token 吃掉，
# 该块永不会结束 → 之后到文件尾的规则整片失效；而 grep 只看文本、文本还在，
# 所以 179 项断言全绿却照样翻车。这里用「括号感知」的解析器复现浏览器行为。
node -e '
const fs=require("fs");
function check(src){
  const s=src.replace(/\/\*[\s\S]*?\*\//g,m=>" ".repeat(m.length));
  const st=[]; const errs=[]; let line=1;
  for(let i=0;i<s.length;i++){ const c=s[i];
    if(c==="\n"){line++;continue;}
    if(c==="(")st.push({t:"(",line});
    else if(c==="{")st.push({t:"{",line});
    else if(c===")"){ if(st.length&&st[st.length-1].t==="(")st.pop(); else errs.push("L"+line+" 多余 )"); }
    else if(c==="}"){ if(!st.length)errs.push("L"+line+" 多余 }");
      else if(st[st.length-1].t==="{")st.pop();
      else errs.push("L"+line+" } 被未闭合 ( 吞掉 → 后续规则整片失效"); }
  }
  st.forEach(x=>errs.push("L"+x.line+" 的 "+x.t+" 未闭合"));
  return errs;
}
let bad=0;
for(const f of process.argv.slice(1)){
  const e=check(fs.readFileSync(f,"utf8"));
  if(e.length){ console.error("  ✗ "+f.split("/").pop()+" → "+e.join("; ")); bad++; }
}
process.exit(bad?1:0);' $CSS_ALL \
  && ok "5 层 CSS 括号配平、无「吞尾」（浏览器可正常解析）" || no "存在会被浏览器吞掉的 CSS"
# 被吞掉的那片规则必须真实存在且可解析（性能页 + 个人页）
node -e '
const fs=require("fs");
function rules(css){
  const s=css.replace(/\/\*[\s\S]*?\*\//g,m=>" ".repeat(m.length));
  const set=new Set(); let i=0;
  while(i<s.length){ const o=s.indexOf("{",i); if(o<0)break;
    const sel=s.slice(i,o).trim(); let d=1,j=o+1;
    while(j<s.length&&d>0){ if(s[j]==="{")d++; else if(s[j]==="}")d--; j++; }
    if(sel&&!sel.startsWith("@")) sel.split(",").forEach(x=>set.add(x.trim().replace(/^\[data-theme="crt"\]\s*/,"")));
    i=j; }
  return set;
}
const set=new Set();
for(const f of process.argv.slice(1)) rules(fs.readFileSync(f,"utf8")).forEach(x=>set.add(x));
const need=[".perf-tips",".perf-actions",".perf-table-wrap",".perf-table",".perf-sub",".perf-note",".perf-empty",
            ".delta-good",".delta-bad",".delta-none",
            ".gh-card",".gh-profile",".gh-avatar-wrap",".gh-avatar",".gh-name",".gh-bio",".gh-cmd",".gh-crt",
            ".tip-row b",".hidden"];
const miss=need.filter(r=>!set.has(r));
if(miss.length){ console.error("  缺失("+miss.length+"):",miss.join(" ")); process.exit(1); }
process.exit(0);' $CSS_ALL \
  && ok "性能页/个人页被吞的 20 条规则已全部恢复可解析" || no "仍有规则被吞未恢复"

echo "═══ F16. WebUI 页面严格自查（沙箱执行 + 逐项对撞）═══"
# 这是 F1-F15 的补盲：前面大多是 grep 文本匹配，查不出
# 「文本在、但浏览器/Vue 解析时不认」的问题（实测踩过：少一个 ) 就让整片规则作废）。
node "$CI/audit_webui.js" > "$T/aw.out" 2>&1 || true
grep "❌" "$T/aw.out" > "$T/aw.bad" || true
if [ -s "$T/aw.bad" ]; then
  while IFS= read -r l; do no "自查: ${l#*❌ }"; done < "$T/aw.bad"
else
  ok "WebUI 自查通过（Vue绑定/标签配平/class交叉/CSS值/重复规则/孤儿规则）"
fi
AWP=$(grep -c "✅" "$T/aw.out" || true)
[ "$AWP" -ge 6 ] && ok "审查器自身跑出 $AWP 项 ✅（≥6，防止审查器被误删）" || no "审查器输出异常（$AWP 项）"

echo "═══ F17. CRT 开机门禁（gate骨架/三重放行/层级/配色 防回归）═══"
IDX5=$SRC/webroot/index.html
CSSB=$SRC/webroot/assets/app.components.css
# 1) gate 全屏层由 !bootDone 控制：丢了 → 主界面裸奔；失控 true → 永远进不去
grep -q 'class="crt-boot" v-if="!bootDone"' $IDX5 && ok "gate 层存在且 v-if=!bootDone" || no "gate 层丢失或失控"
# 2) z-index 须 ≥3000：guide-overlay=3000、bottom-nav=200，太小会被引导层/底栏盖穿
ZI=$(grep -o 'crt-boot{[^}]*z-index:[0-9]*' $CSSB | grep -o '[0-9]*$' | head -1)
if [ -n "$ZI" ] && [ "$ZI" -ge 3000 ]; then ok "gate z-index=$ZI ≥3000（盖住引导层/底栏）"; else no "gate z-index 不足或缺失 (=$ZI)"; fi
# 3) 放行点 ≥4：正常完成/15s超时/.catch兜底/SKIP，少一个就存在卡死开机画面的路径
NT=$(grep -c 'bootDone = true' $IDX5)
[ "$NT" -ge 4 ] && ok "放行点 ≥4 处 (=$NT)" || no "放行点不足 (=$NT，期望≥4：完成/超时/catch/skip)"
# 4) refreshAll 链尾 .catch 必须兜底放行（否则检测抛错 = 永久卡 gate）
grep -A3 '})\.catch(function(e) {' $IDX5 | grep -q 'bootDone = true' && ok "检测链 .catch 异常兜底放行" || no "缺 .catch 放行兜底"
# 5) 15s 超时强制放行（正常检测约 8s；慢机/卡死兜底）
grep -B3 '}, 15000);' $IDX5 | grep -q 'bootDone = true' && ok "15s 超时强制放行" || no "缺 15s 超时兜底"
# 6) SKIP 按钮与方法配对（防只删一半留下死按钮）
grep -q '@click="skipBoot()"' $IDX5 && grep -q 'skipBoot: function' $IDX5 && ok "SKIP 按钮与 skipBoot 方法配对" || no "SKIP 按钮或方法缺失"
# 7) gate 自绘进度条：mdui 内部色不可控，Symbiote 配色全靠 track/fill
grep -Fq ':style="{ width: progress +' $IDX5 && grep -q 'crt-boot-fill' $CSSB && ok "gate 自绘进度条 track/fill 在位" || no "gate 自绘进度条丢失"
# 8) Symbiote 关键色防回退（屏底紫黑 #0f0918 + Strange Pink #ee8fc4）
grep -q '#0f0918' $CSSB && grep -q '#ee8fc4' $CSSB && ok "Symbiote 紫黑底/Strange Pink 在位" || no "Symbiote 配色被回退"

echo "═══ F18. 三种列表渲染统一为聚合头视觉 + 重启标签不回加 ═══"
IDX6=$SRC/webroot/index.html
# 1) A 单项功能 / B 单包聚合已改用 C 聚合头结构：两容器必须都在（改回 mdui-list-item 必先删容器）
AGPL=$(grep -c 'class="agg-list-plain"' $IDX6)
[ "$AGPL" -ge 2 ] && ok "A/B 聚合头容器 agg-list-plain ×$AGPL" || no "agg-list-plain 丢失 (=$AGPL，疑似改回 list-item)"
# 2) 「重启后生效」标签已删：模板/组件CSS/分层基线三处均不得回加（基线漏改会假红）
RH=$(grep -l 'reboot-hint' $IDX6 $SRC/webroot/assets/app.base.css $SRC/.ci/prev_index.html 2>/dev/null | wc -l)
[ "$RH" -eq 0 ] && ok "reboot-hint 三处均为 0（标签已删不回加）" || no "reboot-hint 回加到 $RH 个文件"

echo "═══ F19. SYSTEM CONFIG 真机信息动态读取（防写死回退）═══"
IDXS=$SRC/webroot/index.html
# 1) 动态绑定在位：模板读 {{ devName }}/{{ devSystem }}，丢了就退回静态显示
grep -q '{{ devName }}' $IDXS && grep -q '{{ devSystem }}' $IDXS && ok "DEVICE/SYSTEM 动态绑定在位" || no "动态绑定丢失（回退静态？）"
# 2) 历史写死值不得回潮（改码时若图省事写回常量即红）
grep -qE '>OnePlus Ace5<|>ColorOS 16<' $IDXS && no "SYSTEM CONFIG 出现写死设备值" || ok "无写死设备值"
# 3) getprop 读取链 + 10 机型映射表（映射被清则未知型号显示成 brand+model）
grep -q 'echo "model=\$(getprop ro.product.model)"' $IDXS && grep -q 'PKG110' $IDXS && ok "getprop 读取链 + 机型映射表在位" || no "读取链或映射表丢失"

echo "════════ 结果：$P 通过 / $F 失败 ════════"
[ "$F" = "0" ] && echo "🎉 全部通过" || echo "⚠️ 有失败项"
exit $F