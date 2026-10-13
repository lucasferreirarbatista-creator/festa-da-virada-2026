-- Festa da Virada 2026 - pagamentos avulsos e consulta por protocolo ou CPF.

begin;

alter table public.reservation_payments
  drop constraint if exists reservation_payments_payment_kind_check;

alter table public.reservation_payments
  add constraint reservation_payments_payment_kind_check
  check (payment_kind in ('full', 'deposit', 'installment', 'balance'));

drop function if exists public.start_payment(text, text, text);

create function public.start_payment(
  p_access_token text,
  p_payment_plan text,
  p_payment_method text,
  p_payment_amount numeric default null
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
  balance numeric(10,2);
  kind text;
  cash_deadline timestamptz;
begin
  perform public.expire_stale_reservations();
  if p_payment_plan not in ('full', 'deposit') then raise exception 'invalid_payment_plan'; end if;
  if p_payment_method not in ('pix', 'cash') then raise exception 'invalid_payment_method'; end if;

  select * into r
  from public.reservations
  where access_token_hash = digest(p_access_token, 'sha256')
  for update;

  if not found then raise exception 'reservation_not_found'; end if;
  if r.status not in ('held', 'partially_paid') then raise exception 'payment_not_available'; end if;
  if r.status = 'held' and r.expires_at <= now() then raise exception 'reservation_expired'; end if;

  select * into e from public.events where id = r.event_id;
  balance := greatest(r.total_amount - r.paid_amount, 0);

  if r.paid_amount > 0 then
    due := round(coalesce(p_payment_amount, balance), 2);
    if due < 1 or due > balance then raise exception 'invalid_payment_amount'; end if;
    kind := case when due < balance then 'installment' else 'balance' end;
  elsif p_payment_plan = 'deposit' then
    due := round(r.total_amount * e.deposit_percent / 100, 2);
    kind := 'deposit';
  else
    due := r.total_amount;
    kind := 'full';
  end if;

  if due <= 0 then raise exception 'nothing_to_pay'; end if;

  update public.reservations
  set payment_plan = case when r.paid_amount > 0 then payment_plan else p_payment_plan end,
      updated_at = now()
  where id = r.id;

  if p_payment_method = 'cash' then
    cash_deadline := now() + make_interval(hours => e.cash_hold_hours);
    insert into public.reservation_payments (reservation_id, payment_kind, payment_method, amount_due)
    values (r.id, kind, 'cash', due);

    update public.reservations
    set status = 'awaiting_cash', payment_status = 'awaiting_cash',
        cash_expires_at = cash_deadline, updated_at = now()
    where id = r.id;

    update public.seats s
    set status = case when r.paid_amount > 0 then 'confirmed' else 'pending_review' end,
        updated_at = now()
    from public.reservation_seats rs
    where rs.reservation_id = r.id
      and rs.seat_id = s.id
      and rs.item_status = 'active';
  end if;

  return jsonb_build_object(
    'status', case when p_payment_method = 'cash' then 'awaiting_cash' else r.status end,
    'payment_status', case when p_payment_method = 'cash' then 'awaiting_cash' else r.payment_status end,
    'payment_plan', case when r.paid_amount > 0 then r.payment_plan else p_payment_plan end,
    'payment_method', p_payment_method,
    'payment_kind', kind,
    'amount_due', due,
    'cash_expires_at', cash_deadline,
    'balance_due_date', e.balance_due_date
  );
end;
$$;

drop function if exists public.record_payment_proof(text, text, text);

create function public.record_payment_proof(
  p_access_token text,
  p_storage_path text,
  p_original_filename text,
  p_payment_amount numeric default null
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
  balance numeric(10,2);
  kind text;
begin
  perform public.expire_stale_reservations();

  select * into r
  from public.reservations
  where access_token_hash = digest(p_access_token, 'sha256')
  for update;

  if not found then raise exception 'reservation_not_found'; end if;
  if r.status not in ('held', 'partially_paid') then raise exception 'payment_not_available'; end if;
  if r.status = 'held' and r.expires_at <= now() then raise exception 'reservation_expired'; end if;
  if r.payment_plan is null then raise exception 'payment_plan_required'; end if;
  if exists (
    select 1 from public.reservation_payments
    where reservation_id = r.id and status = 'pending_review'
  ) then raise exception 'payment_already_pending'; end if;

  select * into e from public.events where id = r.event_id;
  balance := greatest(r.total_amount - r.paid_amount, 0);

  if r.paid_amount > 0 then
    due := round(coalesce(p_payment_amount, balance), 2);
    if due < 1 or due > balance then raise exception 'invalid_payment_amount'; end if;
    kind := case when due < balance then 'installment' else 'balance' end;
  elsif r.payment_plan = 'deposit' then
    due := round(r.total_amount * e.deposit_percent / 100, 2);
    kind := 'deposit';
  else
    due := r.total_amount;
    kind := 'full';
  end if;

  if split_part(p_storage_path, '/', 1) <> encode(r.access_token_hash, 'hex') then
    raise exception 'invalid_storage_path';
  end if;

  select metadata->>'mimetype', nullif(metadata->>'size', '')::bigint
  into stored_mime, stored_size
  from storage.objects
  where bucket_id = 'payment-proofs' and name = p_storage_path;

  if not found then raise exception 'payment_file_not_found'; end if;
  if stored_mime not in ('image/jpeg', 'image/png', 'application/pdf') then raise exception 'invalid_file_type'; end if;
  if stored_size <= 0 or stored_size > 10485760 then raise exception 'invalid_file_size'; end if;

  insert into public.payment_proofs (
    reservation_id, storage_path, original_filename, mime_type, size_bytes
  ) values (
    r.id, p_storage_path, trim(p_original_filename), stored_mime, stored_size
  ) returning id into proof_id_value;

  insert into public.reservation_payments (
    reservation_id, payment_kind, payment_method, amount_due, proof_id
  ) values (
    r.id, kind, 'pix', due, proof_id_value
  );

  update public.reservations
  set status = 'pending_review', payment_status = 'pending_review', updated_at = now()
  where id = r.id;

  update public.seats s
  set status = 'pending_review', updated_at = now()
  from public.reservation_seats rs
  where rs.reservation_id = r.id
    and rs.seat_id = s.id
    and rs.item_status = 'active'
    and r.paid_amount = 0;

  return jsonb_build_object(
    'status', 'pending_review',
    'payment_status', 'pending_review',
    'protocol', r.protocol,
    'total_amount', r.total_amount,
    'paid_amount', r.paid_amount,
    'balance_amount', balance,
    'amount_due', due,
    'payment_kind', kind
  );
end;
$$;

create or replace function public.recover_reservation_access(
  p_protocol text default null,
  p_buyer_cpf text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  selected_reservation public.reservations%rowtype;
  clean_protocol text := upper(trim(coalesce(p_protocol, '')));
  clean_cpf text := regexp_replace(coalesce(p_buyer_cpf, ''), '[^0-9]', '', 'g');
  has_protocol boolean := clean_protocol ~ '^FV26-[0-9A-F]{8}$';
  has_cpf boolean := length(clean_cpf) > 0;
  active_matches integer;
  new_access_token text;
begin
  perform public.expire_stale_reservations();

  if not has_protocol and not has_cpf then
    raise exception 'invalid_recovery_credentials';
  end if;
  if has_cpf and not public.is_valid_cpf(clean_cpf) then
    raise exception 'invalid_recovery_credentials';
  end if;

  if has_protocol then
    select * into selected_reservation
    from public.reservations
    where upper(protocol) = clean_protocol
      and (not has_cpf or buyer_cpf = clean_cpf)
    for update;

    if not found then raise exception 'invalid_recovery_credentials'; end if;
    if selected_reservation.status in ('expired', 'cancelled', 'rejected') then
      raise exception 'reservation_not_active';
    end if;
  else
    select count(*) into active_matches
    from public.reservations
    where buyer_cpf = clean_cpf
      and status not in ('expired', 'cancelled', 'rejected');

    if active_matches > 1 then raise exception 'multiple_reservations_found'; end if;
    if active_matches = 0 then
      if exists (select 1 from public.reservations where buyer_cpf = clean_cpf) then
        raise exception 'reservation_not_active';
      end if;
      raise exception 'invalid_recovery_credentials';
    end if;

    select * into selected_reservation
    from public.reservations
    where buyer_cpf = clean_cpf
      and status not in ('expired', 'cancelled', 'rejected')
    for update;
  end if;

  new_access_token := encode(gen_random_bytes(32), 'hex');

  update public.reservations
  set access_token_hash = digest(new_access_token, 'sha256'), updated_at = now()
  where id = selected_reservation.id;

  return jsonb_build_object(
    'access_token', new_access_token,
    'protocol', selected_reservation.protocol
  );
end;
$$;

revoke all on function public.start_payment(text, text, text, numeric) from public;
grant execute on function public.start_payment(text, text, text, numeric) to anon, authenticated;

revoke all on function public.record_payment_proof(text, text, text, numeric) from public;
grant execute on function public.record_payment_proof(text, text, text, numeric) to anon, authenticated;

revoke all on function public.recover_reservation_access(text, text) from public;
grant execute on function public.recover_reservation_access(text, text) to anon, authenticated;

commit;

select
  to_regprocedure('public.start_payment(text,text,text,numeric)') is not null as pagamento_flexivel_configurado,
  to_regprocedure('public.record_payment_proof(text,text,text,numeric)') is not null as comprovante_flexivel_configurado,
  to_regprocedure('public.recover_reservation_access(text,text)') is not null as consulta_flexivel_configurada;
