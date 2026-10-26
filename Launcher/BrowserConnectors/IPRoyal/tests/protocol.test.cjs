const test=require('node:test'), assert=require('node:assert/strict'), vm=require('node:vm'), fs=require('node:fs'), path=require('node:path'), crypto=require('node:crypto');
const root=path.join(__dirname,'..'), load=n=>fs.readFileSync(path.join(root,n),'utf8');
function protocol(){const c=vm.createContext({URL,Date});vm.runInContext(load('protocol.js'),c);return c.FangcunIPRoyalProtocol;}
const P=protocol();
test('manifest grants only dashboard and required bridge capabilities, stable public identity',()=>{
 const m=JSON.parse(load('manifest.json'));assert.deepEqual(m.permissions,['storage','alarms','nativeMessaging']);
 assert.deepEqual(m.host_permissions,['https://dashboard.iproyal.com/*']);
 assert.equal(m.content_scripts.length,2);for(const s of m.content_scripts){assert.equal(s.all_frames,false);assert.deepEqual(s.matches,['https://dashboard.iproyal.com/me/orders/*']);}
 const id=[...crypto.createHash('sha256').update(Buffer.from(m.key,'base64')).digest('hex').slice(0,32)].map(c=>String.fromCharCode(97+parseInt(c,16))).join('');
 assert.equal(id,load('extension-id.txt').trim());
});
test('quota schema rejects invalid types, inconsistency and overflows without inventing zero',()=>{
 assert.equal(P.quota({gb_limit:400,gb_used:397.073,gb_balance:2.927}),true);
 for(const bad of [{gb_limit:100,gb_used:0,gb_balance:0},{gb_limit:0,gb_used:0,gb_balance:0},{gb_limit:100,gb_used:'1',gb_balance:99},{gb_limit:100,gb_used:NaN,gb_balance:99},{gb_limit:Infinity,gb_used:1,gb_balance:2},{gb_limit:100,gb_used:1,gb_balance:99,token:'fixture-not-a-credential'}])assert.equal(P.quota(bad),false);
 assert.equal(P.resetDate('2026-02-30'),false);assert.equal(P.resetDate('2028-02-29'),true);
});
test('only exact order GET endpoints are eligible',()=>{
 assert.equal(P.apiRequest('https://apid.iproyal.com/v1/orders/123/data-usage?measurement_unit=MB','GET').orderID,'123');
 for(const [u,m] of [['https://apid.iproyal.com/v1/orders/123','POST'],['https://apid.iproyal.com.evil.test/v1/orders/123','GET'],['https://apid.iproyal.com/v1/orders/proxies','GET'],['https://apid.iproyal.com/v1/user/me','GET'],['https://apid.iproyal.com/v1/orders/123?api_key=fixture','GET'],['https://apid.iproyal.com/v1/orders/123/extras','GET'],['http://apid.iproyal.com/v1/orders/123','GET']])assert.equal(P.apiRequest(u,m),null);
 assert.equal(P.pageOrder('https://dashboard.iproyal.com/me/orders/123?tab=data-usage'),'123');assert.equal(P.pageOrder('https://accounts.google.com/'),null);
});
function observer(body,status=200,options={}){
 const emitted=[], listeners={}, c={URL,Date,TextDecoder,Uint8Array,WeakMap,Reflect,Promise,Response,
 location:{origin:'https://dashboard.iproyal.com',href:'https://dashboard.iproyal.com/me/orders/123?tab=data-usage'},
 postMessage:v=>emitted.push(v),addEventListener:(n,fn)=>{(listeners[n]??=[]).push(fn)},fetch:()=>options.fetchPromise??Promise.resolve(new Response(body,{status,headers:options.headers}))};
 c.window=c;c.top=c;c.XMLHttpRequest=function(){this.listeners={};};c.XMLHttpRequest.prototype={open(){},send(){},addEventListener(n,f){(this.listeners[n]??=[]).push(f);},emit(n){for(const f of this.listeners[n]??[])f.call(this);}};
 vm.createContext(c);vm.runInContext(load('protocol.js'),c);vm.runInContext(load('observer.js'),c);
 vm.runInContext(`globalThis.bindEvent={source:window,origin:location.origin,data:{channel:'fangcun-iproyal-quota',version:1,type:'bind',generation:'00000000-0000-4000-8000-000000000001'}}`,c);
 const bind=()=>{for(const fn of listeners.message)fn(c.bindEvent);};if(options.bound!==false)bind();return{c,emitted,bind};
}
const settle=()=>new Promise(r=>setTimeout(r,30));
test('observer exports only quota fields and never reads request headers',async()=>{
 const{c,emitted}=observer(JSON.stringify({remaining:{gb_limit:100,gb_used:1,gb_balance:99},private_field:'discard'}));
 const init={method:'GET',get headers(){throw Error('headers accessed')}};
 const response=await c.fetch('https://apid.iproyal.com/v1/orders/123/data-usage',init);assert.equal(response.status,200);await settle();
 assert.equal(emitted.length,1);assert.deepEqual(Object.keys(emitted[0]).sort(),['channel','generation','orderID','remaining','type','version']);assert.equal(JSON.stringify(emitted).includes('private_field'),false);
});
test('observer ignores wrong orders, POST and oversized responses',async()=>{
 for(const [url,init,body] of [['https://apid.iproyal.com/v1/orders/456/data-usage',{},'{"remaining":{"gb_limit":100,"gb_used":1,"gb_balance":99}}'],['https://apid.iproyal.com/v1/orders/123/data-usage',{method:'POST'},'{}'],['https://apid.iproyal.com/v1/orders/123/data-usage',{},' '.repeat(65537)]]){
  const{c,emitted}=observer(body);await c.fetch(url,init);await settle();assert.equal(emitted.length,0);
 }
});
test('observer reports authentication failure without body content',async()=>{
 const{c,emitted}=observer('{"secret":"discard"}',401);await c.fetch('https://apid.iproyal.com/v1/orders/123/data-usage');await settle();assert.equal(emitted.length,1);assert.equal(emitted[0].type,'authentication');assert.equal(JSON.stringify(emitted).includes('secret'),false);
});
function event(){const f=[];return{addListener:fn=>f.push(fn),emit:(...a)=>f.map(fn=>fn(...a))};}
function background(options={}){
 const messages=[],created=[],removed=[],tabMap=new Map(),timers=[],local={enabled:true},session={},ports=[],intervals=new Set();let nativeCalls=0,intervalID=0;
 const storage=data=>({get:async k=>{if(data===local&&k==='enabled'&&options.storageGate)await options.storageGate;return typeof k==='string'?{[k]:data[k]}:{...data};},set:async v=>Object.assign(data,v),remove:async k=>{delete data[k]}});
 const makePort=()=>({postMessage:v=>messages.push(v),onMessage:event(),onDisconnect:event(),disconnect(){this.onDisconnect.emit();}});const port=makePort();
 const chrome={storage:{local:storage(local),session:storage(session)},runtime:{id:'fixture-extension',connectNative:()=>{const p=nativeCalls++===0?port:makePort();ports.push(p);return p;},getURL:p=>'chrome-extension://fixture-extension/'+p,onMessage:event(),onStartup:event(),onInstalled:event()},alarms:{create:async()=>{},clear:async()=>{},onAlarm:event()},tabs:{
 create:async spec=>{const tab={id:1,...spec};created.push(spec);tabMap.set(1,tab);return tab;},get:async id=>{if(!tabMap.has(id))throw Error('missing');return tabMap.get(id);},remove:async id=>{if(options.removeGate)await options.removeGate;removed.push(id);tabMap.delete(id);chrome.tabs.onRemoved.emit(id);},onRemoved:event(),onUpdated:event(),onActivated:event()}};
 const c=vm.createContext({chrome,URL,Date,console,setTimeout:(fn,ms)=>{const t={fn,ms};timers.push(t);return t;},clearTimeout:t=>{t.cancelled=true;},setInterval:()=>{const id=++intervalID;intervals.add(id);return id;},clearInterval:id=>intervals.delete(id)});
 vm.runInContext(load('protocol.js'),c);vm.runInContext(load('background.js').replace("import './protocol.js';",''),c);
 const request={version:1,requestID:'10000000-0000-4000-8000-000000000001',sourceID:'20000000-0000-4000-8000-000000000001',orderID:'123',createdAt:Date.now()/1000,expiresAt:Date.now()/1000+180};
 const sender={id:chrome.runtime.id,frameId:0,tab:{id:1},documentId:'doc-A',url:'https://dashboard.iproyal.com/me/orders/123?tab=data-usage'};
 const generation='30000000-0000-4000-8000-000000000001';
 const send=(message,override={})=>{let response;chrome.runtime.onMessage.emit({generation,orderID:'123',...message},{...sender,...override},r=>response=r);return response;};
 return{chrome,port,messages,created,removed,timers,tabMap,request,send,sender,generation,ports,intervals,nativeCalls:()=>nativeCalls,local};
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
async function start(h){await flush();h.port.onMessage.emit({version:1,type:'request',request:h.request});await flush();h.send({type:'document'});}
const quotaMessage={type:'observation',kind:'quota',remaining:{gb_limit:100,gb_used:1,gb_balance:99}};
const resetMessage={type:'observation',kind:'reset',resetDateText:'2026-11-25'};
test('worker creates only one inactive owned tab, accepts matching document and closes it',async()=>{
 const h=background();await start(h);h.port.onMessage.emit({version:1,type:'request',request:h.request});await flush();assert.equal(h.created.length,1);assert.equal(h.created[0].active,false);
 h.send(quotaMessage);h.send(resetMessage);await flush();const r=h.messages.find(m=>m.type==='result').result;assert.equal(r.status,'success');assert.equal(r.gbBalance,99);assert.deepEqual(h.removed,[1]);assert.equal(r.documentID,'doc-A');
});
test('worker rejects subframes, unrelated tabs, old documents and old generations',async()=>{
 const h=background();await start(h);
 h.send(quotaMessage,{frameId:1});h.send(quotaMessage,{tab:{id:2}});h.send(quotaMessage,{documentId:'old-document'});h.send({...quotaMessage,generation:'40000000-0000-4000-8000-000000000001'});h.send(resetMessage);await flush();assert.equal(h.messages.some(m=>m.type==='result'),false);
 h.send(quotaMessage);await flush();assert.equal(h.messages.find(m=>m.type==='result').result.status,'success');
});
test('new document discards all prior quota observations',async()=>{
 const h=background();await start(h);h.send(quotaMessage);h.send({type:'document'},{documentId:'doc-B'});h.send(resetMessage,{documentId:'doc-B'});await flush();assert.equal(h.messages.some(m=>m.type==='result'),false);
 h.send(quotaMessage,{documentId:'doc-B'});await flush();assert.equal(h.messages.find(m=>m.type==='result').result.documentID,'doc-B');
});
test('a user activating the connector tab takes ownership and it is not closed',async()=>{
 const h=background();await start(h);h.tabMap.get(1).active=true;h.chrome.tabs.onActivated.emit({tabId:1});await flush();assert.equal(h.removed.length,0);assert.equal(h.messages.find(m=>m.type==='result').result.status,'unavailable');
});
test('timeout reports missing data without a zero reading and removes its tab',async()=>{
 const h=background();await start(h);h.timers.find(t=>t.ms===45000).fn();await flush();const result=h.messages.find(m=>m.type==='result').result;assert.equal(result.status,'timeout');assert.equal('gbUsed' in result,false);assert.deepEqual(h.removed,[1]);
});
test('navigation to authentication closes only the connector tab and forwards no URL',async()=>{
 const h=background();await start(h);h.chrome.tabs.onUpdated.emit(1,{url:'https://dashboard.iproyal.com/login'});await flush();const result=h.messages.find(m=>m.type==='result').result;assert.equal(result.status,'authentication');assert.equal('url' in result,false);
});

test('XHR JSON reads only bounded quota fields and ignores the rest of its parsed response',()=>{
 const{c,emitted}=observer('{}');const xhr=new c.XMLHttpRequest();
 xhr.open('GET','https://apid.iproyal.com/v1/orders/123/data-usage');xhr.send();
 xhr.status=200;xhr.responseURL='https://apid.iproyal.com/v1/orders/123/data-usage';xhr.responseType='json';
 xhr.response={remaining:{gb_limit:100,gb_used:2,gb_balance:98},get unrelated(){throw Error('unrelated field accessed');}};
 xhr.emit('load');assert.equal(emitted.length,1);assert.equal(emitted[0].remaining.gb_used,2);assert.equal('unrelated' in emitted[0],false);
});
test('XHR JSON preserves reset dates and rejects redirect order mismatches',()=>{
 for(const [url,expected] of [['https://apid.iproyal.com/v1/orders/123',1],['https://apid.iproyal.com/v1/orders/456',0]]){
  const{c,emitted}=observer('{}');const xhr=new c.XMLHttpRequest();xhr.open('GET','https://apid.iproyal.com/v1/orders/123');xhr.send();
  xhr.status=200;xhr.responseURL=url;xhr.responseType='json';xhr.response={bandwidth_limit_reset_at:'2026-11-25'};xhr.emit('load');
  assert.equal(emitted.length,expected);if(expected)assert.equal(emitted[0].resetDateText,'2026-11-25');
 }
});

function deferred(){let resolve;const promise=new Promise(r=>resolve=r);return{promise,resolve};}
test('Retry-After parses seconds and HTTP dates with a seven-day bound',()=>{
 const now=Date.parse('Mon, 26 Oct 2026 00:00:00 GMT')/1000;
 assert.equal(P.retryAfter('120',now),120);assert.equal(P.retryAfter('Mon, 26 Oct 2026 00:02:00 GMT',now),120);
 assert.equal(P.retryAfter('99999999999999999999',now),604800);assert.equal(P.retryAfter('Sun, 25 Oct 2026 00:00:00 GMT',now),0);
 for(const bad of [null,'-1','Infinity','1.5','2026-10-26','x'.repeat(129),'Tue, 31 Feb 2026 00:00:00 GMT'])assert.equal(P.retryAfter(bad,now),undefined);
 assert.equal(P.validRetryAfter(604801),false);
});
test('Fetch 429 only reads response Retry-After and forwards no response body',async()=>{
 const{c,emitted}=observer('{"private":"discard"}',429,{headers:{'Retry-After':'120'}});
 await c.fetch('https://apid.iproyal.com/v1/orders/123/data-usage',{get headers(){throw Error('request headers accessed');}});await settle();
 assert.equal(emitted.length,1);assert.equal(emitted[0].type,'rateLimited');assert.equal(emitted[0].retryAfterSeconds,120);assert.equal(JSON.stringify(emitted).includes('private'),false);
});
test('XHR 429 reads only Retry-After and preserves missing header as rate limiting',()=>{
 for(const header of ['60',null]){const{c,emitted}=observer('{}');const xhr=new c.XMLHttpRequest();xhr.open('GET','https://apid.iproyal.com/v1/orders/123');xhr.send();
 xhr.status=429;xhr.responseURL='https://apid.iproyal.com/v1/orders/123';xhr.getResponseHeader=n=>{assert.equal(n,'Retry-After');return header;};xhr.emit('load');
 assert.equal(emitted[0].type,'rateLimited');assert.equal(emitted[0].retryAfterSeconds,header?60:undefined);}
});
test('worker forwards rate limit separately from a missing reading',async()=>{
 const h=background();await start(h);h.send({type:'observation',kind:'rateLimited',retryAfterSeconds:120});await flush();
 const r=h.messages.find(m=>m.type==='result').result;assert.equal(r.status,'rateLimited');assert.equal(r.retryAfterSeconds,120);assert.equal('gbUsed' in r,false);
});
test('same-document request started before binding can finish after binding',async()=>{
 const d=deferred(),{c,emitted,bind}=observer('',200,{bound:false,fetchPromise:d.promise});
 const pending=c.fetch('https://apid.iproyal.com/v1/orders/123/data-usage');bind();d.resolve(new Response('{"remaining":{"gb_limit":100,"gb_used":1,"gb_balance":99}}'));await pending;await settle();assert.equal(emitted.length,1);
});
test('a response before binding is buffered as bounded whitelist fields',async()=>{
 const{c,emitted,bind}=observer('{"remaining":{"gb_limit":100,"gb_used":1,"gb_balance":99},"discard":"private"}',200,{bound:false});
 for(let i=0;i<10;i++)await c.fetch('https://apid.iproyal.com/v1/orders/123/data-usage');await settle();assert.equal(emitted.length,0);bind();assert.equal(emitted.length,3);assert.equal(JSON.stringify(emitted).includes('private'),false);
});
test('concurrent startup and alarm events open only one native port and polling timer',async()=>{
 const d=deferred(),h=background({storageGate:d.promise});h.chrome.runtime.onStartup.emit();h.chrome.alarms.onAlarm.emit({name:'reconnect'});d.resolve();await flush();assert.equal(h.nativeCalls(),1);assert.equal(h.intervals.size,1);
});
test('disabling during a pending connect never reopens the native host',async()=>{
 const d=deferred(),h=background({storageGate:d.promise});h.send({type:'setEnabled',enabled:false},{url:h.chrome.runtime.getURL('popup.html')});await flush();d.resolve();await flush();assert.equal(h.nativeCalls(),0);assert.equal(h.local.enabled,false);assert.equal(h.intervals.size,0);
});
test('an old port disconnect cannot clear the newly enabled connection',async()=>{
 const h=background();await flush();h.send({type:'setEnabled',enabled:false},{url:h.chrome.runtime.getURL('popup.html')});await flush();h.send({type:'setEnabled',enabled:true},{url:h.chrome.runtime.getURL('popup.html')});await flush();
 assert.equal(h.nativeCalls(),2);h.port.onDisconnect.emit();h.ports[1].onMessage.emit({version:1,type:'request',request:h.request});await flush();assert.equal(h.created.length,1);assert.equal(h.intervals.size,1);
});

test('a superseded toggle cannot persist over a newer choice while its tab is closing',async()=>{
 const d=deferred(),h=background({removeGate:d.promise});await start(h);
 h.send({type:'setEnabled',enabled:true},{url:h.chrome.runtime.getURL('popup.html')});
 h.send({type:'setEnabled',enabled:false},{url:h.chrome.runtime.getURL('popup.html')});
 await flush();d.resolve();await flush();assert.equal(h.local.enabled,false);assert.equal(h.intervals.size,0);assert.equal(h.nativeCalls(),1);
});

test('reconnect alarms cannot bypass an explicit disable while owned-tab cleanup is pending',async()=>{
 const d=deferred(),h=background({removeGate:d.promise});await start(h);
 h.send({type:'setEnabled',enabled:false},{url:h.chrome.runtime.getURL('popup.html')});
 await flush();assert.equal(h.local.enabled,true); // The old persisted value is intentionally still visible.
 h.chrome.alarms.onAlarm.emit({name:'reconnect'});h.chrome.runtime.onStartup.emit();await flush();
 assert.equal(h.nativeCalls(),1);assert.equal(h.intervals.size,0);
 d.resolve();await flush();assert.equal(h.local.enabled,false);
 h.chrome.alarms.onAlarm.emit({name:'reconnect'});await flush();assert.equal(h.nativeCalls(),1);
});
