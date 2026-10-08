-- Festa da Virada 2026 - cotas, pagamentos fracionados, ingressos e check-in.
-- Execute depois da migração 008.

begin;

alter table public.events
  add column if not exists full_seat_limit smallint not null default 350,
  add column if not exists half_seat_limit smallint not null default 50,
  add column if not exists deposit_percent numeric(5,2) not null default 30,
  add column if not exists balance_due_date date,
  add column if not exists cash_hold_hours smallint not null default 48;

update public.events
set full_seat_limit = 350,
    half_seat_limit = 50,
    deposit_percent = 30,
    balance_due_date = date '2026-12-10',
    cash_hold_hours = 48,
    updated_at = now()
where slug = 'festa-da-virada-2026';

alter table public.reservations drop constraint if exists reservations_status_check;
alter table public.reservations
  add constraint reservations_status_check check (status in (
    'held', 'pending_review', 'awaiting_cash', 'partially_paid',
    'confirmed', 'cancelled', 'expired', 'rejected'
  ));

alter table public.reservations
  add column if not exists payment_plan text check (payment_plan in ('full', 'deposit')),
  add column if not exists payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid', 'pending_review', 'awaiting_cash', 'partial', 'paid', 'overdue', 'rejected')),
  add column if not exists paid_amount numeric(10,2) not null default 0 check (paid_amount >= 0),
  add column if not exists balance_due_date date,
  add column if not exists cash_expires_at timestamptz,
  add column if not exists refund_due numeric(10,2) not null default 0 check (refund_due >= 0);

alter table public.reservation_seats
  add column if not exists item_status text not null default 'active'
    check (item_status in ('active', 'cancelled')),
  add column if not exists ticket_token uuid not null default gen_random_uuid(),
  add column if not exists ticket_status text not null default 'active'
    check (ticket_status in ('active', 'cancelled', 'checked_in')),
  add column if not exists checked_in_at timestamptz,
  add column if not exists checked_in_by uuid references auth.users(id) on delete set null,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
  add column if not exists cancellation_notes text;

create unique index if not exists reservation_seats_ticket_token_idx
  on public.reservation_seats(ticket_token);

create table if not exists public.reservation_guests (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  participant_name text not null,
  birth_date date not null,
  age_on_event smallint not null check (age_on_event between 0 and 5),
  price_category text not null default 'free' check (price_category = 'free'),
  price numeric(10,2) not null default 0 check (price = 0),
  item_status text not null default 'active' check (item_status in ('active', 'cancelled')),
  ticket_token uuid not null default gen_random_uuid() unique,
  ticket_status text not null default 'active' check (ticket_status in ('active', 'cancelled', 'checked_in')),
  checked_in_at timestamptz,
  checked_in_by uuid references auth.users(id) on delete set null,
  cancelled_at timestamptz,
  cancelled_by uuid references auth.users(id) on delete set null,
  cancellation_notes text,
  created_at timestamptz not null default now()
);

create table if not exists public.reservation_payments (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  payment_kind text not null check (payment_kind in ('full', 'deposit', 'balance')),
  payment_method text not null check (payment_method in ('pix', 'cash')),
  amount_due numeric(10,2) not null check (amount_due > 0),
  amount_received numeric(10,2) check (amount_received >= 0),
  status text not null default 'pending_review' check (status in ('pending_review', 'approved', 'rejected', 'expired')),
  proof_id uuid references public.payment_proofs(id) on delete set null,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_notes text
);

create index if not exists reservation_payments_reservation_idx
  on public.reservation_payments(reservation_id, submitted_at desc);
create unique index if not exists reservation_payments_one_pending_idx
  on public.reservation_payments(reservation_id) where status = 'pending_review';

drop index if exists public.payment_proofs_reservation_unique_idx;

alter table public.reservation_admin_actions drop constraint if exists reservation_admin_actions_action_check;
alter table public.reservation_admin_actions
  add constraint reservation_admin_actions_action_check check (action in (
    'confirm', 'reject', 'cancel', 'cancel_seat', 'cancel_guest', 'check_in', 'note'
  ));

alter table public.reservation_guests enable row level security;
alter table public.reservation_payments enable row level security;
drop policy if exists "admins read reservation guests" on public.reservation_guests;
create policy "admins read reservation guests" on public.reservation_guests
  for select to authenticated using (public.is_admin());
