const fs=require('fs');
const D=require('path').join(require('os').tmpdir(),'audit11_dev')+require('path').sep;
const SRC=require('path').resolve(__dirname,'..');
// 设备快照缺失时给出明确失败（不静默跳过 —— 静默跳过 = 假通过）
for(const _f of ['config.json','state.json','disabled.txt','all.txt']){
  if(!fs.existsSync(D+_f)){
    console.log('  ❌ 缺设备快照: '+D+_f);
    console.log('     生成方法（在有 su 的设备上）: su -c "cat /data/adb/Logd_Disabler_ColorOS16/config.json" > '+D+'config.json');
    process.exit(1);
  }
}
// 设备快照缺失时给出明确失败（不静默跳过 —— 静默跳过 = 假通过）
for(const _f of ['config.json','state.json','disabled.txt','all.txt']){
  if(!fs.existsSync(D+_f)){
    console.log('  ❌ 缺设备快照: '+D+_f);
    console.log('     生成方法（在有 su 的设备上）: su -c "cat /data/adb/Logd_Disabler_ColorOS16/config.json" > '+D+'config.json');
    process.exit(1);
  }
}
// 设备快照缺失时给出明确失败（不静默跳过 —— 静默跳过 = 假通过）
for(const _f of ['config.json','state.json','disabled.txt','all.txt']){
  if(!fs.existsSync(D+_f)){
    console.log('  ❌ 缺设备快照: '+D+_f);
    console.log('     生成方法（在有 su 的设备上）: su -c "cat /data/adb/Logd_Disabler_ColorOS16/config.json" > '+D+'config.json');
    process.exit(1);
  }
}
const cfg=JSON.parse(fs.readFileSync(D+'config.json','utf8'));
let raw=fs.readFileSync(D+'state.json','utf8');
const st=raw.trim()?JSON.parse(raw):{};
const disabled=new Set(fs.readFileSync(D+'disabled.txt','utf8').split('\n').filter(Boolean));
const all=new Set(fs.readFileSync(D+'all.txt','utf8').split('\n').filter(Boolean));
const h=fs.readFileSync(SRC+'/webroot/index.html','utf8');
const s0=h.indexOf('var FEATURES = ['),e0=h.indexOf('\n];',s0);
const F=eval('('+h.slice(s0,e0+3).replace(/^var FEATURES = /,'').replace(/;\s*$/,'')+')');
let P=0,Fa=[];const ok=m=>{P++;console.log('  ✅ '+m)};const no=m=>{Fa.push(m);console.log('  ❌ '+m)};

console.log('═══ 1. 意图(config+keep) vs 真机 pm —— 逐包 1:1 ═══');
let tot=0, mismatch=[];
F.forEach(g=>(g.items||[]).forEach(i=>{
  if(!i.pkgs||!i.pkgs.length) return;
  const on = cfg[i.key]===true;
  const keep=String(cfg[i.key+'_keep']||'').split(',').filter(Boolean);
  i.pkgs.forEach(p=>{
    if(!all.has(p)) return;              // 未安装跳过
    tot++;
    const expect = on && !keep.includes(p);
    const real   = disabled.has(p);
    if(expect!==real) mismatch.push(`${i.key} / ${p}: 期望${expect?'禁用':'启用'} 实际${real?'禁用':'启用'}`);
  });
}));
mismatch.length? mismatch.forEach(m=>no(m)) : ok(`覆盖 ${tot} 个已安装包，意图与真机状态 0 分歧`);
console.log(`     （另有 ${[...disabled].length} 个系统已禁用包不在本模块管理范围）`);

