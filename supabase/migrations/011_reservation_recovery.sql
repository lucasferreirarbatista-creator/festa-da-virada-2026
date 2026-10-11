-- Keep existing reservation and ticket links valid when recovering on another device.
begin;
create table public.reservation_access_sessions (
  token_hash bytea primary key,
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '120 days'
);
create index reservation_access_sessions_reservation_idx on public.reservation_access_sessions(reservation_id);
alter table public.reservation_access_sessions enable row level security;
revoke all on public.reservation_access_sessions from public, anon, authenticated;

create table public.reservation_lookup_limits (
  reservation_id uuid primary key references public.reservations(id) on delete cascade,
  window_start timestamptz not null default now(),
  attempts integer not null default 0
);
alter table public.reservation_lookup_limits enable row level security;
revoke all on public.reservation_lookup_limits from public, anon, authenticated;

create function public.reservation_access_hash(p_token text)
returns bytea language sql stable security definer set search_path = public, extensions as $$
  select r.access_token_hash from public.reservations r
  where r.access_token_hash = digest(p_token, 'sha256')
  or exists (select 1 from public.reservation_access_sessions s
    where s.reservation_id = r.id and s.token_hash = digest(p_token, 'sha256') and s.expires_at > now())
  limit 1;
$$;
revoke all on function public.reservation_access_hash(text) from public, anon, authenticated;

