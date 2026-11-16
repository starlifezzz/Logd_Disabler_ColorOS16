#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ══════════════════════════════════════════════════════════════════
# .ci/check_remote_status.py —— 读 KernelSU Modules 官方收录状态并交叉验证
#
# 【为什么需要】2026-11-16 实发：本模块已审核通过（status: listed），
#   但读 https://raw.githubusercontent.com/.../status.json 得到
#   maxVersionCode/stable/lastSuccessAt 全为 null —— 是 CDN 缓存旧值，
#   加 ?cb=<epoch> 也破不掉。若只看这一个通道，会把「已收录」误判成「未同步」。
#
# 【做法】三条通道取同一份 status.json 并互相比对：
#   A: raw.githubusercontent.com  —— 走 Fastly 缓存，可能返回旧值（有坑的那个）
#   B: cdn.jsdelivr.net/gh/...@main —— CDN（通常最新，但会整站 503）
#   C: api.github.com contents API —— 动态、不缓存、无需认证（60 次/小时限流）
#   三者两两比对；任何两者不一致 → 报红，并指出谁新谁旧。
#   只有一个通道可用 → 不算「已验证」，返回 2（无法取证），绝不假装通过。
#   再把 sources.lock.json（客户端真正读取的锁文件）与本地 module.prop /
#   update.json 对齐，最后实测资产 sha256。
#
# 【退出码】
#   0 = 全绿（至少两条通道一致，且其余检查通过）
#   1 = 有真实矛盾（通道间数据不一致 / 本地与官方不一致 / 摘要不符）
#   2 = 无法取证（网络失败导致证据不足，不能声称「一致」）
#
# 【用法】
#   python3 .ci/check_remote_status.py               # 全量（含下载资产校验）
#   python3 .ci/check_remote_status.py --no-download # 跳过资产下载
#   MODULE_ID=Other_Id python3 .ci/check_remote_status.py
#
# 【环境变量覆盖（用于故障演练/换源，平时不用改）】
#   MODULE_ID / RAW_STATUS_URL / JSD_STATUS_URL / API_STATUS_URL /
#   LOCK_URL / DATA_REPO / UPDATE_JSON / MODULE_PROP
#
# 【注意】本脚本需要联网，故【不】并入 verify_v239.sh 离线门禁，单独跑。
# ══════════════════════════════════════════════════════════════════
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.request

SRC = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))

MODULE_ID = os.environ.get('MODULE_ID', 'Logd_Disabler_ColorOS16')
DATA_REPO = os.environ.get('DATA_REPO', 'KernelSU-Modules/repo')
RAW_STATUS_URL = os.environ.get(
    'RAW_STATUS_URL',
    'https://raw.githubusercontent.com/%s/main/status.json' % DATA_REPO)
JSD_STATUS_URL = os.environ.get(
    'JSD_STATUS_URL',
    'https://cdn.jsdelivr.net/gh/%s@main/status.json' % DATA_REPO)
API_STATUS_URL = os.environ.get(
    'API_STATUS_URL',
    'https://api.github.com/repos/%s/contents/status.json?ref=main' % DATA_REPO)
LOCK_URL = os.environ.get(
    'LOCK_URL',
    'https://cdn.jsdelivr.net/gh/%s@main/sources.lock.json' % DATA_REPO)
API_LOCK_URL = os.environ.get(
    'API_LOCK_URL',
    'https://api.github.com/repos/%s/contents/sources.lock.json?ref=main' % DATA_REPO)
UPDATE_JSON = os.environ.get('UPDATE_JSON', os.path.join(SRC, 'update.json'))
MODULE_PROP = os.environ.get('MODULE_PROP', os.path.join(SRC, 'module.prop'))

NO_DOWNLOAD = '--no-download' in sys.argv

P = 0
F = 0
# 无法取证（网络/解析失败）单独计数：它不等于「通过」，也不等于「数据矛盾」
U = 0


def ok(msg):
    global P
    P += 1
    print('  \u2705 %s' % msg)


def no(msg, detail=None):
    global F
    F += 1
    print('  \u274c %s' % msg)
    if detail:
        for line in str(detail).splitlines():
            print('       %s' % line)


def warn(msg):
    print('  \u26a0\ufe0f  %s' % msg)


