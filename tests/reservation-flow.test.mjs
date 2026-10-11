import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import { webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/migrations/011_reservation_recovery.sql', import.meta.url), 'utf8');

function harness(saved = null) {
  const nodes = new Map();
  const element = () => ({ hidden:false, value:'', disabled:false, dataset:{}, events:{}, textContent:'', innerHTML:'', addEventListener(type, fn) { this.events[type] = fn; }, classList:{ toggle() {} }, closest() { return this; } });
  const get = id => { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); };
  get('registration').hidden = true;
  const radioPlan = Object.assign(element(), { value:'full' });
  const radioMethod = Object.assign(element(), { value:'pix' });
  const storage = new Map(saved ? [['fv26_reservation_access', JSON.stringify(saved)]] : []);
  const requests = [];
  const document = { getElementById:get, querySelectorAll:()=>[], querySelector(selector) { if (selector.includes('payment-plan')) return radioPlan; if (selector.includes('payment-method')) return radioMethod; return get(selector); } };
  const context = vm.createContext({ document, window:{scrollTo(){}}, localStorage:{ getItem:key=>storage.get(key)??null, setItem:(key,value)=>storage.set(key,value), removeItem:key=>storage.delete(key) }, console:{error(){}}, crypto:webcrypto, setInterval:()=>1, clearInterval(){}, TextEncoder, buildPixPayload:(_,amount)=>`PIX:${amount}`, qrcode:()=>({ addData(){}, make(){}, createSvgTag:()=>'<svg/>' }) });
  const script=app.replace(/^import .*;\n/gm,'').replace('void init();','').replace(/^export .*;\n?/gm,'');
  vm.runInContext(script+`\nrenderMap = () => {}; renderSelection = () => {}; loadSeatStatuses = async () => {}; supabaseRequest = async (path, options) => { requests.push({path, body:JSON.parse(options.body)}); return response; }; this.api = { init, beginNewReservation, showHome, restoreReservation, consultReservation, openReservation, renderConclusion, startPayment, state };`, Object.assign(context, { requests, response:null }));
  return { ...context.api, nodes, get, storage, requests, context };
}
const reservation = (status, paid, paymentStatus= status==='partially_paid'?'partial':status) => ({ protocol:'FV26-ABC12345', status, payment_status:paymentStatus, total_amount:1000, paid_amount:paid, seats:[{code:'S01-01', item_status:'active', name:'Visitante', price:1000, category:'full'}], free_children:[] });

test('homepage with saved access never restores or redirects automatically', async () => {
  const h=harness({accessToken:'old-token'});
  await h.init();
  assert.equal(h.get('landing').hidden,false);
  assert.equal(h.get('registration').hidden,true);
  assert.equal(h.requests.length,0);
  assert.equal(h.get('resume-reservation-button').hidden,false);
});
test('new reservation resets previous people and payment without deleting their access', () => {
  const h=harness({accessToken:'old-token'});
  h.state.reservation=reservation('confirmed',1000,'paid');
  h.state.selectedSeats.add('S01-01'); h.state.participants['S01-01']={name:'Old'};
  h.state.proofFile={name:'old.pdf'}; h.state.paymentStarted=true;
  h.beginNewReservation();
  assert.equal(h.state.reservation,null); assert.equal(h.state.selectedSeats.size,0);
  assert.equal(Object.keys(h.state.participants).length,0); assert.equal(h.state.proofFile,null);
  assert.equal(h.state.paymentStarted,false); assert.equal(h.state.step,1);
  assert.equal(JSON.parse(h.storage.get('fv26_reservation_access')).accessToken,'old-token');
});
test('confirmed 30% shows 70% balance and only generates the server-calculated Pix', async () => {
  const h=harness(); h.openReservation(reservation('partially_paid',300),'token');
  assert.equal(h.get('pay-balance-button').hidden,false);
  assert.match(h.get('conclusion-paid').textContent,/300/); assert.match(h.get('conclusion-balance').textContent,/700/);
  h.context.response={status:'partially_paid',amount_due:700};
  await h.startPayment();
  assert.equal(h.requests[0].path,'rpc/start_payment'); assert.equal(h.state.paymentDue,700);
  assert.equal(h.get('pix-code').value,'PIX:700');
});
test('pending balance proof and paid booking never offer another balance payment', () => {
  for(const [status,paid,paymentStatus] of [['pending_review',300,'pending_review'],['confirmed',1000,'paid'],['awaiting_cash',300,'awaiting_cash']]) {
    const h=harness(); h.openReservation(reservation(status,paid,paymentStatus),'token');
    assert.equal(h.state.step,5); assert.equal(h.get('pay-balance-button').hidden,true);
  }
});
test('lookup validates CPF and protocol then uses server recovery without storing CPF', async () => {
  const h=harness(); h.get('lookup-protocol').value='fv26-abc12345'; h.get('lookup-cpf').value='529.982.247-25';
  h.context.response=reservation('confirmed',1000,'paid');
  await h.consultReservation({preventDefault(){}});
  assert.equal(h.requests[0].body.p_protocol,'FV26-ABC12345');
  assert.equal(h.requests[0].body.p_buyer_cpf,'52998224725');
  assert.match(h.requests[0].body.p_new_access_token,/^[a-f0-9]{64}$/);
  assert.equal(h.get('lookup-cpf').value,'');
  assert.equal(h.storage.get('fv26_reservation_access').includes('52998224725'),false);
});
test('incorrect lookup leaves the home available and does not save an access token', async () => {
  const h=harness(); h.get('lookup-protocol').value='FV26-ABC12345'; h.get('lookup-cpf').value='52998224725';
  await h.consultReservation({preventDefault(){}});
  assert.equal(h.get('lookup-error').hidden,false); assert.equal(h.get('registration').hidden,true);
  assert.equal(h.storage.size,0);
});
test('recovery preserves original tokens, secures session tables and reuses the proof folder', () => {
  assert.equal((migration.match(/access_token_hash = public.reservation_access_hash\(p_access_token\)/g)??[]).length,3);
  assert.doesNotMatch(migration,/update public.reservations set access_token_hash/);
  assert.match(migration,/revoke all on function public.reservation_access_hash\(text\) from public, anon, authenticated/);
  assert.match(migration,/attempts >= 20 then return null/);
  assert.match(migration,/'proof_folder', encode\(r.access_token_hash, 'hex'\)/);
  assert.match(app,/state.reservation.proof_folder \?\? await sha256Hex/);
});
