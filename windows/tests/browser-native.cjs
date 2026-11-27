'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const https = require('node:https');
const {execFileSync} = require('node:child_process');
const {createHash, randomUUID, X509Certificate} = require('node:crypto');

const [playwrightPackage, installDir, dataDir, workDir, origin] = process.argv.slice(2);
const {chromium} = require(playwrightPackage);
const extensionId = 'ipggjapdbehjdikobhedllpdbchkoigf';
const extension = path.join(installDir, 'BrowserExtension');
const browserPaths = {
  chrome: [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean)
    .map(root => path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe')),
  edge: [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean)
    .map(root => path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe')),
};
let pageToken;

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

async function run() {
  const html = await (await fetch(origin)).text();
  pageToken = html.match(/name="gao-token" content="([^"]+)"/)?.[1];
  assert.ok(pageToken, 'The isolated portal did not return its page token');
  const fixture = await startFixture();
  const centers = {};
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
      await page.waitForURL(loginURL, {timeout: 12_000, waitUntil: 'domcontentloaded'});
      await page.waitForFunction(expected => document.querySelector('input[type=password]')?.value === expected, `fixture-only-${name}`, {timeout: 12_000});
      assert.equal(await page.locator('[autocomplete=username]').inputValue(), `${name}@example.test`);
      const other = name === 'chrome' ? centers.edge : centers.chrome;
      assert.ok(other.context.pages().every(candidate => candidate.url() !== loginURL), `${name} URL opened in the other browser`);
      await until(async () => (await api('/api/launcher/runtime')).launchFeedback[launch.requestID]?.includes('已填入'),
        `${name} did not return a filled acknowledgement`);
      console.log(`${name} opened the selected profile, filled the isolated HTTPS form and returned the filled acknowledgement`);
    }
  } finally {
    await Promise.allSettled(Object.values(centers).map(value => value.context.close()));
    fixture.server.close();
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
