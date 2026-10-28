/* Shared validation. All observations are untrusted page data, never authentication. */
(() => {
  'use strict';
  const MAX_MESSAGE = 16384;
  const orderID = v => typeof v === 'string' && /^[1-9][0-9]{0,19}$/.test(v);
  const uuid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
  const record = v => !!v && typeof v === 'object' && !Array.isArray(v);
  const keys = (v, allowed) => record(v) && Object.keys(v).every(k => allowed.includes(k));
  const finiteGB = n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 9e6;
  const quota = v => keys(v, ['gb_limit','gb_used','gb_balance']) && finiteGB(v.gb_limit) && v.gb_limit > 0 &&
    finiteGB(v.gb_used) && finiteGB(v.gb_balance) && v.gb_balance <= v.gb_limit + .002 &&
    Math.abs(Math.max(0, v.gb_limit - v.gb_used) - v.gb_balance) <= .002;
  const validRetryAfter = v => v === undefined || (typeof v === 'number' && Number.isFinite(v) && v >= 0 && v <= 604800);
  const retryAfter = (value, now = Date.now()/1000) => {
    if (typeof value !== 'string' || value.length > 128) return undefined;
    const text = value.trim();
    if (/^[0-9]{1,20}$/.test(text)) return Math.min(604800,Number(text));
    if (!/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT$/.test(text)) return undefined;
    const date = new Date(text);
    return Number.isFinite(date.getTime()) && date.toUTCString() === text
      ? Math.min(604800,Math.max(0,Math.ceil(date.getTime()/1000-now))) : undefined;
  };
  const resetDate = v => {
    if (v === null) return true;
    if (typeof v !== 'string' || !/^[2-9][0-9]{3}-[0-9]{2}-[0-9]{2}$/.test(v)) return false;
    const d = new Date(v + 'T00:00:00Z');
    return Number.isFinite(d.getTime()) && d.toISOString().slice(0,10) === v;
  };
  const pageOrder = value => {
    try { const u = new URL(value); const m = u.pathname.match(/^\/me\/orders\/([1-9][0-9]{0,19})\/?$/);
      return u.origin === 'https://dashboard.iproyal.com' && !u.username && !u.password && m ? m[1] : null;
    } catch { return null; }
  };
  const apiRequest = (value, method) => {
    try { if (String(method || 'GET').toUpperCase() !== 'GET') return null;
      const u = new URL(value); const m = u.pathname.match(/^\/v1\/orders\/([1-9][0-9]{0,19})(\/data-usage)?$/);
      if (u.origin !== 'https://apid.iproyal.com' || u.username || u.password || u.hash || !m) return null;
      const allowed = m[2] ? ['date_from','date_to','time_zone','measurement_unit','rounding_decimal','ips[]','hostnames[]'] : [];
      if ([...u.searchParams.keys()].some(k => !allowed.includes(k))) return null;
      return { orderID:m[1], type:m[2] ? 'quota' : 'reset' };
    } catch { return null; }
  };
  const request = (v, now = Date.now()/1000) => keys(v, ['version','requestID','sourceID','orderID','createdAt','expiresAt']) &&
    v.version === 1 && uuid(v.requestID) && uuid(v.sourceID) && orderID(v.orderID) &&
    Number.isFinite(v.createdAt) && Number.isFinite(v.expiresAt) && v.createdAt <= now+5 && v.expiresAt > now &&
    v.expiresAt > v.createdAt && v.expiresAt-v.createdAt <= 300;
  const observation = v => keys(v, ['channel','version','generation','type','orderID','remaining','resetDateText','retryAfterSeconds']) &&
    v.channel === 'deskden-iproyal-quota' && v.version === 1 && uuid(v.generation) && orderID(v.orderID) &&
    (validRetryAfter(v.retryAfterSeconds) && (v.type === 'rateLimited' || v.retryAfterSeconds === undefined)) &&
    ((v.type === 'quota' && quota(v.remaining) && v.resetDateText === undefined) ||
     (v.type === 'reset' && resetDate(v.resetDateText) && v.remaining === undefined) ||
     ((v.type === 'authentication' || v.type === 'rateLimited') && v.remaining === undefined && v.resetDateText === undefined));
  globalThis.DeskDenIPRoyalProtocol = Object.freeze({MAX_MESSAGE, orderID, uuid, keys, quota, validRetryAfter, retryAfter, resetDate, pageOrder, apiRequest, request, observation});
})();
