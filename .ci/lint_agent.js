const fs=require("fs");
const F=process.env.COLOROS_AGENT_MD
  || '/data/data/com.termux/files/home/.config/opencode/agents/coloros.md';
if(!fs.existsSync(F)){console.log('  ℹ 跳过：coloros.md 不在本机（'+F+'）');process.exit(0);}
const lines=fs.readFileSync(F,"utf8").split("\n");
let P=0,Fc=0;
const ok=m=>{console.log("  ✅ "+m);P++};
const no=m=>{console.log("  ❌ "+m);Fc++};

// 先算出哪些行在代码围栏内（语言感知：围栏内的 `# xxx` 是注释，不是标题）
const inCode=new Array(lines.length).fill(false);
{let open=-1;lines.forEach((l,i)=>{if(/^\s*```/.test(l)){if(open<0)open=i;else{for(let k=open;k<=i;k++)inCode[k]=true;open=-1;}}});}

// 1 frontmatter
if(lines[0]==="---"&&lines.slice(1,4).some(l=>l.startsWith("mode:"))) ok("frontmatter 完整且 mode 存在");
else no("frontmatter 缺失或异常");

// 2 围栏配对
let inF=false,fc=0;
lines.forEach(l=>{if(/^\s*```/.test(l)){fc++;inF=!inF;}});
fc%2===0?ok(`代码围栏配对（×${fc}）`):no(`围栏未配对 ×${fc}`);
inF?no("文件结束时仍在围栏内"):ok("文件结束时围栏已闭合");

// 3 表格：表头后必须紧跟分隔行（同样跳过代码块）
let tblBad=[],intbl=false;
for(let i=0;i<lines.length;i++){
  if(inCode[i]){intbl=false;continue;}
  const l=lines[i];
  if(/^\|.*\|$/.test(l.trim())){
    const next=(lines[i+1]||"").trim();
    if(/^\|[\s:|-]+\|$/.test(next)) intbl=true;
    else if(!intbl) tblBad.push(i+1);
  } else intbl=false;
}
tblBad.length===0?ok("表格：每个表头行后均有分隔行"):no("表格缺分隔行 @ "+tblBad.join(","));

// 4 标题层级不跳跃（跳过代码块内）
let prev=0,jump=[];
lines.forEach((l,i)=>{
  if(inCode[i])return;
  const m=l.match(/^(#{1,6})\s/);
  if(m){const lv=m[1].length;
    if(prev&&lv>prev+1)jump.push(`${i+1}: h${prev}→h${lv}`);
    prev=lv;}
});
jump.length===0?ok("标题层级无跳跃（已跳过代码块内的注释行）"):no("标题跳跃 "+jump.join(" | "));

// 5 交叉引用目标存在（跳过代码块）
const chapters={};
lines.forEach((l,i)=>{if(inCode[i])return;const m=l.match(/^##\s+([一二三四五六七八])、/);if(m)chapters[m[1]]=1;});
const refs=new Set();
lines.forEach((l,i)=>{if(inCode[i])return;for(const m of l.matchAll(/第([一二三四五六七八])章/g)) refs.add(m[1]);});
const missing=[...refs].filter(c=>!chapters[c]);
missing.length===0?ok(`交叉引用 ${refs.size} 个全部指向存在的章节`):no("引用了不存在的章节: "+missing.join(","));

// 6 「第X章第N节」精确命中
const detail=[];
lines.forEach((l,i)=>{
  if(inCode[i])return;
  for(const m of l.matchAll(/第([一二三四五六七八])章第\s*(\d)\s*节?/g)){
    const ch=m[1],n=+m[2];
    const secIdx=lines.findIndex(x=>/^##\s/.test(x)&&x.includes(ch+"、"));
    if(secIdx<0){detail.push(`L${i+1}: 第${ch}章不存在`);continue;}
    const nextCh=lines.findIndex((x,ix)=>ix>secIdx&&/^##\s/.test(x));
    const seg=lines.slice(secIdx,nextCh<0?lines.length:nextCh);
    if(!seg.some(x=>new RegExp(`^###\\s+${n}\\.`).test(x))) detail.push(`L${i+1}: 第${ch}章第${n}节不存在`);
  }
});
detail.length===0?ok("「第X章第N节」级引用全部精确命中"):no(detail.join(" | "));

// 7 硬编码数字是否标注基准（防过时）
if(lines.some(l=>l.includes("截至 v2.3.19"))) ok("条数快照已标注基准版本（防过时误导）");
else no("存在未标注基准的硬编码条数");

// 8 计数类断言：标题声称「下面 N 条」必须等于表格实际数据行数
//    背景：本项目实际发生过——加了一行陷阱却忘了改计数（10 → 实际 11），
//    而我当时的统计脚本范围写错，还报了"✅ 一致"。机器核对，不靠人眼。
const cntBad=[]; let cntSeen=0;
lines.forEach((l,i)=>{
  if(inCode[i]) return;
  const m=l.match(/下面\s*(\d+)\s*条/);
  if(!m) return;
  cntSeen++;
  const claimed=+m[1];
  let j=i+1;
  while(j<lines.length && !/^\|/.test(lines[j])) j++;
  if(j>=lines.length) return;
  let rows=0;
  while(j<lines.length && /^\|/.test(lines[j])) { rows++; j++; }
  const data=rows-2;                       // 扣掉表头行 + 分隔行
  if(data!==claimed) cntBad.push(`L${i+1}: 标题写 ${claimed} 条、实际 ${data} 条`);
});
if(cntSeen===0)      console.log("  ℹ 计数类断言：文档已去数字化（无「N 条」类硬编码），无需校验");
else if(cntBad.length===0) ok(`计数类断言 ${cntSeen} 处：标题条数与表格实际行数一致`);
else no("计数矛盾: "+cntBad.join(" | "));

console.log(`\n═══ 解析结果：${P} 通过 / ${Fc} 失败 ═══`);
process.exit(Fc);
