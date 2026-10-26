/* MAIN world: observe only the two quota-related GET responses already made by this page. */
(() => {
  'use strict';
  if (window !== window.top || location.origin !== 'https://dashboard.iproyal.com') return;
  const P = globalThis.FangcunIPRoyalProtocol;
  const send = window.postMessage.bind(window), originalFetch = window.fetch;
  let generation = null;
  const pending = [];
  const deliver = (route,captured,payload) => {
    if ((captured && captured !== generation) || P.pageOrder(location.href) !== route.orderID) return;
    if (!generation) { if (pending.length < 3) pending.push({route,payload}); return; }
    send({channel:'fangcun-iproyal-quota',version:1,generation,orderID:route.orderID,...payload},location.origin);
  };
  window.addEventListener('message', event => {
    const v = event.data;
    if (event.source !== window || event.origin !== location.origin ||
        !P.keys(v, ['channel','version','type','generation']) || v.channel !== 'fangcun-iproyal-quota' ||
        v.version !== 1 || v.type !== 'bind' || !P.uuid(v.generation)) return;
    if (generation === null) {
      generation = v.generation;
      for (const item of pending.splice(0)) deliver(item.route,null,item.payload);
    }
  });
  const publish = (route, body, captured) => {
    const base = {type:route.type};
    if (route.type === 'quota') {
      const r = body && body.remaining;
      if (!r || !P.quota({gb_limit:r.gb_limit,gb_used:r.gb_used,gb_balance:r.gb_balance})) return;
      base.remaining = {gb_limit:r.gb_limit,gb_used:r.gb_used,gb_balance:r.gb_balance};
    } else {
      const d = body && body.bandwidth_limit_reset_at;
      if (!P.resetDate(d)) return;
      base.resetDateText = d;
    }
    deliver(route,captured,base);
  };
  const auth = (route, captured) => {
    deliver(route,captured,{type:'authentication'});
  };
  const rateLimited = (route, captured, header) => {
    const message = {type:'rateLimited'};
    const delay = P.retryAfter(header);
    if (delay !== undefined) message.retryAfterSeconds=delay;
    deliver(route,captured,message);
  };
  async function readBounded(response) {
    const clone = response.clone(), reader = clone.body?.getReader();
    if (!reader) return null;
    let size = 0; const chunks = [];
    try {
      while (true) { const {done,value} = await reader.read(); if (done) break;
        size += value.byteLength; if (size > 65536) { await reader.cancel(); return null; } chunks.push(value); }
      const bytes = new Uint8Array(size); let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk,offset); offset += chunk.byteLength; }
      return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
    } catch { return null; } finally { reader.releaseLock(); }
  }
  if (typeof originalFetch === 'function') window.fetch = function(...args) {
    const input = args[0], init = args[1];
    // URL and method are the only request properties inspected. Headers/body/credentials are never read.
    let route = null;
    try { route = P.apiRequest(typeof input === 'string' || input instanceof URL ? String(input) : input?.url,
      init?.method || (typeof input === 'object' ? input?.method : undefined)); } catch {}
    const captured = generation, result = Reflect.apply(originalFetch, this, args);
    if (route) result.then(async response => {
      if (response.status === 429 && !response.redirected) {
        const final = response.url ? P.apiRequest(response.url,'GET') : route;
        if (final?.orderID === route.orderID && final?.type === route.type) {
          let header; try { header=response.headers.get('Retry-After'); } catch {}
          rateLimited(route,captured,header);
        }
        return;
      }
      if (response.status === 401 || response.status === 403) { auth(route,captured); return; }
      const finalRoute = response.url ? P.apiRequest(response.url,'GET') : route;
      if (response.status === 200 && !response.redirected && finalRoute?.orderID === route.orderID && finalRoute?.type === route.type)
        publish(route, await readBounded(response), captured);
    }).catch(() => {});
    return result;
  };
  const opened = new WeakMap(), originalOpen = XMLHttpRequest.prototype.open, originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method,url,...rest) {
    opened.set(this,P.apiRequest(url,method)); return Reflect.apply(originalOpen,this,[method,url,...rest]);
  };
  XMLHttpRequest.prototype.send = function(...args) {
    const route = opened.get(this), captured = generation;
    if (route) this.addEventListener('load', () => {
      try {
        if (this.status === 429) {
          const final = P.apiRequest(this.responseURL,'GET');
          if (final?.orderID === route.orderID && final?.type === route.type) {
            let header; try { header=this.getResponseHeader('Retry-After'); } catch {}
            rateLimited(route,captured,header);
          }
          return;
        }
        if (this.status === 401 || this.status === 403) { auth(route,captured); return; }
        const finalRoute = P.apiRequest(this.responseURL,'GET');
        if (this.status !== 200 || finalRoute?.orderID !== route.orderID || finalRoute?.type !== route.type) return;
        if (this.responseType === 'json') {
          // The browser has already parsed this object. Read only bounded quota/date fields;
          // never enumerate, serialize or retain the surrounding response.
          publish(route,this.response,captured);
        } else if (this.responseType === '' || this.responseType === 'text') {
          const text = this.responseText; if (text.length <= 65536) publish(route,JSON.parse(text),captured);
        }
      } catch { /* A missing reading stays missing. */ }
    }, {once:true});
    return Reflect.apply(originalSend,this,args);
  };
})();
