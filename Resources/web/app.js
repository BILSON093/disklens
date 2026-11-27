/* ============ 状态 ============ */
const S = {
  mode: 'explorer',
  rootPath: null, rootName: '',
  currentPath: null, stack: [],
  childrenCache: {}, items: [],
  node: null,
  junk: [], junkSel: new Set(), junkFilter: null,
  dups: [], dupSel: new Set(), dupKeep: {}, dupFocus: null,
  thumbs: {}, thumbPending: {},
  kinds: [], appStats: [], kindMode: 'kinds',
  large: [], largeSel: new Set(), largeMin: 524288000,
  apps: [], appSel: new Set(), appFocus: null, appQuery: '', appIcons: {},
  dupMode: 'exact',
  minSize: 1048576,
  sort: {
    app: { key: 'size', dir: -1 },
    junk: { key: 'size', dir: -1 },
    dup: { key: 'reclaim', dir: -1 },
    large: { key: 'size', dir: -1 }
  },
  appsSorted: false,
  deniedSamples: [],
  scanning: false, lastScan: null
};

const KIND_COLORS = {
  '视频': '#7262fd', '图片': '#f6bd16', '音频': '#f08bb4', '代码': '#5b8ff9',
  '压缩包': '#f6903d', '文档': '#61ddaa', '应用': '#008685', '数据': '#9661bc', '其他': '#9aa2b1'
};

/* ============ 通信 ============ */
function call(action, payload = {}) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native;
  if (h) h.postMessage(Object.assign({ action }, payload));
  else console.log('[mock]', action, payload);
}
window.native = { on: handleEvent };
window.onerror = function (m, s, l, c, err) {
  call('log', { message: m + ' @' + l + ' ' + (err && err.stack ? err.stack : '') });
  return false;
};

/* ============ 工具 ============ */
function fmtSize(b) {
  if (!b || b < 0) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = b, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return i === 0 ? Math.round(v) + ' B' : (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + ' ' + u[i];
}
function fmtDelta(b) {
  if (!b) return '持平';
  return (b > 0 ? '+' : '−') + fmtSize(Math.abs(b));
}
function fmtDate(iso) { return iso ? String(iso).slice(0, 10) : '—'; }
function fmtCount(n) { return (n ?? 0).toLocaleString('zh-CN'); }
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function shorten(p, max = 80) {
  p = String(p || '');
  return p.length > max ? '…' + p.slice(p.length - max + 1) : p;
}
function $(id) { return document.getElementById(id); }
function toast(m) {
  const el = $('toast');
  el.textContent = m; el.classList.add('show');
  clearTimeout(el._t);
  el._t = setTimeout(() => el.classList.remove('show'), 2800);
}
function colorOf(o) { return o.color || KIND_COLORS[o.kind] || '#9aa2b1'; }

/* ============ 事件 ============ */
function handleEvent(e) {
  switch (e.type) {
    case 'progress':
      $('status').textContent = `${fmtCount(e.files)} 个文件 · ${(e.path || '').split('/').pop() || ''}`;
      break;

    case 'scanStarted':
      S.scanning = true;
      $('btnScan').textContent = '扫描中…';
      $('btnScan').disabled = true;
      $('status').textContent = '正在遍历目录…';
      $('pageSub').textContent = '扫描中，请稍候…';
      $('permBar').hidden = true;
      break;

    case 'scanDone': {
      S.scanning = false;
      S.rootPath = e.rootPath;
      S.rootName = e.rootName;
      S.currentPath = e.rootPath;
      S.stack = [{ name: e.rootName, path: e.rootPath }];
      S.lastScan = e;
      S.childrenCache = {};
      $('btnScan').textContent = '重新扫描';
      $('btnScan').disabled = false;
      $('targetPath').textContent = e.rootPath === '/' ? '整块磁盘 (/)' : shorten(e.rootPath, 42);
      $('status').textContent = `${fmtCount(e.fileCount)} 个文件 · ${fmtCount(e.dirCount)} 个目录 · ${e.duration.toFixed(1)} 秒`;
      $('explorerEmpty').style.display = 'none';

      let sub = `${fmtSize(e.totalSize)} · ${fmtCount(e.fileCount)} 个文件`;
      if (e.rootPath === '/') sub += ' · 不含系统卷与快照';

      if (e.fromCache && e.scannedAt) {
        S.cached = true;
        const d = new Date(e.scannedAt);
        const label = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')} ` +
                      `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
        sub += ` · 扫描于 ${label}`;
        $('status').textContent = `上次扫描 ${label} · 点「重新扫描」更新数据`;
      } else {
        S.cached = false;
      }
      if (e.prevTotal > 0) {
        sub += ` · 较上次 ${fmtDelta(e.totalSize - e.prevTotal)}`;
      }
      $('pageSub').textContent = sub;

      S.deniedSamples = e.deniedSamples || [];
      if (e.deniedCount > 0) {
        const ok = !!e.hasFDA;
        $('permBar').hidden = false;
        $('permBar').classList.toggle('ok', ok);
        $('permText').textContent = ok
          ? `有 ${fmtCount(e.deniedCount)} 个系统级目录受保护（如 /private/var/db），属正常现象`
          : `有 ${fmtCount(e.deniedCount)} 个目录无法读取 · 完全磁盘访问尚未生效`;
        $('permOpen').hidden = ok;
        $('permDetail').hidden = S.deniedSamples.length === 0;
        $('permBox').hidden = true;
        $('permBox').dataset.fda = ok ? '1' : '0';
      } else {
        $('permBar').hidden = true;
        $('permBox').hidden = true;
      }

      $('junkBadge').textContent = e.junkCount || '';
      call('children', { path: e.rootPath });
      call('aggregates');
      break;
    }

    case 'children':
      S.childrenCache[e.path] = e;
      if (e.path === S.currentPath) {
        S.node = e;
        S.items = [];
        renderCrumbs();
        drawTreemap();
        renderChildList();
      }
      break;

    case 'junk':
      S.junk = e.items || [];
      S.junkTotal = e.totalSize || 0;
      S.junkTotalCount = e.total || 0;
      if (S.junkSel.size === 0) {
        S.junk.forEach(j => { if (j.risk === '安全') S.junkSel.add(j.path); });
      }
      if (S.mode === 'junk') {
        $('pageSub').textContent = `共 ${S.junkTotalCount} 项 · 预计可释放 ${fmtSize(S.junkTotal)}`;
      }
      renderJunk();
      break;

    case 'aggregates':
      S.kinds = e.kinds || [];
      S.appStats = e.apps || [];
      if (S.mode === 'kinds') renderKinds();
      break;

    case 'largeFiles':
      S.large = e.items || [];
      S.largeCount = e.count || 0;
      S.largeTotal = e.totalSize || 0;
      S.largeSel = new Set();
      $('largeBadge').textContent = e.count || '';
      if (S.mode === 'large') {
        $('pageSub').textContent = `${fmtCount(e.count)} 个文件 · 合计 ${fmtSize(e.totalSize)}`;
        renderLarge();
      }
      break;

    case 'appsStarted':
      $('appsSummary').textContent = '正在分析已安装应用…';
      break;

    case 'appProgress':
      $('appsSummary').textContent = e.message;
      break;

    case 'appsDone':
      S.apps = e.apps || [];
      S.appsSorted = false;
      S.appFocus = null;
      S.appSel = new Set();
      $('appBadge').textContent = e.count || '';
      $('appsSummary').textContent =
        `${e.count} 个应用 · 正在统计体积 · 残留 ${fmtSize(e.leftoverSize)}`;
      if (S.mode === 'uninstall') {
        $('pageSub').textContent = `${e.count} 个应用 · 正在统计体积`;
        renderApps(); renderAppPreview();
      }
      break;

    case 'appDetail': {
      const a = S.apps.find(x => x.path === e.path);
      if (a) {
        a.size = e.size;
        a.leftoverSize = e.leftoverSize;
        const map = new Map((e.leftovers || []).map(o => [o.path, o.size]));
        (a.leftovers || []).forEach(l => { if (map.has(l.path)) l.size = map.get(l.path); });

        if (S.mode === 'uninstall') {
          const row = document.querySelector(`#appList .approw[data-path="${CSS.escape(e.path)}"]`);
          if (row) {
            row.querySelector('.asz').textContent = fmtSize(e.size);
            const lo = row.querySelector('.loBadge');
            if (lo && a.leftovers.length) lo.textContent = `残留 ${a.leftovers.length}`;
          }
          if (S.appFocus && S.appFocus.path === e.path) renderAppPreview();
          // 边算边排：节流重绘，避免每来一个就重排一次
          const now = Date.now();
          if (e.done >= e.total) {
            S.appsSorted = true;
            renderApps();
          } else if (!S.appsSorted && now - (S.appLastRender || 0) > 350) {
            S.appLastRender = now;
            renderApps();
          }
          const appTotal = S.apps.reduce((s2, x) => s2 + (x.size || 0), 0);
          const loTotal = S.apps.reduce((s2, x) => s2 + (x.leftoverSize || 0), 0);
          $('appsSummary').textContent =
            `${S.apps.length} 个应用 · 占用 ${fmtSize(appTotal)} · 残留 ${fmtSize(loTotal)}` +
            (e.done < e.total ? ` · 分析中 ${e.done}/${e.total}` : '');
        }
      }
      break;
    }

    case 'similarStarted':
      $('dupProgress').hidden = false;
      $('dupBar').style.width = '0%';
      $('dupProgressText').textContent = '正在分析图片…';
      $('dupScan').disabled = true;
      break;

    case 'similarProgress':
      $('dupBar').style.width = Math.round(e.value * 100) + '%';
      $('dupProgressText').textContent = e.message;
      break;

    case 'similarDone':
      $('dupProgress').hidden = true;
      $('dupScan').disabled = false;
      applyDupGroups(e.groups, true);
      $('dupBadge').textContent = e.count || '';
      $('pageSub').textContent = e.count
        ? `${e.count} 组相似照片 · 可回收 ${fmtSize(e.reclaimable)}`
        : '没有发现相似照片';
      renderDups(e);
      break;

    case 'dupStarted':
      $('dupProgress').hidden = false;
      $('dupBar').style.width = '0%';
      $('dupProgressText').textContent = '准备中…';
      $('dupScan').disabled = true;
      break;

    case 'dupProgress':
      $('dupBar').style.width = Math.round(e.value * 100) + '%';
      $('dupProgressText').textContent = e.message;
      break;

    case 'dupDone': {
      $('dupProgress').hidden = true;
      $('dupScan').disabled = false;
      applyDupGroups(e.groups, false);
      $('dupBadge').textContent = e.count || '';
      $('pageSub').textContent = e.count
        ? `${e.count} 组 · 可回收 ${fmtSize(e.reclaimable)}`
        : '没有发现重复文件';
      renderDups(e);
      break;
    }

    case 'trashDone': {
      const done = new Set(e.paths || []);
      S.junk = S.junk.filter(j => !done.has(j.path));
      S.dups.forEach(g => { g.files = g.files.filter(f => !done.has(f.path)); });
      S.dups = S.dups.filter(g => g.files.length > 1);
      S.large = S.large.filter(f => !done.has(f.path));
      S.junkSel.clear();
      S.dupSel.clear();
      S.largeSel.clear();

      if (S.lastScan && e.newTotal) {
        S.lastScan.totalSize = e.newTotal;
      }
      S.childrenCache = {};
      if (S.currentPath) call('children', { path: S.currentPath });
      if (S.mode === 'kinds') call('aggregates');

      if (S.appFocus && done.has(S.appFocus.path)) {
        S.apps = S.apps.filter(x => x.path !== S.appFocus.path);
        S.appFocus = null;
        S.appSel = new Set();
        $('appBadge').textContent = S.apps.length || '';
        renderApps(); renderAppPreview();
      }
      renderJunk(); renderLarge(); renderDups(null);
      let msg = `已移到废纸篓 ${e.ok} 项，释放 ${fmtSize(e.freed)}`;
      if (e.blocked && e.blocked.length) msg += ` · ${e.blocked.length} 项被保护规则拦截`;
      if (e.failed && e.failed.length) msg += ` · ${e.failed.length} 项失败`;
      toast(msg);
      break;
    }

    case 'needRescan':
      toast(e.reason || '请先重新扫描');
      $('dupProgress').hidden = true;
      $('dupScan').disabled = false;
      $('dupList').innerHTML = `<div class="empty-note">${esc(e.reason || '需要重新扫描')}<br>顶部点「重新扫描」即可。</div>`;
      break;

    case 'thumbnail':
      applyThumb(e.path, e.data || '');
      break;

    case 'appIcon':
      S.appIcons[e.path] = e.data || '';
      document.querySelectorAll(`img.aicon[data-icon-path="${CSS.escape(e.path)}"]`).forEach(img => {
        img.src = e.data || '';
      });
      break;

    case 'folderChosen':
      $('targetPath').textContent = shorten(e.path, 42);
      call('scan', { path: e.path });
      break;

    case 'diskInfo':
      renderDisk(e);
      break;

    case 'exported':
      toast('已导出到 ' + shorten(e.path, 48));
      break;

    case 'exportFailed':
      toast('导出失败：' + e.message);
      break;

    case 'trashCancelled':
      break;
  }
}

