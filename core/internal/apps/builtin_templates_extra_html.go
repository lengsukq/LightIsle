package apps

const templateMedicineExpiryIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#FF453A"/>
  <rect x="14" y="18" width="36" height="30" rx="7" stroke="#FFFFFF" stroke-width="3.5"/>
  <path d="M24 18v-3a3 3 0 0 1 3-3h10a3 3 0 0 1 3 3v3" stroke="#FFFFFF" stroke-width="3.5"/>
  <path d="M32 25v16M24 33h16" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round"/>
</svg>`

const templateUtilityLedgerIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#0A84FF"/>
  <path d="M35 13L19 35h13l-3 16 16-22H32l3-16z" stroke="#FFFFFF" stroke-width="3.5" stroke-linejoin="round"/>
</svg>`

const templateBabyGrowthIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#FF6B8B"/>
  <path d="M16 44l10-12 9 7 13-18" stroke="#FFFFFF" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="26" cy="32" r="3" fill="#FFFFFF"/>
  <circle cx="35" cy="39" r="3" fill="#FFFFFF"/>
  <circle cx="48" cy="21" r="3" fill="#FFFFFF"/>
</svg>`

const templateMedicineExpiryHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>家庭药箱与证件有效期</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card, input, select { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: rgba(255,255,255,0.12) !important; } }
  .wrap { max-width: 780px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; box-shadow: 0 4px 16px rgba(0,0,0,0.04); }
  h1 { margin: 0 0 4px; font-size: 20px; } p.sub { margin: 0; font-size: 13px; opacity: 0.7; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 14px; }
  .stat { padding: 12px 14px; border-radius: 12px; background: rgba(255,69,58,0.09); }
  .stat b { display: block; font-size: 22px; color: #ff453a; margin-top: 4px; }
  .form, .filters { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  input, select { padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(0,0,0,0.14); font-size: 13px; background: #fff; }
  button { padding: 8px 14px; border-radius: 10px; border: none; background: #ff453a; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; }
  button.ghost { background: rgba(120,120,128,0.16); color: inherit; }
  button.active { background: #1d1d1f; color: #fff; }
  @media (prefers-color-scheme: dark) { button.active { background: #f5f5f7; color: #121214; } }
  .list { display: grid; gap: 8px; }
  .item { display: flex; justify-content: space-between; align-items: center; padding: 12px 14px; border-radius: 12px; border: 1px solid rgba(120,120,128,0.18); gap: 10px; flex-wrap: wrap; }
  .expired { border-color: #ff453a; background: rgba(255,69,58,0.1); }
  .soon { border-color: #ff9f0a; background: rgba(255,159,10,0.09); }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>家庭药箱与证件有效期</h1>
    <p class="sub">集中管理常备药品、护照、身份证、驾照与年检到期日，临期自动高亮预警</p>
    <div class="stats">
      <div class="stat"><span>已过期项目</span><b id="expiredCount">0</b></div>
      <div class="stat"><span>30 天内到期</span><b id="soonCount">0</b></div>
      <div class="stat"><span>全部登记</span><b id="totalCount">0</b></div>
    </div>
    <div class="form">
      <select id="kind"><option value="药品">💊 家庭药品</option><option value="证件">🪪 重要证件</option><option value="食品">🥫 储备食品</option></select>
      <input id="name" placeholder="名称（如：布洛芬 / 护照 / 驾照）" style="flex:1;min-width:170px"/>
      <input id="expiry" type="date" title="到期日期"/>
      <input id="place" placeholder="存放位置或用法备注" style="flex:1;min-width:150px"/>
      <button id="addBtn">登记</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
    <div class="filters">
      <button class="ghost active" data-filter="all">全部</button>
      <button class="ghost" data-filter="药品">💊 药品</button>
      <button class="ghost" data-filter="证件">🪪 证件</button>
      <button class="ghost" data-filter="食品">🥫 食品</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
const KEY = 'lightisle_medicine_expiry_v1';
let currentFilter = 'all';
const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch { return []; } };
const save = (items) => { localStorage.setItem(KEY, JSON.stringify(items)); render(); };
function daysUntil(dateStr) {
  if (!dateStr) return null;
  const target = new Date(dateStr + 'T00:00:00');
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  return Math.ceil((target.getTime() - today.getTime()) / 86400000);
}
function render() {
  const all = load().sort((a, b) => (a.expiry || '9999-99-99').localeCompare(b.expiry || '9999-99-99'));
  let expired = 0, soon = 0;
  all.forEach(it => {
    const d = daysUntil(it.expiry);
    if (d !== null && d < 0) expired++;
    else if (d !== null && d <= 30) soon++;
  });
  document.getElementById('expiredCount').textContent = String(expired);
  document.getElementById('soonCount').textContent = String(soon);
  document.getElementById('totalCount').textContent = String(all.length);
  const items = currentFilter === 'all' ? all : all.filter(it => it.kind === currentFilter);
  const box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) { box.textContent = '暂无到期记录，可在上方登记家中常备药或重要证件有效期。'; return; }
  items.forEach(it => {
    const d = daysUntil(it.expiry);
    const row = document.createElement('div');
    row.className = 'item' + (d !== null && d < 0 ? ' expired' : (d !== null && d <= 30 ? ' soon' : ''));
    const left = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = '[' + it.kind + '] ' + it.name;
    const meta = document.createElement('div');
    meta.style.cssText = 'font-size:12px;opacity:.75;margin-top:3px';
    const status = d === null ? '未设置日期' : (d < 0 ? '已过期 ' + Math.abs(d) + ' 天 (' + it.expiry + ')' : (d === 0 ? '今天到期' : '剩余 ' + d + ' 天 (' + it.expiry + ')'));
    meta.textContent = status + (it.place ? ' · ' + it.place : '');
    left.append(title, meta);
    const del = document.createElement('button');
    del.className = 'ghost';
    del.textContent = '移除';
    del.onclick = () => { const next = load().filter(x => x.id !== it.id); save(next); };
    row.append(left, del);
    box.appendChild(row);
  });
}
document.querySelectorAll('[data-filter]').forEach(btn => {
  btn.onclick = () => {
    currentFilter = btn.dataset.filter;
    document.querySelectorAll('[data-filter]').forEach(b => b.classList.toggle('active', b === btn));
    render();
  };
});
document.getElementById('addBtn').onclick = () => {
  const name = document.getElementById('name').value.trim();
  if (!name) return;
  const items = load();
  items.push({ id: Date.now() + '-' + Math.random().toString(36).slice(2, 6), kind: document.getElementById('kind').value, name, expiry: document.getElementById('expiry').value, place: document.getElementById('place').value.trim() });
  ['name', 'expiry', 'place'].forEach(id => document.getElementById(id).value = '');
  save(items);
};
document.getElementById('exportBtn').onclick = () => {
  const blob = new Blob([JSON.stringify(load(), null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'medicine-expiry.json';
  a.click();
};
render();
</script></body></html>`

const templateUtilityLedgerHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>水电燃气与月度账本</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card, input, select { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: rgba(255,255,255,0.12) !important; } }
  .wrap { max-width: 780px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; box-shadow: 0 4px 16px rgba(0,0,0,0.04); }
  h1 { margin: 0 0 4px; font-size: 20px; } p.sub { margin: 0; font-size: 13px; opacity: 0.7; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 14px; }
  .stat { padding: 12px 14px; border-radius: 12px; background: rgba(10,132,255,0.1); }
  .stat b { display: block; font-size: 22px; color: #0a84ff; margin-top: 4px; }
  .form { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  input, select { padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(0,0,0,0.14); font-size: 13px; background: #fff; }
  button { padding: 8px 14px; border-radius: 10px; border: none; background: #0a84ff; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; }
  button.ghost { background: rgba(120,120,128,0.16); color: inherit; }
  .chart { width: 100%; height: 150px; margin-top: 8px; }
  .list { display: grid; gap: 8px; }
  .item { display: flex; justify-content: space-between; align-items: center; padding: 11px 14px; border-radius: 12px; border: 1px solid rgba(120,120,128,0.18); gap: 10px; flex-wrap: wrap; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>水电燃气与月度账本</h1>
    <p class="sub">记录每月电费、水费、燃气与物业账单，自动绘制近 6 个月趋势柱状图</p>
    <div class="stats">
      <div class="stat"><span>最近一月合计</span><b id="latestMonth">¥0.00</b></div>
      <div class="stat"><span>累计总支出</span><b id="grandTotal">¥0.00</b></div>
      <div class="stat"><span>账单笔数</span><b id="entryCount">0</b></div>
    </div>
    <div class="form">
      <input id="month" type="month"/>
      <select id="type"><option value="电费">⚡ 电费</option><option value="水费">💧 水费</option><option value="燃气">🔥 燃气</option><option value="物业">🏢 物业</option></select>
      <input id="amount" type="number" step="0.01" min="0" placeholder="金额 (元)" style="width:110px"/>
      <input id="usage" placeholder="用量（如：285 度 / 18 吨）" style="flex:1;min-width:150px"/>
      <button id="addBtn">记一笔</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
  </div>
  <div class="card">
    <strong style="font-size:14px">近 6 个月月度走势</strong>
    <svg id="chart" class="chart" viewBox="0 0 600 150" preserveAspectRatio="none"></svg>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
const KEY = 'lightisle_utility_ledger_v1';
document.getElementById('month').value = new Date().toISOString().slice(0, 7);
const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch { return []; } };
const save = (items) => { localStorage.setItem(KEY, JSON.stringify(items)); render(); };
function renderChart(byMonth) {
  const svg = document.getElementById('chart');
  svg.textContent = '';
  const keys = Object.keys(byMonth).sort().slice(-6);
  if (!keys.length) return;
  const max = Math.max(...keys.map(k => byMonth[k]), 1);
  const w = 600 / keys.length;
  keys.forEach((k, i) => {
    const val = byMonth[k];
    const h = Math.max(8, (val / max) * 100);
    const x = i * w + w * 0.2;
    const bw = w * 0.6;
    const y = 122 - h;
    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    rect.setAttribute('x', x); rect.setAttribute('y', y); rect.setAttribute('width', bw); rect.setAttribute('height', h); rect.setAttribute('rx', '6'); rect.setAttribute('fill', '#0a84ff');
    const lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    lbl.setAttribute('x', x + bw / 2); lbl.setAttribute('y', 142); lbl.setAttribute('text-anchor', 'middle'); lbl.setAttribute('font-size', '11'); lbl.setAttribute('fill', 'currentColor'); lbl.textContent = k;
    const top = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    top.setAttribute('x', x + bw / 2); top.setAttribute('y', Math.max(12, y - 4)); top.setAttribute('text-anchor', 'middle'); top.setAttribute('font-size', '11'); top.setAttribute('fill', 'currentColor'); top.textContent = '¥' + val.toFixed(0);
    svg.append(rect, lbl, top);
  });
}
function render() {
  const items = load().sort((a, b) => (b.month || '').localeCompare(a.month || ''));
  const byMonth = {};
  let total = 0;
  items.forEach(it => {
    const amt = Number(it.amount) || 0;
    total += amt;
    if (it.month) byMonth[it.month] = (byMonth[it.month] || 0) + amt;
  });
  const sortedMonths = Object.keys(byMonth).sort();
  const latest = sortedMonths.length ? byMonth[sortedMonths[sortedMonths.length - 1]] : 0;
  document.getElementById('latestMonth').textContent = '¥' + latest.toFixed(2);
  document.getElementById('grandTotal').textContent = '¥' + total.toFixed(2);
  document.getElementById('entryCount').textContent = String(items.length);
  renderChart(byMonth);
  const box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) { box.textContent = '暂无水电燃气记录，在上方添加本月账单吧。'; return; }
  items.forEach((it, idx) => {
    const row = document.createElement('div');
    row.className = 'item';
    const left = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = it.month + ' · ' + it.type + ' ¥' + (Number(it.amount) || 0).toFixed(2);
    const meta = document.createElement('div');
    meta.style.cssText = 'font-size:12px;opacity:.72;margin-top:2px';
    meta.textContent = it.usage || '未填写用量备注';
    left.append(title, meta);
    const del = document.createElement('button');
    del.className = 'ghost';
    del.textContent = '删除';
    del.onclick = () => { const next = load(); next.splice(idx, 1); save(next); };
    row.append(left, del);
    box.appendChild(row);
  });
}
document.getElementById('addBtn').onclick = () => {
  const month = document.getElementById('month').value;
  const amount = parseFloat(document.getElementById('amount').value || '0');
  if (!month || !(amount >= 0)) return;
  const items = load();
  items.push({ month, type: document.getElementById('type').value, amount, usage: document.getElementById('usage').value.trim() });
  document.getElementById('amount').value = '';
  document.getElementById('usage').value = '';
  save(items);
};
document.getElementById('exportBtn').onclick = () => {
  const blob = new Blob([JSON.stringify(load(), null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'utility-ledger.json';
  a.click();
};
render();
</script></body></html>`

const templateBabyGrowthHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>宝宝成长身高体重记录</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 24px; }
  @media (prefers-color-scheme: dark) { body { background: #121214; color: #f5f5f7; } .card, input { background: #1c1c1e !important; color: #f5f5f7 !important; border-color: rgba(255,255,255,0.12) !important; } }
  .wrap { max-width: 780px; margin: 0 auto; display: grid; gap: 16px; }
  .card { background: #fff; border: 1px solid rgba(0,0,0,0.08); border-radius: 16px; padding: 20px; box-shadow: 0 4px 16px rgba(0,0,0,0.04); }
  h1 { margin: 0 0 4px; font-size: 20px; } p.sub { margin: 0; font-size: 13px; opacity: 0.7; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin-top: 14px; }
  .stat { padding: 12px 14px; border-radius: 12px; background: rgba(255,107,139,0.12); }
  .stat b { display: block; font-size: 22px; color: #ff4f79; margin-top: 4px; }
  .form { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  input { padding: 8px 12px; border-radius: 10px; border: 1px solid rgba(0,0,0,0.14); font-size: 13px; background: #fff; }
  button { padding: 8px 14px; border-radius: 10px; border: none; background: #ff4f79; color: #fff; font-size: 13px; font-weight: 600; cursor: pointer; }
  button.ghost { background: rgba(120,120,128,0.16); color: inherit; }
  .chart { width: 100%; height: 150px; margin-top: 8px; }
  .list { display: grid; gap: 8px; }
  .item { display: flex; justify-content: space-between; align-items: center; padding: 11px 14px; border-radius: 12px; border: 1px solid rgba(120,120,128,0.18); gap: 10px; flex-wrap: wrap; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>宝宝成长身高体重记录</h1>
    <p class="sub">记录每次体检的身高、体重与成长里程碑，自动绘制成长曲线</p>
    <div class="stats">
      <div class="stat"><span>最新身高</span><b id="latestHeight">-- cm</b></div>
      <div class="stat"><span>最新体重</span><b id="latestWeight">-- kg</b></div>
      <div class="stat"><span>成长记录</span><b id="recordCount">0 条</b></div>
    </div>
    <div class="form">
      <input id="date" type="date"/>
      <input id="height" type="number" step="0.1" min="0" placeholder="身高 (cm)" style="width:110px"/>
      <input id="weight" type="number" step="0.05" min="0" placeholder="体重 (kg)" style="width:110px"/>
      <input id="milestone" placeholder="里程碑备注（如：第一次翻身 / 会叫爸爸）" style="flex:1;min-width:180px"/>
      <button id="addBtn">记录成长</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
  </div>
  <div class="card">
    <strong style="font-size:14px">身高成长曲线 (cm)</strong>
    <svg id="chart" class="chart" viewBox="0 0 600 150"></svg>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
const KEY = 'lightisle_baby_growth_v1';
document.getElementById('date').value = new Date().toISOString().slice(0, 10);
const load = () => { try { return JSON.parse(localStorage.getItem(KEY) || '[]'); } catch { return []; } };
const save = (items) => { localStorage.setItem(KEY, JSON.stringify(items)); render(); };
function renderChart(items) {
  const svg = document.getElementById('chart');
  svg.textContent = '';
  const pts = items.filter(it => Number(it.height) > 0).slice(-12);
  if (!pts.length) return;
  const vals = pts.map(p => Number(p.height));
  const min = Math.min(...vals) - 2, max = Math.max(...vals) + 2;
  const span = Math.max(1, max - min);
  const coords = pts.map((p, i) => {
    const x = pts.length === 1 ? 300 : 36 + (i / (pts.length - 1)) * 528;
    const y = 120 - ((Number(p.height) - min) / span) * 92;
    return { x, y, p };
  });
  const poly = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
  poly.setAttribute('fill', 'none'); poly.setAttribute('stroke', '#ff4f79'); poly.setAttribute('stroke-width', '3');
  poly.setAttribute('points', coords.map(c => c.x + ',' + c.y).join(' '));
  svg.appendChild(poly);
  coords.forEach(c => {
    const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', c.x); dot.setAttribute('cy', c.y); dot.setAttribute('r', '4.5'); dot.setAttribute('fill', '#ff4f79');
    const lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    lbl.setAttribute('x', c.x); lbl.setAttribute('y', 142); lbl.setAttribute('text-anchor', 'middle'); lbl.setAttribute('font-size', '10'); lbl.setAttribute('fill', 'currentColor'); lbl.textContent = c.p.date.slice(5);
    svg.append(dot, lbl);
  });
}
function render() {
  const asc = load().sort((a, b) => (a.date || '').localeCompare(b.date || ''));
  const latest = asc[asc.length - 1];
  document.getElementById('latestHeight').textContent = latest && latest.height ? latest.height + ' cm' : '-- cm';
  document.getElementById('latestWeight').textContent = latest && latest.weight ? latest.weight + ' kg' : '-- kg';
  document.getElementById('recordCount').textContent = asc.length + ' 条';
  renderChart(asc);
  const box = document.getElementById('list');
  box.textContent = '';
  if (!asc.length) { box.textContent = '暂无成长记录，添加宝宝的第一次身高体重吧。'; return; }
  [...asc].reverse().forEach(it => {
    const row = document.createElement('div');
    row.className = 'item';
    const left = document.createElement('div');
    const title = document.createElement('strong');
    title.textContent = it.date + (it.height ? ' · 身高 ' + it.height + ' cm' : '') + (it.weight ? ' · 体重 ' + it.weight + ' kg' : '');
    const meta = document.createElement('div');
    meta.style.cssText = 'font-size:12px;opacity:.72;margin-top:2px';
    meta.textContent = it.milestone || '常规体检记录';
    left.append(title, meta);
    const del = document.createElement('button');
    del.className = 'ghost';
    del.textContent = '删除';
    del.onclick = () => { save(load().filter(x => x.id !== it.id)); };
    row.append(left, del);
    box.appendChild(row);
  });
}
document.getElementById('addBtn').onclick = () => {
  const date = document.getElementById('date').value;
  const height = document.getElementById('height').value.trim();
  const weight = document.getElementById('weight').value.trim();
  const milestone = document.getElementById('milestone').value.trim();
  if (!date || (!height && !weight && !milestone)) return;
  const items = load();
  items.push({ id: Date.now() + '-' + Math.random().toString(36).slice(2, 6), date, height, weight, milestone });
  ['height', 'weight', 'milestone'].forEach(id => document.getElementById(id).value = '');
  save(items);
};
document.getElementById('exportBtn').onclick = () => {
  const blob = new Blob([JSON.stringify(load(), null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'baby-growth.json';
  a.click();
};
render();
</script></body></html>`
