"use strict";

const mail = {
  route: "overview", mailbox: "", folder: "INBOX", identity: "", query: "", detail: null, formatting: false,
  state: {accounts:[], identities:[], platforms:[], drafts:[], messages:[], submissions:[], authorized:[], preferences:{}},
  busy: false, sidebarHidden: false,
};
const mailPages = [
  ["overview","总览","home"], ["inbox","邮件","tray"], ["accounts","邮箱管理","mail"],
  ["platforms","关联平台","link"], ["drafts","草稿","file"],
];
const providerConfig = {
  google: ["Gmail / Google Workspace","imap.gmail.com",993,"smtp.gmail.com",465],
  microsoft: ["Outlook / Microsoft 365","outlook.office365.com",993,"smtp.office365.com",587],
  qq: ["QQ 邮箱","imap.qq.com",993,"smtp.qq.com",465],
  netease: ["163 邮箱","imap.163.com",993,"smtp.163.com",465],
  vip163: ["VIP 163 邮箱","imap.vip.163.com",993,"smtp.vip.163.com",465],
  mailcom: ["mail.com","imap.mail.com",993,"smtp.mail.com",587],
  imap: ["其他 IMAP / SMTP","",993,"",465],
};
let mailSidebar, mailBody, mailToolbar;

function accountById(id) { return mail.state.accounts.find(account => account.id === id); }
function identityById(id) { return mail.state.identities.find(identity => identity.id === id); }
function accountLabel(account) { return account.displayName || account.email; }
function displayDate(value, full = false) {
  if (!value) return "";
  const date = new Date(Number(value) * 1000);
  return Number.isFinite(date.getTime()) ? new Intl.DateTimeFormat("zh-CN", {dateStyle: "short", ...(full ? {timeStyle: "short"} : {})}).format(date) : "";
}
function filteredAccounts() {
  return mail.state.accounts.filter(account => !mail.identity || account.identityID === mail.identity);
}
function accountChoices(include, accounts = filteredAccounts()) {
  return [["",include], ...accounts.map(account => [account.id, accountLabel(account)])];
}
function filteredMessages() {
  const accounts = new Set(filteredAccounts().map(account => account.id));
  const query = mail.query.toLocaleLowerCase();
  return mail.state.messages.filter(message => accounts.has(message.accountID) && (!mail.mailbox || mail.mailbox === message.accountID) &&
    (message.folder || "INBOX") === mail.folder && (!query || [message.from,message.subject,message.preview,message.code]
      .some(value => String(value || "").toLocaleLowerCase().includes(query)))).sort((a,b) => (b.date || 0) - (a.date || 0));
}
function unread() {
  return mail.state.messages.filter(message => (message.folder || "INBOX") === "INBOX" && !message.isRead);
}

async function refreshMail() {
  mail.state = await api("state");
  setAppearance(mail.state.preferences.appearance);
  renderMail();
}
async function mutateMail(action, values = {}) {
  const result = await api(action, values);
  await refreshMail();
  return result;
}

function setMailPage(route, mailbox = "") {
  mail.route = route;
  mail.mailbox = mailbox;
  mail.folder = "INBOX";
  mail.detail = null;
  mail.query = "";
  renderMail();
}

function startMail() {
  document.title = "搞门户 · 邮件";
  mailToolbar = el("header", {class: "toolbar"});
  mailSidebar = el("aside", {"aria-label": "邮件导航"});
  mailBody = el("main", {class: "body"});
  const mainWindow = el("div", {class: "mail-window"}, mailToolbar, el("div", {class: "shell mail"}, mailSidebar, mailBody));
  root.replaceChildren(mainWindow);
  async function openMailLink() {
    if (location.hash === "#floating") { renderFloatingMail(); return; }
    if (!mainWindow.isConnected) { root.replaceChildren(mainWindow); renderMail(); }
    if (location.hash === "#settings") showMailSettings();
    if (location.hash === "#inbox") setMailPage("inbox");
    if (location.hash === "#compose") await mailComposer();
    if (location.hash.startsWith("#message=")) {
      const id = decodeURIComponent(location.hash.slice("#message=".length));
      const message = mail.state.messages.find(value => value.id === id);
      if (message) {
        setMailPage("inbox", message.accountID);
        mail.folder = message.folder || "INBOX";
        await selectMessage(id);
      }
    }
  }
  refreshMail().then(async () => {
    await openMailLink();
    setInterval(() => {
      if (document.hidden || mail.busy || sheets.querySelector("dialog[open]")) return;
      if (location.hash === "#floating" || mail.route === "inbox") refreshMail().catch(error => flash(error.message, true));
    }, 15000);
  }).catch(error => {
    mailToolbar.replaceChildren(el("strong", {}, document.title));
    mailBody.replaceChildren(empty("warning","邮件资料需要恢复，已停止写入",error.message));
  });
  window.addEventListener("hashchange", () => openMailLink().catch(error => flash(error.message, true)));
  window.addEventListener("keydown", event => {
    if (!event.ctrlKey || sheets.querySelector("dialog[open]")) return;
    if (event.key.toLowerCase() === "n") { event.preventDefault(); mailComposer().catch(error => flash(error.message,true)); }
    if (event.key === ",") { event.preventDefault(); showMailSettings(); }
    if (event.key.toLowerCase() === "f") {
      event.preventDefault();
      if (!["inbox","platforms"].includes(mail.route)) setMailPage("inbox");
      (mailSidebar.querySelector("input[type=search]") || mailToolbar.querySelector("input[type=search]"))?.focus();
    }
  });
}

function mailSearch() {
  const search = el("input", {type:"search",placeholder:"搜索邮件或平台","aria-label":"搜索邮件或平台",value:mail.query});
  search.addEventListener("input", () => {
    mail.query = search.value;
    if (mail.route === "inbox") renderInbox();
    if (mail.route === "platforms") renderPlatforms();
  });
  return search;
}

