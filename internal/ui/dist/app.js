// =============================================================================
// conMon Web UI — app.js
// =============================================================================
'use strict';

// ── 全局状态 ─────────────────────────────────────────────────────────────────
const State = {
  targets: [],       // [{target, state}]
  events: [],
  alerts: [],
  probes: [],
  currentPage: 'dashboard',
  currentDetail: null,
  detailChart: null,
  wsConnected: false,
  filterStatus: '',
  refreshTimer: null,
};

// ── 常量 ─────────────────────────────────────────────────────────────────────
const STATUS_COLOR = {
  UP:          { bg: 'bg-emerald-100', text: 'text-emerald-700', dot: 'bg-emerald-500', border: 'border-emerald-300' },
  DOWN:        { bg: 'bg-red-100',     text: 'text-red-700',     dot: 'bg-red-500',     border: 'border-red-300' },
  DEGRADED:    { bg: 'bg-amber-100',   text: 'text-amber-700',   dot: 'bg-amber-500',   border: 'border-amber-300' },
  FLAPPING:    { bg: 'bg-orange-100',  text: 'text-orange-700',  dot: 'bg-orange-500',  border: 'border-orange-300' },
  MAINTENANCE: { bg: 'bg-blue-100',    text: 'text-blue-700',    dot: 'bg-blue-500',    border: 'border-blue-300' },
  SILENT:      { bg: 'bg-slate-100',   text: 'text-slate-600',   dot: 'bg-slate-400',   border: 'border-slate-300' },
  UNKNOWN:     { bg: 'bg-slate-100',   text: 'text-slate-500',   dot: 'bg-slate-300',   border: 'border-slate-200' },
};

const PROTO_ICON = {
  https: '🔒', http: '🌐', tcp: '🔌', udp: '📡',
  icmp: '📶', dns: '🔤', grpc: '⚡', websocket: '🔄',
};

// ── API 请求 ──────────────────────────────────────────────────────────────────
async function api(method, path, body) {
  const opts = { method, headers: { 'Content-Type': 'application/json' } };
  if (body) opts.body = JSON.stringify(body);
  const resp = await fetch('/api/v1' + path, opts);
  if (!resp.ok) {
    const err = await resp.json().catch(() => ({ message: resp.statusText }));
    throw new Error(err.message || resp.statusText);
  }
  if (resp.status === 204) return null;
  return resp.json();
}

// ── WebSocket 实时推送 ────────────────────────────────────────────────────────
function connectWS() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${proto}://${location.host}/api/v1/ws/status`);

  ws.onopen = () => {
    State.wsConnected = true;
    setWsIndicator(true);
    console.log('[WS] 已连接');
  };

  ws.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data);
      handleWSMessage(msg);
    } catch { }
  };

  ws.onclose = () => {
    State.wsConnected = false;
    setWsIndicator(false);
    // 5 秒后重连
    setTimeout(connectWS, 5000);
  };

  ws.onerror = () => ws.close();
}

function handleWSMessage(msg) {
  if (msg.type === 'snapshot') {
    // 全量状态快照（初始连接时）
    if (msg.data) {
      State.targets = msg.data;
      renderAll();
    }
  } else if (msg.type === 'status_changed') {
    // 增量状态变更
    const idx = State.targets.findIndex(t => t.target?.id === msg.target_id);
    if (idx >= 0 && State.targets[idx].state) {
      State.targets[idx].state.status = msg.to;
      State.targets[idx].state.status_changed_at = msg.timestamp;
    }
    renderAll();
    // 如果是 DOWN 事件，展示 toast
    if (msg.to === 'DOWN') {
      const name = State.targets[idx]?.target?.name || msg.target_id;
      showToast(`⚠ ${name} 变为 DOWN`, 'error');
    } else if (msg.to === 'UP' && msg.from === 'DOWN') {
      const name = State.targets[idx]?.target?.name || msg.target_id;
      showToast(`✓ ${name} 已恢复`, 'success');
    }
  }
}

