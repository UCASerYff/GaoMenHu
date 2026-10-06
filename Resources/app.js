'use strict';
const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const icons = {
  search:'<circle cx="8.5" cy="8.5" r="5.5"/><path d="m13 13 5 5"/>',
  vault:'<rect x="3" y="7" width="14" height="11" rx="3"/><path d="M6 7V5a4 4 0 0 1 8 0v2"/><path d="M10 11v3"/>',
  unlock:'<rect x="3" y="8" width="14" height="10" rx="3"/><path d="M7 8V5a4 4 0 0 1 7-2"/><path d="M10 12v2"/>',
  full:'<path d="M7 3H3v4m10-4h4v4M3 13v4h4m10-4v4h-4"/>',
  settings:'<path d="m8 2-.8 2.1-2 .9-2.1-.6L2 7l1.8 1.4v2.2L2 12l1.1 2.6 2.1-.6 2 .9L8 17h3l.8-2.1 2-.9 2.1.6L17 12l-1.8-1.4V8.4L17 7l-1.1-2.6-2.1.6-2-.9L11 2z"/><circle cx="9.5" cy="9.5" r="2.6"/>',
  drag:'<circle cx="7" cy="4" r=".7"/><circle cx="13" cy="4" r=".7"/><circle cx="7" cy="10" r=".7"/><circle cx="13" cy="10" r=".7"/><circle cx="7" cy="16" r=".7"/><circle cx="13" cy="16" r=".7"/>'
};
const svg = key => '<svg viewBox="0 0 20 20" aria-hidden="true">' + icons[key] + '</svg>';
const waiters = new Map();
let serial = 0, S = null, page = 0, folderID = null, draft = null, drag = null, mergeTimer = null, mergeTarget = null, toastTimer = null, lastFocus = null;
let totalPages = 1, pageAnimation = null, dragSourceNode = null;
const wheelGesture = {lastTime: -Infinity, distance: 0, direction: 0, consumed: false};
const palette = ['#D97757','#248977','#537CE6','#35384B','#ED83A7','#AC83C8','#C29A55','#5B9DAD'];
function native(action, data = {}) {
  return new Promise((resolve,reject) => {
    const id = String(++serial);
    const timeout = setTimeout(() => {waiters.delete(id); reject(new Error('操作超时，请重试。'));}, ['launch','saveSite','unlock','launchWorkspace','deleteAccount','chooseIcon','previewBackup','export'].includes(action)?120000:15000);
    waiters.set(id, {resolve,reject,timeout});
    if (window.webkit?.messageHandlers?.mendao) window.webkit.messageHandlers.mendao.postMessage({id,action,data});
    else {clearTimeout(timeout);waiters.delete(id);reject(new Error('请在搞门户 App 中打开此页面。'));}
  });
}
window.nativeReply = message => {
  const entry = waiters.get(message.id);
  if (!entry) return;
  clearTimeout(entry.timeout);waiters.delete(message.id);
  const value = message.value;
  if (value.state) updateState(value.state);
  if (value.ok || value.cancelled) entry.resolve(value);
  else entry.reject(new Error(value.error || value.message || '操作未完成，请重试。'));
};
window.nativeEvent = message => {
  if (message.payload.state) updateState(message.payload.state);
  switch(message.event){
    case 'toast':toast(message.payload.message);break;
    case 'settings':showSettings();break;
    case 'search':if($('dialogOverlay').hidden&&$('cropOverlay').hidden){closeFolder();$('search').focus();$('search').select();}break;
    case 'addSite':showEditor();break;
    case 'locked':if(S){S.unlocked=false;renderLock();}break;
  }
};
function updateState(state){S=state;document.body.classList.toggle('light',S.library.appearance==='light');$('version').textContent='V'+S.version;applyPreferences();render();renderLock();}
function toast(message){if(!message)return;$('toast').textContent=message;$('toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').classList.remove('visible'),5200);}
const siteById = id => S.library.sites.find(x=>x.id===id);
const folderById = id => S.library.tiles.find(x=>x.kind==='folder'&&x.id===id);
function visibleIDs(){return new Set(S.library.tiles.flatMap(t=>t.kind==='folder'?t.children:[t.id]));}
function iconHTML(site, mini=false){
  if(site.icon && /^data:image\/(png|jpeg|webp);base64,[a-zA-Z0-9+/=]+$/.test(site.icon)){
    const pixels=Number(site.iconSourcePixels),maxSize=pixels/Math.max(1,window.devicePixelRatio||1);
    const limit=site.iconSource==='website'&&Number.isFinite(pixels)&&pixels>=64?' style="max-width:'+maxSize+'px;max-height:'+maxSize+'px"':'';
    return '<img draggable="false" src="'+esc(site.icon)+'" alt=""'+limit+'>';
  }
  const letters = site.name.match(/^[A-Za-z]/) ? site.name.slice(0,1).toUpperCase() : site.name.slice(0,1);
  if(site.name==='Claude')return '<span aria-hidden="true" style="font-size:'+(mini?'10':'47')+'px;font-weight:300">✳</span>';
  if(site.name==='ChatGPT')return '<span aria-hidden="true" style="font-size:'+(mini?'9':'38')+'px;font-weight:300">◎</span>';
  if(site.name==='Gemini')return '<span aria-hidden="true" style="font-size:'+(mini?'10':'44')+'px;font-weight:300">✦</span>';
  return '<span>'+esc(letters)+'</span>';
}
function safeColor(color){return /^#[a-fA-F0-9]{6}$/.test(color)?color:'#D97757';}
function tileElement(tile, inside=null){
  const isFolder=tile.kind==='folder';const site=isFolder?null:siteById(tile.id);if(!site&&!isFolder)return null;
  const el=document.createElement('button');el.type='button';el.className='tile'+(isFolder?' folder':'');el.draggable=!selectionMode;el.dataset.id=tile.id;el.id='tile-'+tile.id;
  el.setAttribute('aria-label',(isFolder?'打开文件夹 ':'打开网站 ')+(isFolder?tile.name:site.name));
  el.title=isFolder?tile.name:site.name+' · '+(S.browsers.find(b=>b.id===site.defaultBrowser)?.name||site.defaultBrowser);
  if(isFolder){
    el.innerHTML='<div class="tile-body"><div class="tile-icon">'+tile.children.slice(0,9).map(id=>{const s=siteById(id);return s?'<span class="mini-icon" style="--site-color:'+safeColor(s.color)+'">'+iconHTML(s,true)+'</span>':'';}).join('')+'</div></div><span class="tile-name">'+esc(tile.name)+'</span>';
  }else{
    el.innerHTML='<div class="tile-body"><div class="tile-icon" style="--site-color:'+safeColor(site.color)+'">'+iconHTML(site)+'</div><span class="browser-badge badge-'+esc(site.defaultBrowser)+'">'+({chrome:'C',edge:'E',safari:'S',firefox:'F'}[site.defaultBrowser]||'')+'</span></div><span class="tile-name">'+esc(site.name)+'</span>';
  }
  if(!isFolder&&selectionMode){el.classList.toggle('selected',selectedSites.has(site.id));el.setAttribute('aria-pressed',String(selectedSites.has(site.id)));el.insertAdjacentHTML('beforeend','<span class="selection-check" aria-hidden="true">'+(selectedSites.has(site.id)?'✓':'')+'</span>');}
  el.addEventListener('click',()=>{if(drag)return;if(!isFolder&&selectionMode){toggleSiteSelection(site.id);return;}isFolder?openFolder(tile.id):launch(site.id);});
  el.addEventListener('contextmenu',event=>{event.preventDefault();contextMenu(event,tile);});
  el.addEventListener('dragstart',event=>{
    drag={id:tile.id,inside,kind:tile.kind};dragSourceNode=el;event.dataTransfer.effectAllowed='move';event.dataTransfer.setData('text/plain',tile.id);setTimeout(()=>{if(dragSourceNode===el)el.classList.add('dragging');},0);hideContext();
  });
  el.addEventListener('dragend',()=>{drag=null;dragSourceNode=null;clearEdgePaging();clearMerge();document.querySelectorAll('.dragging').forEach(x=>x.classList.remove('dragging'));$('folderOut').classList.remove('ready');render();});
  el.addEventListener('dragover',event=>{
    if(!drag||drag.id===tile.id||$('search').value.trim())return;event.preventDefault();event.stopPropagation();event.dataTransfer.dropEffect='move';
    const rect=el.getBoundingClientRect(),x=(event.clientX-rect.left)/rect.width,y=(event.clientY-rect.top)/rect.height;
    const central=x>.23&&x<.77&&y<.82;
    const canMerge=drag.kind==='site'&&!inside&&drag.inside!==tile.id;
    document.querySelectorAll('.drop-before,.drop-after').forEach(x=>x.classList.remove('drop-before','drop-after'));
    if(central&&canMerge){
      if(mergeTarget!==tile.id){clearMerge();mergeTarget=tile.id;mergeTimer=setTimeout(()=>{el.classList.add('merge-ready');if(isFolder){mergeTimer=setTimeout(()=>openFolder(tile.id),900);}},450);}
    }else{clearMerge();el.classList.add(x<.5?'drop-before':'drop-after');}
  });
  el.addEventListener('dragleave',event=>{if(!el.contains(event.relatedTarget)){if(mergeTarget===tile.id)clearMerge();el.classList.remove('drop-before','drop-after');}});
  el.addEventListener('drop',event=>{
    if(!drag)return;event.preventDefault();event.stopPropagation();
    const rect=el.getBoundingClientRect(),after=(event.clientX-rect.left)>rect.width/2;
    const combine=el.classList.contains('merge-ready');
    const moving={...drag};drag=null;dragSourceNode=null;clearEdgePaging();clearMerge();
    moveTile(moving,tile.id,inside,combine,after);
  });
  return el;
}
function clearMerge(){clearTimeout(mergeTimer);mergeTimer=null;mergeTarget=null;document.querySelectorAll('.merge-ready,.drop-before,.drop-after').forEach(x=>x.classList.remove('merge-ready','drop-before','drop-after'));}
function columns(){const size=Number(S?.library.iconSize)||76,compact=S?.library.layoutDensity!=='comfortable';return Math.max(3,Math.min(10,Math.floor(($('launchArea').clientWidth+12)/(size+(compact?39:66)))));}
function pageSize(){const size=Number(S?.library.iconSize)||76,gap=S?.library.layoutDensity==='comfortable'?24:14;const rows=Math.max(1,Math.floor(($('launchArea').clientHeight-19+gap)/(size+49+gap)));return columns()*rows;}
function pagingBlocked(target){
  const editing=el=>el instanceof Element&&(el.matches('input,textarea,select')||el.isContentEditable||!!el.closest('[role="textbox"]'));
  return !S||folderID||draft||drag||!$('dialogOverlay').hidden||!$('cropOverlay').hidden||!$('folderOverlay').hidden||!$('contextMenu').hidden||editing(target)||editing(document.activeElement);
}
function goToPage(next,{focusTile=false}={}){
  next=Math.max(0,Math.min(totalPages-1,next));if(next===page)return false;
  const direction=next>page?1:-1;page=next;if($('search').value.trim())searchIndex=page*pageSize();clearMerge();hideContext();render();$('launchArea').scrollTop=0;
  if(pageAnimation)pageAnimation.cancel();
  if(!matchMedia('(prefers-reduced-motion: reduce)').matches)pageAnimation=$('grid').animate([{opacity:.45,transform:'translateX('+(direction*20)+'px)'},{opacity:1,transform:'translateX(0)'}],{duration:170,easing:'ease-out'});
  if(focusTile){const tiles=$('grid').children;(direction>0?tiles[0]:tiles[tiles.length-1])?.focus();}
  return true;
}
function renderPagination(){
  const single=totalPages<=1;$('pagination').classList.toggle('single-page',single);$('pagination').setAttribute('aria-hidden',String(single));$('pagingHint').hidden=single;
  $('previousPage').disabled=page===0;$('nextPage').disabled=page===totalPages-1;
  $('pageNumber').textContent=(page+1)+' / '+totalPages;
  const dots=$('pageDots');
  if(dots.children.length!==totalPages){
    dots.replaceChildren();
    for(let i=0;i<totalPages;i++){
      const button=document.createElement('button');button.type='button';button.className='page-dot';button.setAttribute('aria-label','第 '+(i+1)+' 页');button.title='第 '+(i+1)+' 页';button.onclick=()=>goToPage(i);
      // Keep the existing drag-to-page behavior for arranging sites across pages.
      button.addEventListener('dragover',event=>{if(drag){event.preventDefault();goToPage(i);}});dots.append(button);
    }
  }
  [...dots.children].forEach((button,i)=>{button.classList.toggle('active',i===page);button.setAttribute('aria-current',i===page?'page':'false');});
}
function handleLauncherWheel(event){
  if(pagingBlocked(event.target)||totalPages<=1||event.ctrlKey||event.metaKey||event.altKey)return;
  const scale=event.deltaMode===1?16:event.deltaMode===2?$('launchArea').clientWidth:1;
  const x=event.deltaX*scale,y=event.deltaY*scale;
  // Vertical scrolling remains native, including diagonal gestures whose main direction is vertical.
  if(Math.abs(x)<2||Math.abs(x)<=Math.abs(y)*1.2)return;
  event.preventDefault();
  const now=performance.now();
  if(now-wheelGesture.lastTime>280){wheelGesture.distance=0;wheelGesture.direction=0;wheelGesture.consumed=false;}
  wheelGesture.lastTime=now;
  // A wheel stream includes its momentum tail: it can advance only one page until it goes quiet.
  if(wheelGesture.consumed)return;
  const direction=Math.sign(x);
  if(direction!==wheelGesture.direction){wheelGesture.distance=0;wheelGesture.direction=direction;}
  wheelGesture.distance+=Math.abs(x);
  if(wheelGesture.distance>=56){wheelGesture.consumed=true;goToPage(page+direction);}
}
function clearGridForRender(root){
  // Keeping the drag source under its original parent lets WebKit continue the native drag across pages.
  const held=drag&&dragSourceNode?.parentElement===root?dragSourceNode:null;
  if(!held)root.replaceChildren();
  else{[...root.children].forEach(child=>{if(child!==held)child.remove();});held.classList.add('drag-carry');}
  return held;
}
function placeRenderedTile(root,tile,inside,index,held){
  const reused=held?.dataset.id===tile.id,el=reused?held:tileElement(tile,inside);if(!el)return null;
  el.classList.remove('drag-carry');el.style.order=index;
  if(!reused)root.append(el);
  return el;
}
function render(){
  if(!S)return;const query=$('search').value.trim().toLowerCase();const root=$('grid'),held=clearGridForRender(root);root.style.setProperty('--columns',columns());
  let tiles;
  if(query){
    const active=visibleIDs();tiles=S.library.sites.filter(s=>active.has(s.id)&&searchText(s).includes(query)).map(s=>({id:s.id,kind:'site'}));
    const matchingFolders=S.library.tiles.filter(t=>t.kind==='folder'&&t.name.toLowerCase().includes(query));tiles=matchingFolders.concat(tiles);
  }else tiles=S.library.tiles;
  searchTiles=query?tiles:[];searchIndex=Math.max(0,Math.min(searchIndex,searchTiles.length-1));
  const size=pageSize();totalPages=Math.max(1,Math.ceil(tiles.length/size));page=Math.max(0,Math.min(page,totalPages-1));
  tiles.slice(page*size,(page+1)*size).forEach((t,index)=>{const el=placeRenderedTile(root,t,null,index,held);if(el){if(query)el.draggable=false;if(query&&searchTiles[searchIndex]?.id===t.id){el.classList.add('search-active');$('search').setAttribute('aria-activedescendant',el.id);}}});
  $('caption').textContent=query?'搜索结果':'我的网站';$('count').textContent=query?tiles.length+' 个结果':visibleIDs().size+' 个网站 · '+S.library.tiles.filter(t=>t.kind==='folder').length+' 个文件夹';
  $('empty').hidden=tiles.length>0;
  $('empty').innerHTML=query?'<strong>没有找到这个地方</strong><p>试试网站名称、拼音、简称、账号或网址。</p>':'<strong>从一个常去的网站开始。</strong><p>点击右上角「添加网站」，建立你的上网入口。</p>';
  if(!query||!tiles.length)$('search').removeAttribute('aria-activedescendant');
  renderPagination();renderSelection();
  if(folderID)renderFolder();
}
function renderLock(){$('lockButton').innerHTML=svg(S.unlocked?'unlock':'vault')+(S.unlocked?'账号库已解锁 · 点击锁定':'账号库已锁定');}
async function launch(siteID,browser,accountID){
  try{toast('正在打开网站…');const result=await native('launch',{siteID,...(browser?{browser}:{}),...(accountID?{accountID}:{})});toast(result.message);}catch(error){toast(error.message);}
}
function openFolder(id){folderID=id;renderFolder();$('folderOverlay').hidden=false;if(!drag)setTimeout(()=>$('folderClose').focus(),30);}
function closeFolder(){folderID=null;$('folderOverlay').hidden=true;}
function renderFolder(){
  const folder=folderById(folderID);if(!folder){closeFolder();return;}$('folderTitle').textContent=folder.name;const root=$('folderGrid'),held=clearGridForRender(root);
  folder.children.forEach((id,index)=>placeRenderedTile(root,{id,kind:'site'},folderID,index,held));
}
function detach(tiles,moving){
  let record;
  if(moving.inside){const folder=tiles.find(t=>t.id===moving.inside);if(!folder)return null;folder.children=folder.children.filter(id=>id!==moving.id);record={id:moving.id,kind:'site'};if(!folder.children.length)tiles.splice(tiles.indexOf(folder),1);}
  else{const index=tiles.findIndex(t=>t.id===moving.id);if(index<0)return null;record=tiles.splice(index,1)[0];}
  return record;
}
async function persistLayout(tiles){
  const previous=structuredClone(S.library.tiles);S.library.tiles=tiles;render();
  try{await native('layout',{tiles});}catch(error){S.library.tiles=previous;render();toast(error.message);}
}
function moveTile(moving,targetID,targetFolder,combine,after){
  if(moving.id===targetID||moving.kind==='folder'&&targetFolder||moving.inside===targetID)return;
  const tiles=structuredClone(S.library.tiles);
  if(moving.inside&&moving.inside===targetFolder){
    const folder=tiles.find(t=>t.id===targetFolder);const old=folder.children.indexOf(moving.id);folder.children.splice(old,1);let position=folder.children.indexOf(targetID);if(position<0)position=folder.children.length;else if(after)position++;folder.children.splice(position,0,moving.id);persistLayout(tiles);return;
  }
  const record=detach(tiles,moving);if(!record)return;
  if(targetFolder){const folder=tiles.find(t=>t.id===targetFolder);if(!folder)return;let position=targetID?folder.children.indexOf(targetID):folder.children.length;if(position<0)position=folder.children.length;else if(after&&targetID)position++;folder.children.splice(position,0,moving.id);}
  else if(combine){
    const target=tiles.find(t=>t.id===targetID);if(!target)return;
    if(target.kind==='folder'){target.children.push(moving.id);toast('已加入「'+target.name+'」。');}
    else{const index=tiles.indexOf(target);tiles[index]={id:crypto.randomUUID(),kind:'folder',name:'新文件夹',children:[target.id,moving.id]};toast('文件夹已创建。打开后点击名称即可重命名。');}
  }else{
    let index=targetID?tiles.findIndex(t=>t.id===targetID):tiles.length;if(index<0)index=tiles.length;else if(after&&targetID)index++;tiles.splice(index,0,record);
  }
  persistLayout(tiles);
}
function hideContext(){$('contextMenu').hidden=true;}
function contextMenu(event,tile){
  const menu=$('contextMenu');menu.replaceChildren();
  const row=(label,fn,cls='')=>{const button=document.createElement('button');button.textContent=label;button.className=cls;button.onclick=()=>{hideContext();fn();};menu.append(button);};
  if(tile.kind==='folder'){row('打开文件夹',()=>openFolder(tile.id));row('重命名文件夹',()=>renameFolder(tile.id));row('解散文件夹',()=>{const tiles=structuredClone(S.library.tiles),i=tiles.findIndex(t=>t.id===tile.id);tiles.splice(i,1,...tile.children.map(id=>({id,kind:'site'})));persistLayout(tiles);});}
  else{
    const site=siteById(tile.id);row('打开 '+site.name,()=>launch(site.id));
    const label=document.createElement('div');label.className='menu-label';label.textContent='使用浏览器';menu.append(label);
    site.allowedBrowsers.forEach(id=>row((S.browsers.find(b=>b.id===id)?.name||id)+(site.defaultBrowser===id?' · 默认':''),()=>launch(site.id,id)));
    if(site.accounts.length>1){const label2=document.createElement('div');label2.className='menu-label';label2.textContent='使用账号';menu.append(label2);site.accounts.forEach(a=>row(a.label||a.username||'未命名账号',()=>launch(site.id,null,a.id)));}
    menu.append(document.createElement('hr'));row('重新获取清晰图标',()=>native('refreshIcon',{siteID:site.id}).then(r=>toast(r.message)).catch(e=>toast(e.message)));row('选择并批量整理',()=>{selectionMode=true;selectedSites.add(site.id);render();});row('编辑网站与账号…',()=>showEditor(site.id));row('移除网站入口…',()=>removeSite(site),'danger');
  }
  menu.hidden=false;const rect=menu.getBoundingClientRect();menu.style.left=Math.min(event.clientX,innerWidth-rect.width-12)+'px';menu.style.top=Math.min(event.clientY,innerHeight-rect.height-12)+'px';
}
function openDialog(html,small=false){
  lastFocus=document.activeElement;$('dialog').className='dialog'+(small?' small':'');$('dialog').innerHTML=html;$('dialogOverlay').hidden=false;
  $('dialog').querySelectorAll('[data-close]').forEach(button=>button.onclick=closeDialog);setTimeout(()=>($('dialog').querySelector('input,button')||$('dialog')).focus(),30);
}
function closeDialog(){closeCrop();$('dialogOverlay').hidden=true;$('dialog').replaceChildren();draft=null;if(lastFocus?.isConnected)lastFocus.focus();}
function head(eyebrow,title,description){return '<div class="dialog-head"><div><span class="eyebrow">'+eyebrow+'</span><h2>'+esc(title)+'</h2>'+(description?'<p class="description">'+esc(description)+'</p>':'')+'</div><button class="icon-button close" data-close aria-label="关闭">×</button></div>';}
function confirmDialog(title,body,button,action){
  openDialog(head('MENDAO',title,'')+'<p class="confirm-body">'+esc(body)+'</p><div class="form-error" id="confirmError"></div><div class="dialog-actions"><button class="soft-button" data-close>取消</button><button class="primary-button" id="confirmAction">'+esc(button)+'</button></div>',true);
  $('confirmAction').onclick=async()=>{const el=$('confirmAction');el.disabled=true;try{await action();closeDialog();}catch(error){$('confirmError').textContent=error.message;el.disabled=false;}};
}
function renameFolder(id){
  const folder=folderById(id);if(!folder)return;
  openDialog(head('FOLDER','给文件夹起个名字','')+'<input class="small-input" id="folderName" maxlength="60" value="'+esc(folder.name)+'" aria-label="文件夹名称"><div class="dialog-actions"><button class="soft-button" data-close>取消</button><button class="primary-button" id="renameSave">保存名称</button></div>',true);
  $('renameSave').onclick=()=>{const name=$('folderName').value.trim();if(!name)return;const tiles=structuredClone(S.library.tiles);tiles.find(t=>t.id===id).name=name;persistLayout(tiles);closeDialog();};
  $('folderName').onkeydown=event=>{if(event.key==='Enter')$('renameSave').click();};setTimeout(()=>$('folderName').select(),50);
}
function removeSite(site){confirmDialog('移除「'+site.name+'」？','只移除启动台入口。已保存的账号会保留在账号库中，也可以恢复这个网站。','移除入口',async()=>{await native('removeSite',{siteID:site.id});toast('网站入口已移除，账号信息仍在账号库中。');});}
function showEditor(id){
  const existing=id?siteById(id):null;
  const installed=S.browsers.filter(b=>b.installed).map(b=>b.id),preferred=installed.includes('chrome')?'chrome':installed[0]||'safari';
  draft=existing?structuredClone(existing):{id:crypto.randomUUID(),name:'',url:'',color:palette[0],icon:null,allowedBrowsers:[preferred],defaultBrowser:preferred,accounts:[],defaultAccount:null,profiles:{},aliases:''};
  draft.iconChanged=false;
  const initial=draft;
  openDialog(head('WEBSITE',existing?'编辑网站':'添加一个常去的地方','设定浏览器和账号，下次一点就到。')+
    '<form id="siteForm"><div class="icon-edit"><div class="tile-icon" id="editorIcon"></div><div><button type="button" class="soft-button" id="chooseIcon">更换图标</button><button type="button" class="text-button" id="resetIcon" style="margin-left:10px">获取清晰图标</button><div class="color-palette" id="palette"></div></div></div>'+
    '<div class="two-col"><label class="field"><span class="field-label">网站名称</span><input id="siteName" required maxlength="100" placeholder="例如：Claude" value="'+esc(initial.name)+'"></label><label class="field"><span class="field-label">网站网址</span><input id="siteURL" required placeholder="https://claude.ai" value="'+esc(initial.url)+'"></label></div>'+
    '<label class="field"><span class="field-label">自定义简称 · 可用空格或逗号分隔</span><input id="siteAliases" maxlength="300" placeholder="例如：学术 scholar" value="'+esc(initial.aliases||'')+'"></label>'+
    '<div class="field"><span class="field-label">允许使用的浏览器 · 至少选择一个</span><div class="browser-options" id="browserOptions"></div></div>'+
    '<label class="field"><span class="field-label">点击图标时使用</span><select id="defaultBrowser"></select></label><div id="profileFields"></div>'+
    '<div class="section-title"><span>关联账号 <span style="color:var(--subtle);font-size:10px">可选</span></span><button type="button" class="soft-button" id="addAccount">＋ 添加账号</button></div>'+
    '<div id="accounts"></div><p class="form-note">密码保存在本机钥匙串，验证 Mac 身份后填充。登录按钮、验证码和二次验证由你完成。自动填充支持 Chrome / Edge。</p>'+
    '<div class="form-error" id="formError"></div><div class="dialog-actions"><button type="button" class="soft-button" data-close>取消</button><button class="primary-button" type="submit" id="saveSite">保存网站</button></div></form>');
  draft=initial;
  $('siteName').oninput=()=>{draft.name=$('siteName').value;renderEditorIcon();};$('siteURL').oninput=()=>draft.url=$('siteURL').value;
  $('chooseIcon').onclick=async()=>{const editingID=draft?.id;try{const result=await native('chooseIcon');if(result.icon&&draft?.id===editingID)openCrop(result.icon);}catch(error){if($('formError'))$('formError').textContent=error.message;}};
  $('resetIcon').onclick=()=>{draft.icon=null;draft.iconSource='website';draft.iconRevision=null;draft.iconSourcePixels=null;draft.iconCheckedAt=null;draft.iconChanged=true;renderEditorIcon();};
  $('addAccount').onclick=()=>{captureAccounts();const account={id:crypto.randomUUID(),label:'',username:'',password:'',hasPassword:false,loginHosts:[]};draft.accounts.push(account);if(!draft.defaultAccount)draft.defaultAccount=account.id;renderAccounts();};
  $('defaultBrowser').onchange=()=>draft.defaultBrowser=$('defaultBrowser').value;
  $('siteForm').onsubmit=async event=>{
    event.preventDefault();captureAccounts();draft.name=$('siteName').value.trim();draft.url=$('siteURL').value.trim();draft.aliases=$('siteAliases').value.trim();if(!/^[a-z]+:\/\//i.test(draft.url))draft.url='https://'+draft.url;
    if(!draft.allowedBrowsers.length){$('formError').textContent='请至少选择一个浏览器。';return;}
    $('saveSite').disabled=true;$('formError').textContent='';
    try{const result=await native('saveSite',{site:draft});closeDialog();toast(result.warning||'网站已保存。');}catch(error){if($('formError'))$('formError').textContent=error.message;if($('saveSite'))$('saveSite').disabled=false;}
  };
  renderEditorIcon();renderBrowserOptions();renderAccounts();
}
function renderEditorIcon(){
  const temp={...draft,name:draft.name||'门'};$('editorIcon').style.setProperty('--site-color',safeColor(draft.color));$('editorIcon').innerHTML=iconHTML(temp);$('palette').replaceChildren();
  palette.forEach(color=>{const button=document.createElement('button');button.type='button';button.className='color-dot'+(draft.color===color?' active':'');button.style.background=color;button.setAttribute('aria-label','选择颜色 '+color);button.onclick=()=>{draft.color=color;renderEditorIcon();};$('palette').append(button);});
}
function renderBrowserOptions(){
  $('browserOptions').replaceChildren();
  S.browsers.forEach(browser=>{
    const label=document.createElement('label');label.className='browser-choice'+(draft.allowedBrowsers.includes(browser.id)?' selected':'')+(!browser.installed?' unavailable':'');
    label.innerHTML='<input type="checkbox" '+(draft.allowedBrowsers.includes(browser.id)?'checked ':'')+(!browser.installed&&!draft.allowedBrowsers.includes(browser.id)?'disabled ':'')+'><span>'+browser.name+'</span>'+(!browser.installed?'<small>未安装</small>':'');
    label.querySelector('input').onchange=event=>{if(event.target.checked)draft.allowedBrowsers.push(browser.id);else draft.allowedBrowsers=draft.allowedBrowsers.filter(x=>x!==browser.id);if(!draft.allowedBrowsers.includes(draft.defaultBrowser))draft.defaultBrowser=draft.allowedBrowsers[0]||'';renderBrowserOptions();};$('browserOptions').append(label);
  });
  $('defaultBrowser').innerHTML=draft.allowedBrowsers.map(id=>'<option value="'+id+'">'+esc(S.browsers.find(b=>b.id===id)?.name||id)+'</option>').join('');$('defaultBrowser').value=draft.defaultBrowser;
  $('profileFields').replaceChildren();
  draft.allowedBrowsers.filter(id=>['chrome','edge'].includes(id)).forEach(id=>{
    const profiles=S.profiles.filter(p=>p.browser===id),remembered=draft.profiles[id]||'';const el=document.createElement('div');el.className='profile-field';
    el.innerHTML='<label>'+esc(S.browsers.find(b=>b.id===id)?.name)+' 个人资料</label><select class="profile-select" data-browser="'+id+'"><option value="">自动选择唯一连接的资料</option>'+profiles.map(p=>'<option value="'+esc(p.id)+'">'+esc(p.label)+'</option>').join('')+(remembered&&!profiles.some(p=>p.id===remembered)?'<option value="'+esc(remembered)+'">指定资料（当前未连接）</option>':'')+'</select>';
    const select=el.querySelector('select');select.value=remembered;select.onchange=()=>{if(select.value)draft.profiles[id]=select.value;else delete draft.profiles[id];};$('profileFields').append(el);
  });
}
function captureAccounts(){
  if(!draft)return;
  $('accounts').querySelectorAll('.account-card').forEach(el=>{
    const account=draft.accounts.find(a=>a.id===el.dataset.id);if(!account)return;
    account.label=el.querySelector('[data-field="label"]').value.trim();account.username=el.querySelector('[data-field="username"]').value.trim();account.password=el.querySelector('[data-field="password"]').value;account.loginHosts=el.querySelector('[data-field="hosts"]').value.split(/[,\s，]+/).map(s=>s.trim()).filter(Boolean);
    if(el.querySelector('[data-field="default"]').checked)draft.defaultAccount=account.id;
  });
}
function renderAccounts(){
  const root=$('accounts');root.replaceChildren();
  if(!draft.accounts.length){root.innerHTML='<p class="empty-accounts">可以先收藏网站，之后再添加账号。</p>';return;}
  draft.accounts.forEach((account,index)=>{
    const el=document.createElement('div');el.className='account-card';el.dataset.id=account.id;
    el.innerHTML='<div class="account-top"><label><input type="radio" name="defaultAccount" data-field="default" '+(draft.defaultAccount===account.id?'checked':'')+'> 默认账号</label><button type="button" class="text-button danger" data-remove>移除账号</button></div>'+
      '<div class="account-fields"><input data-field="label" placeholder="账号备注，例如工作账号" aria-label="账号备注" value="'+esc(account.label)+'"><input data-field="username" placeholder="账号 / 邮箱" aria-label="账号或邮箱" autocomplete="off" value="'+esc(account.username)+'"><input class="wide" type="password" data-field="password" aria-label="密码" autocomplete="new-password" placeholder="'+(account.hasPassword?'已保存在钥匙串；留空保持原密码':'密码（可选）')+'" value="'+esc(account.password||'')+'"><input class="wide" data-field="hosts" placeholder="其他登录域名（可选），例如 auth.example.com" aria-label="其他登录域名" value="'+esc(account.loginHosts.join(', '))+'"></div>';
    el.querySelector('[data-remove]').onclick=()=>{captureAccounts();draft.accounts.splice(index,1);if(draft.defaultAccount===account.id)draft.defaultAccount=draft.accounts[0]?.id||null;renderAccounts();};
    root.append(el);
  });
}
async function setAppearance(appearance){try{await native('appearance',{appearance});S.library.appearance=appearance;document.body.classList.toggle('light',appearance==='light');}catch(error){toast(error.message);}}
function showVault(archivedOnly=false){
  const active=visibleIDs();const sites=S.library.sites.filter(s=>archivedOnly?!active.has(s.id):s.accounts.length||!active.has(s.id));
  openDialog(head(archivedOnly?'ARCHIVE':'ACCOUNTS',archivedOnly?'已移除的网站':'你的账号库',archivedOnly?'恢复后，网站会重新出现在首页。':'账号密码保存在 macOS 钥匙串，移除网站入口后仍可管理。')+
    (!sites.length?'<p class="empty-accounts">'+(archivedOnly?'没有已移除的网站。':'还没有保存账号。编辑网站即可添加。')+'</p>':'')+
    sites.map(site=>'<section class="vault-site"><div class="vault-site-head"><div><strong>'+esc(site.name)+'</strong> '+(!active.has(site.id)?'<span class="form-note">已移除入口</span>':'')+'</div><div class="setting-actions">'+(!active.has(site.id)?'<button class="soft-button" data-restore="'+esc(site.id)+'">恢复入口</button>':'')+'<button class="soft-button" data-edit="'+esc(site.id)+'">编辑</button></div></div>'+site.accounts.map(account=>'<div class="vault-account"><div><strong>'+esc(account.label||'网站账号')+'</strong><span>'+esc(account.username||'未填写用户名')+' · '+(account.hasPassword?'密码已保存':'未保存密码')+'</span></div><button class="text-button danger" data-site="'+esc(site.id)+'" data-delete-account="'+esc(account.id)+'">删除账号</button></div>').join('')+'</section>').join(''));
  $('dialog').querySelectorAll('[data-edit]').forEach(b=>b.onclick=()=>showEditor(b.dataset.edit));
  $('dialog').querySelectorAll('[data-restore]').forEach(b=>b.onclick=async()=>{try{await native('restoreSite',{siteID:b.dataset.restore});toast('网站入口已恢复。');showVault(archivedOnly);}catch(error){toast(error.message);}});
  $('dialog').querySelectorAll('[data-delete-account]').forEach(b=>b.onclick=()=>confirmDialog('删除保存的账号？','将删除搞门户中的账号信息与本机钥匙串密码。浏览器已保存的密码和网站登录状态由浏览器管理。','删除账号',async()=>{await native('deleteAccount',{siteID:b.dataset.site,accountID:b.dataset.deleteAccount});toast('搞门户保存的账号与密码已删除。');}));
}
function initializeLauncher(){
$('searchSymbol').innerHTML=svg('search');$('dragSymbol').innerHTML=svg('drag');$('vaultButton').innerHTML=svg('vault');$('fullButton').innerHTML=svg('full');$('settingsButton').innerHTML=svg('settings');
$('addButton').onclick=()=>showEditor();$('settingsButton').onclick=showSettings;$('vaultButton').onclick=()=>showVault();$('fullButton').onclick=()=>native('fullscreen').catch(e=>toast(e.message));
$('lockButton').onclick=async()=>{try{await native(S.unlocked?'lock':'unlock');toast(S.unlocked?'账号库已解锁，5 分钟后自动锁定。':'账号库已锁定。');}catch(error){toast(error.message);}};
$('search').oninput=()=>{page=0;searchIndex=0;render();};$('search').addEventListener('keydown',handleSearchKey);$('folderClose').onclick=closeFolder;$('folderTitle').onclick=()=>renameFolder(folderID);
$('previousPage').onclick=()=>goToPage(page-1);$('nextPage').onclick=()=>goToPage(page+1);
document.querySelector('main').addEventListener('wheel',handleLauncherWheel,{passive:false});
$('folderOverlay').onclick=event=>{if(event.target===$('folderOverlay'))closeFolder();};
$('dialogOverlay').onclick=event=>{if(event.target===$('dialogOverlay'))closeDialog();};
document.addEventListener('click',event=>{if(!$('contextMenu').contains(event.target))hideContext();});
document.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&!$('cropOverlay').hidden){event.preventDefault();closeCrop();return;}
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='z'&&!event.shiftKey&&!isTextEditing(event.target)){event.preventDefault();window.mendaoUndo();return;}
  if(event.key==='Escape'){hideContext();if(!$('dialogOverlay').hidden)closeDialog();else if(folderID)closeFolder();else if(selectionMode){setSelectionMode(false);}else if($('search').value){$('search').value='';page=0;render();}else $('search').blur();}
  if((event.metaKey||event.ctrlKey)&&event.key==='f'){event.preventDefault();$('search').focus();}
  if(pagingBlocked(event.target)||event.metaKey||event.ctrlKey||event.altKey||event.shiftKey||event.isComposing)return;
  if(event.key==='ArrowRight'||event.key==='ArrowLeft'){
    const direction=event.key==='ArrowRight'?1:-1,tile=event.target.closest?.('#grid .tile');
    event.preventDefault();
    if(tile){const tiles=[...$('grid').children],next=tiles[tiles.indexOf(tile)+direction];if(next)next.focus();else goToPage(page+direction,{focusTile:true});}
    else goToPage(page+direction);
  }else if(['PageUp','PageDown','Home','End'].includes(event.key)){
    event.preventDefault();goToPage(event.key==='Home'?0:event.key==='End'?totalPages-1:page+(event.key==='PageDown'?1:-1));
  }
});
function emptyDrop(event,folder=null){if(!drag||drag.kind==='folder'&&folder)return;event.preventDefault();event.stopPropagation();const moving={...drag};drag=null;dragSourceNode=null;clearEdgePaging();clearMerge();moveTile(moving,null,folder,false,false);}
$('launchArea').addEventListener('dragover',event=>{if(drag){event.preventDefault();event.dataTransfer.dropEffect='move';}});
$('launchArea').addEventListener('dragover',handleEdgePaging,true);
$('launchArea').addEventListener('dragleave',event=>{if(!$('launchArea').contains(event.relatedTarget))clearEdgePaging();});
document.addEventListener('drop',clearEdgePaging,true);document.addEventListener('dragend',clearEdgePaging,true);
$('launchArea').addEventListener('drop',event=>emptyDrop(event));
$('folderGrid').addEventListener('dragover',event=>{if(drag&&drag.kind==='site')event.preventDefault();});
$('folderGrid').addEventListener('drop',event=>emptyDrop(event,folderID));
$('folderOut').addEventListener('dragover',event=>{if(drag){event.preventDefault();$('folderOut').classList.add('ready');}});
$('folderOut').addEventListener('dragleave',()=>$('folderOut').classList.remove('ready'));
$('folderOut').addEventListener('drop',event=>{emptyDrop(event);$('folderOut').classList.remove('ready');});
$('folderOverlay').addEventListener('dragover',event=>{if(drag&&event.target===$('folderOverlay'))event.preventDefault();});
$('folderOverlay').addEventListener('drop',event=>{if(event.target===$('folderOverlay')){emptyDrop(event);closeFolder();}});
let resizeTimer;window.addEventListener('resize',()=>{clearTimeout(resizeTimer);resizeTimer=setTimeout(render,100);});
// Available only in an explicitly launched ephemeral UI test instance.
window.mendaoTest={get state(){return S;},get draft(){return draft;},moveTile,showEditor,openFolder,showSettings,render,goToPage,get page(){return page;},get totalPages(){return totalPages;}};

}
