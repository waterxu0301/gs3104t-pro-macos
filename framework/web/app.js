/* GANSS Device Hub — app.js (MD3 + Hybrid Transport) */
const $ = i => document.getElementById(i);
let devices = [], curDev = null, layer = 'normal';
let keys = [], modified = { normal: {}, fn: {} }, curKey = null, mediaKeys = [];
let msButtons = {}, msSelBtn = null, msState = { sensorType: 149, maxReportRate: 2 };
let commLines = [];
let whidDev = null;

const MODES = [[0,'关闭'],[1,'静态恒亮'],[2,'单点亮'],[3,'单熄灭'],[4,'繁星点点'],[5,'漫天飞雪'],[6,'百花争艳'],[7,'动态呼吸'],[8,'光谱循环'],[9,'彩泉涌动'],[10,'多彩纵横'],[11,'随波逐流'],[12,'峰回路转'],[13,'一触即发'],[14,'一石二鸟'],[15,'涟漪扩散'],[16,'川流不息'],[17,'重峦叠嶂'],[18,'斜风细雨'],[19,'来回穿梭']];
const MEDIA_KEYS = ['音量+','音量-','静音','播放暂停','播放停止','上一曲','下一曲','计算器','多媒体','主页','刷新','前进','后退','收藏','搜索','邮箱'];
const RATE_LABELS = {8:'125Hz',4:'250Hz',2:'500Hz',1:'1000Hz',17:'2000Hz',18:'4000Hz',20:'8000Hz'};

function status(kind, text) { const s = $('status'); if (!s) return; s.className = kind; s.textContent = text; commLog(kind + ': ' + text); }
function msStatus(kind, text) { const s = $('msStatus'); if (!s) return; s.className = kind === 'ok' ? 'ok' : kind; s.className = kind; s.textContent = text; commLog('[MS] ' + text); }
function commLog(line) {
  commLines.push(`[${new Date().toLocaleTimeString()}] ${line}`);
  const el = $('commLog');
  if (el) el.textContent = commLines.slice(-100).join('\n');
}
async function api(m, p = {}) {
  const r = await fetch('/api', {method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({api_version:2, id:String(Date.now()), method:m, params:p})});
  const j = await r.json();
  commLog(`API ${m} → ${j.ok ? 'ok' : j.error?.code}`);
  return j;
}

/* ================= device bar ================= */
async function scan() {
  const r = await api('devices.scan');
  if (!r.ok) return status('err', r.error.message);
  devices = r.result.devices;
  renderDevbar();
  if (!curDev || !devices.find(d => d.device_id === curDev)) {
    const kb = devices.find(d => d.device_type === 'keyboard');
    if (kb) switchDev(kb.device_id);
  }
}
function renderDevbar() {
  $('devbar').innerHTML = devices.map(d => {
    const online = d.online !== false && !d.sleeping && d.readonly !== true;
    const dot = d.readonly ? 'ro' : (online ? 'ok' : 'sleep');
    const conn = d.connection === 'wireless' ? '2.4G' : d.connection === 'bluetooth' ? 'BT' : 'USB';
    const icon = d.device_type === 'keyboard' ? 'i-kb' : 'i-mouse';
    const batt = d.battery != null ? `<span class="batt"><span class="batt-bar"><span class="batt-fill" style="width:${d.battery}%"></span></span>${d.battery}%</span>` : '';
    return `<div class="devtab${curDev===d.device_id?' active':''}" onclick="switchDev('${d.device_id}')">
      <svg><use href="#${icon}"/></svg>
      <span>${d.name.replace('GANSS ','')}</span>
      <span class="conn-chip">${conn}</span>
      ${batt}
      <span class="status-dot dot-${dot}"></span></div>`;
  }).join('');
  const sleeping = devices.some(d => d.sleeping);
  $('sleepbar').classList.toggle('show', sleeping);
}
async function switchDev(id) {
  curDev = id;
  const d = devices.find(x => x.device_id === id);
  renderDevbar();
  if (d.device_type === 'keyboard') { $('kbView').classList.remove('hidden'); $('msView').classList.add('hidden'); initKb(d); }
  else { $('msView').classList.remove('hidden'); $('kbView').classList.add('hidden'); initMouse(d); }
}
async function syncPending() { status('info', '设备唤醒后请重新下发配置（各键位操作会即时生效）'); scan(); }

