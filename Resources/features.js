'use strict';
// Launcher conveniences share the same local native bridge; no website content is loaded here.
let selectionMode=false,selectedSites=new Set(),searchTiles=[],searchIndex=0;
let edgeTimer=null,edgeDirection=0,edgeTurned=false,cropState=null,undoInFlight=false;
function applyPreferences(){
  const density=S.library.layoutDensity==='comfortable'?'comfortable':'compact';
  const size=[60,76,92].includes(Number(S.library.iconSize))?Number(S.library.iconSize):76;
  document.body.classList.toggle('compact',density==='compact');
  document.documentElement.style.setProperty('--icon-size',size+'px');
  document.documentElement.style.setProperty('--tile-height',(size+49)+'px');
  document.documentElement.style.setProperty('--grid-gap',density==='comfortable'?'24px':'14px');
  $('undoButton').disabled=!S.canUndo;
  selectedSites=new Set([...selectedSites].filter(id=>visibleIDs().has(id)));
  updateConnectionLabels();
}
function searchText(site){
  return [site.name,site.url,site.aliases||'',...(site.accounts||[]).flatMap(a=>[a.label,a.username]),S.searchKeys?.[site.id]||''].join(' ').toLocaleLowerCase();
}
function handleSearchKey(event){
  if(event.isComposing||event.metaKey||event.ctrlKey||event.altKey||!$('search').value.trim()||!searchTiles.length)return;
  if(event.key==='ArrowDown'||event.key==='ArrowUp'){
    event.preventDefault();event.stopPropagation();searchIndex=Math.max(0,Math.min(searchTiles.length-1,searchIndex+(event.key==='ArrowDown'?1:-1)));page=Math.floor(searchIndex/pageSize());render();
  }else if(event.key==='Enter'){
    event.preventDefault();event.stopPropagation();const tile=searchTiles[searchIndex];
    if(tile.kind==='folder')openFolder(tile.id);else if(selectionMode)toggleSiteSelection(tile.id);else launch(tile.id);
  }
}
function isTextEditing(el){return el instanceof Element&&(el.matches('input,textarea,select')||el.isContentEditable||!!el.closest('[role="textbox"]'));}
window.mendaoUndo=async()=>{
  if(isTextEditing(document.activeElement)){document.execCommand('undo');return;}
  if(!$('dialogOverlay').hidden||!$('cropOverlay').hidden)return;
  if(!S?.canUndo){toast('没有可以撤销的整理操作。');return;}
  if(undoInFlight)return;undoInFlight=true;
  try{const result=await native('undo');toast(result.message||'已撤销上次整理。');}catch(error){toast(error.message);}finally{undoInFlight=false;}
};
function setSelectionMode(enabled){selectionMode=enabled;if(!enabled)selectedSites.clear();hideContext();render();}
function toggleSiteSelection(id){if(selectedSites.has(id))selectedSites.delete(id);else selectedSites.add(id);render();}
function renderSelection(){
  $('selectionBar').hidden=!selectionMode;document.body.classList.toggle('selecting',selectionMode);
  $('manageButton').textContent=selectionMode?'完成整理':'整理';$('folderManage').textContent=selectionMode?'完成整理':'整理';
  $('selectionCount').textContent='已选择 '+selectedSites.size+' 个';
  ['batchMoveButton','batchBrowserButton','batchRemoveButton','clearSelectionButton'].forEach(id=>$(id).disabled=!selectedSites.size);
}
function selectCurrentPage(){
  const root=folderID?$('folderGrid'):$('grid');
  root.querySelectorAll('.tile').forEach(el=>{const folder=folderById(el.dataset.id);if(folder)folder.children.forEach(id=>selectedSites.add(id));else selectedSites.add(el.dataset.id);});render();
}
async function runBatch(operation,options={}){
  const result=await native('batch',{siteIDs:[...selectedSites],operation,...options});
  selectedSites.clear();render();toast(result.message||'整理已完成，可以使用 ⌘ Z 撤销。');return result;
}
function showBatchMove(){
  if(!selectedSites.size)return;
  openDialog(head('ORGANIZE','移动 '+selectedSites.size+' 个网站','选择现有文件夹，或新建一个文件夹。')+
    '<label class="field"><span class="field-label">移到</span><select id="batchFolder"><option value="">启动台首页</option>'+S.library.tiles.filter(t=>t.kind==='folder').map(t=>'<option value="'+esc(t.id)+'">'+esc(t.name)+'</option>').join('')+'<option value="__new__">＋ 新建文件夹</option></select></label><label class="field" id="newFolderField" hidden><span class="field-label">新文件夹名称</span><input id="newFolderName" maxlength="60" placeholder="例如：写论文"></label><div class="form-error" id="batchError"></div><div class="dialog-actions"><button class="soft-button" data-close>取消</button><button class="primary-button" id="batchApply">移动网站</button></div>',true);
  $('batchFolder').onchange=()=>{$('newFolderField').hidden=$('batchFolder').value!=='__new__';if(!$('newFolderField').hidden)$('newFolderName').focus();};
  $('batchApply').onclick=async()=>{const button=$('batchApply'),value=$('batchFolder').value,name=$('newFolderName').value.trim();if(value==='__new__'&&!name){$('batchError').textContent='请填写新文件夹名称。';return;}button.disabled=true;try{await runBatch('move',value==='__new__'?{folderName:name}:{folderID:value});closeDialog();}catch(error){if($('batchError'))$('batchError').textContent=error.message;button.disabled=false;}};
}
function showBatchBrowser(){
  const sites=[...selectedSites].map(siteById).filter(Boolean);if(!sites.length)return;
  const common=S.browsers.filter(b=>b.installed&&sites.every(s=>s.allowedBrowsers.includes(b.id)));
  openDialog(head('BROWSER','修改默认浏览器','只显示所有选中网站均已允许使用的浏览器。')+
    (common.length?'<label class="field"><span class="field-label">点击网站时使用</span><select id="batchBrowser">'+common.map(b=>'<option value="'+esc(b.id)+'">'+esc(b.name)+'</option>').join('')+'</select></label>':'<p class="confirm-body">这些网站没有共同允许的已安装浏览器。请先在各网站的编辑页面调整允许浏览器，或减少本次选择。</p>')+
    '<div class="form-error" id="batchError"></div><div class="dialog-actions"><button class="soft-button" data-close>取消</button><button class="primary-button" id="batchApply" '+(!common.length?'disabled':'')+'>保存默认浏览器</button></div>',true);
  $('batchApply').onclick=async()=>{const button=$('batchApply');button.disabled=true;try{await runBatch('browser',{browser:$('batchBrowser').value});closeDialog();}catch(error){if($('batchError'))$('batchError').textContent=error.message;button.disabled=false;}};
}
function showBatchRemove(){if(selectedSites.size)confirmDialog('移除 '+selectedSites.size+' 个网站入口？','网站与已保存账号仍可在账号库中恢复，本次整理也可以撤销。','移除入口',()=>runBatch('remove'));}
function clearEdgePaging(){clearTimeout(edgeTimer);edgeTimer=null;edgeDirection=0;edgeTurned=false;$('edgeLeft').classList.remove('ready');$('edgeRight').classList.remove('ready');}
function handleEdgePaging(event){
  if(!drag||folderID||$('search').value.trim()||totalPages<=1){clearEdgePaging();return;}
  const rect=$('launchArea').getBoundingClientRect(),direction=event.clientX<rect.left+48?-1:event.clientX>rect.right-48?1:0;
  if(!direction||direction<0&&page===0||direction>0&&page===totalPages-1){clearEdgePaging();return;}
  if(direction===edgeDirection)return;
  clearEdgePaging();edgeDirection=direction;clearMerge();$(direction<0?'edgeLeft':'edgeRight').classList.add('ready');
  edgeTimer=setTimeout(()=>{if(drag&&edgeDirection===direction&&!edgeTurned){edgeTurned=true;goToPage(page+direction);$(direction<0?'edgeLeft':'edgeRight').classList.remove('ready');}},600);
}
function settingRow(title,description,actions){return '<div class="setting-row"><div><strong>'+esc(title)+'</strong><p>'+esc(description)+'</p></div><div class="setting-actions">'+actions+'</div></div>';}
function updateConnectionLabels(){
  if(!S)return;document.querySelectorAll('[data-connection]').forEach(el=>{const profiles=S.profiles.filter(p=>p.browser===el.dataset.connection);el.textContent=profiles.length?profiles.map(p=>p.label).join('、')+' · 已连接':'尚未连接浏览器助手';el.classList.toggle('offline',!profiles.length);});
}
function showSettings(){
  openDialog(head('PREFERENCES','让搞门户更顺手','搞门户 V'+S.version+' · 网站启动台')+
    '<div class="settings-section"><h3>启动台</h3>'+settingRow('排列密度','紧凑布局让常去的网站更容易在一页找到。','<select class="compact-select" id="layoutDensity" aria-label="排列密度"><option value="compact">紧凑</option><option value="comfortable">宽松</option></select>')+
    settingRow('图标大小','网站名称最多显示两行。','<select class="compact-select" id="iconSize" aria-label="图标大小"><option value="60">小 · 60</option><option value="76">标准 · 76</option><option value="92">大 · 92</option></select>')+
    settingRow('启动台背景','暮色与暖白，两种安静的底色。','<button class="soft-button" id="duskTheme">暮色</button><button class="soft-button" id="lightTheme">暖白</button>')+'</div>'+
    '<div class="settings-section"><h3>网站与图标</h3>'+settingRow('从浏览器导入收藏','选择 Edge 或 Chrome 的个人资料，预览收藏栏与文件夹后导入。','<button class="soft-button" id="browserImportButton">导入收藏</button>')+
    settingRow('重新获取清晰图标','优先使用高清来源；你手动更换的图标会保留。','<button class="soft-button" id="refreshIconsButton">刷新图标</button>')+'</div>'+
    '<div class="settings-section"><h3>浏览器助手</h3>'+S.browsers.filter(b=>b.supportsFill).map(browser=>'<div class="setting-row"><div><strong>'+esc(browser.name)+'</strong><p class="connection" data-connection="'+esc(browser.id)+'"></p></div><div class="setting-actions"><button class="soft-button" data-reconnect="'+esc(browser.id)+'" '+(!browser.installed?'disabled':'')+'>重新连接</button><button class="soft-button" data-setup="'+esc(browser.id)+'" '+(!browser.installed?'disabled':'')+'>管理扩展</button></div></div>').join('')+
    '<details class="setup-details"><summary>首次安装助手</summary><div class="steps">① 打开扩展管理，开启「开发者模式」。<br>② 点击「加载已解压的扩展程序」，选择下面的 BrowserExtension 文件夹。<br>③ 打开「搞门户助手」，可为当前个人资料命名，也能收藏当前网页。<br><code>'+esc(S.extensionPath)+'</code><br><button class="soft-button" id="revealExtension" style="margin-top:9px">在 Finder 中显示扩展文件夹</button></div></details></div>'+
    '<div class="settings-section"><h3>备份与恢复</h3>'+settingRow('导出完整网站备份','保存网站、文件夹、排列和工作场景；密码留在本机钥匙串。','<button class="soft-button" id="exportButton">导出</button>')+
    settingRow('导入备份','合并新增内容，或完整恢复备份中的布局。先预览，再应用。','<button class="soft-button" id="importButton">合并导入</button><button class="soft-button" id="restoreBackupButton">恢复备份</button>')+
    settingRow('本地自动快照','批量整理与导入前自动保存，可查看并恢复。','<button class="soft-button" id="snapshotsButton">查看快照</button>')+
    settingRow('已移除的网站','移除入口后，网站与账号仍可以恢复。','<button class="soft-button" id="archivedButton">查看</button>')+'</div>'+
    '<p class="form-note">⌃ ⌥ Space 唤起并搜索 · 输入后用 ↑ ↓ 选择、回车打开<br>⌘ N 添加网站 · ⌘ F 搜索 · ⌘ Z 撤销整理 · ⌘ L 锁定账号库<br>账号库解锁有效期为 5 分钟，睡眠或锁屏后自动锁定。</p>');
  $('layoutDensity').value=S.library.layoutDensity==='comfortable'?'comfortable':'compact';$('iconSize').value=String(S.library.iconSize||76);
  const preferences=async()=>{const fields=[$('layoutDensity'),$('iconSize')],values={layoutDensity:fields[0].value,iconSize:Number(fields[1].value)};fields.forEach(el=>el.disabled=true);try{await native('preferences',values);}catch(error){toast(error.message);if(fields[0].isConnected){fields[0].value=S.library.layoutDensity||'compact';fields[1].value=String(S.library.iconSize||76);}}finally{fields.forEach(el=>el.disabled=false);}};
  $('layoutDensity').onchange=preferences;$('iconSize').onchange=preferences;
  $('duskTheme').onclick=()=>setAppearance('dusk');$('lightTheme').onclick=()=>setAppearance('light');
  $('refreshIconsButton').onclick=()=>performButton('refreshIconsButton','refreshIcons');
  $('dialog').querySelectorAll('[data-setup]').forEach(button=>button.onclick=()=>native('extensionSetup',{browser:button.dataset.setup}).catch(e=>toast(e.message)));
  $('dialog').querySelectorAll('[data-reconnect]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{toast('正在唤起浏览器助手…');const result=await native('reconnectBrowser',{browser:button.dataset.reconnect});toast(result.message);}catch(error){toast(error.message);}finally{button.disabled=false;}});
  $('revealExtension').onclick=()=>native('extensionFolder').catch(e=>toast(e.message));
  $('exportButton').onclick=()=>performButton('exportButton','export');$('archivedButton').onclick=()=>showVault(true);
  $('importButton').onclick=()=>startBackupPreview('merge');$('restoreBackupButton').onclick=()=>startBackupPreview('restore');$('snapshotsButton').onclick=showSnapshots;$('browserImportButton').onclick=showBookmarkSources;updateConnectionLabels();
}
async function performButton(id,action,data={}){const button=$(id);if(button)button.disabled=true;try{const result=await native(action,data);toast(result.message);return result;}catch(error){toast(error.message);}finally{if(button)button.disabled=false;}}
async function startBackupPreview(mode){
  try{const result=await native('previewBackup',{mode});if(!result.cancelled)showImportPreview(result,'applyBackup',mode==='restore'?'恢复备份':'合并导入备份',mode==='restore');}catch(error){toast(error.message);}
}
function previewCount(value){return Array.isArray(value)?value.length:Math.max(0,Number(value)||0);}
function showImportPreview(result,action,title,restoring=false){
  if(!result.token||!result.preview){toast('没有可导入的内容。');return;}
  const preview=result.preview;
  openDialog(head('PREVIEW',title,'确认预览后再应用。操作前会自动保存当前布局快照。')+
    '<div class="preview-stats"><div><strong>'+previewCount(preview.sites)+'</strong><span>网站</span></div><div><strong>'+previewCount(preview.folders)+'</strong><span>文件夹</span></div><div><strong>'+previewCount(preview.duplicates)+'</strong><span>重复网站</span></div></div>'+
    '<p class="confirm-body">'+esc(preview.message||(restoring?'恢复备份中的网站、文件夹和排列。':'保留现有内容，新增网站按原文件夹结构合并。'))+'</p>'+
    (Array.isArray(preview.folderNames)&&preview.folderNames.length?'<p class="form-note">文件夹：'+esc(preview.folderNames.join('、'))+'</p>':'')+
    '<p class="form-note">密码不会从备份或浏览器导入；已保存在本机钥匙串的密码由搞门户继续管理。</p><div class="form-error" id="previewError"></div><div class="dialog-actions"><button class="soft-button" data-close>取消</button><button class="primary-button" id="applyPreview">'+(restoring?'恢复布局':'确认导入')+'</button></div>');
  $('applyPreview').onclick=async()=>{const button=$('applyPreview');button.disabled=true;try{const response=await native(action,{token:result.token});setSelectionMode(false);page=0;closeFolder();render();closeDialog();toast(response.message||'已完成。');}catch(error){if($('previewError'))$('previewError').textContent=error.message;button.disabled=false;}};
}
async function showSnapshots(){
  try{const result=await native('snapshots'),snapshots=result.snapshots||[];
    openDialog(head('SNAPSHOTS','本地自动快照','快照仅保存在这台 Mac，用于恢复网站和布局，不包含密码。')+
      (!snapshots.length?'<p class="empty-accounts">还没有自动快照。批量整理或导入前会自动保存。</p>':'<div class="snapshot-list">'+snapshots.map(s=>'<div class="setting-row"><div><strong>'+esc(s.label||'整理前快照')+'</strong><p>'+esc(formatSnapshotDate(s.date))+' · '+previewCount(s.sites)+' 个网站 · '+previewCount(s.folders)+' 个文件夹</p></div><button class="soft-button" data-snapshot="'+esc(s.id)+'">预览恢复</button></div>').join('')+'</div>'));
    $('dialog').querySelectorAll('[data-snapshot]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{const response=await native('previewSnapshot',{id:button.dataset.snapshot});showImportPreview(response,'applyBackup','恢复自动快照',true);}catch(error){toast(error.message);button.disabled=false;}});
  }catch(error){toast(error.message);}
}
function formatSnapshotDate(value){const date=new Date(value);return Number.isNaN(date.valueOf())?'时间未知':date.toLocaleString('zh-CN',{year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit'});}
async function showBookmarkSources(){
  try{const result=await native('bookmarkSources'),sources=result.sources||[];
    openDialog(head('IMPORT','导入浏览器收藏','选择个人资料，将收藏栏网站连同文件夹导入搞门户。')+
      (!sources.length?'<p class="empty-accounts">未找到 Edge 或 Chrome 的收藏资料。请先在浏览器中添加收藏，然后重新打开这里。</p>':'<div class="bookmark-sources">'+sources.map(source=>'<button class="source-option" data-source="'+esc(source.id)+'"><span class="source-badge">'+(source.browser==='edge'?'E':'C')+'</span><span><strong>'+esc(source.label)+'</strong><small>'+esc(source.browser==='edge'?'Microsoft Edge':'Google Chrome')+' · 收藏栏</small></span><span aria-hidden="true">›</span></button>').join('')+'</div>')+'<p class="form-note">相同网址会在预览中列为重复，现有账号和浏览器偏好会保留。</p>');
    $('dialog').querySelectorAll('[data-source]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{const response=await native('previewBookmarks',{sourceID:button.dataset.source});showImportPreview(response,'applyBookmarks','导入收藏栏');}catch(error){toast(error.message);button.disabled=false;}});
  }catch(error){toast(error.message);}
}
function showWorkspaces(){
  const workspaces=S.library.workspaces||[];
  openDialog(head('WORKSPACES','为一件事，打开常用网站','每个网站仍使用自己的默认浏览器。一个场景最多包含 20 个网站。')+
    '<div class="workspace-list">'+(!workspaces.length?'<p class="empty-accounts">例如创建「写论文」，把检索、写作和邮箱放在一起。</p>':workspaces.map(w=>{const sites=w.siteIDs.map(siteById).filter(Boolean);return '<section class="workspace-card"><div class="workspace-title"><div><strong>'+esc(w.name)+'</strong><p>'+sites.length+' 个网站 · '+esc(sites.slice(0,3).map(s=>s.name).join('、'))+(sites.length>3?'…':'')+'</p></div><button class="primary-button" data-launch-workspace="'+esc(w.id)+'">打开场景</button></div><div class="workspace-controls"><button class="text-button" data-edit-workspace="'+esc(w.id)+'">编辑场景</button><button class="text-button danger" data-delete-workspace="'+esc(w.id)+'">删除</button></div></section>';}).join(''))+'</div><div class="dialog-actions"><button class="primary-button" id="newWorkspace">＋ 创建工作场景</button></div>');
  $('newWorkspace').onclick=()=>showWorkspaceEditor();
  $('dialog').querySelectorAll('[data-edit-workspace]').forEach(button=>button.onclick=()=>showWorkspaceEditor(button.dataset.editWorkspace));
  $('dialog').querySelectorAll('[data-delete-workspace]').forEach(button=>button.onclick=()=>confirmDialog('删除这个工作场景？','只删除场景，里面的网站入口和账号会保留。','删除场景',async()=>{const result=await native('deleteWorkspace',{id:button.dataset.deleteWorkspace});toast(result.message||'工作场景已删除。');}));
  $('dialog').querySelectorAll('[data-launch-workspace]').forEach(button=>button.onclick=async()=>{button.disabled=true;try{toast('正在打开工作场景…');const result=await native('launchWorkspace',{id:button.dataset.launchWorkspace});toast(result.message);closeDialog();}catch(error){toast(error.message);button.disabled=false;}});
}
function showWorkspaceEditor(id){
  const existing=(S.library.workspaces||[]).find(w=>w.id===id),selected=new Set(existing?.siteIDs||[]),active=visibleIDs();
  const sites=S.library.sites.filter(s=>active.has(s.id)||selected.has(s.id));
  openDialog(head('WORKSPACE',existing?'编辑工作场景':'创建工作场景','选择需要一起打开的网站；每个网站使用自己的默认浏览器。')+
    '<form id="workspaceForm"><label class="field"><span class="field-label">场景名称</span><input id="workspaceName" maxlength="60" required placeholder="例如：写论文" value="'+esc(existing?.name||'')+'"></label><div class="workspace-picker-head"><label class="field"><input id="workspaceSearch" type="search" placeholder="筛选网站" aria-label="筛选场景网站"></label><span id="workspaceSelectedCount"></span></div><div class="workspace-picker" id="workspacePicker"></div><div class="form-error" id="workspaceError"></div><div class="dialog-actions"><button type="button" class="soft-button" data-close>取消</button><button class="primary-button" type="submit" id="workspaceSave">保存场景</button></div></form>');
  const renderPicker=()=>{const query=$('workspaceSearch').value.trim().toLowerCase(),filtered=sites.filter(s=>searchText(s).includes(query));$('workspaceSelectedCount').textContent=selected.size+' / 20 已选';$('workspacePicker').innerHTML=filtered.map(s=>'<label class="workspace-choice"><input type="checkbox" value="'+esc(s.id)+'" '+(selected.has(s.id)?'checked':'')+'><span class="workspace-mini" style="--site-color:'+safeColor(s.color)+'">'+iconHTML(s,true)+'</span><span>'+esc(s.name)+'</span><small>'+esc(S.browsers.find(b=>b.id===s.defaultBrowser)?.name||s.defaultBrowser)+'</small></label>').join('')||'<p class="empty-accounts">没有找到网站。</p>';
    $('workspacePicker').querySelectorAll('input').forEach(input=>input.onchange=()=>{if(input.checked&&selected.size>=20){input.checked=false;$('workspaceError').textContent='每个工作场景最多选择 20 个网站。';return;}if(input.checked)selected.add(input.value);else selected.delete(input.value);$('workspaceError').textContent='';$('workspaceSelectedCount').textContent=selected.size+' / 20 已选';});};
  $('workspaceSearch').oninput=renderPicker;renderPicker();
  $('workspaceForm').onsubmit=async event=>{event.preventDefault();const name=$('workspaceName').value.trim();if(!name||!selected.size){$('workspaceError').textContent='请填写场景名称，并至少选择一个网站。';return;}$('workspaceSave').disabled=true;try{const result=await native('saveWorkspace',{workspace:{id:existing?.id||crypto.randomUUID(),name,siteIDs:[...selected]}});toast(result.message||'工作场景已保存。');showWorkspaces();}catch(error){if($('workspaceError'))$('workspaceError').textContent=error.message;if($('workspaceSave'))$('workspaceSave').disabled=false;}};
}
function openCrop(dataURL){
  if(!draft||!/^data:image\/(png|jpeg|webp);base64,/.test(dataURL))return;
  const image=new Image(),editingID=draft.id;image.onload=()=>{if(draft?.id!==editingID)return;cropState={image,editingID,zoom:1,x:0,y:0,pointer:null};$('cropZoom').value='1';$('cropOverlay').hidden=false;drawCrop();$('cropZoom').focus();};image.onerror=()=>toast('无法读取这张图片，请换一张试试。');image.src=dataURL;
}
function drawCrop(){
  if(!cropState)return;const canvas=$('cropCanvas'),ctx=canvas.getContext('2d'),c=cropState;ctx.clearRect(0,0,canvas.width,canvas.height);ctx.imageSmoothingEnabled=true;ctx.imageSmoothingQuality='high';
  const scale=Math.min(canvas.width/c.image.width,canvas.height/c.image.height)*c.zoom,w=c.image.width*scale,h=c.image.height*scale;ctx.drawImage(c.image,(canvas.width-w)/2+c.x,(canvas.height-h)/2+c.y,w,h);$('cropZoomValue').textContent=Math.round(c.zoom*100)+'%';
}
function closeCrop(){if(!$('cropOverlay').hidden){$('cropOverlay').hidden=true;$('chooseIcon')?.focus();}cropState=null;}
function saveCrop(){
  if(!cropState||draft?.id!==cropState.editingID){closeCrop();return;}
  const output=document.createElement('canvas');output.width=output.height=256;const ctx=output.getContext('2d');ctx.imageSmoothingEnabled=true;ctx.imageSmoothingQuality='high';ctx.drawImage($('cropCanvas'),0,0,256,256);
  draft.icon=output.toDataURL('image/png');draft.iconSource='custom';draft.iconRevision=2;draft.iconSourcePixels=256;draft.iconChanged=true;closeCrop();renderEditorIcon();
}
$('cropZoom').oninput=()=>{if(cropState){cropState.zoom=Number($('cropZoom').value);drawCrop();}};
$('cropReset').onclick=()=>{if(cropState){Object.assign(cropState,{zoom:1,x:0,y:0});$('cropZoom').value='1';drawCrop();}};
$('cropClose').onclick=closeCrop;$('cropCancel').onclick=closeCrop;$('cropSave').onclick=saveCrop;
$('cropCanvas').addEventListener('pointerdown',event=>{if(!cropState||event.button!==0)return;event.preventDefault();cropState.pointer={id:event.pointerId,x:event.clientX,y:event.clientY,startX:cropState.x,startY:cropState.y};$('cropCanvas').setPointerCapture(event.pointerId);});
$('cropCanvas').addEventListener('pointermove',event=>{const p=cropState?.pointer;if(!p||p.id!==event.pointerId)return;const ratio=512/$('cropCanvas').getBoundingClientRect().width;cropState.x=Math.max(-512,Math.min(512,p.startX+(event.clientX-p.x)*ratio));cropState.y=Math.max(-512,Math.min(512,p.startY+(event.clientY-p.y)*ratio));drawCrop();});
['pointerup','pointercancel','lostpointercapture'].forEach(name=>$('cropCanvas').addEventListener(name,()=>{if(cropState)cropState.pointer=null;}));
$('cropCanvas').tabIndex=0;$('cropCanvas').addEventListener('keydown',event=>{if(!cropState||!['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(event.key))return;event.preventDefault();const step=event.shiftKey?20:4;if(event.key==='ArrowLeft')cropState.x-=step;if(event.key==='ArrowRight')cropState.x+=step;if(event.key==='ArrowUp')cropState.y-=step;if(event.key==='ArrowDown')cropState.y+=step;drawCrop();});
$('manageButton').onclick=()=>setSelectionMode(!selectionMode);$('folderManage').onclick=()=>setSelectionMode(!selectionMode);$('manageDone').onclick=()=>setSelectionMode(false);$('undoButton').onclick=()=>window.mendaoUndo();
$('selectPageButton').onclick=selectCurrentPage;$('clearSelectionButton').onclick=()=>{selectedSites.clear();render();};$('batchMoveButton').onclick=showBatchMove;$('batchBrowserButton').onclick=showBatchBrowser;$('batchRemoveButton').onclick=showBatchRemove;$('workspacesButton').onclick=showWorkspaces;
initializeLauncher();
if(S){applyPreferences();render();}
native('state').catch(error=>toast(error.message));
