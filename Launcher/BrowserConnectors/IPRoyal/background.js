import './protocol.js';
const P = globalThis.FangcunIPRoyalProtocol;
const HOST = 'com.uuthings.fangcun.iproyal';
let port = null, pollTimer = null, active = null, starting = false, finishing = false, enabledSession = false, connectionGeneration = 0, requestedEnabled = null;
const now = () => Date.now()/1000;
const safeText = code => ({ready:'已连接 DeskDen',disabled:'连接已关闭',missingHost:'请先安装本机连接文件',login:'请在 Chrome 登录 IPRoyal 后重试',waiting:'等待 DeskDen 发起查询',querying:'正在读取订单额度',timeout:'页面未返回额度，请检查登录状态',unavailable:'连接暂不可用',rateLimited:'查询过于频繁，DeskDen 将稍后重试'}[code] || '连接暂不可用');
async function status(code) { await chrome.storage.local.set({status:code,statusText:safeText(code)}); }
function poll() { if (port && enabledSession) { try { port.postMessage({version:1,type:'poll'}); } catch {} } }
async function removeOwned(tabID) {
  if (!Number.isInteger(tabID)) return;
  try { const tab = await chrome.tabs.get(tabID); if (!tab.active) await chrome.tabs.remove(tabID); } catch {}
}
async function finish(code) {
  const job = active; if (!job) return; active = null; finishing=true;
  clearTimeout(job.timer);
  const result = {version:1,requestID:job.request.requestID,sourceID:job.request.sourceID,orderID:job.request.orderID,status:code,observedAt:code === 'success' ? job.observedAt : now()};
  if (code === 'success') {
    if (!job.quota || !job.documentID || !P.uuid(job.generation)) { finishing=false; return; }
    Object.assign(result,{documentID:job.documentID,generation:job.generation,gbLimit:job.quota.gb_limit,gbUsed:job.quota.gb_used,gbBalance:job.quota.gb_balance});
    if (job.resetDateText !== null && job.resetDateText !== undefined) result.resetDateText = job.resetDateText;
  }
  if (code === 'rateLimited' && job.retryAfterSeconds !== undefined) result.retryAfterSeconds=job.retryAfterSeconds;
  try { port?.postMessage({version:1,type:'result',result}); } catch {}
  await removeOwned(job.tabID); await chrome.storage.session.remove('ownedTab');
  await status(code === 'success' ? 'ready' : code === 'authentication' ? 'login' : code);
  finishing=false; poll();
}
async function begin(request) {
  if (active || finishing || !enabledSession || !P.request(request)) return;
  const job = {request,tabID:null,documentID:null,generation:null,quota:null,resetSeen:false}; active = job;
  job.timer = setTimeout(() => { if (active === job) finish(job.quota ? 'success' : 'timeout'); },45000);
  try {
    const tab = await chrome.tabs.create({url:'https://dashboard.iproyal.com/me/orders/'+request.orderID+'?tab=data-usage',active:false});
    if (active !== job) { await removeOwned(tab.id); return; }
    job.tabID = tab.id; await chrome.storage.session.set({ownedTab:tab.id}); await status('querying');
  } catch { if (active === job) await finish('unavailable'); }
}
async function connect() {
  if (port || starting || requestedEnabled === false) return;
  // Acquire before the first await: startup, alarms and popup events may overlap.
  starting = true;
  const epoch = connectionGeneration;
  const current = () => epoch === connectionGeneration;
  try {
    const preferences = await chrome.storage.local.get('enabled');
    if (!current() || requestedEnabled === false || !preferences.enabled) return;
    enabledSession=true;
    const old = (await chrome.storage.session.get('ownedTab')).ownedTab;
    if (!current()) return;
    await removeOwned(old);
    if (!current()) return;
    await chrome.storage.session.remove('ownedTab');
    if (!current() || !enabledSession) return;
    const candidate = chrome.runtime.connectNative(HOST);
    port = candidate;
    let timer = null;
    candidate.onMessage.addListener(message => {
      if (port !== candidate || !current() || !enabledSession || !P.keys(message,['version','type','request']) || message.version !== 1) return;
      if (message.type === 'request' && P.request(message.request)) begin(message.request);
      else if (message.type === 'idle' && !active) status('ready');
    });
    candidate.onDisconnect.addListener(() => {
      void chrome.runtime.lastError;
      if (port !== candidate) return;
      port = null; clearInterval(timer); if (pollTimer === timer) pollTimer = null;
      if (active) finish('unavailable'); status(enabledSession ? 'missingHost' : 'disabled');
    });
    timer = setInterval(() => { if (port === candidate && current()) poll(); },5000);
    pollTimer=timer; poll();
  } catch { if (current()) { port=null; await status(enabledSession ? 'missingHost' : 'disabled'); } }
  finally {
    starting=false;
    // A new enable action may have been waiting for an older connection attempt.
    if (!current() && enabledSession && !port) connect();
  }
}
chrome.runtime.onMessage.addListener((message,sender,reply) => {
  if (sender.id !== chrome.runtime.id || !P.keys(message,['type','generation','orderID','kind','remaining','resetDateText','retryAfterSeconds','enabled'])) return;
  if (message.type === 'setEnabled' && sender.url === chrome.runtime.getURL('popup.html') && typeof message.enabled === 'boolean') {
    (async () => {
      const epoch=++connectionGeneration; enabledSession=message.enabled;
      // Keep explicit disable authoritative while tab cleanup/storage are still pending.
      // null permits only the initial startup preference read.
      requestedEnabled=message.enabled;
      const previous=port; port=null; clearInterval(pollTimer); pollTimer=null; previous?.disconnect();
      if (active) await finish('unavailable');
      if (epoch !== connectionGeneration) { reply({ok:true}); return; }
      await chrome.storage.local.set({enabled:message.enabled});
      if (epoch !== connectionGeneration) { reply({ok:true}); return; }
      if (message.enabled) { await chrome.alarms.create('reconnect',{periodInMinutes:1}); if (epoch === connectionGeneration) await connect(); }
      else { await chrome.alarms.clear('reconnect'); if (epoch === connectionGeneration) { if (active) await finish('unavailable'); if (epoch === connectionGeneration) await status('disabled'); } }
      reply({ok:true});
    })(); return true;
  }
  const job = active;
  if (!job || sender.frameId !== 0 || sender.tab?.id !== job.tabID || !sender.documentId ||
      P.pageOrder(sender.url) !== job.request.orderID || message.orderID !== job.request.orderID || !P.uuid(message.generation)) { reply({accepted:false}); return; }
  if (message.type === 'document') {
    // A new document invalidates every observation from the preceding navigation.
    job.documentID=sender.documentId; job.generation=message.generation; job.quota=null; job.observedAt=null; job.resetSeen=false; job.resetDateText=null;
    reply({accepted:true}); return;
  }
  if (message.type !== 'observation' || sender.documentId !== job.documentID || message.generation !== job.generation) return;
  if (message.kind === 'authentication') finish('authentication');
  else if (message.kind === 'rateLimited' && P.validRetryAfter(message.retryAfterSeconds)) { job.retryAfterSeconds=message.retryAfterSeconds; finish('rateLimited'); }
  else if (message.kind === 'quota' && P.quota(message.remaining)) { job.quota={...message.remaining}; job.observedAt=now(); }
  else if (message.kind === 'reset' && P.resetDate(message.resetDateText)) { job.resetSeen=true; job.resetDateText=message.resetDateText; }
  if (active === job && job.quota && job.resetSeen) finish('success');
  reply({accepted:true});
});
chrome.tabs.onRemoved.addListener(tabID => { if (active?.tabID === tabID) finish('unavailable'); });
chrome.tabs.onActivated.addListener(({tabId}) => {
  if (active?.tabID === tabId) { active.tabID=null; chrome.storage.session.remove('ownedTab'); finish('unavailable'); }
});
chrome.tabs.onUpdated.addListener((tabID,change) => {
  if (active?.tabID !== tabID || !change.url) return;
  if (P.pageOrder(change.url) !== active.request.orderID) finish('authentication');
});
chrome.alarms.onAlarm.addListener(alarm => { if (alarm.name === 'reconnect') { connect(); poll(); } });
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(() => status('disabled'));
connect();
