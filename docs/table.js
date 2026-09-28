'use strict';
// The benchmark table: one row per measured model and precision (VELLA_BENCHMARKS, VELLA_MODELS from data.js),
// plus the cloud APIs as estimated reference rows. Absent figures show —.
const B = VELLA_BENCHMARKS, families = Object.fromEntries(VELLA_MODELS.families.map(f => [f.id, f]));
const columns = [
 ['name', 'Model'],
 ['mode', 'Mode'],
 ['q', 'Q', 'Bits per weight: 32 is FP32, 16 is BF16 or FP16, 8 and 4 are quantized. Green: the recommended precision.'],
 ['wer', 'WER', 'Word error rate: the percentage of words wrong (substituted, missed or added), ignoring case and punctuation. Lower is better. Per-language rates are in the tooltip.'],
 ['format', 'Format', 'Character error rate with case and punctuation kept: how much editing the finished text needs. Lower is better.'],
 ['languages', 'Languages', 'Benchmark languages besides English that the model supports, of 9.'],
 ['speed', 'Speed', 'Audio seconds per processing second (RTFx), after the model is loaded. 100× is a minute of audio in 0.6 s. Higher is better.'],
 ['energy', 'J / min', 'Energy the whole chip (CPU, GPU, Neural Engine and memory) used per minute of audio, idle power subtracted. Lower is better.'],
 ['memory', 'Memory', 'The loaded model\'s footprint.'],
 ['disk', 'On disk', 'Download size of a published precision, else the measured size of one made on the Mac.'],
 ['suite', 'Benchmark', 'v2: the full 240-minute benchmark. v2-quick: its 22.5-minute subset.'],
 ['date', 'Measured']
];
const higherIsBetter = new Set(['speed']);
const bits = label => ({FP32: 32, BF16: 16, FP16: 16})[label.toUpperCase()] ?? (/^\d+(\.\d+)?b$/i.test(label) ? parseFloat(label) : null);
const formatName = label => ({FP32: 'FP32 (float32)', BF16: 'BF16 (bfloat16)', FP16: 'FP16 (float16)'})[label.toUpperCase()] ?? `${bits(label)}-bit quantized`;
const repoURL = repo => `https://huggingface.co/${repo}`;