function setWsIndicator(connected) {
  const dot = document.getElementById('ws-dot');
  const label = document.getElementById('ws-label');
  if (connected) {
    dot.className = 'status-dot bg-emerald-500';
    label.textContent = '实时连接';
  } else {
    dot.className = 'status-dot bg-slate-300 pulse';
    label.textContent = '重连中...';
  }
}

// ── 数据加载 ──────────────────────────────────────────────────────────────────
async function loadAll() {
  await Promise.allSettled([
    loadTargets(),
    loadEvents(),
    loadAlerts(),
    loadProbes(),
  ]);
  renderAll();
}

async function loadTargets() {
  try {
    const res = await api('GET', '/targets?limit=500');
    // 对每个目标取状态
    const targets = res.data || [];
    const withState = await Promise.all(targets.map(async t => {
      try {
        const detail = await api('GET', `/targets/${t.id}`);
        return detail;
      } catch {
        return { target: t, state: null };
      }
    }));
    State.targets = withState.filter(Boolean);
  } catch (e) {
    console.error('loadTargets:', e);
  }
}

async function loadEvents() {
  try {
    const res = await api('GET', '/events?limit=100');
    State.events = res?.data || [];
  } catch (e) {
    // /events 可能需要 target_id，尝试全局
    State.events = [];
  }
}

async function loadAlerts() {
  try {
    const res = await api('GET', '/alerts?limit=100');
    State.alerts = res?.data || [];
    updateAlertBadge();
  } catch (e) {
    State.alerts = [];
  }
}

async function loadProbes() {
  try {
    const res = await api('GET', '/probes');
    State.probes = res?.data || [];
  } catch (e) {
    State.probes = [];
  }
}

// ── 渲染：统一入口 ────────────────────────────────────────────────────────────
function renderAll() {
  renderStats();
  if (State.currentPage === 'dashboard') {
    renderDashTargets();
    renderDashEvents();
  } else if (State.currentPage === 'targets') {
    renderTargets();
  } else if (State.currentPage === 'events') {
    renderEvents();
  } else if (State.currentPage === 'alerts') {
    renderAlerts();
  } else if (State.currentPage === 'probes') {
    renderProbes();
  }
}

// ── 统计卡片 ──────────────────────────────────────────────────────────────────
function renderStats() {
  const counts = { UP: 0, DOWN: 0, DEGRADED: 0, FLAPPING: 0, UNKNOWN: 0, MAINTENANCE: 0, SILENT: 0 };
  State.targets.forEach(({ state }) => {
    const s = state?.status || 'UNKNOWN';
    counts[s] = (counts[s] || 0) + 1;
  });
  setText('stat-total', State.targets.length);
  setText('stat-up', counts.UP);
  setText('stat-down', counts.DOWN);
  setText('stat-degraded', counts.DEGRADED + counts.FLAPPING);
}

// ── 总览页目标列表 ────────────────────────────────────────────────────────────
function renderDashTargets() {
  const search = document.getElementById('dash-search')?.value?.toLowerCase() || '';
  const container = document.getElementById('dash-targets');
  if (!container) return;

  let items = State.targets;
  if (State.filterStatus) items = items.filter(({ state }) => state?.status === State.filterStatus);
  if (search) items = items.filter(({ target }) =>
    target.name?.toLowerCase().includes(search) ||
    target.host?.toLowerCase().includes(search)
  );

  // 按状态优先级排序: DOWN > DEGRADED > FLAPPING > UP > others
  const order = { DOWN: 0, DEGRADED: 1, FLAPPING: 2, UP: 3 };
  items.sort((a, b) => (order[a.state?.status] ?? 9) - (order[b.state?.status] ?? 9));

  if (!items.length) {
    container.innerHTML = `<div class="text-center py-12 text-slate-400 text-sm">${search ? '无匹配结果' : '暂无监控目标'}</div>`;
    return;
  }

  container.innerHTML = items.map(({ target, state }) => {
    const s = state?.status || 'UNKNOWN';
    const c = STATUS_COLOR[s] || STATUS_COLOR.UNKNOWN;
    const latency = state?.avg_latency_ms ? `${state.avg_latency_ms.toFixed(0)}ms` : '—';
    const since = state?.status_changed_at ? timeAgo(state.status_changed_at) : '';
    return `
      <div class="flex items-center px-5 py-3 hover:bg-slate-50 cursor-pointer transition" onclick="openDetail('${target.id}')">
        <div class="flex items-center gap-2 w-5">
          <span class="status-dot ${c.dot} ${s === 'DOWN' ? 'pulse' : ''}"></span>
        </div>
        <div class="flex-1 min-w-0 ml-3">
          <div class="flex items-center gap-2">
            <span class="text-sm font-medium text-slate-700 truncate">${escHtml(target.name)}</span>
            <span class="text-xs ${c.text} ${c.bg} px-1.5 py-0.5 rounded">${s}</span>
          </div>
          <div class="text-xs text-slate-400 truncate">${PROTO_ICON[target.protocol] || '◉'} ${escHtml(target.host)}${target.port ? ':' + target.port : ''}</div>
        </div>
        <div class="text-right ml-4 flex-shrink-0">
          <div class="text-sm font-mono ${s === 'DOWN' ? 'text-red-500' : 'text-slate-600'}">${latency}</div>
          <div class="text-xs text-slate-400">${since}</div>
        </div>
      </div>`;
  }).join('');
}

