'use strict';

const portalToken = document.querySelector('meta[name="gao-token"]').content;
const settingsWindow = document.body.classList.contains('settings-window');
const browserCatalog = [
  {id: 'chrome', name: 'Chrome', supportsFill: true},
  {id: 'edge', name: 'Edge', supportsFill: true},
  {id: 'safari', name: 'Safari', supportsFill: false},
  {id: 'firefox', name: 'Firefox', supportsFill: false}
];
let currentAccess, libraryRevision, settingsTab = 'modules';
let lastProposal, lastAppliedQuery, previousFeedback;
let activeActionReview, checkingActions = false;
let pendingPortalActions = 0;
let launcherDesktopHidden = false;
const launcherPolls = [];
const backgroundPortalRequests = new Set(['/api/launcher/state', '/api/launcher/runtime', '/api/launcher/acknowledge',
  '/api/actions/queue', '/api/actions/ack-notice', '/api/sites/icon-warmup', '/api/browser/diagnostics']);

function launcherHidden() {
  return launcherDesktopHidden || document.hidden;
}

function launcherVisibilityChanged() {
  launcherPolls.forEach(update => update());
}

// WinForms Hide may leave WebView2's document visibility unchanged.
window.gaoSetDesktopHidden = hidden => {
  if (typeof hidden !== 'boolean' || hidden === launcherDesktopHidden) return;
  launcherDesktopHidden = hidden;
  launcherVisibilityChanged();
};
document.addEventListener('visibilitychange', launcherVisibilityChanged);

window.gaoCloseState = () => ({
  busy: pendingPortalActions > 0 || preferenceFeedback.kind === 'busy',
  editing: !$('dialogOverlay').hidden && !$('dialog').querySelector('.preferences-layout'),
  draft: false,
});

function profileOptions(profiles) {
  return profiles.flatMap(profile => (profile.browsers || [profile.browser])
    .filter(Boolean)
    .map(browser => ({id: profile.id, label: profile.label, browser})));
}

function applyPortalState(state) {
  if (libraryRevision !== undefined && state.libraryRevision < libraryRevision) return;
  libraryRevision = state.libraryRevision;
  currentAccess = state.access;
  updateState({
    ...state, version: state.version.split('+')[0],
    library: state.library || {sites: [], tiles: [], appearance: 'system'},
    unlocked: state.vaultUnlocked,
    recoveryRequired: state.access !== 'ready',
    recoveryMessage: state.message,
    browsers: browserCatalog.map(browser => ({...browser, installed: state.installedBrowsers.includes(browser.id)})),
    profiles: profileOptions(state.profiles)
  });
  if (currentAccess === 'uninitialized') {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'soft-button';
    button.textContent = '创建网站资料';
    button.onclick = () => applyButton(button, () => portalAPI('/api/library/create'), '网站资料已创建。');
    $('recoveryNotice').append(' ', button);
  }
  refreshSettingsState();
  handlePortalEvents(state);
}

async function portalAPI(path, data = {}, apply = true) {
  const awaited = !backgroundPortalRequests.has(path);
  if (awaited) pendingPortalActions++;
  try {
    const response = await fetch(path, {
      method: 'POST',
      headers: {'X-Gao-Token': portalToken, 'Content-Type': 'application/json'},
      body: JSON.stringify(data)
    });
    const value = await response.json();
    const state = value.state || (Object.hasOwn(value, 'libraryRevision') ? value : null);
    if (apply && state) applyPortalState(state);
    if (!response.ok || !value.ok) {
      throw Object.assign(new Error(value.error || value.message || '操作未完成，请重试。'), {code: value.code});
    }
    return value;
  } finally {
    if (awaited) pendingPortalActions--;
  }
}

