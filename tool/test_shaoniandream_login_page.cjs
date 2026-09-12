// Run with: node --test tool/test_shaoniandream_login_page.cjs
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { runInNewContext } = require('node:vm');
const test = require('node:test');
const assert = require('node:assert/strict');

const page = readFileSync(join(__dirname, '../python-backend/app/site_plugins/shaoniandream_login_page.py'), 'utf8');
const script = page.match(/<script>([\s\S]*?)<\/script>/)[1];
const flush = () => new Promise(resolve => setImmediate(resolve));

async function browser(loginResponse, token = 'a'.repeat(43)) {
  const nodes = Object.fromEntries(['form', 'submit', 'message', 'retry', 'password', 'hint', 'captcha', 'username']
    .map(id => [id, { value: '', textContent: '', hidden: false, disabled: false, events: {},
      addEventListener(type, fn) { this.events[type] = fn; }, replaceChildren() {} }]));
  const widgets = [], calls = [], timers = new Map();
  let sequence = 0, clearedHash = false;
  runInNewContext(script, {
    location: { hash: '#' + token, pathname: '/site-login/shaoniandream' },
    history: { replaceState() { clearedHash = true; } },
    document: { getElementById: id => nodes[id] },
    AbortController,
    setTimeout: fn => { const id = ++sequence; timers.set(id, fn); return id; },
    clearTimeout: id => timers.delete(id),
    fetch: async (path, options) => {
      calls.push({ path, options });
      return path.endsWith('/geetest')
        ? { ok: true, json: async () => ({ gt: 'gt', challenge: 'challenge', success: 1, new_captcha: 1 }) }
        : loginResponse;
    },
    initGeetest(config, callback) {
      const widget = { destroyed: false, verified: false,
        destroy() { this.destroyed = true; },
        onReady(fn) { this.ready = fn; }, onSuccess(fn) { this.success = fn; }, onError(fn) { this.error = fn; },
        appendTo() { queueMicrotask(() => this.ready()); },
        getValidate() { return this.verified ? { geetest_challenge: 'challenge',
          geetest_validate: 'verified', geetest_seccode: 'verified|jordan' } : false; },
      };
      widgets.push(widget); callback(widget);
    },
  });
  await flush();
  return { nodes, calls, widgets, timers, clearedHash,
    async submit() {
      const widget = widgets.at(-1); widget.verified = true; widget.success();
      nodes.username.value = ' reader '; nodes.password.value = 'private-password';
      await nodes.form.events.submit({ preventDefault() {} }); await flush();
    },
  };
}

test('structured errors display safe fields and refresh verification for retry', async () => {
  const app = await browser({ ok: false, json: async () => ({ detail: {
    code: 'invalid_credentials', msg: '账号或密码错误', hint: '请检查后重新验证',
    errors: [{ input: 'private-password' }],
  } }) });
  await app.submit();
  assert.equal(app.nodes.message.textContent, '账号或密码错误');
  assert.equal(app.nodes.hint.textContent, '请检查后重新验证');
  assert.equal(app.nodes.password.value, '');
  assert.equal(app.widgets.length, 2);
  assert.equal(app.widgets[0].destroyed, true);
  assert.equal(app.nodes.submit.disabled, true);
  assert.equal(app.nodes.retry.disabled, false);
  app.widgets[0].success();
  assert.equal(app.nodes.submit.disabled, true);
  assert.equal(app.clearedHash, true);
  const sent = JSON.parse(app.calls.find(call => call.options.method === 'POST').options.body);
  assert.equal(sent.username, 'reader');
  assert.equal(sent.auto_login, 1);
  assert.equal(app.timers.size, 0);
});

test('terminal errors stop the page without refreshing consumed flows', async () => {
  const app = await browser({ ok: false, json: async () => ({ detail: {
    code: 'too_many_attempts', msg: '登录尝试次数已用完', hint: '请回到青卷重新发起登录',
  } }) });
  await app.submit();
  assert.equal(app.nodes.form.hidden, true);
  assert.equal(app.nodes.retry.hidden, true);
  assert.equal(app.nodes.password.value, '');
  assert.equal(app.widgets.length, 1);
  assert.equal(app.widgets[0].destroyed, true);
});

test('only an explicit successful session completes login', async () => {
  const invalid = await browser({ ok: true, json: async () => ({}) });
  await invalid.submit();
  assert.equal(invalid.nodes.form.hidden, false);
  assert.equal(invalid.nodes.message.textContent, '登录未完成，请重试');
  const success = await browser({ ok: true, json: async () => ({ loggedIn: true }) });
  await success.submit();
  assert.equal(success.nodes.form.hidden, true);
  assert.equal(success.nodes.retry.hidden, true);
  assert.equal(success.nodes.password.value, '');
  assert.equal(success.widgets[0].destroyed, true);
});

test('invalid links make no upstream calls', async () => {
  const app = await browser(null, 'invalid');
  assert.equal(app.nodes.form.hidden, true);
  assert.equal(app.calls.length, 0);
  assert.equal(app.nodes.hint.textContent, '请回到青卷重新发起登录');
});
