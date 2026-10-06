const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const packageRoot=process.env.MENDAO_NODE_PACKAGES;
if(!packageRoot)throw new Error('Set MENDAO_NODE_PACKAGES to bundled dependencies.');
const {chromium}=require(path.join(packageRoot,'playwright'));
const script=fs.readFileSync(path.join(__dirname,'..','BrowserExtension','content.js'),'utf8');
(async()=>{
  const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
  let cases=0;
  try{
    async function run(html){
      const context=await browser.newContext();const page=await context.newPage();
      await page.route('https://example.test/**',route=>route.fulfill({status:200,contentType:'text/html',body:html}));
      await page.goto('https://example.test/login');
      await page.evaluate(()=>{
        window.received=[];window.credentialCalls=0;
        window.chrome={runtime:{async sendMessage(message){
          window.received.push(message);
          if(message.type==='credentials'){window.credentialCalls++;return{ok:true,username:'dummy@example.test',password:'dummy-password-only-for-tests'};}
          return{ok:true};
        }}};
      });
      await page.addScriptTag({content:script});
      await page.waitForTimeout(100);
      const result=await page.evaluate(()=>({calls:credentialCalls,messages:received,inputs:[...document.querySelectorAll('input')].map(i=>({type:i.type,value:i.value})),submits:window.submits||0}));
      await context.close();return result;
    }
    let r=await run('<form onsubmit="window.submits=(window.submits||0)+1;return false"><input type="email" autocomplete="username"><input type="password" autocomplete="current-password"><button type="submit">登录</button></form>');
    assert.equal(r.inputs[0].value,'dummy@example.test');assert.equal(r.inputs[1].value,'dummy-password-only-for-tests');assert.equal(r.submits,0);assert(r.messages.some(m=>m.passwordFilled===true));cases+=4;
    r=await run('<form><input type="email" name="email"><button type="submit">Continue</button></form>');
    assert.equal(r.inputs[0].value,'dummy@example.test');assert(r.messages.some(m=>m.type==='filled'&&m.passwordFilled===false));cases+=2;
    r=await run('<form><input type="email"><input type="password" autocomplete="new-password"><button type="submit">注册</button></form>');
    assert.equal(r.calls,0);cases++;
    r=await run('<form><input type="password"><input type="password"><button type="submit">Change password</button></form>');
    assert.equal(r.calls,0);cases++;
    r=await run('<form><input type="email" value="another@example.test"><input type="password"><button type="submit">Sign in</button></form>');
    assert.equal(r.inputs[1].value,'');cases++;
    r=await run('<input type="text" name="search" placeholder="搜索"><button>搜索</button>');
    assert.equal(r.calls,0);cases++;
    r=await run('<form><input type="email"><input type="password"><button type="submit">Create account</button></form>');
    assert.equal(r.calls,0);cases++;
    r=await run('<form><input type="email"><input type="password" style="display:none"><button type="submit">登录</button></form>');
    assert.equal(r.inputs[1].value,'');cases++;
    console.log('Content autofill tests passed: '+cases);
  }finally{await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1});
