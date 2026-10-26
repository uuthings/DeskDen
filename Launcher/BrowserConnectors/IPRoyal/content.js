/* ISOLATED world: forward a field whitelist from this main-frame document only. */
(() => {
  'use strict';
  if (window !== window.top || location.origin !== 'https://dashboard.iproyal.com') return;
  const P = globalThis.FangcunIPRoyalProtocol, generation = crypto.randomUUID();
  let enabled = null;
  const queued = [];
  const bind = () => window.postMessage({channel:'fangcun-iproyal-quota',version:1,type:'bind',generation},location.origin);
  bind();
  const forward = safe => chrome.runtime.sendMessage(safe).catch(() => {});
  const hello = async attempt => {
    try {
      const reply = await chrome.runtime.sendMessage({type:'document',generation,orderID:P.pageOrder(location.href)});
      if (reply?.accepted === true) { enabled=true; bind(); queued.forEach(forward); queued.length=0; return; }
    } catch {}
    // A newly-created tab can reach document_start before tabs.create resolves.
    if (attempt < 4) { setTimeout(() => hello(attempt+1),100); return; }
    enabled=false; queued.length=0;
  };
  hello(0);
  window.addEventListener('message', event => {
    if (enabled === false || event.source !== window || event.origin !== location.origin) return;
    const v = event.data;
    if (!P.observation(v) || v.generation !== generation || v.orderID !== P.pageOrder(location.href)) return;
    const safe = {type:'observation',generation,orderID:v.orderID,kind:v.type};
    if (v.type === 'quota') safe.remaining = {gb_limit:v.remaining.gb_limit,gb_used:v.remaining.gb_used,gb_balance:v.remaining.gb_balance};
    if (v.type === 'reset') safe.resetDateText = v.resetDateText;
    if (v.type === 'rateLimited' && v.retryAfterSeconds !== undefined) safe.retryAfterSeconds = v.retryAfterSeconds;
    if (enabled) forward(safe); else if (queued.length < 3) queued.push(safe);
  });
})();
