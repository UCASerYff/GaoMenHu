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
      return portalAPI('/api/launcher/state');
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
  try {
    const result = await action();
    toast(result?.message || success);
    return result;
  } catch (error) {
    toast(error.message);
  } finally {
    if (button.isConnected) button.disabled = false;
  }
}

function settingGroup(title, rows) {
  return '<section class="setting-group"><h3>' + esc(title) + '</h3><div>' + rows.join('') + '</div></section>';
}

function settingChoice(id, title, choices, selected) {
  return '<label class="setting-row"><strong>' + esc(title) + '</strong><select class="compact-select" id="' + id + '">'
    + choices.map(([value, label]) => '<option value="' + value + '"' + (String(selected) === String(value) ? ' selected' : '') + '>' + esc(label) + '</option>').join('')
    + '</select></label>';
}

function settingButton(id, label) {
  return '<button type="button" class="soft-button" id="' + id + '">' + esc(label) + '</button>';
}

function settingsContent(tab) {
  const note = text => '<p class="settings-note">' + esc(text) + '</p>';
  const row = (label, value) => '<div class="setting-row"><strong>' + esc(label) + '</strong><span>' + esc(value) + '</span></div>';
  const buttonRow = (...buttons) => '<div class="setting-row settings-buttons">' + buttons.join('') + '</div>';
  if (tab === 'appearance') {
    return settingGroup('外观', [
      row('语言', '简体中文'),
      settingChoice('settingsAppearance', '外观', [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']], S.library.appearance),
      row('版本', 'V' + S.version)
    ]);
  }
  if (tab === 'data') {
    return settingGroup('当前资料', [
      note('ZIP 包含当前网站、账号元数据、图标、文件夹、工作场景与外观。密码由 Windows 凭据保护保管。'),
      buttonRow(settingButton('exportZip', '导出当前资料…'), settingButton('restoreZip', '从资料恢复…'))
    ]) + settingGroup('JSON 格式', [
      note('导出当前网站资料，可合并导入或预览恢复。'),
      buttonRow(settingButton('exportJson', '导出 JSON…'), settingButton('mergeJson', '导入 JSON…'), settingButton('restoreJson', '恢复 JSON…'))
    ]) + settingGroup('跨 App 交接', [
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
    note('Chrome 和 Edge 助手支持自动填充。每个浏览器个人资料需要单独加载并连接。'),
    ...S.browsers.filter(browser => browser.supportsFill).map(browser =>
      '<div class="setting-row settings-browser-row"><strong>' + esc(browser.name) + '</strong><span class="connection" data-settings-connection="' + browser.id + '"></span><div class="setting-actions">'
      + settingButton('reconnect-' + browser.id, '重新连接') + settingButton('extensions-' + browser.id, '管理扩展…') + '</div></div>'),
    buttonRow(settingButton('extensionFolder', '打开助手文件夹')),
    note('在浏览器扩展管理页开启开发者模式，加载助手文件夹。更新后可在该页面重新加载助手。')
  ]) + settingGroup('悬浮窗', [
    '<label class="setting-row"><strong>显示悬浮窗</strong><input type="checkbox" id="settingsDockEnabled"></label>',
    settingChoice('settingsDock', '停靠位置', [['left', '左侧'], ['right', '右侧'], ['none', '自由浮动']], S.floating.dock),
    buttonRow(settingButton('resetDock', '重置悬浮窗位置'), '<span class="settings-key">Ctrl + Alt + P 显示或隐藏</span>'),
    note('悬停约 0.45 秒或点击展开。移出实际窗口约 0.15 秒收起。展开时拖动顶部、两侧或底部空白处，靠近侧边时吸附。')
  ]) + settingGroup('下载中心', [
    buttonRow(settingButton('settingsDownloads', '打开下载队列…')),
    note('HTTP / HTTPS 文件直链。复核保存目录后传输。')
  ]) + settingGroup('邮件', [
    buttonRow(settingButton('settingsMail', '打开邮件…'), settingButton('settingsMailPreferences', '邮件设置…')),
    note('管理收件箱、身份、草稿与关联平台。首次显示缓存。连接邮箱须明确确认。')
  ]) + settingGroup('账号库', [
    '<div class="setting-row"><strong id="settingsLockState"></strong>' + settingButton('settingsLock', '锁定账号库') + '</div>',
    note('密码由 Windows 凭据保护保管。解锁 5 分钟后自动锁定。填入账号密码后，由你自行完成登录。')
  ]);
}

function refreshSettingsState() {
  if (!$('launcherSettingsTabs')) return;
  for (const indicator of document.querySelectorAll('[data-settings-connection]')) {
    const browser = S.browsers.find(item => item.id === indicator.dataset.settingsConnection);
    const count = S.profiles.filter(profile => profile.browser === browser.id).length;
    indicator.textContent = count ? '已连接 · ' + count + ' 个资料' : '未连接';
    indicator.classList.toggle('offline', !count);
    $('reconnect-' + browser.id).disabled = !browser.installed;
    $('extensions-' + browser.id).disabled = !browser.installed;
  }
  if ($('settingsDockEnabled')) $('settingsDockEnabled').checked = S.floating.enabled;
  if ($('settingsDock')) $('settingsDock').value = S.floating.dock || 'right';
  if ($('settingsLock')) {
    $('settingsLock').disabled = !S.unlocked;
    $('settingsLockState').textContent = S.unlocked ? '已解锁' : '已锁定';
  }
  for (const [id, value] of [
    ['settingsAppearance', S.library.appearance],
    ['settingsDensity', S.library.layoutDensity || 'compact'],
    ['settingsIconSize', S.library.iconSize || 76]
  ]) {
    if ($(id) && $(id) !== document.activeElement) $(id).value = value;
  }
  for (const id of ['settingsAppearance', 'settingsDensity', 'settingsIconSize', 'importBookmarks', 'refreshIcons',
      'exportZip', 'restoreZip', 'exportJson', 'mergeJson', 'restoreJson', 'exportSitesCatalog', 'exportWorkspacesCatalog']) {
    if ($(id)) $(id).disabled = currentAccess !== 'ready';
  }
}

function renderWindowsSettings(tab = settingsTab) {
  if (!S) return;
  settingsTab = tab;
  const root = $('dialog');
  const previous = root.querySelector('.settings-pane');
  const scrollTop = previous?.scrollTop || 0;
  const content = '<div class="settings-tabs" id="launcherSettingsTabs" role="tablist" aria-label="设置">'
    + [['modules', '模块设置'], ['appearance', '外观'], ['data', '数据']].map(([key, label]) =>
      '<button type="button" role="tab" id="settings-tab-' + key + '" data-settings-tab="' + key + '" aria-controls="launcherSettingsPane" aria-selected="' + (key === tab) + '">' + label + '</button>').join('')
    + '</div><div class="settings-pane" id="launcherSettingsPane" role="tabpanel" aria-labelledby="settings-tab-' + tab + '">' + settingsContent(tab) + '</div>';
  openDialog((settingsWindow ? '' : head('', '搞门户设置', '')) + content);
  root.classList.add('launcher-settings');
  if (settingsWindow) root.removeAttribute('aria-modal');
  root.querySelector('.settings-pane').scrollTop = scrollTop;
  root.querySelectorAll('[data-settings-tab]').forEach(button => {
    button.onclick = () => renderWindowsSettings(button.dataset.settingsTab);
    button.onkeydown = event => {
      const buttons = Array.from(button.parentElement.querySelectorAll('button'));
      const i = buttons.indexOf(button);
      if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
      event.preventDefault();
      const next = (i + (event.key === 'ArrowLeft' ? -1 : 1) + buttons.length) % buttons.length;
      renderWindowsSettings(buttons[next].dataset.settingsTab);
    };
  });
  setTimeout(() => $('settings-tab-' + tab)?.focus(), 40);
  const bind = (id, action, success) => {
    const button = $(id);
    if (button) button.onclick = () => applyButton(button, action, success);
  };
  const preferences = async () => {
    try {
      await portalAPI('/api/preferences', {layoutDensity: $('settingsDensity').value, iconSize: Number($('settingsIconSize').value)});
    } catch (error) {
      renderWindowsSettings();
      toast(error.message);
    }
  };
  if (tab === 'modules') {
    $('settingsDensity').onchange = preferences;
    $('settingsIconSize').onchange = preferences;
    bind('importBookmarks', showBookmarkSources);
    bind('archivedSites', () => showVault(true));
    bind('refreshIcons', () => native('refreshIcon'));
    for (const browser of S.browsers.filter(item => item.supportsFill)) {
      bind('reconnect-' + browser.id, () => portalAPI('/api/browser/extensions', {browserID: browser.id, reconnect: true}));
      bind('extensions-' + browser.id, () => portalAPI('/api/browser/extensions', {browserID: browser.id}));
    }
    bind('extensionFolder', () => portalAPI('/api/browser/extensions'));
    const floating = async change => {
      try {
        const result = await portalAPI('/api/floating', change);
        S.floating = result.floating;
      } finally {
        refreshSettingsState();
      }
    };
    $('settingsDockEnabled').onchange = event => floating({enabled: event.target.checked}).catch(error => toast(error.message));
    $('settingsDock').onchange = event => floating({dock: event.target.value}).catch(error => toast(error.message));
    bind('resetDock', () => floating({reset: true, enabled: true}), '悬浮窗位置已重置。');
    bind('settingsDownloads', () => native('openDownloads'));
    bind('settingsMail', () => native('openMail'));
    bind('settingsMailPreferences', () => openPortalWindow('/mail#settings'));
    bind('settingsLock', () => native('lock'), '账号库已锁定。');
  }
  if (tab === 'appearance') $('settingsAppearance').onchange = event => setAppearance(event.target.value);
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
  if (settingsWindow || checkingActions || !S || document.hidden || !$('dialogOverlay').hidden) return;
  checkingActions = true;
  try {
    const result = await portalAPI('/api/actions/queue', {}, false);
    if (!$('dialogOverlay').hidden) return;
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
  const leavingSettings = Boolean($('launcherSettingsTabs'));
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
  if (!S || document.hidden || drag) return;
  const live = await portalAPI('/api/launcher/runtime', {}, false);
  if (live.revision !== libraryRevision || live.access !== currentAccess) {
    await portalAPI('/api/launcher/state');
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
  if (settingsWindow) {
    const waitForSettings = setInterval(() => {
      if (S) {clearInterval(waitForSettings); renderWindowsSettings();}
    }, 50);
  } else if (!new URLSearchParams(location.search).has('offline')) {
    portalAPI('/api/sites/icon-warmup', {}, false).catch(logBackgroundIssue);
  }
  setInterval(() => pollLauncherRuntime().catch(logBackgroundIssue), 2300);
  if (!settingsWindow) setInterval(() => pollActionQueue().catch(logBackgroundIssue), 1200);
});
