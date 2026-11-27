'use strict';

const windowsWorkspaceIcons = {
  folder: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 7v-1a2 2 0 0 1 2-2h3l2 2h5a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z"/><path d="M3 8h14"/></svg>',
  launch: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7 5h8v8m0-8L5 15"/></svg>',
  organize: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="M7 5h9M7 10h9m-9 5h9M4 5h.01M4 10h.01M4 15h.01" stroke-width="1.85"/></svg>',
  done: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m4 10 4 4 8-8"/></svg>',
  play: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m7 5 8 5-8 5V5Z"/></svg>',
  warning: '<svg viewBox="0 0 20 20" aria-hidden="true"><path d="m10 3 8 14H2L10 3Zm0 5v3m0 2.5v.1"/></svg>',
};

function workspaceHost(url) {
  try { return new URL(url).host; } catch (_) { return ''; }
}

function workspaceBrowser(site) {
  return S.browsers.find(browser => browser.id === site.defaultBrowser)?.name || site.defaultBrowser;
}

function workspaceSiteIcon(site) {
  return '<span class="workspace-item-icon" style="--site-color:' + safeColor(site.color) + '">'
    + iconHTML(site, true) + '</span>';
}

const inheritedTileElement = tileElement;
tileElement = function windowsTileElement(tile, inside) {
  const card = inheritedTileElement(tile, inside);
  if (!card) return null;
  const folder = tile.kind === 'folder';
  const site = folder ? null : siteById(tile.id);
  const icon = card.querySelector('.tile-icon');
  const check = card.querySelector('.selection-check');
  const name = folder ? tile.name : site.name;
  const meta = folder ? tile.children.length + ' 个网站' : workspaceHost(site.url);
  const browserName = folder ? '' : workspaceBrowser(site);
  const browser = browserName ? '<span class="workspace-tile-browser">' + esc(browserName) + '</span>' : '';
  card.setAttribute('aria-description', [meta, browserName].filter(Boolean).join('，'));
  card.innerHTML = '<span class="workspace-tile-top"><span class="workspace-tile-icon-slot"></span>'
    + '<span class="workspace-tile-action">' + (folder ? windowsWorkspaceIcons.folder : windowsWorkspaceIcons.launch)
    + '</span></span><span class="tile-name" title="' + esc(name) + '">' + esc(name) + '</span>'
    + '<span class="workspace-tile-info"><span class="workspace-tile-host" title="' + esc(meta) + '">' + esc(meta)
    + '</span>' + browser + '</span>';
  card.querySelector('.workspace-tile-icon-slot').append(icon);
  if (check) card.append(check);
  return card;
};

function workspaceMetric(name) {
  return Number.parseFloat(getComputedStyle(document.body).getPropertyValue(name));
}

columns = function windowsWorkspaceColumns() {
  const width = $('grid').clientWidth;
  const metrics = getComputedStyle($('grid'));
  const contentWidth = width - parseFloat(metrics.paddingLeft) - parseFloat(metrics.paddingRight);
  const gap = parseFloat(metrics.columnGap);
  const icon = Number(S?.library.iconSize) || 76;
  const minimum = Math.max(workspaceMetric('--workspace-min-card'), icon + 65);
  return Math.max(1, Math.min(8, Math.floor((contentWidth + gap) / (minimum + gap))));
};

pageSize = function windowsWorkspacePageSize() {
  const metrics = getComputedStyle($('grid'));
  const contentHeight = $('launchArea').clientHeight - parseFloat(metrics.paddingTop) - parseFloat(metrics.paddingBottom);
  const gap = parseFloat(metrics.rowGap);
  const iconSize = (Number(S?.library.iconSize) || 76) * workspaceMetric('--workspace-icon-factor');
  const cardHeight = iconSize + workspaceMetric('--workspace-card-caption');
  return columns() * Math.max(1, Math.floor((contentHeight + gap) / (cardHeight + gap)));
};

const inheritedRenderPagination = renderPagination;
renderPagination = function windowsRenderPagination() {
  inheritedRenderPagination();
  $('pagination').hidden = totalPages <= 1;
};

