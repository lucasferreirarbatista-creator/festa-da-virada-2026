-- Festa da Virada 2026 - corrige referência ambígua na limpeza de reservas.
-- Execute depois da migração 009.

begin;

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
     set ticket_status = 'cancelled', item_status = 'cancelled',
         cancelled_at = coalesce(rs.cancelled_at, now())
    from public.reservations r
   where r.id = rs.reservation_id and r.status = 'expired' and rs.item_status = 'active';

  update public.reservation_guests rg
     set ticket_status = 'cancelled', item_status = 'cancelled',
         cancelled_at = coalesce(rg.cancelled_at, now())
    from public.reservations r
   where r.id = rg.reservation_id and r.status = 'expired' and rg.item_status = 'active';

  -- Pagamentos em dinheiro não confirmados dentro de 48 horas.
  update public.reservation_payments p
     set status = 'expired', reviewed_at = now(), review_notes = 'Prazo de 48 horas expirado.'
    from public.reservations r
   where p.reservation_id = r.id and p.status = 'pending_review'
     and p.payment_method = 'cash' and r.cash_expires_at <= now();

  -- Quando já houve entrada, apenas o pagamento em dinheiro pendente expira.
  update public.reservations
     set status = 'partially_paid', payment_status = 'partial',
         cash_expires_at = null, updated_at = now()
   where status = 'awaiting_cash' and cash_expires_at <= now() and paid_amount > 0;

  -- Sem entrada aprovada, a reserva expira e as cadeiras são liberadas.
  with expired_cash as (
    update public.reservations
       set status = 'expired', payment_status = 'unpaid',
           cash_expires_at = null, updated_at = now()
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
     set ticket_status = 'cancelled', item_status = 'cancelled',
         cancelled_at = coalesce(rs.cancelled_at, now())
    from public.reservations r
   where r.id = rs.reservation_id and r.status = 'expired' and rs.item_status = 'active';

  update public.reservation_guests rg
     set ticket_status = 'cancelled', item_status = 'cancelled',
         cancelled_at = coalesce(rg.cancelled_at, now())
    from public.reservations r
   where r.id = rg.reservation_id and r.status = 'expired' and rg.item_status = 'active';

  return expired_count;
end;
$$;

revoke all on function public.expire_stale_reservations() from public;
grant execute on function public.expire_stale_reservations() to anon, authenticated;

commit;

select public.expire_stale_reservations() as reservas_expiradas,
       to_regprocedure('public.create_hold(text,text,text,text,text,text,jsonb,jsonb)') is not null
         as reserva_configurada;