function renderDisk(e) {
  const used = (e.total - e.free) / Math.max(e.total, 1);
  $('diskFree').textContent = fmtSize(e.free);
  $('diskFree').style.color = e.free < 20e9 ? 'var(--red)' : 'var(--text)';
  const bar = $('diskBar');
  bar.style.width = (used * 100).toFixed(1) + '%';
  bar.className = used > 0.9 ? 'hot' : (used > 0.8 ? 'warn' : '');
  $('diskSub').textContent = `共 ${fmtSize(e.total)} · 已用 ${Math.round(used * 100)}%`;
}

/* ============ 排序 ============ */
function cmpNum(a, b) { return a > b ? 1 : (a < b ? -1 : 0); }
function cmpStr(a, b) { return String(a).localeCompare(String(b), 'zh-CN'); }

function sortJunk(list) {
  const { key, dir } = S.sort.junk;
  const arr = list.slice();
  arr.sort((a, b) => {
    let r = 0;
    if (key === 'size') r = cmpNum(a.size, b.size);
    else if (key === 'name') r = cmpStr(a.name, b.name);
    else if (key === 'category') r = cmpStr(a.category, b.category) || cmpNum(b.size, a.size);
    else if (key === 'risk') r = cmpStr(a.risk, b.risk) || cmpNum(b.size, a.size);
    return r * dir;
  });
  return arr;
}

function sortDups(groups) {
  const { key, dir } = S.sort.dup;
  const arr = groups.slice();
  arr.sort((a, b) => {
    let r = 0;
    if (key === 'reclaim') r = cmpNum(a.reclaimable || 0, b.reclaimable || 0);
    else if (key === 'size') r = cmpNum(a.size, b.size);
    else if (key === 'count') r = cmpNum(a.files.length, b.files.length);
    else if (key === 'name') r = cmpStr(a.files[0] ? a.files[0].name : '', b.files[0] ? b.files[0].name : '');
    return r * dir;
  });
  return arr;
}

function sortLarge(list) {
  const { key, dir } = S.sort.large;
  const arr = list.slice();
  arr.sort((a, b) => {
    let r = 0;
    if (key === 'size') r = cmpNum(a.size, b.size);
    else if (key === 'name') r = cmpStr(a.name, b.name);
    else if (key === 'idle') r = cmpNum(a.idleDays ?? -1, b.idleDays ?? -1);
    else if (key === 'kind') r = cmpStr(a.kind || '', b.kind || '') || cmpNum(b.size, a.size);
    return r * dir;
  });
  return arr;
}

function sortApps(list) {
  const { key, dir } = S.sort.app;
  const arr = list.slice();
  arr.sort((a, b) => {
    // 体积未算出的先沉底，保证已算出的部分始终有序
    const az = (a.size || 0) > 0, bz = (b.size || 0) > 0;
    if (az !== bz) return az ? -1 : 1;
    let r = 0;
    if (key === 'size') r = cmpNum(a.size || 0, b.size || 0);
    else if (key === 'used') r = cmpStr(a.lastUsed || '', b.lastUsed || '');
    else if (key === 'installed') r = cmpStr(a.installed || '', b.installed || '');
    else if (key === 'name') r = cmpStr(a.name, b.name);
    return r * dir;
  });
  return arr;
}

