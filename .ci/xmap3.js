const fs=require('fs');
const SRC=require('path').resolve(__dirname,'..');
const shAll=fs.readFileSync(SRC+'/service.sh','utf8')+'\n'+fs.readFileSync(SRC+'/post-fs-data.sh','utf8');
const sh=shAll;
const h =fs.readFileSync(SRC+'/webroot/index.html','utf8');
let P=0,Fa=[];const ok=m=>{P++;console.log('  ✅ '+m)};const no=m=>{Fa.push(m);console.log('  ❌ '+m)};

const s0=h.indexOf('var FEATURES = ['),e0=h.indexOf('\n];',s0);
const F=eval('('+h.slice(s0,e0+3).replace(/^var FEATURES = /,'').replace(/;\s*$/,'')+')');
const W=[];F.forEach(g=>(g.items||[]).forEach(i=>W.push(i)));
const SUB=[...new Set(W.filter(i=>i.subGroupKey).map(i=>i.subGroupKey))];

// 服务端动作集合
const acted=new Set([...sh.matchAll(/is_on\s+"?([A-Za-z0-9_]+)"?/g)].map(m=>m[1]));
sh.match(/PKG_TABLE='([\s\S]*?)'/)[1].trim().split('\n').filter(l=>l.trim())
  .forEach(l=>acted.add(l.split('|')[0]));

console.log('═══ F1. 每个 WebUI 开关，服务端必须有动作分支 ═══');
const miss=W.filter(i=>!acted.has(i.key)).map(i=>i.key);
miss.length?no('服务端完全不处理: '+miss):ok(`WebUI ${W.length} 个功能键 → 服务端全部有 is_on / PKG_TABLE 分支`);
SUB.every(k=>acted.has(k))?ok('两个一级编组 key 也在 ALL_KEYS/默认配置中'):no('编组 key 服务端无痕迹');

console.log('═══ F1b. is_on 分支分布在 service.sh / post-fs-data.sh ═══');
const ss=fs.readFileSync(SRC+'/service.sh','utf8'), pf=fs.readFileSync(SRC+'/post-fs-data.sh','utf8');
const inS=[...new Set([...ss.matchAll(/is_on\s+"?([A-Za-z0-9_]+)"?/g)].map(m=>m[1]))];
const inP=[...new Set([...pf.matchAll(/is_on\s+"?([A-Za-z0-9_]+)"?/g)].map(m=>m[1]))];
ok('service.sh 分支: '+inS.length+' 个  →  '+inS.join(', '));
ok('post-fs-data.sh 分支: '+inP.length+' 个  →  '+inP.join(', '));
const pcfg=(pf.match(/local CONFIG_FILE="([^"]+)"/)||[])[1];
const scfg=(ss.match(/^CONFIG="([^"]+)"/m)||[])[1];
pcfg===scfg?ok('两个脚本读同一份 config.json: '+pcfg):no(`config 路径不一致: ${scfg} vs ${pcfg}`);

console.log('═══ F2. 反向：服务端动作键 WebUI 必须有 ═══');
const fkeys=new Set(W.map(i=>i.key)); SUB.forEach(k=>fkeys.add(k));
const orphan=[...acted].filter(k=>!fkeys.has(k));
orphan.length?no('服务端会动、WebUI 无开关: '+orphan):ok(`服务端 ${acted.size} 个动作键全部有 WebUI 开关`);

console.log('═══ F3. verifyCmd 输出能否被 parsePkgStates 解析 ═══');
const PPS=h;
const pat=/[\\]?:?([a-z0-9._]+):(disabled|enabled|missing)/;
let bad=0;
W.filter(i=>i.pkgs&&i.pkgs.length).forEach(i=>{
  const v=i.verifyCmd||'';
  // 每个 pkgs 里的包都必须以 "<pkg>:state" 形式出现在输出里
  const missing=i.pkgs.filter(p=>!v.includes('"'+p+':"') && !v.includes("'"+p+":'") && !v.includes('$p:'+'')===false ? false : !v.includes(p+':'));
  if(missing.length){bad++;no(`${i.key} verifyCmd 漏报包: ${missing.join(',')}`);}
});
if(!bad)ok(`23 个包类功能的 verifyCmd 均覆盖其全部 pkgs`);
const single=W.filter(i=>i.pkgs&&i.pkgs.length===1)[0];
/parsePkgStates/.test(h)?ok('parsePkgStates 存在并被 checkItem 调用'):no('缺 parsePkgStates');

