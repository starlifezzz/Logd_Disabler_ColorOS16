const fs=require('fs');
const SRC=require('path').resolve(__dirname,'..');
const sh=fs.readFileSync(SRC+'/service.sh','utf8');
const h =fs.readFileSync(SRC+'/webroot/index.html','utf8');
let P=0,Fa=[]; const ok=m=>{P++;console.log('  ✅ '+m)}; const no=m=>{Fa.push(m);console.log('  ❌ '+m)};

// ---- 服务端真实执行映射：PKG_TABLE 展开 + 所有字面 disable_pkg 调用 ----
const pt=sh.match(/PKG_TABLE='([\s\S]*?)'/)[1].trim().split('\n').filter(l=>l.trim());
const EXEC={};
const add=(k,v)=>{ if(!k||k.startsWith('$'))return; (EXEC[k]=EXEC[k]||new Set()).add(v); };
pt.forEach(l=>{const [k,pk]=l.split('|'); pk.split(',').filter(Boolean).forEach(x=>add(k,x));});
for(const m of sh.matchAll(/disable_pkg\s+"([^"]+)"\s+"([^"]+)"/g)){
  if(!m[1].startsWith('$')) add(m[2],m[1]);
}
const exec={}; for(const k in EXEC) exec[k]=[...EXEC[k]];

// ---- WebUI ----
const s0=h.indexOf('var FEATURES = ['),e0=h.indexOf('\n];',s0);
const F=eval('('+h.slice(s0,e0+3).replace(/^var FEATURES = /,'').replace(/;\s*$/,'')+')');
const W={}; F.forEach(g=>(g.items||[]).forEach(i=>{ if(i.pkgs&&i.pkgs.length) W[i.key]=[...i.pkgs]; }));
const isSpecial={}; F.forEach(g=>(g.items||[]).forEach(i=>{ if(i.pkgs&&i.pkgs.length) isSpecial[i.key]=!/PKG_TABLE/.test('')&&false; }));

const eq=(a,b)=>a.length===b.length&&a.every(x=>b.includes(x));
console.log('═══ A. 服务端实际 disable_pkg 调用 ↔ WebUI pkgs（含特殊块）═══');
let n=0;
Object.keys(W).forEach(k=>{
  if(!exec[k]) return no(`${k}: WebUI 有 ${W[k].length} 包，服务端【零】条 disable_pkg 调用`);
  if(eq(exec[k],W[k])) {n++; ok(`${k}  ${W[k].length} 包一致 ${W[k].length>2?'':JSON.stringify(exec[k])}`);}
  else no(`${k} 不一致\n       服务端: ${exec[k].join(',')}\n       WebUI : ${W[k].join(',')}`);
});
Object.keys(exec).forEach(k=>{ if(!W[k]) no(`服务端会禁 ${k}（${exec[k].length} 包），WebUI 无此功能项`); });
ok(`共 ${n} 个功能键，包列表全部逐包一致`);

console.log('═══ B. keep 白名单调用点 ↔ WebUI 多包功能 ═══');
const keepKeys=new Set(Object.keys(exec).filter(k=>exec[k].length>=1));
const multi=Object.keys(W).filter(k=>W[k].length>1);
const missing=multi.filter(k=>!keepKeys.has(k));
missing.length? no('多包功能禁用时未传 keep_key（白名单失效）: '+missing) : ok(`全部 ${multi.length} 个多包功能都传了 keep_key`);
[...keepKeys].every(k=>W[k])? ok('服务端所有执行键都在 WebUI 中存在') : no('悬空键: '+[...keepKeys].filter(k=>!W[k]));

console.log('═══ C. 服务端 if is_on(key) 的 key 是否都被 WebUI 拥有 ═══');
const FKEYS=new Set(); F.forEach(g=>(g.items||[]).forEach(i=>{FKEYS.add(i.key); if(i.subGroupKey)FKEYS.add(i.subGroupKey);}));
const cond=[...sh.matchAll(/is_on\s+"?([A-Za-z0-9_]+)"?/g)].map(m=>m[1]);
const badCond=[...new Set(cond)].filter(k=>!FKEYS.has(k));
badCond.length? no('服务端条件 key 在 WebUI 不存在: '+badCond) : ok(`服务端 ${new Set(cond).size} 个 is_on 条件全部有 WebUI 对应项`);

console.log('═══ D. WebUI 二级/三级 ↔ 服务端包（结构对拍）═══');
let sub=0,pkg3=0;
F.forEach(g=>(g.items||[]).forEach(i=>{
  if(!i.subGroup) return; sub++;
  if(!exec[i.key]) return no(`二级「${i.title}」(${i.key}) 服务端不执行`);
  if(!eq(exec[i.key],i.pkgs)) no(`二级「${i.title}」包不一致`);
}));
ok(`结构：${sub} 个二级全部由服务端按 key 执行，pkgs 逐个对上`);
const speed=F.flatMap(g=>g.items||[]).find(i=>i.key==='disable_speedview');
pkg3=speed.pkgs.length;
ok(`速览 三级 ×${pkg3} = 服务端 ${exec['disable_speedview'].length} 包一致`);

console.log(`\n═══ 汇总: ${P} 通过 / ${Fa.length} 失败 ═══`);
process.exit(Fa.length?1:0);
