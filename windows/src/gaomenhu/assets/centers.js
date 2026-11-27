"use strict";

const root = document.querySelector("#center");
const notices = document.querySelector("#notice");
const sheets = document.querySelector("#sheets");
const center = location.pathname.split("/")[1];
const token = document.querySelector('meta[name="gao-token"]').content;
const version = document.querySelector('meta[name="gao-version"]').content;
const icons = {
  tray: "M3 5h18l1 10v4H2v-4L3 5zm-1 10h6l2 2h4l2-2h6",
  download: "M12 3v12m-5-5 5 5 5-5M4 16v4h16v-4",
  pause: "M8 6v12m8-12v12",
  play: "M8 5l12 7-12 7z",
  check: "M4 12l5 5L20 6",
  warning: "M12 8v5m0 3v.1M3 20h18L12 4 3 20z",
  exchange: "M3 7h17m-4-4 4 4-4 4M21 17H4m4-4-4 4 4 4",
  plus: "M12 4v16M4 12h16",
  gear: "M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1 1-3zm6 9a3 3 0 1 1-6 0 3 3 0 0 1 6 0z",
  folder: "M3 6h7l2 2h9v11H3z",
  file: "M5 3h9l5 5v13H5zM14 3v5h5m-7 3v6m-3-3 3 3 3-3",
  search: "M15.5 9a6.5 6.5 0 1 1-13 0 6.5 6.5 0 0 1 13 0zM14 14l7 7",
  info: "M12 11v6m0-10v.1m9 4.9a9 9 0 1 1-18 0 9 9 0 0 1 18 0z",
  mail: "M3 6h18v13H3zM3 7l9 7 9-7",
  person: "M15 8a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM4 20c0-7 16-7 16 0",
  link: "M10 7l2-2a4 4 0 0 1 6 6l-3 3m-1 3-2 2a4 4 0 0 1-6-6l3-3m0 5 6-6",
  edit: "M5 16l-1 4 4-1L20 7l-3-3-12 12zm10-10 3 3",
  refresh: "M4 12a8 8 0 1 1 2 6m-2-1v4m0-4h5",
  window: "M3 4h15v12H3zM8 16v4h13V9h-3",
  close: "M5 5l14 14M19 5 5 19",
  lock: "M6 10h12v10H6zm2 0V7a4 4 0 0 1 8 0v3",
  star: "M12 3l2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-2.9-5.6 2.9 1.1-6.2L3 9.6l6.2-.9z",
  key: "M14 6a4 4 0 1 1 4 4L9 19H5v-4l8-8",
  attachment: "M11 8l5-5c3-3 7 1 4 4L9 18c-4 4-8 0-4-4l9-9m-7 9 8-8",
  home: "M3 11l9-8 9 8m-16-2v11h14V9",
};

function domChildren(...children) {
  return children.flat(Infinity).filter(child => child !== undefined && child !== null && child !== false);
}

function el(name, attrs = {}, ...kids) {
  const node = document.createElement(name);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null) continue;
    if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else if (key === "checked" || key === "disabled") node[key] = Boolean(value);
    else if (key === "value") node.value = value;
    else node.setAttribute(key, value);
  }
  node.append(...domChildren(kids));
  return node;
}

function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  const path = document.createElementNS(svg.namespaceURI, "path");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("aria-hidden", "true");
  path.setAttribute("d", icons[name] || icons.info);
  svg.append(path);
  return svg;
}

let noticeTimer;
function flash(text, isError = false) {
  clearTimeout(noticeTimer);
  notices.textContent = text;
  notices.classList.toggle("warning", isError);
  noticeTimer = setTimeout(() => { notices.textContent = ""; }, isError ? 9000 : 3500);
}

function button(text, callback, {symbol, primary, disabled, toolbar, danger, className} = {}) {
  const node = el("button", {type: "button", title: text, "aria-label": text, disabled,
    class: [primary && "primary", toolbar && "tool-icon", danger && "danger", className].filter(Boolean).join(" ")
  }, symbol && icon(symbol), toolbar ? el("span", {class: "tool-label"}, text) : text);
  node.addEventListener("click", async () => {
    node.disabled = true;
    try { await callback(); }
    catch (error) {
      const issue = node.closest("dialog")?.querySelector(".sheet-error");
      if (issue) issue.textContent = error.message || "操作没有完成。";
      else flash(error.message || "操作没有完成。", true);
    }
    finally { node.disabled = Boolean(disabled); }
  });
  return node;
}