/* ================= keyboard ================= */
let kbInited = false;
async function initKb(d) {
  const st = await api('device.state', {device: d.device_id});
  if (st.ok) {
    const s = st.result.state;
    if (s.shadow) modified = s.shadow.keymap || {normal:{},fn:{}};
    const ro = s.readonly === true;
    $('kbStateInfo').innerHTML =
      `连接: ${s.connection}${ro?'（只读）':''} · 硬件回读: ${s.readback==='hardware'?'支持（新固件）':'不支持'}` +
      (s.battery!=null?`<br>电量: ${s.battery}%`:'') +
      (s.fn_tab_required?'<br>映射生效前需按 Fn+Tab 开启驱动自定义模式':'') +
      (s.note?`<br>${s.note}`:'');
    document.querySelectorAll('#kbView button').forEach(b => b.disabled = ro);
    $('sleepbar').classList.toggle('show', s.sleeping === true);
  }
  if (kbInited) { refreshBadges(); return; }
  kbInited = true;
  const k = await api('keys.list', {device: d.device_id});
  if (k.ok) {
    keys = k.result.keys;
    mediaKeys = k.result.media_keys || [];
    $('mediaKey').innerHTML = mediaKeys.map(m => `<option value="${m.id}">${m.name}</option>`).join('');
    buildCanvas(); buildUsageList(); buildModifiers();
  }
  refreshProfiles();
}
function buildCanvas() {
  if (!keys.length) return;
  const maxX = Math.max(...keys.map(k => k.rect[0]+k.rect[2]));
  const maxY = Math.max(...keys.map(k => k.rect[1]+k.rect[3]));
  const sc = 1.9, W = (maxX+10)*sc, H = (maxY+10)*sc;
  let svg = `<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" style="background:#FAFAFA;border:1px solid var(--g-line);border-radius:12px">`;
  for (const k of keys) {
    const [x,y,w,h] = k.rect;
    svg += `<g><rect class="keyrect" data-idx="${k.index}" x="${(x+5)*sc}" y="${(y+5)*sc}" width="${w*sc}" height="${h*sc}" rx="5"/>
      <text class="keylabel" x="${(x+5)*sc+w*sc/2}" y="${(y+5)*sc+h*sc/2+3}" text-anchor="middle">${k.name}</text>
      <text class="keysub" data-badge="${k.index}" x="${(x+5)*sc+w*sc-2}" y="${(y+5)*sc+11}" text-anchor="end"></text></g>`;
  }
  $('kb').innerHTML = svg + '</svg>';
  $('kb').addEventListener('click', e => { const r = e.target.closest('.keyrect'); if (r) selectKey(+r.dataset.idx); });
  refreshBadges();
}
function keyByIndex(i) { return keys.find(k => k.index === i); }
function selectKey(i) {
  curKey = i;
  document.querySelectorAll('.keyrect').forEach(r => r.classList.toggle('selected', +r.dataset.idx === i));
  const k = keyByIndex(i);
  $('selName').textContent = `${k.name} · #${i}`;
  if (k.name === 'Fn') status('info', 'Fn 为系统保留键，禁止修改（防自锁保护）');
  const cur = modified[layer][k.name];
  renderTypeUI();
  if (cur) {
    if (cur.startsWith('media:')) { $('mapType').value='media'; $('mediaKey').value=cur; }
    else if (cur.startsWith('macro:')) { $('mapType').value='macro'; $('macroSlot').value=cur.slice(6); }
    else if (cur === 'disabled') $('mapType').value = 'disabled';
    else if (cur !== 'default') { $('mapType').value='key'; $('comboKey').value=cur; }
    else $('mapType').value='default';
  } else $('mapType').value='default';
}
function setLayer(l) {
  layer = l;
  $('layNormal').classList.toggle('active', l==='normal');
  $('layFn').classList.toggle('active', l==='fn');
  refreshBadges();
}
function refreshBadges() {
  const m = modified[layer] || {}; let n = 0;
  document.querySelectorAll('.keyrect').forEach(r => {
    const k = keyByIndex(+r.dataset.idx);
    const mod = m[k.name] && m[k.name] !== 'default';
    r.classList.toggle('modified', !!mod);
    r.classList.toggle('reserved', k.name === 'Fn');
    if (mod) n++;
    const b = document.querySelector(`[data-badge="${k.index}"]`);
    if (b) b.textContent = mod ? m[k.name].replace('media:','').slice(0,6) : '';
  });
}
function buildUsageList() {
  $('usageList').innerHTML = ['A','B','C','V','X','Q','W','Esc','Space','Enter','Tab'].map(n => `<option value="${n}">`).join('');
}
function buildModifiers() {
  ['LCtrl','LShift','LAlt','LWin','RCtrl','RShift','RAlt','RWin'].forEach(m => {
    $('modifierBoxes').insertAdjacentHTML('beforeend', `<label><input type="checkbox" data-mod="${m}">${m}</label>`);
  });
}
function renderTypeUI() {
  const t = $('mapType').value;
  $('uiKey').classList.toggle('hidden', t!=='key');
  $('uiMedia').classList.toggle('hidden', t!=='media');
  $('uiMacro').classList.toggle('hidden', t!=='macro');
}
function comboFromUI() {
  const m = [...document.querySelectorAll('[data-mod]:checked')].map(c => c.dataset.mod);
  const k = $('comboKey').value.trim();
  return k ? [...m, k].join('+') : null;
}
async function applyMap() {
  if (curKey == null) return status('err', '请先点击键盘选择一个按键');
  const k = keyByIndex(curKey);
  if (k.name === 'Fn') return status('warn', 'Fn 为系统保留键，禁止修改');
  const t = $('mapType').value;
  let target = 'default';
  if (t === 'key') { target = comboFromUI(); if (!target) return status('err','请填写目标键'); }
  if (t === 'media') target = $('mediaKey').value;
  if (t === 'disabled') target = 'disabled';
  if (t === 'macro') target = `macro:${$('macroSlot').value}`;
  const r = await api('device.apply', {device: curDev, module:'keymap', patch:{source:k.name, target, layer}});
  if (r.ok) { modified[layer][k.name] = target; refreshBadges();
    status('ok', `${k.name} → ${target} 已下发（硬件 ACK）` + (r.result.apply.note ? '\n' + r.result.apply.note : '')); }
  else status('err', r.error.message);
}
async function applyDefault() {
  if (curKey == null) return status('err','请先选择按键');
  const k = keyByIndex(curKey);
  if (k.name === 'Fn') return status('warn','Fn 为系统保留键');
  const r = await api('device.apply', {device:curDev, module:'keymap', patch:{source:k.name, target:'default', layer}});
  if (r.ok) { modified[layer][k.name] = 'default'; refreshBadges(); status('ok', `${k.name} 已恢复默认`); }
  else status('err', r.error.message);
}
async function applyFullLayer() {
  const r = await api('device.apply', {device:curDev, module:'keymap_full', patch:{layer, mappings: modified[layer] || {}}});
  status(r.ok ? 'ok' : 'err', r.ok ? `整层（${layer==='normal'?'普通':'Fn'}层 112 键）已下发` : r.error.message);
}
async function restoreLayer() {
  if (!confirm(`确认恢复${layer==='normal'?'普通':'Fn'}层全部 112 键为默认？`)) return;
  const r = await api('device.reset', {device:curDev, scope:'layer', layer});
  if (r.ok) { modified[layer] = {}; refreshBadges(); status('ok','全层已恢复默认'); }
  else status('err', r.error.message);
}
async function kbLighting() {
  const r = await api('device.apply', {device:curDev, module:'lighting', patch:{mode:1, color:'1A73E8', brightness:4, speed:3}});
  status(r.ok?'ok':'err', r.ok?'灯光已切换（Google Blue）':r.error.message);
}