// ── 总览页事件 ────────────────────────────────────────────────────────────────
function renderDashEvents() {
  const container = document.getElementById('dash-events');
  if (!container) return;

  // 收集所有目标的事件（用目标名补充）
  const allEvents = [...State.events].slice(0, 30);

  setText('events-ts', allEvents.length ? `共 ${allEvents.length} 条` : '');

  if (!allEvents.length) {
    container.innerHTML = '<div class="text-center py-12 text-slate-400 text-sm">暂无事件</div>';
    return;
  }

  container.innerHTML = allEvents.map(e => {
    const tgt = State.targets.find(t => t.target?.id === e.target_id);
    const name = tgt?.target?.name || e.target_id;
    const isDown = e.to_status === 'DOWN';
    const icon = isDown ? '🔴' : (e.to_status === 'UP' ? '🟢' : '🟡');
    return `
      <div class="px-5 py-3 hover:bg-slate-50 transition">
        <div class="flex items-start gap-2">
          <span class="text-base mt-0.5">${icon}</span>
          <div class="flex-1 min-w-0">
            <div class="text-sm font-medium text-slate-700 truncate">${escHtml(name)}</div>
            <div class="text-xs text-slate-500">
              ${e.from_status || '?'} → <strong>${e.to_status}</strong>
              ${e.reason ? `<span class="text-slate-400 ml-1">(${e.reason})</span>` : ''}
            </div>
            <div class="text-xs text-slate-400 mt-0.5">${timeAgo(e.timestamp)}</div>
          </div>
        </div>
      </div>`;
  }).join('');
}