drop policy if exists "admins read reservation payments" on public.reservation_payments;
create policy "admins read reservation payments" on public.reservation_payments
  for select to authenticated using (public.is_admin());
revoke all on public.reservation_guests, public.reservation_payments from anon;
grant select on public.reservation_guests, public.reservation_payments to authenticated;

create or replace function public.expire_stale_reservations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_count integer := 0;
begin
  -- Reservas que nunca tiveram pagamento.
  with expired as (
    update public.reservations
       set status = 'expired', payment_status = 'unpaid', updated_at = now()
     where status = 'held' and expires_at <= now()
     returning id
  )
  select count(*) into expired_count from expired;

  update public.seats s
     set status = 'available', updated_at = now()
    from public.reservation_seats rs
    join public.reservations r on r.id = rs.reservation_id
   where rs.seat_id = s.id and r.status = 'expired' and rs.item_status = 'active';

  update public.reservation_seats rs
     set ticket_status='cancelled', item_status='cancelled', cancelled_at=coalesce(rs.cancelled_at,now())
    from public.reservations r
   where r.id=rs.reservation_id and r.status='expired' and rs.item_status='active';
  update public.reservation_guests rg
     set ticket_status='cancelled', item_status='cancelled', cancelled_at=coalesce(rg.cancelled_at,now())
    from public.reservations r
   where r.id=rg.reservation_id and r.status='expired' and rg.item_status='active';

  -- Dinheiro não confirmado em 48 horas. Se já há entrada aprovada, volta a parcial.
  update public.reservation_payments p
     set status = 'expired', reviewed_at = now(), review_notes = 'Prazo de 48 horas expirado.'
    from public.reservations r
   where p.reservation_id = r.id and p.status = 'pending_review'
     and p.payment_method = 'cash' and r.cash_expires_at <= now();

  update public.reservations
     set status = 'partially_paid', payment_status = 'partial', cash_expires_at = null, updated_at = now()
   where status = 'awaiting_cash' and cash_expires_at <= now() and paid_amount > 0;

  with expired_cash as (
    update public.reservations
       set status = 'expired', payment_status = 'unpaid', cash_expires_at = null, updated_at = now()
     where status = 'awaiting_cash' and cash_expires_at <= now() and paid_amount = 0
     returning id
  )
  select expired_count + count(*) into expired_count from expired_cash;

  update public.seats s
     set status = 'available', updated_at = now()
    from public.reservation_seats rs
    join public.reservations r on r.id = rs.reservation_id
   where rs.seat_id = s.id and r.status = 'expired' and rs.item_status = 'active';

  update public.reservation_seats rs
     set ticket_status='cancelled', item_status='cancelled', cancelled_at=coalesce(rs.cancelled_at,now())
    from public.reservations r
   where r.id=rs.reservation_id and r.status='expired' and rs.item_status='active';
  update public.reservation_guests rg
     set ticket_status='cancelled', item_status='cancelled', cancelled_at=coalesce(rg.cancelled_at,now())
    from public.reservations r
   where r.id=rg.reservation_id and r.status='expired' and rg.item_status='active';

  return expired_count;
end;
$$;

create or replace function public.can_upload_payment_proof(p_object_name text)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.reservations r
    where encode(r.access_token_hash,'hex')=split_part(p_object_name,'/',1)
      and split_part(p_object_name,'/',1)~'^[0-9a-f]{64}$'
      and ((r.status='held' and r.expires_at>now()) or r.status='partially_paid'));
$$;