async function api(action, body = {}) {
  const result = await fetch("/api/" + center + "/" + action, {
    method: "POST", headers: {"Content-Type": "application/json", "X-Gao-Token": token}, body: JSON.stringify(body),
  });
  const data = await result.json();
  if (!data.ok) throw new Error(data.error || "操作没有完成。");
  return data;
}

function field(title, input) {
  return el("label", {class: "field"}, el("span", {}, title), input);
}

function checkbox(title, checked) {
  const input = el("input", {type: "checkbox", checked});
  return [el("label", {class: "field check"}, input, el("span", {}, title)), input];
}

function select(choices, value) {
  const node = el("select", {}, choices.map(([key, label]) => el("option", {value: key}, label)));
  node.value = String(value ?? "");
  return node;
}

function nav(title, symbol, current, choose, count) {
  const row = button(title, choose, {symbol, className: "nav-row"});
  if (current) row.setAttribute("aria-current", "page");
  if (count !== undefined) row.append(el("i", {class: "space"}), el("small", {}, count));
  return row;
}

function empty(symbol, title, text, action) {
  return el("div", {class: "empty"}, icon(symbol), el("h2", {}, title), text && el("p", {}, text), action);
}

function titleHeading(title, detail, action) {
  return el("header", {class: "heading"}, el("div", {class: "title-copy"},
    el("h1", {}, title), detail && el("p", {class: "muted"}, detail)), action);
}

function sheet(title, description, body, actions) {
  const dialog = el("dialog");
  const close = () => dialog.close();
  dialog.append(el("section", {class: "sheet"}, el("header", {}, el("h2", {}, title),
    description && el("p", {class: "muted"}, description)), body, el("div", {class: "sheet-error warning", role: "status"}),
    el("footer", {}, actions?.(close) || [button("关闭", close)])));
  dialog.addEventListener("close", () => dialog.remove(), {once: true});
  sheets.append(dialog);
  dialog.showModal();
  return close;
}

function confirmSheet(title, detail, confirm, action, danger = false) {
  sheet(title, detail, null, close => [
    button("返回", close), button(confirm, async () => { await action(); close(); }, {primary: !danger, danger}),
  ]);
}

function setAppearance(appearance) {
  document.documentElement.dataset.appearance = appearance || "system";
}

async function openCenter(path) {
  if (window.pywebview?.api?.open_window) await window.pywebview.api.open_window(path);
  else window.open(path, "_blank", "noopener");
}

async function pickDirectory(action, title = "选择目录") {
  if (window.pywebview?.api?.choose_folder) {
    const path = await window.pywebview.api.choose_folder();
    if (path) await action(Array.isArray(path) ? path[0] : path);
    return;
  }
  const control = el("input", {type: "text", placeholder: "C:\\Downloads"});
  sheet(title, "输入已存在目录的完整 Windows 路径。", field("目录路径", control), close => [
    button("取消", close), button("选择", async () => { await action(control.value.trim()); close(); }, {primary: true}),
  ]);
}

async function clipboard(value) {
  if (navigator.clipboard?.writeText) {
    try { await navigator.clipboard.writeText(value); flash("已复制。"); return; }
    catch { /* Windows WebView clipboard permission can be disabled. */ }
  }
  const textarea = el("textarea", {readonly: ""}, value);
  sheet("复制内容", null, textarea);
  textarea.select();
}

function bytes(count) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let amount = Number(count) || 0;
  let unit = 0;
  while (amount >= 1000 && unit < units.length - 1) { amount /= 1000; unit++; }
  return new Intl.NumberFormat("zh-CN", {maximumFractionDigits: unit > 0 ? 1 : 0}).format(amount) + " " + units[unit];
}