console.log('═══ 2. WebUI pkgStates vs 真机 pm（UI 是否说真话）═══');
let uiM=[], uiN=0;
const ps=st.pkgStates||{};
Object.keys(ps).forEach(k=>Object.keys(ps[k]).forEach(p=>{
  if(!all.has(p)) { if(ps[k][p]!=='missing') uiM.push(`${k}/${p} 真机未安装但 UI 记 ${ps[k][p]}`); return; }
  uiN++;
  const real = disabled.has(p)?'disabled':'enabled';
  if(ps[k][p]!==real) uiM.push(`${k}/${p}: UI=${ps[k][p]} 真机=${real}`);
}));
uiM.length? uiM.forEach(m=>no(m)) : ok(`UI ${uiN} 条子包状态与真机完全一致`);

console.log('═══ 3. 屏幕服务（你复现的场景）语义核对 ═══');
const g=(k)=>cfg[k];
const sp=(k)=>Object.keys(ps[k]||{});
console.log('     config: disable_screen_services='+g('disable_screen_services')
  +'  截屏(disable_double_tap)='+g('disable_double_tap')
  +'  速览(disable_speedview)='+g('disable_speedview'));
const scrOk = ps.disable_screen_services && ps.disable_speedview && ps.disable_double_tap;
if(scrOk){
  const parentAll = Object.values(ps.disable_screen_services).every(v=>v==='disabled');
  const dj = ps.disable_double_tap['com.oplus.exsystemservice']==='disabled';
  const sv = Object.values(ps.disable_speedview).every(v=>v==='disabled');
  const expectParent = g('disable_screen_services')===true && parentAll;
  console.log('     一级「屏幕服务」显示 = '+(parentAll?'开':'关')+'  ← '+(parentAll?'全禁才开':'有包未禁 → 必须显示关'));
  console.log('     二级「截屏」显示 = '+(dj?'开':'关')+'   二级「速览」显示 = '+(sv?'开':'关'));
  const cond = !parentAll && !dj && sv;   // 规格3：下层任一不符 → 一级必须关
  cond? ok('规格3 成立：截屏未禁 → 一级显示关；速览仍禁 → 二级开（编组只显示不改意图）')
      : no('规格3 不成立: parentAll='+parentAll+' 截屏禁='+dj+' 速览禁='+sv);
}

console.log('═══ 4. 脏数据 / 孤儿键检查 ═══');
const fkeys=new Set(), sub=new Set();
F.forEach(g2=>(g2.items||[]).forEach(i=>{fkeys.add(i.key); if(i.subGroupKey)sub.add(i.subGroupKey);}));
const orphan=Object.keys(cfg).filter(k=>k!=='version'&&!fkeys.has(k)&&!sub.has(k)&&!k.endsWith('_keep'));
orphan.length? no('config 孤儿键（WebUI 无此开关）: '+orphan.join(', ')) : ok('config 无孤儿键');
const dirty=[];
Object.keys(cfg).forEach(k=>{
  if(!k.endsWith('_keep'))return;
  const base=k.replace(/_keep$/,'');
  const item=F.flatMap(g2=>g2.items||[]).find(i=>i.key===base);
  if(!item)return;
  String(cfg[k]||'').split(',').filter(Boolean).forEach(p=>{
    if(!item.pkgs.includes(p)) dirty.push(`${k} 里有非本组包 ${p}`);
  });
});
dirty.length? no('跨组白名单脏数据: '+dirty.join('; ')) : ok('所有 _keep 都只含本组包');
Object.keys(cfg).forEach(k=>{
  if(!k.endsWith('_keep'))return;
  const base=k.replace(/_keep$/,'');
  if(String(cfg[k]).trim()==='' && fkeys.has(base) && !Object.keys(cfg).includes(base)) no(base+' 有 keep 却无主键');
});

console.log('═══ 5. serviceReady / 期望 vs 实际告警 ═══');
(st.serviceReady===true)? ok('serviceReady=true（service.sh 已跑完）') : no('serviceReady='+st.serviceReady);
(st.t)? ok('状态快照时间 '+new Date(st.t).toLocaleString('zh-CN')) : no('缺时间戳');

console.log(`\n═══ 汇总: ${P} 通过 / ${Fa.length} 失败 ═══`);
process.exit(Fa.length?1:0);