def unknown(msg, detail=None):
    """证据缺失：不算失败，但绝不当作通过。"""
    global U
    U += 1
    print('  \u2753 %s' % msg)
    if detail:
        for line in str(detail).splitlines():
            print('       %s' % line)


def info(msg):
    print('     %s' % msg)


def bust(url):
    """给 http(s) URL 加一个不重复的查询参数，尽量绕开缓存。

    file:// 不加（查询串会让本地路径失效）。
    """
    if not url.startswith('http'):
        return url
    sep = '&' if '?' in url else '?'
    return '%s%scb=%d' % (url, sep, int(time.time() * 1000))


def fetch(url, timeout=45, attempts=3, headers=None):
    """拉取 URL 原始字节。失败不吞错，抛异常给调用方判「无法取证」。"""
    hdrs = {'User-Agent': 'logd-ci-check/1.0 (+kernelsu-modules)'}
    if headers:
        hdrs.update(headers)
    last = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers=hdrs)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except Exception as exc:  # noqa: BLE001 - 网络异常类型太杂，统一记录
            last = exc
            if i + 1 < attempts:
                time.sleep(2)
    raise RuntimeError('%s' % last)


def load_json_from(url, label):
    """返回 (doc, err)。err 非空表示该通道不可用（不代表数据矛盾）。"""
    try:
        raw = fetch(bust(url), headers={'Accept': 'application/vnd.github.raw'})
    except Exception as exc:  # noqa: BLE001
        return None, '%s' % exc
    try:
        return json.loads(raw.decode('utf-8', 'replace')), None
    except Exception as exc:  # noqa: BLE001
        return None, 'JSON 解析失败: %s' % exc


def pick(obj, path, default='<缺失>'):
    cur = obj
    for part in path.split('.'):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def brief(entry):
    """把一条 status 条目压成可比较的签名。"""
    return {
        'health': pick(entry, 'health'),
        'installation': pick(entry, 'installation'),
        'maxVersionCode': pick(entry, 'maxVersionCode'),
        'lastSuccessAt': pick(entry, 'lastSuccessAt'),
        'stable.tag': pick(entry, 'stable.tag'),
        'stable.versionCode': pick(entry, 'stable.versionCode'),
        'contentCommit': pick(entry, 'contentCommit'),
    }


def read_local_json(path, label):
    if not os.path.isfile(path):
        no('%s 不存在: %s' % (label, path))
        return None
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            return json.load(fh)
    except Exception as exc:  # noqa: BLE001
        no('%s 解析失败: %s' % (label, path), exc)
        return None


def read_prop(path):
    props = {}
    if not os.path.isfile(path):
        no('module.prop 不存在: %s' % path)
        return None
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            props[k.strip()] = v.strip()
    return props


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def download(url, dest):
    req = urllib.request.Request(
        url, headers={'User-Agent': 'logd-ci-check/1.0 (+kernelsu-modules)'})
    total = 0
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, 'wb') as out:
        while True:
            chunk = resp.read(256 * 1024)
            if not chunk:
                break
            out.write(chunk)
            total += len(chunk)
    return total