function renderMail() {
  if (!mailSidebar) return;
  if (location.hash === "#floating") { renderFloatingMail(); return; }
  const shell = mailSidebar.parentElement;
  shell.classList.toggle("hide-sidebar", mail.sidebarHidden);
  mailToolbar.replaceChildren(...domChildren(
    button(mail.sidebarHidden ? "显示侧边栏" : "隐藏侧边栏", () => { mail.sidebarHidden = !mail.sidebarHidden; renderMail(); },
      {symbol:"window", toolbar:true}),
    mail.sidebarHidden && ["inbox","platforms"].includes(mail.route) && mailSearch(),
    el("span", {class: "space"}),
    button("显示悬浮窗", () => openCenter("/mail#floating"), {symbol:"window",toolbar:true}),
    button(mail.busy ? "正在同步…" : "同步", () => syncMail(), {symbol:"refresh",toolbar:true,disabled:mail.busy}),
    button("写信", () => mailComposer(), {symbol:"edit",primary:true,toolbar:true}),
    button("更多操作", showMailActions, {symbol:"plus",toolbar:true}),
    button("邮件设置", showMailSettings, {symbol:"gear",toolbar:true})));
  const counts = {inbox:unread().length, accounts:mail.state.accounts.length, platforms:mail.state.platforms.length,
    drafts:mail.state.drafts.filter(draft => !mail.state.submissions.some(record => record.draftID === draft.id && record.phase === "completed")).length};
  mailSidebar.replaceChildren(...domChildren(
    el("div", {class:"brand row nowrap"}, el("img",{src:"/portal-assets/Mark.png",alt:""}),
      el("div",{class:"title-copy"},el("strong",{},"搞门户 · 邮件"),el("small",{},"邮箱 · 身份 · 平台"))),
    ["inbox","platforms"].includes(mail.route) && mailSearch(),
    el("div",{class:"group"},"邮箱管理"),
    ...mailPages.map(([route,title,symbol]) => nav(title,symbol,mail.route===route,() => setMailPage(route),counts[route])),
    el("div",{class:"group spaced"},"身份"),
    nav("全部身份","person",!mail.identity,() => {mail.identity=""; mail.mailbox=""; mail.detail=null; renderMail();}),
    ...mail.state.identities.map(identity => nav(identity.name,"person",mail.identity===identity.id,() => {
      mail.identity=identity.id; mail.mailbox=""; mail.detail=null; renderMail();
    },mail.state.accounts.filter(account=>account.identityID===identity.id).length)),
    button("添加身份", () => identityEditor(), {symbol:"plus",className:"link"}),
    el("footer",{},el("hr"),el("small",{},mail.busy ? "正在同步邮箱" :
      mail.state.accounts.length+" 个邮箱 · "+mail.state.accounts.filter(account=>account.enabled).length+" 个开启收发"),
      el("small",{},"身份与平台资料保存在本机"))));
  const render = {overview:renderOverview,inbox:renderInbox,accounts:renderAccounts,platforms:renderPlatforms,drafts:renderDrafts};
  render[mail.route]();
}

function showMailActions() {
  const items = [["添加邮箱",addMailAccount,"mail"],["登记平台",() => platformEditor(),"link"],
    ["添加身份",() => identityEditor(),"person"],["邮箱别名助手…",() => aliasHelper(mail.mailbox),"key"]];
  sheet("邮件操作",null,el("div",{class:"stack"},items.map(([title,action,symbol]) =>
    button(title,()=>{ sheets.querySelector("dialog[open]")?.close(); return action(); },{symbol}))));
}

function renderOverview() {
  const cards = [
    ["邮箱",mail.state.accounts.length,"mail","已登记的邮箱"],
    ["身份",mail.state.identities.length,"person","学校、工作与生活"],
    ["关联平台",mail.state.platforms.length,"link","登记的网站和 App"],
    ["缓存未读",unread().length,"tray","最近一次同步范围"],
  ];
  mailBody.replaceChildren(el("div",{class:"content"}, el("section",{class:"card hero"},
    el("div",{class:"row between"},el("div",{class:"title-copy"},el("h1",{},"每个邮箱，都有自己的身份。"),
      el("p",{class:"muted"},"学校、工作与生活，在这里各归其位。")),el("span",{class:"mark"},icon("mail")))),
    el("div",{class:"card-grid"},cards.map(([title,count,symbol,description]) => el("div",{class:"card metric"},
      el("div",{class:"row between"},el("span",{class:"muted"},title),icon(symbol)),el("strong",{},String(count)),el("small",{},description)))),
    el("div",{class:"row between"},el("h3",{},"按身份整理"),button("管理身份", showIdentities,{className:"link"})),
    mail.state.identities.length
      ? el("div",{class:"card-grid"},mail.state.identities.map(identity=>el("div",{class:"card"},
        el("div",{class:"row between"},el("strong",{},identity.name),el("small",{},mail.state.accounts.filter(account=>account.identityID===identity.id).length+" 个邮箱")),
        identity.description && el("small",{},identity.description),button("查看邮箱",()=>{mail.identity=identity.id;setMailPage("accounts");},{className:"link"}))))
      : el("div",{class:"card"},el("h2",{},"从你的第一个邮箱开始"),
        el("p",{class:"muted"},"可以先登记邮箱和用途，再连接收发。把注册过的网站与 App 记下来，随时查找关联。"),
        el("div",{class:"actions"},button("添加邮箱",addMailAccount,{primary:true}),button("了解账号授权",()=>showMailSettings("module"),{className:"link"}))),
    mail.state.accounts.length > 0 && el("div",{class:"row between"},el("h3",{},"我的邮箱"),button("查看全部",()=>setMailPage("accounts"),{className:"link"})),
    ...filteredAccounts().slice(0,4).map(accountCard)));
}

function accountCard(account) {
  const authorized = mail.state.authorized.includes(account.id);
  const status = !account.enabled ? "仅登记" : account.syncError ? "需要处理"
    : !authorized ? "本次尚未连接" : account.lastSync ? "已连接" : "待验证";
  return el("article",{class:"card"},
    el("div",{class:"row nowrap"},el("span",{class:"mark"},icon("mail")),
      el("div",{class:"title-copy space"},el("h3",{class:"truncate"},accountLabel(account)),el("small",{class:"truncate"},account.email)),
      el("span",{class:"badge "+(account.syncError?"warning":"")},status),button("编辑",()=>editAccount(account))),
    account.syncError && el("small",{class:"warning"},account.syncError),
    el("div",{class:"row"},el("small",{},providerConfig[account.provider]?.[0] || account.provider || "IMAP"),
      identityById(account.identityID) && el("span",{class:"badge"},identityById(account.identityID).name),
      el("small",{},mail.state.platforms.filter(record=>record.accountID===account.id).length+" 个关联平台"),
      account.lastSync && el("small",{},"同步于 "+displayDate(account.lastSync,true))),
    el("div",{class:"actions"},
      account.enabled && !authorized && button("连接邮箱…",()=>connectAccount(account),{primary:true}),
      account.enabled && authorized && button("同步",()=>syncMail(account.id)),
      ["google","microsoft"].includes(account.auth) && button("重新授权…",()=>authorizeOAuth(account.auth,account)),
      button("查看关联平台",()=>setMailPage("platforms",account.id),{className:"link"}),
      button("别名助手",()=>aliasHelper(account.id),{className:"link"}),
      button("移除邮箱…",()=>confirmSheet("移除这个邮箱？","将清除本机连接凭据及邮件缓存，保留平台资料与草稿。",
        "移除邮箱",()=>mutateMail("account-delete",{id:account.id}),true),{danger:true})));
}

