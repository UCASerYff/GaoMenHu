'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const http = require('node:http');
const https = require('node:https');
const {execFileSync} = require('node:child_process');
const {createHash, randomUUID, X509Certificate} = require('node:crypto');

const [playwrightPackage, installDir, dataDir, workDir, origin, hostAlias] = process.argv.slice(2);
const {chromium} = require(playwrightPackage);
const extensionId = 'ipggjapdbehjdikobhedllpdbchkoigf';
const bundledExtension = path.join(installDir, 'BrowserExtension');
const browserPaths = {
  chrome: [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean)
    .map(root => path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe')),
  edge: [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean)
    .map(root => path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe')),
};
let pageToken;

function fixtureExtension() {
  if (!hostAlias) return bundledExtension;
  assert.match(hostAlias, /^cn\.mendao\.bridge\.smoke_[a-f0-9]{32}$/);
  const fixture = path.join(workDir, 'IsolatedExtension');
  fs.cpSync(bundledExtension, fixture, {recursive: true});
  const background = path.join(fixture, 'background.js');
  const script = fs.readFileSync(background, 'utf8');
  const productionHost = "'cn.mendao.bridge'";
  assert.equal(script.split(productionHost).length, 2, 'Expected exactly one configured native host');
  fs.writeFileSync(background, script.replace(productionHost, `'${hostAlias}'`), 'utf8');
  return fixture;
}

async function startFixture() {
  fs.writeFileSync(path.join(workDir, 'browser-fixture.cnf'), '[req]\ndistinguished_name=fixture_dn\nprompt=no\n[fixture_dn]\nCN=127.0.0.1\n');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-config', 'browser-fixture.cnf', '-addext', 'subjectAltName=IP:127.0.0.1',
    '-keyout', 'browser-fixture.key', '-out', 'browser-fixture.crt'], {cwd: workDir, windowsHide: true, stdio: 'pipe'});
  const cert = fs.readFileSync(path.join(workDir, 'browser-fixture.crt'));
  const key = fs.readFileSync(path.join(workDir, 'browser-fixture.key'));
  const spki = new X509Certificate(cert).publicKey.export({type: 'spki', format: 'der'});
  const fingerprint = createHash('sha256').update(spki).digest('base64');
  const server = https.createServer({cert, key}, (request, response) => {
    response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8'});
    response.end(`<!doctype html><title>Isolated portal form</title><form>
      <input type="text" name="username" autocomplete="username">
      <input type="password" name="password" autocomplete="current-password"></form>`);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {server, fingerprint, origin: `https://127.0.0.1:${server.address().port}`};
}

async function api(endpoint, payload = {}) {
  const response = await fetch(origin + endpoint, {
    method: 'POST', headers: {'Content-Type': 'application/json', 'X-Gao-Token': pageToken},
    body: JSON.stringify(payload),
  });
  const body = await response.json();
  assert.ok(response.ok && body.ok, body.error || `Portal returned HTTP ${response.status}`);
  return body;
}

async function until(check, message) {
  const deadline = Date.now() + 18_000;
  while (Date.now() < deadline) {
    const result = await check();
    if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 350));
  }
  throw new Error(message);
}

