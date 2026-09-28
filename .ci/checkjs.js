const fs = require('fs');
const html = fs.readFileSync(require('path').join(__dirname, '..', 'webroot', 'index.html'), 'utf8');
// 抽取所有内联 <script>（排除 src= 外链）
const re = /<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)<\/script>/g;
let m, i = 0, ok = true;
while ((m = re.exec(html))) {
  i++;
  const code = m[1];
  try {
    new Function(code);
    console.log(`script#${i}: OK (${code.length} chars)`);
  } catch (e) {
    ok = false;
    console.log(`script#${i}: FAIL -> ${e.message}`);
  }
}
if (!i) { console.log('no inline script found'); ok = false; }
process.exit(ok ? 0 : 1);
