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
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #5e5ce6; --accent-soft: rgba(94, 92, 230, 0.11); }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>家庭账单与订阅管家</h1>
    <p class="sub">0 MB 静态轻应用 · 全家共享存储并自动接入 LightIsle 续费到期通知</p>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
    <div class="stats">
      <div class="stat"><span>折合月均支出</span><b id="monthlyTotal">¥0.00</b></div>
      <div class="stat"><span>预计年度总额</span><b id="yearlyTotal">¥0.00</b></div>
      <div class="stat"><span>7 天内续费项</span><b id="soonCount">0</b></div>
    </div>
    <div class="form">
      <input id="name" placeholder="项目名称（如：千兆宽带 / Apple One）" style="flex:1;min-width:180px"/>
      <input id="price" type="number" step="0.01" min="0" placeholder="金额 (元)" style="width:105px"/>
      <select id="cycle"><option value="month">按月</option><option value="year">按年</option></select>
      <input id="nextDate" type="date" title="下次续费日期"/>
      <button id="addBtn">添加记录</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_family_subscriptions_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  buildReminders: function (items) {
    return (items || []).filter(function (it) { return it && it.nextDate; }).map(function (it, idx) {
      return {
        id: it.id || ('sub-' + idx + '-' + it.name),
        title: '续费提醒：' + it.name,
        dueDate: it.nextDate,
        warnDays: 7,
        category: 'subscription'
      };
    });
  },
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function render() {
  var monthly = 0, soon = 0;
  var box = document.getElementById('list');
  box.textContent = '';
  if (!stateItems.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '暂无订阅记录，可在上方添加宽带、视频会员或物业缴费提醒。';
    box.appendChild(empty);
  }
  stateItems.forEach(function (it, idx) {
    var p = Number(it.price) || 0;
    monthly += it.cycle === 'year' ? p / 12 : p;
    var days = LightIsleKV.daysUntil(it.nextDate);
    if (days !== null && days >= 0 && days <= 7) soon++;
    var row = document.createElement('div');
    row.className = 'item' + (days !== null && days < 0 ? ' expired' : (days !== null && days <= 7 ? ' soon' : ''));
    var left = document.createElement('div');
    var strong = document.createElement('strong');
    strong.textContent = it.name;
    var meta = document.createElement('div');
    meta.className = 'meta';
    var datePart = '';
    if (it.nextDate) {
      if (days < 0) datePart = ' · 已过期 ' + Math.abs(days) + ' 天 (' + it.nextDate + ')';
      else if (days === 0) datePart = ' · 今天续费 (' + it.nextDate + ')';
      else datePart = ' · 下次续费 ' + it.nextDate + '（剩余 ' + days + ' 天）';
    }
    meta.textContent = '¥' + p.toFixed(2) + (it.cycle === 'year' ? ' / 年' : ' / 月') + datePart;
    left.append(strong, meta);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '移除';
    del.onclick = function () {
      var next = stateItems.filter(function (_, i) { return i !== idx; });
      store.save(next);
    };
    row.append(left, del);
    box.appendChild(row);
  });
  document.getElementById('monthlyTotal').textContent = '¥' + monthly.toFixed(2);
  document.getElementById('yearlyTotal').textContent = '¥' + (monthly * 12).toFixed(2);
  document.getElementById('soonCount').textContent = String(soon);
}

