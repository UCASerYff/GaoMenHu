const token = document.querySelector('meta[name="gao-token"]').content;
const app = document.querySelector("#app");
let state = null;
let view = document.body.classList.contains("float-mode") ? "float" : "launch";
let query = "";
let page = 0;
let selected = new Set();
let editing = null;
let menu = null;

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: {"Content-Type": "application/json", "X-Gao-Token": token},
    body: JSON.stringify(body || {})
  });
  const data = await response.json();
  if (!data.ok && data.error) throw new Error(data.error);
  if (data.state) state = data.state;
  return data;
}

function appearance() {
  const choice = state && state.library ? state.library.appearance : "system";
  if (choice === "light" || choice === "dark") return choice;
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyChrome() {
  const library = state && state.library;
  document.body.dataset.appearance = appearance();
  document.body.dataset.density = (library && library.layoutDensity) || "compact";
  document.body.style.setProperty("--tile", ((library && library.iconSize) || 76) + "px");
}

function sitesById() {
  const map = {};
  for (const site of (state.library && state.library.sites) || []) map[site.id] = site;
  return map;
}

function ordered() {
  const map = sitesById();
  const result = [];
  for (const tile of (state.library && state.library.tiles) || []) {
    const ids = tile.kind === "folder" ? tile.children || [] : [tile.id];
    for (const id of ids) if (map[id]) result.push(map[id]);
  }
  return result;
}

function matches(site) {
  const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (!terms.length) return true;
  const key = ((state.searchKeys || {})[site.id] || "") + " " + site.name + " " + site.url + " " + (site.aliases || "");
  const text = key.toLowerCase();
  return terms.every(term => text.includes(term));
}

async function refresh() {
  const response = await fetch("/api/state", {method: "POST", headers: {"Content-Type": "application/json", "X-Gao-Token": token}, body: "{}"});
  state = await response.json();
  applyChrome();
  render();
}

function h(tag, attrs, children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === "onclick") node.addEventListener("click", value);
    else if (key === "oncontextmenu") node.addEventListener("contextmenu", value);
    else if (key === "ondragstart") node.addEventListener("dragstart", value);
    else if (key === "ondrop") node.addEventListener("drop", value);
    else if (key === "ondragover") node.addEventListener("dragover", value);
    else if (key === "onchange") node.addEventListener("change", value);
    else if (key === "oninput") node.addEventListener("input", value);
    else if (value !== null && value !== undefined) node.setAttribute(key, value);
  }
  for (const child of [].concat(children || [])) {
    if (child === null || child === undefined || child === false) continue;
    node.append(child.nodeType ? child : document.createTextNode(String(child)));
  }
  return node;
}

function render() {
  applyChrome();
  app.replaceChildren();
  if (!state || state.access === "uninitialized") {
    app.append(h("div", {class: "main"}, [
      h("div", {class: "panel"}, [
        h("h1", {}, "搞门户"),
        h("p", {}, (state && state.message) || "首次使用会在本机建立网站资料。"),
        h("button", {class: "primary", onclick: async () => { state = await api("/api/library/create"); render(); }}, "创建网站资料")
      ])
    ]));
    return;
  }
  if (state.access === "blocked") {
    app.append(h("div", {class: "main"}, [h("div", {class: "banner"}, state.message || "资料处于恢复保护状态。")]));
    return;
  }
  if (view === "float") return renderFloat();
  const shell = h("div", {class: "shell"});
  const side = h("aside", {class: "side"});
  side.append(h("div", {class: "brand"}, ["搞门户", h("small", {}, state.version)]));
  const nav = h("nav", {class: "nav"});
  for (const item of [["launch", "启动台"], ["workspaces", "工作场景"], ["accounts", "账号"], ["downloads", "下载"], ["mail", "邮件"], ["data", "资料"], ["settings", "设置"]]) {
    nav.append(h("button", {class: view === item[0] ? "active" : "", onclick: () => { view = item[0]; page = 0; render(); }}, item[1]));
  }
  nav.append(h("button", {onclick: () => window.open("/float", "gaomenhu-float", "width=400,height=640")}, "打开悬浮条"));
  side.append(nav);
  const main = h("main", {class: "main"});
  if (view === "launch") main.append(renderLaunch());
  if (view === "workspaces") main.append(renderWorkspaces());
  if (view === "accounts") main.append(renderAccounts());
  if (view === "downloads") main.append(renderDownloads());
  if (view === "mail") main.append(renderMail());
  if (view === "data") main.append(renderData());
  if (view === "settings") main.append(renderSettings());
  shell.append(side, main);
  app.append(shell);
  if (menu) app.append(menu);
}