create or replace function public.start_payment(
  p_access_token text,
  p_payment_plan text,
  p_payment_method text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r public.reservations%rowtype;
  e public.events%rowtype;
  due numeric(10,2);
  kind text;
  cash_deadline timestamptz;
begin
  perform public.expire_stale_reservations();
  if p_payment_plan not in ('full', 'deposit') then raise exception 'invalid_payment_plan'; end if;
  if p_payment_method not in ('pix', 'cash') then raise exception 'invalid_payment_method'; end if;
  select * into r from public.reservations where access_token_hash = public.reservation_access_hash(p_access_token) for update;
  if not found then raise exception 'reservation_not_found'; end if;
  if r.status not in ('held', 'partially_paid') then raise exception 'payment_not_available'; end if;
  if r.status = 'held' and r.expires_at <= now() then raise exception 'reservation_expired'; end if;
  select * into e from public.events where id = r.event_id;

  if r.paid_amount > 0 then
    due := greatest(r.total_amount - r.paid_amount, 0); kind := 'balance';
  elsif p_payment_plan = 'deposit' then
    due := round(r.total_amount * e.deposit_percent / 100, 2); kind := 'deposit';
  else
    due := r.total_amount; kind := 'full';
  end if;
  if due <= 0 then raise exception 'nothing_to_pay'; end if;

  update public.reservations set payment_plan = case when r.paid_amount > 0 then payment_plan else p_payment_plan end,
    updated_at = now() where id = r.id;

  if p_payment_method = 'cash' then
    cash_deadline := now() + make_interval(hours => e.cash_hold_hours);
    insert into public.reservation_payments (reservation_id, payment_kind, payment_method, amount_due)
    values (r.id, kind, 'cash', due);
    update public.reservations set status = 'awaiting_cash', payment_status = 'awaiting_cash',
      cash_expires_at = cash_deadline, updated_at = now() where id = r.id;
    update public.seats s set status = case when r.paid_amount > 0 then 'confirmed' else 'pending_review' end, updated_at = now()
      from public.reservation_seats rs where rs.reservation_id = r.id and rs.seat_id = s.id and rs.item_status = 'active';
  end if;

  return jsonb_build_object(
    'status', case when p_payment_method = 'cash' then 'awaiting_cash' else r.status end,
    'payment_status', case when p_payment_method = 'cash' then 'awaiting_cash' else r.payment_status end,
    'payment_plan', case when r.paid_amount > 0 then r.payment_plan else p_payment_plan end,
    'payment_method', p_payment_method, 'payment_kind', kind, 'amount_due', due,
    'cash_expires_at', cash_deadline, 'balance_due_date', e.balance_due_date
  );
end;
$$;

create or replace function public.record_payment_proof(
  p_access_token text,
  p_storage_path text,
  p_original_filename text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r public.reservations%rowtype;
  e public.events%rowtype;
  stored_mime text;
  stored_size bigint;
  proof_id_value uuid;
  due numeric(10,2);
  kind text;
begin
  perform public.expire_stale_reservations();
  select * into r from public.reservations where access_token_hash = public.reservation_access_hash(p_access_token) for update;
  if not found then raise exception 'reservation_not_found'; end if;
  if r.status not in ('held', 'partially_paid') then raise exception 'payment_not_available'; end if;
  if r.status = 'held' and r.expires_at <= now() then raise exception 'reservation_expired'; end if;
  if r.payment_plan is null then raise exception 'payment_plan_required'; end if;
  if exists (select 1 from public.reservation_payments where reservation_id = r.id and status = 'pending_review') then raise exception 'payment_already_pending'; end if;
  select * into e from public.events where id = r.event_id;
  if r.paid_amount > 0 then due := greatest(r.total_amount - r.paid_amount, 0); kind := 'balance';
  elsif r.payment_plan = 'deposit' then due := round(r.total_amount * e.deposit_percent / 100, 2); kind := 'deposit';
  else due := r.total_amount; kind := 'full'; end if;
  if split_part(p_storage_path, '/', 1) <> encode(r.access_token_hash, 'hex') then raise exception 'invalid_storage_path'; end if;

  select metadata->>'mimetype', nullif(metadata->>'size', '')::bigint into stored_mime, stored_size
  from storage.objects where bucket_id = 'payment-proofs' and name = p_storage_path;
  if not found then raise exception 'payment_file_not_found'; end if;
  if stored_mime not in ('image/jpeg', 'image/png', 'application/pdf') then raise exception 'invalid_file_type'; end if;
  if stored_size <= 0 or stored_size > 10485760 then raise exception 'invalid_file_size'; end if;

  insert into public.payment_proofs (reservation_id, storage_path, original_filename, mime_type, size_bytes)
  values (r.id, p_storage_path, trim(p_original_filename), stored_mime, stored_size) returning id into proof_id_value;
  insert into public.reservation_payments (reservation_id, payment_kind, payment_method, amount_due, proof_id)
  values (r.id, kind, 'pix', due, proof_id_value);
  update public.reservations set status = 'pending_review', payment_status = 'pending_review', updated_at = now() where id = r.id;
  update public.seats s set status = 'pending_review', updated_at = now()
    from public.reservation_seats rs where rs.reservation_id = r.id and rs.seat_id = s.id and rs.item_status = 'active' and r.paid_amount = 0;
  return jsonb_build_object('status','pending_review','payment_status','pending_review','protocol',r.protocol,
    'total_amount',r.total_amount,'paid_amount',r.paid_amount,'amount_due',due,'payment_kind',kind);
end;
$$;

create or replace function public.get_reservation(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare r public.reservations%rowtype; result jsonb;
begin
  perform public.expire_stale_reservations();
  select * into r from public.reservations where access_token_hash = public.reservation_access_hash(p_access_token);
  if not found then raise exception 'reservation_not_found'; end if;
  select jsonb_build_object(
    'reservation_id', r.id, 'protocol', r.protocol, 'status', r.status, 'payment_status', r.payment_status,
    'payment_plan', r.payment_plan, 'total_amount', r.total_amount, 'paid_amount', r.paid_amount,
    'balance_amount', greatest(r.total_amount-r.paid_amount,0), 'refund_due', r.refund_due,
    'expires_at', r.expires_at, 'cash_expires_at', r.cash_expires_at, 'balance_due_date', r.balance_due_date,
    'buyer_name', r.buyer_name, 'proof_folder', encode(r.access_token_hash, 'hex'),
    'seats', coalesce((select jsonb_agg(jsonb_build_object(
      'id',rs.id,'code',s.code,'name',rs.participant_name,'category',rs.price_category,'price',rs.price,
      'ticket_token',rs.ticket_token,'ticket_status',rs.ticket_status,'item_status',rs.item_status
    ) order by s.code) from public.reservation_seats rs join public.seats s on s.id=rs.seat_id where rs.reservation_id=r.id), '[]'::jsonb),
    'free_children', coalesce((select jsonb_agg(jsonb_build_object(
      'id',rg.id,'name',rg.participant_name,'birth_date',rg.birth_date,'age',rg.age_on_event,'category','free','price',0,'ticket_token',rg.ticket_token,
      'ticket_status',rg.ticket_status,'item_status',rg.item_status
    ) order by rg.participant_name) from public.reservation_guests rg where rg.reservation_id=r.id), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;


create function public.recover_reservation(p_protocol text, p_buyer_cpf text, p_new_access_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.reservations%rowtype; limit_row public.reservation_lookup_limits%rowtype;
begin
  if p_new_access_token is null or p_new_access_token !~ '^[0-9a-f]{64}$' then return null; end if;
  if p_protocol is null or upper(trim(p_protocol)) !~ '^FV26-[A-F0-9]{8}$' then return null; end if;
  perform public.expire_stale_reservations();
  select * into r from public.reservations where protocol = upper(trim(p_protocol)) for update;
  if not found then return null; end if;
  insert into public.reservation_lookup_limits(reservation_id) values(r.id) on conflict do nothing;
  select * into limit_row from public.reservation_lookup_limits where reservation_id = r.id for update;
  if limit_row.window_start <= now() - interval '15 minutes' then
    update public.reservation_lookup_limits set window_start = now(), attempts = 1 where reservation_id = r.id;
  elsif limit_row.attempts >= 20 then return null;
  else update public.reservation_lookup_limits set attempts = attempts + 1 where reservation_id = r.id;
  end if;
  -- Returning null (rather than raising) commits failed-attempt counters.
  if p_buyer_cpf is null or regexp_replace(p_buyer_cpf, '[^0-9]', '', 'g') <> r.buyer_cpf
    or r.status not in ('held', 'partially_paid', 'pending_review', 'awaiting_cash', 'confirmed') then return null; end if;
  if exists(select 1 from public.reservations where access_token_hash = digest(p_new_access_token, 'sha256')) then return null; end if;
  delete from public.reservation_access_sessions where reservation_id = r.id and expires_at <= now();
  insert into public.reservation_access_sessions(token_hash, reservation_id)
    values(digest(p_new_access_token, 'sha256'), r.id) on conflict do nothing;
  if not found then return null; end if;
  return public.get_reservation(p_new_access_token);
end;
$$;
revoke all on function public.recover_reservation(text,text,text) from public;
grant execute on function public.recover_reservation(text,text,text) to anon, authenticated;
commit;