function renderAccounts() {
  const accounts = filteredAccounts();
  mailBody.replaceChildren(titleHeading("你的邮箱，各有归属","连接收发，或先登记身份和关联平台。",
    button("添加邮箱",addMailAccount,{symbol:"plus",primary:true})));
  if (!accounts.length) mailBody.append(empty("mail","还没有邮箱","添加邮箱来登记身份，或开启邮件收发。",button("添加邮箱",addMailAccount,{primary:true})));
  else mailBody.append(el("div",{class:"content"},accounts.map(accountCard)));
}

function connectAccount(account) {
  confirmSheet("允许搞门户连接这个邮箱？",
    "将从 Windows 凭据保护存储中读取该邮箱的凭据，仅在本次运行连接并同步。连接过程不会发送测试邮件。",
    "允许本次运行连接并同步", async () => {
      await mutateMail("authorize",{id:account.id,sync:true});
      setMailPage("inbox",account.id);
    });
}

async function syncMail(id = "") {
  if (mail.busy) return;
  const ids = id ? [id] : mail.mailbox ? [mail.mailbox] : filteredAccounts().filter(account=>mail.state.authorized.includes(account.id)).map(account=>account.id);
  if (!ids.length) { flash("请先在邮箱管理连接邮箱。",true); return; }
  if (!mail.state.authorized.includes(ids[0])) { connectAccount(accountById(ids[0])); return; }
  mail.busy = true; renderMail();
  try {
    const folder = mail.mailbox && mail.folder !== "__local_sent__" ? mail.folder : "INBOX";
    const failures = [];
    for (const id of ids) {
      try { await api("sync",{id,folder}); }
      catch(error) { failures.push(accountLabel(accountById(id))+ "： " +error.message); }
    }
    if (failures.length) throw new Error(failures.join("；"));
    flash("同步完成。");
  } finally { mail.busy=false; await refreshMail(); }
}

function addMailAccount() {
  const cards = Object.entries(providerConfig).map(([key,config]) =>
    button(config[0],()=>{
      sheets.querySelector("dialog[open]")?.close();
      return (key==="google"||key==="microsoft") ? oauthProvider(key) : editAccount(null,key);
    },{symbol:"mail"}));
  sheet("添加邮箱","选择邮箱服务商，或先登记资料。",[
    el("div",{class:"card-grid"},cards),
    button("仅登记邮箱资料",()=>{sheets.querySelector("dialog[open]")?.close();editAccount(null,"imap",true);},{symbol:"person"}),
  ]);
}

function oauthProvider(provider) {
  const configured = mail.state.preferences[provider + "ClientID"];
  sheet(providerConfig[provider][0],"使用服务商网页验证身份并开启收发。",el("div",{class:"info-block"},
    configured ? "网页登录会在系统浏览器打开。" : "尚未配置网页登录客户端。"),
    close=>[
      button("返回",close),button("打开网页登录配置…",()=>{close();showMailSettings("module");}),
      button("网页登录添加",async()=>{close();await authorizeOAuth(provider);},{primary:true,disabled:!configured}),
      button("手动配置…",()=>{close();editAccount(null,provider);}),
    ]);
}

function editAccount(account, provider = account?.provider || "imap", registerOnly = false) {
  const config = providerConfig[provider] || providerConfig.imap;
  const email = el("input",{type:"email",value:account?.email || "",required:""});
  const displayName = el("input",{value:account?.displayName || ""});
  const username = el("input",{value:account?.username || ""});
  const tags = el("input",{value:Array.isArray(account?.tags)?account.tags.join("，"):(account?.tags||"")});
  const signature = el("textarea",{},account?.signature || "");
  const aliases = el("input",{value:(account?.aliases || []).join("，")});
  const identity = select([["","未分类"],...mail.state.identities.map(value=>[value.id,value.name])],account?.identityID);
  const [enabledField,enabled] = checkbox("启用邮箱收发",account ? account.enabled : !registerOnly);
  const [imapTLSField,imapTLS] = checkbox("IMAP 使用 TLS",account?.imapTLS!==false);
  const [smtpTLSField,smtpTLS] = checkbox("SMTP 使用 TLS",account?.smtpTLS!==false);
  const imapHost = el("input",{value:account?.imapHost??config[1]});
  const imapPort = el("input",{type:"number",min:1,max:65535,value:account?.imapPort??config[2]});
  const smtpHost = el("input",{value:account?.smtpHost??config[3]});
  const smtpPort = el("input",{type:"number",min:1,max:65535,value:account?.smtpPort??config[4]});
  const password = el("input",{type:"password",autocomplete:"new-password",placeholder:account?"留空保留已保存凭据":""});
  const auth = account?.auth || "password";
  const connections = el("div",{class:"stack",hidden:!enabled.checked ? "" : undefined},
    field("连接用户名（可选）",username),
    el("div",{class:"form-grid"},field("IMAP 主机",imapHost),field("IMAP 端口",imapPort),field("SMTP 主机",smtpHost),field("SMTP 端口",smtpPort)),
    el("div",{class:"actions"},imapTLSField,smtpTLSField),
    auth==="password" && field("密码或客户端授权码",password));
  enabled.addEventListener("change",()=>{connections.hidden=!enabled.checked;});
  sheet(account?"编辑邮箱":registerOnly?"登记邮箱":config[0],null,
    [el("div",{class:"form-grid"},field("邮箱地址",email),field("显示名称",displayName),field("身份",identity),field("标签",tags)),
      enabledField,connections,field("发件别名（以逗号分隔）",aliases),field("签名",signature)],close=>[
      button("取消",close),button("保存邮箱",async()=>{
        if (!email.reportValidity()) return;
        if (enabled.checked && (!imapHost.value.trim() || !smtpHost.value.trim())) throw new Error("启用收发需填写 IMAP 和 SMTP 主机。");
        if (enabled.checked && (!imapTLS.checked || !smtpTLS.checked) && !window.confirm("所选服务器将通过明文传输邮箱凭据。仍然保存这项设置？")) return;
        await mutateMail("account",{account:{
          id:account?.id,email:email.value,displayName:displayName.value,username:username.value,
          identityID:identity.value || null,tags:splitValues(tags.value),signature:signature.value,aliases:splitValues(aliases.value),
          provider,auth,enabled:enabled.checked,imapHost:imapHost.value,imapPort:Number(imapPort.value),imapTLS:imapTLS.checked,
          smtpHost:smtpHost.value,smtpPort:Number(smtpPort.value),smtpTLS:smtpTLS.checked,
        },password:password.value || undefined});
        close(); setMailPage("accounts");
      },{primary:true}),
    ]);
}

