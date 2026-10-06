'use strict';
const HOST='cn.mendao.bridge',WAKE_ALARM='mendao-connection';
let port=null,profileId=null,label='默认资料',status={connected:false,error:'连接中…'},serial=0;
let initialization=null,pollPromise=null,reconnectTimer=null,reconnectAttempt=0,nextConnectAt=0;
const pending=new Map(),launches=new Map();
function initialize(){
  if(initialization)return initialization;
  initialization=(async()=>{
    const saved=await chrome.storage.local.get(['profileId','label']);
    profileId=saved.profileId||crypto.randomUUID();label=saved.label||'默认资料';
    await chrome.storage.local.set({profileId,label});
    const session=await chrome.storage.session.get('launches');
    Object.entries(session.launches||{}).forEach(([tab,id])=>{if(Number.isInteger(Number(tab))&&Number(tab)>=0&&typeof id==='string'&&id.length<=100)launches.set(Number(tab),id);});
  })().catch(()=>{initialization=null;status={connected:false,error:'无法读取助手配置，请重新启用搞门户助手。'};throw new Error(status.error);});
  return initialization;
}
function scheduleReconnect(){
  if(reconnectTimer)return;
  const delay=Math.min(30000,1000*2**Math.min(reconnectAttempt++,5));nextConnectAt=Date.now()+delay;
  reconnectTimer=setTimeout(()=>{reconnectTimer=null;void poll();},delay);
}
function connectionLost(connection,error){
  if(port!==connection)return;
  port=null;status={connected:false,error};
  for(const [rid,entry] of pending){if(entry.connection!==connection)continue;clearTimeout(entry.timer);entry.resolve({ok:false,error});pending.delete(rid);}
  scheduleReconnect();
}
function connect(){
  if(port||Date.now()<nextConnectAt)return port;
  try{
    const connection=chrome.runtime.connectNative(HOST);port=connection;
    connection.onMessage.addListener(response=>{
      if(port!==connection)return;
      const entry=pending.get(response.rid);
      if(entry&&entry.connection===connection){
        pending.delete(response.rid);clearTimeout(entry.timer);
        if(response.ok){reconnectAttempt=0;nextConnectAt=0;if(reconnectTimer){clearTimeout(reconnectTimer);reconnectTimer=null;}}
        entry.resolve(response);
      }
    });
    connection.onDisconnect.addListener(()=>{
      // Read lastError to acknowledge it; do not expose implementation paths or page data.
      const ignored=chrome.runtime.lastError;
      connectionLost(connection,'搞门户连接已断开，正在自动重连。请确认搞门户已打开。');
    });
    return connection;
  }catch(error){status={connected:false,error:'无法连接搞门户助手，请确认搞门户已安装并打开。'};scheduleReconnect();return null;}
}
function request(type,data={}){
  return new Promise(resolve=>{
    if(!profileId){resolve({ok:false,error:'连接尚未初始化。'});return;}
    const connection=connect();if(!connection){resolve({ok:false,error:status.error});return;}
    const rid=String(++serial);
    const timer=setTimeout(()=>{
      if(!pending.has(rid))return;
      connectionLost(connection,'搞门户未响应，正在重新连接。');
      try{connection.disconnect();}catch(error){}
    },9000);
    pending.set(rid,{resolve,timer,connection});
    try{connection.postMessage({type,rid,profileId,label,...data});}
    catch(error){connectionLost(connection,'搞门户连接中断，正在重新连接。');try{connection.disconnect();}catch(ignored){}}
  });
}
async function saveLaunches(){await chrome.storage.session.set({launches:Object.fromEntries(launches)});}
function validPage(value){
  try{const url=new URL(value);return ['http:','https:'].includes(url.protocol)&&url.hostname&&!url.username&&!url.password&&value.length<8192?url:null;}catch(error){return null;}
}
function poll(force=false){
  if(force){nextConnectAt=0;if(reconnectTimer){clearTimeout(reconnectTimer);reconnectTimer=null;}}
  if(pollPromise)return pollPromise;
  pollPromise=(async()=>{
    try{
      await initialize();
      // Drain a bounded queue so a multi-site workspace does not wait one interval per tab.
      for(let delivered=0;delivered<32;delivered++){
        const result=await request('poll');status={connected:!!result.ok,error:result.error||(!result.ok?'请打开搞门户 App 后重试。':''),version:result.version};
        if(!result.ok||!result.launch)break;
        const requestId=result.launch.id;let tab;
        try{
          if(typeof requestId!=='string'||!validPage(result.launch.url))throw new Error('Invalid launch');
          tab=await chrome.tabs.create({url:result.launch.url,active:true});
          if(!Number.isInteger(tab?.id))throw new Error('Missing tab');
          const bound=await request('bind',{requestId,tabId:tab.id});
          if(!bound.ok)throw new Error('Binding failed');
          launches.set(tab.id,requestId);await saveLaunches();
          await request('launchStatus',{requestId,tabId:tab.id,status:'opened'});
        }catch(error){
          if(tab?.id!==undefined){launches.delete(tab.id);await saveLaunches();}
          await request('launchStatus',{requestId,...(Number.isInteger(tab?.id)?{tabId:tab.id}:{}),status:'failed'});
          status={...status,error:'网页打开未完成，请从搞门户重试。'};
        }
      }
    }catch(error){status={connected:false,error:'助手初始化失败，请重新启用搞门户助手。'};}
    finally{pollPromise=null;}
  })();
  return pollPromise;
}
async function wake(){
  // An alarm survives service-worker suspension; the short timer is only for a live native connection.
  try{const existing=await chrome.alarms.get(WAKE_ALARM);if(!existing)await chrome.alarms.create(WAKE_ALARM,{periodInMinutes:0.5});}catch(error){}
  await poll();
}
async function popupMessage(message){
  await initialize();
  if(message.type==='status'||message.type==='reconnect'){await poll(message.type==='reconnect');return {...status,label,profileId};}
  if(message.type==='setLabel'){
    label=String(message.label||'默认资料').trim().slice(0,80)||'默认资料';
    await chrome.storage.local.set({label});await poll();return {ok:true};
  }
  if(message.type==='collections'){return request('collections');}
  if(message.type==='saveBookmark'){
    // The selected page is taken from browser metadata after the user's popup action, never a page message.
    const tabs=await chrome.tabs.query({active:true,lastFocusedWindow:true}),tab=tabs[0];
    if(!tab||typeof tab.url!=='string'||!validPage(tab.url))return {ok:false,error:'只能收藏普通的 HTTP 或 HTTPS 网页。'};
    if(message.folderID!=null&&(typeof message.folderID!=='string'||message.folderID.length>100))return {ok:false,error:'请选择有效的文件夹。'};
    const title=Array.from(String(tab.title||'').trim()||new URL(tab.url).hostname).slice(0,100).join('');
    return request('saveBookmark',{url:tab.url,title,...(message.folderID?{folderID:message.folderID}:{})});
  }
  return {ok:false,error:'不支持的操作。'};
}
chrome.runtime.onMessage.addListener((message,sender,respond)=>{
  if(!message||typeof message.type!=='string')return false;
  if(!sender.tab){
    if(sender.url!==chrome.runtime.getURL('popup.html'))return false;
    if(!['status','reconnect','setLabel','collections','saveBookmark'].includes(message.type))return false;
    popupMessage(message).then(respond).catch(()=>respond({ok:false,error:'操作未完成，请打开搞门户后重试。'}));return true;
  }
  if(sender.frameId!==0||!sender.url||!sender.url.startsWith('https:')){respond({ok:false});return false;}
  if(!['credentials','filled'].includes(message.type))return false;
  initialize().then(async()=>{
    const tabId=sender.tab.id,requestId=launches.get(tabId);
    if(!requestId){respond({ok:false});return;}
    if(message.type==='credentials'){
      // Origin, tab and grant come from browser metadata rather than the page.
      respond(await request('credentials',{requestId,tabId,url:sender.url}));return;
    }
    const result=await request('filled',{requestId,tabId,passwordFilled:message.passwordFilled===true});
    if(result.ok&&message.passwordFilled===true){launches.delete(tabId);await saveLaunches();}
    respond({ok:!!result.ok});
  }).catch(()=>respond({ok:false}));return true;
});
chrome.tabs.onRemoved.addListener(async tabId=>{try{await initialize();const requestId=launches.get(tabId);if(requestId){launches.delete(tabId);await saveLaunches();await request('close',{requestId});}}catch(error){}});
chrome.runtime.onStartup.addListener(()=>{void wake();});
chrome.runtime.onInstalled.addListener(()=>{void wake();});
chrome.alarms.onAlarm.addListener(alarm=>{if(alarm.name===WAKE_ALARM)void wake();});
setInterval(()=>{void poll();},2500);
void wake();
