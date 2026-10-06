'use strict';
const $=id=>document.getElementById(id);
let refreshing=false;
async function refresh(reconnect=false){
  if(refreshing)return;refreshing=true;$('reconnect').disabled=true;$('status').textContent='正在连接搞门户…';
  try{
    const state=await chrome.runtime.sendMessage({type:reconnect?'reconnect':'status'});
    $('status').textContent=state.connected?'● 已连接搞门户 V'+state.version:'○ '+(state.error||'请打开搞门户 App。');
    $('status').classList.toggle('online',!!state.connected);
    if(document.activeElement!==$('label'))$('label').value=state.label||'默认资料';
    $('bookmark').disabled=!state.connected;
    if(state.connected){
      const result=await chrome.runtime.sendMessage({type:'collections'});
      if(!result?.ok)throw new Error(result?.error||'读取文件夹失败。');
      const chosen=$('folder').value;$('folder').replaceChildren(new Option('首页',''));
      for(const folder of result.folders||[]){if(typeof folder.id==='string'&&typeof folder.name==='string')$('folder').add(new Option(folder.name,folder.id));}
      if([...$('folder').options].some(option=>option.value===chosen))$('folder').value=chosen;
    }
  }catch(error){$('status').textContent=error.message||'连接未完成，请重试。';$('bookmark').disabled=true;}
  finally{refreshing=false;$('reconnect').disabled=false;}
}
$('reconnect').onclick=()=>refresh(true);
$('save').onclick=async()=>{
  $('save').disabled=true;
  try{const result=await chrome.runtime.sendMessage({type:'setLabel',label:$('label').value});if(!result?.ok)throw new Error(result?.error||'保存失败。');$('save').textContent='已保存';}
  catch(error){$('status').textContent=error.message||'保存失败，请重试。';}
  finally{$('save').disabled=false;setTimeout(()=>{$('save').textContent='保存名称';},1500);}
};
$('bookmark').onclick=async()=>{
  $('bookmark').disabled=true;$('bookmarkResult').textContent='正在保存…';
  try{const result=await chrome.runtime.sendMessage({type:'saveBookmark',folderID:$('folder').value});if(!result?.ok)throw new Error(result?.error||'收藏失败，请重试。');$('bookmarkResult').textContent=result.message||'已收藏到搞门户。';}
  catch(error){$('bookmarkResult').textContent=error.message||'收藏失败，请重试。';}
  finally{$('bookmark').disabled=false;}
};
void refresh();