const renderWorkspaceSelection = () => {
  const button = $('manageButton');
  button.setAttribute('aria-pressed', String(selectionMode));
  button.innerHTML = selectionMode ? windowsWorkspaceIcons.done + '<span>完成整理</span>'
    : windowsWorkspaceIcons.organize + '<span>整理</span>';
};

const inheritedRender = render;
render = function windowsRender() {
  inheritedRender();
  if (!S || activeSection !== 'launcher') return;
  const query = $('search').value.trim();
  $('launcherPage').toggleAttribute('data-empty', !$('empty').hidden);
  if (currentAccess !== 'ready') {
    $('empty').hidden = true;
    $('count').textContent = '';
    return;
  }
  renderWorkspaceSelection();
  $('launcherPage').toggleAttribute('data-searching', Boolean(query));
  if (!query && !S.library.tiles.some(tile => tile.kind === 'folder')) {
    $('count').textContent = visibleIDs().size + ' 个网站';
  }
  if (!$('empty').hidden) {
    $('empty').innerHTML = '<span class="workspace-empty-icon">' + svg(query ? 'search' : 'launcher')
      + '</span><strong>' + (query ? '没有匹配的网站' : '启动台为空') + '</strong><p>'
      + (query ? '可按网站、拼音、简称、账号或网址查找。' : '添加网站后，可从这里直接打开。') + '</p>'
      + '<button class="soft-button" type="button" id="workspaceEmptyAction">'
      + (query ? '清除搜索' : '添加网站') + '</button>';
    $('workspaceEmptyAction').onclick = () => {
      if (query) { $('search').value = ''; page = 0; searchIndex = 0; render(); $('search').focus(); }
      else $('addButton').click();
    };
  }
};

function workspaceSceneCard(workspace) {
  const sites = workspace.siteIDs.map(siteById).filter(Boolean);
  const items = sites.slice(0, 3).map(site => '<li>' + workspaceSiteIcon(site)
    + '<span title="' + esc(site.name) + '">' + esc(site.name) + '</span><small>'
    + esc(workspaceBrowser(site)) + '</small></li>').join('');
  return '<section class="workspace-card"><div class="workspace-title"><span class="workspace-group-icon">' + svg('workspaces')
    + '</span><div><strong>' + esc(workspace.name) + '</strong><p>' + sites.length + ' 个网站</p></div></div>'
    + '<ul class="workspace-scene-sites">' + items + '</ul>'
    + (sites.length > 3 ? '<p class="workspace-scene-extra">另有 ' + (sites.length - 3) + ' 个网站</p>' : '')
    + '<div class="workspace-controls"><button type="button" class="soft-button" data-edit-workspace="' + esc(workspace.id)
    + '">编辑场景</button><button type="button" class="text-button danger" data-delete-workspace="' + esc(workspace.id)
    + '">删除</button><button type="button" class="primary-button" data-launch-workspace="' + esc(workspace.id)
    + '">' + windowsWorkspaceIcons.play + '打开场景</button></div></section>';
}

function workspaceVaultCard(site, archived) {
  const accounts = site.accounts.map(account => '<div class="vault-account"><div><strong>' + esc(account.label || '网站账号')
    + '</strong><span>' + esc(account.username || '未填写用户名') + '</span></div><span class="workspace-password-state'
    + (account.hasPassword ? ' has-password' : '') + '">'
    + (account.hasPassword ? '已保存密码' : '未保存密码') + '</span><button type="button" class="text-button danger" data-site="'
    + esc(site.id) + '" data-delete-account="' + esc(account.id) + '">删除账号</button></div>').join('');
  return '<section class="vault-site"><div class="vault-site-head"><div class="workspace-vault-site">' + workspaceSiteIcon(site)
    + '<div><strong>' + esc(site.name) + '</strong><span>' + esc(workspaceHost(site.url))
    + (archived ? ' · 已移除入口' : '') + '</span></div></div><div class="setting-actions">'
    + (archived ? '<button type="button" class="soft-button" data-restore="' + esc(site.id) + '">恢复入口</button>' : '')
    + '<button type="button" class="soft-button" data-edit="' + esc(site.id) + '">编辑网站</button></div></div>'
    + (accounts ? '<div class="workspace-vault-accounts">' + accounts + '</div>' : '') + '</section>';
}