/* ============ 树图 ============ */
function squarify(nodes, W, H) {
  if (!nodes.length || W <= 1 || H <= 1) return [];
  const total = nodes.reduce((s, n) => s + n.size, 0);
  if (total <= 0) return [];

  let items = nodes.filter(n => n.size > total * 0.0012);
  if (!items.length) items = nodes.slice();
  items = items.slice().sort((a, b) => b.size - a.size);

  const area = W * H;
  const sum = items.reduce((s, n) => s + n.size, 0);
  let scaled = items.map(n => ({ node: n, area: n.size / sum * area }));

  const out = [];
  let free = { x: 0, y: 0, w: W, h: H };
  const worst = (row, side) => {
    const s = row.reduce((a, b) => a + b, 0);
    if (s <= 0 || side <= 0) return Infinity;
    const mx = Math.max(...row), mn = Math.min(...row);
    if (mn <= 0) return Infinity;
    return Math.max(side * side * mx / (s * s), (s * s) / (side * side * mn));
  };

  while (scaled.length && free.w > 0.5 && free.h > 0.5) {
    const side = Math.min(free.w, free.h);
    let row = [scaled[0]], idx = 1;
    let cur = worst(row.map(r => r.area), side);
    while (idx < scaled.length) {
      const cand = row.concat([scaled[idx]]);
      const cw = worst(cand.map(r => r.area), side);
      if (cw <= cur) { row = cand; cur = cw; idx++; } else break;
    }
    const rowArea = row.reduce((a, b) => a + b.area, 0);
    if (free.w >= free.h) {
      const w = rowArea / free.h;
      let y = free.y;
      for (const it of row) {
        const h = it.area / w;
        out.push({ node: it.node, x: free.x, y, w, h });
        y += h;
      }
      free = { x: free.x + w, y: free.y, w: free.w - w, h: free.h };
    } else {
      const h = rowArea / free.w;
      let x = free.x;
      for (const it of row) {
        const w = it.area / h;
        out.push({ node: it.node, x, y: free.y, w, h });
        x += w;
      }
      free = { x: free.x, y: free.y + h, w: free.w, h: free.h - h };
    }
    scaled = scaled.slice(row.length);
  }
  return out;
}

function textOn(hex) {
  const r = parseInt(hex.slice(1, 3), 16), g = parseInt(hex.slice(3, 5), 16), b = parseInt(hex.slice(5, 7), 16);
  const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return lum > 0.66 ? 'rgba(22,26,34,.94)' : 'rgba(255,255,255,.98)';
}

const canvas = $('treemap');
const ctx = canvas.getContext('2d');
let hoverItem = null;

// 缩放动画：滚轮进入下一级时，从点击的方块扩散到全屏
let zoomAnim = null;
let rafId = 0;

function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
function lerp(a, b, t) { return a + (b - a) * t; }

function startZoomIn(originRect) {
  zoomAnim = { origin: originRect, start: performance.now(), dur: 260, mode: 'in' };
  if (!rafId) rafId = requestAnimationFrame(tickZoom);
}

function tickZoom() {
  rafId = 0;
  const done = !zoomAnim || zoomAnim.mode !== 'in'
    || performance.now() - zoomAnim.start >= zoomAnim.dur;
  drawTreemap();
  if (!done) rafId = requestAnimationFrame(tickZoom);
  else zoomAnim = null;
}

function drawTreemap() {
  const wrap = $('treemapWrap');
  const rect = wrap.getBoundingClientRect();
  const W = Math.max(10, rect.width - 24);
  const H = Math.max(10, rect.height - 20);
  const dpr = window.devicePixelRatio || 1;

  canvas.width = W * dpr; canvas.height = H * dpr;
  canvas.style.width = W + 'px'; canvas.style.height = H + 'px';
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);

  const node = S.node;
  if (!node || !node.items || !node.items.length) { S.items = []; return; }

  const items = squarify(node.items, W, H);
  S.items = items;

  // 动画进度（0→1），期间把每块从 origin 矩形插值到目标位置
  let t = 1, origin = null;
  if (zoomAnim && zoomAnim.mode === 'in') {
    t = Math.min(1, (performance.now() - zoomAnim.start) / zoomAnim.dur);
    origin = zoomAnim.origin;
    t = easeOutCubic(t);
  }

  for (const it of items) {
    let x = it.x, y = it.y, w = it.w, h = it.h;
    if (origin && t < 1) {
      x = lerp(origin.x, x, t);
      y = lerp(origin.y, y, t);
      w = lerp(Math.max(origin.w, 2), w, t);
      h = lerp(Math.max(origin.h, 2), h, t);
    }

    const base = colorOf(it.node);
    const isHover = hoverItem && hoverItem.node.path === it.node.path;
    const fade = origin && t < 1 ? (0.25 + 0.75 * t) : 1;
    ctx.globalAlpha = (isHover ? 1 : (it.node.isDir ? 0.82 : 0.6)) * fade;
    ctx.fillStyle = base;
    roundRect(ctx, x, y, w - 1.5, h - 1.5, Math.min(4, Math.min(w, h) / 5));
    ctx.fill();

    if (isHover) {
      ctx.globalAlpha = fade; ctx.strokeStyle = 'rgba(255,255,255,.95)'; ctx.lineWidth = 1.8; ctx.stroke();
    } else {
      ctx.globalAlpha = 0.45 * fade; ctx.strokeStyle = 'rgba(255,255,255,.6)'; ctx.lineWidth = 0.8; ctx.stroke();
    }

    if (w > 76 && h > 30 && (!origin || t > 0.55)) {
      const labelAlpha = origin ? Math.max(0, (t - 0.55) / 0.45) : 1;
      ctx.globalAlpha = labelAlpha;
      ctx.fillStyle = textOn(base);
      ctx.font = '600 10.5px -apple-system, "PingFang SC", sans-serif';
      ctx.fillText(fitText(ctx, it.node.name, w - 12), x + 6, y + 15);
      ctx.globalAlpha = 0.78 * labelAlpha;
      ctx.font = '500 9.5px -apple-system, "PingFang SC", sans-serif';
      ctx.fillText(fmtSize(it.node.size), x + 6, y + 27);
    }
  }
  ctx.globalAlpha = 1;
}

function roundRect(c, x, y, w, h, r) {
  r = Math.max(0, Math.min(r, w / 2, h / 2));
  c.beginPath();
  c.moveTo(x + r, y);
  c.arcTo(x + w, y, x + w, y + h, r);
  c.arcTo(x + w, y + h, x, y + h, r);
  c.arcTo(x, y + h, x, y, r);
  c.arcTo(x, y, x + w, y, r);
  c.closePath();
}
function fitText(c, text, maxW) {
  if (c.measureText(text).width <= maxW) return text;
  let t = text;
  while (t.length > 1 && c.measureText(t + '…').width > maxW) t = t.slice(0, -1);
  return t + '…';
}
function hitTest(x, y) {
  let best = null, area = Infinity;
  for (const it of S.items) {
    if (x >= it.x && x <= it.x + it.w && y >= it.y && y <= it.y + it.h) {
      const a = it.w * it.h;
      if (a < area) { area = a; best = it; }
    }
  }
  return best;
}

