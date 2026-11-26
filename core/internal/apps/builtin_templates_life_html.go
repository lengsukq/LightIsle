package apps

const templateHouseInfoIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#B86B43"/>
  <path d="M16 30L32 16l16 14v18a3 3 0 0 1-3 3H19a3 3 0 0 1-3-3V30z" stroke="#FFFFFF" stroke-width="3.4" stroke-linejoin="round"/>
  <path d="M26 51V37h12v14" stroke="#FFFFFF" stroke-width="3.4" stroke-linejoin="round"/>
</svg>`

const templateWeeklyMenuIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#4E7A5B"/>
  <path d="M22 16v32M17 16v11a5 5 0 0 0 10 0V16M42 16v32M42 16c5 3 7 8 7 15h-7" stroke="#FFFFFF" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`

const templateHouseInfoHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>家庭公共备忘卡</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #b86b43; --accent-soft: rgba(184, 107, 67, 0.13); }
  @media (prefers-color-scheme: dark) { :root { --accent: #f0a175; --accent-soft: rgba(240, 161, 117, 0.18); } }
  .cards-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 12px; }
  .memo-card { background: var(--surface); border: 1px solid var(--border); border-radius: 15px; padding: 15px; display: grid; gap: 8px; align-content: start; }
  .memo-top { display: flex; justify-content: space-between; align-items: center; gap: 8px; }
  .memo-val { font-size: 16px; font-weight: 650; word-break: break-all; padding: 9px 11px; border-radius: 10px; background: var(--surface-soft); letter-spacing: 0.01em; }
  .memo-actions { display: flex; justify-content: space-between; align-items: center; gap: 8px; margin-top: 2px; }
  .presets { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <div class="head-row">
      <div>
        <h1>家庭公共备忘卡</h1>
        <p class="sub">集中保管 Wi-Fi、宽带光猫、水电燃气户号、车架号、公司开票抬头与物业电话，全家随时一键复制</p>
      </div>
      <button id="exportBtn" class="ghost sm">导出 JSON</button>
    </div>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
    <div class="presets">
      <span class="meta" style="margin:0;align-self:center">快速模板：</span>
      <button type="button" class="ghost sm" data-preset="网络 Wi-Fi|客厅 Wi-Fi 密码">Wi-Fi 密码</button>
      <button type="button" class="ghost sm" data-preset="水电户号|电表户号">电表户号</button>
      <button type="button" class="ghost sm" data-preset="车辆与开票|公司开票抬头与税号">开票抬头</button>
      <button type="button" class="ghost sm" data-preset="车辆与开票|家庭车辆车架号 (VIN)">车架号</button>
      <button type="button" class="ghost sm" data-preset="物业与紧急|小区物业 24 小时电话">物业电话</button>
    </div>
    <div class="form">
      <select id="cat">
        <option value="网络 Wi-Fi">📶 网络 Wi-Fi</option>
        <option value="水电户号">⚡ 水电户号</option>
        <option value="车辆与开票">🧾 车辆与开票</option>
        <option value="物业与紧急">🏠 物业与紧急</option>
        <option value="其他">📌 其他</option>
      </select>
      <input id="title" placeholder="卡片标题（如：主卧 Wi-Fi / 燃气表号）" style="flex:1;min-width:160px"/>
      <input id="val" placeholder="具体号码、密码或抬头信息" style="flex:1.2;min-width:180px"/>
      <input id="note" placeholder="补充备注（可选）" style="flex:1;min-width:140px"/>
      <button id="addBtn">保存卡片</button>
    </div>
    <div class="toolbar">
      <div class="filters" style="margin:0;flex:1">
        <button class="ghost active sm" data-filter="all">全部</button>
        <button class="ghost sm" data-filter="网络 Wi-Fi">网络 Wi-Fi</button>
        <button class="ghost sm" data-filter="水电户号">水电户号</button>
        <button class="ghost sm" data-filter="车辆与开票">车辆与开票</button>
        <button class="ghost sm" data-filter="物业与紧急">物业与紧急</button>
        <button class="ghost sm" data-filter="其他">其他</button>
      </div>
      <input id="search" placeholder="搜索标题、号码或备注…" style="width:190px"/>
    </div>
  </div>
  <div id="grid" class="cards-grid"></div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var stateItems = [];
var activeFilter = 'all';
var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_house_info_v1',
  defaultValue: [],
  statusEl: 'syncBar',
  onData: function (data) {
    stateItems = Array.isArray(data) ? data : [];
    render();
  }
});