async function saveFile(filename, data, type = "application/octet-stream", encoded = false) {
  if (encoded && window.pywebview?.api?.save_blob) {
    await window.pywebview.api.save_blob(filename, data);
    return;
  }
  const blob = new Blob([encoded ? Uint8Array.from(atob(data), char => char.charCodeAt(0)) : data], {type});
  const url = URL.createObjectURL(blob);
  const link = el("a", {href: url, download: filename.replace(/[\\/]/g, "_")});
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

const downloadSections = [
  ["all", "全部任务", "tray", () => true],
  ["active", "正在下载", "download", entry => ["queued", "running", "pausing", "verifying", "committing"].includes(entry.state)],
  ["paused", "已暂停 / 等待", "pause", entry => ["paused", "waitingForNetwork", "waitingForDestination", "retryScheduled"].includes(entry.state)],
  ["completed", "已完成", "check", entry => entry.state === "completed"],
  ["failed", "失败 / 取消", "warning", entry => ["failed", "cancelled", "partial"].includes(entry.state)],
  ["exchange", "跨应用请求", "exchange"],
];
const downloadStatus = {
  queued: "等待开始", running: "正在下载", pausing: "正在暂停", verifying: "正在校验", committing: "正式落盘",
  paused: "已暂停", waitingForNetwork: "等待网络", waitingForDestination: "等待目录授权", retryScheduled: "等待重试",
  completed: "已完成", partial: "部分下载", failed: "失败", cancelled: "已取消",
};
const download = {section: "all", selected: null, query: "", limit: 100, state: {items: [], destinations: [], requests: [], settings: {}, busy: []}};
let downloadBody;
let downloadSidebar;
let downloadStatusbar;

async function refreshDownloads() {
  download.state = await api("state");
  setAppearance(download.state.settings.appearance);
  renderDownloadState();
}

async function mutateDownload(action, body) {
  const result = await api(action, body);
  download.state = result;
  setAppearance(result.settings.appearance);
  renderDownloadState();
  return result;
}

function startDownloads() {
  document.title = "搞门户 · 下载";
  downloadSidebar = el("aside", {"aria-label": "下载分类"});
  downloadBody = el("div", {class: "body"});
  downloadStatusbar = el("footer", {class: "statusbar"});
  const search = el("input", {type: "search", placeholder: "搜索文件名或来源", "aria-label": "搜索文件名或来源"});
  search.addEventListener("input", () => { download.query = search.value; renderDownloadState(); });
  const toolbar = el("div", {class: "toolbar"}, el("strong", {class: "window-title"}, document.title),
    search, button("新建下载", () => composeDownload(), {symbol: "plus", toolbar: true}),
    button("暂停全部", () => mutateDownload("pause-all"), {symbol: "pause", toolbar: true}),
    button("恢复全部", () => mutateDownload("resume-all"), {symbol: "play", toolbar: true}),
    button("下载设置", showDownloadSettings, {symbol: "gear", toolbar: true}));
  root.replaceChildren(el("div", {class: "shell"}, downloadSidebar,
    el("main", {}, toolbar, downloadBody, downloadStatusbar)));
  async function openDownloadLink() {
    const params = new URLSearchParams(location.search);
    if (params.has("site") || params.has("review")) {
      const result = await api("prepare", {siteID: params.get("site"), review: params.get("review")});
      composeDownload({urls: result.prepared.map(entry => entry.url)});
    } else if (location.hash === "#new") composeDownload();
    else if (location.hash === "#settings") showDownloadSettings();
    else if (location.hash.startsWith("#request=")) {
      download.section = "exchange";
      renderDownloadState();
      const request = download.state.requests.find(record => record.id === location.hash.slice(9));
      if (request?.stage === "awaitingReview") await reviewRequest(request);
    }
  }
  refreshDownloads().then(async () => {
    await openDownloadLink();
    setInterval(() => {
      if (download.state.busy.length || download.state.items.some(entry => entry.state === "queued")) {
        refreshDownloads().catch(error => flash(error.message, true));
      }
    }, 1200);
  }).catch(error => {
    downloadBody.replaceChildren(empty("warning", "资料需要恢复，已停止写入", error.message));
    toolbar.querySelectorAll("button").forEach(control => { control.disabled = true; });
  });
  window.addEventListener("hashchange", () => openDownloadLink().catch(error => flash(error.message, true)));
  window.addEventListener("keydown", event => {
    if (!event.ctrlKey || sheets.querySelector("dialog[open]")) return;
    if (event.key.toLowerCase() === "n") { event.preventDefault(); composeDownload(); }
    if (event.key === ",") { event.preventDefault(); showDownloadSettings(); }
    if (event.key.toLowerCase() === "f") { event.preventDefault(); search.focus(); }
  });
}

function renderDownloadState() {
  if (!downloadSidebar) return;
  const scroll = downloadBody.querySelector(".list")?.scrollTop || 0;
  const focus = document.activeElement?.dataset?.downloadId;
  const selected = downloadSections.find(section => section[0] === download.section);
  const items = download.state.items;
  const records = download.state.requests;
  downloadSidebar.replaceChildren(el("div", {class: "group"}, "下载"),
    ...downloadSections.flatMap(([id, title, symbol, match]) => [
      id === "exchange" && el("div", {class: "group spaced"}, "交接"),
      nav(title, symbol, id === download.section, () => {
        download.section = id; download.selected = null; download.limit = 100; renderDownloadState();
      }, match ? items.filter(match).length : records.filter(entry => entry.stage === "awaitingReview").length),
    ]).filter(Boolean), el("footer", {}, el("hr"), el("div", {class: "row"}, icon("info"), "仅在应用运行时下载"),
      el("small", {}, "退出会暂停，重新打开后由你恢复。")));
  downloadStatusbar.replaceChildren(el("span", {}, items.filter(entry => entry.state === "running").length + " 项传输中"),
    el("span", {}, "校验和正式落盘完成后才记为完成"));
  if (download.section === "exchange") {
    renderExchange(records);
    return;
  }
  const query = download.query.trim().toLocaleLowerCase();
  const matching = items.filter(selected[3]).filter(entry =>
    !query || [entry.suggestedName, entry.displayURL].some(value => value.toLocaleLowerCase().includes(query))).reverse();
  downloadBody.replaceChildren(el("header", {class: "heading"},
    el("div", {class: "title-line"}, el("h1", {}, selected[1]), el("small", {}, matching.length + " 个任务")),
    download.state.settings.speedLimitBytesPerSecond ? el("small", {}, "限速 " + bytes(download.state.settings.speedLimitBytesPerSecond) + "/s") : null));
  if (!matching.length) {
    downloadBody.append(empty(query ? "search" : "file", query ? "没有匹配的任务" : "从一个链接开始",
      query ? "尝试文件名或来源主机名。" : "粘贴 HTTP 或 HTTPS 文件直链，确认保存位置后下载。",
      !query && button("新建下载…", () => composeDownload(), {primary: true})));
    return;
  }
  const current = matching.find(entry => entry.id === download.selected);
  const list = el("div", {class: "list"});
  for (const item of matching.slice(0, download.limit)) {
    const row = el("button", {class: "tile", type: "button", "aria-pressed": item.id === current?.id,
      "data-download-id": item.id, onclick: () => { download.selected = item.id; renderDownloadState(); }},
      el("div", {class: "row nowrap"},
        el("span", {class: "mark"}, icon("file")),
        el("div", {class: "stack space"}, el("strong", {class: "truncate"}, item.artifact?.fileName || item.suggestedName),
          el("small", {class: "truncate"}, item.displayURL)),
        el("span", {class: "badge " + (item.state === "completed" ? "good" : item.error ? "warning" : "")}, downloadStatus[item.state] || item.state)),
      downloadProgress(item), el("small", {}, downloadCounts(item)));
    list.append(row);
  }
  if (matching.length > download.limit) list.append(button("再显示 100 个", () => { download.limit += 100; renderDownloadState(); }));
  downloadBody.append(el("div", {class: "split" + (current ? " with-detail" : "")}, list, current && downloadDetail(current)));
  list.scrollTop = scroll;
  if (focus) list.querySelector('[data-download-id="' + CSS.escape(focus) + '"]')?.focus({preventScroll: true});
}

function downloadCounts(item) {
  return [bytes(item.bytesReceived), item.totalBytes != null ? " / " + bytes(item.totalBytes) : "",
    item.speed ? " · " + bytes(item.speed) + "/s" : ""].join("");
}

function downloadProgress(item) {
  if (!item.totalBytes && !["running", "verifying", "committing"].includes(item.state)) return null;
  return el("progress", {max: item.totalBytes || 1, value: item.totalBytes ? item.bytesReceived : undefined, "aria-label": "传输进度"});
}

function downloadDetail(item) {
  const destination = download.state.destinations.find(grant => grant.id === item.destinationID);
  const active = downloadSections[1][3](item);
  const terminal = ["completed", "partial", "failed", "cancelled"].includes(item.state);
  const working = download.state.busy.includes(item.id);
  const current = (action, options) => mutateDownload(action, {id: item.id, ...options});
  const rows = [["来源", item.displayURL], ["保存位置", destination?.displayPath || "未授权"],
    ["已收到", downloadCounts(item)], ["SHA-256", item.artifact?.sha256], ["完成文件", item.artifact?.fileName]];
  return el("section", {class: "detail"}, el("h2", {}, item.artifact?.fileName || item.suggestedName),
    el("div", {class: "row"}, el("span", {class: "badge"}, downloadStatus[item.state] || item.state)),
    downloadProgress(item),
    item.error && el("div", {class: "info-block warning"}, item.error),
    el("dl", {class: "info-block"}, rows.filter(([,value]) => value).map(([key, value]) =>
      el("div", {class: "pair"}, el("dt", {class: "muted"}, key), el("dd", {class: key === "SHA-256" ? "mono" : ""}, value)))),
    el("div", {class: "actions"},
      active && item.state !== "committing" && button("暂停", () => current("pause"), {symbol: "pause"}),
      !active && item.state !== "completed" && item.state !== "waitingForDestination" &&
        button("继续", () => current("resume"), {symbol: "play", disabled: working}),
      ["partial","failed","cancelled","retryScheduled"].includes(item.state) &&
        button("从头重试…", () => confirmSheet("从头下载？", "会替换此任务自己的未完成片段。", "从头重试", () => current("retry", {restart:true})), {disabled:working}),
      destination && !active && button("重新授权原保存目录…", () => pickDirectory(path =>
        mutateDownload("reauthorize", {destinationID: destination.id, path}))),
      destination && button(item.artifact ? "在资源管理器中显示文件" : "打开保存目录", () => current("reveal"), {symbol: "folder"}),
      item.artifact && button("重新核验文件", async () => { await api("verify-artifact", {id:item.id}); flash("文件长度和 SHA-256 相符。"); }, {symbol: "check"}),
      !terminal && item.state !== "committing" && button("取消…", () => sheet("取消这项下载？",
        "已发布的文件保留在目标目录。", null, close => [
          button("返回", close),
          button("取消并保留临时数据", async () => { await current("cancel"); close(); }),
          button("取消并清理本任务临时数据", async () => { await current("cancel", {removePartial:true}); close(); }, {danger: true}),
        ])),
      terminal && !item.requestID && button("删除历史…", () => confirmSheet("删除这项历史记录？", "下载文件保留在保存目录。",
        "删除历史", () => current("delete"), true), {danger: true, disabled: working})));
}

async function reviewRequest(record) {
  const reviewed = await api("request-preview", {id: record.id});
  composeDownload({request: record, urls: reviewed.prepared.map(item => item.url)});
}

function composeDownload({urls = [], request} = {}) {
  const draft = el("textarea", {placeholder: "https://example.com/file.pdf", rows: 5, readonly: request ? "" : undefined});
  draft.value = urls.join("\n");
  const locations = select([], "");
  const previews = el("div", {class: "stack"});
  const issue = el("div", {role: "status", class: "warning"});
  const privacyField = el("div", {class: "info-block", hidden: ""});
  const privacy = select([["", "请选择处理方式"], ["strip", "移除查询参数和片段"], ["keep", "保留原始链接"]], "");
  privacyField.append(el("p", {}, "地址含查询参数或片段，可能包含临时访问凭据。移除后链接可能失效。"), field("链接隐私", privacy));
  let prepared = [];
  let generation = 0;
  const updateLocations = (selected = locations.value) => {
    const grants = download.state.destinations.filter(grant => !grant.requiresReauthorization);
    locations.replaceChildren(el("option", {value: ""}, "请选择目录"),
      ...grants.map(grant => el("option", {value: grant.id}, grant.displayPath)));
    locations.value = selected || (grants.length === 1 ? grants[0].id : "");
  };
  async function verify() {
    const run = ++generation;
    prepared = [];
    previews.replaceChildren();
    privacyField.hidden = true;
    issue.textContent = "";
    const rows = draft.value.split("\n").map(line => line.trim()).filter(Boolean);
    if (!rows.length) return;
    try {
      const result = await api("prepare", {urls: rows});
      if (run !== generation) return;
      prepared = result.prepared;
      privacyField.hidden = !prepared.some(row => row.requiresPrivacyReview);
      previews.replaceChildren(...prepared.map(item =>
        el("div", {class: "info-block"}, el("strong", {}, item.suggestedName), el("small", {}, item.displayURL))));
      issue.textContent = prepared.length + " 个文件 · 并发上限 " + download.state.settings.concurrency;
    } catch (error) { if (run === generation) issue.textContent = error.message; }
  }
  let timer;
  draft.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(verify, 260); });
  updateLocations();
  sheet(request ? "复核下载请求" : "新建下载", request
    ? "来源声明 " + request.sourceBundleID + "。来源标识用于关联，确认链接与保存位置后开始。"
    : "确认链接与保存位置后开始", [
    field("HTTP / HTTPS 文件链接 · 每行一条，最多 32 条", draft),
    previews, privacyField, el("div", {class: "row nowrap"}, field("保存位置", locations), button("选择目录…", () =>
      pickDirectory(async path => { const result = await mutateDownload("destination", {path}); updateLocations(result.destination.id); }))),
    el("small", {}, "同名文件自动使用新名称。先校验，再正式落盘。"),
    el("small", {}, "暂停后会核验资源版本。本版下载 HTTP / HTTPS 文件直链。"), issue,
  ], close => [
    !request && button("粘贴链接", async () => { draft.value = await navigator.clipboard.readText(); await verify(); }),
    button("返回", close), button("确认并开始下载", async () => {
      await verify();
      if (!prepared.length || !locations.value) throw new Error("请检查文件链接并选择保存目录。");
      if (!privacyField.hidden && !privacy.value) throw new Error("请先复核链接隐私。");
      await mutateDownload("create", {
        urls: prepared.map(item => item.url), destinationID: locations.value,
        privacy: privacy.value, requestID: request?.id,
      });
      download.section = "all"; renderDownloadState(); close();
    }, {primary: true}),
  ]);
  verify();
}

