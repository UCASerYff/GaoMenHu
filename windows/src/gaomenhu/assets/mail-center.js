"use strict";

const mail = {
  route: "inbox", mailbox: "", folder: "INBOX", identity: "", query: "", filter: "all", detail: null, formatting: false,
  state: {accounts:[], identities:[], platforms:[], drafts:[], messages:[], submissions:[], authorized:[], preferences:{}},
  busy: false, sidebarHidden: false, detailRequest: 0,
  search: {key:"", matches:null, error:""}, searchRequest: 0, searchTimer: 0, visibleRows: 100,
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
const mailComposers = new Map();

function mailCloseState() {
  const composers = [...mailComposers.values()];
  return {busy:composers.some(composer=>composer.busy()), draft:composers.some(composer=>composer.dirty())};
}

if (center === "mail") window.gaoSaveDraftBeforeClose = async () => {
  try {
    if (mailCloseState().busy) throw new Error("邮件编辑器正在处理操作，请稍候。");
    for (const composer of mailComposers.values()) {
      if (composer.dirty()) await composer.save();
    }
    if (mailCloseState().draft) throw new Error("草稿仍有未保存的更改，请再试一次。");
    return {ok:true};
  } catch (error) {
    return {ok:false,error:error.message||"无法保存草稿，请检查后重试。"};
  }
};

function accountById(id) { return mail.state.accounts.find(account => account.id === id); }
function identityById(id) { return mail.state.identities.find(identity => identity.id === id); }
function accountLabel(account) { return account.displayName || account.email; }
const shortMailDate = new Intl.DateTimeFormat("zh-CN", {dateStyle:"short"});
const fullMailDate = new Intl.DateTimeFormat("zh-CN", {dateStyle:"short",timeStyle:"short"});
function displayDate(value, full = false) {
  if (!value) return "";
  const date = new Date(Number(value) * 1000);
  return Number.isFinite(date.getTime()) ? (full ? fullMailDate : shortMailDate).format(date) : "";
}
function filteredAccounts() {
  return mail.state.accounts.filter(account => !mail.identity || account.identityID === mail.identity);
}
function accountChoices(include, accounts = filteredAccounts()) {
  return [["",include], ...accounts.map(account => [account.id, accountLabel(account)])];
}
const mailFilters = [
  ["all","全部",null,()=>true], ["unread","未读","mail",message=>!message.isRead],
  ["starred","星标","star",message=>message.isFlagged], ["attachments","附件","attachment",message=>message.hasAttachments],
];
function mailSearchKey() {
  return mail.query.trim() ? JSON.stringify([mail.query.trim(), mail.mailbox, mail.folder, mail.identity]) : "";
}
function searchMailCache(delay = 0) {
  clearTimeout(mail.searchTimer);
  const sequence = ++mail.searchRequest;
  const key = mailSearchKey();
  if (mail.search.key !== key) mail.search = {key,matches:null,error:""};
  if (!key || mail.route !== "inbox") return;
  const [query, accountID, folder, identityID] = JSON.parse(key);
  mail.searchTimer = setTimeout(async () => {
    try {
      const result = await api("search", {query, accountID, folder, identityID});
      if (sequence !== mail.searchRequest) return;
      mail.search = {key, matches:new Map(result.matches.map(item=>[item.id,item.excerpt])), error:""};
    } catch (error) {
      if (sequence !== mail.searchRequest) return;
      mail.search = {key, matches:null, error:error.message};
    }
    if (mail.route === "inbox" && location.hash !== "#floating") renderInbox();
  }, delay);
}
function unread() {
  return mail.state.messages.filter(message => (message.folder || "INBOX") === "INBOX" && !message.isRead);
}

async function refreshMail() {
  mail.state = await api("state");
  setAppearance(mail.state.preferences.appearance);
  if (mail.route === "inbox" && location.hash !== "#floating") searchMailCache();
  renderMail();
}
async function mutateMail(action, values = {}) {
  const result = await api(action, values);
  await refreshMail();
  return result;
}

function setMailPage(route, mailbox = "") {
  mail.detailRequest++;
  mail.route = route;
  mail.mailbox = mailbox;
  mail.folder = "INBOX";
  mail.detail = null;
  mail.query = "";
  mail.filter = "all";
  mail.visibleRows = 100;
  searchMailCache();
  renderMail();
  mailBody.scrollTop = 0;
}

function startMail() {
  document.title = "搞门户 · 邮件";
  mailToolbar = el("header", {class: "toolbar"}, centerBrand("邮件中心"));
  mailSidebar = el("aside", {"aria-label": "邮件导航"});
  mailBody = el("main", {class: "body"}, loadingView("正在读取本机邮件资料"));
  const mainWindow = el("div", {class: "mail-window"}, mailToolbar, el("div", {class: "shell mail"}, mailSidebar, mailBody));
  root.replaceChildren(mainWindow);
  async function openMailLink() {
    const route = location.hash;
    const standaloneSettings = route === "#settings" || route === "#floating-settings";
    document.body.toggleAttribute("data-mail-settings", standaloneSettings);
    if (location.hash === "#floating") { renderFloatingMail(); return; }
    document.title = standaloneSettings ? "邮件设置" : "搞门户 · 邮件";
    if (!mainWindow.isConnected) { root.replaceChildren(mainWindow); renderMail(); }
    if (standaloneSettings) {
      showMailSettings(route === "#floating-settings" ? "appearance" : "module");
      sheets.lastElementChild.addEventListener("close", () => {
        if (location.hash !== route) return;
        if (window.pywebview?.api?.close_window) { window.pywebview.api.close_window(); return; }
        history.replaceState(null, "", location.pathname + location.search);
        openMailLink().catch(error => flash(error.message, true));
      }, {once:true});
    }
    if (location.hash === "#overview") setMailPage("overview");
    if (location.hash === "#accounts") setMailPage("accounts");
    if (location.hash === "#add-account") { setMailPage("accounts"); addMailAccount(); }
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
    mailToolbar.replaceChildren(centerBrand("邮件中心"));
    mailBody.replaceChildren(empty("warning","邮件资料需要恢复，已停止写入",error.message));
  });
  window.addEventListener("hashchange", () => openMailLink().catch(error => flash(error.message, true)));
  window.addEventListener("focus", () => {
    if (!mail.busy && !sheets.querySelector("dialog[open]")) refreshMail().catch(error => flash(error.message, true));
  });
  window.addEventListener("keydown", event => {
    if (event.isComposing || sheets.querySelector("dialog[open]")) return;
    if (event.key === "Escape" && mail.route === "inbox" && mail.detail && document.activeElement?.closest(".mail-reader")) {
      closeMailReader();
      return;
    }
    if (!event.ctrlKey) return;
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
  const label = mail.route === "platforms" ? "搜索平台" : "搜索缓存邮件";
  const search = el("input", {type:"search",placeholder:label,"aria-label":label,value:mail.query,maxlength:200});
  search.addEventListener("input", () => {
    mail.query = search.value;
    if (mail.route === "inbox") {
      if (mail.detail && matchMedia("(max-width: 870px)").matches) {
        mail.detail = null;
        mail.detailRequest++;
      }
      mail.visibleRows = 100;
      searchMailCache(180);
      renderInbox();
    }
    if (mail.route === "platforms") renderPlatforms();
  });
  return search;
}

function renderMail() {
  if (!mailSidebar) return;
  if (location.hash === "#floating") { renderFloatingMail(); return; }
  const shell = mailSidebar.parentElement;
  shell.classList.toggle("hide-sidebar", mail.sidebarHidden);
  const focused = document.activeElement;
  const searchFocused = focused?.matches(".center-search input");
  const searchPosition = searchFocused ? [focused.selectionStart, focused.selectionEnd] : null;
  const focusedRoute = focused?.dataset.mailRoute;
  const focusedTool = focused?.closest(".toolbar") && focused.getAttribute("aria-label");
  mailToolbar.replaceChildren(...domChildren(
    el("div", {class: "mail-toolbar-brand"},
      button(mail.sidebarHidden ? "显示导航" : "隐藏导航", () => {
        mail.sidebarHidden = !mail.sidebarHidden;
        renderMail();
        mailToolbar.querySelector(".navigation-toggle")?.focus();
      }, {symbol:"window", toolbar:true, className:"compact-action navigation-toggle"}), centerBrand("邮件中心")),
    ["inbox","platforms"].includes(mail.route) ? el("div", {class:"center-search"}, icon("search"), mailSearch()) : el("div", {class:"space"}),
    el("div", {class:"toolbar-actions"},
      button("写信", () => mailComposer(), {symbol:"edit",toolbar:true,primary:true}),
      button(mail.busy ? "正在同步…" : "同步", () => syncMail(), {symbol:"refresh",toolbar:true,disabled:mail.busy}),
      button(mail.state.preferences.floatingVisible ? "隐藏悬浮窗" : "显示悬浮窗", toggleMailFloating, {symbol:"window",toolbar:true,className:"compact-action"}),
      button("更多操作", showMailActions, {symbol:"plus",toolbar:true,className:"compact-action"}),
      button("邮件设置", showMailSettings, {symbol:"gear",toolbar:true,className:"compact-action"}))));
  const accountIDs = new Set(filteredAccounts().map(account=>account.id));
  const counts = {inbox:unread().filter(message=>accountIDs.has(message.accountID)).length, accounts:mail.state.accounts.length, platforms:mail.state.platforms.length,
    drafts:mail.state.drafts.filter(draft => !mail.state.submissions.some(record => record.draftID === draft.id && record.phase === "completed")).length};
  const scope = select([["","全部身份"],...mail.state.identities.map(identity => [identity.id,identity.name])],mail.identity);
  scope.setAttribute("aria-label", "筛选身份");
  scope.addEventListener("change", () => {
    mail.identity = scope.value;
    setMailPage(mail.route);
    mailSidebar.querySelector("select")?.focus();
  });
  mailSidebar.replaceChildren(el("nav", {class:"mail-nav", "aria-label":"邮件分区"}, mailPages.map(([route,title,symbol]) => {
      const item = nav(title,symbol,mail.route===route,() => setMailPage(route),counts[route]);
      item.dataset.mailRoute = route;
      return item;
    })),
    el("div", {class:"identity-scope"}, field("身份", scope),
      button("添加身份", () => identityEditor(), {symbol:"plus",toolbar:true,className:"compact-action"})),
    el("footer",{class:"mail-sidebar-status",role:"status"},
      el("span",{class:"mail-status-dot", "data-syncing":String(mail.busy), "aria-hidden":"true"}),
      el("small",{},mail.busy ? "正在同步邮箱" : mail.state.authorized.length ? `${mail.state.authorized.length} 个邮箱已连接` : "使用本机缓存")));
  const render = {overview:renderOverview,inbox:renderInbox,accounts:renderAccounts,platforms:renderPlatforms,drafts:renderDrafts};
  render[mail.route]();
  if (searchPosition) {
    const field = mailToolbar.querySelector("input[type=search]");
    field?.focus({preventScroll:true});
    field?.setSelectionRange(...searchPosition);
  } else if (focusedRoute) {
    mailSidebar.querySelector(`[data-mail-route="${CSS.escape(focusedRoute)}"]`)?.focus({preventScroll:true});
  } else if (focusedTool) {
    mailToolbar.querySelector(`[aria-label="${CSS.escape(focusedTool)}"]`)?.focus({preventScroll:true});
  }
}

function showMailActions() {
  const items = [["添加邮箱",addMailAccount,"mail"],["登记平台",() => platformEditor(),"link"],
    ["添加身份",() => identityEditor(),"person"],["邮箱别名助手…",() => aliasHelper(mail.mailbox),"key"]];
  sheet("邮件操作",null,el("div",{class:"stack"},items.map(([title,action,symbol]) =>
    button(title,()=>{ sheets.querySelector("dialog[open]")?.close(); return action(); },{symbol}))));
}

function renderOverview() {
  const accounts = filteredAccounts();
  const accountIDs = new Set(accounts.map(account => account.id));
  const metrics = [
    ["邮箱",accounts.length,"mail","accounts"],
    ["关联平台",mail.state.platforms.filter(item=>!mail.identity || accountIDs.has(item.accountID)).length,"link","platforms"],
    ["缓存未读",unread().filter(item=>accountIDs.has(item.accountID)).length,"tray","inbox"],
  ];
  const scope = identityById(mail.identity)?.name;
  mailBody.replaceChildren(titleHeading("邮件总览", scope && "当前身份 · " + scope,
    button("添加邮箱",addMailAccount,{symbol:"plus",primary:true})),
    el("div",{class:"content mail-overview"},
      el("div",{class:"mail-overview-metrics"},metrics.map(([title,count,symbol,route]) =>
        el("button",{type:"button",class:"metric",onclick:()=>setMailPage(route)},
          el("span",{class:"mark"},icon(symbol)),el("span",{class:"metric-caption"},title),el("strong",{},String(count)),icon("up-right")))),
      mail.state.accounts.length === 0 && el("div",{class:"card mail-overview-welcome"},el("span",{class:"mark"},icon("mail-open")),
        el("div",{class:"stack"},el("h2",{},"还没有邮箱"),
          el("p",{class:"muted"},"添加后可登记关联账号，或按需连接邮件收发。"),
          button("了解连接与授权",()=>showMailSettings("module"),{className:"link"}))),
      mail.state.accounts.length > 0 && el("section",{class:"overview-section"},el("header",{class:"row between"},el("h2",{},"邮箱"),
        accounts.length > 0 && button("查看全部",()=>setMailPage("accounts"),{className:"link"})),
        accounts.length > 0 ? el("div",{class:"account-list"},accounts.slice(0,4).map(accountCard)) :
          el("p",{class:"muted"},"此身份还没有关联邮箱。")),
      el("section",{class:"overview-section"},el("header",{class:"row between"},el("h2",{},"身份"),
        button("管理身份", showIdentities,{className:"link"})),
        mail.state.identities.length > 0 ? el("div",{class:"identity-list"},mail.state.identities.map(identity=>
          el("button",{type:"button",class:"mail-identity-card",onclick:()=>{mail.identity=identity.id;setMailPage("accounts");}},
            icon("person"),el("strong",{},identity.name),el("small",{},mail.state.accounts.filter(account=>account.identityID===identity.id).length+" 个邮箱"),icon("up-right")))) :
          el("p",{class:"muted"},"创建身份可按用途整理邮箱。"))));
}

function accountCard(account) {
  const authorized = mail.state.authorized.includes(account.id);
  const status = !account.enabled ? "仅登记" : account.syncError ? "需要处理"
    : !authorized ? "本次尚未连接" : account.lastSync ? "已连接" : "待验证";
  return el("article",{class:"mail-account-card"},
    el("span",{class:"mark"},icon("mail")),
    el("div",{class:"account-description"},el("h3",{},accountLabel(account)),
      accountLabel(account) !== account.email && el("small",{},account.email),
      el("div",{class:"row account-meta"},el("small",{},providerConfig[account.provider]?.[0] || account.provider || "IMAP"),
        identityById(account.identityID) && el("small",{},identityById(account.identityID).name),
        account.lastSync && el("small",{},"同步于 "+displayDate(account.lastSync,true))),
      account.syncError && el("small",{class:"warning"},account.syncError)),
    el("div",{class:"actions account-primary"},el("span",{class:"badge "+(account.syncError?"warning":authorized?"good":"")},status),
      account.enabled && !authorized && button("连接邮箱…",()=>connectAccount(account),{primary:true}),
      account.enabled && authorized && button("同步",()=>syncMail(account.id)),
      button("编辑",()=>editAccount(account))),
    el("div",{class:"actions account-links"},
      ["google","microsoft"].includes(account.auth) && button("重新授权…",()=>authorizeOAuth(account.auth,account)),
      button("关联平台 · " + mail.state.platforms.filter(record=>record.accountID===account.id).length,()=>setMailPage("platforms",account.id),{className:"link"}),
      button("别名助手",()=>aliasHelper(account.id),{className:"link"}),
      button("移除邮箱…",()=>confirmSheet("移除这个邮箱？","将清除本机连接凭据及邮件缓存，保留平台资料与草稿。",
        "移除邮箱",()=>mutateMail("account-delete",{id:account.id}),true),{danger:true})));
}

function renderAccounts() {
  const accounts = filteredAccounts();
  mailBody.replaceChildren(titleHeading("邮箱管理", `${accounts.length} 个邮箱`,
    button("添加邮箱",addMailAccount,{symbol:"plus",primary:true})));
  if (!accounts.length) mailBody.append(empty("mail","没有可显示的邮箱","添加邮箱，或选择其他身份。"));
  else mailBody.append(el("div",{class:"content"},el("div",{class:"account-list"},accounts.map(accountCard))));
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
  const box = titleHeading("关联平台",null,
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
  if (!items.length) mailBody.append(empty("link","没有关联平台","登记使用邮箱注册的网站或应用。"));
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
  const scope = new Map(filteredAccounts().map(account=>[account.id,account]));
  const searching = Boolean(mail.search.key);
  const matches = mail.search.matches;
  const matchesFilter = mailFilters.find(([key])=>key===mail.filter)[3];
  const messages = mail.state.messages.filter(message => scope.has(message.accountID) &&
    (!mail.mailbox || mail.mailbox === message.accountID) && (message.folder || "INBOX") === mail.folder &&
    (!searching || matches?.has(message.id)) && matchesFilter(message)).sort((a,b)=>(b.date||0)-(a.date||0));
  const account = accountById(mail.mailbox);
  const mailbox = select(accountChoices("统一收件箱"),mail.mailbox);
  mailbox.name = "mailbox";
  mailbox.addEventListener("change",()=>{
    mail.mailbox=mailbox.value;
    switchMailFolder("INBOX");
  });
  const folders=[["INBOX","收件箱"],["__local_sent__","本机发送记录"],
    ...(account?.folders||[]).filter(folder=>folder.selectable && folder.path.toUpperCase()!=="INBOX").map(folder=>[folder.path,folder.displayName])];
  const folder=select(folders,mail.folder);
  folder.name = "folder";
  folder.addEventListener("change",async()=>{
    switchMailFolder(folder.value);
    if (folder.value!=="__local_sent__" && mail.state.authorized.includes(mail.mailbox)) {
      try { await syncMail(mail.mailbox); } catch(error) { flash(error.message,true); }
    }
  });
  const previousList = mailBody.querySelector(".mail-message-list");
  const inbox = mailBody.querySelector(".mail-inbox");
  const previousReader = inbox?.lastElementChild;
  const oldScroll = previousList?.scrollTop || 0;
  const readScroll = previousReader?.dataset.openMessage === mail.detail?.id ? previousReader?.scrollTop || 0 : 0;
  const focus = document.activeElement;
  const focusedMessage = focus?.dataset.mailMessage;
  const focusedAction = focus?.closest(".mail-reader") && focus.getAttribute("aria-label");
  const focusedFilter = focus?.dataset.mailFilter;
  const focusedScope = focus?.closest(".inbox-filters") && focus.name;
  const rows = messages.slice(0,mail.visibleRows);
  const previousTabStop = previousList?.querySelector('[tabindex="0"]')?.dataset.mailMessage;
  const tabStop = rows.find(message=>message.id===(focusedMessage || previousTabStop || mail.detail?.id)) || rows[0];
  const list=el("div",{class:"list mail-message-list",role:"group","aria-label":"邮件列表"},rows.map(message=>mailMessageRow(
    message, scope.get(message.accountID), matches?.get(message.id), message===tabStop)));
  listKeyboard(list, "[data-mail-message]");
  list.addEventListener("focusin", event=>{
    if (!event.target.matches("[data-mail-message]")) return;
    const previous = list.querySelector('[tabindex="0"]');
    if (previous) previous.tabIndex = -1;
    event.target.tabIndex = 0;
  });
  if (!messages.length) list.append(mailInboxEmpty(searching, matches));
  if (rows.length < messages.length) list.append(button("加载更多",()=>{
    const next = messages[rows.length];
    mail.visibleRows += 100;
    renderInbox();
    mailBody.querySelector(`[data-mail-message="${CSS.escape(next.id)}"]`)?.focus();
  },{className:"mail-more"}));
  const rail=el("section",{class:"mail-message-rail"},el("header",{class:"message-rail-header"},
    el("div",{class:"row between message-rail-title"},el("h1",{},searching?"搜索结果":account ?
      folders.find(([key])=>key===mail.folder)?.[1] || "收件箱" : "统一收件箱"),
      el("small",{role:"status"},searching&&!matches?"本机缓存":`${messages.length} 封`)),
    el("div",{class:"inbox-filters"},field("邮箱",mailbox),account&&field("文件夹",folder)),
    el("div",{class:"mail-filter-tabs",role:"group","aria-label":"筛选邮件"},mailFilters.map(([key,label,symbol])=>el("button",{
      type:"button","aria-pressed":mail.filter===key,"data-mail-filter":key,
      title:key==="attachments"?"有已缓存附件的邮件":undefined,
      onclick:()=>{mail.filter=key;mail.visibleRows=100;renderInbox();},
    },symbol&&icon(symbol),label)))),list);
  const readerState = JSON.stringify([mail.formatting,mail.state.authorized.includes(mail.detail?.accountID),accountById(mail.detail?.accountID)?.folders]);
  const keepReader = previousReader && previousReader.mailDetail === mail.detail && previousReader.dataset.viewState === readerState;
  const reader = keepReader ? previousReader : el("section",{class:"detail mail-reader","aria-label":"邮件详情",
    "data-open-message":mail.detail?.id,"data-view-state":readerState},mail.detail ? messageDetail(mail.detail) :
      empty("mail-open","选择一封邮件"));
  reader.mailDetail = mail.detail;
  if (inbox) {
    inbox.classList.toggle("reading",Boolean(mail.detail));
    inbox.firstElementChild.replaceWith(rail);
    if (!keepReader) previousReader.replaceWith(reader);
  } else mailBody.replaceChildren(el("div",{class:"split mail-inbox"+(mail.detail?" reading":"")},rail,reader));
  list.scrollTop=oldScroll;
  if (!keepReader) reader.scrollTop=readScroll;
  if (focusedMessage) (list.querySelector(`[data-mail-message="${CSS.escape(focusedMessage)}"]`) || list.querySelector('[tabindex="0"]'))?.focus({preventScroll:true});
  if (focusedFilter) rail.querySelector(`[data-mail-filter="${CSS.escape(focusedFilter)}"]`)?.focus({preventScroll:true});
  if (focusedScope) rail.querySelector(`select[name="${CSS.escape(focusedScope)}"]`)?.focus({preventScroll:true});
  if (focusedAction && !keepReader) reader.querySelector(`[aria-label="${CSS.escape(focusedAction)}"]`)?.focus({preventScroll:true});
}

function switchMailFolder(folder) {
  mail.folder=folder;
  mail.detail=null;
  mail.detailRequest++;
  mail.visibleRows=100;
  searchMailCache();
  renderInbox();
  mailBody.querySelector(".mail-message-list").scrollTop=0;
}

function mailInboxEmpty(searching, matches) {
  if (mail.search.error) return empty("warning","无法搜索本机缓存",mail.search.error,
    button("重试",()=>{ mail.search.error="";searchMailCache();renderInbox(); }));
  if (searching) return matches ? empty("search","没有匹配的邮件","搜索范围为当前邮箱和文件夹中的主题、发件人和已缓存正文。") :
    loadingView("正在搜索本机缓存");
  if (mail.filter === "attachments") return empty("attachment","没有已缓存附件的邮件","打开邮件并读取正文后，此处会显示其中的附件。");
  if (mail.filter !== "all") return empty(mail.filter==="starred"?"star":"mail",mail.filter==="starred"?"没有星标邮件":"没有未读邮件");
  if (!mail.state.accounts.length) return empty("mail","还没有邮箱",null,button("添加邮箱",addMailAccount,{symbol:"plus",primary:true}));
  return empty("mail","没有缓存邮件",mail.state.authorized.length?"同步后查看最近的邮件。":"连接邮箱并同步后，邮件会显示在这里。");
}

function mailMessageRow(message, account, excerpt, tabStop) {
  const sender = message.from || "未知发件人";
  const subject = message.subject || "（无主题）";
  return el("button",{type:"button",class:"tile mail-message",tabindex:tabStop?0:-1,"aria-pressed":mail.detail?.id===message.id,
    "data-mail-message":message.id,"data-unread":String(!message.isRead),
    onclick:()=>selectMessage(message.id).catch(error=>flash(error.message,true))},
  el("span",{class:"mail-message-marker"},!message.isRead&&el("span",{class:"unread",role:"img","aria-label":"未读"})),
  el("span",{class:"mail-message-copy"},
    el("span",{class:"mail-message-from"},el("strong",{class:"truncate",title:sender},sender),el("small",{},displayDate(message.date))),
    el("span",{class:"mail-subject truncate",title:subject},subject),
    (excerpt||message.preview)&&el("small",{class:"mail-preview",title:excerpt||message.preview},excerpt||message.preview),
    el("span",{class:"mail-message-meta"},el("small",{class:"truncate",title:account.email},mail.mailbox ? "" : accountLabel(account)),
      message.isFlagged&&el("span",{class:"mail-message-star",role:"img","aria-label":"已加星",title:"已加星"},icon("star")),
      message.hasAttachments&&el("span",{role:"img","aria-label":"有附件",title:"有附件"},icon("attachment")),
      message.code&&el("span",{class:"badge mono"},icon("key"),message.code))));
}

async function selectMessage(id, load = false) {
  const sequence = ++mail.detailRequest;
  const moveFocus = mail.detail?.id !== id && matchMedia("(max-width: 870px)").matches;
  const result=await api("message",{id,load});
  if (mail.route !== "inbox" || sequence !== mail.detailRequest) return;
  if (load) await refreshMail();
  if (mail.route === "inbox" && sequence === mail.detailRequest) {
    if (mail.detail?.id !== id) mail.formatting = false;
    mail.detail=result.message;
    renderInbox();
    if (moveFocus) mailBody.querySelector(".mail-reader-close")?.focus();
  }
}

function closeMailReader() {
  const id=mail.detail?.id;
  mail.detail=null;
  mail.detailRequest++;
  renderInbox();
  if (id) mailBody.querySelector(`[data-mail-message="${CSS.escape(id)}"]`)?.focus({preventScroll:true});
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
      html&&button(mail.formatting?"纯文本":"排版视图",()=>{
        mail.formatting=!mail.formatting;
        renderInbox();
        mailBody.querySelector(".message-format")?.focus({preventScroll:true});
      },{className:"message-format"}),
      plain,html,
      message.attachments?.length>0&&el("h3",{},"附件 · "+message.attachments.length),
      (message.attachments||[]).map(attachment=>button(attachment.filename+" · "+bytes(attachment.byteCount),async()=>{
        const result=await api("attachment",{id:message.id,attachmentID:attachment.id});
        await saveFile(result.attachment.filename,result.attachment.base64,"application/octet-stream",true);
      },{symbol:"attachment"})));
  }
  return el("article",{class:"message-article"},el("header",{class:"message-header"},
    el("div",{class:"detail-title"},el("h1",{},message.subject||"（无主题）"),
      button("返回列表",closeMailReader,{symbol:"close",toolbar:true,className:"mail-reader-close"})),
    el("dl",{class:"message-addresses"},[["发件人",message.from||"未知发件人"],["收件人",message.to],["抄送",message.cc],["时间",displayDate(message.date,true)],["邮箱",account&&accountLabel(account)]]
      .filter(([,value])=>value).map(([label,value])=>el("div",{class:"pair"},el("dt",{},label),el("dd",{},value))))),
    actions,codeSection,content);
}

function renderDrafts() {
  const drafts=mail.state.drafts.slice().reverse().filter(draft=>!mail.state.submissions.find(record=>record.draftID===draft.id&&record.phase==="completed"));
  mailBody.replaceChildren(titleHeading("草稿",`${drafts.length} 份草稿`));
  if (!drafts.length) {
    mailBody.append(empty("file","还没有草稿","编辑中的邮件可以存为本机草稿。"));
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
  const draftIdentity=draft.id||crypto.randomUUID();
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
  const status=el("span",{class:"mail-compose-status",role:"status"},draft.id?"草稿已保存到本机":"自动保存到本机");
  const names=el("div",{class:"stack"});
  const renderAttachments=()=>names.replaceChildren(...attachments.map((item,index)=>el("div",{class:"row between"},
    el("small",{},item.filename+" · "+bytes(item.byteCount)),button("移除",()=>{
      if (sending || locked) return;
      attachments.splice(index,1);renderAttachments();editDraft();
    },{disabled:locked}))));
  chooser.addEventListener("change",async()=>{
    const files=[...chooser.files];
    if (files.length+attachments.length>24||files.reduce((total,file)=>total+file.size,0)+attachments.reduce((total,item)=>total+(item.byteCount||0),0)>25*1024*1024) {
      chooser.value="";flash("附件最多 24 个，总计 25 MB。",true);return;
    }
    const previousCount = attachments.length;
    chooser.disabled=true;
    try {
      for (const file of files) {
        const data=await new Promise((resolve,reject)=>{
          const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(",",2)[1]);
          reader.onerror=()=>reject(new Error("无法读取附件。"));reader.readAsDataURL(file);
        });
        attachments.push({id:crypto.randomUUID(),filename:file.name,type:file.type||"application/octet-stream",byteCount:file.size,base64:data});
      }
    } catch(error) { flash(error.message,true); }
    finally {
      chooser.value="";
      chooser.disabled=false;
      if (attachments.length !== previousCount) {renderAttachments();editDraft();}
      else scheduleDraftSave();
    }
  });
  const collect=()=>({id:draftIdentity,accountID:accountSelect.value,from:from.value,to:to.value.trim(),cc:cc.value.trim(),bcc:bcc.value.trim(),
    subject:subject.value,body:body.value,inReplyTo:draft.inReplyTo||((kind==="reply"||kind==="all")?reply?.messageID:""),attachments:[...attachments]});
  let revision=0;
  let savedRevision=0;
  let autosaveTimer=0;
  let sending=false;
  let saving=false;
  let closing=false;
  let confirming=false;
  let locked=false;
  const editors=[accountSelect,from,to,cc,bcc,subject,body];
  const dirty=()=>revision!==savedRevision;
  const saveStatus=(value,text)=>{status.dataset.state=value;status.textContent=text;};
  renderAttachments();
  function scheduleDraftSave() {
    clearTimeout(autosaveTimer);
    if (!dirty() || sending || saving || closing || confirming || chooser.disabled || locked) return;
    autosaveTimer=setTimeout(()=>{save().catch(()=>{});},1200);
  }
  function editDraft() {
    if (sending || locked) return;
    revision++;
    if (!saving) saveStatus("pending","有待保存的更改");
    scheduleDraftSave();
  }
  for (const editor of editors) editor.addEventListener(editor.matches("select")?"change":"input",editDraft);
  async function save() {
    if (saving) throw new Error("请等草稿保存完成。");
    if (chooser.disabled) throw new Error("请等附件读取完成。");
    clearTimeout(autosaveTimer);
    const snapshot=collect();
    const snapshotRevision=revision;
    saving=true;
    if (!sending) saveStatus("saving","正在保存草稿…");
    try {
      const result=await api("draft",{draft:snapshot});
      draft=result.draft;
      savedRevision=snapshotRevision;
      if (!sending) saveStatus(dirty()?"pending":"saved",dirty()?"有待保存的更改":"草稿已保存到本机");
      return draft;
    } catch (error) {
      saveStatus("error","草稿保存失败 · 可重试");
      throw error;
    } finally {
      saving=false;
      if (snapshotRevision !== revision) scheduleDraftSave();
    }
  }
  async function closeComposer(done) {
    if (sending||saving||closing) return;
    closing=true;
    try {
      if (dirty()) {
        await save();
        if (dirty()) throw new Error("草稿仍有未保存的更改，请再试一次。");
        flash("草稿已保存。");
      }
      done();await refreshMail();
    } finally {
      closing=false;
      if (status.dataset.state !== "error" && dialog.open) scheduleDraftSave();
    }
  }
  const close=sheet(draftId?"继续写邮件":"新邮件",null,[
    el("div",{class:"form-grid"},field("发件邮箱",accountSelect),field("发件人",from)),
    field("收件人",to),el("div",{class:"form-grid"},field("抄送",cc),field("密送",bcc)),field("主题",subject),field("正文",body),
    field("选择附件",chooser),names,
  ],done=>[
    status,
    button("关闭",()=>closeComposer(done)),
    button("存为草稿",async()=>{
      if (sending||saving||closing||locked) return;
      await save();
      if (dirty()) throw new Error("草稿仍有未保存的更改，请再试一次。");
      flash("草稿已保存。");done();await refreshMail();
    }),
    button("发送…",async()=>{
      if (sending||confirming||locked) return;
      if (saving || chooser.disabled) throw new Error("请等草稿保存和附件读取完成。");
      if (!to.value.trim()) throw new Error("请填写收件人。");
      if (!mail.state.authorized.includes(accountSelect.value)) throw new Error("请先在邮箱管理连接发件邮箱。");
      confirming=true;
      clearTimeout(autosaveTimer);
      confirmSheet("发送这封邮件？",`从 ${from.value} 发送给 ${to.value}`,"确认发送",async()=>{
        if (locked) throw new Error("请到邮箱服务商核对发送状态。");
        if (sending) return;
        sending=true;
        saveStatus("sending","正在提交发送…");
        try {
          const ready=await save();
          await api("send",{draftID:ready.id});
        } catch(error) {
          try { await refreshMail(); } catch { /* Keep the original send or save error. */ }
          locked=mail.state.submissions.some(record=>record.draftID===draftIdentity&&["accepted","uncertain","completed"].includes(record.phase));
          if (locked) {
            for (const editor of [...editors,chooser]) editor.disabled=true;
            renderAttachments();
            dialog.querySelector('[aria-label="发送…"]').disabled=true;
            dialog.querySelector('[aria-label="存为草稿"]').disabled=true;
            saveStatus("error","发送状态待核对");
          } else if (status.dataset.state !== "error") saveStatus("saved","草稿已保存到本机");
          throw error;
        } finally { sending=false; }
        done();
        flash("邮件已发送。");
        refreshMail().catch(error=>flash(error.message,true));
      });
      sheets.lastElementChild.addEventListener("close",()=>{
        confirming=false;
        if (dialog.open) scheduleDraftSave();
      },{once:true});
    },{primary:true}),
  ], "mail-compose-dialog");
  const dialog=sheets.lastElementChild;
  mailComposers.set(dialog,{dirty,save,busy:()=>sending||saving||closing||(!locked&&chooser.disabled)});
  dialog.addEventListener("close",()=>{clearTimeout(autosaveTimer);mailComposers.delete(dialog);},{once:true});
  dialog.addEventListener("cancel",async event=>{
    event.preventDefault();
    try {await closeComposer(close);}
    catch(error){flash(error.message,true);}
  });
  if (!draftId && reply) editDraft();
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

async function toggleMailFloating() {
  if (!window.pywebview?.api?.open_window) return openCenter("/mail#floating");
  const current = await api("state");
  await mutateMail("settings",{preferences:{floatingVisible:!current.preferences.floatingVisible}});
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
  const [visibleLabel,visible]=checkbox("显示邮件悬浮窗",prefs.floatingVisible===true);
  const [previewLabel,preview]=checkbox("悬浮窗显示最近三封邮件的发件人和主题",prefs.showPreviews);
  const [topLabel,top]=checkbox("悬浮窗置于其他窗口上方",prefs.keepOnTop!==false);
  const opacity=el("input",{type:"range",min:"0.65",max:"1",step:"0.01",value:prefs.floatingOpacity??1});
  const opacityValue=el("span");
  const showOpacity=()=>{opacityValue.textContent=Math.round(Number(opacity.value)*100)+"%";};
  opacity.addEventListener("input",showOpacity);
  showOpacity();
  const googleClient=el("input",{value:prefs.googleClientID||""});
  const googleSecret=el("input",{type:"password",autocomplete:"new-password",placeholder:"留空保留已保存密钥"});
  const microsoftClient=el("input",{value:prefs.microsoftClientID||""});
  const tenant=el("input",{value:prefs.microsoftTenant||"common"});
  function choose(next) {
    const keepTabFocus = tabbar.contains(document.activeElement);
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
    if (tab==="appearance") body.replaceChildren(field("颜色模式",theme),visibleLabel,previewLabel,topLabel,
      field("悬浮窗透明度",el("span",{class:"row"},opacity,opacityValue)),
      button("重置悬浮窗位置",()=>mutateMail("settings",{preferences:{floatingPlacement:null}}),{symbol:"window"}));
    if (tab==="data") body.replaceChildren(el("p",{},"邮箱、身份、关联平台及草稿保存在本机。邮件凭据独立保存在 Windows 数据保护存储。"),
      button("导出／恢复资料",mailBackup,{symbol:"exchange"}),button("导入／导出 CSV",platformCSV,{symbol:"exchange"}),
      button("打开数据文件夹",()=>api("reveal"),{symbol:"folder"}));
    if (tab==="about") body.replaceChildren(el("h2",{},"搞门户 · 邮件"),el("p",{},version),el("small",{},"邮箱 · 身份 · 平台"));
    if (keepTabFocus) tabbar.querySelector('[aria-pressed="true"]')?.focus();
  }
  choose(tab);
  sheet("邮件设置",null,settingsLayout(tabbar,body),close=>[
    button("关闭",close),button("保存设置",async()=>{
      await mutateMail("settings",{preferences:{syncMinutes:Number(sync.value),fetchLimit:Number(fetch.value),appearance:theme.value,
        floatingVisible:visible.checked,showPreviews:preview.checked,keepOnTop:top.checked,
        floatingOpacity:Number(opacity.value),googleClientID:googleClient.value.trim(),
        microsoftClientID:microsoftClient.value.trim(),microsoftTenant:tenant.value.trim()||"common"},googleSecret:googleSecret.value||undefined});
      close();
    },{primary:true}),
  ], "settings-dialog mail-settings-dialog");
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