// ── 目标页 ────────────────────────────────────────────────────────────────────
function renderTargets() {
  const search = document.getElementById('tgt-search')?.value?.toLowerCase() || '';
  const statusFilter = document.getElementById('tgt-status-filter')?.value || '';
  const tbody = document.getElementById('targets-tbody');
  if (!tbody) return;

  let items = State.targets;
  if (search) items = items.filter(({ target }) =>
    target.name?.toLowerCase().includes(search) || target.host?.toLowerCase().includes(search)
  );
  if (statusFilter) items = items.filter(({ state }) => state?.status === statusFilter);

  if (!items.length) {
    tbody.innerHTML = `<tr><td colspan="8" class="text-center py-12 text-slate-400 text-sm">暂无数据</td></tr>`;
    return;
  }

  tbody.innerHTML = items.map(({ target, state }) => {
    const s = state?.status || 'UNKNOWN';
    const c = STATUS_COLOR[s] || STATUS_COLOR.UNKNOWN;
    const latency = state?.avg_latency_ms ? `${state.avg_latency_ms.toFixed(0)}ms` : '—';
    const avail = state?.availability_7d ? `${(state.availability_7d * 100).toFixed(2)}%` : '—';
    const tags = (target.tags || []).slice(0, 3)
      .map(tag => `<span class="bg-slate-100 text-slate-600 text-xs px-1.5 py-0.5 rounded">${escHtml(tag)}</span>`)
      .join(' ');
    return `
      <tr class="hover:bg-slate-50 transition cursor-pointer" onclick="openDetail('${target.id}')">
        <td class="px-5 py-3.5">
          <span class="status-dot ${c.dot} ${s === 'DOWN' ? 'pulse' : ''}" title="${s}"></span>
        </td>
        <td class="px-4 py-3.5">
          <div class="font-medium text-slate-800 text-sm">${escHtml(target.name)}</div>
          <div class="text-xs text-slate-400">${escHtml(target.id)}</div>
        </td>
        <td class="px-4 py-3.5 hidden md:table-cell">
          <div class="text-sm font-mono text-slate-600">${escHtml(target.host)}</div>
          <div class="text-xs text-slate-400">${target.port || '—'}</div>
        </td>
        <td class="px-4 py-3.5 hidden lg:table-cell">
          <span class="text-xs font-medium uppercase bg-slate-100 text-slate-600 px-2 py-0.5 rounded">
            ${PROTO_ICON[target.protocol] || ''} ${target.protocol}
          </span>
        </td>
        <td class="px-4 py-3.5 hidden lg:table-cell font-mono text-sm ${s === 'DOWN' ? 'text-red-500' : 'text-slate-700'}">${latency}</td>
        <td class="px-4 py-3.5 hidden xl:table-cell text-sm text-slate-600">${avail}</td>
        <td class="px-4 py-3.5 hidden xl:table-cell">
          <div class="flex flex-wrap gap-1">${tags}</div>
        </td>
        <td class="px-5 py-3.5 text-right">
          <div class="flex justify-end gap-1.5">
            <span class="text-xs ${c.text} ${c.bg} ${c.border} border px-2 py-0.5 rounded">${s}</span>
            <button onclick="event.stopPropagation(); deleteTarget('${target.id}', '${escHtml(target.name)}')"
              class="text-xs text-slate-400 hover:text-red-500 transition px-1">✕</button>
          </div>
        </td>
      </tr>`;
  }).join('');

  document.getElementById('targets-pagination').textContent = `共 ${items.length} 个目标`;
}

// ── 事件页 ────────────────────────────────────────────────────────────────────
function renderEvents() {
  const search = document.getElementById('evt-search')?.value?.toLowerCase() || '';
  const typeFilter = document.getElementById('evt-type-filter')?.value || '';
  const container = document.getElementById('events-list');
  if (!container) return;

  let items = State.events;
  if (search) items = items.filter(e => {
    const tgt = State.targets.find(t => t.target?.id === e.target_id);
    return (tgt?.target?.name || e.target_id).toLowerCase().includes(search);
  });
  if (typeFilter) items = items.filter(e => e.to_status === typeFilter || e.from_status === typeFilter);

  if (!items.length) {
    container.innerHTML = '<div class="text-center py-12 text-slate-400 text-sm">暂无事件</div>';
    return;
  }

  container.innerHTML = items.map(e => {
    const tgt = State.targets.find(t => t.target?.id === e.target_id);
    const name = tgt?.target?.name || e.target_id;
    const isDown = e.to_status === 'DOWN';
    const bgClass = isDown ? 'border-l-4 border-l-red-400' : (e.to_status === 'UP' ? 'border-l-4 border-l-emerald-400' : '');
    const durationSec = e.duration_ms ? (e.duration_ms / 1000).toFixed(0) : null;
    return `
      <div class="flex items-start gap-4 px-5 py-4 hover:bg-slate-50 transition ${bgClass}">
        <div class="text-xl mt-0.5 flex-shrink-0">${isDown ? '🔴' : (e.to_status === 'UP' ? '🟢' : '🟡')}</div>
        <div class="flex-1 min-w-0">
          <div class="flex flex-wrap items-center gap-2 mb-1">
            <span class="font-medium text-slate-800">${escHtml(name)}</span>
            <span class="text-xs text-slate-500">${e.from_status || '?'} → <strong>${e.to_status}</strong></span>
            ${e.reason ? `<span class="text-xs bg-slate-100 text-slate-500 px-1.5 rounded">${e.reason}</span>` : ''}
          </div>
          ${e.message ? `<div class="text-sm text-slate-600 mb-1">${escHtml(e.message)}</div>` : ''}
          <div class="flex gap-4 text-xs text-slate-400">
            <span>${formatDate(e.timestamp)}</span>
            ${durationSec ? `<span>持续 ${fmtDuration(durationSec)}</span>` : ''}
            ${e.probe_node_id ? `<span>探针: ${e.probe_node_id}</span>` : ''}
          </div>
        </div>
        <div class="flex-shrink-0">
          <span class="text-xs ${STATUS_COLOR[e.to_status]?.text || 'text-slate-500'} ${STATUS_COLOR[e.to_status]?.bg || 'bg-slate-100'} px-2 py-0.5 rounded">
            ${e.to_status}
          </span>
        </div>
      </div>`;
  }).join('');
}

