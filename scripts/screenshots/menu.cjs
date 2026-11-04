const path = require('node:path');
const fs = require('node:fs');
const board = require('./menu-board.cjs');
module.exports = async (root, output) => {
  const renderer = require('../../dist-electron/statusBar.js');
  const { defaultPrefs } = require('../../dist-electron/prefs.js');
  const { BAR_DESIGNS } = require('../../dist-electron/barDesign.js');
  const { MENU_BAR_SCALES, MENU_BAR_SCALE_LABELS } = require('../../dist-electron/types.js');
  const names = { chatgpt:'ChatGPT', cursor:'Cursor', grokbot:'Grok Bot', openai:'OpenAI API', claude:'Claude' };
  const quotas = ['chatgpt','cursor','grokbot','claude'];
  const ids = ['chatgpt','cursor','grokbot','openai','claude'];
  renderer.setArtworkRoot(path.join(root,'menubar/Artwork'));
  await renderer.warmStatusBarIcons(ids);
  const source = (id,work=false) => ({ id, enabled:true, showInTray:true, status:'ok',
    meters: work || id==='openai' ? [] : id==='chatgpt' || id==='claude'
      ? [{id:'session',label:'5-hour',percentLeft:id==='claude'?64:78},{id:'weekly',label:'Weekly',percentLeft:id==='claude'?85:42}]
      : [{id:'weekly',label:id==='cursor'?'Included allowance':'Weekly',percentLeft:id==='cursor'?92:56}],
    lines:id==='openai'?[{label:'Estimated balance',value:'$24.15'}]:[],
    ...(work || id==='openai' ? {todayUSD:2.40,monthUSD:18.60}:{}),
  });
  const render = (sources,design,patch={}) => {
    const prefs=defaultPrefs();Object.assign(prefs,patch);
    for (const id of ids) Object.assign(prefs.sources[id],{enabled:true,showInTray:true,barDesign:design,sharedPill:false});
    return renderer.renderStatusBarPng(renderer.blocksFromSources(sources,prefs),prefs).png;
  };
  if(ids.some(id=>defaultPrefs().sources[id].sharedPill!==false)) throw new Error('Shared pill default changed; review documentation');
  const items=[];
  const styleProofs={};
  const mixedPrefs=defaultPrefs();
  const mixedStyles={chatgpt:'divider',cursor:'rings',grokbot:'baseline',openai:'stack',claude:'lanes'};
  for(const id of ids)Object.assign(mixedPrefs.sources[id],{enabled:true,showInTray:true,barDesign:mixedStyles[id],sharedPill:false});
  const mixed=renderer.renderStatusBarPng(renderer.blocksFromSources(ids.map(id=>source(id)),mixedPrefs),mixedPrefs);
  fs.writeFileSync(path.join(output,'menu-bar-combined.png'),mixed.png);
  const {nativeImage}=require('electron');
  items.push({file:'menu-bar-combined.png',caption:'One combined menu bar with ChatGPT, Cursor, Grok Bot, OpenAI API, and Claude, each using its own supported style.',size:nativeImage.createFromBuffer(mixed.png).getSize()});
  const save = async (file,title,rows,caption) => items.push(await board(output,file,title,rows,caption));
  const shared = (sources,{optOut=[],letters=false}={}) => {
    const prefs=defaultPrefs();Object.assign(prefs,{sharedRingLetters:letters});
    for(const id of ids)Object.assign(prefs.sources[id],{enabled:true,showInTray:true,sharedPill:!optOut.includes(id),barDesign:'lanes'});
    const blocks=renderer.blocksFromSources(sources,prefs);
    if(blocks.filter(block=>block.sharedPill).length!==sources.length-optOut.length)throw new Error('Shared provider participation mismatch');
    return renderer.renderStatusBarPng(blocks,prefs).png;
  };
  const compact=['chatgpt','cursor','grokbot'].map((id,i)=>{
    const sample=source(id);sample.meters=sample.meters.slice(0,1);sample.meters[0].percentLeft=[81,67,32][i];return sample;
  });
  const compactPng=shared(compact);
  fs.writeFileSync(path.join(output,'menu-bar-shared-pill.png'),compactPng);
  items.unshift({file:'menu-bar-shared-pill.png',caption:'One shared pill containing ChatGPT, Cursor, and Grok Bot, with fictional remaining allowances and standard provider marks.',size:nativeImage.createFromBuffer(compactPng).getSize()});
  await save('menu-bar-shared-options.png','TokenPulse · single combined pill',[
    {label:'Compact example · three providers reporting a single allowance',png:compactPng},
    {label:'All five providers · allowance rings and OpenAI money figures',png:shared(ids.map(id=>source(id)))},
    {label:'Mixed mode · Claude opts out and keeps its own Stacked tracks capsule',png:shared(ids.map(id=>source(id)),{optOut:['claude']})},
    {label:'Optional ring letters enabled · all five providers',png:shared(ids.map(id=>source(id)),{letters:true})},
  ],'Shared-pill examples: compact standard marks, all five providers, per-provider opt-out, and optional ring letters. All data is synthetic.');

  await save('menu-bar.png','TokenPulse · every menu-bar style',BAR_DESIGNS.map((style,i) => {
    const id=quotas[i%quotas.length];return {label:`${style.number} · ${style.name} — ${names[id]}`,png:render([source(id)],style.id)};
  }),'All seven menu-bar styles, rendered by production code with fictional allowance values.');
  await save('menu-bar-providers.png','TokenPulse · all five providers',ids.map((id,i)=>({
    label:`${names[id]} · ${id==='openai'?'estimated balance, daily and monthly spend':'personal allowance'}`,
    png:render([source(id)],id==='openai'?'stack':BAR_DESIGNS[i].id),
  })),'Every provider appears: ChatGPT, Cursor, Grok Bot, OpenAI API, and Claude. OpenAI shows money rather than quota gauges.');
  for (const style of BAR_DESIGNS) {
    const rows=quotas.map(id=>({label:names[id],png:render([source(id)],style.id)}));
    styleProofs[style.id]=require('node:crypto').createHash('sha256').update(Buffer.concat(rows.map(row=>row.png))).digest('hex');
    await save(`menu-bar-style-${style.id}.png`,`${style.number} · ${style.name}`,rows,
      `${style.name} with each allowance provider: ChatGPT, Cursor, Grok Bot, and Claude.`);
  }
  if(new Set(Object.values(styleProofs)).size!==BAR_DESIGNS.length) throw new Error('Menu styles unexpectedly render identically');
  await save('menu-bar-spend.png','TokenPulse · spend and balance',BAR_DESIGNS.filter(style=>style.spendOk).flatMap(style=>['openai','chatgpt','cursor','claude'].map(id=>({
    label:`${names[id]} · ${style.name} · ${id==='openai'?'B balance / D today / M month':'work spend: D today / M month'}`,
    png:render([source(id,true)],style.id),
  }))),'Both supported spend layouts for OpenAI balance and ChatGPT, Cursor, and Claude work spend. Dollar figures never use quota gauges.');
  const samples = ['chatgpt','openai'].map(id=>source(id));
  await save('menu-bar-appearance.png','TokenPulse · appearance choices',[
    {label:'Current monochrome provider marks · capsule background',png:render(samples,'divider')},
    {label:'Current monochrome provider marks · capsule background off',png:render(samples,'divider',{darkBarBackground:false})},
  ],'ChatGPT and OpenAI using the current monochrome marks, with capsule backgrounds on and off.');
  await save('menu-bar-sizes.png','TokenPulse · every menu-bar size',MENU_BAR_SCALES.map(scale=>({label:`${MENU_BAR_SCALE_LABELS[scale]} · ${scale}%`,png:render([source('chatgpt'),source('claude')],'stack',{menuBarScale:scale})})),
    'All eight supported menu-bar sizes, from Normal (100%) to Micro (65%), using the Compact stack style.');
  const normal=source('chatgpt'), low=source('claude');low.meters[0].percentLeft=10;low.meters[1].percentLeft=5;
  const empty=source('cursor');empty.meters[0].percentLeft=0;
  await save('menu-bar-status.png','TokenPulse · allowance states',[
    {label:'Healthy allowance',png:render([normal],'divider')},
    {label:'Low allowance · 10% session / 5% weekly',png:render([low],'lanes')},
    {label:'Exhausted allowance · 0% remaining',png:render([empty],'divider')},
    {label:'Stale data · last received values fade',png:render([{...normal,status:'stale'}],'divider')},
  ],'Healthy, low, exhausted, and stale allowance states using production status and tint logic.');
  const coverage={styles:BAR_DESIGNS.map(s=>s.id),providers:ids,allowanceProviders:quotas,
    quotaExamples:BAR_DESIGNS.length*quotas.length,spendExamples:BAR_DESIGNS.filter(s=>s.spendOk).length*4,
    sizes:[...MENU_BAR_SCALES],providerArtwork:"monochrome",sharedPill:true,sharedPillExamples:4,styleProofs};
  if(coverage.styles.length!==7 || coverage.providers.length!==5 || coverage.quotaExamples!==28 || coverage.spendExamples!==8) throw new Error('Incomplete menu-bar coverage');
  fs.writeFileSync(path.join(output,'menu-coverage.json'),JSON.stringify(coverage,null,2)+'\n');
  return items;
};