function render() {
  var q = (document.getElementById('search').value || '').trim().toLowerCase();
  var items = stateItems.filter(function (it) {
    if (activeFilter !== 'all' && it.cat !== activeFilter) return false;
    if (!q) return true;
    return ((it.title || '') + ' ' + (it.val || '') + ' ' + (it.note || '') + ' ' + (it.cat || '')).toLowerCase().indexOf(q) >= 0;
  });
  var grid = document.getElementById('grid');
  grid.textContent = '';
  if (!items.length) {
    var emptyCard = document.createElement('div');
    emptyCard.className = 'card empty';
    emptyCard.style.gridColumn = '1 / -1';
    emptyCard.textContent = stateItems.length ? '没有匹配筛选条件的备忘卡片。' : '还没有家庭备忘卡，点击上方快速模板或填写第一条常用信息吧。';
    grid.appendChild(emptyCard);
    return;
  }
  items.forEach(function (it) {
    var card = document.createElement('div');
    card.className = 'memo-card';
    var top = document.createElement('div');
    top.className = 'memo-top';
    var title = document.createElement('strong');
    title.textContent = it.title;
    var badge = document.createElement('span');
    badge.className = 'pill';
    badge.textContent = it.cat || '其他';
    top.append(title, badge);

    var valBox = document.createElement('div');
    valBox.className = 'memo-val';
    valBox.textContent = it.val;

    var note = document.createElement('div');
    note.className = 'meta';
    note.style.marginTop = '0';
    note.textContent = it.note || ' ';

    var actions = document.createElement('div');
    actions.className = 'memo-actions';
    var copyBtn = document.createElement('button');
    copyBtn.className = 'sm';
    copyBtn.textContent = '一键复制';
    copyBtn.onclick = function () {
      LightIsleKV.copyText(it.val).then(function () {
        copyBtn.textContent = '已复制 ✓';
        setTimeout(function () { copyBtn.textContent = '一键复制'; }, 1400);
      }).catch(function () {
        copyBtn.textContent = '复制失败，请手动选中';
        setTimeout(function () { copyBtn.textContent = '一键复制'; }, 2000);
      });
    };
    var delBtn = document.createElement('button');
    delBtn.className = 'ghost sm';
    delBtn.textContent = '删除';
    delBtn.onclick = function () {
      store.save(stateItems.filter(function (x) { return x.id !== it.id; }));
    };
    actions.append(copyBtn, delBtn);
    card.append(top, valBox, note, actions);
    grid.appendChild(card);
  });
}

