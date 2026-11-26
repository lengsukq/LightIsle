package apps

const templatePetCareIconSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <rect width="64" height="64" rx="16" fill="#C47D3B"/>
  <circle cx="22" cy="24" r="4" fill="#FFFFFF"/>
  <circle cx="32" cy="19" r="4" fill="#FFFFFF"/>
  <circle cx="42" cy="24" r="4" fill="#FFFFFF"/>
  <path d="M21 41c0-6 5-11 11-11s11 5 11 11c0 4-3 7-7 7h-8c-4 0-7-3-7-7z" fill="#FFFFFF"/>
</svg>`

const templatePetCareHTML = `<!doctype html>
<html lang="zh-CN">
<head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/><title>宠物健康与疫苗驱虫</title>
<style>
/*__LIGHTISLE_SHARED_CSS__*/
  :root { --accent: #c47d3b; --accent-soft: rgba(196, 125, 59, 0.13); }
  @media (prefers-color-scheme: dark) { :root { --accent: #f3ad6b; --accent-soft: rgba(243, 173, 107, 0.18); } }
  .chart { width: 100%; height: 155px; margin-top: 8px; }
  .pet-tabs { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; align-items: center; }
  button.danger-ghost { background: var(--danger-soft); color: var(--danger); border: 1px solid var(--danger); }
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
    <div id="weightList" class="list" style="margin-top:10px"></div>
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
  poly.setAttribute('fill', 'none'); poly.setAttribute('stroke', 'var(--accent)'); poly.setAttribute('stroke-width', '3');
  poly.setAttribute('points', coords.map(function (c) { return c.x + ',' + c.y; }).join(' '));
  svg.appendChild(poly);
  coords.forEach(function (c) {
    var dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', c.x); dot.setAttribute('cy', c.y); dot.setAttribute('r', '4.5'); dot.setAttribute('fill', 'var(--accent)');
    var top = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    top.setAttribute('x', c.x); top.setAttribute('y', Math.max(14, c.y - 8)); top.setAttribute('text-anchor', 'middle'); top.setAttribute('font-size', '10'); top.setAttribute('fill', 'currentColor'); top.textContent = c.p.kg + 'kg';
    var lbl = document.createElementNS('http://www.w3.org/2000/svg', 'text');
    lbl.setAttribute('x', c.x); lbl.setAttribute('y', 146); lbl.setAttribute('text-anchor', 'middle'); lbl.setAttribute('font-size', '10'); lbl.setAttribute('fill', 'currentColor'); lbl.textContent = (c.p.date || '').slice(5);
    svg.append(dot, top, lbl);
  });
}

function renderWeightList(active, weights) {
  var box = document.getElementById('weightList');
  box.textContent = '';
  if (!active || !weights.length) return;
  weights.slice().reverse().forEach(function (w) {
    var row = document.createElement('div');
    row.className = 'item';
    var left = document.createElement('div');
    var title = document.createElement('strong');
    title.textContent = (w.date || '未设日期') + ' · ' + w.kg + ' kg';
    var meta = document.createElement('div');
    meta.className = 'meta';
    meta.textContent = w.note || '常规称重记录';
    left.append(title, meta);
    var delBtn = document.createElement('button');
    delBtn.className = 'ghost sm';
    delBtn.textContent = '删除';
    delBtn.onclick = function () {
      var nextPets = state.pets.map(function (p) {
        if (p.id !== active.id) return p;
        var nextWeights = (p.weights || []).filter(function (x) {
          return w.id ? x.id !== w.id : !(x.date === w.date && x.kg === w.kg && (x.note || '') === (w.note || ''));
        });
        return { id: p.id, name: p.name, breed: p.breed, birth: p.birth, weights: nextWeights, cares: p.cares || [] };
      });
      store.save({ pets: nextPets, activePetId: active.id });
    };
    row.append(left, delBtn);
    box.appendChild(row);
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
  if (active) {
    var delPetBtn = document.createElement('button');
    delPetBtn.className = 'danger-ghost sm';
    delPetBtn.textContent = '删除当前宠物';
    delPetBtn.onclick = function () {
      if (!window.confirm('确定删除宠物档案「' + active.name + '」及其全部体重与疫苗驱虫记录吗？')) return;
      var nextPets = state.pets.filter(function (p) { return p.id !== active.id; });
      var nextActiveId = nextPets.length ? nextPets[0].id : '';
      store.save({ pets: nextPets, activePetId: nextActiveId });
    };
    tabs.appendChild(delPetBtn);
  }

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
    renderWeightList(null, []);
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
  renderWeightList(active, weights);

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
