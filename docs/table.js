'use strict';
// The benchmark table: one row per offered model × tier × path, as in the app's Models table (VELLA_BENCHMARKS schema 2,
// VELLA_MODELS from data.js), plus the cloud APIs as estimated reference rows. Absent figures show —; a cell not measured
// yet says "measure pending". Every measured cell is a row; one that loses against 16 says what in its tier tooltip.
const B = VELLA_BENCHMARKS, families = Object.fromEntries(VELLA_MODELS.families.map(f => [f.id, f]));
const columns = [
 ['name', 'Model'],
 ['mode', 'Mode'],
 ['tier', 'Tier', 'Precision kept: 16 is bf16 or fp16 (Parakeet v3 converts its pinned FP32 source once at Get), 8 and 4 are affine 8- and 4-bit (group 64) made on the Mac from it.'],
 ['path', 'Path', 'Standard: stock MLX, what any Apple-silicon Mac runs. Optimized: Vella\'s kernels for this chip; Exact uses only kernels that must match Standard on the load-time self-test, Fast adds chip-specific kernels within the model\'s own noise.'],
 ['wer', 'English WER', 'English WER on the 167 English minutes of v2 (239.7 min total); nine other languages scored separately. Word error rate: the percentage of words wrong (substituted, missed or added), ignoring case and punctuation. Lower is better. Per-language rates are in the tooltip.'],
 ['format', 'Format', 'Character error rate with case and punctuation kept: how much editing the finished text needs. Lower is better.'],
 ['languages', 'Languages', 'Benchmark languages besides English that the model supports, of 9.'],
 ['speed', 'Speed', 'Audio seconds per processing second (RTFx), after the model is loaded. 100× is a minute of audio in 0.6 s. Higher is better.'],
 ['energy', 'J / min', 'Energy the whole chip (CPU, GPU, Neural Engine and memory) used per minute of audio, idle power subtracted. Lower is better.'],
 ['memory', 'Peak RAM', 'Peak resident memory during transcription, not the idle model footprint.'],
 ['disk', 'On disk', 'Download size of a published precision, else the measured size of one made on the Mac.'],
 ['suite', 'Benchmark', 'v2: the full 240-minute benchmark. v2-quick: its 22.5-minute subset.'],
 ['date', 'Measured']
];
const higherIsBetter = new Set(['speed']);
const repoURL = repo => `https://huggingface.co/${repo}`;
const flavour = (tier, recipe) => {
 const all = (recipe.layers || {}).all;
 if (tier === '16') return `${all || 'bf16'}${recipe.converted_from ? `, converted once from the published ${recipe.converted_from}` : ', as published'}`;
 const layers = Object.entries(recipe.layers || {});
 return layers.length ? layers.map(([name, dtype]) => name === 'all' ? dtype : `${name} ${dtype}`).join('; ') : `${tier}-bit affine weights (group 64)`;
};
// Standard, then Optimized: one Optimized row where Fast runs no inexact kernel (Exact = Fast), as in the README.
const displayCell = (t, path) => t[(t.display_cells || {})[path] || path];
const pathRows = t => t.optimized_fast.recipe.inexact.length || Boolean(t.optimized_exact.measured) !== Boolean(t.optimized_fast.measured)
 ? [['Standard', displayCell(t, 'standard')], ['Optimized · Exact', displayCell(t, 'optimized_exact')], ['Optimized · Fast', displayCell(t, 'optimized_fast')]]
 : [['Standard', displayCell(t, 'standard')], ['Optimized (Exact = Fast)', displayCell(t, 'optimized_fast')]];