function splitValues(value) { return String(value || "").split(/[，,；;\n]/).map(part=>part.trim()).filter(Boolean); }
function valuesText(value) { return Array.isArray(value) ? value.join(", ") : value || ""; }

function showIdentities() {
  sheet("管理身份",null,el("div",{class:"stack"},mail.state.identities.map(identity=>el("div",{class:"row between"},
    el("strong",{},identity.name),el("div",{class:"actions"},button("编辑",()=>identityEditor(identity)),
      button("删除…",()=>confirmSheet("删除这个身份？","关联邮箱将改为未分类。","删除身份",
        async()=>{await mutateMail("record-delete",{kind:"identities",id:identity.id});sheets.querySelector("dialog[open]")?.close();},true),{danger:true}))))),
  close=>[button("关闭",close),button("添加身份",()=>{close();identityEditor();},{primary:true})]);
}

function identityEditor(identity) {
  const name = el("input",{value:identity?.name || "",required:""});
  const description = el("textarea",{},identity?.description || "");
  const color = el("input",{type:"color",value:identity?.color || "#635cde"});
  sheet(identity?"编辑身份":"添加身份",null,[field("名称",name),field("说明",description),field("颜色",color)],close=>[
    button("取消",close),button("保存",async()=>{
      if (!name.reportValidity()) return;
      await mutateMail("record",{kind:"identities",record:{id:identity?.id,name:name.value,description:description.value,color:color.value}});
      close();
    },{primary:true}),
  ]);
}

function renderPlatforms() {
  const box = titleHeading("这个账号，用的是哪个邮箱？","手动记下关联，随时双向查找。",
    el("div",{class:"actions"},button("导入／导出 CSV",platformCSV,{symbol:"exchange"}),
      button("登记平台",()=>platformEditor(),{symbol:"plus",primary:true})));
  const mailbox = select(accountChoices("所有邮箱"),mail.mailbox);
  mailbox.addEventListener("change",()=>{mail.mailbox=mailbox.value;renderPlatforms();});
  const query = mail.query.toLocaleLowerCase();
  const items = mail.state.platforms.filter(record=>(!mail.mailbox||record.accountID===mail.mailbox) &&
    (!mail.identity||filteredAccounts().some(account=>account.id===record.accountID)) &&
    (!query||[record.name,record.url,record.username,record.address,record.notes].some(value=>String(value||"").toLocaleLowerCase().includes(query))));
  const list = el("div",{class:"content"},el("div",{class:"row between"},field("邮箱",mailbox),el("small",{},items.length+" 条记录")));
  if (items.length) list.append(...items.map(record=>{
    const email=record.address||accountById(record.accountID)?.email||"未关联邮箱";
    return el("article",{class:"card"},el("div",{class:"row nowrap"},el("span",{class:"mark"},record.name.slice(0,1).toUpperCase()),
      el("div",{class:"title-copy space"},el("strong",{},record.name),el("small",{class:"truncate"},record.username||record.url||record.kind||"")),
      el("span",{class:"badge"},record.status||"使用中")),
      el("div",{class:"row"},el("small",{},email),record.loginMethod&&el("small",{},record.loginMethod),
        record.roles?.length>0&&el("small",{},record.roles.join(" · "))),
      el("div",{class:"actions"},button("编辑",()=>platformEditor(record)),button("复制关联邮箱",()=>clipboard(email),{disabled:email==="未关联邮箱"}),
        button("删除…",()=>confirmSheet("删除平台记录？","此操作只删除本机登记。","删除记录",
          ()=>mutateMail("record-delete",{kind:"platforms",id:record.id}),true),{danger:true})));
  }));
  mailBody.replaceChildren(box,list);
  if (!items.length) mailBody.append(empty("link","没有关联平台","登记使用邮箱注册的网站或 App。",button("登记平台",()=>platformEditor(),{primary:true})));
}

function platformEditor(record = {}) {
  const controls = Object.fromEntries(["name","url","username","address","loginMethod","roles","notes"].map(key=>[key,
    key==="notes" ? el("textarea",{},record[key]||"") : el("input",{value:valuesText(record[key])})]));
  const account = select(accountChoices("未关联邮箱",mail.state.accounts),record.accountID||mail.mailbox);
  const kinds = select([["网站","网站"],["App","App"],["其他","其他"]],record.kind||"网站");
  const status = select([["使用中","使用中"],["暂停使用","暂停使用"],["已注销","已注销"]],record.status||"使用中");
  sheet(record.id?"编辑平台":"登记平台",null,[
    el("div",{class:"form-grid"},field("平台名称",controls.name),field("类型",kinds),field("网址",controls.url),
      field("关联邮箱",account),field("使用的邮箱／别名",controls.address),field("用户名",controls.username),
      field("登录方式",controls.loginMethod),field("角色",controls.roles),field("状态",status)),field("备注",controls.notes),
  ],close=>[button("取消",close),button("保存",async()=>{
    const values=Object.fromEntries(Object.entries(controls).map(([key,input])=>[key,key==="roles"?splitValues(input.value):input.value]));
    await mutateMail("record",{kind:"platforms",record:{...record,...values,kind:kinds.value,status:status.value,accountID:account.value||null}});
    close();setMailPage("platforms",account.value);
  },{primary:true})]);
}

