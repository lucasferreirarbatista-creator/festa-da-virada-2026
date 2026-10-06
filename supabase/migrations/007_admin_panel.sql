-- Festa da Virada 2026 - painel administrativo seguro
-- Execute uma única vez no SQL Editor depois da migração 006.

begin;

create table if not exists public.reservation_admin_actions (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  admin_user_id uuid not null references auth.users(id) on delete restrict,
  action text not null check (action in ('confirm', 'reject', 'cancel')),
  previous_status text not null,
  new_status text not null,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists reservation_admin_actions_reservation_idx
  on public.reservation_admin_actions(reservation_id, created_at desc);

alter table public.reservation_admin_actions enable row level security;

drop policy if exists "admins read reservation actions" on public.reservation_admin_actions;
create policy "admins read reservation actions"
  on public.reservation_admin_actions for select
  to authenticated using (public.is_admin());

grant select on public.reservation_admin_actions to authenticated;
grant select on public.admin_users to authenticated;

create or replace function public.admin_me()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  profile public.admin_users%rowtype;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;

  select * into profile
  from public.admin_users
  where user_id = auth.uid() and active = true;

  return jsonb_build_object(
    'user_id', profile.user_id,
    'display_name', profile.display_name,
    'email', auth.jwt()->>'email'
  );
end;
$$;

create or replace function public.admin_dashboard(p_event_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  event_id_value uuid;
  result jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  perform public.expire_stale_reservations();

  select id into event_id_value
  from public.events
  where slug = p_event_slug;
  if not found then raise exception 'event_not_found'; end if;

  select jsonb_build_object(
    'total_seats', (select count(*) from public.seats where event_id = event_id_value),
    'available_seats', (select count(*) from public.seats where event_id = event_id_value and status = 'available'),
    'held_seats', (select count(*) from public.seats where event_id = event_id_value and status = 'held'),
    'pending_seats', (select count(*) from public.seats where event_id = event_id_value and status = 'pending_review'),
    'confirmed_seats', (select count(*) from public.seats where event_id = event_id_value and status = 'confirmed'),
    'blocked_seats', (select count(*) from public.seats where event_id = event_id_value and status = 'blocked'),
    'pending_reservations', (select count(*) from public.reservations where event_id = event_id_value and status = 'pending_review'),
    'confirmed_reservations', (select count(*) from public.reservations where event_id = event_id_value and status = 'confirmed'),
    'confirmed_revenue', coalesce((select sum(total_amount) from public.reservations where event_id = event_id_value and status = 'confirmed'), 0),
    'pending_revenue', coalesce((select sum(total_amount) from public.reservations where event_id = event_id_value and status = 'pending_review'), 0),
    'updated_at', now()
  ) into result;

  return result;
end;
$$;

create or replace function public.admin_list_reservations(
  p_event_slug text,
  p_status text default null,
  p_search text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  normalized_search text := lower(trim(coalesce(p_search, '')));
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if p_status is not null and p_status <> 'all'
     and p_status not in ('held', 'pending_review', 'confirmed', 'cancelled', 'expired', 'rejected') then
    raise exception 'invalid_status';
  end if;

  perform public.expire_stale_reservations();

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into result
  from (
    select
      r.created_at,
      jsonb_build_object(
        'id', r.id,
        'protocol', r.protocol,
        'buyer_name', r.buyer_name,
        'buyer_whatsapp', r.buyer_whatsapp,
        'buyer_email', r.buyer_email,
        'status', r.status,
        'total_amount', r.total_amount,
        'expires_at', r.expires_at,
        'created_at', r.created_at,
        'seat_count', count(rs.id),
        'seat_codes', coalesce(jsonb_agg(s.code order by s.code) filter (where s.id is not null), '[]'::jsonb),
        'has_proof', exists (
          select 1 from public.payment_proofs pp where pp.reservation_id = r.id
        )
      ) as item
    from public.reservations r
    join public.events e on e.id = r.event_id
    left join public.reservation_seats rs on rs.reservation_id = r.id
    left join public.seats s on s.id = rs.seat_id
    where e.slug = p_event_slug
      and (p_status is null or p_status = 'all' or r.status = p_status)
      and (
        normalized_search = ''
        or lower(r.protocol) like '%' || normalized_search || '%'
        or lower(r.buyer_name) like '%' || normalized_search || '%'
        or lower(r.buyer_email) like '%' || normalized_search || '%'
        or (
          length(regexp_replace(normalized_search, '[^0-9]', '', 'g')) >= 3
          and r.buyer_whatsapp like '%' || regexp_replace(normalized_search, '[^0-9]', '', 'g') || '%'
        )
        or exists (
          select 1
          from public.reservation_seats search_rs
          join public.seats search_s on search_s.id = search_rs.seat_id
          where search_rs.reservation_id = r.id
            and lower(search_s.code) like '%' || normalized_search || '%'
        )
      )
    group by r.id
    order by r.created_at desc
    limit 300
  ) rows;

  return result;
end;
$$;

create or replace function public.admin_get_reservation(p_reservation_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;

  select jsonb_build_object(
    'id', r.id,
    'protocol', r.protocol,
    'buyer_name', r.buyer_name,
    'buyer_cpf', r.buyer_cpf,
    'buyer_whatsapp', r.buyer_whatsapp,
    'buyer_email', r.buyer_email,
    'status', r.status,
    'total_amount', r.total_amount,
    'expires_at', r.expires_at,
    'created_at', r.created_at,
    'updated_at', r.updated_at,
    'confirmed_at', r.confirmed_at,
    'cancelled_at', r.cancelled_at,
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'seat_code', s.code,
        'name', rs.participant_name,
        'cpf', rs.participant_cpf,
        'whatsapp', rs.participant_whatsapp,
        'birth_date', rs.birth_date,
        'age', rs.age_on_event,
        'category', rs.price_category,
        'price', rs.price
      ) order by s.code)
      from public.reservation_seats rs
      join public.seats s on s.id = rs.seat_id
      where rs.reservation_id = r.id
    ), '[]'::jsonb),
    'proof', (
      select jsonb_build_object(
        'storage_path', pp.storage_path,
        'original_filename', pp.original_filename,
        'mime_type', pp.mime_type,
        'size_bytes', pp.size_bytes,
        'uploaded_at', pp.uploaded_at,
        'reviewed_at', pp.reviewed_at,
        'review_notes', pp.review_notes
      )
      from public.payment_proofs pp
      where pp.reservation_id = r.id
      limit 1
    ),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object(
        'action', a.action,
        'previous_status', a.previous_status,
        'new_status', a.new_status,
        'notes', a.notes,
        'created_at', a.created_at,
        'admin_name', au.display_name
      ) order by a.created_at desc)
      from public.reservation_admin_actions a
      left join public.admin_users au on au.user_id = a.admin_user_id
      where a.reservation_id = r.id
    ), '[]'::jsonb)
  ) into result
  from public.reservations r
  where r.id = p_reservation_id;

  if result is null then raise exception 'reservation_not_found'; end if;
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
  selected_reservation public.reservations%rowtype;
  next_status text;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  if p_action not in ('confirm', 'reject', 'cancel') then raise exception 'invalid_action'; end if;
  if length(coalesce(p_notes, '')) > 500 then raise exception 'notes_too_long'; end if;

  select * into selected_reservation
  from public.reservations
  where id = p_reservation_id
  for update;
  if not found then raise exception 'reservation_not_found'; end if;

  if p_action = 'confirm' then
    if selected_reservation.status not in ('pending_review', 'confirmed') then
      raise exception 'invalid_status_transition';
    end if;
    next_status := 'confirmed';

    update public.reservations
       set status = 'confirmed', confirmed_at = coalesce(confirmed_at, now()),
           cancelled_at = null, updated_at = now()
     where id = p_reservation_id;

    update public.seats s
       set status = 'confirmed', updated_at = now()
      from public.reservation_seats rs
     where rs.reservation_id = p_reservation_id and rs.seat_id = s.id;
  else
    if p_action = 'reject' and selected_reservation.status <> 'pending_review' then
      raise exception 'invalid_status_transition';
    end if;
    if selected_reservation.status in ('cancelled', 'expired', 'rejected') then
      raise exception 'invalid_status_transition';
    end if;
    next_status := case when p_action = 'reject' then 'rejected' else 'cancelled' end;

    update public.reservations
       set status = next_status, cancelled_at = now(), updated_at = now()
     where id = p_reservation_id;

    update public.seats s
       set status = 'available', updated_at = now()
      from public.reservation_seats rs
     where rs.reservation_id = p_reservation_id and rs.seat_id = s.id
       and s.status <> 'blocked';
  end if;

  update public.payment_proofs
     set reviewed_at = now(), reviewed_by = auth.uid(), review_notes = nullif(trim(p_notes), '')
   where reservation_id = p_reservation_id;

  if selected_reservation.status <> next_status then
    insert into public.reservation_admin_actions (
      reservation_id, admin_user_id, action, previous_status, new_status, notes
    ) values (
      p_reservation_id, auth.uid(), p_action, selected_reservation.status, next_status,
      nullif(trim(p_notes), '')
    );
  end if;

  return jsonb_build_object(
    'id', p_reservation_id,
    'protocol', selected_reservation.protocol,
    'status', next_status
  );
end;
$$;

revoke all on function public.admin_me() from public;
revoke all on function public.admin_dashboard(text) from public;
revoke all on function public.admin_list_reservations(text, text, text) from public;
revoke all on function public.admin_get_reservation(uuid) from public;
revoke all on function public.admin_review_reservation(uuid, text, text) from public;

grant execute on function public.admin_me() to authenticated;
grant execute on function public.admin_dashboard(text) to authenticated;
grant execute on function public.admin_list_reservations(text, text, text) to authenticated;
grant execute on function public.admin_get_reservation(uuid) to authenticated;
grant execute on function public.admin_review_reservation(uuid, text, text) to authenticated;

commit;

select
  to_regprocedure('public.admin_me()') is not null as perfil_admin,
  to_regprocedure('public.admin_dashboard(text)') is not null as dashboard_admin,
  to_regprocedure('public.admin_review_reservation(uuid,text,text)') is not null as revisao_admin;