function renderLaunch() {
  const wrap = h("section");
  const top = h("div", {class: "top"});
  const input = h("input", {class: "search", placeholder: "搜索名称、网址、拼音或简称", value: query, oninput: event => { query = event.target.value; page = 0; render(); }});
  top.append(input, h("button", {class: "primary", onclick: () => openEditor(blankSite())}, "添加网站"));
  if (selected.size) {
    top.append(h("button", {class: "ghost", onclick: () => batch("remove")}, "移出"));
    top.append(h("button", {class: "ghost", onclick: () => { const name = prompt("文件夹名称"); if (name) batch("move", {folderName: name}); }}, "放入新文件夹"));
  }
  top.append(h("button", {class: "ghost", onclick: async () => { await api("/api/undo"); render(); }}, "撤销"));
  wrap.append(top);
  const visible = ordered().filter(matches);
  const columns = Math.max(3, Math.min(10, Math.floor((document.body.clientWidth - 280) / (((state.library.iconSize || 76) + 24)))));
  const pageSize = Math.max(columns * 3, 9);
  const pages = Math.max(1, Math.ceil(visible.length / pageSize));
  page = Math.min(page, pages - 1);
  const slice = visible.slice(page * pageSize, page * pageSize + pageSize);
  const grid = h("div", {class: "grid panel"});
  for (const site of slice) grid.append(siteButton(site));
  const archived = (state.library.sites || []).filter(site => !ordered().some(item => item.id === site.id));
  wrap.append(grid);
  const pager = h("div", {class: "pager"});
  pager.append(h("button", {onclick: () => { page = Math.max(0, page - 1); render(); }}, "上一页"));
  pager.append(h("span", {}, `${page + 1} / ${pages}`));
  pager.append(h("button", {onclick: () => { page = Math.min(pages - 1, page + 1); render(); }}, "下一页"));
  wrap.append(pager);
  if (archived.length) {
    const box = h("div", {class: "panel"});
    box.append(h("h3", {}, "已移除"));
    for (const site of archived) {
      box.append(h("div", {class: "row"}, [site.name, h("button", {onclick: async () => { await api("/api/sites/restore", {id: site.id}); render(); }}, "恢复")]));
    }
    wrap.append(box);
  }
  return wrap;
}

function siteButton(site) {
  const icon = h("div", {class: "icon", style: `background:${site.color || "#635ce0"}`});
  if (site.icon) icon.append(h("img", {src: site.icon, alt: ""}));
  else icon.append((site.name || "?").slice(0, 1));
  return h("button", {
    class: "tile" + (selected.has(site.id) ? " selected" : ""),
    draggable: "true",
    ondragstart: event => event.dataTransfer.setData("text/plain", site.id),
    ondragover: event => event.preventDefault(),
    ondrop: event => dropOn(event, site.id),
    onclick: event => { if (event.shiftKey || event.metaKey || event.ctrlKey) { toggle(site.id); return; } launch(site.id); },
    oncontextmenu: event => openMenu(event, site)
  }, [icon, h("div", {class: "name"}, site.name)]);
}

function toggle(id) {
  if (selected.has(id)) selected.delete(id); else selected.add(id);
  render();
}

async function launch(id, browserID) {
  await api("/api/sites/launch", {siteID: id, browserID});
  render();
}