def section_a():
    """A. status.json 多通道一致性。返回 (权威 entry, 是否有至少两条通道)"""
    print('═══ A. status.json 多通道交叉验证 ═══')
    channels = [('A(raw)', RAW_STATUS_URL), ('B(jsDelivr)', JSD_STATUS_URL),
                ('C(githubAPI)', API_STATUS_URL)]
    entries = {}
    down = []      # 拉取失败：通道本身不可用（网络/CDN 故障）
    missing = []   # 通道正常但里面没有本模块（多半是缓存旧到收录前）
    for name, url in channels:
        doc, err = load_json_from(url, name)
        if err:
            down.append((name, err))
            continue
        if not isinstance(doc, dict):
            down.append((name, '返回的不是 JSON 对象'))
            continue
        mods = doc.get('modules') or {}
        entry = mods.get(MODULE_ID)
        if entry is None:
            missing.append(name)
            entries[name] = {'__missing__': True}
            continue
        entries[name] = entry
        info('%s 读到：maxVersionCode=%s stable=%s/%s' % (
            name, pick(entry, 'maxVersionCode'),
            pick(entry, 'stable.tag'), pick(entry, 'stable.versionCode')))

    usable = {k: v for k, v in entries.items() if not v.get('__missing__')}
    if not usable:
        for name, err in down:
            no('%s 不可用：%s' % (name, err))
        for name in missing:
            no('%s 里没有 %s（缓存旧到收录前，或 ID 写错）' % (name, MODULE_ID))
        return None, False

    # 有两条以上通道可用时，个别通道故障/缺条目只是警告（已被覆盖）；
    # 只剩一条时才降级为「无法取证」——单通道读数不能当交叉验证的证据。
    report = unknown if len(usable) < 2 else warn
    for name, err in down:
        report('%s 不可用：%s' % (name, err))
    for name in missing:
        report('%s 里没有 %s（该通道缓存旧到收录前）' % (name, MODULE_ID))

    # 权威通道优先级：C(API，动态不缓存) > B(jsDelivr) > A(raw，会缓存)
    order = ['C(githubAPI)', 'B(jsDelivr)', 'A(raw)']
    auth_name = next((n for n in order if n in usable), None)
    auth = usable[auth_name]

    if len(usable) >= 2:
        sigs = {k: brief(v) for k, v in usable.items()}
        # 按签名分组：A 与 B、A 与 C 往往只是同一份旧值的重复，合并成「组 vs 组」报一次
        groups = {}
        for name, sig in sigs.items():
            key = tuple(sorted((k, str(v)) for k, v in sig.items()))
            groups.setdefault(key, []).append(name)
        if len(groups) > 1:
            glist = list(groups.values())
            for i in range(len(glist)):
                for j in range(i + 1, len(glist)):
                    ga, gb = glist[i], glist[j]
                    sa, sb = sigs[ga[0]], sigs[gb[0]]
                    diffs = [(k, sa[k], sb[k]) for k in sa if str(sa[k]) != str(sb[k])]
                    no('%s 与 %s 读到不同内容（%d 处）'
                       % ('/'.join(ga), '/'.join(gb), len(diffs)),
                       '\n'.join('%-20s %s=%-30s %s=%s'
                                 % (k, ga[0], va, gb[0], vb) for k, va, vb in diffs))
            warn('判定为 CDN 缓存差异，不是仓库数据矛盾；权威取 %s' % auth_name)
            warn('若你刚发版，等几分钟重跑即可；持续不一致才需要看数据仓库本身')
        else:
            ok('所有可用通道（%s）内容一致：maxVersionCode=%s stable=%s/%s'
               % ('/'.join(sigs), pick(auth, 'maxVersionCode'),
                  pick(auth, 'stable.tag'), pick(auth, 'stable.versionCode')))
    else:
        unknown('只有 %s 一个通道可用，无法交叉验证（单通道读数不算证据）' % auth_name)

    if str(pick(auth, 'health')) != 'ok':
        no('官方健康态不是 ok：%s' % pick(auth, 'health'),
           'message=%s' % pick(auth, 'message'))
    else:
        ok('官方健康态 health=ok')
    if str(pick(auth, 'installation')) != 'present':
        no('installation=%s（应为 present）' % pick(auth, 'installation'))
    else:
        ok('installation=present')
    print()
    return auth, len(usable) >= 2


def load_lock():
    """锁文件：jsDelivr 优先，失败退 GitHub API。"""
    print('═══ B. sources.lock.json 与 status.json 一致 ═══')
    failed = []
    for url in (LOCK_URL, API_LOCK_URL):
        doc, err = load_json_from(url, '锁文件')
        if err:
            failed.append((url, err))
            continue
        entry = (doc.get('modules') or {}).get(MODULE_ID) if isinstance(doc, dict) else None
        if entry is None:
            no('锁文件里没有 %s' % MODULE_ID)
            return None
        info('锁文件来源：%s' % url)
        for f_url, f_err in failed:
            warn('锁文件备用通道不可用（已由上面这条覆盖）：%s' % f_err)
        return entry
    for f_url, f_err in failed:
        no('锁文件通道不可用：%s' % f_err)
    no('所有锁文件通道都不可用，无法核对 maxVersionCode / 资产摘要')
    return None


