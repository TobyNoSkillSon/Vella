'use strict';
const columns = [
 ['name','Model'],['quantization','Precision'],['mode','Mode'],['suite','Test'],
 ['words','Word errors','Word error rate; ignores case and punctuation. Lower is better.'],
 ['text','Text errors','Character error rate including case and punctuation. Lower is better.'],
 ['punctuation','Punct. F1','Conditional on aligned boundaries; coverage is in the source record. Higher is better.'],
 ['casing','Case accuracy','Conditional on aligned words; coverage is in the source record. Higher is better.'],
 ['speed','Speed','Warm compute throughput; not microphone-to-word latency. Higher is better.'],
 ['seconds','Compute time','Sum of per-clip median compute times, excluding loading.'],
 ['ram','MLX memory','Decimal GB allocated through MLX, not total process RAM.'],
 ['memory','Memory basis','Legacy peaks lack the newer warm-reset protocol. Timing-run and separate-run peaks are distinguished.'],
 ['date','Measured']
];
const all = VELLA_RESULTS.rows;
let key = 'text', ascending = true;
const search = document.querySelector('#search'), suite = document.querySelector('#suite'), mode = document.querySelector('#mode');
for (const label of [...new Set(all.map(row => row.suite))].sort()) suite.add(new Option(label,label));
for (const [field,label,hint] of columns) {
 const th = document.createElement('th'); th.scope='col'; th.setAttribute('aria-sort','none');
 const button=document.createElement('button'); button.type='button'; button.dataset.key=field; button.textContent=label; button.title=hint || `Sort by ${label.toLowerCase()}`;
 button.addEventListener('click',()=>{ascending=key===field?!ascending:!['speed','punctuation','casing'].includes(field);key=field;render()});
 th.append(button); document.querySelector('#head').append(th);
}
function value(row,field) {
 if(field==='quantization') return ({'4-bit':4,'8-bit':8,'BF16':16,'FP16':16,'FP32':32})[row[field]] ?? 99;
 return row[field];
}
function display(row,field) {
 const value=row[field]; if(value==null)return '—';
 if(['words','text','punctuation','casing'].includes(field))return value.toFixed(2)+'%';
 if(field==='speed')return value.toFixed(2)+'×';
 if(field==='seconds')return value.toFixed(2)+'s';
 if(field==='ram')return value.toFixed(2)+' GB';
 return value;
}
function render() {
 const query=search.value.trim().toLowerCase();
 const rows=all.filter(row=>(!query||`${row.name} ${row.quantization}`.toLowerCase().includes(query))&&(!suite.value||row.suite===suite.value)&&(!mode.value||row.mode===mode.value));
 rows.sort((a,b)=>{
  const x=value(a,key),y=value(b,key);
  if(x==null||y==null)return x==null?(y==null?a.id.localeCompare(b.id):1):-1;
  const order=typeof x==='number'?x-y:x.localeCompare(y);
  return (ascending?order:-order)||a.id.localeCompare(b.id);
 });
 const body=document.querySelector('#rows');body.replaceChildren();
 for(const row of rows){
  const tr=document.createElement('tr');tr.dataset.id=row.id;tr.title=row.provenance;
  for(const [field] of columns){
   const td=document.createElement('td');td.dataset.key=field;
   if(field==='name'){const a=document.createElement('a');a.textContent=row.name;a.href=row.source;a.title='Open measured result';td.append(a)}
   else td.textContent=display(row,field);
   tr.append(td);
  }
  body.append(tr);
 }
 if(!rows.length){const tr=document.createElement('tr'),td=document.createElement('td');td.colSpan=columns.length;td.className='empty';td.textContent='No matching models';tr.append(td);body.append(tr)}
 document.querySelector('#count').textContent=`${rows.length} / ${all.length} runs`;
 for(const button of document.querySelectorAll('th button'))button.parentElement.setAttribute('aria-sort',button.dataset.key===key?(ascending?'ascending':'descending'):'none');
}
search.addEventListener('input',render);suite.addEventListener('change',render);mode.addEventListener('change',render);
document.querySelector('#reset').addEventListener('click',()=>{search.value='';suite.value='';mode.value='';key='text';ascending=true;render();document.querySelector('.table-wrap').scrollTo(0,0)});render();