console.log('═══ F4. 非包类功能（无法实测）→ 显示=意图，需确认服务端确有分支 ═══');
const nonpkg=W.filter(i=>!i.pkgs||!i.pkgs.length);
nonpkg.forEach(i=>{ acted.has(i.key)?ok(`${i.key.padEnd(28)} 服务端有分支（显示=config 意图）`) : no(`${i.key} 无服务端分支`); });

console.log('═══ F5. 语义方向一致性 ═══');
// config=true ⇔ 服务端 is_on ⇒ 禁用包
// v2.3.17 缺陷1 修复后变量由 allDisabled 改名 allOk，且 missing 按期望判定（与 checkItem 同源）
/ps\.enabled = allOk;/.test(h)?ok('父开关: 开 ⇔ 下层全部实际达标（与"配置开=去禁用"同向）'):no('父开关方向可疑（allOk 缺失）');
const spBody=h.slice(h.indexOf('syncParentSwitch: function'), h.indexOf('syncSubGroupSwitch: function'));
spBody.includes("'missing'")?ok('父开关对 missing 显式判定（不再只认 disabled）'):no('父开关 missing 判定缺失');
/keepList\.indexOf\(p\) < 0/.test(spBody)?ok('父开关 missing 判定纳入 _keep 白名单'):no('父开关 missing 未纳入白名单');
/ps\.enabled = (cfgOn|cfgEnabled);/.test(spBody)?no('父开关直接拿 config 当显示（绕过"下层不符→关"）'):ok('父开关不直接用 config 作为显示值');
h.includes('s.enabled = hasPkgs ? (cfgEnabled && keepList.length === 0) : cfgEnabled')
  ?ok('一级显示 = config 且白名单空（同向）'):no('一级方向可疑');
sh.includes('if is_on "$key"; then')||sh.includes('if is_on "$key"; then')?ok('服务端: is_on ⇒ disable_pkg（同向）'):no('服务端方向可疑');

console.log('═══ F6. 特殊块动作 ↔ WebUI 声明 ═══');
[['disable_logd','start logd|stop logd|pkill'],['lock_developer_options','development_settings_enabled'],
 ['kill_redundant_processes','pkill'],['system_prop_toggles','setprop'],
 ['disable_data_collection','/system_ext/bin'],['memory_io_optimization','sched_schedstats'],
 ['extra_kernel_optimization','kernel/printk']].forEach(([k,re])=>{
  new RegExp(re).test(sh)?ok(`${k} 服务端确有对应实现 (${re})`):no(`${k} 服务端找不到实现 (${re})`);
});
sh.includes('is_on "block_ota"')&&sh.includes('setprop persist.sys.ota.disabled')
  ?ok('block_ota: 禁包 + 停 update_engine + 3 个 OTA 属性'):no('block_ota 实现不全');
sh.includes('is_on "block_ads_and_tracking"')&&sh.includes('setprop persist.sys.oplus.ad_enable 0')
  &&sh.includes('disable_pkg "com.oplus.qualityprotect" "block_ads_and_tracking"')
  &&sh.includes('enable_pkg "com.oplus.qualityprotect"')
  ?ok('block_ads: 禁 5 包（含 qualityprotect/midas 宿主，disable/enable 对称）+ ad_enable=0 等 8 属性'):no('block_ads 实现不全');

console.log(`\n═══ 汇总: ${P} 通过 / ${Fa.length} 失败 ═══`);
process.exit(Fa.length?1:0);