// ── 告警页 ────────────────────────────────────────────────────────────────────
function renderAlerts() {
  const statusFilter = document.getElementById('alert-status-filter')?.value || '';
  const container = document.getElementById('alerts-list');
  if (!container) return;

  let items = State.alerts;
  if (statusFilter) items = items.filter(a => a.status === statusFilter);

  if (!items.length) {
    container.innerHTML = '<div class="text-center py-12 text-slate-400 text-sm">暂无告警</div>';
    return;
  }

  const sevColor = {
    critical: 'bg-red-100 border-red-300 text-red-800',
    error:    'bg-red-50  border-red-200 text-red-700',
    warn:     'bg-amber-50 border-amber-200 text-amber-700',
    info:     'bg-blue-50 border-blue-200 text-blue-700',
  };

  container.innerHTML = items.map(a => {
    const tgt = State.targets.find(t => t.target?.id === a.target_id);
    const name = tgt?.target?.name || a.target_id;
    const cls = sevColor[a.severity] || 'bg-slate-50 border-slate-200 text-slate-700';
    return `
      <div class="bg-white rounded-xl border ${cls.includes('red') ? 'border-red-200' : 'border-slate-200'} p-5 shadow-sm slide-in">
        <div class="flex items-start justify-between gap-4">
          <div class="flex-1">
            <div class="flex items-center gap-2 mb-1">
              <span class="text-sm font-semibold ${cls} px-2 py-0.5 rounded border">${(a.severity || 'info').toUpperCase()}</span>
              <span class="font-medium text-slate-800">${escHtml(a.title)}</span>
            </div>
            <div class="text-sm text-slate-600 mb-2">${escHtml(a.body || '').replace(/\n/g, '<br>')}</div>
            <div class="flex flex-wrap gap-4 text-xs text-slate-400">
              <span>目标: ${escHtml(name)}</span>
              ${a.rule_name ? `<span>规则: ${escHtml(a.rule_name)}</span>` : ''}
              <span>时间: ${timeAgo(a.sent_at)}</span>
              <span>状态: <strong>${a.status}</strong></span>
            </div>
          </div>
          <div class="flex gap-2 flex-shrink-0">
            ${a.status === 'firing' ? `
              <button onclick="ackAlert('${a.id}')"
                class="text-xs px-3 py-1.5 bg-amber-50 border border-amber-300 text-amber-700 rounded-lg hover:bg-amber-100 transition">
                确认 ACK
              </button>` : ''}
          </div>
        </div>
      </div>`;
  }).join('');
}