/* profiles */
async function refreshProfiles() {
  const r = await api('profiles.list', {device:curDev});
  if (r.ok) {
    const ps = r.result.profiles;
    $('profiles').innerHTML = ps.length ? ps.map(p =>
      `<div class="profile-item"><span>${p.name}</span><span><button class="m3" onclick="delProfile('${p.name}')">删除</button></span></div>`).join('')
      : '<span style="font-size:12px;color:var(--g-sub)">暂无已保存配置</span>';
  }
}
async function saveProfile() {
  const n = $('profileName').value.trim();
  if (!n) return status('err','请填写配置名');
  const r = await api('profiles.save', {device:curDev, name:n, data:{keymap: JSON.parse(JSON.stringify(modified))}});
  if (r.ok) { status('ok','配置已保存: '+n); $('profileName').value=''; refreshProfiles(); }
  else status('err', r.error.message);
}
async function delProfile(n) { await api('profiles.delete',{device:curDev,name:n}); refreshProfiles(); }
async function exportProfiles() {
  const r = await api('profiles.export',{device:curDev});
  if (r.ok) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([JSON.stringify(r.result.export,null,2)],{type:'application/json'}));
    a.download = 'ganss-profiles.json'; a.click();
  }
}
async function importProfiles(ev) {
  const f = ev.target.files[0]; if (!f) return;
  const r = await api('profiles.import',{device:curDev, data: JSON.parse(await f.text())});
  if (r.ok) { status('ok',`已导入 ${r.result.result.imported} 个配置`); refreshProfiles(); }
  else status('err', r.error.message);
}
/* presets */
async function applyPreset(kind) {
  closeMenus();
  const mapping = {};
  if (kind === 'mac') {
    Object.assign(mapping, {'Win_L':'Alt_L','Alt_L':'Win_L',
      'VOLINC':'media:音量+','VOLDEC':'media:音量-','MUTE':'media:静音'});
  } else if (kind === 'game') {
    mapping['Win_L'] = 'disabled';
  } else if (kind === 'win') {
    /* all default */
  }
  if (kind === 'win') {
    const r = await api('device.reset',{device:curDev, scope:'layer', layer:'normal'});
    status(r.ok?'ok':'err', r.ok?'已恢复标准 Windows 默认（全层下发）':r.error.message);
    if (r.ok) { modified.normal = {}; refreshBadges(); }
  } else {
    const r = await api('device.apply',{device:curDev, module:'keymap_multi', patch:{layer:'normal', mappings:mapping}});
    if (r.ok) { Object.assign(modified.normal, mapping); refreshBadges();
      status('ok', `模板已应用（${Object.keys(mapping).length} 键）`); }
    else status('err', r.error.message);
  }
}
function closeMenus() { $('presetMenu').classList.remove('show'); }

