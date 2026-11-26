package apps

import "strings"

const (
	templateSharedCSSPlaceholder = "/*__LIGHTISLE_SHARED_CSS__*/"
	templateSharedJSPlaceholder  = "/*__LIGHTISLE_KV_JS__*/"
)

func injectTemplateSharedAssets(html string) string {
	out := strings.Replace(html, templateSharedCSSPlaceholder, lightIsleSharedCSS, 1)
	out = strings.Replace(out, templateSharedJSPlaceholder, lightIsleKVJS, 1)
	return out
}

const lightIsleSharedCSS = `
  :root {
    color-scheme: light dark;
    --bg: #faf7f2;
    --surface: #ffffff;
    --surface-soft: #f3eee6;
    --text: #1f1c18;
    --muted: #6f685f;
    --border: rgba(31, 28, 24, 0.10);
    --shadow: 0 6px 24px rgba(31, 28, 24, 0.05);
    --radius-card: 18px;
    --radius-ctrl: 11px;
    --accent: #c46b3b;
    --accent-fg: #ffffff;
    --accent-soft: rgba(196, 107, 59, 0.12);
    --warn: #b45309;
    --warn-soft: rgba(217, 119, 6, 0.11);
    --danger: #dc2626;
    --danger-soft: rgba(220, 38, 38, 0.11);
    --ok: #15803d;
    --ok-soft: rgba(21, 128, 61, 0.11);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #151412;
      --surface: #1e1c19;
      --surface-soft: #272420;
      --text: #f4efe8;
      --muted: #b5ada2;
      --border: rgba(244, 239, 232, 0.12);
      --shadow: 0 8px 28px rgba(0, 0, 0, 0.32);
      --accent: #f09a68;
      --accent-fg: #151412;
      --accent-soft: rgba(240, 154, 104, 0.18);
      --warn: #fbbf24;
      --warn-soft: rgba(251, 191, 36, 0.17);
      --danger: #fca5a5;
      --danger-soft: rgba(248, 113, 113, 0.18);
      --ok: #4ade80;
      --ok-soft: rgba(74, 222, 128, 0.17);
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", sans-serif;
    background: var(--bg);
    color: var(--text);
    padding: 20px 16px 40px;
    line-height: 1.5;
    font-variant-numeric: tabular-nums;
  }
  .wrap { max-width: 840px; margin: 0 auto; display: grid; gap: 16px; }
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius-card);
    padding: 20px;
    box-shadow: var(--shadow);
  }
  .head-row { display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; flex-wrap: wrap; }
  h1 { margin: 0 0 4px; font-size: 20px; font-weight: 650; letter-spacing: -0.01em; }
  h2 { margin: 0 0 10px; font-size: 15px; font-weight: 650; }
  p.sub { margin: 0; font-size: 13px; color: var(--muted); }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 14px; }
  .stat { padding: 12px 14px; border-radius: 13px; background: var(--accent-soft); }
  .stat span { font-size: 12px; color: var(--muted); }
  .stat b { display: block; font-size: 22px; color: var(--accent); margin-top: 3px; font-weight: 680; }
  .form, .filters, .toolbar { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; align-items: center; }
  input, select, textarea {
    padding: 8px 12px;
    border-radius: var(--radius-ctrl);
    border: 1px solid var(--border);
    font-size: 13px;
    background: var(--surface-soft);
    color: var(--text);
    font-family: inherit;
  }
  input:focus, select:focus, textarea:focus { outline: 2px solid var(--accent); outline-offset: 1px; }
  button {
    padding: 8px 14px;
    border-radius: var(--radius-ctrl);
    border: none;
    background: var(--accent);
    color: var(--accent-fg);
    font-size: 13px;
    font-weight: 600;
    cursor: pointer;
    transition: opacity .15s ease, transform .08s ease;
  }
  button:hover { opacity: 0.92; }
  button:active { transform: scale(0.98); }
  button.ghost { background: var(--surface-soft); color: var(--text); border: 1px solid var(--border); }
  button.active { background: var(--text); color: var(--bg); border-color: transparent; }
  button.sm { padding: 5px 10px; font-size: 12px; border-radius: 9px; }
  .list { display: grid; gap: 9px; }
  .item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 14px;
    border-radius: 13px;
    border: 1px solid var(--border);
    background: var(--surface);
    gap: 10px;
    flex-wrap: wrap;
  }
  .item.soon, .item.expiring { border-color: var(--warn); background: var(--warn-soft); }
  .item.expired { border-color: var(--danger); background: var(--danger-soft); }
  .meta { font-size: 12px; color: var(--muted); margin-top: 3px; }
  .pill { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 600; padding: 3px 9px; border-radius: 999px; background: var(--surface-soft); color: var(--muted); }
  .pill.warn { background: var(--warn-soft); color: var(--warn); }
  .pill.danger { background: var(--danger-soft); color: var(--danger); }
  .pill.ok { background: var(--ok-soft); color: var(--ok); }
  .empty { font-size: 13px; color: var(--muted); padding: 10px 2px; }
  .li-sync-bar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    flex-wrap: wrap;
    padding: 9px 13px;
    border-radius: 12px;
    border: 1px solid var(--border);
    background: var(--surface-soft);
    font-size: 12px;
    color: var(--muted);
    margin-top: 12px;
  }
  .li-sync-bar.is-ok { color: var(--ok); background: var(--ok-soft); border-color: transparent; }
  .li-sync-bar.is-warn { color: var(--warn); background: var(--warn-soft); border-color: var(--warn); }
  .li-sync-bar.is-danger { color: var(--danger); background: var(--danger-soft); border-color: var(--danger); }
  .li-sync-actions { display: inline-flex; gap: 6px; align-items: center; }
`