async function openPortalWindow(path) {
  const host = window.pywebview?.api;
  if (host?.open_window) {
    if (!await host.open_window(path)) throw new Error('无法打开窗口，请重试。');
  } else if (path === '/settings') {
    renderWindowsSettings();
  } else if (!window.open(path, path.split(/[?#]/)[0])) {
    throw new Error('无法打开窗口，请允许搞门户打开弹出窗口。');
  }
  return {ok: true};
}

const endpoints = {
  layout: '/api/layout', batch: '/api/batch', undo: '/api/undo',
  appearance: '/api/appearance', lock: '/api/vault/lock',
  saveWorkspace: '/api/workspaces/save', deleteWorkspace: '/api/workspaces/delete',
  refreshIcon: '/api/sites/icon',
  portalProposalCancelled: '/api/launcher/acknowledge'
};

native = async function windowsNative(action, data = {}) {
  if (endpoints[action]) return portalAPI(endpoints[action], data);
  switch (action) {
    case 'state':
      return settingsWindow ? loadSettingsWindow() : portalAPI('/api/launcher/state');
    case 'launch':
      return launchWithVault('/api/sites/launch', {...data, browserID: data.browser});
    case 'launchWorkspace':
      return launchWithVault('/api/workspaces/launch', data);
    case 'saveSite': {
      const site = structuredClone(data.site);
      const passwords = site.accounts.filter(account => account.password)
        .map(account => ({id: account.id, password: account.password}));
      const retained = new Set(site.accounts.map(account => account.id));
      site.accounts.forEach(account => delete account.password);
      const deletingPassword = siteById(site.id)?.accounts.some(account => account.hasPassword && !retained.has(account.id));
      if ((passwords.length || deletingPassword) && !S.unlocked) {
        if (!await confirmVaultUnlock()) throw new Error('已取消更新账号密码。');
      }
      const response = await portalAPI('/api/sites/save', {...data, site, passwords});
      if (!site.icon && site.iconSource !== 'custom') {
        portalAPI('/api/sites/icon', {siteID: site.id}).catch(logBackgroundIssue);
      }
      return response;
    }
    case 'removeSite':
      return portalAPI('/api/sites/remove', {id: data.siteID});
    case 'restoreSite':
      return portalAPI('/api/sites/restore', {id: data.siteID});
    case 'deleteAccount': {
      const account = siteById(data.siteID)?.accounts.find(item => item.id === data.accountID);
      if (account?.hasPassword && !S.unlocked && !await confirmVaultUnlock()) throw new Error('已取消删除账号。');
      return portalAPI('/api/accounts/delete', data);
    }
    case 'unlock': {
      if (!await confirmVaultUnlock()) throw new Error('已取消解锁。');
      return {ok: true};
    }
    case 'chooseIcon': {
      const selected = await selectFile('image/png,image/jpeg,image/webp,image/x-icon,image/gif,.ico');
      if (!selected) return {ok: true, cancelled: true};
      if (selected.size > 4 * 1024 * 1024) throw new Error('图标文件必须小于 4 MB。');
      return portalAPI('/api/sites/icon-preview', {iconBase64: await fileBase64(selected)});
    }
    case 'openSettings':
      return openPortalWindow('/settings');
    case 'openDownloads':
      return openPortalWindow('/downloads');
    case 'openMail':
      return openPortalWindow('/mail');
    case 'portalPrepareSelectedDownload':
      return openPortalWindow('/downloads?site=' + encodeURIComponent(data.siteID));
    case 'fullscreen': {
      const host = window.pywebview?.api;
      if (host?.toggle_fullscreen) await host.toggle_fullscreen();
      else if (document.fullscreenElement) await document.exitFullscreen();
      else await document.documentElement.requestFullscreen();
      return {ok: true};
    }
    case 'bookmarkSources': {
      const result = await portalAPI('/api/bookmarks/sources');
      return {...result, sources: result.sources.map(source => ({...source, browser: source.browserID, label: source.name}))};
    }
    case 'previewBookmarks':
      return portalAPI('/api/bookmarks/preview', data);
    case 'applyBookmarks':
      return portalAPI('/api/backup/apply', {...data, kind: 'bookmarks'});
    case 'previewBackup':
      return previewBackupFile(data.mode);
    case 'applyBackup':
      return portalAPI('/api/backup/apply', {...data, kind: 'backup'});
    default:
      throw new Error('无法处理此操作。');
  }
};

async function confirmVaultUnlock() {
  if (!window.confirm('解锁搞门户的网站账号库？解锁后可在已授权的 HTTPS 页面填充，5 分钟后自动锁定。')) return false;
  await portalAPI('/api/vault/unlock');
  return true;
}

async function launchWithVault(path, data) {
  try {
    return await portalAPI(path, data);
  } catch (error) {
    if (!['vault_locked', 'vault-locked'].includes(error.code)) throw error;
    if (!await confirmVaultUnlock()) throw new Error('已取消打开。');
    return portalAPI(path, data);
  }
}

function selectFile(accept) {
  return new Promise(resolve => {
    const input = document.createElement('input');
    input.type = 'file';
    input.hidden = true;
    input.accept = accept;
    document.body.append(input);
    const finish = file => {input.remove(); resolve(file);};
    input.addEventListener('change', () => finish(input.files[0]), {once: true});
    input.addEventListener('cancel', () => finish(), {once: true});
    if (input.showPicker) input.showPicker();
    else input.click();
  });
}

function fileBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = () => reject(new Error('无法读取所选文件。'));
    reader.readAsDataURL(file);
  });
}

async function previewBackupFile(mode) {
  const restoring = mode === 'restore';
  const file = await selectFile(restoring ? '.zip,application/zip' : '.json,application/json');
  if (!file) return {ok: true, cancelled: true};
  if (file.size > 30 * 1000 * 1000) throw new Error('所选文件超过 30 MB。');
  if (restoring) return portalAPI('/api/backup/zip-preview', {zipBase64: await fileBase64(file)});
  return portalAPI('/api/backup/preview', {library: await readBackupJson(file), mode});
}

async function readBackupJson(file) {
  if (file.size > 30 * 1000 * 1000) throw new Error('所选文件超过 30 MB。');
  try {
    return JSON.parse((await file.text()).replace(/^\uFEFF/, ''));
  } catch {
    throw new Error('JSON 格式无效，请选择搞门户模块备份。');
  }
}

async function saveBackupFile(format) {
  const zip = format === 'zip';
  const filename = zip ? '搞门户-当前资料.zip' : '搞门户-模块备份.json';
  let filenameHandle;
  if ('showSaveFilePicker' in window && !window.pywebview?.api) {
    try {
      filenameHandle = await window.showSaveFilePicker({
        suggestedName: filename,
        types: [{description: zip ? '搞门户完整资料' : '搞门户模块资料', accept: {
          [zip ? 'application/zip' : 'application/json']: [zip ? '.zip' : '.json']
        }}]
      });
    } catch (error) {
      if (error.name === 'AbortError') return;
      if (error.name !== 'SecurityError') throw error;
    }
  }
  const result = await portalAPI(zip ? '/api/backup/zip' : '/api/backup/export', {});
  const blob = zip ? new Blob([Uint8Array.from(atob(result.zipBase64), char => char.charCodeAt(0))], {type:'application/zip'})
    : new Blob([JSON.stringify(result.library, null, 2) + '\n'], {type:'application/json'});
  if (await saveLocalFile(format, filename, blob, filenameHandle)) toast('资料已导出。');
}

async function saveLocalFile(format, filename, blob, filenameHandle) {
  const host = window.pywebview?.api;
  if (host?.save_file) {
    const saved = await host.save_file(format, filename, await fileBase64(blob));
    if (typeof saved === 'string') throw new Error(saved);
    return saved;
  } else if (filenameHandle) {
    const output = await filenameHandle.createWritable();
    await output.write(blob);
    await output.close();
  } else {
    const link = document.createElement('a');
    link.download = filename;
    link.href = URL.createObjectURL(blob);
    link.click();
    setTimeout(() => URL.revokeObjectURL(link.href), 30000);
  }
  return true;
}

async function applyButton(button, action, success) {
  button.disabled = true;
  pendingPortalActions++;
  try {
    const result = await action();
    toast(result?.message || success);
    return result;
  } catch (error) {
    toast(error.message);
  } finally {
    pendingPortalActions--;
    if (button.isConnected) button.disabled = false;
  }
}

const preferenceTabs = [['modules', '功能'], ['browsers', '浏览器'], ['appearance', '外观'], ['data', '资料与交接']];
const preferenceScroll = new Map();
let preferenceWrites = Promise.resolve();
let preferenceWriteID = 0;
let preferenceFeedback = {text: '', kind: ''};

function settingGroup(title, rows, description = '') {
  return '<section class="setting-group"><header><h3>' + esc(title) + '</h3>'
    + (description ? '<p>' + esc(description) + '</p>' : '') + '</header><div>' + rows.join('') + '</div></section>';
}