// ── 探针页 ────────────────────────────────────────────────────────────────────
function renderProbes() {
  const container = document.getElementById('probes-grid');
  if (!container) return;

  if (!State.probes.length) {
    container.innerHTML = '<div class="text-center py-12 text-slate-400 text-sm col-span-full">暂无探针节点</div>';
    return;
  }

  container.innerHTML = State.probes.map(p => {
    const online = p.status === 'online';
    const dot = online ? 'bg-emerald-500' : 'bg-slate-300 pulse';
    const last = p.last_heartbeat ? timeAgo(p.last_heartbeat) : '—';
    return `
      <div class="bg-white rounded-xl border border-slate-200 p-5 shadow-sm hover:shadow-md transition">
        <div class="flex items-start justify-between mb-3">
          <div>
            <div class="flex items-center gap-2">
              <span class="status-dot ${dot}"></span>
              <span class="font-semibold text-slate-800">${escHtml(p.name || p.id)}</span>
            </div>
            <div class="text-xs text-slate-400 mt-1">${escHtml(p.id)}</div>
          </div>
          <span class="text-xs font-medium px-2 py-0.5 rounded ${online ? 'bg-emerald-100 text-emerald-700' : 'bg-slate-100 text-slate-500'}">
            ${p.status}
          </span>
        </div>
        <div class="grid grid-cols-2 gap-3 text-sm">
          <div><span class="text-slate-400 text-xs">地域</span><div class="font-medium">${escHtml(p.location || '—')}</div></div>
          <div><span class="text-slate-400 text-xs">ISP</span><div class="font-medium">${escHtml(p.isp || '—')}</div></div>
          <div><span class="text-slate-400 text-xs">任务数</span><div class="font-medium">${p.assigned_targets ?? 0}</div></div>
          <div><span class="text-slate-400 text-xs">版本</span><div class="font-medium">${escHtml(p.version || '—')}</div></div>
        </div>
        <div class="mt-3 pt-3 border-t border-slate-100 text-xs text-slate-400">
          最后心跳: ${last} · IP: ${escHtml(p.ip_address || '—')}
        </div>
        ${p.tags?.length ? `<div class="flex flex-wrap gap-1 mt-2">${p.tags.map(t => `<span class="bg-blue-50 text-blue-600 text-xs px-1.5 py-0.5 rounded">${escHtml(t)}</span>`).join('')}</div>` : ''}
      </div>`;
  }).join('');
}

// ── 目标详情模态框 ────────────────────────────────────────────────────────────
async function openDetail(targetId) {
  State.currentDetail = targetId;
  const found = State.targets.find(t => t.target?.id === targetId);
  if (!found) return;

  const { target, state } = found;
  document.getElementById('modal-detail').classList.remove('hidden');
  document.getElementById('detail-title').textContent = target.name;
  setText('detail-status', state?.status || 'UNKNOWN');
  setText('detail-latency', state?.avg_latency_ms ? `${state.avg_latency_ms.toFixed(1)}ms` : '—');
  setText('detail-avail', state?.availability_7d ? `${(state.availability_7d * 100).toFixed(2)}%` : '—');
  setText('detail-fails', state?.consecutive_fails ?? 0);

  // 静默按钮文本
  const silenceBtn = document.getElementById('detail-silence-btn');
  silenceBtn.textContent = state?.status === 'SILENT' ? '取消静默' : '静默';

  // 延迟模拟图（真实数据需 /api/v1/targets/:id/latency）
  renderDetailChart(target, state);

  // 目标事件
  try {
    const res = await api('GET', `/targets/${targetId}/events?limit=10`);
    const events = res?.data || [];
    const evtContainer = document.getElementById('detail-events');
    if (!events.length) {
      evtContainer.innerHTML = '<div class="text-slate-400">暂无事件记录</div>';
    } else {
      evtContainer.innerHTML = events.map(e => `
        <div class="flex items-center gap-2 py-1 border-b border-slate-50">
          <span class="${STATUS_COLOR[e.to_status]?.text || 'text-slate-500'}">${e.to_status}</span>
          <span class="text-slate-400">←</span>
          <span class="text-slate-500">${e.from_status}</span>
          <span class="text-slate-300">|</span>
          <span class="text-slate-400">${timeAgo(e.timestamp)}</span>
          ${e.reason ? `<span class="text-slate-400">(${e.reason})</span>` : ''}
        </div>`).join('');
    }
  } catch { }
}

