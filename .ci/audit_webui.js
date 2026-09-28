/* audit_webui.js — WebUI 页面严格审查
 * 盲区补齐：checkjs 只查 JS 语法，verify 大多是 grep 文本匹配（文本在、浏览器不认也照样绿）。
 *   A. 把页面脚本在沙箱里真实执行 → 拿到 Vue options → 与模板标识符逐个对撞
 *   B. HTML 标签配平
 *   C. 模板 class ↔ CSS class 双向交叉（含 JS 动态拼接的类）
 *   D. CSS 值合法性（rgb(--x) 漏 var / 裸 color:var(--mdui-color-x) / token 引用缺失）
 *   E. CSS 完全重复规则
 *   F. CSS「孤儿规则」：选择器目标类在模板和 JS 里都不存在
 */
const fs = require('fs'), vm = require('vm');
const SRC = require('path').join(__dirname, '..', 'webroot');
const IDX = SRC + '/index.html';
const CSSFILES = ['app.tokens.css','app.base.css','app.components.css','app.pages.css','app.theme.crt.css']
  .map(f => SRC + '/assets/' + f);

const tokSrc = fs.readFileSync(SRC + '/assets/app.tokens.css', 'utf8');
const tokenDefs = new Set([...tokSrc.matchAll(/(--app-[\w-]+)\s*:/g)].map(m => m[1]));