function settingChoice(id, title, choices, selected) {
  return '<label class="setting-row"><strong>' + esc(title) + '</strong><select class="compact-select" id="' + id + '">'
    + choices.map(([value, label]) => '<option value="' + value + '"' + (String(selected) === String(value) ? ' selected' : '') + '>' + esc(label) + '</option>').join('')
    + '</select></label>';
}

function settingButton(id, label) {
  return '<button type="button" class="soft-button" id="' + id + '">' + esc(label) + '</button>';
}

const diagnosticStates = new Map([['connected', '已连接'], ['attention', '需处理'], ['indeterminate', '未能确认']]);
const diagnosticChecks = new Map([['ok', '已验证'], ['issue', '需检查'], ['unknown', '未能确认']]);
const diagnosticStages = [['browser', '浏览器程序'], ['package', '随包助手'], ['registration', 'Windows 主机登记'], ['extension', '浏览器扩展']];

function diagnosticProfileAge(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '本次检测确认';
  if (seconds < 10) return '刚刚';
  if (seconds < 60) return Math.floor(seconds) + ' 秒前';
  return Math.floor(seconds / 60) + ' 分钟前';
}

function diagnosticCard(browser, result) {
  const state = diagnosticStates.has(result.state) ? result.state : 'indeterminate';
  const issues = diagnosticStages.filter(([key]) => result[key]?.status === 'issue').map(([, title]) => title);
  const stages = diagnosticStages.map(([key, title]) => {
    const item = result[key];
    const status = diagnosticChecks.has(item?.status) ? item.status : 'unknown';
    return '<div class="diagnostic-evidence"><dt>' + title + '</dt><dd><span data-status="' + status + '">'
      + diagnosticChecks.get(status) + '</span><p>' + esc(item?.detail || '本次未取得该项信息。') + '</p></dd></div>';
  }).join('');
  const profiles = Array.isArray(result.profiles) ? result.profiles : [];
  const recent = profiles.length ? '<ul class="diagnostic-profiles">' + profiles.map(profile => '<li><span>'
    + esc(profile.label || '默认资料') + '</span><small>' + diagnosticProfileAge(profile.ageSeconds) + '</small></li>').join('') + '</ul>'
    : '<p class="diagnostic-help">本次未收到资料连接。每个资料都需要单独启用助手。</p>';
  let repair = '';
  if (result.browser?.status === 'issue') {
    repair = '如果尚未安装，请通过浏览器的官方渠道手动安装，完成后重新检测。';
  } else if (result.package?.status === 'issue' || result.registration?.status === 'issue') {
    repair = '可用搞门户的 Windows 安装包手动覆盖安装，勾选「注册 Chrome 和 Edge 的搞门户助手」，完成后重新检测。';
  } else if (state !== 'connected') {
    repair = '在要连接的浏览器资料中确认助手已启用，打开助手弹窗并点「重新连接」，然后返回重新检测。';
  }
  const manage = result.browser?.status === 'ok'
    ? '<button type="button" class="soft-button" data-diagnostic-browser="' + browser.id + '">打开 ' + esc(browser.name) + ' 扩展管理…</button>'
    : '';
  return '<section class="diagnostic-card" data-browser="' + browser.id + '" aria-labelledby="diagnostic-' + browser.id + '">'
    + '<div class="diagnostic-card-title"><h4 id="diagnostic-' + browser.id + '">' + esc(browser.name) + '</h4>'
    + '<span class="diagnostic-state" data-state="' + state + '">' + diagnosticStates.get(state) + '</span></div>'
    + '<p class="diagnostic-summary">' + esc(result.summary || '本次未取得连接结论。') + '</p>'
    + (issues.length ? '<p class="diagnostic-issues">需检查 ' + issues.join('、') + '</p>' : '')
    + (manage ? '<div class="diagnostic-actions">' + manage + '</div>' : '')
    + '<h5>近期连接资料' + (profiles.length ? '（' + profiles.length + '）' : '') + '</h5>' + recent
    + '<details><summary>检测依据</summary><dl>' + stages + '</dl></details>'
    + (repair ? '<p class="diagnostic-help">' + esc(repair) + '</p>' : '') + '</section>';
}

function bindBrowserDiagnostics() {
  const panel = $('browserDiagnostics');
  const status = $('diagnosticStatus');
  const results = $('diagnosticResults');
  const retry = $('diagnosticRetry');
  const folder = $('extensionFolder');
  let checking = false;
  let folderAvailable = false;
  async function inspect() {
    if (checking) return;
    checking = true;
    status.dataset.kind = '';
    status.textContent = '正在检测浏览器连接…';
    results.setAttribute('aria-busy', 'true');
    retry.setAttribute('aria-disabled', 'true');
    try {
      const {browsers} = await portalAPI('/api/browser/diagnostics', {}, false);
      if (!panel.isConnected) return;
      if (!Array.isArray(browsers)) throw new Error('检测结果不完整，请重新检测。');
      const cards = browserCatalog.filter(browser => browser.supportsFill).map(browser => [browser, browsers.find(row => row?.id === browser.id)]);
      if (cards.some(([, result]) => !result)) throw new Error('检测结果不完整，请重新检测。');
      const expanded = new Set([...results.querySelectorAll('details[open]')].map(details => details.closest('[data-browser]').dataset.browser));
      results.innerHTML = cards.map(([browser, result]) => diagnosticCard(browser, result)).join('');
      for (const details of results.querySelectorAll('details')) details.open = expanded.has(details.closest('[data-browser]').dataset.browser);
      folderAvailable = cards.some(([, result]) => result.package?.status === 'ok');
      folder.disabled = !folderAvailable;
      status.textContent = '本次检测已完成。';
    } catch (error) {
      if (!panel.isConnected) return;
      results.replaceChildren();
      folderAvailable = false;
      folder.disabled = true;
      status.dataset.kind = 'error';
      status.textContent = error instanceof TypeError ? '无法获取检测结果，请重新检测。' : error.message;
    } finally {
      checking = false;
      if (panel.isConnected) {
        retry.removeAttribute('aria-disabled');
        results.setAttribute('aria-busy', 'false');
      }
    }
  }
  retry.onclick = inspect;
  results.addEventListener('click', event => {
    const button = event.target.closest('[data-diagnostic-browser]');
    if (!button) return;
    applyButton(button, () => portalAPI('/api/browser/extensions', {browserID: button.dataset.diagnosticBrowser}),
      '已请求打开扩展管理。完成检查后请返回重新检测。');
  });
  folder.onclick = async () => {
    if (!folderAvailable) return;
    await applyButton(folder, () => portalAPI('/api/browser/extensions'));
    folder.disabled = !folderAvailable;
  };
  void inspect();
}

