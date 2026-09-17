// Execute the real table renderer against only the DOM surface it uses.
// This checks native anchor markup, not browser focus or rendering behavior.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.value = '';
    this.textContent = '';
  }
  append(child) { child.parentElement = this; this.children.push(child); }
  replaceChildren() { this.children = []; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(type, listener) { this.listeners[type] = listener; }
  dispatch(type) { assert.equal(typeof this.listeners[type], 'function'); this.listeners[type](); }
  scrollTo() {}
}

const elements = Object.fromEntries([
  ['#head', 'tr'], ['#rows', 'tbody'], ['#search', 'input'],
  ['#mode', 'select'], ['#reset', 'button'], ['#count', 'span'], ['.table-wrap', 'div']
].map(([selector, tag]) => [selector, new Element(tag)]));
const document = {
  createElement: tag => new Element(tag),
  querySelector(selector) { assert.ok(elements[selector], selector); return elements[selector]; },
  querySelectorAll(selector) {
    assert.equal(selector, 'th button');
    return elements['#head'].children.flatMap(th => th.children);
  }
};
const rows = [
  {id:'a', name:'Alpha', quantization:'4-bit', mode:'Batch', date:'2026-09-12', text:3},
  {id:'b', name:'Beta', quantization:'8-bit', mode:'Streaming', date:'2026-09-14', text:1},
  {id:'c', name:'Alpha', quantization:'BF16', mode:'Streaming', date:'2026-09-13', text:2}
].map(row => ({...row, modelURL:`https://huggingface.co/example/${row.id}`,
  source:`https://example.invalid/results/${row.id}.json`, provenance:'Synthetic measurement'}));
const context = vm.createContext({document, VELLA_RESULTS:{rows}});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../docs/table.js'), 'utf8'), context);

function checkRows(ids) {
  const rendered = elements['#rows'].children;
  assert.deepEqual(rendered.map(tr => tr.dataset.id), ids);
  for (const tr of rendered) {
    const row = rows.find(row => row.id === tr.dataset.id);
    assert.equal(tr.children.length, 12, 'No added columns');
    const cell = key => tr.children.find(td => td.dataset.key === key);
    const model = cell('name').children[0], source = cell('date').children[0];
    assert.equal(cell('name').children.length, 1);
    assert.equal(cell('date').children.length, 1);
    assert.deepEqual([model.href, source.href], [row.modelURL, row.source]);
    assert.equal(model.textContent, row.name);
    assert.equal(source.textContent, row.date);
    assert.equal(source.title, 'View source measurement');
    const label = source.attributes['aria-label'];
    for (const part of [row.date, 'source measurement', row.name, row.quantization, row.mode]) {
      assert.ok(label.includes(part), `Accessible source name includes ${part}`);
    }
    for (const link of [model, source]) {
      assert.equal(link.tagName, 'A', 'Use native keyboard-operable anchors');
      assert.ok(link.href.startsWith('https://'));
      assert.equal(link.attributes.tabindex, undefined, 'Do not remove anchors from tab order');
      assert.equal(link.tabIndex, undefined);
      assert.equal(link.attributes.role, undefined, 'Preserve native link semantics');
      assert.deepEqual(Object.keys(link.listeners), [], 'No custom keyboard/click interception');
    }
  }
  assert.equal(elements['#count'].textContent, `${ids.length} / 3 runs`);
}

checkRows(['b', 'c', 'a']); // Existing initial full-text sort.
const dateButton = document.querySelectorAll('th button').find(button => button.dataset.key === 'date');
dateButton.dispatch('click');
checkRows(['a', 'c', 'b']);
assert.equal(dateButton.parentElement.attributes['aria-sort'], 'ascending');
dateButton.dispatch('click');
checkRows(['b', 'c', 'a']);
assert.equal(dateButton.parentElement.attributes['aria-sort'], 'descending');
elements['#search'].value = ' alpha ';
elements['#search'].dispatch('input');
checkRows(['c', 'a']);
elements['#mode'].value = 'Streaming';
elements['#mode'].dispatch('change');
checkRows(['c']);
elements['#search'].value = 'nonexistent';
elements['#search'].dispatch('input');
assert.equal(elements['#rows'].children[0].children[0].textContent, 'No matching models');
elements['#reset'].dispatch('click');
checkRows(['b', 'c', 'a']);
assert.equal(elements['#search'].value, '');
assert.equal(elements['#mode'].value, '');
console.log('Benchmark DOM regression passed: links, native anchors, date sort, filters, reset.');