document.querySelectorAll('[data-preset]').forEach(function (btn) {
  btn.onclick = function () {
    var parts = btn.dataset.preset.split('|');
    document.getElementById('cat').value = parts[0];
    document.getElementById('title').value = parts[1];
    document.getElementById('val').focus();
  };
});
document.querySelectorAll('[data-filter]').forEach(function (btn) {
  btn.onclick = function () {
    activeFilter = btn.dataset.filter;
    document.querySelectorAll('[data-filter]').forEach(function (b) { b.classList.toggle('active', b === btn); });
    render();
  };
});
document.getElementById('search').oninput = render;
document.getElementById('addBtn').onclick = function () {
  var title = document.getElementById('title').value.trim();
  var val = document.getElementById('val').value.trim();
  if (!title || !val) return;
  var next = [{
    id: LightIsleKV.genId(),
    cat: document.getElementById('cat').value,
    title: title,
    val: val,
    note: document.getElementById('note').value.trim()
  }].concat(stateItems);
  store.save(next).then(function (res) {
    if (res && res.ok) {
      ['title', 'val', 'note'].forEach(function (id) { document.getElementById(id).value = ''; });
    }
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('house-info.json', stateItems);
};
store.init();
</script></body></html>`

const templateWeeklyMenuHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>每周菜单与冰箱囤货</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #4e7a5b; --accent-soft: rgba(78, 122, 91, 0.13); }
  @media (prefers-color-scheme: dark) { :root { --accent: #7ec994; --accent-soft: rgba(126, 201, 148, 0.18); } }
  .days-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 10px; }
  .day-card { background: var(--surface-soft); border: 1px solid var(--border); border-radius: 14px; padding: 12px; display: grid; gap: 6px; }
  .day-card input { width: 100%; background: var(--surface); padding: 6px 9px; font-size: 12px; }
  .missing-box { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }
  .missing-chip { padding: 6px 11px; border-radius: 999px; background: var(--warn-soft); color: var(--warn); font-size: 12px; font-weight: 600; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <div class="head-row">
      <div>
        <h1>每周菜单与冰箱囤货</h1>
        <p class="sub">规划周一至周日菜谱、管理冷藏/冷冻食材保质期并自动推送临期预警，一键提取缺料采购清单</p>
      </div>
      <div style="display:flex;gap:8px">
        <button id="extractBtn" class="sm">提取缺料清单</button>
        <button id="exportBtn" class="ghost sm">导出 JSON</button>
      </div>
    </div>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
    <div class="stats">
      <div class="stat"><span>冰箱在库食材</span><b id="stockCount">0</b></div>
      <div class="stat"><span>3 天内临期 / 过期</span><b id="expiringCount">0</b></div>
      <div class="stat"><span>本周待补缺料</span><b id="missingCount">0</b></div>
    </div>
    <div id="missingWrap" style="display:none;margin-top:12px;padding-top:12px;border-top:1px solid var(--border)">
      <div class="head-row">
        <strong style="font-size:13px">本周缺料清单（对照冰箱未过期库存自动比对）</strong>
        <button id="copyMissingBtn" class="ghost sm">复制采购清单</button>
      </div>
      <div id="missingList" class="missing-box"></div>
    </div>
  </div>

  <div class="card">
    <div class="head-row">
      <h2>本周菜单排期（周一至周日）</h2>
      <button id="saveMenuBtn" class="sm">保存本周菜单</button>
    </div>
    <div id="daysGrid" class="days-grid"></div>
  </div>

  <div class="card">
    <h2>冰箱与储物柜囤货</h2>
    <div class="form">
      <select id="zone"><option value="冷藏">🧊 冷藏</option><option value="冷冻">❄️ 冷冻</option><option value="常温">🧺 常温</option></select>
      <input id="itemName" placeholder="食材名称（如：牛肉 / 牛奶 / 番茄）" style="flex:1;min-width:150px"/>
      <input id="qty" placeholder="数量（如：500g / 2 盒）" style="width:120px"/>
      <input id="inDate" type="date" title="入库日期"/>
      <input id="expDate" type="date" title="保质期截止日"/>
      <button id="addStockBtn">入库</button>
    </div>
    <div class="filters">
      <button class="ghost active sm" data-zone="all">全部区域</button>
      <button class="ghost sm" data-zone="冷藏">🧊 冷藏</button>
      <button class="ghost sm" data-zone="冷冻">❄️ 冷冻</button>
      <button class="ghost sm" data-zone="常温">🧺 常温</button>
    </div>
    <div id="stockList" class="list" style="margin-top:12px"></div>
  </div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
var DAYS = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
function defaultMenuState() {
  return {
    menu: DAYS.map(function (d) { return { day: d, meals: '', ingredients: '' }; }),
    pantry: []
  };
}
var state = defaultMenuState();
var menuDraft = null;
var menuDirty = false;
var zoneFilter = 'all';
var latestMissing = [];
document.getElementById('inDate').value = LightIsleKV.todayISO();

function cloneMenu(list) {
  return (list || []).map(function (m, idx) {
    return {
      day: (m && m.day) || DAYS[idx],
      meals: (m && m.meals) || '',
      ingredients: (m && m.ingredients) || ''
    };
  });
}

function captureMenuDraft() {
  var base = menuDraft ? cloneMenu(menuDraft) : cloneMenu(state.menu);
  document.querySelectorAll('[data-menu-idx]').forEach(function (el) {
    var i = Number(el.dataset.menuIdx);
    if (base[i]) base[i][el.dataset.menuField] = el.value;
  });
  menuDraft = base;
  return base;
}

function getEffectiveMenu() {
  return (menuDirty && menuDraft) ? menuDraft : state.menu;
}

var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_weekly_menu_v1',
  defaultValue: defaultMenuState(),
  statusEl: 'syncBar',
  buildReminders: function (data) {
    var list = (data && Array.isArray(data.pantry)) ? data.pantry : [];
    return list.filter(function (it) { return it && it.expDate; }).map(function (it, idx) {
      return {
        id: it.id || ('fridge-' + idx + '-' + it.name),
        title: '冰箱食材临期：' + it.name + (it.zone ? '（' + it.zone + '）' : ''),
        dueDate: it.expDate,
        warnDays: 3,
        category: 'fridge'
      };
    });
  },
  onData: function (data, meta) {
    var base = defaultMenuState();
    if (data && Array.isArray(data.menu) && data.menu.length === 7) base.menu = data.menu;
    if (data && Array.isArray(data.pantry)) base.pantry = data.pantry;
    state = base;
    if (meta && meta.source === 'saved' && menuDirty) {
      renderPantryAndStats();
      return;
    }
    menuDraft = cloneMenu(state.menu);
    menuDirty = false;
    renderMenuGrid();
    renderPantryAndStats();
  }
});

function computeMissing() {
  var freshNames = {};
  state.pantry.forEach(function (it) {
    var d = LightIsleKV.daysUntil(it.expDate);
    if (d === null || d >= 0) {
      freshNames[(it.name || '').trim().toLowerCase()] = true;
    }
  });
  var seen = {};
  var missing = [];
  getEffectiveMenu().forEach(function (day) {
    String(day.ingredients || '').split(/[,，、;\s]+/).forEach(function (raw) {
      var token = raw.trim();
      if (!token) return;
      var low = token.toLowerCase();
      var hasMatch = freshNames[low] || Object.keys(freshNames).some(function (k) { return k && (k.indexOf(low) >= 0 || low.indexOf(k) >= 0); });
      if (!hasMatch && !seen[low]) {
        seen[low] = true;
        missing.push(token);
      }
    });
  });
  return missing;
}

function renderMenuGrid() {
  var daysGrid = document.getElementById('daysGrid');
  daysGrid.textContent = '';
  var sourceMenu = getEffectiveMenu();
  sourceMenu.forEach(function (m, idx) {
    var box = document.createElement('div');
    box.className = 'day-card';
    var lbl = document.createElement('strong');
    lbl.textContent = m.day || DAYS[idx];
    var meals = document.createElement('input');
    meals.placeholder = '菜谱（如：番茄牛腩 + 清炒时蔬）';
    meals.value = m.meals || '';
    meals.dataset.menuIdx = String(idx);
    meals.dataset.menuField = 'meals';
    meals.oninput = function () {
      menuDirty = true;
      captureMenuDraft();
    };
    var ing = document.createElement('input');
    ing.placeholder = '所需食材（逗号分隔：牛肉,番茄）';
    ing.value = m.ingredients || '';
    ing.dataset.menuIdx = String(idx);
    ing.dataset.menuField = 'ingredients';
    ing.oninput = function () {
      menuDirty = true;
      captureMenuDraft();
      latestMissing = computeMissing();
      document.getElementById('missingCount').textContent = String(latestMissing.length);
    };
    box.append(lbl, meals, ing);
    daysGrid.appendChild(box);
  });
}

function renderPantryAndStats() {
  var expiring = 0;
  state.pantry.forEach(function (it) {
    var d = LightIsleKV.daysUntil(it.expDate);
    if (d !== null && d <= 3) expiring++;
  });
  latestMissing = computeMissing();
  document.getElementById('stockCount').textContent = String(state.pantry.length);
  document.getElementById('expiringCount').textContent = String(expiring);
  document.getElementById('missingCount').textContent = String(latestMissing.length);

  var sorted = state.pantry.slice().sort(function (a, b) {
    return (a.expDate || '9999-99-99').localeCompare(b.expDate || '9999-99-99');
  });
  var filtered = zoneFilter === 'all' ? sorted : sorted.filter(function (it) { return it.zone === zoneFilter; });
  var stockList = document.getElementById('stockList');
  stockList.textContent = '';
  if (!filtered.length) {
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '当前区域还没有入库食材，在上方登记冰箱囤货吧。';
    stockList.appendChild(empty);
    return;
  }
  filtered.forEach(function (it) {
    var d = LightIsleKV.daysUntil(it.expDate);
    var row = document.createElement('div');
    row.className = 'item' + (d !== null && d < 0 ? ' expired' : (d !== null && d <= 3 ? ' soon' : ''));
    var left = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = '[' + it.zone + '] ' + it.name + (it.qty ? ' · ' + it.qty : '');
    var meta = document.createElement('div');
    meta.className = 'meta';
    var expText = d === null ? '未设保质期' : (d < 0 ? '已过期 ' + Math.abs(d) + ' 天 (' + it.expDate + ')' : (d === 0 ? '今天到期' : '保质期剩余 ' + d + ' 天 (' + it.expDate + ')'));
    meta.textContent = (it.inDate ? '入库 ' + it.inDate + ' · ' : '') + expText;
    left.append(title, meta);
    var del = document.createElement('button');
    del.className = 'ghost sm';
    del.textContent = '已吃完';
    del.onclick = function () {
      if (menuDirty) captureMenuDraft();
      store.save({ menu: state.menu, pantry: state.pantry.filter(function (x) { return x.id !== it.id; }) });
    };
    row.append(left, del);
    stockList.appendChild(row);
  });
}

function renderMissingDrawer() {
  var wrap = document.getElementById('missingWrap');
  var box = document.getElementById('missingList');
  wrap.style.display = 'block';
  box.textContent = '';
  if (!latestMissing.length) {
    var ok = document.createElement('span');
    ok.className = 'pill ok';
    ok.textContent = '冰箱食材齐全，本周暂无缺料！';
    box.appendChild(ok);
    return;
  }
  latestMissing.forEach(function (item) {
    var chip = document.createElement('span');
    chip.className = 'missing-chip';
    chip.textContent = item;
    box.appendChild(chip);
  });
}

document.getElementById('saveMenuBtn').onclick = function () {
  var nextMenu = captureMenuDraft().map(function (m) {
    return { day: m.day, meals: (m.meals || '').trim(), ingredients: (m.ingredients || '').trim() };
  });
  menuDirty = false;
  store.save({ menu: nextMenu, pantry: state.pantry }).then(function (res) {
    if (!res || !res.ok) menuDirty = true;
  });
};
document.getElementById('addStockBtn').onclick = function () {
  var name = document.getElementById('itemName').value.trim();
  if (!name) return;
  if (menuDirty) captureMenuDraft();
  var nextPantry = state.pantry.concat([{
    id: LightIsleKV.genId(),
    zone: document.getElementById('zone').value,
    name: name,
    qty: document.getElementById('qty').value.trim(),
    inDate: document.getElementById('inDate').value,
    expDate: document.getElementById('expDate').value
  }]);
  store.save({ menu: state.menu, pantry: nextPantry }).then(function (res) {
    if (res && res.ok) {
      ['itemName', 'qty', 'expDate'].forEach(function (id) { document.getElementById(id).value = ''; });
    }
  });
};
document.getElementById('extractBtn').onclick = function () {
  if (menuDirty) captureMenuDraft();
  latestMissing = computeMissing();
  renderMissingDrawer();
};
document.getElementById('copyMissingBtn').onclick = function () {
  if (!latestMissing.length) return;
  var btn = document.getElementById('copyMissingBtn');
  LightIsleKV.copyText('本周缺料采购清单：' + latestMissing.join('、')).then(function () {
    btn.textContent = '已复制 ✓';
    setTimeout(function () { btn.textContent = '复制采购清单'; }, 1400);
  }).catch(function () {
    btn.textContent = '复制失败，请手动复制';
    setTimeout(function () { btn.textContent = '复制采购清单'; }, 2000);
  });
};
document.querySelectorAll('[data-zone]').forEach(function (btn) {
  btn.onclick = function () {
    zoneFilter = btn.dataset.zone;
    document.querySelectorAll('[data-zone]').forEach(function (b) { b.classList.toggle('active', b === btn); });
    renderPantryAndStats();
  };
});
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('weekly-menu-pantry.json', state);
};
store.init();
</script></body></html>`