/* ================= WebHID bridge (FLX3) ================= */
const WHID_VID = 0x04F3;
async function whidConnect() {
  if (!navigator.hid) { $('whidState').textContent = '浏览器不支持 WebHID'; return; }
  try {
    let ds = await navigator.hid.getDevices();
    if (!ds.length) ds = await navigator.hid.requestDevice({filters:[{vendorId: WHID_VID}]});
    if (!ds.length) { $('whidState').textContent = '未选择设备'; return; }
    whidDev = ds.find(d => d.collections.length > 2) || ds[0];
    if (!whidDev.opened) await whidDev.open();
    whidDev.addEventListener('inputreport', onWhidInput);
    const st = await whidDev.receiveFeatureReport(5);
    $('whidState').textContent = `已直连: ${whidDev.productName}`;
    $('btnWhidConnect').disabled = true;
    parseWhidState(st);
    commLog('[WebHID] connected ' + whidDev.productName);
  } catch (e) { $('whidState').textContent = '连接失败: ' + e.message; }
}
function onWhidInput(e) {
  if (e.reportId !== 4) return;
  const b = new Uint8Array(e.data.buffer);
  const st = {linkStatus:b[0], currentLevel:b[1], currentReportRate:b[2],
    batteryLevel:b[3], batteryStatus:b[4], lightEffectMode:b[5], maxReportRate:b[7],
    sensorType: b[8] || 149};
  msState = st;
  msUpdateLive(st);
  // state sync to backend shadow
  if (curDev && devices.find(d=>d.device_id===curDev && d.device_type==='mouse')) {
    fetch('/api', {method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({api_version:2, id:String(Date.now()), method:'device.telemetry',
        params:{device:curDev, state:st}})});
  }
}
function parseWhidState(buf) {
  const b = new Uint8Array(buf.buffer);
  msUpdateLive({linkStatus:b[1], currentLevel:b[2], currentReportRate:b[3],
    batteryLevel:b[4], batteryStatus:b[5], maxReportRate:b[7], sensorType:b[8]||149});
}
function msUpdateLive(st) {
  $('msStateInfo').innerHTML = `电量 <b>${st.batteryLevel ?? '?'}%</b> · 传感器 ${st.sensorType} ` +
    `(${ {17:'3311',149:'PAW3395',80:'3950',32:'3220',18:'3212',9:'3809',6:'S205',112:'OM70'}[st.sensorType]||'未知' })` +
    ` · 回报率上限 ${RATE_LABELS[st.maxReportRate]||st.maxReportRate}` +
    `<br>状态: ${st.linkStatus ? '在线' : '休眠'}`;
  $('sleepbar').classList.toggle('show', !st.linkStatus);
}
async function whidCmd(logical, fill = 255) {
  if (!whidDev) throw new Error('浏览器直连未就绪，请先点击"授权浏览器直连"');
  const a = logical.slice(); a[1] = (a[1] + 1) % 256 || 1;
  while (a.length < 31) a.push(fill);
  let sum = 6; a.forEach((v,i) => { if (i !== 3) sum += v; });
  a.splice(3, 0, sum & 255); a.length = 32;
  await whidDev.sendFeatureReport(6, a);
  await new Promise(r => setTimeout(r, 400));
  const ack = await whidDev.receiveFeatureReport(6);
  return ack.getUint8(1) === 1;
}

