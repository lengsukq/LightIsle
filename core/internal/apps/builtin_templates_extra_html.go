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
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #dc2626; --accent-soft: rgba(220, 38, 38, 0.10); }
  @media (prefers-color-scheme: dark) { :root { --accent: #ff8585; --accent-soft: rgba(255, 133, 133, 0.18); } }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>家庭药箱与证件有效期</h1>
    <p class="sub">集中管理常备药品、护照、身份证、驾照与年检到期日 · 全家共享并自动推送 30 天临期预警</p>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
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
      <button class="ghost active sm" data-filter="all">全部</button>
      <button class="ghost sm" data-filter="药品">💊 药品</button>
      <button class="ghost sm" data-filter="证件">🪪 证件</button>
      <button class="ghost sm" data-filter="食品">🥫 食品</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
var currentFilter = 'all';
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_medicine_expiry_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  buildReminders: function (items) {
    return (items || []).filter(function (it) { return it && it.expiry; }).map(function (it, idx) {
      return {
        id: it.id || ('exp-' + idx + '-' + it.name),
        title: '[' + (it.kind || '到期') + '] ' + it.name,
        dueDate: it.expiry,
        warnDays: 30,
        category: 'expiry'
      };
    });
  },
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function render() {
  var all = stateItems.slice().sort(function (a, b) {
    return (a.expiry || '9999-99-99').localeCompare(b.expiry || '9999-99-99');
  });
  var expired = 0, soon = 0;
  all.forEach(function (it) {
    var d = LightIsleKV.daysUntil(it.expiry);
    if (d !== null && d < 0) expired++;
    else if (d !== null && d <= 30) soon++;
  });
  document.getElementById('expiredCount').textContent = String(expired);
  document.getElementById('soonCount').textContent = String(soon);
  document.getElementById('totalCount').textContent = String(all.length);
  var items = currentFilter === 'all' ? all : all.filter(function (it) { return it.kind === currentFilter; });
  var box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '暂无到期记录，可在上方登记家中常备药或重要证件有效期。';
    box.appendChild(empty);
    return;
  }
  items.forEach(function (it) {
    var d = LightIsleKV.daysUntil(it.expiry);
    var row = document.createElement('div');
    row.className = 'item' + (d !== null && d < 0 ? ' expired' : (d !== null && d <= 30 ? ' soon' : ''));
    var left = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = '[' + it.kind + '] ' + it.name;
    var meta = document.createElement('div');
    meta.className = 'meta';
    var status = d === null ? '未设置日期' : (d < 0 ? '已过期 ' + Math.abs(d) + ' 天 (' + it.expiry + ')' : (d === 0 ? '今天到期' : '剩余 ' + d + ' 天 (' + it.expiry + ')'));
    meta.textContent = status + (it.place ? ' · ' + it.place : '');
    left.append(title, meta);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '移除';
    del.onclick = function () {
      var next = stateItems.filter(function (x) { return x.id !== it.id; });
      store.save(next);
    };
    row.append(left, del);
    box.appendChild(row);
  });
}

document.querySelectorAll('[data-filter]').forEach(function (btn) {
  btn.onclick = function () {
    currentFilter = btn.dataset.filter;
    document.querySelectorAll('[data-filter]').forEach(function (b) { b.classList.toggle('active', b === btn); });
    render();
  };
});
document.getElementById('addBtn').onclick = function () {
  var name = document.getElementById('name').value.trim();
  if (!name) return;
  var next = stateItems.concat([{
    id: LightIsleKV.genId(),
    kind: document.getElementById('kind').value,
    name: name,
    expiry: document.getElementById('expiry').value,
    place: document.getElementById('place').value.trim()
  }]);
  store.save(next).then(function (res) {
    if (res && res.ok) {
      ['name', 'expiry', 'place'].forEach(function (id) { document.getElementById(id).value = ''; });
    }
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('medicine-expiry.json', stateItems);
};
store.init();
</script></body></html>`

const templateUtilityLedgerHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>水电燃气与月度账本</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #0a84ff; --accent-soft: rgba(10, 132, 255, 0.11); }
  @media (prefers-color-scheme: dark) { :root { --accent: #6cb8ff; --accent-soft: rgba(108, 184, 255, 0.18); } }
  .chart { width: 100%; height: 150px; margin-top: 8px; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>水电燃气与月度账本</h1>
    <p class="sub">记录每月电费、水费、燃气与物业账单，自动绘制近 6 个月趋势柱状图 · 全家共享存储</p>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
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
    <h2>近 6 个月月度走势</h2>
    <svg id="chart" class="chart" viewBox="0 0 600 150" preserveAspectRatio="none"></svg>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
document.getElementById('month').value = LightIsleKV.todayISO().slice(0, 7);
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_utility_ledger_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function renderChart(byMonth) {
  var svg = document.getElementById('chart');
  svg.textContent = '';
  var keys = Object.keys(byMonth).sort().slice(-6);
  if (!keys.length) return;
  var max = Math.max.apply(null, keys.map(function (k) { return byMonth[k]; }).concat([1]));
  var w = 600 / keys.length;
  keys.forEach(function (k, i) {
    var val = byMonth[k];
    var h = Math.max(8, (val / max) * 100);
    var x = i * w + w * 0.2;
    var bw = w * 0.6;
    var y = 122 - h;
    var rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
    rect.setAttribute('x', x); rect.setAttribute('y', y); rect.setAttribute('width', bw); rect.setAttribute('height', h); rect.setAttribute('rx', '6'); rect.setAttribute('fill', 'var(--accent)');
    var lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    lbl.setAttribute('x', x + bw / 2); lbl.setAttribute('y', 142); lbl.setAttribute('text-anchor', 'middle'); lbl.setAttribute('font-size', '11'); lbl.setAttribute('fill', 'currentColor'); lbl.textContent = k;
    var top = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    top.setAttribute('x', x + bw / 2); top.setAttribute('y', Math.max(12, y - 4)); top.setAttribute('text-anchor', 'middle'); top.setAttribute('font-size', '11'); top.setAttribute('fill', 'currentColor'); top.textContent = '¥' + val.toFixed(0);
    svg.append(rect, lbl, top);
  });
}

function render() {
  var items = stateItems.map(function (it, idx) { return { it: it, idx: idx }; }).sort(function (a, b) {
    return (b.it.month || '').localeCompare(a.it.month || '');
  });
  var byMonth = {};
  var total = 0;
  items.forEach(function (entry) {
    var amt = Number(entry.it.amount) || 0;
    total += amt;
    if (entry.it.month) byMonth[entry.it.month] = (byMonth[entry.it.month] || 0) + amt;
  });
  var sortedMonths = Object.keys(byMonth).sort();
  var latest = sortedMonths.length ? byMonth[sortedMonths[sortedMonths.length - 1]] : 0;
  document.getElementById('latestMonth').textContent = '¥' + latest.toFixed(2);
  document.getElementById('grandTotal').textContent = '¥' + total.toFixed(2);
  document.getElementById('entryCount').textContent = String(items.length);
  renderChart(byMonth);
  var box = document.getElementById('list');
  box.textContent = '';
  if (!items.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '暂无水电燃气记录，在上方添加本月账单吧。';
    box.appendChild(empty);
    return;
  }
  items.forEach(function (entry) {
    var it = entry.it;
    var row = document.createElement('div');
    row.className = 'item';
    var left = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = it.month + ' · ' + it.type + ' ¥' + (Number(it.amount) || 0).toFixed(2);
    var meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = it.usage || '未填写用量备注';
    left.append(title, meta);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '删除';
    del.onclick = function () {
      var next = stateItems.filter(function (_, i) { return i !== entry.idx; });
      store.save(next);
    };
    row.append(left, del);
    box.appendChild(row);
  });
}

document.getElementById('addBtn').onclick = function () {
  var month = document.getElementById('month').value;
  var amount = parseFloat(document.getElementById('amount').value || '0');
  if (!month || !(amount >= 0)) return;
  var next = stateItems.concat([{
    id: LightIsleKV.genId(),
    month: month,
    type: document.getElementById('type').value,
    amount: amount,
    usage: document.getElementById('usage').value.trim()
  }]);
  store.save(next).then(function (res) {
    if (res && res.ok) {
      document.getElementById('amount').value = '';
      document.getElementById('usage').value = '';
    }
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('utility-ledger.json', stateItems);
};
store.init();
</script></body></html>`

const templateBabyGrowthHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>宝宝成长身高体重记录</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #e14d72; --accent-soft: rgba(225, 77, 114, 0.11); }
  @media (prefers-color-scheme: dark) { :root { --accent: #ff8aa8; --accent-soft: rgba(255, 138, 168, 0.18); } }
  .chart { width: 100%; height: 150px; margin-top: 8px; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>宝宝成长身高体重记录</h1>
    <p class="sub">记录每次体检的身高、体重与成长里程碑，自动绘制成长曲线 · 全家共同记录</p>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
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
    <h2>身高成长曲线 (cm)</h2>
    <svg id="chart" class="chart" viewBox="0 0 600 150"></svg>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
document.getElementById('date').value = LightIsleKV.todayISO();
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_baby_growth_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function renderChart(items) {
  var svg = document.getElementById('chart');
  svg.textContent = '';
  var pts = items.filter(function (it) { return Number(it.height) > 0; }).slice(-12);
  if (!pts.length) return;
  var vals = pts.map(function (p) { return Number(p.height); });
  var min = Math.min.apply(null, vals) - 2;
  var max = Math.max.apply(null, vals) + 2;
  var span = Math.max(1, max - min);
  var coords = pts.map(function (p, i) {
    var x = pts.length === 1 ? 300 : 36 + (i / (pts.length - 1)) * 528;
    var y = 120 - ((Number(p.height) - min) / span) * 92;
    return { x: x, y: y, p: p };
  });
  var poly = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
  poly.setAttribute('fill', 'none'); poly.setAttribute('stroke', 'var(--accent)'); poly.setAttribute('stroke-width', '3');
  poly.setAttribute('points', coords.map(function (c) { return c.x + ',' + c.y; }).join(' '));
  svg.appendChild(poly);
  coords.forEach(function (c) {
    var dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', c.x); dot.setAttribute('cy', c.y); dot.setAttribute('r', '4.5'); dot.setAttribute('fill', 'var(--accent)');
    var lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    lbl.setAttribute('x', c.x); lbl.setAttribute('y', 142); lbl.setAttribute('text-anchor', 'middle'); lbl.setAttribute('font-size', '10'); lbl.setAttribute('fill', 'currentColor'); lbl.textContent = (c.p.date || '').slice(5);
    svg.append(dot, lbl);
  });
}

function render() {
  var asc = stateItems.slice().sort(function (a, b) { return (a.date || '').localeCompare(b.date || ''); });
  var latest = asc[asc.length - 1];
  document.getElementById('latestHeight').textContent = latest && latest.height ? latest.height + ' cm' : '-- cm';
  document.getElementById('latestWeight').textContent = latest && latest.weight ? latest.weight + ' kg' : '-- kg';
  document.getElementById('recordCount').textContent = asc.length + ' 条';
  renderChart(asc);
  var box = document.getElementById('list');
  box.textContent = '';
  if (!asc.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '暂无成长记录，添加宝宝的第一次身高体重吧。';
    box.appendChild(empty);
    return;
  }
  asc.slice().reverse().forEach(function (it) {
    var row = document.createElement('div');
    row.className = 'item';
    var left = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = it.date + (it.height ? ' · 身高 ' + it.height + ' cm' : '') + (it.weight ? ' · 体重 ' + it.weight + ' kg' : '');
    var meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = it.milestone || '常规体检记录';
    left.append(title, meta);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '删除';
    del.onclick = function () {
      store.save(stateItems.filter(function (x) { return x.id !== it.id; }));
    };
    row.append(left, del);
    box.appendChild(row);
  });
}

document.getElementById('addBtn').onclick = function () {
  var date = document.getElementById('date').value;
  var height = document.getElementById('height').value.trim();
  var weight = document.getElementById('weight').value.trim();
  var milestone = document.getElementById('milestone').value.trim();
  if (!date || (!height && !weight && !milestone)) return;
  var next = stateItems.concat([{
    id: LightIsleKV.genId(),
    date: date,
    height: height,
    weight: weight,
    milestone: milestone
  }]);
  store.save(next).then(function (res) {
    if (res && res.ok) {
      ['height', 'weight', 'milestone'].forEach(function (id) { document.getElementById(id).value = ''; });
    }
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('baby-growth.json', stateItems);
};
store.init();
</script></body></html>`