drop function if exists public.create_hold(text,text,text,text,text,text,jsonb);
create or replace function public.create_hold(
  p_event_slug text,
  p_access_token text,
  p_buyer_name text,
  p_buyer_cpf text,
  p_buyer_whatsapp text,
  p_buyer_email text,
  p_participants jsonb,
  p_free_children jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  selected_event public.events%rowtype;
  new_reservation_id uuid;
  new_protocol text;
  participant jsonb;
  child jsonb;
  selected_seat public.seats%rowtype;
  birth_value date;
  age_value integer;
  category_value text;
  price_value numeric(10,2);
  total numeric(10,2) := 0;
  item_count integer;
  unique_count integer;
  new_full integer := 0;
  new_half integer := 0;
  used_full integer := 0;
  used_half integer := 0;
  expiry timestamptz;
begin
  perform public.expire_stale_reservations();
  if length(coalesce(p_access_token, '')) < 32 then raise exception 'invalid_access_token'; end if;
  if length(trim(coalesce(p_buyer_name, ''))) < 3 then raise exception 'invalid_buyer_name'; end if;
  if not public.is_valid_cpf(p_buyer_cpf) then raise exception 'invalid_buyer_cpf'; end if;
  if not public.is_valid_whatsapp(p_buyer_whatsapp) then raise exception 'invalid_buyer_whatsapp'; end if;
  if trim(coalesce(p_buyer_email, '')) !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}$' then raise exception 'invalid_buyer_email'; end if;
  if jsonb_typeof(p_participants) <> 'array' or jsonb_typeof(p_free_children) <> 'array' then raise exception 'invalid_participants'; end if;

  item_count := jsonb_array_length(p_participants);
  if item_count < 1 or item_count > 20 then raise exception 'invalid_seat_count'; end if;
  if jsonb_array_length(p_free_children) > 20 then raise exception 'invalid_free_count'; end if;
  select count(distinct item->>'seat_code') into unique_count from jsonb_array_elements(p_participants) item;
  if unique_count <> item_count then raise exception 'duplicate_seat'; end if;

  select * into selected_event from public.events
   where slug = p_event_slug and active = true for update;
  if not found then raise exception 'event_not_found'; end if;

  -- Calcula as categorias antes de criar a reserva para validar as cotas globais.
  for participant in select value from jsonb_array_elements(p_participants) loop
    begin birth_value := (participant->>'birth_date')::date;
    exception when others then raise exception 'invalid_birth_date'; end;
    if birth_value < date '1900-01-01' or birth_value > selected_event.event_date then raise exception 'invalid_birth_date'; end if;
    age_value := extract(year from age(selected_event.event_date, birth_value))::integer;
    if age_value <= selected_event.free_max_age then raise exception 'free_requires_no_seat';
    elsif age_value <= selected_event.half_max_age then new_half := new_half + 1;
    else new_full := new_full + 1;
    end if;
  end loop;

  select count(*) filter (where rs.price_category = 'full'), count(*) filter (where rs.price_category = 'half')
    into used_full, used_half
  from public.reservation_seats rs
  join public.reservations r on r.id = rs.reservation_id
  where r.event_id = selected_event.id and rs.item_status = 'active'
    and r.status not in ('cancelled', 'expired', 'rejected');

  if used_full + new_full > selected_event.full_seat_limit then raise exception 'full_quota_unavailable'; end if;
  if used_half + new_half > selected_event.half_seat_limit then raise exception 'half_quota_unavailable'; end if;

  expiry := now() + make_interval(mins => selected_event.hold_minutes);
  new_protocol := 'FV26-' || upper(encode(gen_random_bytes(4), 'hex'));
  insert into public.reservations (
    event_id, protocol, access_token_hash, buyer_name, buyer_cpf,
    buyer_whatsapp, buyer_email, expires_at, balance_due_date
  ) values (
    selected_event.id, new_protocol, digest(p_access_token, 'sha256'), trim(p_buyer_name),
    regexp_replace(p_buyer_cpf, '[^0-9]', '', 'g'), regexp_replace(p_buyer_whatsapp, '[^0-9]', '', 'g'),
    lower(trim(p_buyer_email)), expiry, selected_event.balance_due_date
  ) returning id into new_reservation_id;

  for participant in select value from jsonb_array_elements(p_participants) loop
    select * into selected_seat from public.seats
     where event_id = selected_event.id and code = participant->>'seat_code' for update;
    if not found or selected_seat.status <> 'available' then raise exception 'unavailable:%', participant->>'seat_code'; end if;
    if length(trim(coalesce(participant->>'name', ''))) < 2 then raise exception 'invalid_participant_name'; end if;
    if not public.is_valid_cpf(participant->>'cpf') then raise exception 'invalid_participant_cpf'; end if;
    if not public.is_valid_whatsapp(participant->>'whatsapp') then raise exception 'invalid_participant_whatsapp'; end if;
    birth_value := (participant->>'birth_date')::date;
    age_value := extract(year from age(selected_event.event_date, birth_value))::integer;
    if age_value <= selected_event.half_max_age then category_value := 'half'; price_value := selected_event.half_price;
    else category_value := 'full'; price_value := selected_event.full_price;
    end if;
    insert into public.reservation_seats (
      reservation_id, seat_id, participant_name, participant_cpf, participant_whatsapp,
      birth_date, age_on_event, price_category, price
    ) values (
      new_reservation_id, selected_seat.id, trim(participant->>'name'),
      regexp_replace(participant->>'cpf', '[^0-9]', '', 'g'),
      regexp_replace(participant->>'whatsapp', '[^0-9]', '', 'g'),
      birth_value, age_value, category_value, price_value
    );
    update public.seats set status = 'held', updated_at = now() where id = selected_seat.id;
    total := total + price_value;
  end loop;

  for child in select value from jsonb_array_elements(p_free_children) loop
    if length(trim(coalesce(child->>'name', ''))) < 2 then raise exception 'invalid_free_child_name'; end if;
    begin birth_value := (child->>'birth_date')::date;
    exception when others then raise exception 'invalid_birth_date'; end;
    if birth_value < date '1900-01-01' or birth_value > selected_event.event_date then raise exception 'invalid_birth_date'; end if;
    age_value := extract(year from age(selected_event.event_date, birth_value))::integer;
    if age_value > selected_event.free_max_age then raise exception 'free_child_age_invalid'; end if;
    insert into public.reservation_guests (reservation_id, participant_name, birth_date, age_on_event)
    values (new_reservation_id, trim(child->>'name'), birth_value, age_value);
  end loop;

  update public.reservations set total_amount = total where id = new_reservation_id;
  return jsonb_build_object(
    'reservation_id', new_reservation_id, 'protocol', new_protocol, 'status', 'held',
    'payment_status', 'unpaid', 'total_amount', total, 'paid_amount', 0,
    'amount_due', total, 'expires_at', expiry, 'balance_due_date', selected_event.balance_due_date
  );