// What a shown cell loses against 16, from its own gate, in the app's words (TableHelp.swift cellLoss): lost test clips
// first, which an average hides, then one item per metric, limits left out. Every measured cell is offered (6 Oct).
const plainLoss = reasons => {
 const clips = [], other = [], seen = new Set();
 for (const r of reasons || []) {
  if (!r) continue;
  const m = r.match(/^(\d+) clips? empty or cut short where (?:same-layout Standard )?16 had the words(?: \(limit [^)]*\))?$/);
  if (m) { if (!seen.has('clips')) { seen.add('clips'); const n = Number(m[1]); clips.push(`${n} test clip${n === 1 ? '' : 's'} came back empty or cut short`); } continue; }
  const item = r.replace(/ \((presence limit|absent from|limit) [^)]*\)/, '').replace(/ vs (same-layout Standard )?16$/, '');
  const metric = item.split(/ [+\u2212-][0-9]/)[0];
  if (!seen.has(metric)) { seen.add(metric); other.push(item); }
 }
 return clips.concat(other);
};
const cellLoss = (t, c) => {
 const g = c.gate;
 if (!g) return t.gate.status === 'pass' ? [] : (t.gate.loss || []);
 const reasons = g.presence && g.presence.offered === false ? [...(g.presence.reasons || [])] : [];
 if (g.status === 'fail' || g.status === 'borderline') reasons.push(...(g.reasons || []));
 return plainLoss(reasons);
};
function modelRows() {
 const rows = [];
 for (const [id, model] of Object.entries(B.models)) {
  const family = families[id]; if (!family) continue;
  // Integer-like keys enumerate ascending in JS: walk 16, 8, 4 explicitly.
  for (const [tier, t] of ['16', '8', '4'].filter(k => (model.tiers || {})[k]).map(k => [k, model.tiers[k]])) {
   const variant = family.variants[t.precision] || {};
   const root = family.download?.repo || (variant.repository ? variant.repository : (family.variants[variant.derivedFrom] || {}).repository);
   for (const [path, c] of pathRows(t)) {
    if (c.gate && !c.gate.presence) continue; // malformed gate data: not offered, as in the app
    const ml = c.multilingual || {}, m = c.measured;
    rows.push({
     id: `${id}/${tier}/${path}`, name: family.name, family, reference: false,
     mode: family.mode, tier: Number(tier), tierLabel: tier, path, flavour: flavour(tier, c.recipe), loss: cellLoss(t, c),
     wer: c.wer ?? null, format: c.format ?? null, languages: ml.coverage ?? null, byLanguage: ml.by_language || null,
     speed: c.speed_x ?? null, energy: c.j_per_min ?? null, memory: c.memory_mb ?? null, disk: c.disk_mb ?? null,
     suite: m?.suite || 'v2', date: m?.date || null, pending: !m, notMeasuredReason: c.not_measured_reason || null, note: c.note || null, hardware: m?.hardware || B.hardware,
     kernels: c.recipe.kernels || [], inexact: c.recipe.inexact || [],
     url: root ? repoURL(root) : null
    });
   }
  }
 }
 return rows;
}
function referenceRows() {
 return Object.entries(B.references || {}).filter(([, r]) => r.reference && r.estimated).map(([id, r]) => ({
  id: `reference/${id}`, name: `${r.name} (cloud API)`, reference: true, mode: r.mode || 'dictation', q: null,
  wer: r.wer ?? null, range: r.range || null, byLanguage: (r.multilingual || {}).by_language || null,
  tier: null, path: null, format: null, languages: null, speed: null, energy: null, memory: null, disk: null,
  suite: 'v2', date: r.date || null, source: r.source, method: r.method
 }));
}
const all = [...modelRows(), ...referenceRows()];

const pct = v => v.toFixed(2) + '%';
const speed = v => (v >= 100 ? v.toFixed(0) : v.toFixed(1)) + '×';
const energy = v => (v < 10 ? v.toFixed(1) : v.toFixed(0)) + ' J';
const size = mb => mb >= 1000 ? (mb / 1000).toFixed(2) + ' GB' : mb.toFixed(0) + ' MB';
const languageNames = new Intl.DisplayNames(['en'], {type: 'language'});
const byLanguage = (map, approx) => Object.entries(map).sort(([a], [b]) => a.localeCompare(b))
 .map(([code, v]) => `${languageNames.of(code) || code} ${approx ? '~' + v.toFixed(0) : v.toFixed(1)}%`).join(', ');

function display(row, key) {
 const v = row[key];
 if (row.reference && key === 'wer') return v == null ? "—" : `~${v.toFixed(1)}%`;
 if (row.reference && key === 'suite') return 'estimated';
 if (key === 'date' && row.pending) return 'Not measured yet';
 if (v == null) return '—';
 switch (key) {
  case 'mode': return v === 'streaming' ? 'Streaming' : 'Dictation';
  case 'wer': case 'format': return pct(v);
  case 'languages': return `${v}/9`;
  case 'tier': return row.tierLabel;
  case 'speed': return speed(v);
  case 'energy': return energy(v);
  case 'memory': case 'disk': return size(v);
  default: return String(v);
 }
}
function tooltip(row, key) {
 if (row.pending && row.notMeasuredReason) return `Not measured yet: ${row.notMeasuredReason}`;
 if (row.reference) {
  if (key === 'wer' && row.wer != null) {
   let t = `Estimated, not measured by us: ~${row.wer.toFixed(1)}% on our v2 benchmark`;
   if (row.range) t += `, range ${row.range[0].toFixed(1)}–${row.range[1].toFixed(1)}%`;
   t += `. Estimated from the ${row.source}. ${row.method}`;
   if (row.byLanguage) t += ` Estimated by language: ${byLanguage(row.byLanguage, true)}.`;
   return t;
  }
  return key === 'name' ? 'A cloud API, shown for perspective. No audio was sent to it.' : '';
 }
 switch (key) {
  case 'name': return `Licence: ${row.family.license}.${row.url ? ' Opens the model on Hugging Face.' : ''}`;
  case 'tier': return row.flavour + (row.loss.length ? `. Loss vs 16: ${row.loss.join(', ')}.` : '.');
  case 'path': return row.path === 'Standard' ? 'Stock MLX.' : `Kernels: ${row.kernels.join(', ') || 'none'}${row.inexact.length ? `; inexact, within the model's noise: ${row.inexact.join(', ')}` : ''}.`;
  case 'wer': return row.byLanguage ? `By language: ${byLanguage(row.byLanguage, false)}.` : '';
  case 'date': return [row.hardware, row.note].filter(Boolean).join('. ');
  default: return '';
 }
}