function platformCSV() {
  const importer=el("input",{type:"file",accept:".csv,text/csv"});
  sheet("关联平台 CSV",null,field("选择 CSV 文件",importer),close=>[
    button("关闭",close),button("导出 CSV",async()=>{
      const result=await api("platforms-csv");await saveFile("搞门户-关联平台.csv","\ufeff"+result.csv,"text/csv;charset=utf-8");
    }),
    button("导入 CSV",async()=>{
      const file=importer.files[0];if (!file||file.size>1000000) throw new Error("请选择不超过 1 MB 的 CSV 文件。");
      if (!window.confirm("导入将添加 CSV 中的关联平台记录。继续？")) return;
      const result=await mutateMail("platforms-csv",{text:await file.text()});flash("已添加 "+result.count+" 条记录。");close();
    },{primary:true}),
  ]);
}

function aliasHelper(accountId = "") {
  const accounts=select(accountChoices("输入邮箱",mail.state.accounts),accountId);
  const address=el("input",{type:"email",value:accountById(accountId)?.email||""});
  const service=el("input",{placeholder:"例如 github.com"});
  const count=el("input",{type:"number",min:1,max:100,value:8});
  const [dotsField,dots]=checkbox("Gmail 圆点变体",true);
  const [plusField,plus]=checkbox("加号标签",true);
  const [googleField,google]=checkbox("googlemail.com 域名",false);
  const results=el("div",{class:"stack"});
  accounts.addEventListener("change",()=>{address.value=accountById(accounts.value)?.email||"";});
  sheet("邮箱别名助手","别名的可用性由邮箱服务商和注册平台决定。",[
    field("邮箱",accounts),field("邮箱地址",address),field("指定平台（可选）",service),field("生成数量",count),
    el("div",{class:"actions"},dotsField,plusField,googleField),results,
  ],close=>[
    button("关闭",close),button("生成别名",async()=>{
      if (!address.value || !address.reportValidity()) throw new Error("请填写邮箱地址。");
      const result=await api("aliases",{email:address.value,service:service.value,count:Number(count.value),
        options:{useDots:dots.checked,usePlus:plus.checked,useGooglemailDomain:google.checked}});
      const aliases=result.aliases||[result.alias];
      results.replaceChildren(...aliases.map(alias=>el("div",{class:"row between"},el("code",{class:"mono"},alias),
        el("div",{class:"actions"},button("复制",()=>clipboard(alias)),button("登记平台",()=>{
          close();platformEditor({name:service.value,accountID:accounts.value||null,address:alias});
        })))));
    },{primary:true}),
  ]);
}
function renderInbox() {
  const messages = filteredMessages();
  const account = accountById(mail.mailbox);
  const mailbox = select(accountChoices("统一收件箱"),mail.mailbox);
  mailbox.addEventListener("change",()=>{mail.mailbox=mailbox.value;mail.folder="INBOX";mail.detail=null;renderInbox();});
  const folders=[["INBOX","收件箱"],["__local_sent__","本机发送记录"],
    ...(account?.folders||[]).filter(folder=>folder.selectable && folder.path.toUpperCase()!=="INBOX").map(folder=>[folder.path,folder.displayName])];
  const folder=select(folders,mail.folder);
  folder.addEventListener("change",async()=>{
    mail.folder=folder.value;mail.detail=null;renderInbox();
    if (folder.value!=="__local_sent__" && mail.state.authorized.includes(mail.mailbox)) {
      try { await syncMail(mail.mailbox); } catch(error) { flash(error.message,true); }
    }
  });
  const filter=el("div",{class:"heading row between"},
    el("div",{class:"actions"},field("邮箱",mailbox),account&&field("文件夹",folder)),el("small",{},"最近 "+messages.length+" 封"));
  const previousScroll=mailBody.querySelector(".list")?.scrollTop||0;
  const list=el("div",{class:"list"},messages.slice(0,500).map(message=>el("button",{type:"button",class:"tile",
    "aria-pressed":mail.detail?.id===message.id,onclick:()=>selectMessage(message.id).catch(error=>flash(error.message,true))},
    el("div",{class:"row nowrap"},!message.isRead&&el("span",{class:"unread","aria-label":"未读"}),
      el("strong",{class:"truncate space"},message.from||"未知发件人"),message.isFlagged&&icon("star"),el("small",{},displayDate(message.date))),
    el("span",{},message.subject||"（无主题）"),
    el("small",{class:"truncate"},message.preview||accountById(message.accountID)?.email||""),
    message.code&&el("span",{class:"badge mono"},icon("key"),message.code))));
  if (!messages.length) list.append(el("p",{class:"muted empty-rows"},mail.query?"没有匹配的邮件。":"没有缓存邮件。"));
  const detail=el("div",{class:"detail"});
  detail.append(mail.detail ? messageDetail(mail.detail) : empty("mail","选择一封邮件","在邮件列表中选择邮件查看详情。"));
  mailBody.replaceChildren(filter,el("div",{class:"split mail-inbox"},list,detail));
  list.scrollTop=previousScroll;
}

async function selectMessage(id, load = false) {
  const result=await api("message",{id,load});
  mail.detail=result.message;
  if (load) mail.state.messages= (await api("state")).messages;
  renderInbox();
}