function renderExchange(records) {
  const uploader = el("input", {type: "file", webkitdirectory: "", hidden: ""});
  uploader.addEventListener("change", async () => {
    try {
      const files = [...uploader.files];
      const input = files.find(file => /^[^/]+\.gaoaction\/manifest\.json$/i.test(file.webkitRelativePath));
      if (!input || input.size > 1048576 || files.length !== 1) throw new Error("请选择仅包含清单的 .gaoaction 下载请求目录。");
      const result = await mutateDownload("request", {manifest: JSON.parse(await input.text())});
      await reviewRequest(result.requests.find(record => record.id === result.requestID));
    } catch (error) { flash(error.message, true); }
  });
  const chooseRequest = button("接收请求…", async () => {
    if (window.pywebview?.api?.choose_folder) {
      await pickDirectory(async path => {
        const result = await mutateDownload("request-directory", {path});
        await reviewRequest(result.requests.find(record => record.id === result.requestID));
      });
    } else {
      uploader.click();
    }
  }, {primary: true, symbol: "folder"});
  downloadBody.replaceChildren(titleHeading("跨应用请求", "先复核，再建任务。接收回执与最终结果分别回送。", chooseRequest), uploader);
  if (!records.length) {
    downloadBody.append(empty("exchange", "尚未收到下载请求", "其他搞系列应用可交接文件直链，也可以打开 .gaoaction 请求包。"));
    return;
  }
  const content = el("div", {class: "content"});
  for (const record of records.slice().reverse()) {
    const status = ({awaitingReview:"等待复核",accepted:"已接受",rejected:"已拒绝"})[record.stage] || record.stage;
    const ready = record.stage === "rejected" || (record.deliveries.some(delivery=>delivery.status==="pending") && record.itemIDs.length > 0 && record.itemIDs.every(id =>
      ["completed", "partial", "failed", "cancelled"].includes(download.state.items.find(item => item.id === id)?.state)));
    const deliver = phase => pickDirectory(async path => {
      const response = await mutateDownload("request-result", {id: record.id, phase, path});
      flash("结果包已保存到 " + response.package);
    }, "选择结果包保存目录");
    content.append(el("article", {class: "card"},
      el("div", {class: "row between"}, el("strong", {}, record.sourceBundleID), el("span", {class: "badge"}, status)),
      el("small", {class: "mono"}, record.id),
      record.deliveries.length ? el("small", {}, "已生成 " + record.deliveries.length + " 个回执或结果包") : null,
      el("div", {class: "actions"},
        record.stage === "awaitingReview" && button("复核…", () => reviewRequest(record), {primary: true}),
        record.stage === "awaitingReview" && button("拒绝…", () => confirmSheet("拒绝这个请求？", "拒绝后可保存取消回执。", "拒绝请求",
          () => mutateDownload("request-reject", {id: record.id}), true), {danger: true}),
        record.stage === "accepted" && button("保存接收回执…", () => deliver("pending")),
        ready && button("保存最终结果包…", () => deliver("final"), {primary: true}))));
  }
  downloadBody.append(content);
}