let key = 'wer', ascending = true;
const search = document.querySelector('#search'), mode = document.querySelector('#mode'), suite = document.querySelector('#suite');
const suites = [...new Set(all.map(r => r.suite).filter(Boolean))].sort();
for (const id of suites) {
 const option = document.createElement('option'); option.value = id;
 const minutes = B.suites?.[id]?.audio_min;
 option.textContent = (id === 'v2' ? 'Full benchmark' : id === 'v2-quick' ? 'Quick subset' : id) + (minutes ? ` (${minutes} min)` : '');
 suite.append(option);
}
suite.value = suites.includes('v2') ? 'v2' : suites[0] || '';

for (const [field, label, hint] of columns) {
 const th = document.createElement('th'); th.scope = 'col'; th.setAttribute('aria-sort', 'none');
 const button = document.createElement('button'); button.type = 'button'; button.dataset.key = field; button.textContent = label;
 button.title = hint || `Sort by ${label.toLowerCase()}`;
 button.addEventListener('click', () => { ascending = key === field ? !ascending : !higherIsBetter.has(field); key = field; render(); });
 th.append(button); document.querySelector('#head').append(th);
}

function render() {
 const query = search.value.trim().toLowerCase();
 const shown = all.filter(row => (!query || (row.familyName || row.name).toLowerCase().includes(query)) && (!mode.value || row.mode === mode.value) && row.suite === suite.value);
 const rows = shown.slice().sort((a, b) => {
  const x = a[key], y = b[key];
  if (x == null || y == null) return x == null ? (y == null ? a.id.localeCompare(b.id) : 1) : -1;
  const order = typeof x === 'number' ? x - y : String(x).localeCompare(String(y));
  return (ascending ? order : -order) || a.id.localeCompare(b.id);
 });
 const body = document.querySelector('#rows'); body.replaceChildren();
 for (const row of rows) {
  const tr = document.createElement('tr'); tr.dataset.id = row.id; if (row.reference) tr.className = 'reference'; if (row.pending) tr.className = 'pending';
  for (const [field] of columns) {
   const td = document.createElement('td'); td.dataset.key = field;
   const title = tooltip(row, field); if (title) td.title = title;
   if (field === 'name' && row.url) { const a = document.createElement('a'); a.textContent = row.name; a.href = row.url; td.append(a); }
   else td.textContent = display(row, field);
   tr.append(td);
  }
  body.append(tr);
 }
 if (!rows.length) { const tr = document.createElement('tr'), td = document.createElement('td'); td.colSpan = columns.length; td.className = 'empty'; td.textContent = 'No matching models'; tr.append(td); body.append(tr); }
 document.querySelector('#footer').textContent = [rows.some(r => r.reference) ? referenceNote : ''].filter(Boolean).join(' ');
 document.querySelector('#count').textContent = `${rows.length} / ${all.filter(r => r.suite === suite.value).length} rows`;
 for (const button of document.querySelectorAll('th button')) button.parentElement.setAttribute('aria-sort', button.dataset.key === key ? (ascending ? 'ascending' : 'descending') : 'none');
}

const dates = [...new Set(all.filter(r => !r.reference && !r.pending).map(r => r.date).filter(Boolean))].sort();
document.querySelector('#summary').textContent =
 `Measured on ${B.hardware} · ${dates.length ? dates.at(-1) : '—'} · v2: ${B.suites?.v2?.audio_min ?? '—'} minutes of English and 9 other languages. Other Macs may use component fallbacks; speed, energy, peak RAM and transcripts can differ.`;
const referenceNote =
 'Cloud API rows are estimates, not measurements: we sent no audio to them. Each is the provider\'s WER on the Hugging Face Open ASR Leaderboard scaled by the ratio between our v2 WER and the leaderboard WER of the models measured on both. The WER tooltip gives the range and sources.';
search.addEventListener('input', render); mode.addEventListener('change', render); suite.addEventListener('change', render);
document.querySelector('#reset').addEventListener('click', () => { search.value = ''; mode.value = ''; suite.value = suites.includes('v2') ? 'v2' : suites[0] || ''; key = 'wer'; ascending = true; render(); document.querySelector('.table-wrap').scrollTo(0, 0); });
render();