end;
$$;

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
  select * into r from public.reservations where access_token_hash = digest(p_access_token, 'sha256') for update;
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
  select * into r from public.reservations where access_token_hash = digest(p_access_token, 'sha256') for update;
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
  select * into r from public.reservations where access_token_hash = digest(p_access_token, 'sha256');
  if not found then raise exception 'reservation_not_found'; end if;
  select jsonb_build_object(
    'reservation_id', r.id, 'protocol', r.protocol, 'status', r.status, 'payment_status', r.payment_status,
    'payment_plan', r.payment_plan, 'total_amount', r.total_amount, 'paid_amount', r.paid_amount,
    'balance_amount', greatest(r.total_amount-r.paid_amount,0), 'refund_due', r.refund_due,
    'expires_at', r.expires_at, 'cash_expires_at', r.cash_expires_at, 'balance_due_date', r.balance_due_date,
    'buyer_name', r.buyer_name,
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

create or replace function public.admin_review_reservation(p_reservation_id uuid, p_action text, p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.reservations%rowtype; p public.reservation_payments%rowtype; next_status text; new_paid numeric(10,2);
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if p_action not in ('confirm','reject','cancel') then raise exception 'invalid_action'; end if;
  if length(coalesce(p_notes,'')) > 500 then raise exception 'notes_too_long'; end if;
  select * into r from public.reservations where id=p_reservation_id for update;
  if not found then raise exception 'reservation_not_found'; end if;

  if p_action in ('confirm','reject') then
    select * into p from public.reservation_payments where reservation_id=r.id and status='pending_review'
      order by submitted_at desc limit 1 for update;
    if not found then raise exception 'pending_payment_not_found'; end if;
  end if;

  if p_action='confirm' then
    update public.reservation_payments set status='approved', amount_received=amount_due,
      reviewed_at=now(), reviewed_by=auth.uid(), review_notes=nullif(trim(p_notes),'') where id=p.id;
    update public.payment_proofs set reviewed_at=now(), reviewed_by=auth.uid(), review_notes=nullif(trim(p_notes),'') where id=p.proof_id;
    new_paid := least(r.total_amount, r.paid_amount + p.amount_due);
    next_status := case when new_paid >= r.total_amount then 'confirmed' else 'partially_paid' end;
    update public.reservations set paid_amount=new_paid,
      payment_status=case when new_paid>=total_amount then 'paid' else 'partial' end,
      status=next_status, confirmed_at=case when new_paid>=total_amount then now() else confirmed_at end,
      cash_expires_at=null, updated_at=now() where id=r.id;
    update public.seats s set status='confirmed',updated_at=now() from public.reservation_seats rs
      where rs.reservation_id=r.id and rs.seat_id=s.id and rs.item_status='active';
  elsif p_action='reject' then
    update public.reservation_payments set status='rejected',reviewed_at=now(),reviewed_by=auth.uid(),review_notes=nullif(trim(p_notes),'') where id=p.id;
    update public.payment_proofs set reviewed_at=now(),reviewed_by=auth.uid(),review_notes=nullif(trim(p_notes),'') where id=p.proof_id;
    next_status := case when r.paid_amount>0 then 'partially_paid' else 'rejected' end;
    update public.reservations set status=next_status,payment_status=case when r.paid_amount>0 then 'partial' else 'rejected' end,
      cash_expires_at=null,cancelled_at=case when r.paid_amount=0 then now() else cancelled_at end,updated_at=now() where id=r.id;
    if r.paid_amount=0 then
      update public.seats s set status='available',updated_at=now() from public.reservation_seats rs where rs.reservation_id=r.id and rs.seat_id=s.id and s.status<>'blocked';
    else
      update public.seats s set status='confirmed',updated_at=now() from public.reservation_seats rs where rs.reservation_id=r.id and rs.seat_id=s.id and rs.item_status='active';
    end if;
  else
    if r.status in ('cancelled','expired','rejected') then raise exception 'invalid_status_transition'; end if;
    next_status := 'cancelled';
    update public.reservations set status='cancelled',cancelled_at=now(),refund_due=paid_amount,updated_at=now() where id=r.id;
    update public.seats s set status='available',updated_at=now() from public.reservation_seats rs where rs.reservation_id=r.id and rs.seat_id=s.id and s.status<>'blocked';
    update public.reservation_seats set item_status='cancelled',ticket_status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_notes=nullif(trim(p_notes),'') where reservation_id=r.id and item_status='active';
    update public.reservation_guests set item_status='cancelled',ticket_status='cancelled',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_notes=nullif(trim(p_notes),'') where reservation_id=r.id and item_status='active';
  end if;

  insert into public.reservation_admin_actions(reservation_id,admin_user_id,action,previous_status,new_status,notes)
  values(r.id,auth.uid(),p_action,r.status,next_status,nullif(trim(p_notes),''));
  return jsonb_build_object('id',r.id,'protocol',r.protocol,'status',next_status);
end; $$;

create or replace function public.admin_cancel_reservation_seat(p_reservation_seat_id uuid, p_notes text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rs public.reservation_seats%rowtype; r public.reservations%rowtype; seat_code text; new_total numeric(10,2); active_count integer;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  select * into rs from public.reservation_seats where id=p_reservation_seat_id for update;
  if not found or rs.item_status<>'active' then raise exception 'active_seat_not_found'; end if;
  select * into r from public.reservations where id=rs.reservation_id for update;
  select code into seat_code from public.seats where id=rs.seat_id;
  update public.reservation_seats set item_status='cancelled',ticket_status='cancelled',cancelled_at=now(),
    cancelled_by=auth.uid(),cancellation_notes=nullif(trim(p_notes),'') where id=rs.id;
  update public.seats set status='available',updated_at=now() where id=rs.seat_id and status<>'blocked';
  select coalesce(sum(price),0),count(*) into new_total,active_count from public.reservation_seats where reservation_id=r.id and item_status='active';
  update public.reservations set total_amount=new_total,refund_due=greatest(paid_amount-new_total,0),
    status=case when active_count=0 then 'cancelled' else status end,
    cancelled_at=case when active_count=0 then now() else cancelled_at end,updated_at=now() where id=r.id;
  if active_count=0 then update public.reservation_guests set item_status='cancelled',ticket_status='cancelled',cancelled_at=now(),cancelled_by=auth.uid() where reservation_id=r.id and item_status='active'; end if;
  insert into public.reservation_admin_actions(reservation_id,admin_user_id,action,previous_status,new_status,notes)
  values(r.id,auth.uid(),'cancel_seat',r.status,case when active_count=0 then 'cancelled' else r.status end,
    concat('Cadeira ',seat_code,case when nullif(trim(p_notes),'') is null then '' else ': '||trim(p_notes) end));
  return jsonb_build_object('protocol',r.protocol,'seat_code',seat_code,'total_amount',new_total,
    'refund_due',greatest(r.paid_amount-new_total,0),'status',case when active_count=0 then 'cancelled' else r.status end);
end; $$;

create or replace function public.admin_add_reservation_note(p_reservation_id uuid, p_notes text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare r public.reservations%rowtype;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if length(trim(coalesce(p_notes,'')))<2 or length(p_notes)>500 then raise exception 'invalid_notes'; end if;
  select * into r from public.reservations where id=p_reservation_id;
  if not found then raise exception 'reservation_not_found'; end if;
  insert into public.reservation_admin_actions(reservation_id,admin_user_id,action,previous_status,new_status,notes)
  values(r.id,auth.uid(),'note',r.status,r.status,trim(p_notes));
  return jsonb_build_object('saved',true);
end; $$;

create or replace function public.admin_export_participants(p_event_slug text)
returns jsonb language sql stable security definer set search_path=public as $$
  select case when public.is_admin() then coalesce(jsonb_agg(row_data order by seat_code nulls last, participant_name),'[]'::jsonb)
    else (select jsonb_agg(x) from (select jsonb_build_object('error','admin_required') x) q) end
  from (
    select jsonb_build_object('protocol',r.protocol,'responsible',r.buyer_name,'whatsapp',r.buyer_whatsapp,
      'participant_name',rs.participant_name,'category',rs.price_category,'seat_code',s.code,
      'item_status',rs.item_status,'reservation_status',r.status,'payment_status',r.payment_status,
      'total_amount',r.total_amount,'paid_amount',r.paid_amount,'balance',greatest(r.total_amount-r.paid_amount,0)) row_data,
      s.code seat_code,rs.participant_name
    from public.reservations r join public.events e on e.id=r.event_id
    join public.reservation_seats rs on rs.reservation_id=r.id join public.seats s on s.id=rs.seat_id where e.slug=p_event_slug
    union all
    select jsonb_build_object('protocol',r.protocol,'responsible',r.buyer_name,'whatsapp',r.buyer_whatsapp,
      'participant_name',rg.participant_name,'category','free','seat_code',null,'item_status',rg.item_status,
      'reservation_status',r.status,'payment_status',r.payment_status,'total_amount',r.total_amount,
      'paid_amount',r.paid_amount,'balance',greatest(r.total_amount-r.paid_amount,0)),null,rg.participant_name
    from public.reservations r join public.events e on e.id=r.event_id
    join public.reservation_guests rg on rg.reservation_id=r.id where e.slug=p_event_slug
  ) data;
$$;

create or replace function public.admin_dashboard(p_event_slug text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare eid uuid; result jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  perform public.expire_stale_reservations();
  select id into eid from public.events where slug=p_event_slug;
  if not found then raise exception 'event_not_found'; end if;
  select jsonb_build_object(
    'total_seats',(select count(*) from public.seats where event_id=eid),
    'available_seats',(select count(*) from public.seats where event_id=eid and status='available'),
    'pending_seats',(select count(*) from public.seats where event_id=eid and status in ('held','pending_review')),
    'confirmed_seats',(select count(*) from public.seats where event_id=eid and status='confirmed'),
    'pending_reservations',(select count(*) from public.reservations where event_id=eid and status in ('pending_review','awaiting_cash')),
    'confirmed_revenue',coalesce((select sum(paid_amount) from public.reservations where event_id=eid),0),
    'pending_revenue',coalesce((select sum(total_amount-paid_amount) from public.reservations where event_id=eid and status in ('pending_review','awaiting_cash','partially_paid')),0),
    'updated_at',now()) into result;
  return result;
end; $$;

create or replace function public.admin_list_reservations(p_event_slug text,p_status text default null,p_search text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb; q text:=lower(trim(coalesce(p_search,'')));
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if p_status is not null and p_status<>'all' and p_status not in ('held','pending_review','awaiting_cash','partially_paid','confirmed','cancelled','expired','rejected') then raise exception 'invalid_status'; end if;
  perform public.expire_stale_reservations();
  select coalesce(jsonb_agg(item order by created_at desc),'[]'::jsonb) into result from (
    select r.created_at,jsonb_build_object('id',r.id,'protocol',r.protocol,'buyer_name',r.buyer_name,
      'buyer_whatsapp',r.buyer_whatsapp,'buyer_email',r.buyer_email,'status',r.status,'payment_status',r.payment_status,
      'total_amount',r.total_amount,'paid_amount',r.paid_amount,'balance_amount',greatest(r.total_amount-r.paid_amount,0),
      'balance_overdue',(r.status='partially_paid' and r.balance_due_date is not null and current_date>r.balance_due_date),
      'created_at',r.created_at,'seat_codes',coalesce(jsonb_agg(s.code order by s.code) filter(where rs.item_status='active'),'[]'::jsonb)) item
    from public.reservations r join public.events e on e.id=r.event_id
    left join public.reservation_seats rs on rs.reservation_id=r.id left join public.seats s on s.id=rs.seat_id
    where e.slug=p_event_slug and (p_status is null or p_status='all' or r.status=p_status)
      and (q='' or lower(r.protocol) like '%'||q||'%' or lower(r.buyer_name) like '%'||q||'%'
        or r.buyer_whatsapp like '%'||regexp_replace(q,'[^0-9]','','g')||'%'
        or exists(select 1 from public.reservation_seats x join public.seats y on y.id=x.seat_id where x.reservation_id=r.id and lower(y.code) like '%'||q||'%'))
    group by r.id order by r.created_at desc limit 300) rows;
  return result;
end; $$;

create or replace function public.admin_get_reservation(p_reservation_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  select jsonb_build_object('id',r.id,'protocol',r.protocol,'buyer_name',r.buyer_name,'buyer_cpf',r.buyer_cpf,
    'buyer_whatsapp',r.buyer_whatsapp,'buyer_email',r.buyer_email,'status',r.status,'payment_status',r.payment_status,
    'payment_plan',r.payment_plan,'total_amount',r.total_amount,'paid_amount',r.paid_amount,
    'balance_amount',greatest(r.total_amount-r.paid_amount,0),'refund_due',r.refund_due,'created_at',r.created_at,
    'participants',coalesce((select jsonb_agg(jsonb_build_object('id',rs.id,'seat_code',s.code,'name',rs.participant_name,
      'cpf',rs.participant_cpf,'whatsapp',rs.participant_whatsapp,'birth_date',rs.birth_date,'age',rs.age_on_event,
      'category',rs.price_category,'price',rs.price,'item_status',rs.item_status,'ticket_status',rs.ticket_status) order by s.code)
      from public.reservation_seats rs join public.seats s on s.id=rs.seat_id where rs.reservation_id=r.id),'[]'::jsonb),
    'free_children',coalesce((select jsonb_agg(jsonb_build_object('id',rg.id,'name',rg.participant_name,'birth_date',rg.birth_date,
      'age',rg.age_on_event,'category','free','price',0,'item_status',rg.item_status,'ticket_status',rg.ticket_status))
      from public.reservation_guests rg where rg.reservation_id=r.id),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'kind',p.payment_kind,'method',p.payment_method,
      'amount_due',p.amount_due,'amount_received',p.amount_received,'status',p.status,'submitted_at',p.submitted_at,
      'review_notes',p.review_notes,'proof',case when pp.id is null then null else jsonb_build_object('storage_path',pp.storage_path,
      'original_filename',pp.original_filename,'uploaded_at',pp.uploaded_at) end) order by p.submitted_at desc)
      from public.reservation_payments p left join public.payment_proofs pp on pp.id=p.proof_id where p.reservation_id=r.id),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(jsonb_build_object('action',a.action,'notes',a.notes,'created_at',a.created_at,'admin_name',u.display_name) order by a.created_at desc)
      from public.reservation_admin_actions a left join public.admin_users u on u.user_id=a.admin_user_id where a.reservation_id=r.id),'[]'::jsonb))
    into result from public.reservations r where r.id=p_reservation_id;
  if result is null then raise exception 'reservation_not_found'; end if;
  return result;
end; $$;

create or replace function public.admin_validate_ticket(p_ticket_token uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  select jsonb_build_object('ticket_type','seat','participant_name',rs.participant_name,'seat_code',s.code,
    'category',rs.price_category,'ticket_status',rs.ticket_status,'payment_status',r.payment_status,
    'protocol',r.protocol,'allowed',r.payment_status='paid' and rs.ticket_status='active') into result
  from public.reservation_seats rs join public.reservations r on r.id=rs.reservation_id join public.seats s on s.id=rs.seat_id
  where rs.ticket_token=p_ticket_token;
  if result is null then
    select jsonb_build_object('ticket_type','free','participant_name',rg.participant_name,'seat_code',null,
      'category','free','ticket_status',rg.ticket_status,'payment_status',r.payment_status,
      'protocol',r.protocol,'allowed',r.payment_status='paid' and rg.ticket_status='active') into result
    from public.reservation_guests rg join public.reservations r on r.id=rg.reservation_id where rg.ticket_token=p_ticket_token;
  end if;
  if result is null then raise exception 'ticket_not_found'; end if;
  return result;
end; $$;

create or replace function public.admin_checkin_ticket(p_ticket_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare validation jsonb; reservation_id_value uuid;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  validation := public.admin_validate_ticket(p_ticket_token);
  if not coalesce((validation->>'allowed')::boolean,false) then raise exception 'ticket_not_allowed'; end if;
  update public.reservation_seats set ticket_status='checked_in',checked_in_at=now(),checked_in_by=auth.uid()
    where ticket_token=p_ticket_token and ticket_status='active' returning reservation_id into reservation_id_value;
  if reservation_id_value is null then
    update public.reservation_guests set ticket_status='checked_in',checked_in_at=now(),checked_in_by=auth.uid()
      where ticket_token=p_ticket_token and ticket_status='active' returning reservation_id into reservation_id_value;
  end if;
  insert into public.reservation_admin_actions(reservation_id,admin_user_id,action,previous_status,new_status,notes)
  values(reservation_id_value,auth.uid(),'check_in','valid','checked_in',validation->>'participant_name');
  return validation || jsonb_build_object('ticket_status','checked_in','allowed',false,'checked_in_at',now());
end; $$;

revoke all on function public.create_hold(text,text,text,text,text,text,jsonb,jsonb) from public;
grant execute on function public.create_hold(text,text,text,text,text,text,jsonb,jsonb) to anon,authenticated;
revoke all on function public.start_payment(text,text,text) from public;
grant execute on function public.start_payment(text,text,text) to anon,authenticated;
revoke all on function public.get_reservation(text) from public;
grant execute on function public.get_reservation(text) to anon,authenticated;
revoke all on function public.record_payment_proof(text,text,text) from public;
grant execute on function public.record_payment_proof(text,text,text) to anon,authenticated;
revoke all on function public.admin_cancel_reservation_seat(uuid,text) from public;
revoke all on function public.admin_export_participants(text) from public;
revoke all on function public.admin_validate_ticket(uuid) from public;
revoke all on function public.admin_checkin_ticket(uuid) from public;
grant execute on function public.admin_cancel_reservation_seat(uuid,text) to authenticated;
grant execute on function public.admin_add_reservation_note(uuid,text) to authenticated;
grant execute on function public.admin_export_participants(text) to authenticated;
grant execute on function public.admin_validate_ticket(uuid) to authenticated;
grant execute on function public.admin_checkin_ticket(uuid) to authenticated;
grant execute on function public.admin_dashboard(text) to authenticated;
grant execute on function public.admin_list_reservations(text,text,text) to authenticated;
grant execute on function public.admin_get_reservation(uuid) to authenticated;

commit;

select
  (select full_seat_limit from public.events where slug='festa-da-virada-2026') as inteiras,
  (select half_seat_limit from public.events where slug='festa-da-virada-2026') as meias,
  to_regprocedure('public.start_payment(text,text,text)') is not null as pagamentos_configurados,
  to_regprocedure('public.admin_checkin_ticket(uuid)') is not null as checkin_configurado;