let P = 0, F = 0;
const ok = m => { P++; console.log('  ✅ ' + m); };
const no = (m, e) => { F++; console.log('  ❌ ' + m + (e ? '  → ' + e : '')); };
const html = fs.readFileSync(IDX, 'utf8');
const stripC = s => s.replace(/\/\*[\s\S]*?\*\//g, x => ' '.repeat(x.length));

/* ---------- 切分模板 / 脚本 ---------- */
const scripts = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map(m => m[1]);
const templateOnly = html.replace(/<script(?![^>]*\bsrc=)[^>]*>[\s\S]*?<\/script>/g, '');

/* ════════ A. Vue 绑定完整性 ════════ */
console.log('═══ A. Vue 绑定完整性（沙箱真实执行脚本）═══');
const cap = {};
let runErr = null;
try {
  const mkApp = () => {
    const a = { config: { globalProperties: {}, compilerOptions: {}, appContext: {}, errorHandler: null },
      mount() { return a; }, unmount() {}, run() {}, on() {}, once() {}, off() {}, emit() {},
      component() { return a; }, use() { return a; }, directive() { return a; }, mixin() { return a; },
      provide() { return a; }, warn() {}, withCtx(f) { return f; },
      rootComponent: null, _component: null, _instance: null, context: null };
    return a;
  };
  const sandbox = {
    console,
    Vue: { createApp(o) { cap.opts = o; return mkApp(); }, defineComponent(o) { return o; },
      ref: v => ({ value: v }), reactive: v => v, computed: f => ({ get: f }), watch() {}, onMounted() {},
      onUnmounted() {}, nextTick: () => Promise.resolve(), h() {}, createTextVNode() {}, Fragment: 'F' },
    mdui: { global: {}, css: {}, snackbar() {}, alert() {}, confirm() {}, prompt() {}, dialog() {},
      throttle: f => f, util: {}, Drawer: {}, Collapse: {}, Tab: {} },
    sh: () => Promise.resolve(''),
    fetch: () => Promise.resolve({ ok: true, json: () => Promise.resolve({}) }),
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    document: { documentElement: { dataset: {} }, body: {}, getElementById: () => null,
      querySelector: () => null, querySelectorAll: () => [], addEventListener() {}, removeEventListener() {},
      createElement: () => ({ style: {}, setAttribute() {}, appendChild() {}, remove() {}, classList: { add() {}, remove() {} } }) },
    navigator: { clipboard: { writeText: () => Promise.resolve() }, userAgent: '' },
    location: { href: '', reload() {} },
    setTimeout, clearTimeout, setInterval, clearInterval,
    Promise, JSON, Date, Math, RegExp, Array, Object, String, Number, Boolean, Error, Set, Map, Symbol, Infinity, NaN,
  };
  sandbox.window = sandbox; sandbox.self = sandbox; sandbox.globalThis = sandbox; sandbox.global = sandbox;
  vm.createContext(sandbox);
  scripts.forEach((code, i) => vm.runInContext(code, sandbox, { filename: 'inline#' + i }));
} catch (e) { runErr = e; }

let methods = [], dataKeys = [], computed = [], used = new Map(), scriptAll = '';
if (runErr) no('页面脚本无法在沙箱执行', runErr.message);
else if (!cap.opts) no('未捕获到 Vue.createApp 的 options');
else {
  ok('页面脚本可执行，已捕获 Vue options');
  methods = Object.keys(cap.opts.methods || {});
  try { dataKeys = Object.keys(cap.opts.data ? cap.opts.data() : {}); } catch (e) { no('data() 抛异常', e.message); }
  computed = Object.keys(cap.opts.computed || {});
  console.log(`     methods=${methods.length}  data=${dataKeys.length}  computed=${computed.length}`);

  scriptAll = scripts.join('\n');
  const globals = new Set();
  for (const m of scriptAll.matchAll(/^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/gm)) globals.add(m[1]);
  for (const m of scriptAll.matchAll(/^\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/gm)) globals.add(m[1]);

  const forVars = new Set();
  for (const m of templateOnly.matchAll(/v-for="([^"]+)"/g)) {
    const head = m[1].split(/\s+in\s+|\s+of\s+/)[0];
    for (const v of head.matchAll(/[A-Za-z_$][\w$]*/g)) forVars.add(v[0]);
  }

  const BUILTIN = new Set(('true false null undefined this Math JSON Number String Boolean Array Object Date ' +
    'parseInt parseFloat isNaN isFinite console Promise Set Map Error RegExp Symbol Infinity NaN event $event ' +
    'row item group g i index key val v u e r t n').split(' '));
  const scope = new Set([...dataKeys, ...methods, ...computed, ...globals, ...forVars, ...BUILTIN]);

  const addExpr = (expr, src) => {
    if (!expr) return;
    // 先剔掉字符串字面量（'home' / "expand_less--outlined" 这类是值不是标识符）
    const t = String(expr).replace(/'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|`(?:[^`\\]|\\.)*`/g, ' ')
                           // 剔掉成员访问的属性名（row.deltaClass 里的 deltaClass）
                           .replace(/\.\s*([A-Za-z_$][\w$]*)/g, ' ')
                           // 剔掉对象字面量的键名（:class="{opened: isOpen(..)}" 里的 opened）
                           .replace(/([{,]\s*)([A-Za-z_$][\w$]*)\s*:/g, '$1');
    for (const m of t.matchAll(/[A-Za-z_$][\w$]*/g)) if (!used.has(m[0])) used.set(m[0], src);
  };
  for (const m of templateOnly.matchAll(/\{\{([\s\S]*?)\}\}/g)) addExpr(m[1], '插值');
  for (const m of templateOnly.matchAll(/\s(v-if|v-else-if|v-show|v-html|v-text|v-model|v-model:value)="([^"]*)"/g)) addExpr(m[2], m[1]);
  for (const m of templateOnly.matchAll(/\s(:[a-zA-Z-]+|@[a-zA-Z-]+)="([^"]*)"/g)) addExpr(m[2], m[1]);
  for (const m of templateOnly.matchAll(/\sv-for="([^"]+)"/g)) addExpr(m[1].split(/\s+in\s+|\s+of\s+/)[1], 'v-for源');

  // 明显不是标识符的（组件属性/标签属性第二段误伤）
  const FP = new Set(('class style slot key name value icon open disabled checked max variant size title type ' +
    'href src ref data props attrs emit url label date time html').split(' '));
  const undef = [...used.keys()].filter(id => !scope.has(id) && !FP.has(id)).sort();
  if (undef.length) no(`模板引用了 ${undef.length} 个未定义标识符`, undef.slice(0, 25).join(' '));
  else ok(`模板标识符全部可解析（data/computed/methods/全局/v-for 作用域，共 ${used.size} 个）`);

  const tplDead = methods.filter(mth => !new RegExp(mth.replace(/\$/g, '\\$')).test(templateOnly));
  if (tplDead.length) console.log(`     ℹ ${tplDead.length} 个 method 未出现在模板（多为脚本内部互调）: ${tplDead.slice(0, 8).join(' ')}${tplDead.length > 8 ? ' …' : ''}`);
  const dataDead = dataKeys.filter(k => !used.has(k));
  if (dataDead.length) console.log(`     ℹ ${dataDead.length} 个 data 字段模板未直接引用: ${dataDead.slice(0, 10).join(' ')}${dataDead.length > 10 ? ' …' : ''}`);

  /* ---------- this.x = 赋值但没在 data 声明 → 非响应式 + 渲染读到 undefined ---------- */
  const assigned = new Set();
  for (const m of scriptAll.matchAll(/\bthis\.([A-Za-z_$][\w$]*)\s*=[^=]/g)) assigned.add(m[1]);
  const declared = new Set([...dataKeys, ...computed, ...methods]);
  const undeclared = [...assigned].filter(k => !declared.has(k)).sort();
  if (undeclared.length) no(`${undeclared.length} 个 this.x 赋值但未在 data/computed/methods 声明`, undeclared.join(' '));
  else ok('所有 this.x = 赋值目标都已在 data 中声明（响应式有效）');
}

/* ════════ B. HTML 标签配平 ════════ */
console.log('═══ B. HTML 标签配平 ═══════');
{
  const VOID = new Set('meta link br hr img input source wbr col embed area base track param'.split(' '));
  const t = templateOnly.replace(/<!--[\s\S]*?-->/g, '').replace(/\{\{[\s\S]*?\}\}/g, x => ' '.repeat(x.length));
  const stack = []; const errs = [];
  const re = /<(\/?)([a-zA-Z][\w-]*)([^>]*?)(\/?)>/g; let m;
  while ((m = re.exec(t))) {
    const [, slash, tag, , self] = m;
    const name = tag.toLowerCase();
    if (VOID.has(name) || self === '/') continue;
    if (!slash) stack.push({ name, i: m.index });
    else if (!stack.length) errs.push(`多余的 </${name}>`);
    else if (stack[stack.length - 1].name !== name) {
      errs.push(`</${name}> 遇到 <${stack[stack.length - 1].name}>`);
      const at = stack.map(x => x.name).lastIndexOf(name);
      if (at >= 0) stack.length = at; else continue;
    } else stack.pop();
  }
  if (stack.length) errs.push('未闭合: ' + stack.map(x => '<' + x.name + '>').join(' '));
  if (errs.length) no('HTML 标签配平', errs.slice(0, 5).join(' | '));
  else ok('HTML 标签配平（含 mdui 自定义组件标签）');
}

/* ════════ C. class 双向交叉 ════════ */
console.log('═══ C. 模板 class ↔ CSS class 双向交叉 ═══════');
const cssAll = CSSFILES.map(f => fs.readFileSync(f, 'utf8')).join('\n');
const cssClasses = new Set([...stripC(cssAll).matchAll(/\.([a-zA-Z][\w-]*)/g)].map(m => m[1]));
const tplClasses = new Set();
for (const m of templateOnly.matchAll(/\sclass="([^"]*)"/g))
  m[1].split(/\s+/).filter(Boolean).forEach(c => { if (/^[a-zA-Z][\w-]*$/.test(c)) tplClasses.add(c); });
for (const m of templateOnly.matchAll(/:class="([^"]*)"/g))
  for (const s of m[1].matchAll(/'([a-zA-Z][\w-]*)'|"([a-zA-Z][\w-]*)"/g)) tplClasses.add(s[1] || s[2]);
const jsClasses = new Set();
// 注意：JS 源码不能去注释！字符串/正则里出现的 /* */ 不是注释，
// 用 stripC 会吞掉大段代码（实测吞掉 43 个类名）。这里直接扫原始 JS。
scripts.join('\n').split('\n').forEach(l => {
  for (const m of l.matchAll(/class=\\?"([^"\\]*)/g))
    m[1].split(/\s+/).filter(Boolean).forEach(x => { if (/^[a-zA-Z][\w-]*$/.test(x)) jsClasses.add(x); });
  for (const m of l.matchAll(/'([a-z][\w-]*(?:-[a-z0-9]+)+)'/g)) jsClasses.add(m[1]);
  for (const m of l.matchAll(/"([a-z][\w-]*(?:-[a-z0-9]+)+)"/g)) jsClasses.add(m[1]);
});
// 动态前缀：模板里有 'toast-' + type 这类拼接 → 前缀命中的类视为在用
const dynPrefix = [];
// 注意：[\w-]* 已经会把尾部的 - 吃进去，别再重复追加（否则变成 "toast--" 永远匹配不上）
const addP = s => dynPrefix.push(s.endsWith('-') ? s : s + '-');
for (const m of templateOnly.matchAll(/'([a-z][\w-]*)'\s*\+/g)) addP(m[1]);
for (const m of templateOnly.matchAll(/<transition\s+name="([a-z][\w-]*)"/g)) addP(m[1]);
{
  const missCss = [...tplClasses].filter(c => !cssClasses.has(c) && !/^toast-$/.test(c));
  if (missCss.length) console.log(`     ℹ ${missCss.length} 个模板类在 CSS 中无定义（语义标记，无对应样式）: ${missCss.join(' ')}`);
  else ok(`模板 ${tplClasses.size} 个 class 全部有 CSS 定义（含 :class 动态字面量）`);
  const dead = [...cssClasses].filter(c => !tplClasses.has(c) && !jsClasses.has(c) && !dynPrefix.some(p => c.startsWith(p)));
  console.log(`     ℹ CSS 定义但模板/JS 均未用 ${dead.length} 个（可能死代码）: ${dead.join(' ') || '无'}`);
}