function messageDetail(message) {
  const account=accountById(message.accountID);
  const isSent=message.folder==="__local_sent__";
  const online=mail.state.authorized.includes(message.accountID)&&!isSent;
  const moves=select([["","移至文件夹"],...(account?.folders||[]).filter(folder=>folder.selectable&&folder.path!==(message.folder||"INBOX"))
    .map(folder=>[folder.path,folder.displayName])],"");
  moves.addEventListener("change",()=>{
    if (!moves.value) return;
    confirmSheet("移动这封邮件？","邮件将在服务器上移至所选文件夹。","移动邮件",async()=>{
      await api("message-move",{id:message.id,folder:moves.value});mail.detail=null;await refreshMail();
    });
  });
  const actions=el("div",{class:"actions"},
    button("回复",()=>mailComposer(null,message,"reply"),{disabled:!message.loaded}),
    button("回复全部",()=>mailComposer(null,message,"all"),{disabled:!message.loaded}),
    button("转发正文",()=>mailComposer(null,message,"forward"),{disabled:!message.loaded}),
    online&&button(message.isRead?"标为未读":"标为已读",async()=>{await api("message-flag",{id:message.id,flag:"read"});await refreshMail();await selectMessage(message.id);}),
    online&&button(message.isFlagged?"取消星标":"添加星标",async()=>{await api("message-flag",{id:message.id,flag:"star"});await refreshMail();await selectMessage(message.id);},{symbol:"star"}),
    online&&moves.options.length>1&&moves);
  const codeSection=(message.codes||[]).filter(item=>item.confidence>=.5).slice(0,6).map(code=>
    el("div",{class:"info-block"},el("div",{class:"row between"},el("strong",{},code.type==="link"?"验证链接":"验证码"),
      el("small",{},"置信度 "+Math.round(100*code.confidence)+"%")),el("span",{class:"mono truncate"},code.value),
      el("div",{class:"actions"},button(code.type==="link"?"复制链接":"复制验证码",()=>clipboard(code.value)),
        code.type==="link"&&button("在浏览器打开…",()=>confirmSheet("打开邮件中的验证链接？",code.value,"打开链接",
          ()=>api("open-link",{id:message.id,url:code.value}))))));
  let content;
  if (!message.loaded) content=online
    ? button("读取正文",()=>selectMessage(message.id,true),{primary:true})
    : el("div",{class:"info-block"},el("p",{},"正文尚未缓存。"),
      account&&button("连接邮箱…",()=>connectAccount(account),{primary:true}));
  else {
    const plain=el("div",{class:"message-body"},message.body||"这封邮件没有纯文本正文，可以切换到排版视图查看。");
    const html=message.html&&el("iframe",{class:"message-html",title:"邮件排版视图",sandbox:"",hidden:!mail.formatting?"":undefined});
    if (html) html.srcdoc="<!doctype html><meta charset=utf-8><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\"><style>:root{color-scheme:light dark}body{font:14px/1.65 Segoe UI,sans-serif;overflow-wrap:anywhere;margin:12px}pre{white-space:pre-wrap}table{max-width:100%}</style>"+message.html;
    if (mail.formatting&&html) plain.hidden=true;
    content=el("div",{class:"stack"},
      html&&button(mail.formatting?"纯文本":"排版视图",()=>{mail.formatting=!mail.formatting;renderInbox();}),
      plain,html,
      message.attachments?.length>0&&el("h3",{},"附件 · "+message.attachments.length),
      (message.attachments||[]).map(attachment=>button(attachment.filename+" · "+bytes(attachment.byteCount),async()=>{
        const result=await api("attachment",{id:message.id,attachmentID:attachment.id});
        await saveFile(result.attachment.filename,result.attachment.base64,"application/octet-stream",true);
      },{symbol:"attachment"})));
  }
  return el("article",{class:"stack"},actions,el("hr"),el("h1",{},message.subject||"（无主题）"),
    el("div",{class:"title-copy muted"},el("small",{},"发件人："+(message.from||"")),el("small",{},"收件人："+(message.to||"")),
      message.cc&&el("small",{},"抄送："+message.cc),el("small",{},displayDate(message.date,true))),
    codeSection,content);
}

function renderDrafts() {
  const drafts=mail.state.drafts.slice().reverse().filter(draft=>!mail.state.submissions.find(record=>record.draftID===draft.id&&record.phase==="completed"));
  mailBody.replaceChildren(titleHeading("留给下一次继续写",null,button("新建邮件",()=>mailComposer(),{primary:true,symbol:"edit"})));
  if (!drafts.length) {
    mailBody.append(empty("file","还没有草稿","可以先把编辑中的邮件保存到本机。",button("新建邮件",()=>mailComposer(),{primary:true})));
    return;
  }
  mailBody.append(el("div",{class:"content"},drafts.map(draft=>{
    const record=mail.state.submissions.find(record=>record.draftID===draft.id&&["accepted","uncertain"].includes(record.phase));
    return el("article",{class:"card"},el("div",{class:"row between"},el("div",{class:"title-copy"},
      el("h3",{},draft.subject||"（无主题）"),el("small",{},draft.to?.length?"发给："+valuesText(draft.to):"尚未填写收件人"),
      el("small",{},displayDate(draft.updatedAt,true))),
      el("div",{class:"actions"},record
        ? button("查看发送状态",()=>sheet("正在核对发送状态","本机未记录服务商确认。请到邮箱网页核对，避免重复发送。"))
        : button("继续写",()=>mailComposer(draft.id)),
        button("删除…",()=>confirmSheet("删除这份草稿？",null,"删除草稿",()=>mutateMail("record-delete",{kind:"drafts",id:draft.id}),true),
          {danger:true,disabled:Boolean(record)}))));
  })));
}

function quoteMessage(message) {
  return "\n\n────────── 原邮件 ──────────\n发件人："+(message.from||"")+"\n时间："+displayDate(message.date,true)+
    "\n主题："+(message.subject||"")+"\n\n"+(message.body||"").split("\n").map(line=>"> "+line).join("\n");
}