function showDownloadSettings() {
  const settings = download.state.settings;
  const content = el("div", {class: "stack"});
  const tabbar = el("div", {class: "tabs"});
  let tab = "download";
  const choices = [["download", "下载"], ["appearance", "外观"], ["data", "数据"], ["about", "关于"]];
  const controls = {
    concurrency: select([[1,"1 个任务"],[2,"2 个任务"]], settings.concurrency),
    speedLimitBytesPerSecond: select([[0,"不限速"],[262144,"256 KB/s"],[1048576,"1 MB/s"],[5242880,"5 MB/s"],[20971520,"20 MB/s"]], settings.speedLimitBytesPerSecond),
    maxItemBytes: select([1,5,20,50,100].map(n => [n*2**30,n+" GiB"]), settings.maxItemBytes),
    maxStagingBytes: select([5,20,40,100,200].map(n => [n*2**30,n+" GiB"]), settings.maxStagingBytes),
    appearance: select([["system","跟随系统"],["light","浅色"],["dark","深色"]], settings.appearance),
  };
  function choose(next) {
    tab = next;
    tabbar.replaceChildren(...choices.map(([id, title]) => {
      const control = button(title, () => choose(id));
      control.setAttribute("aria-pressed", id === tab);
      return control;
    }));
    if (tab === "download") content.replaceChildren(
      field("同时下载", controls.concurrency), el("small", {}, "同一主机最多 1 条连接，每个条目使用单连接。"),
      field("限速", controls.speedLimitBytesPerSecond), field("单文件上限", controls.maxItemBytes), field("暂存上限", controls.maxStagingBytes),
      el("div", {class: "info-block"}, "应用运行时传输。退出会暂停，重新启动后由你恢复任务。"));
    if (tab === "appearance") content.replaceChildren(field("外观", controls.appearance));
    if (tab === "data") content.replaceChildren(el("p", {}, "任务、目录授权、设置与跨应用记录保存在本应用的资料目录。"),
      button("在资源管理器中显示资料目录", () => api("reveal")), el("p", {}, "资料损坏或版本过新时停止写入。下载文件保留在你选择的位置。"));
    if (tab === "about") content.replaceChildren(el("h2", {}, "搞门户 · 内置下载"), el("p", {}, version),
      el("small", {}, "HTTP / HTTPS 直链 · SHA-256 · 原子落盘"));
  }
  choose(tab);
  sheet("下载设置", null, [tabbar, content], close => [
    button("关闭", close),
    button("保存设置", async () => {
      await mutateDownload("settings", {settings: Object.fromEntries(Object.entries(controls).map(([key, control]) =>
        [key, key === "appearance" ? control.value : Number(control.value)]))});
      close();
    }, {primary: true}),
  ]);
}

if (center === "downloads") startDownloads();

window.addEventListener("keydown", event => {
  if (!event.ctrlKey || event.key.toLowerCase() !== "w" || !window.pywebview?.api?.close_window) return;
  event.preventDefault();
  const dialog = [...sheets.querySelectorAll("dialog[open]")].at(-1);
  if (!dialog) { window.pywebview.api.close_window(); return; }
  if (dialog.dispatchEvent(new Event("cancel", {cancelable: true}))) dialog.close();
});