function settingsContent(tab) {
  const row = (label, value) => '<div class="setting-row"><strong>' + esc(label) + '</strong><span>' + esc(value) + '</span></div>';
  const buttonRow = (...buttons) => '<div class="setting-row settings-buttons">' + buttons.join('') + '</div>';
  if (tab === 'browsers') {
    return '<section class="setting-group browser-diagnostics" id="browserDiagnostics"><div class="diagnostic-header">'
      + '<header><h3>连接诊断</h3><p>使用本机登记、随包文件和助手报告的近期连接来判断。</p></header>'
      + '<div class="diagnostic-actions">' + settingButton('diagnosticRetry', '重新检测')
      + '<button type="button" class="soft-button" id="extensionFolder" disabled>打开助手文件夹</button></div></div>'
      + '<p id="diagnosticStatus" role="status"></p><div id="diagnosticResults" aria-busy="false"></div>'
      + '<details class="diagnostic-setup"><summary>首次连接浏览器资料</summary>'
      + '<p>在要使用的浏览器资料中打开扩展管理并启用开发者模式。点击「打开助手文件夹」查看目录，然后在浏览器里选择「加载已解压的扩展程序」。打开助手弹窗并点「重新连接」，再返回这里检测。</p></details></section>';
  }
  if (tab === 'appearance') {
    return settingGroup('窗口主题', [
      settingChoice('settingsAppearance', '主题', [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']], S.library.appearance)
    ], '适用于启动台与搞门户设置。') + settingGroup('应用信息', [row('语言', '简体中文'), row('版本', 'V' + S.version)]);
  }
  if (tab === 'data') {
    return settingGroup('当前资料', [
      buttonRow(settingButton('exportZip', '导出当前资料…'), settingButton('restoreZip', '从资料恢复…'))
    ], 'ZIP 保留网站、图标、文件夹、场景、账号资料及外观。密码留在当前 Windows 用户的凭据库。') + settingGroup('JSON 格式', [
      buttonRow(settingButton('exportJson', '导出 JSON…'), settingButton('mergeJson', '导入 JSON…'), settingButton('restoreJson', '恢复 JSON…'))
    ], '可合并导入，也可在恢复前查看预览。') + settingGroup('跨 App 交接', [
      buttonRow(settingButton('openActionPackage', '打开交接包…'), settingButton('actionHistory', '查看交接结果…'), settingButton('sendDownloadAction', '交接下载网址…')),
      buttonRow(settingButton('exportSitesCatalog', '导出授权网站目录…'), settingButton('exportWorkspacesCatalog', '导出授权场景目录…'))
    ]) + settingGroup('数据目录', [buttonRow(settingButton('revealData', '打开数据目录'))]);
  }
  return settingGroup('启动台', [
    settingChoice('settingsDensity', '排列密度', [['comfortable', '宽松'], ['compact', '紧凑']], S.library.layoutDensity || 'compact'),
    settingChoice('settingsIconSize', '图标大小', [[60, '小'], [76, '标准'], [92, '大']], S.library.iconSize || 76),
    buttonRow(settingButton('importBookmarks', '导入浏览器收藏…'), settingButton('refreshIcons', '刷新网站图标')),
    buttonRow(settingButton('archivedSites', '查看已移除的网站…'))
  ]) + settingGroup('浏览器助手', [
    buttonRow(settingButton('browserDiagnosticsLink', '查看浏览器连接…'))
  ], '每个浏览器资料需单独连接，才能自动填充。') + settingGroup('悬浮窗', [
    '<label class="setting-row"><strong>显示悬浮窗</strong><input type="checkbox" role="switch" id="settingsDockEnabled"></label>',
    settingChoice('settingsDock', '停靠位置', [['left', '左侧'], ['right', '右侧'], ['none', '自由浮动']], S.floating.dock),
    buttonRow(settingButton('resetDock', '重置位置'), '<span class="settings-key"><kbd>Ctrl</kbd><kbd>Alt</kbd><kbd>P</kbd> 显示或隐藏</span>')
  ], '悬停或点击展开，移开后收起。可拖到屏幕两侧吸附。') + settingGroup('下载与邮件', [
    '<div class="setting-row"><strong>下载中心</strong>' + settingButton('settingsDownloads', '打开下载队列…') + '</div>',
    '<div class="setting-row"><strong>邮件中心</strong><div class="setting-actions">' + settingButton('settingsMail', '打开邮件…')
    + settingButton('settingsMailPreferences', '邮件设置…') + '</div></div>'
  ]) + settingGroup('账号库', [
    '<div class="setting-row"><strong id="settingsLockState"></strong>' + settingButton('settingsLock', '锁定账号库') + '</div>'
  ], '密码由 Windows 凭据保护。解锁 5 分钟后自动锁定。');
}

function refreshSettingsState(force = false) {
  if (!$('launcherSettingsTabs')) return;
  if ($('settingsDockEnabled')) $('settingsDockEnabled').checked = S.floating.enabled;
  if ($('settingsDock')) $('settingsDock').value = S.floating.dock || 'right';
  if ($('settingsLock')) {
    $('settingsLock').disabled = !S.unlocked;
    $('settingsLockState').textContent = S.unlocked ? '已解锁' : '已锁定';
  }
  if ($('preferencesRecovery')) {
    $('preferencesRecovery').hidden = currentAccess === 'ready' || !S.recoveryMessage;
    $('preferencesRecovery').textContent = S.recoveryMessage || '';
  }
  for (const [id, value] of [
    ['settingsAppearance', S.library.appearance],
    ['settingsDensity', S.library.layoutDensity || 'compact'],
    ['settingsIconSize', S.library.iconSize || 76]
  ]) {
    if ($(id) && (force || $(id) !== document.activeElement)) $(id).value = value;
  }
  for (const id of ['settingsAppearance', 'settingsDensity', 'settingsIconSize', 'importBookmarks', 'refreshIcons',
      'exportZip', 'restoreZip', 'exportJson', 'mergeJson', 'restoreJson', 'exportSitesCatalog', 'exportWorkspacesCatalog']) {
    if ($(id)) $(id).disabled = currentAccess !== 'ready';
  }
}

function setPreferenceFeedback(text, kind) {
  preferenceFeedback = {text, kind};
  if (!$('preferencesStatus')) return;
  $('preferencesStatus').textContent = text;
  $('preferencesStatus').dataset.kind = kind;
}

function savePreference(action) {
  const id = ++preferenceWriteID;
  setPreferenceFeedback('正在保存…', 'busy');
  preferenceWrites = preferenceWrites.then(action).then(() => {
    if (id === preferenceWriteID) setPreferenceFeedback('设置已保存', 'saved');
  }).catch(error => {
    if (id === preferenceWriteID) {
      setPreferenceFeedback(error.message, 'error');
      refreshSettingsState(true);
    }
  }).finally(refreshSettingsState);
  return preferenceWrites;
}

function markSettingsSurface() {
  const root = $('dialog');
  root.classList.add('launcher-settings');
  if (settingsWindow) {
    root.removeAttribute('aria-modal');
    root.setAttribute('role', 'main');
  }
}

async function loadSettingsWindow() {
  document.body.classList.toggle('dark', matchMedia('(prefers-color-scheme: dark)').matches);
  openDialog('<div class="preferences-layout" id="preferencesStartup"><header class="preferences-header"><h2>设置</h2></header>'
    + '<div class="preferences-startup"><p id="settingsStartupStatus" role="status">正在读取设置…</p>'
    + '<button id="settingsRetry" type="button" class="soft-button" hidden>重试</button></div></div>');
  markSettingsSurface();
  try {
    const result = await portalAPI('/api/launcher/state');
    if (!S) throw new Error('无法读取设置，请重试。');
    renderWindowsSettings();
    return result;
  } catch (error) {
    const status = $('settingsStartupStatus');
    const retry = $('settingsRetry');
    status.setAttribute('role', 'alert');
    status.textContent = '无法读取设置。' + (error instanceof TypeError ? '' : error.message);
    retry.hidden = false;
    retry.onclick = loadSettingsWindow;
    retry.focus();
  }
}

const compactSettingsLayout = matchMedia('(max-width: 530px)');
compactSettingsLayout.addEventListener('change', event => {
  $('launcherSettingsTabs')?.setAttribute('aria-orientation', event.matches ? 'horizontal' : 'vertical');
});

function renderWindowsSettings(tab = settingsTab) {
  if (!S) return;
  const root = $('dialog');
  const previous = root.querySelector('.settings-pane');
  if (previous) preferenceScroll.set(settingsTab, previous.scrollTop);
  settingsTab = tab;
  const heading = '<header class="preferences-header"><h2 id="preferencesTitle">设置</h2>'
    + (settingsWindow ? '' : '<button type="button" class="icon-button close" data-close aria-label="关闭设置">×</button>') + '</header>';
  const navigation = '<nav class="settings-tabs" id="launcherSettingsTabs" role="tablist" aria-label="设置类别" aria-orientation="'
    + (compactSettingsLayout.matches ? 'horizontal' : 'vertical') + '">'
    + preferenceTabs.map(([key, label]) => '<button type="button" role="tab" id="settings-tab-' + key + '" data-settings-tab="' + key
      + '" aria-controls="launcherSettingsPane" aria-selected="' + (key === tab) + '" tabindex="' + (key === tab ? 0 : -1) + '">' + label + '</button>').join('') + '</nav>';
  const content = '<div class="settings-pane" id="launcherSettingsPane" role="tabpanel" aria-labelledby="settings-tab-' + tab + '">'
    + '<p class="preferences-recovery" id="preferencesRecovery" role="status" hidden></p>'
    + '<div class="preferences-groups" data-kind="' + tab + '">' + settingsContent(tab) + '</div></div>';
  openDialog('<div class="preferences-layout">' + heading + '<div class="preferences-main">' + navigation + content
    + '</div><footer class="preferences-footer"><span id="preferencesStatus" role="status" aria-live="polite"></span></footer></div>');
  markSettingsSurface();
  root.querySelector('.settings-pane').scrollTop = preferenceScroll.get(tab) || 0;
  setPreferenceFeedback(preferenceFeedback.text, preferenceFeedback.kind);
  root.querySelectorAll('[data-settings-tab]').forEach(button => {
    button.onclick = () => renderWindowsSettings(button.dataset.settingsTab);
    button.onkeydown = event => {
      const buttons = Array.from(button.parentElement.querySelectorAll('button'));
      const i = buttons.indexOf(button);
      const edge = {Home: 0, End: buttons.length - 1}[event.key];
      const shift = {ArrowLeft: -1, ArrowUp: -1, ArrowRight: 1, ArrowDown: 1}[event.key];
      if (edge === undefined && shift === undefined) return;
      event.preventDefault();
      const next = edge ?? ((i + shift + buttons.length) % buttons.length);
      renderWindowsSettings(buttons[next].dataset.settingsTab);
    };
  });
  const bind = (id, action, success) => {
    const button = $(id);
    if (button) button.onclick = () => applyButton(button, action, success);
  };
  const preferences = () => {
    const values = {layoutDensity: $('settingsDensity').value, iconSize: Number($('settingsIconSize').value)};
    return savePreference(() => portalAPI('/api/preferences', values));
  };
  if (tab === 'modules') {
    $('settingsDensity').onchange = preferences;
    $('settingsIconSize').onchange = preferences;
    bind('importBookmarks', showBookmarkSources);
    bind('archivedSites', () => showVault(true));
    bind('refreshIcons', () => native('refreshIcon'));
    $('browserDiagnosticsLink').onclick = () => renderWindowsSettings('browsers');
    const floating = async change => {
      try {
        const result = await portalAPI('/api/floating', change);
        S.floating = result.floating;
      } finally {
        refreshSettingsState();
      }
    };
    $('settingsDockEnabled').onchange = event => {
      const enabled = event.target.checked;
      savePreference(() => floating({enabled}));
    };
    $('settingsDock').onchange = event => {
      const dock = event.target.value;
      savePreference(() => floating({dock}));
    };
    bind('resetDock', () => floating({reset: true, enabled: true}), '悬浮窗位置已重置。');
    bind('settingsDownloads', () => native('openDownloads'));
    bind('settingsMail', () => native('openMail'));
    bind('settingsMailPreferences', () => openPortalWindow('/mail#settings'));
    bind('settingsLock', () => native('lock'), '账号库已锁定。');
  }
  if (tab === 'browsers') bindBrowserDiagnostics();
  if (tab === 'appearance') $('settingsAppearance').onchange = event => {
    const appearance = event.target.value;
    savePreference(() => portalAPI('/api/appearance', {appearance}));
  };
  if (tab === 'data') {
    bind('exportZip', () => saveBackupFile('zip'));
    bind('restoreZip', () => startBackupPreview('restore'));
    bind('exportJson', () => saveBackupFile('json'));
    bind('mergeJson', () => startBackupPreview('merge'));
    bind('restoreJson', () => restoreJsonBackup());
    bind('openActionPackage', chooseActionPackage);
    bind('actionHistory', showActionHistory);
    bind('sendDownloadAction', showSendDownloadAction);
    bind('exportSitesCatalog', () => chooseCatalog('sites'));
    bind('exportWorkspacesCatalog', () => chooseCatalog('workspaces'));
    bind('revealData', () => portalAPI('/api/launcher/data-directory'));
  }
  refreshSettingsState();
}

async function restoreJsonBackup() {
  const file = await selectFile('.json,application/json');
  if (!file) return;
  const library = await readBackupJson(file);
  const result = await portalAPI('/api/backup/preview', {library, mode:'restore'});
  showImportPreview(result, 'applyBackup', '恢复模块备份', true);
}

async function chooseActionPackage() {
  const host = window.pywebview?.api;
  if (host?.choose_folder) {
    const path = await host.choose_folder();
    if (path) await openActionPackage(path);
    return;
  }
  openDialog(head('', '打开跨 App 交接包', '填写本机 .gaoaction 文件夹的路径。')
    + '<label class="field"><span class="field-label">交接包路径</span><input id="actionPath" type="text"></label>'
    + '<div class="dialog-actions"><button class="soft-button" data-close>取消</button><button id="actionAccept" class="primary-button">打开</button></div>', true);
  $('actionAccept').onclick = event => applyButton(event.currentTarget, async () => {
    const path = $('actionPath').value.trim();
    if (!path) throw new Error('请填写交接包路径。');
    await openActionPackage(path);
  });
}

async function openActionPackage(path) {
  const result = await portalAPI('/api/actions/open', {path});
  if (result.path) return openPortalWindow(result.path);
  if (result.review) return showActionReview(result.review);
  if (result.record) return showActionHistory(result.record.id);
}

const actionNames = {
  'portal.openSite': '打开网站', 'portal.openWorkspace': '打开工作场景', 'portal.focusSearch': '打开搜索',
  'portal.proposeSite': '建议添加网站', 'portal.prepareDownload': '复核下载链接', 'downloads.prepare': '文件下载'
};
const actionStates = {
  awaitingUser:'等待复核', executing:'正在执行', awaitingEditor:'等待保存网站', awaitingDownload:'等待复核下载',
  accepted:'已接收任务', handedOff:'等待接收回执', opened:'已打开', completed:'已完成', partial:'部分完成',
  failed:'失败', cancelled:'已取消', unsupported:'接收方不支持', expired:'投递期限已过'
};

function actionState(record) {
  if (record.sendState === 'expired') return actionStates.expired;
  if (record.status === 'partial') return actionStates.partial;
  return actionStates[record.workflowState] || record.status;
}

function showActionReview(review) {
  if (activeActionReview === review.id) return;
  activeActionReview = review.id;
  const isResult = review.kind === 'result';
  const detail = isResult
    ? '<p>关联请求 ' + esc(review.inReplyTo) + '</p><p>状态 ' + esc(actionStates[review.status] || review.status)
      + ' · 已核验 ' + review.fileCount + ' 个文件。确认后记录私有副本。</p>'
    : '<ul>' + review.summary.filter(Boolean).map(line => '<li>' + esc(line) + '</li>').join('') + '</ul>';
  openDialog(head('', isResult ? '复核下载回送' : '复核跨 App 请求',
    '来源声明 ' + review.source + '。来源标识用于关联。')
    + '<p>' + esc(actionNames[review.action] || review.action) + '</p>' + detail
    + '<p id="actionReviewIssue" role="status"></p>'
    + '<div class="dialog-actions"><button id="cancelActionReview" class="soft-button">取消</button>'
    + '<button id="approveActionReview" class="primary-button">' + (isResult ? '接纳并记录结果' : '确认执行') + '</button></div>', true);
  async function decide(approve) {
    const ok = $('approveActionReview');
    const cancel = $('cancelActionReview');
    ok.disabled = cancel.disabled = true;
    try {
      const response = await launchWithVault('/api/actions/decide', {id: review.id, approve});
      activeActionReview = null;
      closeDialog();
      if (response.path) await openPortalWindow(response.path);
      else if (approve && !isResult && settingsWindow) await openPortalWindow('/');
      toast(approve ? (isResult ? '已记录下载回执或结果。' : '已确认交接。可在数据设置查看处理状态。') : '已取消交接。');
    } catch (error) {
      if (['expired', 'review_unavailable', 'input_changed'].includes(error.code)) {
        activeActionReview = null;
        closeDialog();
        toast(error.message);
      } else {
        $('actionReviewIssue').textContent = error.message;
        ok.disabled = cancel.disabled = false;
      }
    }
  }
  $('approveActionReview').onclick = () => decide(true);
  $('cancelActionReview').onclick = () => decide(false);
}

async function showActionHistory(selected) {
  const history = await portalAPI('/api/actions/history', {}, false);
  const rows = history.records.slice(0, 200);
  const warnings = history.unavailable.map(category => category === 'portal' ? '网站动作历史暂不可读。' : '下载交接历史暂不可读。');
  openDialog(head('', '交接结果', '请求交付、任务接收和完成文件分别记录。')
    + (warnings.length ? '<p role="alert">' + warnings.join(' ') + '</p>' : '')
    + (rows.length ? '<label class="field"><span class="field-label">最近交接</span><select id="actionHistoryChoice">'
      + rows.map(row => '<option value="' + esc(row.id) + '">' + esc((actionNames[row.action] || row.action)
        + ' · ' + actionState(row) + ' · ' + row.id.slice(0, 8)) + '</option>').join('') + '</select></label>'
      + '<div id="actionHistoryDetail"></div>' : '<p>暂无交接结果。</p>')
    + '<div class="dialog-actions"><button class="soft-button" data-close>关闭</button></div>', true);
  if (!rows.length) return;
  const choice = $('actionHistoryChoice');
  if (rows.some(row => row.id === selected)) choice.value = selected;
  function detail() {
    const record = rows.find(row => row.id === choice.value);
    if (!record) return;
    const deliverable = record.direction === 'request' && (record.status !== 'pending' || record.workflowState === 'accepted');
    const retry = record.direction === 'outgoing' && record.status === 'pending' && record.sendState !== 'expired' && !record.deliveries?.length;
    const sites = (record.sites || []).map(item => '<li>' + esc((siteById(item.siteID)?.name || item.siteID) + ' · ' +
      (actionStates[item.workflowState] || item.workflowState) + (item.errorCode ? ' · ' + item.errorCode : '')) + '</li>').join('');
    $('actionHistoryDetail').innerHTML = '<p>' + esc(actionState(record)) + '</p><p>'
      + esc(record.sourceBundleID + ' → ' + record.targetBundleID) + '</p>'
      + (record.errorCode ? '<p>错误编号 ' + esc(record.errorCode) + '</p>' : '')
      + (sites ? '<ul>' + sites + '</ul>' : '')
      + (record.taskIDs?.length ? '<p>' + record.taskIDs.length + ' 项任务 · ' + (record.fileCount || 0) + ' 个已核验文件副本</p>' : '')
      + (record.deliveries?.length ? '<p>' + esc(record.deliveries.map(delivery => actionStates[delivery.status] || delivery.status).join(' → ')) + '</p>' : '')
      + '<div class="dialog-actions">' + (deliverable ? settingButton('saveActionResult', '保存结果包…')
          + settingButton('sendActionResult', '发送结果…') : '')
      + (record.fileCount ? settingButton('revealActionResult', '显示已核验副本') : '')
      + (retry ? settingButton('retryActionRequest', '重新投递') : '') + '</div>';
    if ($('saveActionResult')) $('saveActionResult').onclick = event => applyButton(event.currentTarget, async () => {
      const path = window.pywebview?.api?.choose_folder ? await window.pywebview.api.choose_folder() : window.prompt('保存 .gaoaction 文件夹的目录');
      if (path) await portalAPI('/api/actions/publish', {id: record.id, path}, false);
    });
    if ($('sendActionResult')) $('sendActionResult').onclick = event => applyButton(event.currentTarget, async () => {
      if (!window.confirm('将结果发回 ' + record.sourceBundleID + '？结果不含密码或浏览器资料。')) return;
      const result = await portalAPI('/api/actions/publish', {id: record.id, send: true}, false);
      return {message: result.deliveryError ? result.deliveryError + ' 结果包已保存。' : '结果已交给接收方。'};
    });
    if ($('revealActionResult')) $('revealActionResult').onclick = event => applyButton(event.currentTarget,
      () => portalAPI('/api/actions/reveal', {id: record.id}, false));
    if ($('retryActionRequest')) $('retryActionRequest').onclick = event => applyButton(event.currentTarget,
      () => portalAPI('/api/actions/resend', {id: record.id}, false));
  }
  choice.onchange = detail;
  detail();
}

async function showSendDownloadAction() {
  const {providers} = await portalAPI('/api/actions/providers', {}, false);
  openDialog(head('', '交接下载网址', '接收方须已安装并声明文件下载能力。发送后仍须在接收方复核。')
    + (!providers.length ? '<p>尚未找到兼容的接收方，可从下载中心选择本地下载。</p>' :
      '<label class="field"><span class="field-label">接收方</span><select id="actionDownloadTarget">'
      + providers.map(provider => '<option value="' + esc(provider.bundleID) + '">' + esc(provider.bundleID + ' V' + provider.version) + '</option>').join('')
      + '</select></label><label class="field"><span class="field-label">每行一个 HTTP 或 HTTPS 链接</span><textarea rows="5" id="actionDownloadURLs"></textarea></label>'
      + '<label class="field"><span class="field-label">链接隐私</span><select id="actionDownloadPrivacy"><option value="strip">去除查询参数和片段</option>'
      + '<option value="keep">保留查询参数</option></select></label>')
    + '<div class="dialog-actions"><button class="soft-button" data-close>取消</button>'
    + (providers.length ? '<button id="actionDownloadSend" class="primary-button">确认交接</button>' : '') + '</div>', true);
  if ($('actionDownloadSend')) $('actionDownloadSend').onclick = event => applyButton(event.currentTarget, async () => {
    const result = await portalAPI('/api/actions/send', {target: $('actionDownloadTarget').value,
      urls: $('actionDownloadURLs').value.split(/\r?\n/).map(line => line.trim()).filter(Boolean), privacy: $('actionDownloadPrivacy').value}, false);
    closeDialog();
    return result;
  });
}

async function pollActionQueue() {
  if (settingsWindow || checkingActions || !S || launcherHidden() || !$('dialogOverlay').hidden) return;
  checkingActions = true;
  try {
    const result = await portalAPI('/api/actions/queue', {}, false);
    if (launcherHidden() || !$('dialogOverlay').hidden) return;
    if (result.notice) {
      if (result.notice.error) toast(result.notice.error);
      else if (result.notice.path) await openPortalWindow(result.notice.path);
      else if (result.notice.record) await showActionHistory(result.notice.record.id);
      await portalAPI('/api/actions/ack-notice', {id: result.notice.noticeID}, false);
    } else if (result.review) showActionReview(result.review);
  } finally { checkingActions = false; }
}

function chooseCatalog(kind) {
  const workspaces = kind === 'workspaces';
  const entries = workspaces ? S.library.workspaces || [] : S.library.sites.filter(site => visibleIDs().has(site.id));
  const object = workspaces ? '场景' : '网站';
  const description = '只导出你明确选中的' + object + '名称和标识。';
  const picker = entries.length ? '<div class="workspace-picker">'
    + entries.map(entry => '<label class="workspace-choice"><input name="catalogID" type="checkbox" value="' + esc(entry.id) + '"><span>'
      + esc(entry.name) + '</span></label>').join('') + '</div>'
    : '<p class="empty-accounts">还没有可授权的' + object + '。</p>';
  openDialog(head('', '导出授权' + object + '目录', description) + picker
    + '<div class="dialog-actions"><button class="soft-button" data-close>取消</button><button id="catalogSave" class="primary-button"'
    + (entries.length ? '' : ' disabled') + '>导出目录</button></div>');
  $('catalogSave').onclick = event => applyButton(event.currentTarget, async () => {
    const ids = Array.from(document.querySelectorAll('input[name="catalogID"]:checked'), input => input.value);
    if (!ids.length) throw new Error('请至少选择一个' + object + '。');
    const result = await portalAPI('/api/actions/catalog', {kind, ids});
    const blob = new Blob([JSON.stringify(result.catalog, null, 2) + '\n'], {type:'application/json'});
    if (await saveLocalFile('json', '搞门户-授权' + object + '目录.json', blob)) {
      closeDialog();
      toast('授权目录已导出。');
    }
  });
}

const closeMacDialog = closeDialog;
closeDialog = function closeWindowsDialog() {
  const leavingSettings = Boolean($('launcherSettingsTabs') || $('preferencesStartup'));
  if (activeActionReview) {
    const id = activeActionReview;
    activeActionReview = null;
    portalAPI('/api/actions/decide', {id, approve:false}, false).catch(logBackgroundIssue);
  }
  closeMacDialog();
  if (!settingsWindow) return;
  if (leavingSettings) {
    const host = window.pywebview?.api;
    if (host?.close_window) host.close_window();
    else location.replace('/');
  } else renderWindowsSettings();
};

function handlePortalEvents(state) {
  if (settingsWindow) return;
  if (state.focusRequestID && state.focusRequestID !== lastAppliedQuery && window.portalApplySearch(state.focusQuery || '')) {
    lastAppliedQuery = state.focusRequestID;
    portalAPI('/api/launcher/acknowledge', {requestID: state.focusRequestID}, false).catch(logBackgroundIssue);
  }
  const proposed = state.proposal;
  if (proposed?.requestID && proposed.requestID !== lastProposal &&
      window.portalProposeSite(proposed.url, proposed.title, proposed.requestID)) {
    lastProposal = proposed.requestID;
  }
  const feedback = Object.values(state.launchFeedback || {});
  if (previousFeedback && feedback.length) {
    const fresh = feedback.filter(item => !previousFeedback.includes(JSON.stringify(item)));
    const last = fresh.at(-1);
    const message = typeof last === 'string' ? last : last?.message;
    if (message) toast(message);
  }
  previousFeedback = feedback.map(item => JSON.stringify(item));
}

function logBackgroundIssue(error) {
  console.warn('Windows launcher:', error.message);
}

async function pollLauncherRuntime() {
  if (!S || launcherHidden() || drag) return;
  const live = await portalAPI('/api/launcher/runtime', {}, false);
  if (launcherHidden()) return;
  if (live.revision !== libraryRevision || live.access !== currentAccess) {
    const latest = await portalAPI('/api/launcher/state', {}, false);
    if (!launcherHidden()) applyPortalState(latest);
    return;
  }
  if (S.unlocked !== live.vaultUnlocked) {
    S.unlocked = live.vaultUnlocked;
    renderLock();
  }
  const previousProfiles = S.profiles;
  S.profiles = profileOptions(live.profiles);
  S.floating = live.floating;
  S.browsers.forEach(browser => browser.installed = live.installedBrowsers.includes(browser.id));
  if (draft && $('profileFields') && !$('profileFields').contains(document.activeElement) &&
      JSON.stringify(previousProfiles) !== JSON.stringify(S.profiles)) renderBrowserOptions();
  refreshSettingsState();
  handlePortalEvents(live);
}

function scheduleLauncherPoll(poll, interval) {
  let timer;
  let running = false;
  async function run() {
    if (running || launcherHidden()) return;
    running = true;
    try {
      await poll();
    } catch (error) {
      logBackgroundIssue(error);
    } finally {
      running = false;
      if (!launcherHidden()) timer = setTimeout(run, interval);
    }
  }
  launcherPolls.push(() => {
    clearTimeout(timer);
    void run();
  });
  void run();
}

document.addEventListener('keydown', event => {
  if (!S || !event.ctrlKey || event.isComposing) return;
  const key = event.key.toLowerCase();
  if (key === ',' && !settingsWindow) {
    event.preventDefault();
    native('openSettings').catch(error => toast(error.message));
  }
  if (key === 's' && event.altKey && $('dialogOverlay').hidden) {
    event.preventDefault();
    toggleSidebar();
  }
  if (key === 'n' && !event.altKey && currentAccess === 'ready' && $('dialogOverlay').hidden) {
    event.preventDefault();
    $('addButton').click();
  }
  if (key === 'w' && settingsWindow && window.pywebview?.api?.close_window) {
    event.preventDefault();
    window.pywebview.api.close_window();
  }
  if (key === 'w' && !settingsWindow && window.pywebview?.api?.close_window) {
    event.preventDefault();
    if (!$('dialogOverlay').hidden) closeDialog();
    else window.pywebview.api.close_window();
  }
  if (key === 'p' && event.altKey && !event.shiftKey) {
    event.preventDefault();
    portalAPI('/api/floating', {enabled: !S.floating.enabled}).then(result => {
      S.floating = result.floating;
      refreshSettingsState();
    }).catch(error => toast(error.message));
  }
  if (event.shiftKey && !event.altKey && ['d', 'm'].includes(key)) {
    event.preventDefault();
    native(key === 'd' ? 'openDownloads' : 'openMail').catch(error => toast(error.message));
  }
});

document.addEventListener('DOMContentLoaded', () => {
  if (!settingsWindow && !new URLSearchParams(location.search).has('offline')) {
    portalAPI('/api/sites/icon-warmup', {}, false).catch(logBackgroundIssue);
  }
  scheduleLauncherPoll(pollLauncherRuntime, 2300);
  if (!settingsWindow) scheduleLauncherPoll(pollActionQueue, 1200);
});
