'use strict';
(() => {
  if(window.top!==window||location.protocol!=='https:')return;
  let busy=false,done=false,usernameDone=false,lastAttempt=0;
  const visible=el=>!el.disabled&&!el.readOnly&&el.getClientRects().length>0&&getComputedStyle(el).visibility!=='hidden';
  const description=el=>[el.name,el.id,el.placeholder,el.getAttribute('autocomplete'),el.getAttribute('aria-label')].join(' ').toLowerCase();
  function fields(){
    const passwords=[...document.querySelectorAll('input[type="password"]')].filter(visible);
    if(passwords.length>1||passwords.some(el=>el.autocomplete==='new-password'))return null;
    const password=passwords[0],scope=password?.form||document;
    const submitText=[...scope.querySelectorAll('button[type="submit"],input[type="submit"]')].map(el=>el.innerText||el.value||'').join(' ').trim();
    if(/^(sign.?up|create.?account|register|注册|设置密码|重置密码|reset.?password|change.?password)/i.test(submitText))return null;
    const candidates=[...scope.querySelectorAll('input')].filter(el=>visible(el)&&['email','text','tel'].includes(el.type)&&!/(search|搜索|message|prompt)/i.test(description(el)));
    const username=candidates.find(el=>el.type==='email'||['username','email'].includes(el.autocomplete)||/(email|user.?name|login|identifier|邮箱|账号|帐号)/i.test(description(el)));
    if(!password&&!username)return null;
    if(!password&&usernameDone)return null;
    if(!password){
      const text=(username.form||username.parentElement?.parentElement)?.innerText||'';
      if(!/(sign.?in|log.?in|登录|登入|continue|继续)/i.test(text))return null;
    }
    return {username,password};
  }
  function fill(input,value){
    if(!input||!value||input.value)return false;
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(input,value);
    input.dispatchEvent(new Event('input',{bubbles:true}));input.dispatchEvent(new Event('change',{bubbles:true}));return true;
  }
  async function attempt(){
    if(busy||done||Date.now()-lastAttempt<1300)return;
    const found=fields();if(!found)return;busy=true;lastAttempt=Date.now();
    try{
      const response=await chrome.runtime.sendMessage({type:'credentials'});
      if(!response?.ok)return;
      if(found.username?.value&&found.username.value.trim()!==response.username.trim()){response.password='';response.username='';return;}
      const userFilled=fill(found.username,response.username),passwordFilled=fill(found.password,response.password);
      if(userFilled)usernameDone=true;
      if(userFilled||passwordFilled)await chrome.runtime.sendMessage({type:'filled',passwordFilled});
      if(passwordFilled){done=true;observer.disconnect();clearInterval(timer);}
      response.password='';response.username='';
    }catch(error){/* Never log credential content. */}
    finally{busy=false;}
  }
  const observer=new MutationObserver(()=>attempt());
  observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['type','style','class','hidden']});
  const timer=setInterval(attempt,2000);
  setTimeout(()=>{observer.disconnect();clearInterval(timer);},300000);
  document.addEventListener('DOMContentLoaded',attempt,{once:true});attempt();
})();