/* ════════ D. CSS 值合法性 ════════ */
console.log('═══ D. CSS 值合法性 ═══════');
{
  const bad = [];
  CSSFILES.forEach(f => {
    const name = f.split('/').pop();
    const s = stripC(fs.readFileSync(f, 'utf8'));
    s.split('\n').forEach((ln, i) => {
      const t = ln;
      for (const m of t.matchAll(/(rgb|rgba|hsl|hsla|lab|lch|color)\(\s*--/g)) bad.push(`${name}:${i + 1} ${m[0]} 漏 var()`);
      const re = /([a-z-]+)\s*:\s*var\((--mdui-color-[a-z0-9-]+)\)/g; let m;
      while ((m = re.exec(t))) if (!m[1].startsWith('--')) bad.push(`${name}:${i + 1} 裸 ${m[0]}`);
      for (const m of t.matchAll(/var\((--app-[\w-]+)\)/g))
        if (!tokenDefs.has(m[1])) bad.push(`${name}:${i + 1} 引用未定义 ${m[1]}`);
      // 括号不配平的单行声明
      const o = (t.match(/\(/g) || []).length, c = (t.match(/\)/g) || []).length;
      if (o !== c && !t.includes('/*')) bad.push(`${name}:${i + 1} 单行 ( 数≠) 数`);
    });
  });
  if (bad.length) no(`${bad.length} 处 CSS 值非法/引用缺失`, [...new Set(bad)].slice(0, 6).join(' | '));
  else ok('无 rgb(--x) 漏 var、无裸 color:var(--mdui-color-x)、--app-* token 引用全部有定义');
}

/* ════════ E. 完全重复规则 ════════ */
console.log('═══ E. CSS 完全重复规则 ═══════');
{
  const seen = new Map(); const dup = [];
  CSSFILES.forEach(f => {
    const name = f.split('/').pop(); const s = stripC(fs.readFileSync(f, 'utf8'));
    let i = 0;
    while (i < s.length) {
      const o = s.indexOf('{', i); if (o < 0) break;
      const sel = s.slice(i, o).trim(); let d = 1, j = o + 1;
      while (j < s.length && d > 0) { if (s[j] === '{') d++; else if (s[j] === '}') d--; j++; }
      if (sel && !sel.startsWith('@')) {
        const body = s.slice(o + 1, j - 1).trim().replace(/\s+/g, ' ');
        for (const part of sel.split(',').map(x => x.trim())) {
          const k = part + '{' + body;
          if (seen.has(k)) dup.push(`${name}: ${part}`); else seen.set(k, name);
        }
      }
      i = j;
    }
  });
  if (dup.length) no(`${dup.length} 条完全重复的规则`, dup.slice(0, 5).join(' | '));
  else ok('无「同选择器+同声明体」的完全重复规则');
}

/* ════════ F. 孤儿规则 ════════ */
console.log('═══ F. CSS 孤儿规则（选择器目标类在模板/JS 都不存在）═══');
{
  const orphans = [];
  CSSFILES.forEach(f => {
    const name = f.split('/').pop(); const s = stripC(fs.readFileSync(f, 'utf8'));
    let i = 0;
    while (i < s.length) {
      const o = s.indexOf('{', i); if (o < 0) break;
      const sel = s.slice(i, o).trim(); let d = 1, j = o + 1;
      while (j < s.length && d > 0) { if (s[j] === '{') d++; else if (s[j] === '}') d--; j++; }
      if (sel && !sel.startsWith('@')) {
        for (const part of sel.split(',').map(x => x.trim())) {
          for (const m of part.matchAll(/\.([a-zA-Z][\w-]*)/g)) {
            const c = m[1];
            if (!tplClasses.has(c) && !jsClasses.has(c)) orphans.push(`${name}: ${part}`);
          }
        }
      }
      i = j;
    }
  });
  const uniq = [...new Set(orphans)].filter(s => !dynPrefix.some(p => s.includes('.' + p)));
  if (uniq.length) console.log(`     ℹ ${uniq.length} 条孤儿规则（目标类在模板/JS 都不存在）: ${uniq.slice(0, 8).join(' | ')}${uniq.length > 8 ? ' …' : ''}`);
  else ok('无孤儿规则');
}

console.log('\n════════ 审查结果：' + P + ' 通过 / ' + F + ' 失败 ════════');
process.exit(F ? 1 : 0);
