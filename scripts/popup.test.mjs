import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../popup.js', import.meta.url), 'utf8');
async function setup(url = 'https://meet.google.com/abc-defg-hij') {
  const elements = new Map();
  const calls = [{ id: 'abc-defg-hij', topic: 'Design review', participants: ['Asha'], caption_count: 2 }];
  let record = { ...calls[0], captions: [{ speaker: '<img src=x onerror=alert(1)>', text: '<script>unsafe</script>' }] };
  let listResult = calls;
  let copyFails = false;
  let copied;
  function element(id) {
    if (!elements.has(id)) elements.set(id, {
      value: '', textContent: '', innerHTML: '', listeners: {},
      classList: { add() {}, remove() {} },
      addEventListener(name, fn) { this.listeners[name] = fn; },
      querySelectorAll() { return []; },
      showModal() { this.open = true; }, close() { this.open = false; }
    });
    return elements.get(id);
  }
  const context = vm.createContext({
    document: { getElementById: element, addEventListener() {} },
    chrome: {
      runtime: { getManifest: () => ({ version: 'test' }), sendMessage(message, cb) {
        cb(message.type === 'ACTIVE_CALL' ? {id:'abc-defg-hij'} : message.type === 'LIST_CALLS' ? listResult : message.type === 'GET_CALL' ? record : { value: false });
      } },
      tabs: { query: async () => [{ url }] }
    },
    navigator: { clipboard: { async writeText(text) { if (copyFails) throw Error('denied'); copied = text; } } },
    URL, setTimeout, clearTimeout
  });
  vm.runInContext(await readFile(new URL('../call-history.js', import.meta.url),'utf8'),context);
  vm.runInContext(source, context);
  await new Promise(resolve => setImmediate(resolve));
  return { context, element, setRecord: value => record = value, setList: value => listResult = value, failCopy: () => copyFails = true, copied: () => copied };
}

test('popup shows current call as plain text without requesting the library', async () => {
  const ui = await setup();
  assert.equal(ui.element('call-name').textContent, 'Design review');
  assert.match(ui.element('current-meta').textContent, /1 caption · 1 participant/);
  ui.setRecord({error:'failed'});
  await vm.runInContext('refresh()',ui.context);
  assert.match(ui.element('current-meta').textContent,/Could not load current call/);
});

test('current call recognizes both Meet URL forms and rejects suffixes', async () => {
  for (const path of ['/abc-defg-hij', '/meet/abc-defg-hij?authuser=6']) {
    const ui = await setup('https://meet.google.com' + path);
    assert.equal(await vm.runInContext('getActiveTabMeetId()', ui.context), 'abc-defg-hij');
  }
  const ui = await setup('https://meet.google.com/abc-defg-hij-suffix');
  assert.equal(await vm.runInContext('getActiveTabMeetId()', ui.context), null);
});
