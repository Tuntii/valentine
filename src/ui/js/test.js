// Tests for the DOM-free code in tree.js: `node src/ui/js/test.js` (CI runs it).
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const code = fs.readFileSync(path.join(__dirname, 'tree.js'), 'utf8');
const { leaves, removeLeaf, sanitize, PRESETS, localServers, parseHeaders } =
  new Function(`${code}\nreturn { leaves, removeLeaf, sanitize, PRESETS, localServers, parseHeaders };`)();

const tests = {
  'sanitize keeps a valid tree': () => {
    const t = { split: 'row', ratio: 0.3, a: { pane: 'a' }, b: { split: 'col', ratio: 0.5, a: { pane: 'b' }, b: { pane: 'c' } } };
    assert.deepEqual(sanitize(t, ['a', 'b', 'c']), t);
  },
  'sanitize drops unknown and duplicate panes, adds missing ones, clamps ratios': () => {
    const t = { split: 'row', ratio: 7, a: { pane: 'a' }, b: { split: 'col', ratio: 0.5, a: { pane: 'gone' }, b: { pane: 'a' } } };
    const s = sanitize(t, ['a', 'b']);
    assert.deepEqual(leaves(s), ['a', 'b']);
    assert.equal(s.ratio, 0.5); // the added pane splits the last leaf in half
    assert.equal(sanitize({ split: 'row', ratio: 7, a: { pane: 'a' }, b: { pane: 'b' } }, ['a', 'b']).ratio, 0.9);
  },
  'sanitize builds a grid from garbage': () => {
    assert.deepEqual(leaves(sanitize('nope', ['a', 'b', 'c', 'd'])), ['a', 'b', 'c', 'd']);
    assert.equal(sanitize(null, []), null);
  },
  'removeLeaf collapses the parent split': () => {
    const t = { split: 'row', ratio: 0.5, a: { pane: 'a' }, b: { pane: 'b' } };
    assert.deepEqual(removeLeaf(t, 'a'), { pane: 'b' });
    assert.equal(removeLeaf({ pane: 'a' }, 'a'), null);
  },
  'presets place every pane once': () => {
    for (const [name, p] of Object.entries(PRESETS)) {
      const ids = Array.from({ length: p.n + 1 }, (_, i) => 'p' + i);
      assert.deepEqual(leaves(p.build(ids)), ids, name);
    }
  },
  'localServers finds dev server URLs and opens wildcard binds locally': () => {
    const text = '  ➜  Local:   http://localhost:5173/\n  Network: http://192.168.1.4:5173/\n' +
      'listening on http://0.0.0.0:8000 and http://[::]:3000, also http://127.0.0.1:9229/json\nhttp://localhost:5173';
    assert.deepEqual(localServers(text), ['http://localhost:5173', 'http://localhost:8000', 'http://localhost:3000', 'http://127.0.0.1:9229']);
    assert.deepEqual(localServers('no urls'), []);
  },
  'parseHeaders reads name: value lines': () => {
    assert.deepEqual(parseHeaders('Authorization: Bearer a:b\n\nbad line\n Accept : json \n:x'), { Authorization: 'Bearer a:b', Accept: 'json' });
  },
};

let failed = 0;
for (const [name, fn] of Object.entries(tests)) {
  try {
    fn();
    console.log(`ok    ${name}`);
  } catch (e) {
    failed++;
    console.log(`FAIL  ${name}\n${e.message}`);
  }
}
process.exit(failed ? 1 : 0);
