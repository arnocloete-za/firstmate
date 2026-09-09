// Run a generated dashboard page's own inline script under a minimal DOM shim
// and print what the page actually DOES, so overlay behavior is asserted by
// driving the shipped page rather than by reading its source.
//
// Usage: node dashboard-page-harness.mjs <page.html> <scenario> [argument]
//   overlays            click every card, its backdrop, and its close control
//   save <project>      open that project's overlay, then deliver a stamp
//                       carrying different content, and report what the page
//                       asked the next load to restore
//   restore <name>      load with that window.name already set, as the tab
//                       hands it back across a reload
//   clock <iso>         load with the tab's clock at that instant and report
//                       every age the page painted for itself
// Prints one JSON document per scenario.
import { readFileSync } from 'node:fs';

const [, , pagePath, scenario, argument] = process.argv;
const html = readFileSync(pagePath, 'utf8');

// --- the DOM shim ----------------------------------------------------------
const VOID = new Set(['meta', 'br', 'link', 'img', 'input', 'hr', 'source']);
const RAW = new Set(['script', 'style']);
const unescape = (value) => value
  .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
  .replace(/&#39;/g, "'").replace(/&amp;/g, '&');

class Node {
  constructor(tag, attributes = {}) {
    this.tagName = tag;
    this.attributes = attributes;
    this.children = [];
    this.parentNode = null;
    this.listeners = new Map();
    this.text = '';
    this.dataset = new Proxy(this.attributes, {
      get: (attributes_, key) => attributes_[`data-${String(key).replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)}`],
    });
    this.classList = {
      contains: (name) => this.classes().includes(name),
      add: (name) => { if (!this.classes().includes(name)) this.attributes.class = `${this.className} ${name}`.trim(); },
      remove: (name) => { this.attributes.class = this.classes().filter((c) => c !== name).join(' '); },
      toggle: (name, on) => (on ? this.classList.add(name) : this.classList.remove(name)),
    };
  }

  classes() { return (this.className || '').split(/\s+/).filter(Boolean); }

  get className() { return this.attributes.class || ''; }

  get id() { return this.attributes.id || ''; }

  get textContent() {
    return this.children.length ? this.children.map((c) => c.textContent).join('') : this.text;
  }

  set textContent(value) { this.text = String(value); this.children = []; }

  appendChild(node) { node.parentNode = this; this.children.push(node); return node; }

  remove() {
    if (this.parentNode) this.parentNode.children = this.parentNode.children.filter((c) => c !== this);
  }

  setAttribute(key, value) { this.attributes[key] = String(value); }

  addEventListener(type, handler) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(handler);
  }

  // A click fires on the element and then on its ancestors, so a handler that
  // separates a backdrop click from a click inside the overlay is exercised the
  // way a browser exercises it.
  click() {
    const event = { type: 'click', target: this };
    for (let node = this; node; node = node.parentNode) {
      for (const handler of node.listeners.get('click') || []) handler.call(node, event);
    }
  }

  showModal() { this.attributes.open = ''; }

  // A non-modal open is a different thing: Escape does not close it and focus
  // is not held inside it, so the harness reports which one the page used.
  show() { this.attributes.open = ''; this.nonModal = true; }

  close() { delete this.attributes.open; }

  matches(selector) {
    const tag = selector.match(/^[a-z]+/)?.[0];
    if (tag && tag !== this.tagName) return false;
    for (const wanted of selector.match(/\.[\w-]+/g) || []) {
      if (!this.classList.contains(wanted.slice(1))) return false;
    }
    for (const wanted of selector.match(/\[[^\]]+\]/g) || []) {
      const [name, value] = wanted.slice(1, -1).split('=');
      if (!(name in this.attributes)) return false;
      if (value !== undefined && this.attributes[name] !== value.replace(/^"|"$/g, '')) return false;
    }
    return true;
  }

  querySelectorAll(selector) {
    const out = [];
    const walk = (node) => {
      for (const child of node.children) {
        if (child.matches(selector)) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }

  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}

// A tag-stack scan: enough of a parser for a page this command generates
// itself, and faithful about nesting, which is what the click path needs.
function parse(source) {
  const root = new Node('#root');
  let node = root;
  const tag = /<(\/?)([a-zA-Z][\w-]*)((?:\s+[^\s=>/]+(?:\s*=\s*"[^"]*")?)*)\s*(\/?)>/g;
  let at = 0;
  let match = tag.exec(source);
  while (match) {
    if (match.index > at) node.text += source.slice(at, match.index);
    const [whole, closing, name, attributeText, selfClosing] = match;
    if (closing) {
      if (node.tagName === name && node.parentNode) node = node.parentNode;
    } else {
      const attributes = {};
      for (const [, key, value] of attributeText.matchAll(/([^\s=]+)(?:\s*=\s*"([^"]*)")?/g)) {
        if (key) attributes[key] = value === undefined ? '' : unescape(value);
      }
      const child = node.appendChild(new Node(name, attributes));
      if (RAW.has(name)) {
        // A raw-text element's content is text, never markup to descend into.
        const end = source.indexOf(`</${name}>`, match.index + whole.length);
        child.text = source.slice(match.index + whole.length, end < 0 ? source.length : end);
        tag.lastIndex = end < 0 ? source.length : end + name.length + 3;
      } else if (!selfClosing && !VOID.has(name)) {
        node = child;
      }
    }
    at = tag.lastIndex;
    match = tag.exec(source);
  }
  return root;
}

const document_ = parse(html);
document_.getElementById = (id) => document_.querySelectorAll(`[id="${id}"]`)[0] || null;
document_.createElement = (tag) => new Node(tag);
document_.head = document_.querySelector('head') || document_.appendChild(new Node('head'));

const reloads = [];
const scrolls = [];
globalThis.document = document_;
globalThis.window = {
  name: scenario === 'restore' ? argument : '',
  scrollY: 640,
  scrollTo: (x, y) => scrolls.push(y),
};
globalThis.history = { scrollRestoration: 'auto' };
globalThis.location = { reload: () => reloads.push(true) };
// Node already owns `navigator`, so the clipboard stub is defined onto it.
Object.defineProperty(globalThis, 'navigator', {
  value: { clipboard: { writeText: () => Promise.resolve() } }, configurable: true,
});
globalThis.setInterval = () => 0;
globalThis.setTimeout = () => 0;
if (scenario === 'clock') {
  const fixed = Date.parse(argument);
  Date.now = () => fixed;
}

const script = html.slice(html.indexOf('<script>') + '<script>'.length, html.lastIndexOf('</script>'));
new Function(script)();

// --- the scenarios ---------------------------------------------------------
const openNow = () => document_.querySelector('dialog.detail[open]')?.dataset.project ?? null;
const say = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);

if (scenario === 'overlays') {
  // Measured before anything is clicked: a board opens with nothing in the way.
  const openOnLoad = openNow();
  const cards = document_.querySelectorAll('button.card[data-detail]').map((card) => {
    card.click();
    const opened = openNow();
    const dialog = document_.querySelector('dialog.detail[open]');
    // The backdrop is the dialog element itself; everything visible is inside.
    if (dialog) dialog.click();
    const afterBackdrop = openNow();
    card.click();
    const closeControl = dialog?.querySelector('button.detail-close');
    if (closeControl) closeControl.click();
    return {
      card: card.querySelector('span.proj-name')?.textContent ?? '',
      opened,
      modal: Boolean(dialog) && !dialog.nonModal,
      afterBackdrop,
      hasCloseControl: Boolean(closeControl),
      afterCloseControl: openNow(),
    };
  });
  say({ openOnLoad, cards });
} else if (scenario === 'save') {
  const card = document_.querySelectorAll('button.card[data-detail]')
    .find((c) => c.querySelector('span.proj-name')?.textContent === argument);
  if (!card) throw new Error(`no card for ${argument}`);
  card.click();
  const openedBefore = openNow();
  // What the watch delivers when the board changed under an open overlay.
  globalThis.window.fmDashboardStamp({
    content: 'a-different-board',
    readAt: new Date(Date.now() + 60000).toISOString(),
    dueBy: new Date(Date.now() + 120000).toISOString(),
    watching: true,
  });
  say({ openedBefore, reloaded: reloads.length, name: globalThis.window.name });
} else if (scenario === 'restore') {
  say({ openOnLoad: openNow(), scrolls });
} else if (scenario === 'clock') {
  say({
    ages: document_.querySelectorAll('span.ago[data-at]').map((n) => n.textContent),
    recent: document_.querySelectorAll('.commit[data-recent-at]').map((n) => ({
      at: n.dataset.recentAt, recent: n.classList.contains('recent'),
    })),
  });
} else {
  throw new Error(`unknown scenario: ${scenario}`);
}