canvas.addEventListener('mousemove', ev => {
  const r = canvas.getBoundingClientRect();
  const x = ev.clientX - r.left, y = ev.clientY - r.top;
  const hit = hitTest(x, y);
  const tip = $('tooltip');
  if (!hit) {
    hoverItem = null; tip.classList.remove('show'); drawTreemap(); return;
  }
  if (!hoverItem || hoverItem.node.path !== hit.node.path) { hoverItem = hit; drawTreemap(); }
  tip.innerHTML = `
    <div class="tt-name">${esc(hit.node.name)}</div>
    <div class="tt-size">${fmtSize(hit.node.size)}${hit.node.isDir ? ' · 文件夹' : ''}
      <span class="tt-kind" style="background:${colorOf(hit.node)}22;color:${colorOf(hit.node)}">${esc(hit.node.kind || '')}</span></div>
    <div class="tt-path">${esc(shorten(hit.node.path, 110))}</div>`;
  const wrapR = $('treemapWrap').getBoundingClientRect();
  let tx = x + 18, ty = y + 18;
  if (tx + 340 > wrapR.width) tx = Math.max(6, x - 350);
  if (ty + 84 > wrapR.height) ty = Math.max(6, y - 90);
  tip.style.left = (tx + 12) + 'px';
  tip.style.top = (ty + 10) + 'px';
  tip.classList.add('show');
});
canvas.addEventListener('mouseleave', () => {
  hoverItem = null; $('tooltip').classList.remove('show'); drawTreemap();
});
canvas.addEventListener('wheel', ev => {
  const r = canvas.getBoundingClientRect();
  const x = ev.clientX - r.left, y = ev.clientY - r.top;
  const hit = hitTest(x, y);
  ev.preventDefault();

  // 向上滚：进入鼠标所指的方块；向下滚：退回上一级
  if (ev.deltaY < 0) {
    if (hit && hit.node.isDir && hit.node.path !== S.currentPath) {
      startZoomIn({ x: hit.x, y: hit.y, w: hit.w, h: hit.h });
      drillInto(hit.node.path, hit.node.name);
    }
  } else if (ev.deltaY > 0) {
    if (S.stack.length > 1) {
      S.stack.pop();
      S.currentPath = S.stack[S.stack.length - 1].path;
      hoverItem = null;
      $('tooltip').classList.remove('show');
      requestChildren(S.currentPath);
    }
  }
}, { passive: false });

canvas.addEventListener('click', ev => {
  const r = canvas.getBoundingClientRect();
  const hit = hitTest(ev.clientX - r.left, ev.clientY - r.top);
  if (!hit) return;
  if (hit.node.isDir) drillInto(hit.node.path, hit.node.name);
  else call('reveal', { path: hit.node.path });
});
new ResizeObserver(() => drawTreemap()).observe($('treemapWrap'));

/* ============ 面包屑 ============ */
function renderCrumbs() {
  const el = $('crumbs');
  const stack = S.stack.length ? S.stack : [{ name: S.rootName, path: S.rootPath }];
  let html = '';
  stack.forEach((c, i) => {
    if (i > 0) html += `<span class="crumb-sep">›</span>`;
    html += `<span class="crumb${i === stack.length - 1 ? ' current' : ''}" data-i="${i}">${esc(c.name)}</span>`;
  });
  if (stack.length > 1) html += `<button class="crumb-up" id="crumbUp">↑ 上一级</button>`;
  el.innerHTML = html;
  el.querySelectorAll('.crumb').forEach(node => {
    node.addEventListener('click', () => {
      const i = Number(node.dataset.i);
      if (i < stack.length - 1) {
        S.stack = stack.slice(0, i + 1);
        S.currentPath = S.stack[S.stack.length - 1].path;
        hoverItem = null;
        requestChildren(S.currentPath);
      }
    });
  });
  const up = $('crumbUp');
  if (up) up.addEventListener('click', () => {
    if (S.stack.length > 1) {
      S.stack.pop();
      S.currentPath = S.stack[S.stack.length - 1].path;
      hoverItem = null;
      requestChildren(S.currentPath);
    }
  });
}

function drillInto(path, name) {
  if (!path) return;
  S.stack.push({ name, path });
  S.currentPath = path;
  hoverItem = null;
  $('tooltip').classList.remove('show');
  requestChildren(path);
}
function requestChildren(path) {
  if (S.childrenCache[path]) {
    S.node = S.childrenCache[path];
    renderCrumbs(); drawTreemap(); renderChildList();
  } else {
    call('children', { path });
    renderCrumbs();
  }
}

/* ============ 目录列表 ============ */
function renderChildList() {
  const node = S.node;
  const box = $('childList');
  if (!node || !node.items) { box.innerHTML = ''; $('childCount').textContent = ''; return; }
  const total = Math.max(node.size || 1, 1);
  $('childCount').textContent = `${node.total ?? node.items.length} 项`;

  if (!node.items.length && node.size > 0) {
    box.innerHTML = `<div class="empty-note">这一层没有缓存明细（扫描结果只保存到第 5 层）。<br>点顶部「重新扫描」查看该目录的完整内容。</div>`;
    return;
  }

  box.innerHTML = node.items.map(it => {
    const pct = it.size / total * 100;
    return `<div class="row" data-path="${esc(it.path)}" data-dir="${it.isDir ? 1 : 0}" data-name="${esc(it.name)}">
      <span class="dot" style="background:${colorOf(it)}"></span>
      <span class="nm" title="${esc(it.path)}">${esc(it.name)}</span>
      <span class="kindtag" style="color:${colorOf(it)}">${esc(it.kind || '')}</span>
      <span class="meter"><i style="width:${Math.max(1.5, pct).toFixed(1)}%;background:${colorOf(it)}"></i></span>
      <span class="sz">${fmtSize(it.size)}</span>
      <span class="pct">${pct < 0.05 ? '<0.1' : pct.toFixed(1)}%</span>
      <span class="dt">${fmtDate(it.modified)}</span>
    </div>`;
  }).join('');

  box.querySelectorAll('.row').forEach(r => {
    r.addEventListener('click', () => {
      if (r.dataset.dir === '1') drillInto(r.dataset.path, r.dataset.name);
      else call('reveal', { path: r.dataset.path });
    });
  });
}

/* ============ 类型分析 ============ */
function renderKinds() {
  if (S.mode !== 'kinds') return;
  const useKinds = S.kindMode === 'kinds';
  const rows = useKinds
    ? S.kinds.map(k => ({ name: k.kind, size: k.size, count: k.count, color: k.color, sub: `${fmtCount(k.count)} 个文件` }))
    : S.appStats.map(a => ({ name: a.name, size: a.size, count: a.count, color: a.color, sub: `${fmtCount(a.count)} 个文件` }));

  const total = Math.max(S.lastScan ? S.lastScan.totalSize : rows.reduce((s, r) => s + r.size, 0), 1);
  $('kindsSummary').textContent = useKinds
    ? `${rows.length} 种类型 · 共 ${fmtSize(total)}`
    : `前 ${rows.length} 个应用 · 共 ${fmtSize(total)}`;

  const box = $('kindList');
  if (!rows.length) {
    box.innerHTML = `<div class="empty-note">先扫描一个目录，再来看类型分布。</div>`;
    return;
  }

  const maxSize = Math.max(...rows.map(r => r.size), 1);
  box.innerHTML = rows.map(r => {
    const pct = r.size / total * 100;
    const barW = r.size / maxSize * 100;
    return `<div class="krow">
      <span class="kw" style="background:${r.color}"></span>
      <div class="kinfo">
        <div class="kname">${esc(r.name)}<span class="ksub">${esc(r.sub)}</span></div>
        <div class="kbar"><i style="width:${barW.toFixed(1)}%;background:${r.color}"></i></div>
      </div>
      <span class="ksize">${fmtSize(r.size)}</span>
      <span class="kpct">${pct < 0.1 ? '<0.1' : pct.toFixed(1)}%</span>
    </div>`;
  }).join('');
}

/* ============ 大文件 ============ */
function renderLarge() {
  if (S.mode !== 'large') return;
  const box = $('largeTable');

  if (!S.large.length) {
    box.innerHTML = `<div class="empty-note">这个体积阈值下没有文件。试试调小一些。</div>`;
    updateLargeSel();
    return;
  }

  box.innerHTML = sortLarge(S.large).map(f => {
    const on = S.largeSel.has(f.path);
    const cold = (f.idleDays ?? 0) >= 180;
    const idle = f.idleDays != null
      ? (f.idleDays > 730 ? '2 年未用' : f.idleDays > 365 ? '1 年未用' : `${f.idleDays} 天未用`)
      : '';
    return `<div class="trow large${on ? ' on' : ''}" data-path="${esc(f.path)}">
      <div class="cb${on ? ' on' : ''}"></div>
      <span class="dot" style="background:${colorOf(f)}"></span>
      <div class="info">
        <div class="nm">${esc(f.name)}${cold ? '<span class="tag cold">冷数据</span>' : ''}</div>
        <div class="pth" title="${esc(f.path)}">${esc(shorten(f.path, 92))}</div>
      </div>
      <span class="kt2" style="color:${colorOf(f)}">${esc(f.kind || '')}</span>
      <span class="idt">${idle}</span>
      <div class="sz">${fmtSize(f.size)}</div>
      <button class="mag" title="在访达中显示"><svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg></button>
    </div>`;
  }).join('');

  box.querySelectorAll('.trow').forEach(row => {
    const p = row.dataset.path;
    row.addEventListener('click', ev => {
      if (ev.target.closest('.mag')) { call('reveal', { path: p }); return; }
      if (S.largeSel.has(p)) S.largeSel.delete(p); else S.largeSel.add(p);
      row.classList.toggle('on');
      row.querySelector('.cb').classList.toggle('on');
      updateLargeSel();
    });
  });
  updateLargeSel();
}

