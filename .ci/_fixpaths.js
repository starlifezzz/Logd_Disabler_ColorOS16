#!/usr/bin/env node
// 把门禁脚本里的硬编码绝对路径改成可移植的相对定位。
// 规范要求：写成独立脚本文件执行（不用内联 node -e，反引号/单引号会被 shell 吞掉）。
// 关键保护：任一替换没命中 → 直接报错退出，绝不静默通过。
const fs = require('fs');
const path = require('path');
const CI = __dirname;                                  // .ci/
let fail = 0;

const plans = {
  'verify_v239.sh': [
    ['SRC="/storage/emulated/0/Download/Logd_Disabler_ColorOS16"',
     'SRC="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（本脚本位于 .ci/ 下，自动定位）'],
    ['T="/data/data/com.termux/files/usr/tmp/opencode"   # 对拍脚本目录',
     'T="${TMPDIR:-$SRC/.ci}"   # 临时目录：Termux 的 TMPDIR 可写，否则退回 .ci'],
    ["'/data/data/com.termux/files/usr/tmp/opencode/i.js'", "'$T/i.js'"],
    ["/data/data/com.termux/files/usr/tmp/opencode/feat.txt", "$T/feat.txt"],
  ],
  'audit_module.sh': [
    ['SRC="/storage/emulated/0/Download/Logd_Disabler_ColorOS16"',
     'SRC="$(cd "$(dirname "$0")/.." && pwd)"   # 项目根（本脚本位于 .ci/ 下）'],
    ['T="/data/data/com.termux/files/usr/tmp/opencode"',
     'T="${TMPDIR:-$SRC/.ci}"'],
  ],
  'audit_webui.js': [
    ["const SRC = '/storage/emulated/0/Download/Logd_Disabler_ColorOS16/webroot';",
     "const SRC = require('path').join(__dirname, '..', 'webroot');"],
  ],
  'checkjs.js': [
    ["fs.readFileSync('/storage/emulated/0/Download/Logd_Disabler_ColorOS16/webroot/index.html', 'utf8')",
     "fs.readFileSync(require('path').join(__dirname, '..', 'webroot', 'index.html'), 'utf8')"],
  ],
  'audit11.js': [
    ["const D='/data/data/com.termux/files/usr/tmp/opencode/dev/';",
     "const D=require('path').join(require('os').tmpdir(),'audit11_dev')+require('path').sep;"],
    ["const SRC='/storage/emulated/0/Download/Logd_Disabler_ColorOS16';",
     "const SRC=require('path').resolve(__dirname,'..');"],
    ["const cfg=JSON.parse(fs.readFileSync(D+'config.json','utf8'));",
     ["// 设备快照缺失时给出明确失败（不静默跳过 —— 静默跳过 = 假通过）",
      "for(const _f of ['config.json','state.json','disabled.txt','all.txt']){",
      "  if(!fs.existsSync(D+_f)){",
      "    console.log('  ❌ 缺设备快照: '+D+_f);",
      "    console.log('     生成方法（在有 su 的设备上）: su -c \"cat /data/adb/Logd_Disabler_ColorOS16/config.json\" > '+D+'config.json');",
      "    process.exit(1);",
      "  }",
      "}",
      "const cfg=JSON.parse(fs.readFileSync(D+'config.json','utf8'));"].join('\n')],
  ],
  'lint_agent.js': [
    ['const F="/data/data/com.termux/files/home/.config/opencode/agents/coloros.md";',
     ["const F=process.env.COLOROS_AGENT_MD",
      "  || '/data/data/com.termux/files/home/.config/opencode/agents/coloros.md';",
      "if(!fs.existsSync(F)){console.log('  ℹ 跳过：coloros.md 不在本机（'+F+'）');process.exit(0);}"].join('\n')],
  ],
  'xmap2.js': [
    ["const SRC='/storage/emulated/0/Download/Logd_Disabler_ColorOS16';",
     "const SRC=require('path').resolve(__dirname,'..');"],
  ],
  'xmap3.js': [
    ["const SRC='/storage/emulated/0/Download/Logd_Disabler_ColorOS16';",
     "const SRC=require('path').resolve(__dirname,'..');"],
  ],
  'build_zip.py': [
    ["SRC='/storage/emulated/0/Download/Logd_Disabler_ColorOS16'",
     "SRC=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 项目根（本脚本位于 .ci/ 下）"],
  ],
};

for (const [file, reps] of Object.entries(plans)) {
  const p = path.join(CI, file);
  if (!fs.existsSync(p)) { console.log(`  ❌ ${file} 不存在`); fail++; continue; }
  let s = fs.readFileSync(p, 'utf8');
  let hit = 0, miss = [];
  for (const [from, to] of reps) {
    if (s.includes(from)) { s = s.split(from).join(to); hit++; }
    else if (s.includes(to)) { hit++; }          // 幂等：目标已在场说明跑过了
    else miss.push(from.slice(0, 70));
  }
  if (miss.length) { console.log(`  ❌ ${file}: ${miss.length}/${reps.length} 未命中`); miss.forEach(m => console.log(`       ${m}`)); fail++; }
  else { fs.writeFileSync(p, s); console.log(`  ✅ ${file}: ${hit}/${reps.length} 处替换`); }
}

// 确认绝对路径已清零
console.log('\n── 残留硬编码扫描 ──');
let leftover = 0;
for (const f of Object.keys(plans)) {
  const s = fs.readFileSync(path.join(CI, f), 'utf8');
  const hits = s.match(/\/storage\/emulated\/0\/Download\/Logd_Disabler|\/data\/data\/com\.termux\/files\/usr\/tmp\/opencode/g);
  // build_zip.py / lint_agent.js 里保留的 fallback 注释不算
  if (hits && !/fallback|不匹配|生成方法/.test(s)) { console.log(`  ❌ ${f}: ${hits.length} 处残留`); leftover++; }
}
if (!leftover) console.log('  ✅ 无残留硬编码路径');
console.log(`\n═══ ${fail === 0 ? '路径改造完成' : fail + ' 个文件失败'} ═══`);
process.exit(fail);
