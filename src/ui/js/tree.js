'use strict';
// The first of the files served together as /app.js (see server.v); this one has no
// DOM access, so js/test.js runs it in node.

// ---- layout tree: { pane: id } | { split: 'row' | 'col', ratio, a, b } ----------
// 'row' puts a left of b, 'col' puts a above b; ratio is a's share.

const clampRatio = r => Math.min(0.9, Math.max(0.1, r));
const leaf = id => ({ pane: id });
const chain = (ids, split) => (ids.length === 1 ? leaf(ids[0])
  : { split, ratio: 1 / ids.length, a: leaf(ids[0]), b: chain(ids.slice(1), split) });
// Presets take every pane id in order; panes beyond the preset's count join its last strip.
const PRESETS = {
  '2×2': { n: 4, build: ids => ({ split: 'col', ratio: 0.5, a: chain(ids.slice(0, 2), 'row'), b: chain(ids.slice(2), 'row') }) },
  '3+2': { n: 5, build: ids => ({ split: 'col', ratio: 0.5, a: chain(ids.slice(0, 3), 'row'), b: chain(ids.slice(3), 'row') }) },
  '1+3': { n: 4, build: ids => ({ split: 'row', ratio: 0.55, a: leaf(ids[0]), b: chain(ids.slice(1), 'col') }) },
};

function leaves(n, out = []) {
  if (n.pane) out.push(n.pane); else { leaves(n.a, out); leaves(n.b, out); }
  return out;
}
function replaceLeaf(n, id, fn) {
  if (n.pane) return n.pane === id ? fn(n) : n;
  return { ...n, a: replaceLeaf(n.a, id, fn), b: replaceLeaf(n.b, id, fn) };
}
function removeLeaf(n, id) {
  if (n.pane) return n.pane === id ? null : n;
  const a = removeLeaf(n.a, id), b = removeLeaf(n.b, id);
  return a && b ? { ...n, a, b } : a || b;
}
function pathTo(n, id, path = []) {
  if (n.pane) return n.pane === id ? path : null;
  return pathTo(n.a, id, [...path, n]) || pathTo(n.b, id, [...path, n]);
}
function defaultTree(ids) {
  if (ids.length <= 3) return chain(ids, 'row');
  const half = Math.ceil(ids.length / 2);
  return { split: 'col', ratio: 0.5, a: chain(ids.slice(0, half), 'row'), b: chain(ids.slice(half), 'row') };
}
// sanitize turns a saved tree into one that holds exactly `ids`, each once.
function sanitize(t, ids) {
  const seen = new Set();
  const clean = n => {
    if (!n || typeof n !== 'object') return null;
    if (typeof n.pane === 'string') {
      if (!ids.includes(n.pane) || seen.has(n.pane)) return null;
      seen.add(n.pane);
      return leaf(n.pane);
    }
    if (n.split !== 'row' && n.split !== 'col') return null;
    const a = clean(n.a), b = clean(n.b);
    return a && b ? { split: n.split, ratio: clampRatio(+n.ratio || 0.5), a, b } : a || b;
  };
  let tree = clean(t);
  if (!tree) return ids.length ? defaultTree(ids) : null;
  for (const id of ids.filter(id => !seen.has(id))) {
    const last = leaves(tree).at(-1);
    tree = replaceLeaf(tree, last, n => ({ split: 'row', ratio: 0.5, a: n, b: leaf(id) }));
  }
  return tree;
}

// ---- text helpers -------------------------------------------------------------

// localServers finds the local URLs a dev server printed, ready to open here.
function localServers(text) {
  const found = text.match(/https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{2,5}/g) || [];
  return [...new Set(found.map(u => u.replace(/0\.0\.0\.0|\[::\]/, 'localhost')))]; // listening on all: open locally
}

// parseHeaders reads "Name: value" lines; lines without a name are skipped.
function parseHeaders(text) {
  const headers = {};
  for (const line of text.split('\n')) {
    const i = line.indexOf(':');
    if (i > 0) headers[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return headers;
}