function modelRows() {
 const rows = [];
 for (const [id, model] of Object.entries(B.models)) {
  const family = families[id]; if (!family) continue;
  for (const [label, r] of Object.entries(model.precisions)) {
   const variant = family.variants[label] || {};
   const source = variant.repository ? variant : family.variants[variant.derivedFrom] || {};
   const published = Boolean(variant.repository) && variant.downloadBytes > 0;
   const ml = r.multilingual || {};
   rows.push({
    id: `${id}/${label}`, name: family.name, family, label, reference: false,
    mode: family.mode, q: bits(label), recommended: model.recommended === label,
    wer: r.wer ?? null, format: r.format ?? null, languages: ml.coverage ?? null, byLanguage: ml.by_language || null,
    speed: r.speed_x ?? null, energy: r.j_per_min ?? null, memory: r.memory_mb ?? null,
    disk: published ? variant.downloadBytes / 1e6 : r.disk_mb ?? null,
    suite: r.suite || null, date: r.date || null, engine: r.engine || null, note: r.note || null, hardware: r.hardware || B.hardware,
    url: source.repository ? repoURL(source.repository) : null, published
   });
  }
 }
 return rows;
}
function referenceRows() {
 return Object.entries(B.references || {}).filter(([, r]) => r.reference && r.estimated).map(([id, r]) => ({
  id: `reference/${id}`, name: `${r.name} (cloud API)`, reference: true, mode: r.mode || 'dictation', q: null,
  wer: r.wer ?? null, range: r.range || null, byLanguage: (r.multilingual || {}).by_language || null,
  format: null, languages: null, speed: null, energy: null, memory: null, disk: null,
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
 if (v == null) return '—';
 switch (key) {
  case 'mode': return v === 'streaming' ? 'Streaming' : 'Dictation';
  case 'wer': case 'format': return pct(v);
  case 'languages': return `${v}/9`;
  case 'speed': return speed(v);
  case 'energy': return energy(v);
  case 'memory': case 'disk': return size(v);
  default: return String(v);
 }
}
function tooltip(row, key) {
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
  case 'name': return `Licence: ${row.family.license}.${row.family.offered ? '' : ' Measured, but not offered in the app.'}${row.url ? ' Opens the model on Hugging Face.' : ''}`;
  case 'q': return formatName(row.label) + (row.published ? ', published' : ', made on the Mac from the higher precision') + (row.recommended ? '. Recommended: lowest energy per audio minute within 0.1 points of the native precision\'s WER (up to 0.2 points for a model with measured run-to-run noise).' : '.');
  case 'wer': return row.byLanguage ? `By language: ${byLanguage(row.byLanguage, false)}.` : '';
  case 'speed': return row.engine === 'optimized' ? 'Vella\'s optimized path, self-tested against stock MLX.' : row.engine === 'mlx' ? 'Stock MLX path.' : '';
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
 const rows = all.filter(row => (!query || row.name.toLowerCase().includes(query)) && (!mode.value || row.mode === mode.value) && row.suite === suite.value);
 rows.sort((a, b) => {
  const x = a[key], y = b[key];
  if (x == null || y == null) return x == null ? (y == null ? a.id.localeCompare(b.id) : 1) : -1;
  const order = typeof x === 'number' ? x - y : String(x).localeCompare(String(y));
  return (ascending ? order : -order) || a.id.localeCompare(b.id);
 });
 const body = document.querySelector('#rows'); body.replaceChildren();
 for (const row of rows) {
  const tr = document.createElement('tr'); tr.dataset.id = row.id; if (row.reference) tr.className = 'reference';
  for (const [field] of columns) {
   const td = document.createElement('td'); td.dataset.key = field;
   const title = tooltip(row, field); if (title) td.title = title;
   if (field === 'name' && row.url) { const a = document.createElement('a'); a.textContent = row.name; a.href = row.url; td.append(a); }
   else td.textContent = display(row, field);
   if (field === 'name' && !row.reference && !row.family.offered) { const tag = document.createElement('span'); tag.className = 'tag'; tag.textContent = 'not in the app'; td.append(tag); }
   if (field === 'q' && row.recommended) { td.classList.add('recommended'); td.textContent += ' · recommended'; }
   tr.append(td);
  }
  body.append(tr);
 }
 if (!rows.length) { const tr = document.createElement('tr'), td = document.createElement('td'); td.colSpan = columns.length; td.className = 'empty'; td.textContent = 'No matching models'; tr.append(td); body.append(tr); }
 document.querySelector('#footer').textContent = rows.some(r => r.reference) ? referenceNote : '';
 document.querySelector('#count').textContent = `${rows.length} / ${all.filter(r => r.suite === suite.value).length} rows`;
 for (const button of document.querySelectorAll('th button')) button.parentElement.setAttribute('aria-sort', button.dataset.key === key ? (ascending ? 'ascending' : 'descending') : 'none');
}

const dates = [...new Set(all.filter(r => !r.reference).map(r => r.date).filter(Boolean))].sort();
document.querySelector('#summary').textContent =
 `Measured on ${B.hardware} · ${dates.length ? dates.at(-1) : '—'} · v2: ${B.suites?.v2?.audio_min ?? '—'} minutes of English and 9 other languages. Other Macs differ in speed, energy and memory, not accuracy.`;
const referenceNote =
 'Cloud API rows are estimates, not measurements: we sent no audio to them. Each is the provider\'s WER on the Hugging Face Open ASR Leaderboard scaled by the ratio between our v2 WER and the leaderboard WER of the models measured on both. The WER tooltip gives the range and sources.';
search.addEventListener('input', render); mode.addEventListener('change', render); suite.addEventListener('change', render);
document.querySelector('#reset').addEventListener('click', () => { search.value = ''; mode.value = ''; suite.value = suites.includes('v2') ? 'v2' : suites[0] || ''; key = 'wer'; ascending = true; render(); document.querySelector('.table-wrap').scrollTo(0, 0); });
render();