function updateLargeSel() {
  let size = 0;
  S.large.forEach(f => { if (S.largeSel.has(f.path)) size += f.size; });
  $('largeSelInfo').textContent = S.largeSel.size === 0
    ? `共 ${S.largeCount || 0} 个 · ${fmtSize(S.largeTotal || 0)}`
    : `已选 ${S.largeSel.size} 项 · ${fmtSize(size)}`;
  $('largeTrash').disabled = S.largeSel.size === 0;
}

/* ============ 垃圾文件 ============ */
function junkStats() {
  const safe = S.junk.filter(j => j.risk === '安全');
  const care = S.junk.filter(j => j.risk === '谨慎');
  const sum = a => a.reduce((s, j) => s + j.size, 0);
  return { safeSize: sum(safe), careSize: sum(care), count: S.junk.length, total: sum(S.junk) };
}

function renderJunk() {
  if (S.mode !== 'junk') return;

  const st = junkStats();
  $('junkPills').innerHTML = `
    <div class="pill"><i style="background:var(--green)"></i><span>安全可清理</span><b>${fmtSize(st.safeSize)}</b></div>
    <div class="pill"><i style="background:var(--orange)"></i><span>需确认</span><b>${fmtSize(st.careSize)}</b></div>
    <div class="pill"><i style="background:var(--accent)"></i><span>项目数</span><b>${fmtCount(S.junkTotalCount || st.count)}</b></div>
    <div class="pill"><i style="background:var(--mute)"></i><span>合计</span><b>${fmtSize(st.total)}</b></div>`;

  renderJunkChips();

  const filtered = S.junkFilter ? S.junk.filter(j => j.category === S.junkFilter) : S.junk;
  const list = sortJunk(filtered);
  const box = $('junkTable');
  if (!list.length) {
    box.innerHTML = `<div class="empty-note">${S.lastScan ? '这个范围内没有发现明显垃圾文件。' : '先扫描一个目录，再来看这里。'}</div>`;
    updateJunkSel();
    return;
  }

  box.innerHTML = list.map(j => {
    const on = S.junkSel.has(j.path);
    const tag = j.risk === '安全' ? 'safe' : 'careful';
    return `<div class="trow${on ? ' on' : ''}" data-path="${esc(j.path)}">
      <div class="cb${on ? ' on' : ''}"></div>
      <div class="info">
        <div class="nm">${esc(j.name)}
          ${j.isDir ? '<span class="tag dir">目录</span>' : ''}
          <span class="tag ${tag}">${j.risk}</span>
        </div>
        <div class="pth" title="${esc(j.path)}">${esc(shorten(j.path, 96))}</div>
        <div class="rsn">${esc(j.reason)}</div>
      </div>
      <div class="sz">${fmtSize(j.size)}</div>
      <button class="mag" title="在访达中显示"><svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg></button>
    </div>`;
  }).join('');

  box.querySelectorAll('.trow').forEach(row => {
    const p = row.dataset.path;
    row.addEventListener('click', ev => {
      if (ev.target.closest('.mag')) { call('reveal', { path: p }); return; }
      if (S.junkSel.has(p)) S.junkSel.delete(p); else S.junkSel.add(p);
      row.classList.toggle('on');
      row.querySelector('.cb').classList.toggle('on');
      updateJunkSel();
    });
  });
  updateJunkSel();
}

function renderJunkChips() {
  if (S.mode !== 'junk') return;
  const cats = {};
  S.junk.forEach(j => { cats[j.category] = (cats[j.category] || 0) + 1; });
  let html = `<button class="chip${!S.junkFilter ? ' active' : ''}" data-cat="">全部<em>${S.junk.length}</em></button>`;
  Object.keys(cats).forEach(c => {
    html += `<button class="chip${S.junkFilter === c ? ' active' : ''}" data-cat="${esc(c)}">${esc(c)}<em>${cats[c]}</em></button>`;
  });
  const el = $('junkChips');
  el.innerHTML = html;
  el.querySelectorAll('.chip').forEach(ch => {
    ch.addEventListener('click', () => { S.junkFilter = ch.dataset.cat || null; renderJunk(); });
  });
}

function updateJunkSel() {
  let size = 0, n = 0;
  S.junk.forEach(j => { if (S.junkSel.has(j.path)) { size += j.size; n++; } });
  $('junkSelInfo').textContent = n === 0 ? '未选择' : `已选 ${n} 项 · ${fmtSize(size)}`;
  $('junkTrash').disabled = n === 0;
}

function applyDupGroups(groups, similar) {
  S.dups = groups || [];
  S.dupSel = new Set();
  S.dupKeep = {};
  S.dupFocus = null;
  S.dups.forEach(g => {
    g.similar = similar;
    const keep = similar
      ? g.files[0]
      : g.files.slice().sort((a, b) =>
          String(b.modified || '').localeCompare(String(a.modified || '')))[0];
    S.dupKeep[g.hash] = keep.path;
    g.files.forEach(f => { if (f.path !== keep.path) S.dupSel.add(f.path); });
  });
}

/* ============ 卸载应用 ============ */
function renderApps() {
  if (S.mode !== 'uninstall') return;
  const scroller = $('appList');
  const keepTop = scroller ? scroller.scrollTop : 0;
  const q = S.appQuery.trim().toLowerCase();
  const filtered = q
    ? S.apps.filter(a => a.name.toLowerCase().includes(q) || (a.bundleID || '').toLowerCase().includes(q))
    : S.apps;
  const list = sortApps(filtered);

  const box = $('appList');
  if (!list.length) {
    box.innerHTML = `<div class="empty-note">${S.apps.length ? '没有匹配的应用。' : '正在分析已安装应用…'}</div>`;
    return;
  }

  const head = `<div class="apphead">
      <span class="h-app">应用</span>
      <span class="h-col">最近使用</span>
      <span class="h-col">安装</span>
      <span class="h-col h-lo">残留</span>
      <span class="h-col h-sz">大小</span>
    </div>`;

  box.innerHTML = head + list.map(a => {
    const focused = S.appFocus && S.appFocus.path === a.path;
    const lo = (a.leftovers || []).length;
    return `<div class="approw${focused ? ' focused' : ''}" data-path="${esc(a.path)}">
      <img class="aicon" data-icon-path="${esc(a.path)}" src="${S.appIcons[a.path] || ''}" alt="">
      <div class="ainfo">
        <div class="aname">${esc(a.name)}<span class="aver">${esc(a.version)}</span></div>
        <div class="aid">${esc(a.bundleID || '无 bundle id')}</div>
      </div>
      <span class="adate" title="${a.lastUsed ? '最近使用：' + esc(a.lastUsed.slice(0, 10)) : '无记录'}">${a.lastUsed ? fmtDate(a.lastUsed) : '—'}</span>
      <span class="adate" title="${a.installed ? '安装：' + esc(a.installed.slice(0, 10)) : '未知'}">${a.installed ? fmtDate(a.installed) : '—'}</span>
      <span class="locol">${lo ? `<span class="loBadge">${lo}</span>` : '<i class="loNone">—</i>'}</span>
      <span class="asz">${a.size ? fmtSize(a.size) : '…'}</span>
    </div>`;
  }).join('');

  observeAppIcons();
  if (scroller) scroller.scrollTop = keepTop;

  box.querySelectorAll('.approw').forEach(r => {
    r.addEventListener('click', () => {
      S.appFocus = S.apps.find(x => x.path === r.dataset.path);
      S.appSel = new Set((S.appFocus.leftovers || []).map(l => l.path));
      box.querySelectorAll('.approw').forEach(x => x.classList.toggle('focused', x === r));
      renderAppPreview();
    });
  });
}