const lightIsleKVJS = `
(function () {
  function clone(v) {
    return JSON.parse(JSON.stringify(v));
  }
  function isNonEmptyData(v) {
    if (Array.isArray(v)) return v.length > 0;
    if (v && typeof v === 'object') return Object.keys(v).length > 0;
    return v !== null && v !== undefined && v !== '';
  }
  function readLocal(key, fallback) {
    if (!key) return clone(fallback);
    try {
      var raw = localStorage.getItem(key);
      if (!raw) return clone(fallback);
      var parsed = JSON.parse(raw);
      return parsed === null || parsed === undefined ? clone(fallback) : parsed;
    } catch (_) {
      return clone(fallback);
    }
  }
  function writeLocal(key, value) {
    if (!key) return;
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch (_) {}
  }
  function todayISO() {
    var d = new Date();
    var m = String(d.getMonth() + 1).padStart(2, '0');
    var day = String(d.getDate()).padStart(2, '0');
    return d.getFullYear() + '-' + m + '-' + day;
  }
  function addDaysISO(baseISO, days) {
    var src = baseISO && baseISO.length === 10 ? new Date(baseISO + 'T00:00:00') : new Date();
    src.setDate(src.getDate() + Number(days || 0));
    var m = String(src.getMonth() + 1).padStart(2, '0');
    var day = String(src.getDate()).padStart(2, '0');
    return src.getFullYear() + '-' + m + '-' + day;
  }
  function daysUntil(dateStr) {
    if (!dateStr || dateStr.length < 10) return null;
    var target = new Date(dateStr.slice(0, 10) + 'T00:00:00');
    if (isNaN(target.getTime())) return null;
    var today = new Date();
    today.setHours(0, 0, 0, 0);
    return Math.round((target.getTime() - today.getTime()) / 86400000);
  }
  function genId() {
    return Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 7);
  }
  function exportJSON(filename, data) {
    var blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }
  function copyText(text) {
    var val = String(text || '');
    if (navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(val).catch(function () {
        return fallbackCopy(val);
      });
    }
    return fallbackCopy(val);
  }
  function fallbackCopy(val) {
    return new Promise(function (resolve, reject) {
      try {
        var ta = document.createElement('textarea');
        ta.value = val;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.focus();
        ta.select();
        var ok = document.execCommand('copy');
        document.body.removeChild(ta);
        if (ok) resolve(); else reject(new Error('copy_failed'));
      } catch (e) {
        reject(e);
      }
    });
  }

  function createStore(opts) {
    var key = opts.key || 'state';
    var legacyKey = opts.legacyKey || '';
    var defaultValue = opts.defaultValue !== undefined ? opts.defaultValue : [];
    var onData = opts.onData || function () {};
    var buildReminders = opts.buildReminders || null;
    var etag = '';
    var current = readLocal(legacyKey, defaultValue);
    var offline = false;
    var conflict = false;
    var initialLoaded = false;
    var initialRemoteLoaded = false;
    var initPromise = null;
    var writeChain = Promise.resolve();

    function enqueueWrite(task) {
      var run = writeChain.then(task, task);
      writeChain = run.then(function () {}, function () {});
      return run;
    }

    function resolveStatusEl() {
      if (!opts.statusEl) return null;
      return typeof opts.statusEl === 'string' ? document.getElementById(opts.statusEl) : opts.statusEl;
    }

    function setStatus(kind, text, showReload) {
      var el = resolveStatusEl();
      if (!el) return;
      el.className = 'li-sync-bar' + (kind ? ' is-' + kind : '');
      el.textContent = '';
      var span = document.createElement('span');
      span.textContent = text;
      el.appendChild(span);
      var actions = document.createElement('span');
      actions.className = 'li-sync-actions';
      if (showReload) {
        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'sm';
        btn.textContent = '重新加载最新数据';
        btn.onclick = function () { store.reload(); };
        actions.appendChild(btn);
      } else {
        var refresh = document.createElement('button');
        refresh.type = 'button';
        refresh.className = 'ghost sm';
        refresh.textContent = '刷新同步';
        refresh.onclick = function () { store.reload(); };
        actions.appendChild(refresh);
      }
      el.appendChild(actions);
    }

    function syncRemindersNow(data) {
      if (!buildReminders) return Promise.resolve();
      var items = [];
      try {
        items = buildReminders(data) || [];
      } catch (_) {
        items = [];
      }
      return fetch('./__lightisle_kv/_reminders', {
        method: 'PUT',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json',
          'X-LightIsle-Request': '1'
        },
        body: JSON.stringify({ items: items })
      }).catch(function () {});
    }

    function syncReminders(data) {
      return enqueueWrite(function () {
        return syncRemindersNow(data);
      });
    }

    function putRaw(nextData, useIfMatch, forceCreate) {
      var headers = {
        'Content-Type': 'application/json',
        'X-LightIsle-Request': '1'
      };
      if (forceCreate) {
        headers['If-None-Match'] = '*';
      } else if (useIfMatch) {
        if (etag) {
          headers['If-Match'] = etag;
        } else {
          headers['If-None-Match'] = '*';
        }
      }
      return fetch('./__lightisle_kv/' + encodeURIComponent(key), {
        method: 'PUT',
        credentials: 'same-origin',
        headers: headers,
        body: JSON.stringify(nextData)
      });
    }

    function loadRemote() {
      setStatus('', '正在同步家庭共享数据…', false);
      return fetch('./__lightisle_kv/' + encodeURIComponent(key), {
        cache: 'no-store',
        credentials: 'same-origin'
      }).then(function (resp) {
        if (resp.status === 200) {
          etag = resp.headers.get('ETag') || '';
          return resp.json().then(function (remoteData) {
            offline = false;
            conflict = false;
            initialLoaded = true;
            initialRemoteLoaded = true;
            current = remoteData;
            writeLocal(legacyKey, current);
            setStatus('ok', '已连接 LightIsle 家庭共享存储 · 全家实时同步', false);
            onData(current, { source: 'remote', etag: etag, offline: false });
            return current;
          });
        }
        if (resp.status === 404) {
          var localData = readLocal(legacyKey, defaultValue);
          if (isNonEmptyData(localData)) {
            return putRaw(localData, false, true).then(function (putResp) {
              if (putResp.ok) {
                etag = putResp.headers.get('ETag') || '';
                offline = false;
                conflict = false;
                initialLoaded = true;
                initialRemoteLoaded = false;
                current = localData;
                setStatus('ok', '已将本机旧数据自动迁移至家庭共享存储', false);
                syncReminders(current);
                onData(current, { source: 'migrated', etag: etag, offline: false });
                return current;
              }
              if (putResp.status === 412) {
                return loadRemote();
              }
              throw new Error('migrate_failed');
            });
          }
          etag = '';
          offline = false;
          conflict = false;
          initialLoaded = true;
          initialRemoteLoaded = false;
          current = clone(defaultValue);
          setStatus('ok', '已连接 LightIsle 家庭共享存储 · 全家实时同步', false);
          onData(current, { source: 'empty', etag: '', offline: false });
          return current;
        }
        throw new Error('http_' + resp.status);
      }).catch(function () {
        offline = true;
        initialLoaded = true;
        current = readLocal(legacyKey, defaultValue);
        setStatus('warn', '离线只读模式（当前展示本机缓存，连接恢复后可编辑）', true);
        onData(current, { source: 'offline-cache', etag: etag, offline: true });
        return current;
      });
    }

    function save(nextData) {
      var calledBeforeInit = !initialLoaded;
      var payload = clone(nextData);
      return enqueueWrite(function () {
        var waitInit = (!initialLoaded && initPromise) ? initPromise : Promise.resolve();
        return waitInit.then(function () {
          if (!initialLoaded) {
            setStatus('warn', '正在初始化家庭共享存储，请稍候再保存。', false);
            return { ok: false, pending: true };
          }
          if (calledBeforeInit && initialRemoteLoaded) {
            setStatus('warn', '已完成首次云端同步，为防覆盖最新内容请确认后再操作。', false);
            return { ok: false, staleInit: true };
          }
          if (calledBeforeInit && offline) {
            setStatus('warn', '当前处于离线只读状态，更改未写入 NAS，请检查连接后重试。', true);
            return { ok: false, offline: true };
          }
          if (conflict) {
            setStatus('danger', '数据已被其他设备更新，请先点击右侧「重新加载最新数据」再编辑。', true);
            return { ok: false, conflict: true };
          }
          return putRaw(payload, true, false).then(function (resp) {
            if (resp.ok) {
              etag = resp.headers.get('ETag') || etag;
              offline = false;
              conflict = false;
              current = payload;
              writeLocal(legacyKey, current);
              setStatus('ok', '已保存并同步至家庭共享存储', false);
              onData(current, { source: 'saved', etag: etag, offline: false });
              return syncRemindersNow(current).then(function () {
                return { ok: true, etag: etag };
              });
            }
            if (resp.status === 412) {
              conflict = true;
              setStatus('danger', '检测到其他家人刚刚修改了内容，为防止覆盖已暂停保存。', true);
              return { ok: false, conflict: true };
            }
            return resp.json().catch(function () { return {}; }).then(function (errBody) {
              var msg = (errBody && errBody.message) ? errBody.message : ('保存失败（HTTP ' + resp.status + '）');
              setStatus('danger', msg, resp.status === 503);
              return { ok: false, error: msg };
            });
          }).catch(function () {
            offline = true;
            setStatus('warn', '当前处于离线只读状态，更改未写入 NAS，请检查连接后重试。', true);
            return { ok: false, offline: true };
          });
        });
      });
    }

    var store = {
      init: function () {
        onData(current, { source: 'cache-preview', etag: etag, offline: offline });
        initPromise = loadRemote();
        return initPromise;
      },
      reload: function () {
        initPromise = loadRemote();
        return initPromise;
      },
      get: function () { return current; },
      save: save,
      isOffline: function () { return offline; }
    };
    return store;
  }

  window.LightIsleKV = {
    createStore: createStore,
    todayISO: todayISO,
    addDaysISO: addDaysISO,
    daysUntil: daysUntil,
    genId: genId,
    exportJSON: exportJSON,
    copyText: copyText
  };
})();
`