def main():
    print('════ 官方收录状态交叉验证（%s）════' % MODULE_ID)
    print('  通道 A: %s' % RAW_STATUS_URL)
    print('  通道 B: %s' % JSD_STATUS_URL)
    print('  通道 C: %s' % API_STATUS_URL)
    print()

    auth, multi = section_a()

    lock_e = load_lock()
    if lock_e and auth:
        pairs = [
            ('maxVersionCode', pick(lock_e, 'maxVersionCode'), pick(auth, 'maxVersionCode')),
            ('stable.versionCode', pick(lock_e, 'stable.versionCode'),
             pick(auth, 'stable.versionCode')),
            ('stable.tag', pick(lock_e, 'stable.tag'), pick(auth, 'stable.tag')),
            ('health.status', pick(lock_e, 'health.status'), pick(auth, 'health')),
        ]
        bad = [(n, a, b) for n, a, b in pairs if str(a) != str(b)]
        if bad:
            no('锁文件与 status.json 矛盾（%d 处）' % len(bad),
               '\n'.join('%-20s lock=%-24s status=%s' % (n, a, b) for n, a, b in bad))
        else:
            ok('锁文件与 status.json 完全一致（maxVersionCode=%s, stable=%s）'
               % (pick(lock_e, 'maxVersionCode'), pick(lock_e, 'stable.tag')))
    print()

    # ── C. 锁文件内部自洽 ───────────────────────────────────────
    print('═══ C. 锁文件内部自洽（版本号 / 摘要）═══')
    if lock_e:
        max_vc = pick(lock_e, 'maxVersionCode')
        max_stable_vc = pick(lock_e, 'maxStableVersionCode')
        stable_vc = pick(lock_e, 'stable.versionCode')
        if max_vc == max_stable_vc == stable_vc:
            ok('三个版本号一致：maxVersionCode=maxStableVersionCode=stable.versionCode=%s'
               % max_vc)
        else:
            no('版本号自相矛盾',
               'maxVersionCode=%s maxStableVersionCode=%s stable.versionCode=%s'
               % (max_vc, max_stable_vc, stable_vc))

        dig = str(pick(lock_e, 'stable.asset.digest', ''))
        sha = str(pick(lock_e, 'stable.asset.sha256', ''))
        if dig == 'sha256:' + sha and len(sha) == 64:
            ok('stable.asset.digest 与 sha256 一致：%s' % sha)
        else:
            no('digest 与 sha256 不一致', 'digest=%s\nsha256=%s' % (dig, sha))

        rels = lock_e.get('releases') or []
        matched = [r for r in rels if str(pick(r, 'versionCode')) == str(stable_vc)]
        if not matched:
            no('releases[] 里找不到 versionCode=%s 的条目' % stable_vc,
               '已有: %s' % [pick(r, 'versionCode') for r in rels])
        else:
            r = matched[0]
            if (str(pick(r, 'asset.sha256')) == sha
                    and pick(r, 'asset.size') == pick(lock_e, 'stable.asset.size')):
                ok('releases[] 条目与 stable 的摘要/大小一致（size=%s）'
                   % pick(r, 'asset.size'))
            else:
                no('releases[] 条目与 stable 的摘要/大小不一致',
                   'releases: sha=%s size=%s\nstable:   sha=%s size=%s'
                   % (pick(r, 'asset.sha256'), pick(r, 'asset.size'),
                      sha, pick(lock_e, 'stable.asset.size')))
        if pick(lock_e, 'stable.immutable') is True:
            ok('stable Release 标记为 immutable（不可被覆盖，资产不会被替换）')
        else:
            warn('stable.immutable 不是 true —— 该 Release 可被覆盖，一致性只能靠 sha256 兜')
    print()

    # ── D. 本地 update.json 与官方 stable 一致 ──────────────────
    print('═══ D. 本地 update.json 与官方 stable 一致（防幽灵更新 / 防漏更新）═══')
    local_upd = read_local_json(UPDATE_JSON, 'update.json')
    if local_upd and lock_e:
        stable_vc = str(pick(lock_e, 'stable.versionCode'))
        stable_tag = str(pick(lock_e, 'stable.tag'))
        local_vc = str(local_upd.get('versionCode', '<缺失>'))
        local_ver = str(local_upd.get('version', '<缺失>'))
        asset_name = str(pick(lock_e, 'stable.asset.name'))
        zip_url = str(local_upd.get('zipUrl', ''))

        if local_vc == stable_vc and local_ver == stable_tag:
            ok('update.json 版本与官方 stable 一致：%s / versionCode=%s'
               % (local_ver, local_vc))
        else:
            no('update.json 与官方 stable 不一致',
               'update.json: %s / %s\nofficial:    %s / %s'
               % (local_ver, local_vc, stable_tag, stable_vc))

        if zip_url.rstrip('/').endswith(asset_name):
            ok('update.json 的 zipUrl 指向官方资产 %s' % asset_name)
        else:
            no('update.json 的 zipUrl 未指向官方资产',
               'zipUrl=%s\n期望文件名=%s' % (zip_url, asset_name))
    print()

    # ── E. 资产实测 sha256 / 大小 ───────────────────────────────
    print('═══ E. 资产实测（sha256 / 大小）═══')
    if NO_DOWNLOAD:
        warn('已指定 --no-download，跳过资产下载校验（本次不构成「资产一致」的证据）')
    elif lock_e:
        url = str(pick(lock_e, 'stable.asset.url', ''))
        want_sha = str(pick(lock_e, 'stable.asset.sha256', ''))
        want_size = pick(lock_e, 'stable.asset.size')
        if not url.startswith('http'):
            no('锁文件里没有可用的资产 url：%r' % url)
        else:
            tmpdir = os.environ.get('TMPDIR') or os.path.join(SRC, '.ci', '.tmp')
            try:
                os.makedirs(tmpdir, exist_ok=True)
            except Exception:  # noqa: BLE001
                tmpdir = tempfile.gettempdir()
            dest = os.path.join(tmpdir, 'asset_verify.zip')
            try:
                got = download(url, dest)
            except Exception as exc:  # noqa: BLE001
                unknown('资产下载失败（不影响版本核对，但资产未被实测）', exc)
                got = None
            if got is not None:
                if want_size is not None and got != want_size:
                    no('资产大小不符', '实测=%s 期望=%s' % (got, want_size))
                else:
                    ok('资产大小一致：%s 字节' % got)
                got_sha = sha256_file(dest)
                if got_sha == want_sha:
                    ok('资产 sha256 一致：%s' % got_sha)
                else:
                    no('资产 sha256 不符', '实测=%s\n期望=%s' % (got_sha, want_sha))
                try:
                    os.unlink(dest)
                except OSError:
                    pass
    print()

    # ── F. 本地 module.prop 与 update.json 的关系 ───────────────
    print('═══ F. 本地 module.prop vs update.json（开发态 vs 发布态）═══')
    prop = read_prop(MODULE_PROP)
    if prop and local_upd:
        try:
            pvc = int(str(prop.get('versionCode', '')).strip())
        except ValueError:
            no('module.prop 的 versionCode 不是整数：%r' % prop.get('versionCode'))
            pvc = None
        try:
            uvc = int(str(local_upd.get('versionCode', '')).strip())
        except ValueError:
            no('update.json 的 versionCode 不是整数：%r' % local_upd.get('versionCode'))
            uvc = None
        if pvc is not None and uvc is not None:
            if pvc == uvc:
                ok('module.prop 与 update.json 版本号相同（%d）= 已发布态' % pvc)
            elif pvc > uvc:
                warn('module.prop(%d) > update.json(%d)：开发中尚未发版，属正常'
                     '（发版请打 tag 由 CI 写 update.json，不要手改）' % (pvc, uvc))
            else:
                no('module.prop(%d) < update.json(%d)：本地代码比官方发布旧' % (pvc, uvc),
                   '此时提交推送会导致版本错乱 → 先 git merge --ff-only origin/main 同步')
        expect_uj = ('https://raw.githubusercontent.com/starlifezzz/'
                     'Logd_Disabler_ColorOS16/main/update.json')
        if MODULE_ID == 'Logd_Disabler_ColorOS16' and str(prop.get('updateJson')) != expect_uj:
            warn('module.prop 的 updateJson 与预期地址不同（会改变管理器取更新的通道）')
            info('实际: %s' % prop.get('updateJson'))
    print()

    print('════ 结果：%d 通过 / %d 失败 / %d 无法取证 ════' % (P, F, U))
    if F:
        print('  \u274c 有真实矛盾项，结论：不一致')
        return 1
    if U:
        print('  \u26a0\ufe0f  存在无法取证项（网络/通道故障），不能声称「已确认一致」')
        return 2
    print('  \u2705 全部通过（至少两条通道互相印证）' if multi else '  \u2705 全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
