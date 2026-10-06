const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path'),crypto=require('node:crypto');
const root=path.join(__dirname,'..','BrowserExtension'),script=fs.readFileSync(path.join(root,'background.js'),'utf8');
const checks=[];
function check(name,action){action();checks.push(name);}
async function settle(){for(let i=0;i<4;i++)await new Promise(resolve=>setImmediate(resolve));}
function harness(options={}){
  let now=0,nextTimer=0,connectCount=0,activePorts=0,maxActivePorts=0,tabCount=0,launchSent=false;
  const listeners={},posted=[],timers=new Map(),ports=[],alarms=new Map(),store=options.store||{},session=options.session||{};
  const queuedLaunches=options.launchQueue?[...options.launchQueue]:null;
  const state={connectFails:options.connectFails||0,hangPoll:!!options.hangPoll,createFails:!!options.createFails,bindFails:false,queryTab:{id:15,url:'https://example.test/path?view=1',title:'示例网页'},pollReplies:[]};
  const timer=(fn,delay,interval=false)=>{const id=++nextTimer;timers.set(id,{fn,at:now+delay,delay,interval});return id;};
  const chrome={
    runtime:{
      connectNative(){
        connectCount++;if(state.connectFails>0){state.connectFails--;throw new Error('Native host unavailable');}
        activePorts++;maxActivePorts=Math.max(maxActivePorts,activePorts);
        const connection={message:null,closed:false,onMessage:{addListener(fn){connection.message=fn}},onDisconnect:{addListener(fn){connection.disconnected=fn}},
          disconnect(){if(connection.closed)return;connection.closed=true;activePorts--;connection.disconnected?.();},
          postMessage(message){
            if(connection.closed)throw new Error('Disconnected');posted.push(message);
            let extra={};
            if(message.type==='poll'&&queuedLaunches){const launch=queuedLaunches.shift();if(launch)extra={launch};}
            else if(message.type==='poll'&&options.launch!==false&&!launchSent){launchSent=true;extra={launch:{id:'grant-1',url:'https://example.test'}};}
            if(message.type==='collections')extra={folders:[{id:'folder-1',name:'工作'}]};
            if(message.type==='saveBookmark')extra={message:'已收藏'};
            const response={rid:message.rid,ok:!(message.type==='bind'&&state.bindFails),version:'1.03',...extra};
            const reply=()=>connection.message?.(response);
            if(message.type==='poll'&&state.hangPoll)state.pollReplies.push(reply);else queueMicrotask(reply);
          }};
        ports.push(connection);return connection;
      },
      getURL:name=>'chrome-extension://test-id/'+name,
      onMessage:{addListener(fn){listeners.message=fn}},onStartup:{addListener(fn){listeners.startup=fn}},onInstalled:{addListener(fn){listeners.installed=fn}}
    },
    storage:{local:{async get(){return store},async set(v){Object.assign(store,v)}},session:{async get(){return session},async set(v){Object.assign(session,v)}}},
    alarms:{async get(name){return alarms.get(name)},async create(name,value){alarms.set(name,value)},onAlarm:{addListener(fn){listeners.alarm=fn}}},
    tabs:{async create(){tabCount++;if(state.createFails)throw new Error('Tab creation failed');return{id:6+tabCount}},async query(query){assert.deepEqual(JSON.parse(JSON.stringify(query)),{active:true,lastFocusedWindow:true});return state.queryTab?[state.queryTab]:[];},onRemoved:{addListener(fn){listeners.removed=fn}}}
  };
  class FakeDate extends Date{static now(){return now;}}
  const sandbox={chrome,crypto:crypto.webcrypto,URL,Date:FakeDate,setInterval:(fn,delay)=>timer(fn,delay,true),setTimeout:(fn,delay)=>timer(fn,delay),clearTimeout:id=>timers.delete(id),console};
  vm.createContext(sandbox);vm.runInContext(script,sandbox);
  return {state,listeners,posted,store,session,ports,alarms,timers,get connectCount(){return connectCount},get maxActivePorts(){return maxActivePorts},get tabCount(){return tabCount},
    async advance(ms){const end=now+ms;while(true){const item=[...timers].filter(([,t])=>t.at<=end).sort((a,b)=>a[1].at-b[1].at)[0];if(!item)break;const [id,t]=item;now=t.at;if(t.interval)t.at+=t.delay;else timers.delete(id);t.fn();await settle();}now=end;await settle();},
    message(data,sender={url:'chrome-extension://test-id/popup.html'}){return new Promise(resolve=>{const asynchronous=listeners.message(data,sender,resolve);if(asynchronous===false)resolve({ok:false});});}
  };
}
(async()=>{
  let h=harness();await settle();
  check('cold startup creates one tab and binds it',()=>{assert.equal(h.tabCount,1);assert(h.posted.some(m=>m.type==='bind'&&m.tabId===7));});
  check('opened status is sent only after tab binding',()=>{const bound=h.posted.findIndex(m=>m.type==='bind'),opened=h.posted.findIndex(m=>m.type==='launchStatus'&&m.status==='opened');assert(opened>bound);assert.equal(h.posted[opened].tabId,7);});
  check('startup registers alarm and lifecycle event listeners',()=>{assert.equal(h.alarms.get('mendao-connection').periodInMinutes,.5);assert.equal(typeof h.listeners.startup,'function');assert.equal(typeof h.listeners.installed,'function');});
  const top={tab:{id:7},frameId:0,url:'https://example.test/login'};
  let result=await h.message({type:'credentials',url:'https://evil.test',tabId:99},top);
  check('credential routing uses browser URL, tab and bound grant',()=>{assert.equal(result.ok,true);const m=h.posted.findLast(m=>m.type==='credentials');assert.equal(m.url,top.url);assert.equal(m.tabId,7);assert.equal(m.requestId,'grant-1');});
  for(const [label,sender] of [['subframe',{...top,frameId:2}],['HTTP page',{...top,url:'http://example.test'}],['unbound tab',{...top,tab:{id:8}}]]){
    const before=h.posted.length;result=await h.message({type:'credentials'},sender);check(label+' cannot request credentials',()=>{assert.equal(result.ok,false);assert.equal(h.posted.length,before);});
  }
  result=await h.message({type:'setLabel',label:'Bad'},{url:'chrome-extension://other-id/popup.html'});
  check('another extension cannot change profile',()=>assert.equal(result.ok,false));
  await h.message({type:'filled',passwordFilled:false},top);result=await h.message({type:'credentials'},top);
  check('username-only stage retains fill authorization',()=>assert.equal(result.ok,true));
  await h.message({type:'filled',passwordFilled:true},top);result=await h.message({type:'credentials'},top);
  check('password fill consumes tab authorization',()=>assert.equal(result.ok,false));
  check('session cache does not store credentials',()=>assert(!JSON.stringify(h.session).includes('password')));

  h=harness({launch:false});await settle();
  result=await h.message({type:'collections'});check('trusted popup can fetch folders',()=>{assert.equal(result.ok,true);assert.equal(result.folders[0].id,'folder-1');});
  result=await h.message({type:'saveBookmark',folderID:'folder-1',url:'https://evil.test',title:'Fake'});
  check('bookmark uses real active tab and requested folder',()=>{assert.equal(result.ok,true);const m=h.posted.findLast(m=>m.type==='saveBookmark');assert.equal(m.url,'https://example.test/path?view=1');assert.equal(m.title,'示例网页');assert.equal(m.folderID,'folder-1');});
  const before=h.posted.length;
  for(const type of ['saveBookmark','collections','reconnect','setLabel'])await h.message({type,url:'https://evil.test'},top);
  check('webpages cannot save bookmarks, enumerate folders or manage connection',()=>assert.equal(h.posted.length,before));
  result=await h.message({type:'saveBookmark'},{url:'chrome-extension://other-id/popup.html'});
  check('other extension popup cannot save a bookmark',()=>assert.equal(result.ok,false));
  for(const url of ['chrome://settings','file:///tmp/demo.html','javascript:alert(1)','https://name:password@example.test','https://example.test/'+('a'.repeat(8192))]){
    h.state.queryTab={url,title:'Invalid'};const n=h.posted.length;result=await h.message({type:'saveBookmark'});check('invalid bookmark URL rejected: '+url.split(':')[0]+(url.includes('@')?' credentials':''),()=>{assert.equal(result.ok,false);assert.equal(h.posted.length,n);});
  }
  h.state.queryTab=null;result=await h.message({type:'saveBookmark'});check('no active page reports a useful error',()=>{assert.equal(result.ok,false);assert(result.error);});
  h.state.queryTab={url:'http://example.test',title:'很'.repeat(120)};result=await h.message({type:'saveBookmark',folderID:''});
  check('HTTP bookmark title is limited and empty folder means homepage',()=>{assert.equal(result.ok,true);const m=h.posted.findLast(m=>m.type==='saveBookmark');assert.equal(m.title.length,100);assert.equal(m.folderID,undefined);});
  h.state.queryTab={url:'https://example.test',title:'🚪'.repeat(120)};await h.message({type:'saveBookmark'});check('bookmark title truncation preserves Unicode characters',()=>{const m=h.posted.findLast(m=>m.type==='saveBookmark');assert.equal(Array.from(m.title).length,100);assert(!/[\uD800-\uDBFF]$/.test(m.title));});
  result=await h.message({type:'saveBookmark',folderID:{id:'fake'}});check('invalid folder identifier cannot reach native host',()=>assert.equal(result.ok,false));

  h=harness({launch:false,connectFails:2});await settle();check('initial native-host failure makes one attempt',()=>assert.equal(h.connectCount,1));
  await h.advance(999);check('reconnection respects first backoff',()=>assert.equal(h.connectCount,1));
  await h.advance(1);check('first reconnect happens at one second',()=>assert.equal(h.connectCount,2));
  await h.advance(1500);check('periodic poll cannot bypass exponential backoff',()=>assert.equal(h.connectCount,2));
  await h.advance(500);result=await h.message({type:'status'});check('native-host recovery reconnects and verifies fresh status',()=>{assert.equal(h.connectCount,3);assert.equal(result.connected,true);assert.equal(h.maxActivePorts,1);});
  const old=h.ports.at(-1);old.disconnect();await h.advance(1000);result=await h.message({type:'status'});
  check('native port disconnect reconnects without parallel ports',()=>{assert.equal(result.connected,true);assert.equal(h.connectCount,4);assert.equal(h.maxActivePorts,1);});
  old.disconnected();result=await h.message({type:'status'});check('stale disconnect cannot close replacement connection',()=>{assert.equal(result.connected,true);assert.equal(h.connectCount,4);});

  h=harness({launch:false,hangPoll:true});await settle();
  const first=h.message({type:'status'}),second=h.message({type:'reconnect'});await settle();
  check('concurrent popup requests share one native poll',()=>{assert.equal(h.posted.filter(m=>m.type==='poll').length,1);assert.equal(h.connectCount,1);});
  h.state.hangPoll=false;h.state.pollReplies.splice(0).forEach(reply=>reply());
  const firstStatus=await first,secondStatus=await second;check('waiting popup gets verified connection',()=>{assert.equal(firstStatus.connected,true);assert.equal(secondStatus.connected,true);});
  h.state.hangPoll=true;const pendingStatus=h.message({type:'status'});await settle();await h.advance(9000);result=await pendingStatus;
  check('unresponsive native host times out and releases popup request',()=>{assert.equal(result.connected,false);assert.equal(h.ports[0].closed,true);});
  h.state.hangPoll=false;await h.advance(1000);result=await h.message({type:'status'});check('native timeout reconnects on next retry',()=>assert.equal(result.connected,true));

  h=harness({launch:false,connectFails:1});await settle();result=await h.message({type:'reconnect'});
  check('manual reconnect bypasses pending backoff',()=>{assert.equal(h.connectCount,2);assert.equal(result.connected,true);});
  h.ports.at(-1).disconnect();h.timers.clear();await h.advance(40000);h.listeners.alarm({name:'mendao-connection'});await settle();
  check('alarm restores connection when worker timers were lost',()=>assert.equal(h.connectCount,3));
  h.alarms.clear();h.listeners.startup();h.listeners.installed();await settle();
  check('browser startup and installation reestablish persistent wake alarm',()=>{assert(h.alarms.has('mendao-connection'));assert.equal(h.maxActivePorts,1);});

  h=harness({createFails:true});await settle();check('tab creation failure is reported without fabricated tab ID',()=>{const m=h.posted.find(m=>m.type==='launchStatus');assert.equal(m.status,'failed');assert.equal(m.tabId,undefined);assert(!h.posted.some(m=>m.type==='bind'));});
  h=harness();h.state.bindFails=true;await settle();check('binding failure does not grant filling and reports failure',()=>{assert(h.posted.some(m=>m.type==='launchStatus'&&m.status==='failed'));assert.equal(Object.keys(h.session.launches||{}).length,0);});
  h=harness({launch:false,store:{profileId:'existing-profile',label:'工作'},session:{launches:{7:'grant-restored'}}});
  result=await h.message({type:'credentials'},top);check('cold worker restores bound tab before credential request',()=>{assert.equal(result.ok,true);const m=h.posted.findLast(m=>m.type==='credentials');assert.equal(m.requestId,'grant-restored');assert.equal(m.profileId,'existing-profile');});
  await h.listeners.removed(7);check('closing tab revokes cached and native launch',()=>{assert.equal(h.session.launches[7],undefined);assert(h.posted.some(m=>m.type==='close'&&m.requestId==='grant-restored'));});
  const queued=Array.from({length:10},(_,index)=>({id:'scene-'+index,url:'https://example.test/'+index}));
  h=harness({launchQueue:queued});await settle();
  check('one poll drains a workspace queue without waiting a timer per tab',()=>{assert.equal(h.tabCount,10);assert.equal(h.posted.filter(m=>m.type==='bind').length,10);assert.equal(h.posted.filter(m=>m.type==='launchStatus'&&m.status==='opened').length,10);});
  check('each workspace tab binds its own authorization in native queue order',()=>{const bindings=h.posted.filter(m=>m.type==='bind');assert.deepEqual(bindings.map(m=>m.requestId),queued.map(m=>m.id));assert.equal(new Set(bindings.map(m=>m.tabId)).size,10);assert.equal(Object.keys(h.session.launches).length,10);});
  h=harness({launchQueue:Array.from({length:33},(_,index)=>({id:'bounded-'+index,url:'https://example.test/'+index}))});await settle();
  check('one poll has a bounded launch count',()=>assert.equal(h.tabCount,32));
  await h.advance(2500);check('next poll continues the remaining bounded queue',()=>assert.equal(h.tabCount,33));
  const manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'),'utf8'));
  check('alarm permission adds no new page host access',()=>{assert(manifest.permissions.includes('alarms'));assert.deepEqual(manifest.host_permissions,['https://*/*']);assert.deepEqual(manifest.content_scripts[0].matches,['https://*/*']);});
  console.log('Extension routing and recovery tests passed: '+checks.length);
})().catch(error=>{console.error(error);process.exitCode=1;});