async function dropOn(event, targetId) {
  event.preventDefault();
  const source = event.dataTransfer.getData("text/plain");
  if (!source || source === targetId) return;
  const tiles = JSON.parse(JSON.stringify(state.library.tiles));
  const flat = [];
  for (const tile of tiles) {
    if (tile.kind === "site") flat.push(tile.id);
    else for (const child of tile.children || []) flat.push(child);
  }
  const from = flat.indexOf(source);
  const to = flat.indexOf(targetId);
  if (from < 0 || to < 0) return;
  flat.splice(to, 0, flat.splice(from, 1)[0]);
  const rebuilt = flat.map(id => ({id, kind: "site"}));
  await api("/api/layout", {tiles: rebuilt});
  render();
}

function openMenu(event, site) {
  event.preventDefault();
  menu = h("div", {class: "menu", style: `left:${event.clientX}px;top:${event.clientY}px`});
  for (const browser of site.allowedBrowsers || []) {
    menu.append(h("button", {onclick: () => { menu = null; launch(site.id, browser); }}, "用 " + browser + " 打开"));
  }
  menu.append(h("button", {onclick: () => { menu = null; openEditor(site); }}, "编辑"));
  menu.append(h("button", {onclick: () => { menu = null; prepareDownload(site.url); }}, "在下载中心复核"));
  menu.append(h("button", {onclick: async () => { menu = null; await api("/api/sites/remove", {id: site.id}); render(); }}, "移出启动台"));
  setTimeout(() => document.addEventListener("click", () => { menu = null; render(); }, {once: true}), 0);
  render();
}

function blankSite() {
  const installed = state.installedBrowsers.length ? state.installedBrowsers : ["chrome", "edge", "firefox"];
  return {name: "", url: "https://", color: "#635ce0", allowedBrowsers: installed.slice(), defaultBrowser: installed[0], accounts: [], profiles: {}, aliases: ""};
}

function openEditor(site) {
  editing = JSON.parse(JSON.stringify(site));
  const dialog = h("dialog");
  const form = h("form", {class: "sheet"});
  form.append(h("h2", {}, site.id ? "编辑网站" : "添加网站"));
  const name = h("input", {type: "text", value: editing.name || ""});
  const url = h("input", {type: "url", value: editing.url || ""});
  const aliases = h("input", {type: "text", value: editing.aliases || "", placeholder: "简称，用空格分隔"});
  form.append(h("label", {}, ["名称", name]), h("label", {}, ["网址", url]), h("label", {}, ["简称", aliases]));
  const checks = h("div", {class: "checks"});
  for (const browser of ["chrome", "edge", "safari", "firefox"]) {
    const box = h("input", {type: "checkbox"});
    box.checked = (editing.allowedBrowsers || []).includes(browser);
    box.addEventListener("change", () => {
      const set = new Set(editing.allowedBrowsers);
      if (box.checked) set.add(browser); else set.delete(browser);
      editing.allowedBrowsers = [...set];
      if (!editing.allowedBrowsers.includes(editing.defaultBrowser)) editing.defaultBrowser = editing.allowedBrowsers[0];
    });
    checks.append(h("label", {}, [box, " " + browser]));
  }
  form.append(h("div", {}, ["允许的浏览器", checks]));
  const accountName = h("input", {type: "text", placeholder: "账号备注"});
  const username = h("input", {type: "text", placeholder: "用户名"});
  const password = h("input", {type: "password", placeholder: "密码只保存在本机"});
  const host = h("input", {type: "text", placeholder: "登录域名，例如 example.com"});
  form.append(h("h3", {}, "账号"), accountName, username, password, host);
  const actions = h("div", {class: "pager"});
  actions.append(h("button", {type: "button", class: "ghost", onclick: () => dialog.close()}, "取消"));
  actions.append(h("button", {type: "button", class: "primary", onclick: async () => {
    editing.name = name.value;
    editing.url = url.value;
    editing.aliases = aliases.value;
    const passwords = [];
    if (username.value || accountName.value) {
      const id = crypto.randomUUID();
      editing.accounts = (editing.accounts || []).concat([{id, label: accountName.value, username: username.value, loginHosts: host.value ? [host.value] : [], hasPassword: !!password.value}]);
      if (!editing.defaultAccount) editing.defaultAccount = id;
      if (password.value) passwords.push({id, password: password.value});
    }
    await api("/api/sites/save", {site: editing, passwords});
    dialog.close();
    render();
  }}, "保存"));
  form.append(actions);
  dialog.append(form);
  document.body.append(dialog);
  dialog.showModal();
  dialog.addEventListener("close", () => dialog.remove());
}