let appIconObserver = null;
function observeAppIcons() {
  const root = $('appList');
  if (appIconObserver) appIconObserver.disconnect();
  appIconObserver = new IntersectionObserver(entries => {
    entries.forEach(en => {
      if (!en.isIntersecting) return;
      const img = en.target;
      appIconObserver.unobserve(img);
      const p = img.dataset.iconPath;
      if (!p || S.appIcons[p] !== undefined) return;
      call('appIcon', { path: p });
    });
  }, { root, rootMargin: '120px' });
  root.querySelectorAll('img.aicon[data-icon-path]').forEach(img => appIconObserver.observe(img));
}

function renderAppPreview() {
  const box = $('appPreview');
  const a = S.appFocus;
  if (!a) {
    box.innerHTML = `<div class="preview-empty">
      <svg viewBox="0 0 40 40"><rect x="7" y="7" width="26" height="26" rx="7"/><path d="M14 26V14h8a4 4 0 0 1 0 8h-8"/></svg>
      <p>从左侧选择一个应用<br>查看它能清理哪些残留</p></div>`;
    $('appUninstall').disabled = true;
    $('appSelInfo').textContent = '选择一个应用查看详情';
    return;
  }

  const leftovers = a.leftovers || [];
  const total = leftovers.reduce((s, l) => s + (S.appSel.has(l.path) ? l.size : 0), 0);
  const selCount = leftovers.filter(l => S.appSel.has(l.path)).length;

  const rows = leftovers.length
    ? leftovers.map(l => {
        const on = S.appSel.has(l.path);
        return `<div class="lorow" data-path="${esc(l.path)}">
          <div class="cb${on ? ' on' : ''}"></div>
          <div class="linfo">
            <div class="lname">${esc(l.label)}<span class="tag ${l.risk === '安全' ? 'safe' : 'careful'}">${l.risk}</span></div>
            <div class="lpath" title="${esc(l.path)}">${esc(shorten(l.path, 54))}</div>
          </div>
          <span class="lsize">${fmtSize(l.size)}</span>
        </div>`;
      }).join('')
    : `<div class="pv-note" style="margin:0">没有检测到残留文件，这个应用很干净。</div>`;

  box.innerHTML = `
    <div class="appHead">
      <img src="${a.icon || ''}" alt="">
      <div>
        <div class="pv-name">${esc(a.name)}</div>
        <div class="pv-sub">版本 ${esc(a.version)} · ${fmtSize(a.size)}</div>
      </div>
    </div>
    <div class="pv-path">${esc(a.path)}</div>
    <div class="loHead">残留文件 <span>${leftovers.length} 项 · ${fmtSize(total)}</span></div>
    <div class="lolist">${rows}</div>
    <div class="pv-actions">
      <button class="pv-btn" id="appReveal">
        <svg viewBox="0 0 16 16"><path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.3 1.6h4.1A1.5 1.5 0 0 1 13 6.1v5.4A1.5 1.5 0 0 1 11.5 13h-8A1.5 1.5 0 0 1 2 11.5z"/></svg>
        在访达中显示</button>
    </div>
    <div class="pv-note">勾选的残留会与 App 本体一并移到废纸篓。删除后应用即被卸载，重新安装可恢复。</div>`;

  $('appReveal').addEventListener('click', () => call('reveal', { path: a.path }));
  box.querySelectorAll('.lorow').forEach(r => {
    const p = r.dataset.path;
    r.addEventListener('click', () => {
      if (S.appSel.has(p)) S.appSel.delete(p); else S.appSel.add(p);
      r.querySelector('.cb').classList.toggle('on');
      renderAppPreview();
    });
  });

  $('appSelInfo').textContent =
    `将移除：App 本体 ${fmtSize(a.size)}` +
    (selCount ? ` + ${selCount} 项残留 ${fmtSize(total)}` : '');
  $('appUninstall').disabled = false;
}

/* ============ 重复文件 ============ */
function renderDups(done) {
  if (S.mode !== 'duplicates') return;
  const box = $('dupList');

  if (done && S.dups.length === 0) {
    box.innerHTML = `<div class="empty-note">没有发现重复文件。<br>图标相同不算重复，这里比对的是内容哈希；硬链接按同一份数据计算。</div>`;
    renderDupPreview(); updateDupSel(); return;
  }
  if (!S.dups.length) {
    box.innerHTML = `<div class="empty-note">点击「开始查重」按内容比对。<br>默认只比对大于 1 MB 的文件，避免误伤小配置文件。</div>`;
    renderDupPreview(); updateDupSel(); return;
  }

  const ordered = sortDups(S.dups);
  box.innerHTML = ordered.map(g => {
    const gi = S.dups.indexOf(g);
    const keepPath = S.dupKeep[g.hash];
    const rows = g.files.map(f => {
      const kept = f.path === keepPath;
      const dims = g.similar && f.width ? `${f.width}×${f.height}` : '';
      const sel = !kept && S.dupSel.has(f.path);
      const focused = S.dupFocus && S.dupFocus.path === f.path;
      const ext = (f.name.split('.').pop() || '').toLowerCase();
      return `<div class="frow${kept ? ' kept' : ''}${focused ? ' focused' : ''}"
                   data-path="${esc(f.path)}" data-gi="${gi}">
        ${kept ? '<div class="cb-space"></div>' : `<div class="cb${sel ? ' on' : ''}" data-role="cb"></div>`}
        <div class="thumb" data-path="${esc(f.path)}" data-ext="${esc(ext)}"><span class="ph">${fileGlyph(ext)}</span></div>
        <div class="finfo">
          <div class="fname">${esc(f.name)}</div>
          <div class="fpath" title="${esc(f.path)}">${esc(shorten(f.path, 78))}</div>
        </div>
        <span class="dt">${g.similar ? dims : fmtDate(f.modified)}</span>
        ${kept ? '<span class="kepttag">已保留</span>'
               : '<button class="keepbtn" data-role="keep">保留此份</button>'}
      </div>`;
    }).join('');

    return `<div class="group">
      <div class="group-head">
        <b>${g.files.length} ${g.similar ? '张相似照片' : '个相同文件'}</b>
        <span class="muted">${g.similar ? '最大 ' + fmtSize(g.size) : '每个 ' + fmtSize(g.size)}</span>
        ${g.similar ? '<span class="hl" style="background:rgba(246,189,22,.16);color:#b58900">相似</span>' : ''}
        ${g.hardlink ? `<span class="hl" title="多个路径指向同一份数据，删除不会释放等量空间">硬链接 ${g.files.length - g.uniqueInodes}</span>` : ''}
        <span class="reclaim">${g.hardlink ? '实际可回收 ' : '可回收 '}${fmtSize(g.reclaimable)}</span>
      </div>
      <div class="group-body">${rows}</div>
    </div>`;
  }).join('');

  box.querySelectorAll('.frow').forEach(row => {
    const p = row.dataset.path, gi = Number(row.dataset.gi), g = S.dups[gi];
    row.addEventListener('click', ev => {
      const role = ev.target.closest('[data-role]');
      if (role && role.dataset.role === 'keep') {
        S.dupKeep[g.hash] = p;
        S.dupSel.delete(p);
        g.files.forEach(f => { if (f.path !== p) S.dupSel.add(f.path); });
        S.dupFocus = { path: p, group: g };
        renderDups(null);
        return;
      }
      if (role && role.dataset.role === 'cb') {
        if (S.dupKeep[g.hash] === p) return;
        if (S.dupSel.has(p)) S.dupSel.delete(p); else S.dupSel.add(p);
        role.classList.toggle('on');
        updateDupSel();
        return;
      }
      S.dupFocus = { path: p, group: g };
      box.querySelectorAll('.frow').forEach(r => r.classList.toggle('focused', r === row));
      renderDupPreview();
    });
  });

  observeThumbs();
  renderDupPreview();
  updateDupSel();
}