/* ================= mouse ================= */
let msInited = false;
async function initMouse(d) {
  // prefer WebHID
  if (navigator.hid) {
    const ds = await navigator.hid.getDevices();
    if (ds.length) {
      whidDev = ds.find(x => x.collections.length > 2) || ds[0];
      if (!whidDev.opened) await whidDev.open().catch(()=>{});
      whidDev.addEventListener('inputreport', onWhidInput);
      $('btnWhidConnect').disabled = true;
      $('whidState').textContent = '已直连: ' + whidDev.productName;
    }
  }
  const st = await api('device.state', {device:d.device_id});
  if (st.ok) {
    const s = st.result.state;
    msState = {...msState, sensorType: s.sensorType || 149, maxReportRate: s.maxReportRate || 2};
    $('msStateInfo').innerHTML = s.note || '—';
    $('sleepbar').classList.toggle('show', s.sleeping === true);
  }
  if (msInited) { msRenderButtons(); return; }
  msInited = true;
  $('mouseSvg').innerHTML = `<svg width="280" height="250" viewBox="0 0 280 250">
    <ellipse cx="140" cy="125" rx="80" ry="112" fill="#202124" stroke="#3c4043"/>
    <line x1="140" y1="28" x2="140" y2="110" stroke="#5f6368"/>
    <rect x="128" y="95" width="24" height="26" rx="8" fill="#3c4043"/>
    ${[[1,95,45],[2,185,45],[3,140,88],[6,140,138],[4,68,112],[5,68,150]].map(([b,x,y]) =>
      `<g class="mbtn" data-btn="${b}" onclick="msSelectBtn(${b})">
        <circle cx="${x}" cy="${y}" r="16" fill="#1A73E8" opacity="0.92"/>
        <text x="${x}" y="${y+4}" text-anchor="middle" fill="#fff" font-size="13" font-weight="700">${b}</text></g>`).join('')}
  </svg>`;
  $('msMedia').innerHTML = MEDIA_KEYS.map(n => `<option value="media:${n}">${n}</option>`).join('');
  $('msLightMode').innerHTML = Object.entries({0:'关闭',1:'混彩流光',2:'呼吸',3:'常亮',4:'霓虹',5:'跑马',6:'混彩常亮',7:'七彩波浪'}).map(([v,n])=>`<option value="${v}">${n}</option>`).join('');
  const rates = [8,4,2,1,17];
  $('msRateGroup').innerHTML = rates.map(v => `<label class="pill ro"><input type="radio" name="rate" value="${v}"${v===1?' checked':''}>${RATE_LABELS[v]}</label>`).join('');
  renderDpiStages();
  msRenderButtons();
}
const BTN_LABELS = {1:'左键',2:'右键',3:'中键',4:'前进',5:'后退',6:'DPI循环'};
function msRenderButtons() {
  $('msButtonList').innerHTML = Object.entries(BTN_LABELS).map(([b,n]) => {
    const v = msButtons[b];
    const tag = v ? (v.startsWith('media:') ? v.slice(6) : v.replace('mouse:','').replace('dpi_','DPI')) : '默认';
    return `<div class="profile-item" onclick="msSelectBtn(${b})" style="${msSelBtn==b?'border-color:var(--g-blue)':''}">
      <span><b>${b}</b> · ${n}</span><span class="pill ro">${tag}</span></div>`;
  }).join('');
}
function msSelectBtn(b) {
  msSelBtn = b;
  document.querySelectorAll('.mbtn').forEach(g => g.classList.toggle('active', +g.dataset.btn === b));
  $('msCurBtn').textContent = `按键 ${b}`;
  const cur = msButtons[b];
  msRenderType();
  if (cur) {
    if (cur.startsWith('media:')) { $('msType').value='media'; $('msMedia').value=cur; }
    else if (cur.startsWith('mouse:')) { $('msType').value='mouse'; $('msMouseBtn').value=cur; }
    else if (cur.startsWith('dpi_')) { $('msType').value='dpi'; $('msDpiFn').value=cur; }
    else if (cur.startsWith('fire:')) $('msType').value='fire';
    else if (cur === 'disable') $('msType').value='disable';
    else { $('msType').value='combo'; $('msCombo').value=cur; }
  } else $('msType').value='default';
  msRenderButtons();
}
function msRenderType() {
  const t = $('msType').value;
  for (const [id, show] of [['msUiMouse','mouse'],['msUiCombo','combo'],['msUiMedia','media'],['msUiFire','fire'],['msUiDpi','dpi']])
    $(id).classList.toggle('hidden', t !== show);
}
function msSpecFromUI() {
  const t = $('msType').value;
  if (t === 'default') return null;
  if (t === 'disable') return 'disable';
  if (t === 'mouse') return $('msMouseBtn').value;
  if (t === 'media') return $('msMedia').value;
  if (t === 'fire') return `fire:${$('msFireInt').value}:${$('msFireCnt').value}`;
  if (t === 'dpi') return $('msDpiFn').value;
  return $('msCombo').value.trim() || null;
}
async function msApply() {
  if (!msSelBtn) return msStatus('err','请先点击鼠标图选择按键');
  msButtons[msSelBtn] = msSpecFromUI();
  try {
    const ok = await whidCmd([1,0,1, ...buildMsRecords()], 255);
    msStatus(ok?'ok':'err', ok ? `按键 ${msSelBtn} 已下发（ACK status=1）` : '设备返回 status=0');
  } catch(e) { msStatus('err', e.message); }
  msRenderButtons();
}
function buildMsRecords() {
  const out = [];
  for (let slot = 0; slot < 9; slot++) {
    let btn = slot + 1;
    if (slot === 3) btn = 5; else if (slot === 4) btn = 4; // official swap
    const v = msButtons[btn];
    let rec = [255,255,255];
    if (v === 'disable') rec = [96,0,0];
    else if (v === 'dpi_cycle') rec = [64,1,0];
    else if (v === 'dpi_up') rec = [64,2,0];
    else if (v === 'dpi_down') rec = [64,3,0];
    else if (v && v.startsWith('mouse:')) { const m = {左键:1,右键:2,中键:4,后退:8,前进:16}; rec = [16, m[v.slice(6)]||1, 0]; }
    else if (v && v.startsWith('media:')) { const u = MEDIA_USAGE[v.slice(6)]; rec = [128, u&255, u>>8&255]; }
    else if (v && v.startsWith('dpi_lock:')) rec = [80, +v.slice(9), 0];
    else if (v && v.startsWith('fire:')) { const [,i,c] = v.split(':'); rec = [48, +i, +c]; }
    else if (v && !v.startsWith('macro:')) {
      let mask = 0, usage = null;
      for (const part of v.split('+')) {
        const p = part.trim();
        const mm = {LCtrl:1,LShift:2,LAlt:4,LWin:8,RCtrl:16,RShift:32,RAlt:64,RWin:128};
        if (mm[p]) mask |= mm[p];
        else {
          try { usage = parseInt(p, 0); } catch(e) {}
          if (usage == null || isNaN(usage)) {
            const alias = {a:4,b:5,c:6,d:7,e:8,f:9,g:10,h:11,i:12,j:13,k:14,l:15,m:16,n:17,o:18,p:19,q:20,r:21,s:22,t:23,u:24,v:25,w:26,x:27,y:28,z:29,space:44,enter:40,esc:41,tab:43};
            usage = alias[p.toLowerCase()] || null;
          }
        }
      }
      if (usage != null) rec = [112, mask, usage];
    }
    out.push(...rec);
  }
  return out;
}
const MEDIA_USAGE = {播放暂停:0xCD,播放停止:0xB7,上一曲:0xB6,下一曲:0xB5,音量:0xE9,'音量+':0xE9,'音量-':0xEA,静音:0xE2,计算器:0x192,邮箱:0x18A,多媒体:0x183,主页:0x223,刷新:0x227,前进:0x225,后退:0x224,收藏:0x22A,搜索:0x221};
function renderDpiStages() {
  const sensor = msState.sensorType, step = (sensor===149||sensor===80) ? 50 : 100;
  const max = {17:12000,149:26000,80:30000,32:8000,18:4800,9:6000,6:12800,112:30000}[sensor] || 26000;
  $('msSensorBadge').textContent = `sensor ${sensor} · 步进 ${step} · 上限 ${max}`;
  const defaults = [400,800,1600,3200,6400];
  $('dpiStages').innerHTML = Array.from({length:6}, (_,i) => {
    const v = defaults[i] || Math.min((defaults[i-1]||400)*2, max);
    return `<div class="dpi-cfg"><div style="display:flex;gap:10px;align-items:center">
      <b>档 ${i+1}</b>
      <input type="range" min="100" max="${max}" step="${step}" value="${v}" style="flex:1"
        oninput="this.nextElementSibling.value=this.value">
      <input type="number" value="${v}" onchange="this.previousElementSibling.value=this.value">
      <input type="color" value="${['#EA4335','#4285F4','#34A853','#FBBC04','#00DDE4','#B500EC'][i]}" style="width:36px;height:30px;padding:2px">
    </div></div>`;
  }).join('');
}
async function msApplyDpi() {
  const stages = [...document.querySelectorAll('#dpiStages input[type=number]')].map(i => +i.value);
  const mask = (1 << stages.length) - 1;
  const l = [2,0,2,2,mask];
  const sensor = msState.sensorType, step = (sensor===149||sensor===80) ? 50 : 100;
  for (let i = 0; i < 8; i++) {
    const dpi = stages[i] || 0;
    const reg = dpi ? Math.floor(dpi/step)-1 : 0;
    l.push(reg & 255, (reg>>8) & 255);
  }
  try {
    const ok = await whidCmd(l);
    msStatus(ok?'ok':'err', ok ? `DPI 已下发（${stages.length} 档，ACK=1）` : 'DPI status=0');
  } catch(e) { msStatus('err', e.message); }
}
async function msApplyDpiColor() {
  const colors = [...document.querySelectorAll('#dpiStages input[type=color]')].map(i => i.value);
  const l = [3,0,1];
  for (let i = 0; i < 8; i++) {
    const c = (colors[i] || '#EA5E56').replace('#','');
    l.push(parseInt(c.slice(0,2),16), parseInt(c.slice(2,4),16), parseInt(c.slice(4,6),16));
  }
  try {
    const ok = await whidCmd(l);
    msStatus(ok?'ok':'err', ok ? '档位颜色已下发' : '颜色 status=0');
  } catch(e) { msStatus('err', e.message); }
}
async function msApplyPerf() {
  const rate = +document.querySelector('input[name=rate]:checked').value;
  const lod = +document.querySelector('input[name=lod]:checked').value;
  try {
    const okR = await whidCmd([4,0,1,rate], 0);
    const okL = await whidCmd([5,0,1,lod]);
    const okS = await whidCmd([8,0,1, $('msAngle').checked?1:0, $('msMotion').checked?1:0, $('msRipple').checked?1:0]);
    msStatus(okR&&okL&&okS?'ok':'err', `回报率 ${RATE_LABELS[rate]} · LOD ${lod}mm · Sensor 调整：` +
      (okR&&okL&&okS ? '全部 ACK=1' : '部分 status=0'));
  } catch(e) { msStatus('err', e.message); }
}
async function msApplyPower() {
  try {
    const ok = await whidCmd([7,0,1, +$('msSleep').value, $('msWakeup').checked?1:0, 0]);
    msStatus(ok?'ok':'err', ok ? '电源设置已下发' : '电源 status=0');
  } catch(e) { msStatus('err', e.message); }
}
async function msApplyLight() {
  try {
    const c = $('msLightColor').value.replace('#','');
    const ok = await whidCmd([6,0,1,255, +$('msLightMode').value,
      (Math.min(Math.max(+$('msLightBri').value,1),4)<<4) | Math.min(Math.max(+$('msLightSpd').value,1),3),
      0, parseInt(c.slice(0,2),16), parseInt(c.slice(2,4),16), parseInt(c.slice(4,6),16)]);
    msStatus(ok?'ok':'err', ok ? '灯光已下发（ACK=1）' : '灯光 status=0');
  } catch(e) { msStatus('err', e.message); }
}
async function msFactoryReset() {
  if (!confirm('确认恢复出厂设置？将擦除所有按键、DPI 与宏。')) return;
  try {
    const ok = await whidCmd([15,0,1,255], 255);
    msStatus(ok?'ok':'err', ok ? '已恢复出厂' : 'reset status=0');
  } catch(e) { msStatus('err', e.message); }
}
function msTab(btn, id) {
  document.querySelectorAll('.tabs button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  for (const v of ['msKeys','msDpi','msPerf','msOther']) $(v).classList.toggle('hidden', v !== id);
}

/* drawers & menus */
function openDrawer(id) { $(id).classList.add('show'); $('drawerMask').classList.add('show'); }
function closeDrawers() {
  document.querySelectorAll('.drawer').forEach(d => d.classList.remove('show'));
  $('drawerMask').classList.remove('show');
  closeMenus();
}
$('btnPlugins').onclick = async () => {
  const r = await api('plugins.list');
  if (r.ok) {
    $('pluginList').innerHTML = r.result.plugins.map(p =>
      `<div class="profile-item"><div><b>${p.name}</b> <span class="pill ro">${p.plugin_id} v${p.version}</span>
       <div style="font-size:11px;color:var(--g-sub);margin-top:4px">${p.capabilities.join(', ')}</div></div>
       <button class="m3" onclick="togglePlugin('${p.plugin_id}',${!p.enabled})">${p.enabled?'禁用':'启用'}</button></div>`).join('');
  }
  openDrawer('pluginDrawer');
};
async function togglePlugin(id, en) {
  await api('plugins.set_enabled', {plugin_id:id, enabled:en});
  closeDrawers(); scan();
}
$('btnLogs').onclick = () => openDrawer('logDrawer');
$('btnExport').onclick = exportProfiles;
$('btnImport').onclick = () => $('importFile').click();
$('btnPresets').onclick = e => {
  e.stopPropagation();
  const m = $('presetMenu');
  const r = e.currentTarget.getBoundingClientRect();
  m.style.top = (r.bottom + 6) + 'px';
  m.style.right = (window.innerWidth - r.right) + 'px';
  m.classList.toggle('show');
};
document.addEventListener('click', e => {
  if (!e.target.closest('#presetMenu') && !e.target.closest('#btnPresets')) closeMenus();
});

scan();