async function mailComposer(draftId, reply, kind) {
  if (!mail.state.accounts.length) { addMailAccount(); return; }
  let draft=draftId?(await api("draft-read",{id:draftId})).draft:{};
  const account=accountById(draft.accountID||reply?.accountID||mail.mailbox)||mail.state.accounts[0];
  const accountSelect=select(mail.state.accounts.map(item=>[item.id,accountLabel(item)]),account.id);
  const from=select([],draft.from);
  const updateFrom=()=>{
    const selected=accountById(accountSelect.value);
    const addresses=[selected.email,...(selected.aliases||[])];
    from.replaceChildren(...addresses.map(address=>el("option",{value:address},address)));
    from.value=addresses.includes(draft.from)?draft.from:selected.email;
  };
  updateFrom();
  accountSelect.addEventListener("change",updateFrom);
  const receivedFrom=reply?.replyTo||reply?.from||"";
  const to=el("input",{value:valuesText(draft.to)||(reply&&kind!=="forward"?receivedFrom:"")});
  const cc=el("input",{value:valuesText(draft.cc)||(kind==="all"?[reply.to,reply.cc].filter(Boolean).join(", "):"")});
  const bcc=el("input",{value:valuesText(draft.bcc)});
  const subject=el("input",{value:draft.subject??(reply?(kind==="forward"?"Fwd: ":"Re: ")+(reply.subject||""):"")});
  const body=el("textarea",{rows:9},draft.body??((account.signature?"\n\n"+account.signature:"")+(reply?quoteMessage(reply):"")));
  const chooser=el("input",{type:"file",multiple:""});
  const attachments=(draft.attachments||[]).slice();
  const names=el("div",{class:"stack"});
  const renderAttachments=()=>names.replaceChildren(...attachments.map((item,index)=>el("div",{class:"row between"},
    el("small",{},item.filename+" · "+bytes(item.byteCount)),button("移除",()=>{attachments.splice(index,1);renderAttachments();}))));
  chooser.addEventListener("change",async()=>{
    const files=[...chooser.files];
    if (files.length+attachments.length>24||files.reduce((total,file)=>total+file.size,0)+attachments.reduce((total,item)=>total+(item.byteCount||0),0)>25*1024*1024) {
      chooser.value="";flash("附件最多 24 个，总计 25 MB。",true);return;
    }
    chooser.disabled=true;
    try {
      for (const file of files) {
        const data=await new Promise((resolve,reject)=>{
          const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(",",2)[1]);
          reader.onerror=()=>reject(new Error("无法读取附件。"));reader.readAsDataURL(file);
        });
        attachments.push({id:crypto.randomUUID(),filename:file.name,type:file.type||"application/octet-stream",byteCount:file.size,base64:data});
      }
      renderAttachments();
    } catch(error) { flash(error.message,true); }
    finally { chooser.value="";chooser.disabled=false; }
  });
  renderAttachments();
  const collect=()=>({id:draft.id,accountID:accountSelect.value,from:from.value,to:to.value.trim(),cc:cc.value.trim(),bcc:bcc.value.trim(),
    subject:subject.value,body:body.value,inReplyTo:draft.inReplyTo||((kind==="reply"||kind==="all")?reply?.messageID:""),attachments});
  let signature=JSON.stringify(collect());
  let sending=false;
  let closing=false;
  async function save() {
    if (chooser.disabled) throw new Error("请等附件读取完成。");
    const result=await api("draft",{draft:collect()});draft=result.draft;signature=JSON.stringify(collect());
    return draft;
  }
  const close=sheet(draftId?"继续写邮件":"新邮件",null,[
    el("div",{class:"form-grid"},field("发件邮箱",accountSelect),field("发件人",from)),
    field("收件人",to),el("div",{class:"form-grid"},field("抄送",cc),field("密送",bcc)),field("主题",subject),field("正文",body),
    field("选择附件",chooser),names,
  ],done=>[
    button("关闭",async()=>{if (sending||closing) return;closing=true;try {
      if (signature!==JSON.stringify(collect())) {await save();flash("草稿已保存。");}
      done();await refreshMail();
    } finally {closing=false;}}),
    button("存为草稿",async()=>{if (sending) return;await save();flash("草稿已保存。");done();await refreshMail();}),
    button("发送…",async()=>{
      if (sending) return;
      if (!to.value.trim()) throw new Error("请填写收件人。");
      if (!mail.state.authorized.includes(accountSelect.value)) throw new Error("请先在邮箱管理连接发件邮箱。");
      confirmSheet("发送这封邮件？","收件人 "+to.value,"确认发送",async()=>{
        if (sending) return;
        sending=true;
        try {
          const ready=await save();
          await api("send",{draftID:ready.id});done();await refreshMail();flash("邮件已发送。");
        } catch(error) { await refreshMail();throw error; }
        finally { sending=false; }
      });
    },{primary:true}),
  ]);
  const dialog=sheets.lastElementChild;
  dialog.addEventListener("cancel",async event=>{
    event.preventDefault();
    if (sending||closing) return;
    closing=true;
    try {
      if (signature!==JSON.stringify(collect())) {await save();flash("草稿已保存。");}
      close();await refreshMail();
    } catch(error){flash(error.message,true);}
    finally {closing=false;}
  });
}

function renderFloatingMail() {
  document.title="搞门户 · 邮件悬浮窗";
  const unreadMail=unread().sort((a,b)=>(b.date||0)-(a.date||0));
  const latest=mail.state.accounts.reduce((time,account)=>Math.max(time,account.lastSync||0),0);
  const show=mail.state.preferences.showPreviews;
  const errors=mail.state.accounts.filter(account=>account.syncError).length;
  root.replaceChildren(el("div",{class:"floating stack"},
    el("div",{class:"row between"},el("strong",{},"搞门户 · 邮件"),
      el("span",{class:"badge "+(errors?"warning":"")},mail.busy?"正在同步":errors?errors+" 个邮箱待检查":"本机缓存"),
      button("关闭",()=>window.pywebview?.api?.close_window?window.pywebview.api.close_window():window.close(),{symbol:"close",toolbar:true})),
    !mail.state.accounts.length
      ? el("div",{class:"card"},el("strong",{},"把邮箱带到桌面"),el("small",{},"添加邮箱后，在这里查看缓存未读数量和同步状态。"))
      : !show ? el("div",{class:"card"},el("strong",{},"邮件预览已隐藏"),
        el("small",{},unreadMail.length?"有 "+unreadMail.length+" 封缓存未读邮件，打开收件箱查看。":"当前缓存中没有未读邮件。"))
      : unreadMail.length ? unreadMail.slice(0,3).map(message=>el("div",{class:"card"},
        el("small",{class:"truncate"},message.from||"未知发件人"),
        button(message.subject||"（无主题）",()=>openCenter("/mail#message="+encodeURIComponent(message.id)),{className:"link"}),
        message.code&&button("复制 "+message.code,()=>clipboard(message.code),{symbol:"key"})))
      : el("div",{class:"card"},"暂无缓存未读邮件"),
    el("div",{class:"actions"},button("打开邮件",()=>openCenter("/mail#inbox"),{symbol:"mail",primary:true}),
      button("同步",()=>syncMail(),{symbol:"refresh",disabled:mail.busy}),button("写信",()=>openCenter("/mail#compose"),{symbol:"edit"}),
      button("设置",()=>openCenter("/mail#settings"),{symbol:"gear"})),
    el("div",{class:"row between"},el("small",{},latest?"最近同步 "+displayDate(latest,true):"尚未同步"),
      el("small",{},"最近同步范围"))));
}