async function batch(operation, extra) {
  await api("/api/batch", Object.assign({operation, siteIDs: [...selected]}, extra || {}));
  selected.clear();
  render();
}

function renderWorkspaces() {
  const box = h("section", {class: "panel"});
  box.append(h("h2", {}, "工作场景"));
  const name = h("input", {type: "text", placeholder: "场景名称"});
  box.append(name);
  const picks = h("div", {class: "list"});
  const chosen = new Set();
  for (const site of state.library.sites) {
    const boxInput = h("input", {type: "checkbox"});
    boxInput.addEventListener("change", () => { if (boxInput.checked) chosen.add(site.id); else chosen.delete(site.id); });
    picks.append(h("label", {}, [boxInput, " " + site.name]));
  }
  box.append(picks, h("button", {class: "primary", onclick: async () => {
    await api("/api/workspaces/save", {workspace: {name: name.value, siteIDs: [...chosen]}});
    render();
  }}, "保存场景"));
  for (const group of state.library.workspaces || []) {
    box.append(h("div", {class: "row"}, [
      group.name + " · " + group.siteIDs.length + " 个网站",
      h("span", {}, [
        h("button", {onclick: async () => { await api("/api/workspaces/launch", {id: group.id}); render(); }}, "打开"),
        h("button", {onclick: async () => { await api("/api/workspaces/delete", {id: group.id}); render(); }}, "删除")
      ])
    ]));
  }
  return box;
}

function renderAccounts() {
  const box = h("section", {class: "panel"});
  box.append(h("h2", {}, "账号"), h("p", {class: "muted"}, "密码用当前 Windows 用户的数据保护接口保存，不写入网站资料，也不会放进导出的备份。"));
  box.append(h("button", {class: "ghost", onclick: async () => { await api(state.vaultUnlocked ? "/api/vault/lock" : "/api/vault/unlock"); render(); }}, state.vaultUnlocked ? "锁定" : "解锁"));
  for (const site of state.library.sites) {
    for (const account of site.accounts || []) {
      box.append(h("div", {class: "row"}, [
        `${site.name} · ${account.label || account.username} · ${account.hasPassword ? "已保存密码" : "没有密码"}`,
        h("button", {onclick: async () => { await api("/api/accounts/delete", {siteID: site.id, accountID: account.id}); render(); }}, "删除")
      ]));
    }
  }
  return box;
}

function renderDownloads() {
  const box = h("section", {class: "panel"});
  box.append(h("h2", {}, "下载中心"));
  const url = h("input", {type: "url", placeholder: "https:// 文件地址"});
  const folder = h("input", {type: "text", placeholder: "保存目录，例如 D:\\\\Downloads"});
  box.append(h("p", {class: "muted"}, "先复核网址。带查询参数的地址会提示可能含有私人信息，确认后才进入队列。关闭窗口不会自动继续上次的下载。"));
  box.append(url, folder, h("button", {class: "primary", onclick: () => prepareDownload(url.value, folder.value)}, "复核并下载"));
  const items = (state.downloads && state.downloads.items) || [];
  for (const item of items) {
    box.append(h("div", {class: "row"}, [
      `${item.suggestedName} · ${item.state} · ${item.displayURL}`,
      h("span", {}, [
        h("button", {onclick: async () => { await api("/api/downloads/pause", {id: item.id}); render(); }}, "暂停"),
        h("button", {onclick: async () => { await api("/api/downloads/resume", {id: item.id, run: true}); render(); }}, "继续"),
        h("button", {onclick: async () => { await api("/api/downloads/cancel", {id: item.id}); render(); }}, "取消")
      ])
    ]));
  }
  return box;
}

