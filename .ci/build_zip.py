import os, re, subprocess, zipfile, stat, sys
SRC=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # 项目根（本脚本位于 .ci/ 下）
OUT=os.path.join(SRC,'Logd_Disabler_ColorOS16.zip')

# 排除规则照抄 zip.sh
# 完全照抄 CI 的 -x 规则：*.git* *.github* *.lingma* .gitignore README.md
#   Logd_Disabler_ColorOS16.zip zip.sh update.json reference/*
EXCL_DIRS = {'.git','.github','.lingma','reference','META-INF','node_modules'}
EXCL_FILES = {'Logd_Disabler_ColorOS16.zip','verify_status.sh','README.md',
              '.gitignore','zip.sh','update.json'}
EXCL_PAT = re.compile(r'^(verify_.*|.*\.orig|.*\.bak|.*\.swp)$')

def git_mode(rel):
    """权限照抄 git index（FUSE 上 chmod 不可信）"""
    try:
        r=subprocess.run(['git','-c',f'safe.directory={SRC}','ls-files','-s','--',rel],
                         capture_output=True,text=True,cwd=SRC)
        if r.stdout.strip():
            return int(r.stdout.split()[0][:6],8)
    except Exception: pass
    return 0o755 if rel.endswith('.sh') else 0o644

files=[]
for root,dirs,fnames in os.walk(SRC):
    dirs[:] = [d for d in dirs if d not in EXCL_DIRS]
    for f in fnames:
        full=os.path.join(root,f)
        rel=os.path.relpath(full,SRC)
        if f in EXCL_FILES or EXCL_PAT.match(f): continue
        if rel=='Logd_Disabler_ColorOS16.zip': continue
        files.append(rel)
files.sort()

with zipfile.ZipFile(OUT,'w',zipfile.ZIP_DEFLATED) as z:
    for rel in files:
        zi=zipfile.ZipInfo(rel)
        zi.external_attr = (git_mode(rel) & 0xFFFF) << 16
        zi.compress_type=zipfile.ZIP_DEFLATED
        with open(os.path.join(SRC,rel),'rb') as fh:
            z.writestr(zi, fh.read())

print(f"✅ 已构建 {OUT}  {os.path.getsize(OUT)} 字节  {len(files)} 个文件")

# ===== CI 同款自检 =====
# 照抄 .github/workflows/main.yml 的 Verify zip contains required files 步骤
REQ=['module.prop','customize.sh','service.sh','post-fs-data.sh','boot-completed.sh',
     'uninstall.sh','sepolicy.rule','cnss_diag_off.conf','cnss_diag_always_on_off.conf',
     'webroot/index.html']
z=zipfile.ZipFile(OUT); names=z.namelist()
print("\n── CI 必需文件 ──")
bad=0
for r in REQ:
    ok = r in names
    if not ok: bad+=1
    print(f"  {'✅' if ok else '❌'} {r}")
if 'verify_status.sh' in names: print("  ❌ 含 verify_status.sh（禁止出包）"); bad+=1
else: print("  ✅ 不含 verify_status.sh")
print("\n── 脚本权限 ──")
for n in names:
    if n.endswith('.sh'):
        m=(z.getinfo(n).external_attr >> 16) & 0xFFFF
        exe = bool(m & stat.S_IXUSR)
        print(f"  {'✅' if exe else '⚠️ '} {oct(m)} {n}")
print("\n── 版本 ──")
mp=z.read('module.prop').decode()
print("  "+mp.replace('\n',' | '))
print(f"\n{'🎉 CI 自检通过' if bad==0 else f'❌ {bad} 项失败'}")
sys.exit(1 if bad else 0)