function fileGlyph(ext) {
  if (['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'bmp', 'tiff'].includes(ext)) return '🖼';
  if (['mp4', 'mov', 'mkv', 'avi', 'webm'].includes(ext)) return '🎬';
  if (['mp3', 'wav', 'flac', 'aac', 'm4a'].includes(ext)) return '🎵';
  if (ext === 'pdf') return '📄';
  if (['zip', 'rar', '7z', 'tar', 'gz'].includes(ext)) return '📦';
  if (['dmg', 'pkg', 'iso'].includes(ext)) return '💿';
  if (['doc', 'docx', 'pages'].includes(ext)) return '📝';
  if (['xls', 'xlsx', 'numbers', 'csv'].includes(ext)) return '📊';
  if (['ppt', 'pptx', 'key'].includes(ext)) return '📽';
  return '📄';
}

let thumbObserver = null;
function observeThumbs() {
  const root = $('dupList');
  if (thumbObserver) thumbObserver.disconnect();
  thumbObserver = new IntersectionObserver(entries => {
    entries.forEach(en => {
      if (!en.isIntersecting) return;
      const el = en.target;
      thumbObserver.unobserve(el);
      requestThumb(el.dataset.path, 68, el);
    });
  }, { root, rootMargin: '160px' });
  root.querySelectorAll('.thumb[data-path]').forEach(el => thumbObserver.observe(el));
}

function requestThumb(path, size, el) {
  const cached = S.thumbs[path];
  if (cached !== undefined) {
    if (cached && el) el.innerHTML = `<img src="${cached}" alt="">`;
    return;
  }
  if (S.thumbPending[path]) return;
  S.thumbPending[path] = true;
  call('thumbnail', { path, size });
}

function applyThumb(path, dataUrl) {
  S.thumbs[path] = dataUrl || '';
  delete S.thumbPending[path];
  document.querySelectorAll(`.thumb[data-path="${CSS.escape(path)}"]`).forEach(el => {
    if (dataUrl) el.innerHTML = `<img src="${dataUrl}" alt="">`;
  });
  if (S.pvThumbEl && S.pvThumbPath === path && dataUrl) {
    S.pvThumbEl.innerHTML = `<img src="${dataUrl}" alt="">`;
  }
}

function renderDupPreview() {
  const box = $('dupPreview');
  const f = S.dupFocus;
  if (!f) {
    box.innerHTML = `<div class="preview-empty">
      <svg viewBox="0 0 40 40"><rect x="6" y="6" width="12" height="12" rx="2.5"/><rect x="22" y="6" width="12" height="12" rx="2.5"/><rect x="6" y="22" width="12" height="12" rx="2.5"/><rect x="22" y="22" width="12" height="12" rx="2.5"/></svg>
      <p>点击左侧任意文件<br>在这里查看预览与详情</p></div>`;
    return;
  }
  const file = f.group.files.find(x => x.path === f.path) || { name: '', size: 0 };
  const ext = (file.name.split('.').pop() || '').toLowerCase();
  const isKept = S.dupKeep[f.group.hash] === f.path;

  box.innerHTML = `
    <div class="pv-thumb" id="pvThumb"><span class="ph">${fileGlyph(ext)}</span></div>
    <div class="pv-name">${esc(file.name || '(未命名)')}</div>
    <div class="pv-badge ${isKept ? '' : 'del'}">${isKept ? '✓ 将保留此份' : '将从此组删除'}</div>
    <div class="pv-rows">
      <div class="pv-row"><span class="k">大小</span><span class="v">${fmtSize(file.size)}</span></div>
      <div class="pv-row"><span class="k">修改时间</span><span class="v">${fmtDate(file.modified)}</span></div>
      <div class="pv-row"><span class="k">类型</span><span class="v">${ext ? '.' + esc(ext) : '无扩展名'}</span></div>
      <div class="pv-row"><span class="k">同组</span><span class="v">共 ${f.group.files.length} ${f.group.similar ? '张相似照片' : '个内容相同的文件'}</span></div>
      ${f.group.similar && file.width ? `<div class="pv-row"><span class="k">分辨率</span><span class="v">${file.width} × ${file.height}</span></div>` : ''}
      ${f.group.hardlink ? `<div class="pv-row"><span class="k">硬链接</span><span class="v">含 ${f.group.files.length - f.group.uniqueInodes} 个硬链接副本</span></div>` : ''}
    </div>
    <div class="pv-path">${esc(f.path)}</div>
    <div class="pv-actions">
      <button class="pv-btn primary" id="pvReveal">
        <svg viewBox="0 0 16 16"><path d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.6l1.3 1.6h4.1A1.5 1.5 0 0 1 13 6.1v5.4A1.5 1.5 0 0 1 11.5 13h-8A1.5 1.5 0 0 1 2 11.5z"/></svg>
        在访达中显示</button>
      <button class="pv-btn" id="pvOpen">
        <svg viewBox="0 0 16 16"><path d="M9 2.5h4.5V7M13.2 2.8L7.5 8.5M12 9.5v3.2A1.3 1.3 0 0 1 10.7 14H3.3A1.3 1.3 0 0 1 2 12.7V5.3A1.3 1.3 0 0 1 3.3 4h3.2"/></svg>
        用默认程序打开</button>
      ${isKept ? '' : `<button class="pv-btn" id="pvKeep">
        <svg viewBox="0 0 16 16"><path d="M3 8.5l3.2 3.2L13 5"/></svg>改为保留这一份</button>`}
    </div>
    <div class="pv-note">${f.group.similar
      ? `这一组还有 ${f.group.files.length - 1} 张照片画面相近，可能是同图的不同尺寸或压缩版本。`
      : `这一组还有 ${f.group.files.length - 1} 个文件与之逐字节相同。`}</div>`;

  S.pvThumbEl = $('pvThumb');
  S.pvThumbPath = f.path;
  const cached = S.thumbs[f.path];
  if (cached) S.pvThumbEl.innerHTML = `<img src="${cached}" alt="">`;
  else call('thumbnail', { path: f.path, size: 320 });

  $('pvReveal').addEventListener('click', () => call('reveal', { path: f.path }));
  $('pvOpen').addEventListener('click', () => call('open', { path: f.path }));
  const kb = $('pvKeep');
  if (kb) kb.addEventListener('click', () => {
    S.dupKeep[f.group.hash] = f.path;
    S.dupSel.delete(f.path);
    f.group.files.forEach(x => { if (x.path !== f.path) S.dupSel.add(x.path); });
    renderDups(null);
  });
}

function updateDupSel() {
  let size = 0, n = 0;
  S.dups.forEach(g => {
    const deleted = g.files.filter(f => S.dupSel.has(f.path) && S.dupKeep[g.hash] !== f.path);
    if (!deleted.length) return;
    n += deleted.length;
    if (g.similar) { size += deleted.reduce((s2, f) => s2 + f.size, 0); return; }
    // 硬链接：只有整个 inode 的最后一条路径被删，才真正释放空间
    const allLinks = new Set(g.files.map(f => f.linkId ?? f.path));
    const keptLinks = new Set(g.files.filter(f => !deleted.includes(f)).map(f => f.linkId ?? f.path));
    size += (allLinks.size - keptLinks.size) * g.size;
  });
  $('dupSelInfo').textContent = n === 0 ? '每组保留一份，未标记删除项' : `将删除 ${n} 项 · 释放 ${fmtSize(size)}`;
  $('dupTrash').disabled = n === 0;
}

/* ============ 模式切换 ============ */
document.querySelectorAll('.tab').forEach(tab => {
  tab.addEventListener('click', () => {
    const mode = tab.dataset.mode;
    S.mode = mode;
    document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t === tab));
    ['explorer', 'kinds', 'large', 'junk', 'uninstall', 'duplicates'].forEach(m => {
      $('view-' + m).hidden = m !== mode;
    });

    $('pageTitle').textContent =
      { explorer: '空间树图', kinds: '类型分析', large: '大文件', junk: '垃圾文件',
        uninstall: '卸载应用', duplicates: '重复文件' }[mode];

    if (mode === 'explorer') {
      $('pageSub').textContent = S.lastScan
        ? `${fmtSize(S.lastScan.totalSize)} · ${fmtCount(S.lastScan.fileCount)} 个文件` : '选择一个目录后开始扫描';
      setTimeout(drawTreemap, 30);
    }
    if (mode === 'kinds') {
      $('pageSub').textContent = S.lastScan ? `共 ${fmtSize(S.lastScan.totalSize)}` : '尚未扫描';
      renderKinds();
    }
    if (mode === 'large') {
      $('pageSub').textContent = S.lastScan ? '按文件体积排序' : '尚未扫描';
      call('largeFiles', { minSize: S.largeMin });
    }
    if (mode === 'junk') {
      $('pageSub').textContent = S.junk.length ? `共 ${S.junk.length} 项` : '尚未扫描';
      call('junk'); renderJunk();
    }
    if (mode === 'duplicates') renderDups(null);
    if (mode === 'uninstall') {
      $('pageSub').textContent = S.apps.length
        ? `${S.apps.length} 个应用` : '正在分析已安装应用…';
      if (!S.apps.length) call('listApps');
      else renderApps();
      renderAppPreview();
    }
  });
});