function renderDetailChart(target, state) {
  const canvas = document.getElementById('detail-chart');
  if (!canvas) return;

  if (State.detailChart) {
    State.detailChart.destroy();
    State.detailChart = null;
  }

  // 生成模拟延迟数据（真实场景从 /api/v1/targets/:id/latency 获取）
  const now = Date.now();
  const labels = [];
  const data = [];
  const baseLatency = state?.avg_latency_ms || 50;

  for (let i = 23; i >= 0; i--) {
    const t = new Date(now - i * 3600000);
    labels.push(t.getHours() + ':00');
    const jitter = (Math.random() - 0.5) * baseLatency * 0.4;
    data.push(Math.max(1, baseLatency + jitter));
  }

  State.detailChart = new Chart(canvas, {
    type: 'line',
    data: {
      labels,
      datasets: [{
        label: '延迟 (ms)',
        data,
        borderColor: '#3b82f6',
        backgroundColor: 'rgba(59,130,246,0.08)',
        fill: true,
        tension: 0.4,
        pointRadius: 0,
        borderWidth: 2,
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: { legend: { display: false } },
      scales: {
        x: { grid: { display: false }, ticks: { font: { size: 10 }, maxTicksLimit: 8 } },
        y: { grid: { color: 'rgba(0,0,0,0.05)' }, ticks: { font: { size: 10 } } }
      }
    }
  });
}

// ── 操作：立即探测 ────────────────────────────────────────────────────────────
async function probeNow() {
  if (!State.currentDetail) return;
  try {
    await api('POST', `/targets/${State.currentDetail}/probe`);
    showToast('探测任务已提交', 'success');
  } catch (e) {
    showToast(e.message, 'error');
  }
}

// ── 操作：静默/取消静默 ──────────────────────────────────────────────────────
async function toggleSilence() {
  if (!State.currentDetail) return;
  const found = State.targets.find(t => t.target?.id === State.currentDetail);
  const isSilent = found?.state?.status === 'SILENT';
  try {
    if (isSilent) {
      await api('DELETE', `/targets/${State.currentDetail}/silence`);
      showToast('已取消静默', 'success');
    } else {
      await api('POST', `/targets/${State.currentDetail}/silence`);
      showToast('已静默', 'success');
    }
    await loadTargets();
    renderAll();
  } catch (e) {
    showToast(e.message, 'error');
  }
}

// ── 操作：删除目标 ────────────────────────────────────────────────────────────
async function deleteTarget(id, name) {
  if (!confirm(`确认删除目标「${name}」？此操作不可恢复。`)) return;
  try {
    await api('DELETE', `/targets/${id}`);
    State.targets = State.targets.filter(t => t.target?.id !== id);
    showToast(`已删除：${name}`, 'success');
    renderAll();
  } catch (e) {
    showToast(e.message, 'error');
  }
}

// ── 操作：确认告警 ────────────────────────────────────────────────────────────
async function ackAlert(alertId) {
  try {
    await api('POST', `/alerts/${alertId}/ack`);
    const a = State.alerts.find(x => x.id === alertId);
    if (a) a.status = 'acknowledged';
    showToast('告警已确认', 'success');
    renderAlerts();
    updateAlertBadge();
  } catch (e) {
    showToast(e.message, 'error');
  }
}

// ── 操作：添加目标 ────────────────────────────────────────────────────────────
function openAddTarget() {
  document.getElementById('modal-add').classList.remove('hidden');
  document.getElementById('add-error').classList.add('hidden');
  document.getElementById('add-name').value = '';
  document.getElementById('add-host').value = '';
  document.getElementById('add-port').value = '';
  document.getElementById('add-tags').value = '';
}

async function submitAddTarget() {
  const name  = document.getElementById('add-name').value.trim();
  const host  = document.getElementById('add-host').value.trim();
  const port  = parseInt(document.getElementById('add-port').value) || 0;
  const proto = document.getElementById('add-proto').value;
  const interval = parseInt(document.getElementById('add-interval').value);
  const tagsRaw = document.getElementById('add-tags').value;
  const tags = tagsRaw ? tagsRaw.split(',').map(t => t.trim()).filter(Boolean) : [];
  const errEl = document.getElementById('add-error');

  if (!name || !host) {
    errEl.textContent = '名称和主机不能为空';
    errEl.classList.remove('hidden');
    return;
  }

  try {
    errEl.classList.add('hidden');
    const newTarget = await api('POST', '/targets', {
      name, host, port, protocol: proto, interval_sec: interval, tags,
    });
    closeModal('modal-add');
    await loadTargets();
    renderAll();
    showToast(`已添加：${name}`, 'success');
  } catch (e) {
    errEl.textContent = e.message;
    errEl.classList.remove('hidden');
  }
}

// ── 辅助：页面切换 ────────────────────────────────────────────────────────────
function showPage(name) {
  document.querySelectorAll('.page').forEach(p => p.classList.add('hidden'));
  document.getElementById('page-' + name)?.classList.remove('hidden');
  document.querySelectorAll('.nav-btn').forEach(btn => {
    const active = btn.dataset.page === name;
    btn.classList.toggle('bg-blue-50', active);
    btn.classList.toggle('text-blue-700', active);
    btn.classList.toggle('font-semibold', active);
    btn.classList.toggle('text-slate-600', !active);
  });
  State.currentPage = name;
  State.filterStatus = '';
  renderAll();

  // 页面专属数据刷新
  if (name === 'events') loadEvents().then(() => renderEvents());
  if (name === 'alerts') loadAlerts().then(() => renderAlerts());
  if (name === 'probes') loadProbes().then(() => renderProbes());
}

function filterTargets(status) {
  State.filterStatus = State.filterStatus === status ? '' : status;
  showPage('targets');
  const el = document.getElementById('tgt-status-filter');
  if (el) el.value = State.filterStatus;
}

function closeModal(id) {
  document.getElementById(id).classList.add('hidden');
}

// ── 辅助：Alert 徽标 ─────────────────────────────────────────────────────────
function updateAlertBadge() {
  const firing = State.alerts.filter(a => a.status === 'firing').length;
  const badge = document.getElementById('alert-badge');
  if (!badge) return;
  if (firing > 0) {
    badge.textContent = firing;
    badge.classList.remove('hidden');
  } else {
    badge.classList.add('hidden');
  }
}

// ── Toast 通知 ────────────────────────────────────────────────────────────────
let toastTimer;
function showToast(msg, type = 'info') {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = `fixed bottom-5 right-5 z-50 text-white text-sm px-4 py-3 rounded-xl shadow-lg slide-in ${type === 'error' ? 'bg-red-600' : 'bg-slate-800'}`;
  el.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), 3000);
}

