-- Festa da Virada 2026 - corrige receita e estados após cancelamentos.
-- Execute depois da migração 012.

begin;

create or replace function public.admin_dashboard(p_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  eid uuid;
  result jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  perform public.expire_stale_reservations();

  select id into eid from public.events where slug = p_event_slug;
  if not found then raise exception 'event_not_found'; end if;

  select jsonb_build_object(
    'total_seats', (select count(*) from public.seats where event_id = eid),
    'available_seats', (select count(*) from public.seats where event_id = eid and status = 'available'),
    'pending_seats', (select count(*) from public.seats where event_id = eid and status in ('held', 'pending_review')),
    'confirmed_seats', (select count(*) from public.seats where event_id = eid and status = 'confirmed'),
    'pending_reservations', (select count(*) from public.reservations where event_id = eid and status in ('pending_review', 'awaiting_cash')),
    -- paid_amount permanece como histórico. A receita do evento considera somente
    -- o valor pago que ainda está vinculado a uma reserva ativa.
    'confirmed_revenue', coalesce((
      select sum(least(r.paid_amount, r.total_amount))
      from public.reservations r
      where r.event_id = eid
        and r.status not in ('cancelled', 'expired', 'rejected')
    ), 0),
    'pending_revenue', coalesce((
      select sum(greatest(r.total_amount - r.paid_amount, 0))
      from public.reservations r
      where r.event_id = eid
        and r.status in ('pending_review', 'awaiting_cash', 'partially_paid')
    ), 0),
    'updated_at', now()
  ) into result;

  return result;
end;
$$;

create or replace function public.admin_review_reservation(
  p_reservation_id uuid,
  p_action text,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservations%rowtype;
  p public.reservation_payments%rowtype;
  next_status text;
  new_paid numeric(10,2);
  gross_paid numeric(10,2);
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if p_action not in ('confirm', 'reject', 'cancel') then raise exception 'invalid_action'; end if;
  if length(coalesce(p_notes, '')) > 500 then raise exception 'notes_too_long'; end if;

  select * into r from public.reservations where id = p_reservation_id for update;
  if not found then raise exception 'reservation_not_found'; end if;

  if p_action in ('confirm', 'reject') then
    select * into p
    from public.reservation_payments
    where reservation_id = r.id and status = 'pending_review'
    order by submitted_at desc
    limit 1
    for update;
    if not found then raise exception 'pending_payment_not_found'; end if;
  end if;

  if p_action = 'confirm' then
    update public.reservation_payments
    set status = 'approved', amount_received = amount_due,
        reviewed_at = now(), reviewed_by = auth.uid(), review_notes = nullif(trim(p_notes), '')
    where id = p.id;

    update public.payment_proofs
    set reviewed_at = now(), reviewed_by = auth.uid(), review_notes = nullif(trim(p_notes), '')
    where id = p.proof_id;

    gross_paid := r.paid_amount + p.amount_due;
    new_paid := least(r.total_amount, gross_paid);
    next_status := case when new_paid >= r.total_amount then 'confirmed' else 'partially_paid' end;

    update public.reservations
    set paid_amount = new_paid,
        refund_due = greatest(gross_paid - total_amount, 0),
        payment_status = case when new_paid >= total_amount then 'paid' else 'partial' end,
        status = next_status,
        confirmed_at = case when new_paid >= total_amount then coalesce(confirmed_at, now()) else confirmed_at end,
        cash_expires_at = null,
        updated_at = now()
    where id = r.id;

    update public.seats s
    set status = 'confirmed', updated_at = now()
    from public.reservation_seats rs
    where rs.reservation_id = r.id and rs.seat_id = s.id and rs.item_status = 'active';

  elsif p_action = 'reject' then
    update public.reservation_payments
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(), review_notes = nullif(trim(p_notes), '')
    where id = p.id;

    update public.payment_proofs
    set reviewed_at = now(), reviewed_by = auth.uid(), review_notes = nullif(trim(p_notes), '')
    where id = p.proof_id;

    next_status := case when r.paid_amount > 0 then 'partially_paid' else 'rejected' end;

    update public.reservations
    set status = next_status,
        payment_status = case when r.paid_amount > 0 then 'partial' else 'rejected' end,
        cash_expires_at = null,
        cancelled_at = case when r.paid_amount = 0 then now() else cancelled_at end,
        updated_at = now()
    where id = r.id;

    if r.paid_amount = 0 then
      update public.seats s
      set status = 'available', updated_at = now()
      from public.reservation_seats rs
      where rs.reservation_id = r.id
        and rs.seat_id = s.id
        and rs.item_status = 'active'
        and s.status <> 'blocked';
    else
      update public.seats s
      set status = 'confirmed', updated_at = now()
      from public.reservation_seats rs
      where rs.reservation_id = r.id and rs.seat_id = s.id and rs.item_status = 'active';
    end if;

  else
    if r.status in ('cancelled', 'expired', 'rejected') then raise exception 'invalid_status_transition'; end if;
    next_status := 'cancelled';

    update public.reservations
    set status = 'cancelled', cancelled_at = now(), refund_due = paid_amount, updated_at = now()
    where id = r.id;

    update public.reservation_payments
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
        review_notes = coalesce(nullif(trim(p_notes), ''), 'Reserva cancelada pela organização.')
    where reservation_id = r.id and status = 'pending_review';

    -- Libera somente as cadeiras que ainda pertencem ativamente à reserva.
    update public.seats s
    set status = 'available', updated_at = now()
    from public.reservation_seats rs
    where rs.reservation_id = r.id
      and rs.seat_id = s.id
      and rs.item_status = 'active'
      and s.status <> 'blocked';

    update public.reservation_seats
    set item_status = 'cancelled', ticket_status = 'cancelled', cancelled_at = now(),
        cancelled_by = auth.uid(), cancellation_notes = nullif(trim(p_notes), '')
    where reservation_id = r.id and item_status = 'active';

    update public.reservation_guests
    set item_status = 'cancelled', ticket_status = 'cancelled', cancelled_at = now(),
        cancelled_by = auth.uid(), cancellation_notes = nullif(trim(p_notes), '')
    where reservation_id = r.id and item_status = 'active';
  end if;

  insert into public.reservation_admin_actions(
    reservation_id, admin_user_id, action, previous_status, new_status, notes
  ) values (
    r.id, auth.uid(), p_action, r.status, next_status, nullif(trim(p_notes), '')
  );

  return jsonb_build_object(
    'id', r.id,
    'protocol', r.protocol,
    'status', next_status,
    'refund_due', case when p_action = 'cancel' then r.paid_amount else 0 end
  );
end;
$$;

create or replace function public.admin_cancel_reservation_seat(
  p_reservation_seat_id uuid,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rs public.reservation_seats%rowtype;
  r public.reservations%rowtype;
  seat_code text;
  new_total numeric(10,2);
  active_count integer;
  next_status text;
  next_payment_status text;
  credit_due numeric(10,2);
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;

  select * into rs from public.reservation_seats where id = p_reservation_seat_id for update;
  if not found or rs.item_status <> 'active' then raise exception 'active_seat_not_found'; end if;

  select * into r from public.reservations where id = rs.reservation_id for update;
  if r.status in ('cancelled', 'expired', 'rejected') then raise exception 'invalid_status_transition'; end if;

  select code into seat_code from public.seats where id = rs.seat_id;

  update public.reservation_seats
  set item_status = 'cancelled', ticket_status = 'cancelled', cancelled_at = now(),
      cancelled_by = auth.uid(), cancellation_notes = nullif(trim(p_notes), '')
  where id = rs.id;

  update public.seats
  set status = 'available', updated_at = now()
  where id = rs.seat_id and status <> 'blocked';

  select coalesce(sum(price), 0), count(*)
  into new_total, active_count
  from public.reservation_seats
  where reservation_id = r.id and item_status = 'active';

  credit_due := greatest(r.paid_amount - new_total, 0);
  next_status := case
    when active_count = 0 then 'cancelled'
    when r.paid_amount >= new_total and r.paid_amount > 0 then 'confirmed'
    when r.paid_amount > 0 then 'partially_paid'
    else r.status
  end;
  next_payment_status := case
    when active_count = 0 then r.payment_status
    when r.paid_amount >= new_total and r.paid_amount > 0 then 'paid'
    when r.paid_amount > 0 then 'partial'
    else r.payment_status
  end;

  update public.reservations
  set total_amount = new_total,
      refund_due = credit_due,
      status = next_status,
      payment_status = next_payment_status,
      confirmed_at = case when next_status = 'confirmed' then coalesce(confirmed_at, now()) else confirmed_at end,
      cancelled_at = case when active_count = 0 then now() else cancelled_at end,
      updated_at = now()
  where id = r.id;

  if active_count = 0 then
    update public.reservation_payments
    set status = 'rejected', reviewed_at = now(), reviewed_by = auth.uid(),
        review_notes = coalesce(nullif(trim(p_notes), ''), 'Reserva cancelada após a última cadeira ser removida.')
    where reservation_id = r.id and status = 'pending_review';

    update public.reservation_guests
    set item_status = 'cancelled', ticket_status = 'cancelled', cancelled_at = now(), cancelled_by = auth.uid()
    where reservation_id = r.id and item_status = 'active';
  elsif r.paid_amount > 0 then
    update public.seats s
    set status = 'confirmed', updated_at = now()
    from public.reservation_seats active_rs
    where active_rs.reservation_id = r.id
      and active_rs.seat_id = s.id
      and active_rs.item_status = 'active';
  end if;

  insert into public.reservation_admin_actions(
    reservation_id, admin_user_id, action, previous_status, new_status, notes
  ) values (
    r.id,
    auth.uid(),
    'cancel_seat',
    r.status,
    next_status,
    concat('Cadeira ', seat_code, case when nullif(trim(p_notes), '') is null then '' else ': ' || trim(p_notes) end)
  );

  return jsonb_build_object(
    'protocol', r.protocol,
    'seat_code', seat_code,
    'total_amount', new_total,
    'paid_amount', r.paid_amount,
    'recognized_revenue', case when active_count = 0 then 0 else least(r.paid_amount, new_total) end,
    'refund_due', credit_due,
    'status', next_status,
    'payment_status', next_payment_status
  );
end;
$$;

commit;

