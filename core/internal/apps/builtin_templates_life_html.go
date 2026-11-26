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

const templatePetCareIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#C47D3B"/>
  <circle cx="22" cy="24" r="4" fill="#FFFFFF"/>
  <circle cx="32" cy="19" r="4" fill="#FFFFFF"/>
  <circle cx="42" cy="24" r="4" fill="#FFFFFF"/>
  <path d="M21 41c0-6 5-11 11-11s11 5 11 11c0 4-3 7-7 7h-8c-4 0-7-3-7-7z" fill="#FFFFFF"/>
</svg>`

const templateHouseInfoHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>家庭公共备忘卡</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #b86b43; --accent-soft: rgba(184, 107, 67, 0.13); }
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
var zoneFilter = 'all';
var latestMissing = [];
document.getElementById('inDate').value = LightIsleKV.todayISO();

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
  onData: function (data) {
    var base = defaultMenuState();
    if (data && Array.isArray(data.menu) && data.menu.length === 7) base.menu = data.menu;
    if (data && Array.isArray(data.pantry)) base.pantry = data.pantry;
    state = base;
    render();
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
  state.menu.forEach(function (day) {
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

function render() {
  var daysGrid = document.getElementById('daysGrid');
  daysGrid.textContent = '';
  state.menu.forEach(function (m, idx) {
    var box = document.createElement('div');
    box.className = 'day-card';
    var lbl = document.createElement('strong');
    lbl.textContent = m.day || DAYS[idx];
    var meals = document.createElement('input');
    meals.placeholder = '菜谱（如：番茄牛腩 + 清炒时蔬）';
    meals.value = m.meals || '';
    meals.dataset.menuIdx = String(idx);
    meals.dataset.menuField = 'meals';
    var ing = document.createElement('input');
    ing.placeholder = '所需食材（逗号分隔：牛肉,番茄）';
    ing.value = m.ingredients || '';
    ing.dataset.menuIdx = String(idx);
    ing.dataset.menuField = 'ingredients';
    box.append(lbl, meals, ing);
    daysGrid.appendChild(box);
  });

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
  var nextMenu = state.menu.map(function (m) { return { day: m.day, meals: m.meals, ingredients: m.ingredients }; });
  document.querySelectorAll('[data-menu-idx]').forEach(function (el) {
    var i = Number(el.dataset.menuIdx);
    nextMenu[i][el.dataset.menuField] = el.value.trim();
  });
  store.save({ menu: nextMenu, pantry: state.pantry });
};
document.getElementById('addStockBtn').onclick = function () {
  var name = document.getElementById('itemName').value.trim();
  if (!name) return;
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
  latestMissing = computeMissing();
  renderMissingDrawer();
};
document.getElementById('copyMissingBtn').onclick = function () {
  if (!latestMissing.length) return;
  var btn = document.getElementById('copyMissingBtn');
  LightIsleKV.copyText('本周缺料采购清单：' + latestMissing.join('、')).then(function () {
    btn.textContent = '已复制 ✓';
    setTimeout(function () { btn.textContent = '复制采购清单'; }, 1400);
  });
};
document.querySelectorAll('[data-zone]').forEach(function (btn) {
  btn.onclick = function () {
    zoneFilter = btn.dataset.zone;
    document.querySelectorAll('[data-zone]').forEach(function (b) { b.classList.toggle('active', b === btn); });
    render();
  };
});
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('weekly-menu-pantry.json', state);
};
store.init();
</script></body></html>`

const templatePetCareHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>宠物健康与疫苗驱虫</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #c47d3b; --accent-soft: rgba(196, 125, 59, 0.13); }
  .chart { width: 100%; height: 155px; margin-top: 8px; }
  .pet-tabs { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
</style></head>
<body><div class="wrap">
  <div class="card">
    <div class="head-row">
      <div>
        <h1>宠物健康与疫苗驱虫</h1>
        <p class="sub">多宠物档案管理、原生 SVG 体重曲线，疫苗与内外驱虫下次到期自动推算并接入家庭推送提醒</p>
      </div>
      <button id="exportBtn" class="ghost sm">导出 JSON</button>
    </div>
    <div id="syncBar" class="li-sync-bar">正在初始化…</div>
    <div class="form">
      <input id="petName" placeholder="宠物名字（如：橘座 / 豆包）" style="width:150px"/>
      <input id="petBreed" placeholder="品种/性别（如：英短银渐层）" style="flex:1;min-width:150px"/>
      <input id="petBirth" type="date" title="宠物生日"/>
      <button id="addPetBtn">新增宠物档案</button>
    </div>
    <div id="petTabs" class="pet-tabs"></div>
    <div class="stats">
      <div class="stat"><span>当前宠物</span><b id="activePetTitle">未选择</b></div>
      <div class="stat"><span>最新体重</span><b id="latestWeight">-- kg</b></div>
      <div class="stat"><span>7 天内待办疫苗/驱虫</span><b id="dueCareCount">0</b></div>
    </div>
  </div>

  <div class="card">
    <h2>体重变化曲线 (kg)</h2>
    <div class="form" style="margin-top:0">
      <input id="wDate" type="date"/>
      <input id="wKg" type="number" step="0.05" min="0" placeholder="体重 (kg)" style="width:115px"/>
      <input id="wNote" placeholder="备注（如：换粮后 / 体检称重）" style="flex:1;min-width:150px"/>
      <button id="addWeightBtn">记录体重</button>
    </div>
    <svg id="weightChart" class="chart" viewBox="0 0 600 155"></svg>
  </div>

  <div class="card">
    <h2>疫苗与驱虫周期提醒</h2>
    <div class="form" style="margin-top:0">
      <select id="careKind">
        <option value="体外驱虫|30">🛡️ 体外驱虫 (30天)</option>
        <option value="体内驱虫|90">💊 体内驱虫 (90天)</option>
        <option value="狂犬疫苗|365">💉 狂犬疫苗 (365天)</option>
        <option value="多联疫苗|365">🩺 多联疫苗 (365天)</option>
        <option value="体检洗护|180">🛁 体检/洗护 (180天)</option>
      </select>
      <input id="careDoneDate" type="date" title="本次完成日期"/>
      <input id="careCycleDays" type="number" min="1" max="730" value="30" placeholder="周期(天)" style="width:96px"/>
      <input id="careNote" placeholder="药剂品牌或医院备注" style="flex:1;min-width:140px"/>
      <button id="addCareBtn">登记周期</button>
    </div>
    <div id="careList" class="list" style="margin-top:12px"></div>
  </div>
</div>
<script>
/*__LIGHTISLE_KV_JS__*/
function defaultPetState() {
  return { pets: [], activePetId: '' };
}
var state = defaultPetState();
document.getElementById('wDate').value = LightIsleKV.todayISO();
document.getElementById('careDoneDate').value = LightIsleKV.todayISO();

var store = LightIsleKV.createStore({
  legacyKey: 'lightisle_pet_care_v1',
  defaultValue: defaultPetState(),
  statusEl: 'syncBar',
  buildReminders: function (data) {
    var out = [];
    var pets = (data && Array.isArray(data.pets)) ? data.pets : [];
    pets.forEach(function (pet) {
      (pet.cares || []).forEach(function (c) {
        if (!c || !c.nextDueDate) return;
        out.push({
          id: pet.id + '-' + c.id,
          title: pet.name + ' · ' + c.kind,
          dueDate: c.nextDueDate,
          warnDays: 7,
          category: 'pet-care'
        });
      });
    });
    return out;
  },
  onData: function (data) {
    var base = defaultPetState();
    if (data && Array.isArray(data.pets)) {
      base.pets = data.pets;
      base.activePetId = data.activePetId || (data.pets[0] ? data.pets[0].id : '');
    }
    state = base;
    render();
  }
});

function getActivePet() {
  if (!state.pets.length) return null;
  var found = state.pets.find(function (p) { return p.id === state.activePetId; });
  return found || state.pets[0];
}

function renderWeightChart(weights) {
  var svg = document.getElementById('weightChart');
  svg.textContent = '';
  var pts = (weights || []).slice().sort(function (a, b) { return (a.date || '').localeCompare(b.date || ''); }).slice(-12);
  if (!pts.length) return;
  var vals = pts.map(function (p) { return Number(p.kg) || 0; });
  var min = Math.max(0, Math.min.apply(null, vals) - 0.5);
  var max = Math.max.apply(null, vals) + 0.5;
  var span = Math.max(0.5, max - min);
  var coords = pts.map(function (p, i) {
    var x = pts.length === 1 ? 300 : 40 + (i / (pts.length - 1)) * 520;
    var y = 122 - ((Number(p.kg) - min) / span) * 92;
    return { x: x, y: y, p: p };
  });
  var poly = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
  poly.setAttribute('fill', 'none'); poly.setAttribute('stroke', '#c47d3b'); poly.setAttribute('stroke-width', '3');
  poly.setAttribute('points', coords.map(function (c) { return c.x + ',' + c.y; }).join(' '));
  svg.appendChild(poly);
  coords.forEach(function (c) {
    var dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', c.x); dot.setAttribute('cy', c.y); dot.setAttribute('r', '4.5'); dot.setAttribute('fill', '#c47d3b');
    var top = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    top.setAttribute('x', c.x); top.setAttribute('y', Math.max(14, c.y - 8)); top.setAttribute('text-anchor', 'middle'); top.setAttribute('font-size', '10'); top.setAttribute('fill', 'currentColor'); top.textContent = c.p.kg + 'kg';
    var lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    lbl.setAttribute('x', c.x); lbl.setAttribute('y', 146); lbl.setAttribute('text-anchor', 'middle'); lbl.setAttribute('font-size', '10'); lbl.setAttribute('fill', 'currentColor'); lbl.textContent = (c.p.date || '').slice(5);
    svg.append(dot, top, lbl);
  });
}

function render() {
  var tabs = document.getElementById('petTabs');
  tabs.textContent = '';
  var active = getActivePet();
  state.pets.forEach(function (p) {
    var btn = document.createElement('button');
    btn.className = 'ghost sm' + (active && p.id === active.id ? ' active' : '');
    btn.textContent = p.name + (p.breed ? ' · ' + p.breed : '');
    btn.onclick = function () {
      state.activePetId = p.id;
      render();
    };
    tabs.appendChild(btn);
  });

  var dueCount = 0;
  state.pets.forEach(function (p) {
    (p.cares || []).forEach(function (c) {
      var d = LightIsleKV.daysUntil(c.nextDueDate);
      if (d !== null && d <= 7) dueCount++;
    });
  });
  document.getElementById('dueCareCount').textContent = String(dueCount);
  document.getElementById('activePetTitle').textContent = active ? active.name : '请先新增档案';

  var careList = document.getElementById('careList');
  careList.textContent = '';
  if (!active) {
    document.getElementById('latestWeight').textContent = '-- kg';
    renderWeightChart([]);
    var empty = document.createElement('div');
    empty.className = 'empty';
    empty.textContent = '先在上方新增一只毛孩子的档案，即可记录体重曲线与驱虫疫苗计划。';
    careList.appendChild(empty);
    return;
  }

  var weights = (active.weights || []).slice().sort(function (a, b) { return (a.date || '').localeCompare(b.date || ''); });
  var lastW = weights[weights.length - 1];
  document.getElementById('latestWeight').textContent = lastW ? lastW.kg + ' kg' : '-- kg';
  renderWeightChart(weights);

  var cares = (active.cares || []).slice().sort(function (a, b) { return (a.nextDueDate || '').localeCompare(b.nextDueDate || ''); });
  if (!cares.length) {
    var noCare = document.createElement('div');
    noCare.className = 'empty';
    noCare.textContent = '暂无疫苗或驱虫记录，在上方登记本次时间即可自动推算下次到期日。';
    careList.appendChild(noCare);
    return;
  }
  cares.forEach(function (c) {
    var d = LightIsleKV.daysUntil(c.nextDueDate);
    var row = document.createElement('div');
    row.className = 'item' + (d !== null && d < 0 ? ' expired' : (d !== null && d <= 7 ? ' soon' : ''));
    var left = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = c.kind + ' · 下次到期 ' + c.nextDueDate;
    var meta = document.createElement('div');
    meta.className = 'meta';
    var badge = d === null ? '' : (d < 0 ? '已超期 ' + Math.abs(d) + ' 天' : (d === 0 ? '今天到期' : '剩余 ' + d + ' 天'));
    meta.textContent = badge + ' · 上次 ' + c.lastDate + '（周期 ' + c.cycleDays + ' 天）' + (c.note ? ' · ' + c.note : '');
    left.append(title, meta);

    var right = document.createElement('div');
    right.style.cssText = 'display:flex;gap:6px';
    var renewBtn = document.createElement('button');
    renewBtn.className = 'sm';
    renewBtn.textContent = '今天已打卡';
    renewBtn.onclick = function () {
      var today = LightIsleKV.todayISO();
      var nextPets = state.pets.map(function (p) {
        if (p.id !== active.id) return p;
        return {
          id: p.id, name: p.name, breed: p.breed, birth: p.birth, weights: p.weights || [],
          cares: (p.cares || []).map(function (x) {
            if (x.id !== c.id) return x;
            return {
              id: x.id, kind: x.kind, cycleDays: x.cycleDays, note: x.note,
              lastDate: today, nextDueDate: LightIsleKV.addDaysISO(today, x.cycleDays)
            };
          })
        };
      });
      store.save({ pets: nextPets, activePetId: active.id });
    };
    var delBtn = document.createElement('button');
    delBtn.className = 'ghost sm';
    delBtn.textContent = '移除';
    delBtn.onclick = function () {
      var nextPets = state.pets.map(function (p) {
        if (p.id !== active.id) return p;
        return {
          id: p.id, name: p.name, breed: p.breed, birth: p.birth, weights: p.weights || [],
          cares: (p.cares || []).filter(function (x) { return x.id !== c.id; })
        };
      });
      store.save({ pets: nextPets, activePetId: active.id });
    };
    right.append(renewBtn, delBtn);
    row.append(left, right);
    careList.appendChild(row);
  });
}

document.getElementById('careKind').onchange = function () {
  var parts = document.getElementById('careKind').value.split('|');
  if (parts[1]) document.getElementById('careCycleDays').value = parts[1];
};
document.getElementById('addPetBtn').onclick = function () {
  var name = document.getElementById('petName').value.trim();
  if (!name) return;
  var newPet = {
    id: LightIsleKV.genId(),
    name: name,
    breed: document.getElementById('petBreed').value.trim(),
    birth: document.getElementById('petBirth').value,
    weights: [],
    cares: []
  };
  store.save({ pets: state.pets.concat([newPet]), activePetId: newPet.id }).then(function (res) {
    if (res && res.ok) {
      ['petName', 'petBreed', 'petBirth'].forEach(function (id) { document.getElementById(id).value = ''; });
    }
  });
};
document.getElementById('addWeightBtn').onclick = function () {
  var active = getActivePet();
  var date = document.getElementById('wDate').value;
  var kg = parseFloat(document.getElementById('wKg').value || '0');
  if (!active || !date || !(kg > 0)) return;
  var nextPets = state.pets.map(function (p) {
    if (p.id !== active.id) return p;
    return {
      id: p.id, name: p.name, breed: p.breed, birth: p.birth, cares: p.cares || [],
      weights: (p.weights || []).concat([{ id: LightIsleKV.genId(), date: date, kg: kg, note: document.getElementById('wNote').value.trim() }])
    };
  });
  store.save({ pets: nextPets, activePetId: active.id }).then(function (res) {
    if (res && res.ok) {
      document.getElementById('wKg').value = '';
      document.getElementById('wNote').value = '';
    }
  });
};
document.getElementById('addCareBtn').onclick = function () {
  var active = getActivePet();
  var lastDate = document.getElementById('careDoneDate').value;
  var cycleDays = parseInt(document.getElementById('careCycleDays').value || '30', 10);
  if (!active || !lastDate || !(cycleDays > 0)) return;
  var kind = document.getElementById('careKind').value.split('|')[0];
  var nextDueDate = LightIsleKV.addDaysISO(lastDate, cycleDays);
  var nextPets = state.pets.map(function (p) {
    if (p.id !== active.id) return p;
    return {
      id: p.id, name: p.name, breed: p.breed, birth: p.birth, weights: p.weights || [],
      cares: (p.cares || []).concat([{
        id: LightIsleKV.genId(), kind: kind, lastDate: lastDate, cycleDays: cycleDays,
        nextDueDate: nextDueDate, note: document.getElementById('careNote').value.trim()
      }])
    };
  });
  store.save({ pets: nextPets, activePetId: active.id }).then(function (res) {
    if (res && res.ok) document.getElementById('careNote').value = '';
  });
};
document.getElementById('exportBtn').onclick = function () {
  LightIsleKV.exportJSON('pet-care.json', state);
};
store.init();
</script></body></html>`
