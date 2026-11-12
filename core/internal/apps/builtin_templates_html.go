package apps

const templateSubscriptionsIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#5E5CE6"/>
  <rect x="12" y="18" width="40" height="28" rx="6" stroke="#FFFFFF" stroke-width="3.5"/>
  <path d="M12 27h40M20 37h10" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round"/>
</svg>`

const templateWarrantyIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#30D158"/>
  <path d="M32 12l16 6v13c0 11-7 18.5-16 21-9-2.5-16-10-16-21V18l16-6z" stroke="#FFFFFF" stroke-width="3.5" stroke-linejoin="round"/>
  <path d="M25 32l5 5 9-10" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`

const templateFamilyBoardIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#FF9F0A"/>
  <rect x="15" y="14" width="34" height="36" rx="6" stroke="#FFFFFF" stroke-width="3.5"/>
  <path d="M23 25h18M23 33h18M23 41h11" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round"/>
</svg>`

const templateSubscriptionsHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>家庭账单与订阅管家</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card, input, select { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: rgba(255,255,255,0.12) !important; } }
  .wrap { max-width: 760px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; box-shadow: 0 4px 16px rgba(0,0,0,0.04); }
  h1 { margin: 0 0 4px; font-size: 20px; } p.sub { margin: 0; font-size: 13px; opacity: 0.7; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-top: 14px; }
  .stat { padding: 12px 14px; border-radius: 12px; background: rgba(94,92,230,0.1); }
  .stat b { display: block; font-size: 22px; color: #5e5ce6; margin-top: 4px; }
  .form { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  input, select { padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(0,0,0,0.14); font-size: 13px; background: #fff; }
  button { padding: 8px 14px; border-radius: 10px; border: none; background: #5e5ce6; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; }
  button.ghost { background: rgba(120,120,128,0.16); color: inherit; }
  .list { display: grid; gap: 8px; margin-top: 12px; }
  .item { display: flex; justify-content: space-between; align-items: center; padding: 12px 14px; border-radius: 12px; border: 1px solid rgba(120,120,128,0.18); gap: 10px; flex-wrap: wrap; }
  .soon { border-color: #ff9f0a; background: rgba(255,159,10,0.08); }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>家庭账单与订阅管家</h1>
    <p class="sub">纯本地静态轻应用（0 MB 后台占用）· 数据保存在当前浏览器本地并支持 JSON 备份</p>
    <div class="stats">
      <div class="stat"><span>折合月均支出</span><b id="monthlyTotal">¥0.00</b></div>
      <div class="stat"><span>预计年度总额</span><b id="yearlyTotal">¥0.00</b></div>
      <div class="stat"><span>7 天内续费项</span><b id="soonCount">0</b></div>
    </div>
    <div class="form">
      <input id="name" placeholder="项目名称（如：千兆宽带 / Apple One）" style="flex:1;min-width:180px"/>
      <input id="price" type="number" step="0.01" min="0" placeholder="金额 (元)" style="width:105px"/>
      <select id="cycle"><option value="month">按月</option><option value="year">按年</option></select>
      <input id="nextDate" type="date"/>
      <button id="addBtn">添加记录</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
const KEY = 'lightisle_family_subscriptions_v1';
const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch { return []; } };
const save = (items) => { localStorage.setItem(KEY, JSON.stringify(items)); render(); };
function render() {
  const items = load();
  let monthly = 0, soon = 0;
  const now = Date.now();
  const box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) { box.textContent = '暂无订阅记录，可在上方添加宽带、视频会员或物业缴费提醒。'; }
  items.forEach((it, idx) => {
    const p = Number(it.price) || 0;
    monthly += it.cycle === 'year' ? p / 12 : p;
    const days = it.nextDate ? Math.ceil((new Date(it.nextDate).getTime() - now) / 86400000) : 999;
    if (days >= 0 && days <= 7) soon++;
    const row = document.createElement('div');
    row.className = 'item' + (days >= 0 && days <= 7 ? ' soon' : '');
    const left = document.createElement('div');
    left.innerHTML = '<strong></strong><div style="font-size:12px;opacity:.72;margin-top:2px"></div>';
    left.querySelector('strong').textContent = it.name;
    left.querySelector('div').textContent = '¥' + p.toFixed(2) + (it.cycle === 'year' ? ' / 年' : ' / 月') + (it.nextDate ? ' · 下次续费 ' + it.nextDate : '');
    const del = document.createElement('button');
    del.className = 'ghost';
    del.textContent = '移除';
    del.onclick = () => { const next = load(); next.splice(idx, 1); save(next); };
    row.append(left, del);
    box.appendChild(row);
  });
  document.getElementById('monthlyTotal').textContent = '¥' + monthly.toFixed(2);
  document.getElementById('yearlyTotal').textContent = '¥' + (monthly * 12).toFixed(2);
  document.getElementById('soonCount').textContent = String(soon);
}
document.getElementById('addBtn').onclick = () => {
  const name = document.getElementById('name').value.trim();
  const price = parseFloat(document.getElementById('price').value || '0');
  if (!name || !(price >= 0)) return;
  const items = load();
  items.push({ name, price, cycle: document.getElementById('cycle').value, nextDate: document.getElementById('nextDate').value });
  document.getElementById('name').value = '';
  document.getElementById('price').value = '';
  save(items);
};
document.getElementById('exportBtn').onclick = () => {
  const blob = new Blob([JSON.stringify(load(), null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'family-subscriptions.json';
  a.click();
};
render();
</script></body></html>`

const templateWarrantyHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>电子发票与保修卡夹</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card, input { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: rgba(255,255,255,0.12) !important; } }
  .wrap { max-width: 760px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; }
  h1 { margin: 0 0 4px; font-size: 20px; } p.sub { margin: 0; font-size: 13px; opacity: 0.7; }
  .form { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
  input { padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(0,0,0,0.14); font-size: 13px; background: #fff; }
  button { padding: 8px 14px; border-radius: 10px; border: none; background: #30d158; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; }
  button.ghost { background: rgba(120,120,128,0.16); color: inherit; }
  .list { display: grid; gap: 8px; }
  .item { display: flex; justify-content: space-between; align-items: center; padding: 12px 14px; border-radius: 12px; border: 1px solid rgba(120,120,128,0.18); gap: 10px; flex-wrap: wrap; }
  .expiring { border-color: #ff9f0a; background: rgba(255,159,10,0.08); }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>电子发票与保修卡夹</h1>
    <p class="sub">管理家电数码序列号、保修截止日与发票在轻屿 NAS 中的存放路径备注</p>
    <div class="form">
      <input id="device" placeholder="设备名称（如：Mac mini M4 / 洗碗机）" style="flex:1;min-width:180px"/>
      <input id="sn" placeholder="序列号 / 订单号" style="width:150px"/>
      <input id="until" type="date" title="保修截止日期"/>
      <input id="note" placeholder="发票路径或售后电话备注" style="flex:1;min-width:180px"/>
      <button id="addBtn">登记设备</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
const KEY = 'lightisle_warranty_vault_v1';
const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch { return []; } };
const save = (items) => { localStorage.setItem(KEY, JSON.stringify(items)); render(); };
function render() {
  const items = load();
  const box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) { box.textContent = '暂无保修卡记录，登记后可随时核对过保时间与发票归档位置。'; return; }
  const now = Date.now();
  items.forEach((it, idx) => {
    const days = it.until ? Math.ceil((new Date(it.until).getTime() - now) / 86400000) : null;
    const row = document.createElement('div');
    row.className = 'item' + (days !== null && days >= 0 && days <= 30 ? ' expiring' : '');
    const info = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = it.device + (it.sn ? ' · ' + it.sn : '');
    const meta = document.createElement('div');
    meta.style.cssText = 'font-size:12px;opacity:.75;margin-top:3px';
    const status = days === null ? '长期/未设截止日' : (days < 0 ? '已过保' : '剩余 ' + days + ' 天 (' + it.until + ')');
    meta.textContent = status + (it.note ? ' · ' + it.note : '');
    info.append(title, meta);
    const del = document.createElement('button');
    del.className = 'ghost';
    del.textContent = '删除';
    del.onclick = () => { const next = load(); next.splice(idx, 1); save(next); };
    row.append(info, del);
    box.appendChild(row);
  });
}
document.getElementById('addBtn').onclick = () => {
  const device = document.getElementById('device').value.trim();
  if (!device) return;
  const items = load();
  items.unshift({
    device,
    sn: document.getElementById('sn').value.trim(),
    until: document.getElementById('until').value,
    note: document.getElementById('note').value.trim()
  });
  ['device', 'sn', 'until', 'note'].forEach(id => document.getElementById(id).value = '');
  save(items);
};
render();
</script></body></html>`

const templateFamilyBoardHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>家庭留言板与采购清单</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card, input, select { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: rgba(255,255,255,0.12) !important; } }
  .wrap { max-width: 760px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; }
  h1 { margin: 0 0 4px; font-size: 20px; } p.sub { margin: 0; font-size: 13px; opacity: 0.7; }
  .form { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 14px; }
  input, select { padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(0,0,0,0.14); font-size: 13px; background: #fff; }
  button { padding: 8px 14px; border-radius: 10px; border: none; background: #ff9f0a; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; }
  button.ghost { background: rgba(120,120,128,0.16); color: inherit; }
  .list { display: grid; gap: 8px; }
  .item { display: flex; justify-content: space-between; align-items: center; padding: 11px 14px; border-radius: 12px; border: 1px solid rgba(120,120,128,0.18); gap: 10px; }
  .done strong { text-decoration: line-through; opacity: 0.5; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>家庭留言板与采购清单</h1>
    <p class="sub">随手记录周末采购食材、家务待办与家人温馨留言</p>
    <div class="form">
      <select id="tag"><option value="采购">🛒 采购</option><option value="留言">💬 留言</option><option value="待办">📌 待办</option></select>
      <input id="text" placeholder="输入采购物品或家庭留言…" style="flex:1;min-width:200px"/>
      <button id="addBtn">发布</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
const KEY = 'lightisle_family_board_v1';
const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch { return []; } };
const save = (items) => { localStorage.setItem(KEY, JSON.stringify(items)); render(); };
function render() {
  const items = load();
  const box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) { box.textContent = '还没有留言或待采购项，添加第一条家庭备忘吧！'; return; }
  items.forEach((it, idx) => {
    const row = document.createElement('div');
    row.className = 'item' + (it.done ? ' done' : '');
    const left = document.createElement('label');
    left.style.cssText = 'display:flex;align-items:center;gap:10px;cursor:pointer;flex:1';
    const cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = !!it.done;
    cb.onchange = () => { const next = load(); next[idx].done = cb.checked; save(next); };
    const txt = document.createElement('strong');
    txt.textContent = '[' + it.tag + '] ' + it.text;
    left.append(cb, txt);
    const del = document.createElement('button');
    del.className = 'ghost';
    del.textContent = '清除';
    del.onclick = () => { const next = load(); next.splice(idx, 1); save(next); };
    row.append(left, del);
    box.appendChild(row);
  });
}
document.getElementById('addBtn').onclick = () => {
  const text = document.getElementById('text').value.trim();
  if (!text) return;
  const items = load();
  items.unshift({ tag: document.getElementById('tag').value, text, done: false });
  document.getElementById('text').value = '';
  save(items);
};
render();
</script></body></html>`