document.getElementById('addBtn').onclick = function () {
  var name = document.getElementById('name').value.trim();
  var price = parseFloat(document.getElementById('price').value || '0');
  if (!name || !(price >= 0)) return;
  var next = stateItems.concat([{
    id: LightIsleKV.genId(),
    name: name,
    price: price,
    cycle: document.getElementById('cycle').value,
    nextDate: document.getElementById('nextDate').value
  }]);
  store.save(next).then(function (res) {
    if (res && res.ok) {
      document.getElementById('name').value = '';
      document.getElementById('price').value = '';
    }
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('family-subscriptions.json', stateItems);
};
store.init();
</script></body></html>`

const templateWarrantyHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>电子发票与保修卡夹</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #248a3d; --accent-soft: rgba(36, 138, 61, 0.11); }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>电子发票与保修卡夹</h1>
    <p class="sub">管理家电数码序列号、保修截止日与发票存放位置 · 自动同步全家并推送 30 天过保预警</p>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
    <div class="form">
      <input id="device" placeholder="设备名称（如：Mac mini M4 / 洗碗机）" style="flex:1;min-width:180px"/>
      <input id="sn" placeholder="序列号 / 订单号" style="width:150px"/>
      <input id="until" type="date" title="保修截止日期"/>
      <input id="note" placeholder="发票路径或售后电话备注" style="flex:1;min-width:180px"/>
      <button id="addBtn">登记设备</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_warranty_vault_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  buildReminders: function (items) {
    return (items || []).filter(function (it) { return it && it.until; }).map(function (it, idx) {
      return {
        id: it.id || ('war-' + idx + '-' + it.device),
        title: '保修即将到期：' + it.device,
        dueDate: it.until,
        warnDays: 30,
        category: 'warranty'
      };
    });
  },
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function render() {
  var box = document.getElementById('list');
  box.textContent = '';
  if (!stateItems.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '暂无保修卡记录，登记后可随时核对过保时间与发票归档位置。';
    box.appendChild(empty);
    return;
  }
  stateItems.forEach(function (it, idx) {
    var days = LightIsleKV.daysUntil(it.until);
    var row = document.createElement('div');
    row.className = 'item' + (days !== null && days < 0 ? ' expired' : (days !== null && days <= 30 ? ' expiring' : ''));
    var info = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = it.device + (it.sn ? ' · ' + it.sn : '');
    var meta = document.createElement('div');
    meta.className = 'meta';
    var status = days === null ? '长期 / 未设截止日' : (days < 0 ? '已过保 ' + Math.abs(days) + ' 天 (' + it.until + ')' : (days === 0 ? '今天过保' : '剩余 ' + days + ' 天 (' + it.until + ')'));
    meta.textContent = status + (it.note ? ' · ' + it.note : '');
    info.append(title, meta);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '删除';
    del.onclick = function () {
      var next = stateItems.filter(function (_, i) { return i !== idx; });
      store.save(next);
    };
    row.append(info, del);
    box.appendChild(row);
  });
}

document.getElementById('addBtn').onclick = function () {
  var device = document.getElementById('device').value.trim();
  if (!device) return;
  var next = [{
    id: LightIsleKV.genId(),
    device: device,
    sn: document.getElementById('sn').value.trim(),
    until: document.getElementById('until').value,
    note: document.getElementById('note').value.trim()
  }].concat(stateItems);
  store.save(next).then(function (res) {
    if (res && res.ok) {
      ['device', 'sn', 'until', 'note'].forEach(function (id) { document.getElementById(id).value = ''; });
    }
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('warranty-vault.json', stateItems);
};
store.init();
</script></body></html>`

const templateFamilyBoardHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>家庭留言板与采购清单</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #d97706; --accent-soft: rgba(217, 119, 6, 0.12); }
  .done strong { text-decoration: line-through; opacity: 0.5; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <h1>家庭留言板与采购清单</h1>
    <p class="sub">随手记录周末采购食材、家务待办与家人温馨留言 · 全家实时同步</p>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
    <div class="form">
      <select id="tag"><option value="采购">🛒 采购</option><option value="留言">💬 留言</option><option value="待办">📌 待办</option></select>
      <input id="text" placeholder="输入采购物品或家庭留言…" style="flex:1;min-width:200px"/>
      <button id="addBtn">发布</button>
      <button id="exportBtn" class="ghost">导出 JSON</button>
    </div>
  </div>
  <div class="card"><div id="list" class="list"></div></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_family_board_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function render() {
  var box = document.getElementById('list');
  box.textContent = '';
  if (!stateItems.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '还没有留言或待采购项，添加第一条家庭备忘吧！';
    box.appendChild(empty);
    return;
  }
  stateItems.forEach(function (it, idx) {
    var row = document.createElement('div');
    row.className = 'item' + (it.done ? ' done' : '');
    var left = document.createElement('label');
    left.style.cssText = 'display:flex;align-items:center;gap:10px;cursor:pointer;flex:1';
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.checked = !!it.done;
    cb.onchange = function () {
      var next = stateItems.map(function (x, i) {
        return i === idx ? { id: x.id, tag: x.tag, text: x.text, done: cb.checked } : x;
      });
      store.save(next);
    };
    var txt = document.createElement('strong');
    txt.textContent = '[' + it.tag + '] ' + it.text;
    left.append(cb, txt);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '清除';
    del.onclick = function () {
      var next = stateItems.filter(function (_, i) { return i !== idx; });
      store.save(next);
    };
    row.append(left, del);
    box.appendChild(row);
  });
}

document.getElementById('addBtn').onclick = function () {
  var text = document.getElementById('text').value.trim();
  if (!text) return;
  var next = [{
    id: LightIsleKV.genId(),
    tag: document.getElementById('tag').value,
    text: text,
    done: false
  }].concat(stateItems);
  store.save(next).then(function (res) {
    if (res && res.ok) document.getElementById('text').value = '';
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('family-board.json', stateItems);
};
store.init();
</script></body></html>`