/* ============ 按钮 ============ */
$('btnScan').addEventListener('click', () => {
  if (!S.rootPath) { call('chooseFolder'); return; }
  call('scan', { path: S.rootPath });
});
$('btnFolder').addEventListener('click', () => call('chooseFolder'));
$('btnFullDisk').addEventListener('click', () => {
  S.rootPath = '/';
  $('targetPath').textContent = '整块磁盘 (/)';
  call('diskInfo', { path: '/' });
  call('scan', { path: '/' });
});
$('btnChoose').addEventListener('click', () => call('chooseFolder'));
$('btnExport').addEventListener('click', () => {
  const scope = S.mode === 'kinds' ? (S.kindMode === 'apps' ? 'apps' : 'kinds') : S.mode;
  call('export', { scope });
});
$('permOpen').addEventListener('click', () => call('openPrivacy'));
$('permDetail').addEventListener('click', () => {
  const box = $('permBox');
  if (!box.hidden) { box.hidden = true; return; }
  const fda = box.dataset.fda === '1';
  const head = fda
    ? '以下目录即使拥有完全磁盘访问也无法读取（系统保护或需要 root 权限），不影响用户数据统计：'
    : '磁盘访问授权未生效。本应用为 ad-hoc 签名，重新编译后系统会视为新程序，需要在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中移除 DiskLens 再重新添加。被跳过的目录：';
  box.innerHTML = `<div class="ph">${head}</div>` + (S.deniedSamples || []).map(p => esc(p)).join('<br>');
  box.hidden = false;
});
$('permDismiss').addEventListener('click', () => { $('permBar').hidden = true; });

document.querySelectorAll('#kindMode button').forEach(b => {
  b.addEventListener('click', () => {
    document.querySelectorAll('#kindMode button').forEach(x => x.classList.toggle('active', x === b));
    S.kindMode = b.dataset.m;
    renderKinds();
  });
});
document.querySelectorAll('#largeSize button').forEach(b => {
  b.addEventListener('click', () => {
    document.querySelectorAll('#largeSize button').forEach(x => x.classList.toggle('active', x === b));
    S.largeMin = Number(b.dataset.size);
    call('largeFiles', { minSize: S.largeMin });
  });
});
$('largeSelectIdle').addEventListener('click', () => {
  S.largeSel = new Set(S.large.filter(f => (f.idleDays ?? 0) >= 180).map(f => f.path));
  renderLarge();
  if (!S.largeSel.size) toast('没有超过 180 天未使用的文件');
});
$('largeClear').addEventListener('click', () => { S.largeSel.clear(); renderLarge(); });
$('largeTrash').addEventListener('click', () => {
  const paths = Array.from(S.largeSel);
  if (paths.length) call('trash', { paths });
});

$('junkSelectAll').addEventListener('click', () => {
  // 有分类筛选时只选中当前这一类
  const list = S.junkFilter ? S.junk.filter(j => j.category === S.junkFilter) : S.junk;
  list.forEach(j => S.junkSel.add(j.path));
  renderJunk();
});
$('junkSelectSafe').addEventListener('click', () => {
  S.junkSel.clear();
  S.junk.forEach(j => { if (j.risk === '安全') S.junkSel.add(j.path); });
  renderJunk();
});
$('junkClear').addEventListener('click', () => { S.junkSel.clear(); renderJunk(); });
$('junkTrash').addEventListener('click', () => {
  const paths = Array.from(S.junkSel);
  if (paths.length) call('trash', { paths });
});

$('appsRefresh').addEventListener('click', () => { S.apps = []; S.appsSorted = false; call('listApps'); });
$('appSearch').addEventListener('input', ev => { S.appQuery = ev.target.value; renderApps(); });
$('appUninstall').addEventListener('click', () => {
  const a = S.appFocus;
  if (!a) return;
  const paths = [a.path, ...Array.from(S.appSel)];
  call('trash', { paths });
});

document.querySelectorAll('#dupMode button').forEach(b => {
  b.addEventListener('click', () => {
    document.querySelectorAll('#dupMode button').forEach(x => x.classList.toggle('active', x === b));
    S.dupMode = b.dataset.m;
    const exact = S.dupMode === 'exact';
    document.querySelectorAll('#dupSize button').forEach(x => x.disabled = !exact);
    $('dupScan').textContent = exact ? '开始查重' : '开始识图';
    if (exact) {
      $('pageSub').textContent = S.dups.length ? `${S.dups.length} 组 · 可回收` : '按内容哈希比对';
      renderDups(null);
    } else {
      $('pageSub').textContent = '按感知哈希找相似照片';
      $('dupList').innerHTML = `<div class="empty-note">点击「开始识图」，会比对画面而非字节。<br>能找出同一张图的不同尺寸、不同压缩版本，以及轻微调色后的版本。</div>`;
    }
  });
});

document.querySelectorAll('#dupSize button').forEach(b => {
  b.addEventListener('click', () => {
    document.querySelectorAll('#dupSize button').forEach(x => x.classList.toggle('active', x === b));
    S.minSize = Number(b.dataset.size);
  });
});
$('dupScan').addEventListener('click', () => {
  if (S.dupMode === 'similar') call('findSimilar', { tolerance: 14 });
  else call('findDuplicates', { minSize: S.minSize });
});
$('dupSelectAll').addEventListener('click', () => {
  S.dups.forEach(g => g.files.forEach(f => {
    if (S.dupKeep[g.hash] !== f.path) S.dupSel.add(f.path);
  }));
  renderDups(null);
});
$('dupClear').addEventListener('click', () => { S.dupSel.clear(); renderDups(null); });
$('dupTrash').addEventListener('click', () => {
  const paths = Array.from(S.dupSel);
  if (paths.length) call('trash', { paths });
});

/* ============ 排序控件绑定 ============ */
function bindSort(selectId, dirId, key, rerender) {
  const sel = $(selectId), btn = $(dirId);
  if (!sel || !btn) return;
  sel.value = S.sort[key].key;
  btn.textContent = S.sort[key].dir === 1 ? '↑' : '↓';
  btn.title = S.sort[key].dir === 1 ? '当前升序，点击改为降序' : '当前降序，点击改为升序';

  sel.addEventListener('change', () => {
    S.sort[key].key = sel.value;
    rerender();
  });
  btn.addEventListener('click', () => {
    S.sort[key].dir *= -1;
    btn.textContent = S.sort[key].dir === 1 ? '↑' : '↓';
    btn.title = S.sort[key].dir === 1 ? '当前升序，点击改为降序' : '当前降序，点击改为升序';
    rerender();
  });
}

bindSort('appSort', 'appSortDir', 'app', () => { renderApps(); });
bindSort('junkSort', 'junkSortDir', 'junk', () => { renderJunk(); });
bindSort('dupSort', 'dupSortDir', 'dup', () => { renderDups(null); });
bindSort('largeSort', 'largeSortDir', 'large', () => { renderLarge(); });

/* ============ 图例 ============ */
(function buildLegend() {
  const order = ['视频', '图片', '音频', '代码', '压缩包', '文档', '应用', '数据', '其他'];
  $('legend').innerHTML = `<label>颜色代表类型</label><div class="legend-grid">` +
    order.map(k => `<span><i style="background:${KIND_COLORS[k]}"></i>${k}</span>`).join('') +
    `</div><div class="legend-note">无法归类或内容混杂的目录用区分色</div>`;
})();

/* ============ 初始化 ============ */
(function init() {
  call('diskInfo', { path: '' });
  setTimeout(() => drawTreemap(), 60);
  window.addEventListener('keydown', e => {
    if (e.key === 'Escape' && S.mode === 'explorer' && S.stack.length > 1) {
      S.stack.pop();
      S.currentPath = S.stack[S.stack.length - 1].path;
      requestChildren(S.currentPath);
    }
  });
})();