async function prepareDownload(raw, folder) {
  if (!raw) return;
  const prepared = await api("/api/downloads/prepare", {urls: [raw]});
  const item = prepared.prepared[0];
  const useStrip = item.requiresPrivacyReview && confirm("这个网址含有查询参数或片段，可能带有私人信息。改用去掉参数的地址？");
  const path = folder || prompt("保存目录");
  if (!path) return;
  const destination = await api("/api/downloads/destination", {path});
  await api("/api/downloads/create", {urls: [useStrip ? item.displayURL : item.url], destinationID: destination.destination.id, strip: !!useStrip, run: true});
  view = "downloads";
  render();
}

function renderMail() {
  const box = h("section", {class: "panel"});
  box.append(h("h2", {}, "邮件"));
  box.append(h("p", {class: "muted"}, "未点击连接前只保存账号和草稿，不会登录邮箱。HTML 正文会去掉脚本和远程图片。"));
  const email = h("input", {type: "email", placeholder: "name@example.com"});
  const imap = h("input", {type: "text", placeholder: "IMAP 主机"});
  const smtp = h("input", {type: "text", placeholder: "SMTP 主机"});
  box.append(email, imap, smtp, h("button", {class: "primary", onclick: async () => {
    await api("/api/mail/account", {account: {email: email.value, imapHost: imap.value, smtpHost: smtp.value, auth: "password"}});
    render();
  }}, "保存邮箱"));
  for (const account of ((state.mail || {}).accounts) || []) {
    box.append(h("div", {class: "row"}, [account.email, h("button", {onclick: async () => { await api("/api/mail/authorize", {id: account.id}); render(); }}, "连接")]));
  }
  const sample = h("textarea", {placeholder: "把邮件正文贴在这里，提取验证码"});
  const output = h("div", {class: "muted"});
  box.append(h("h3", {}, "验证码"), sample, h("button", {onclick: async () => {
    const result = await api("/api/mail/codes", {subject: "", body: sample.value});
    output.textContent = result.primary ? result.primary.value : "没有识别到验证码";
  }}, "提取"), output);
  const aliasEmail = h("input", {type: "email", placeholder: "你的邮箱"});
  const service = h("input", {type: "text", placeholder: "平台，例如 github.com"});
  const aliasOut = h("div", {class: "muted"});
  box.append(h("h3", {}, "别名"), aliasEmail, service, h("button", {onclick: async () => {
    const result = await api("/api/mail/aliases", {email: aliasEmail.value, service: service.value});
    aliasOut.textContent = result.alias || (result.aliases || []).join("\n");
  }}, "生成"), aliasOut);
  const subject = h("input", {type: "text", placeholder: "草稿主题"});
  const body = h("textarea", {placeholder: "草稿会先保存在本机"});
  box.append(h("h3", {}, "草稿"), subject, body, h("button", {onclick: async () => {
    const account = ((state.mail || {}).accounts || [])[0];
    await api("/api/mail/draft", {draft: {accountID: account && account.id, subject: subject.value, body: body.value, to: []}});
    alert("草稿已保存。发送前会先写入发送记录，避免不确定的结果被重复提交。");
  }}, "保存草稿"));
  return box;
}