async function activeDownload() {
  const chunk = Buffer.alloc(64 * 1024, 41);
  let transfer;
  const server = http.createServer((_, response) => {
    transfer = response;
    response.writeHead(200, {'Content-Length': 2 * chunk.length, ETag: '"exit-fixture"'});
    response.write(chunk);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return {url: `http://localhost:${server.address().port}/exit-fixture.bin`,
    release: () => transfer?.end(chunk), close: () => { server.closeAllConnections(); server.close(); }};
}

async function run() {
  const extension = fixtureExtension();
  const html = await (await fetch(origin)).text();
  pageToken = html.match(/name="gao-token" content="([^"]+)"/)?.[1];
  assert.ok(pageToken, 'The isolated portal did not return its page token');
  const fixture = await startFixture();
  const centers = {};
  let localDownload;
  try {
    for (const [name, candidates] of Object.entries(browserPaths)) {
      const executablePath = candidates.find(candidate => fs.existsSync(candidate));
      assert.ok(executablePath, `Missing installed ${name}`);
      const context = await chromium.launchPersistentContext(path.join(workDir, name + '-profile'), {
        executablePath, headless: true, timeout: 35_000,
        ignoreDefaultArgs: ['--disable-extensions'],
        args: ['--enable-unsafe-extension-debugging', '--no-first-run', '--no-default-browser-check',
          `--ignore-certificate-errors-spki-list=${fixture.fingerprint}`],
        env: {...process.env, GAOMENHU_DATA_DIR: dataDir},
      });
      centers[name] = {context};
      const root = await context.browser().newBrowserCDPSession();
      const {id} = await root.send('Extensions.loadUnpacked', {path: extension});
      assert.equal(id, extensionId, `${name} loaded the published extension identity`);
      const browserVersion = await root.send('Browser.getVersion');
      const worker = context.serviceWorkers().find(entry => entry.url().startsWith(`chrome-extension://${id}/`)) ||
        await context.waitForEvent('serviceworker', {predicate: entry => entry.url().startsWith(`chrome-extension://${id}/`), timeout: 15_000});
      centers[name].worker = worker;
      centers[name].profile = await until(async () => {
        const id = await worker.evaluate(async () => (await chrome.storage.local.get('profileId')).profileId);
        const state = await api('/api/launcher/runtime');
        return state.profiles.find(profile => profile.browser === name && profile.id === id);
      }, `${name} did not poll the installed Native Messaging host`);
      console.log(`${name} (${browserVersion.product}) loaded the installed extension and identified its real profile`);
    }

    assert.notEqual(centers.chrome.profile.id, centers.edge.profile.id, 'Browser profiles shared an identity');
    for (const [name, {context, profile}] of Object.entries(centers)) {
      const siteID = randomUUID();
      const accountID = randomUUID();
      const loginURL = `${fixture.origin}/${name}`;
      await api('/api/sites/save', {site: {
        id: siteID, name: `Native verification ${name}`, url: loginURL, color: '#537CE6',
        allowedBrowsers: ['chrome', 'edge'], defaultBrowser: name, profiles: {[name]: profile.id},
        accounts: [{id: accountID, label: 'Fixture', username: `${name}@example.test`, loginHosts: []}],
        defaultAccount: accountID,
      }, passwords: [{id: accountID, password: `fixture-only-${name}`}]});
      await api('/api/vault/unlock');
      const pageReady = context.waitForEvent('page', {timeout: 16_000});
      const launch = await api('/api/sites/launch', {siteID, browserID: name});
      assert.ok(launch.requestID, 'GaoMenHu did not create an extension launch grant');
      const page = await pageReady;
      centers[name].form = page;
      await page.waitForURL(loginURL, {timeout: 12_000, waitUntil: 'domcontentloaded'});
      await page.waitForFunction(expected => document.querySelector('input[type=password]')?.value === expected, `fixture-only-${name}`, {timeout: 12_000});
      assert.equal(await page.locator('[autocomplete=username]').inputValue(), `${name}@example.test`);
      const other = name === 'chrome' ? centers.edge : centers.chrome;
      assert.ok(other.context.pages().every(candidate => candidate.url() !== loginURL), `${name} URL opened in the other browser`);
      await until(async () => (await api('/api/launcher/runtime')).launchFeedback[launch.requestID]?.includes('已填入'),
        `${name} did not return a filled acknowledgement`);
      console.log(`${name} opened the selected profile, filled the isolated HTTPS form and returned the filled acknowledgement`);
    }
    for (const {worker} of Object.values(centers)) {
      assert.ok(await worker.evaluate(() => Boolean(globalThis.gaoShutdownProbeConnection = port)));
    }
    localDownload = await activeDownload();
    const downloadDir = fs.mkdtempSync(path.join(workDir, 'quit-transfer-'));
    const grant = (await api('/api/downloads/destination', {path: downloadDir})).destination;
    const task = (await api('/api/downloads/create', {urls: [localDownload.url], destinationID: grant.id})).items
      .find(item => item.destinationID === grant.id);
    await until(async () => (await api('/api/downloads/state')).items.some(item =>
      item.id === task.id && item.state === 'running' && item.bytesReceived === 65536), 'The fixture download did not reach an active checkpoint');
    await api('/api/shutdown');
    const queueFile = path.join(dataDir, 'DownloadCenter', 'downloads.json');
    const checkpoint = await until(() => {
      const record = JSON.parse(fs.readFileSync(queueFile, 'utf8'));
      const payload = Buffer.from(record.payload, 'base64');
      assert.equal(createHash('sha256').update(payload).digest('hex'), record.sha256);
      return JSON.parse(payload).items.find(item => item.id === task.id && item.state === 'paused' && item.bytesReceived === 65536);
    }, 'The exiting portal did not pause its download');
    localDownload.release();
    await until(() => !fs.existsSync(`${dataDir}.native.json`), 'The app did not remove its Native Messaging endpoint');
    assert.equal(checkpoint.etag, '"exit-fixture"');
    assert.ok(!fs.existsSync(path.join(downloadDir, 'exit-fixture.bin')));
    console.log('A real loopback transfer was paused at its 64 KiB checkpoint before process exit');
    for (const [name, {worker, form}] of Object.entries(centers)) {
      assert.equal(await form.locator('[autocomplete=username]').inputValue(), `${name}@example.test`);
      const offline = await worker.evaluate(async () => {
        const result = await request('poll');
        return {sameConnection: port === globalThis.gaoShutdownProbeConnection, available: result.ok, error: result.error};
      });
      assert.ok(offline.sameConnection && offline.available === false && offline.error.includes('没有在运行'),
        `${name} did not keep its own browser and helper connection after the portal exited`);
      console.log(`${name} retained its tab and browser-owned helper after the portal endpoint shut down`);
    }
  } finally {
    await Promise.allSettled(Object.values(centers).map(value => value.context.close()));
    localDownload?.close();
    fixture.server.close();
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
