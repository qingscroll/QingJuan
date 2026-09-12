"""Embedded to keep the browser verification page available in frozen builds."""

LOGIN_HTML = """<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>少年梦账号登录 · 青卷</title>
<style>
*{box-sizing:border-box}body{margin:0;padding:32px 20px;background:#f4f7f6;color:#183c32;font:16px/1.6 system-ui,sans-serif}
main{max-width:420px;margin:6vh auto;background:white;padding:28px;border:1px solid #d9e6e0;border-radius:12px}
h1{font-size:24px;margin:0 0 12px}p{color:#526a61}label{display:block;margin:16px 0 6px}
input,button{font:inherit;width:100%;padding:10px;border:1px solid #8baba0;border-radius:6px}
button{margin-top:18px;background:#17694f;color:white;cursor:pointer}button:disabled{opacity:.55;cursor:default}
#captcha{margin-top:20px;min-height:44px}#message,#hint{overflow-wrap:anywhere}#message{min-height:28px}#retry{background:white;color:#17694f}
</style><main><h1>登录少年梦账号</h1>
<p>登录后，青卷将使用此账号读取可访问的章节。登录状态仅保留在当前后端运行期间。</p>
<form id="form"><label for="username">手机号 / 邮箱 / 用户名</label>
<input id="username" autocomplete="username" required maxlength="128">
<label for="password">密码</label><input id="password" type="password" autocomplete="current-password" required maxlength="256">
<div id="captcha"></div><button id="submit" disabled>登录</button></form>
<div role="status" aria-live="polite"><p id="message">正在加载人机验证…</p><p id="hint" hidden></p></div>
<button id="retry" type="button">重新加载验证</button>
</main><script>
(() => {
'use strict';
const token = location.hash.slice(1);
history.replaceState(null, '', location.pathname);
const form = document.getElementById('form'), submit = document.getElementById('submit');
const message = document.getElementById('message'), retry = document.getElementById('retry');
const password = document.getElementById('password'), hint = document.getElementById('hint');
const terminalCodes = new Set(['invalid_token', 'session_revoked', 'too_many_attempts', 'plugin_disabled']);
let captcha = null, busy = false, generation = 0, ended = false;
class LoginError extends Error {
 constructor(msg, code = '', hint = '') { super(msg); this.code = code; this.hint = hint; }
}
function text(value) { return typeof value === 'string' ? value.trim().slice(0, 300) : ''; }
function show(msg, advice = '') {
 message.textContent = msg; hint.textContent = advice; hint.hidden = !advice;
}
function showError(error) {
 const known = error instanceof LoginError;
 show(known ? error.message : '登录请求失败', known ? error.hint : '请检查网络后重新加载验证');
 if (known && terminalCodes.has(error.code)) {
  ended = true; generation++; password.value = ''; submit.disabled = true;
  form.hidden = true; retry.hidden = true;
  if (captcha) { captcha.destroy(); captcha = null; }
 }
}
async function loadSdk() {
 if (typeof initGeetest === 'function') return;
 await new Promise((resolve, reject) => {
  const script = document.createElement('script');
  const timer = setTimeout(() => { script.remove(); reject(new LoginError('验证组件加载超时，请重试')); }, 15000);
  script.src = 'https://static.geetest.com/static/js/gt.0.5.0.js';
  script.onload = () => { clearTimeout(timer); resolve(); };
  script.onerror = () => { clearTimeout(timer); script.remove(); reject(new LoginError('验证组件加载失败，请检查网络后重试')); };
  document.head.appendChild(script);
 });
}
async function api(path, body) {
 const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 30000);
 try {
  const response = await fetch(location.pathname + path, {method: body ? 'POST' : 'GET',
   headers: {'X-Login-Token':token, 'Content-Type':'application/json'}, credentials:'omit', cache:'no-store',
   body: body ? JSON.stringify(body) : undefined, signal: controller.signal});
  const result = await response.json().catch(() => null);
  if (!response.ok) {
   const detail = result && result.detail;
   throw new LoginError(text(detail && detail.msg) || text(detail) || '登录服务暂时不可用',
    text(detail && detail.code), text(detail && detail.hint) || '请稍后重新加载验证');
  }
  if (!result || typeof result !== 'object' || Array.isArray(result)) throw new LoginError('登录响应无效，请重试');
  return result;
 } finally { clearTimeout(timer); }
}
async function load(notice = null) {
 if (ended) return;
 const current = ++generation;
 submit.disabled = true; retry.disabled = true;
 if (captcha) { captcha.destroy(); captcha = null; }
 document.getElementById('captcha').replaceChildren();
 if (notice) showError(notice); else show('正在加载人机验证…');
 try {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new LoginError('登录链接已失效', 'invalid_token', '请回到青卷重新发起登录');
  await loadSdk();
  const config = await api('/geetest');
  if (typeof initGeetest !== 'function' || !text(config.gt) || !text(config.challenge))
   throw new LoginError('验证组件加载失败，请检查网络后重试');
  const timer = setTimeout(() => {
   if (current !== generation) return;
   generation++; retry.disabled = false;
   if (captcha) { captcha.destroy(); captcha = null; }
   show('验证加载超时，请重新加载');
  }, 20000);
  initGeetest({gt:config.gt,challenge:config.challenge,offline:!config.success,new_captcha:!!config.new_captcha,
   product:'popup',width:'100%',https:true,lang:'zh-cn'}, obj => {
   if (current !== generation) { obj.destroy(); return; }
   captcha = obj;
   obj.onReady(() => { clearTimeout(timer); if (current !== generation) return;
    if (notice) showError(notice); else show('请填写账号密码并完成人机验证'); retry.disabled = false; });
   obj.onSuccess(() => { if (current !== generation || busy) return;
    submit.disabled = false; show('验证通过，可以登录'); });
   obj.onError(() => { clearTimeout(timer); if (current !== generation) return;
    if (!busy) { submit.disabled = true; retry.disabled = false; show('验证加载失败，请重新加载'); } });
   obj.appendTo('#captcha');
  });
 } catch (error) { generation++; showError(error); retry.disabled = ended; }
}
form.addEventListener('submit', async event => {
 event.preventDefault(); if (busy || ended) return;
 const verified = captcha && captcha.getValidate();
 if (!verified) { show('请先完成人机验证'); return; }
 busy = true; submit.disabled = true; retry.disabled = true;
 show('正在登录…');
 const value = password.value; password.value = '';
 try {
  const result = await api('/login', {username:document.getElementById('username').value.trim(),password:value,
   auto_login:1,geetest_challenge:verified.geetest_challenge,geetest_validate:verified.geetest_validate,
   geetest_seccode:verified.geetest_seccode});
  if (result.loggedIn !== true) throw new LoginError('登录未完成，请重试');
  ended = true; generation++; captcha.destroy(); captcha = null;
  form.hidden = true; retry.hidden = true; show('登录成功，请返回青卷。此页面可以关闭。');
 } catch (error) { showError(error); if (!ended) await load(error); }
 finally { busy = false; }
});
retry.addEventListener('click', () => { if (!busy) load(); });
load();
})();
</script></html>"""