function showMailSettings(initial="module") {
  const tabbar=el("div",{class:"tabs"});
  const body=el("div",{class:"stack"});
  let tab=initial;
  const prefs=mail.state.preferences;
  const choices=[["module","模块设置"],["appearance","外观"],["data","数据"],["about","关于"]];
  const intervals=[...new Set([0,1,3,5,15,30,prefs.syncMinutes??15])].sort((a,b)=>a-b);
  const limits=[...new Set([30,80,150,300,prefs.fetchLimit??50])].sort((a,b)=>a-b);
  const sync=select(intervals.map(value=>[value,value?value+" 分钟":"手动同步"]),prefs.syncMinutes??15);
  const fetch=select(limits.map(value=>[value,value+" 封邮件"]),prefs.fetchLimit??50);
  const theme=select([["system","跟随系统"],["light","浅色"],["dark","深色"]],prefs.appearance||"system");
  const [previewLabel,preview]=checkbox("悬浮窗显示最近三封邮件的发件人和主题",prefs.showPreviews);
  const [topLabel,top]=checkbox("悬浮窗置于其他窗口上方",prefs.keepOnTop!==false);
  const googleClient=el("input",{value:prefs.googleClientID||""});
  const googleSecret=el("input",{type:"password",autocomplete:"new-password",placeholder:"留空保留已保存密钥"});
  const microsoftClient=el("input",{value:prefs.microsoftClientID||""});
  const tenant=el("input",{value:prefs.microsoftTenant||"common"});
  function choose(next) {
    tab=next;
    tabbar.replaceChildren(...choices.map(([id,title])=>{
      const option=button(title,()=>choose(id));option.setAttribute("aria-pressed",tab===id);return option;
    }));
    if (tab==="module") body.replaceChildren(field("自动同步间隔",sync),field("每个文件夹同步最近",fetch),
      el("small",{},"仅在本次运行已获连接授权的邮箱才参与自动同步。"),el("hr"),el("h3",{},"网页登录配置"),
      field("Google 客户端 ID",googleClient),field("Google 客户端密钥",googleSecret),
      field("Microsoft 客户端 ID",microsoftClient),field("Microsoft 租户",tenant),
      button("查看授权配置说明…",async()=>{
        const result=await api("oauth-guide");
        sheet("邮件网页登录配置",null,el("div",{class:"stack"},result.guide.map(line=>el("p",{},line))));
      }),button("清除 Google 客户端密钥…",()=>confirmSheet("清除 Google 客户端密钥？","使用该密钥的授权可能需要重新登录。",
        "清除密钥",()=>api("oauth-secret-clear"),true),{danger:true}));
    if (tab==="appearance") body.replaceChildren(field("颜色模式",theme),previewLabel,topLabel,
      button("显示邮件悬浮窗",()=>openCenter("/mail#floating"),{symbol:"window"}));
    if (tab==="data") body.replaceChildren(el("p",{},"邮箱、身份、关联平台及草稿保存在本机。邮件凭据独立保存在 Windows 数据保护存储。"),
      button("导出／恢复资料",mailBackup,{symbol:"exchange"}),button("导入／导出 CSV",platformCSV,{symbol:"exchange"}),
      button("打开数据文件夹",()=>api("reveal"),{symbol:"folder"}));
    if (tab==="about") body.replaceChildren(el("h2",{},"搞门户 · 邮件"),el("p",{},version),el("small",{},"邮箱 · 身份 · 平台"));
  }
  choose(tab);
  sheet("邮件设置",null,[tabbar,body],close=>[
    button("关闭",close),button("保存设置",async()=>{
      await mutateMail("settings",{preferences:{syncMinutes:Number(sync.value),fetchLimit:Number(fetch.value),appearance:theme.value,
        showPreviews:preview.checked,keepOnTop:top.checked,googleClientID:googleClient.value.trim(),
        microsoftClientID:microsoftClient.value.trim(),microsoftTenant:tenant.value.trim()||"common"},googleSecret:googleSecret.value||undefined});
      close();
    },{primary:true}),
  ]);
}

function mailBackup() {
  const source=el("input",{type:"file",accept:".json,application/json"});
  sheet("邮件资料备份",null,[el("p",{},"备份包含邮箱设置、身份、关联平台及草稿。邮箱密码和令牌保存在本机。"),
    field("选择备份文件",source)],close=>[
    button("返回",close),button("导出资料备份",async()=>{
      const result=await api("backup");
      await saveFile("搞门户-邮件资料.json",JSON.stringify(result.library,null,2),"application/json");
    }),
    button("恢复资料…",async()=>{
      const file=source.files[0];if (!file||file.size>25000000) throw new Error("请选择不超过 25 MB 的邮件备份 JSON 文件。");
      const library=JSON.parse(await file.text());
      if (!window.confirm("将把备份中的身份、平台、草稿及缺少的邮箱合并到当前资料。继续？")) return;
      await mutateMail("restore",{library});close();flash("邮件资料已合并。");
    },{primary:true}),
  ]);
}

async function authorizeOAuth(provider, account) {
  if (!mail.state.preferences[provider+"ClientID"]) { showMailSettings("module"); return; }
  const started=await api("oauth-start",{provider,id:account?.id});
  const status=el("p",{role:"status"},"请在系统浏览器中选择邮箱账号并完成授权。");
  let timer;
  let active=true;
  let waiting=false;
  const close=sheet("网页登录",providerConfig[provider][0],status,done=>[
    button("取消授权",async()=>{active=false;clearInterval(timer);try{await api("oauth-cancel",{id:started.id});}finally{done();}}),
  ]);
  const dialog=sheets.lastElementChild;
  dialog.addEventListener("cancel",()=>{active=false;clearInterval(timer);api("oauth-cancel",{id:started.id}).catch(()=>{});});
  timer=setInterval(async()=>{
    if (!active||waiting) return;
    waiting=true;
    try {
      const state=await api("oauth-status",{id:started.id});
      if (state.status==="complete") {
        active=false;clearInterval(timer);close();await refreshMail();setMailPage("inbox",state.accountID);await syncMail(state.accountID);
      } else if (state.status==="failed") {
        active=false;clearInterval(timer);status.textContent=state.message;status.classList.add("warning");
      } else if (state.status==="checking") status.textContent="已返回应用，正在验证收发登录。";
    } catch(error){active=false;clearInterval(timer);status.textContent=error.message;}
    finally {waiting=false;}
  },1000);
}

if (center==="mail") startMail();