// ── 工具函数 ──────────────────────────────────────────────────────────────────
function setText(id, val) {
  const el = document.getElementById(id);
  if (el) el.textContent = val ?? '—';
}

function escHtml(str) {
  if (!str) return '';
  return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function timeAgo(isoString) {
  if (!isoString) return '';
  const diffSec = Math.floor((Date.now() - new Date(isoString).getTime()) / 1000);
  if (diffSec < 60) return `${diffSec}秒前`;
  if (diffSec < 3600) return `${Math.floor(diffSec/60)}分钟前`;
  if (diffSec < 86400) return `${Math.floor(diffSec/3600)}小时前`;
  return `${Math.floor(diffSec/86400)}天前`;
}

function formatDate(isoString) {
  if (!isoString) return '—';
  const d = new Date(isoString);
  return `${d.getMonth()+1}/${d.getDate()} ${d.getHours()}:${String(d.getMinutes()).padStart(2,'0')}`;
}

function fmtDuration(sec) {
  if (sec < 60) return `${sec}秒`;
  if (sec < 3600) return `${Math.floor(sec/60)}分钟`;
  return `${Math.floor(sec/3600)}小时${Math.floor((sec%3600)/60)}分钟`;
}

// ── 键盘事件：ESC 关闭模态框 ─────────────────────────────────────────────────
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') {
    ['modal-add', 'modal-detail'].forEach(id => {
      document.getElementById(id)?.classList.add('hidden');
    });
  }
});

// 点击遮罩层关闭
['modal-add', 'modal-detail'].forEach(id => {
  document.getElementById(id)?.addEventListener('click', e => {
    if (e.target.id === id) closeModal(id);
  });
});

// ── 初始化 ────────────────────────────────────────────────────────────────────
async function init() {
  showPage('dashboard');
  await loadAll();

  // 尝试 WebSocket 连接（降级到轮询）
  try {
    connectWS();
  } catch { }

  // 30 秒轮询刷新（作为 WS 的备份）
  State.refreshTimer = setInterval(loadAll, 30000);
}

init();