function renderData() {
  const box = h("section", {class: "panel"});
  box.append(h("h2", {}, "资料"));
  box.append(h("p", {class: "muted"}, "导出不含密码。不会自动制作备份或快照。合并时重复网址保留这边的浏览器和密码标记；恢复外来账号需要重新填写密码。"));
  box.append(h("button", {onclick: async () => {
    const data = await api("/api/backup/export");
    download("搞门户-模块备份.json", JSON.stringify(data.library, null, 2));
  }}, "导出 JSON"));
  box.append(h("button", {onclick: async () => {
    const data = await api("/api/backup/zip");
    const bytes = Uint8Array.from(atob(data.zipBase64), ch => ch.charCodeAt(0));
    const blob = new Blob([bytes], {type: "application/zip"});
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = "搞门户-完整资料.zip";
    link.click();
  }}, "导出 ZIP"));
  const file = h("input", {type: "file", accept: ".json,application/json"});
  const mode = h("select");
  mode.append(h("option", {value: "merge"}, "合并"), h("option", {value: "restore"}, "恢复排列"));
  box.append(file, mode, h("button", {class: "primary", onclick: async () => {
    const text = await file.files[0].text();
    const preview = await api("/api/backup/preview", {library: JSON.parse(text), mode: mode.value});
    if (!confirm(preview.preview.message + " 网站数 " + preview.preview.sites)) return;
    await api("/api/backup/apply", {token: preview.token, kind: "backup"});
    render();
  }}, "预览并写入"));
  const actionPath = h("input", {type: "text", placeholder: "本地 .gaoaction 目录"});
  box.append(h("h3", {}, "交接包"), actionPath, h("button", {onclick: async () => {
    const result = await api("/api/actions/open", {path: actionPath.value});
    alert(result.plan.type === "proposeSite" ? "已填入建议网站，请在编辑后自行保存。" : "已处理交接包。");
    if (result.plan && result.plan.type === "proposeSite") openEditor(Object.assign(blankSite(), {name: result.plan.title || "", url: result.plan.url}));
    render();
  }}, "打开交接包"));
  return box;
}

function download(filename, text) {
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([text], {type: "application/json"}));
  link.download = filename;
  link.click();
}

function renderSettings() {
  const box = h("section", {class: "panel"});
  box.append(h("h2", {}, "设置"));
  const density = h("select");
  for (const item of [["compact", "紧凑"], ["comfortable", "宽松"]]) {
    const option = h("option", {value: item[0]}, item[1]);
    if ((state.library.layoutDensity || "compact") === item[0]) option.selected = true;
    density.append(option);
  }
  const size = h("select");
  for (const value of [60, 76, 92]) {
    const option = h("option", {value: String(value)}, value + " px");
    if ((state.library.iconSize || 76) === value) option.selected = true;
    size.append(option);
  }
  const look = h("select");
  for (const item of [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]]) {
    const option = h("option", {value: item[0]}, item[1]);
    if ((state.library.appearance || "system") === item[0]) option.selected = true;
    look.append(option);
  }
  box.append(h("label", {}, ["布局", density]), h("label", {}, ["图标", size]), h("label", {}, ["外观", look]));
  box.append(h("button", {class: "primary", onclick: async () => {
    await api("/api/preferences", {layoutDensity: density.value, iconSize: Number(size.value)});
    await api("/api/appearance", {appearance: look.value});
    render();
  }}, "保存"));
  const dock = h("select");
  for (const item of [["right", "右侧"], ["left", "左侧"], ["none", "自由"]]) dock.append(h("option", {value: item[0]}, item[1]));
  box.append(h("h3", {}, "悬浮条"), dock, h("button", {onclick: async () => { await api("/api/floating", {enabled: true, dock: dock.value}); }}, "保存悬浮位置偏好"));
  box.append(h("p", {class: "muted"}, "Windows 没有 macOS 悬浮窗和菜单栏。悬浮条是单独的本地页面，搜索规则与 Mac 版一致：最近 3 个，再用使用次数补到 8 个。Safari 会显示在目录里，但这台电脑没有 Safari。"));
  return box;
}

function renderFloat() {
  const wrap = h("main", {class: "main"});
  const input = h("input", {class: "search", placeholder: "搜索", value: query, oninput: async event => {
    query = event.target.value;
    const data = await api("/api/floating", {query});
    const map = sitesById();
    const list = h("div", {class: "list"});
    for (const id of data.sites) if (map[id]) list.append(siteButton(map[id]));
    wrap.replaceChildren(input, list);
  }});
  wrap.append(input);
  api("/api/floating", {query}).then(data => {
    const map = sitesById();
    const list = h("div", {class: "list"});
    for (const id of data.sites) if (map[id]) list.append(siteButton(map[id]));
    wrap.append(list);
  });
  app.append(wrap);
}

refresh().catch(error => {
  app.textContent = error.message || "搞门户没有打开。";
});