renderSection = function windowsRenderSection() {
  const root = $('sectionPage');
  if (activeSection === 'workspaces') {
    const scenes = S.library.workspaces || [];
    root.innerHTML = scenes.length ? '<div class="workspace-grid">' + scenes.map(workspaceSceneCard).join('') + '</div>'
      : '<div class="empty-state"><span class="empty-state-symbol">' + svg('workspaces')
        + '</span><strong>还没有工作场景</strong><p>选好常一起打开的网站后，可以一次启动。</p>'
        + '<button type="button" class="primary-button" id="newWorkspace">创建工作场景</button></div>';
    bindWorkspaceControls(root);
  } else if (activeSection === 'vault') {
    const active = visibleIDs();
    const sites = S.library.sites.filter(site => site.accounts.length || !active.has(site.id));
    const notice = '<div class="section-notice">' + svg('vault') + '<span>解锁后可自动填充。睡眠、锁屏或解锁 5 分钟后会自动锁定。</span></div>';
    const vault = sites.length ? '<div class="vault-grid">' + sites.map(site => workspaceVaultCard(site, !active.has(site.id))).join('') + '</div>'
      : '<div class="empty-state"><span class="empty-state-symbol">' + svg('vault')
        + '</span><strong>还没有保存账号</strong><p>在网站编辑页中添加账号。密码由 Windows 凭据保护。</p>'
        + '<button type="button" class="soft-button" id="workspaceVaultSites">查看网站</button></div>';
    root.innerHTML = notice + vault;
    bindVaultControls(root);
    if ($('workspaceVaultSites')) $('workspaceVaultSites').onclick = () => selectSection('launcher');
  }
};

renderLock = function windowsRenderLock() {
  const button = $('lockButton');
  button.disabled = currentAccess !== 'ready';
  button.innerHTML = svg(S.unlocked ? 'unlock' : 'vault') + '<span class="workspace-lock-text">'
    + (S.unlocked ? '账号库已解锁' : '账号库已锁定') + '</span>';
  const label = S.unlocked ? '锁定账号库' : '解锁账号库';
  button.setAttribute('aria-label', label);
  button.title = label;
  button.classList.toggle('unlocked', S.unlocked);
};

const inheritedSidebarToggle = toggleSidebar;
toggleSidebar = function windowsToggleSidebar() {
  const hadSidebarFocus = $('portalSidebar').contains(document.activeElement);
  inheritedSidebarToggle();
  const button = $('workspaceSidebarToggle');
  button.setAttribute('aria-expanded', String(!sidebarHidden));
  if (sidebarHidden && hadSidebarFocus) button.focus();
};
$('workspaceSidebarToggle').onclick = () => toggleSidebar();

const inheritedUpdateState = updateState;
updateState = function windowsWorkspaceState(state) {
  inheritedUpdateState(state);
  $('workspaceStartup').hidden = true;
  $('workspacesButton').disabled = false;
  $('vaultButton').disabled = false;
};

const inheritedWindowsNative = native;
const workspaceStartupContent = $('workspaceStartup').innerHTML;
native = async function windowsWorkspaceNative(action, data) {
  try {
    return await inheritedWindowsNative(action, data);
  } catch (error) {
    if (action === 'state' && !S) {
      const status = $('workspaceStartup');
      status.dataset.state = 'error';
      status.innerHTML = '<span class="workspace-empty-icon">' + windowsWorkspaceIcons.warning
        + '</span><strong>无法加载网站资料</strong><button type="button" class="soft-button" id="workspaceRetry">重试</button>';
      $('workspaceRetry').onclick = () => {
        delete status.dataset.state;
        status.innerHTML = workspaceStartupContent;
        native('state').catch(retryError => toast(retryError.message));
      };
    }
    throw error;
  }
};
