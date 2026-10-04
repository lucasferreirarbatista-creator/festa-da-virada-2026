-- Festa da Virada 2026 - estrutura inicial do Supabase
-- Execute este arquivo uma única vez no SQL Editor do projeto.

begin;

create extension if not exists pgcrypto;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  venue text not null,
  event_date date not null,
  event_time time,
  full_price numeric(10,2) not null check (full_price >= 0),
  half_price numeric(10,2) not null check (half_price >= 0),
  free_max_age smallint not null check (free_max_age >= 0),
  half_max_age smallint not null check (half_max_age > free_max_age),
  hold_minutes smallint not null default 15 check (hold_minutes between 5 and 60),
  pix_copy_paste text,
  pix_receiver_name text,
  pix_qr_path text,
  contact_phone text,
  contact_email text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.event_tables (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  code text not null,
  area text not null check (area in ('salao', 'varanda', 'expansao')),
  table_number smallint not null check (table_number > 0),
  seat_count smallint not null default 8 check (seat_count = 8),
  sort_order smallint not null,
  created_at timestamptz not null default now(),
  unique (event_id, code),
  unique (event_id, area, table_number)
);

create table public.seats (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  event_table_id uuid not null references public.event_tables(id) on delete cascade,
  code text not null,
  seat_number smallint not null check (seat_number between 1 and 8),
  status text not null default 'available'
    check (status in ('available', 'held', 'pending_review', 'confirmed', 'blocked')),
  updated_at timestamptz not null default now(),
  unique (event_id, code),
  unique (event_table_id, seat_number)
);

create table public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete restrict,
  protocol text not null unique,
  access_token_hash bytea not null,
  buyer_name text not null,
  buyer_cpf text not null,
  buyer_whatsapp text not null,
  buyer_email text not null,
  status text not null default 'held'
    check (status in ('held', 'pending_review', 'confirmed', 'cancelled', 'expired', 'rejected')),
  total_amount numeric(10,2) not null default 0 check (total_amount >= 0),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz
);

create unique index reservations_access_token_hash_idx
  on public.reservations(access_token_hash);
create index reservations_event_status_idx
  on public.reservations(event_id, status);
create index reservations_expires_at_idx
  on public.reservations(expires_at) where status = 'held';

create table public.reservation_seats (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  seat_id uuid not null references public.seats(id) on delete restrict,
  participant_name text not null,
  participant_cpf text not null,
  participant_whatsapp text not null,
  birth_date date not null,
  age_on_event smallint not null check (age_on_event >= 0),
  price_category text not null check (price_category in ('free', 'half', 'full')),
  price numeric(10,2) not null check (price >= 0),
  created_at timestamptz not null default now(),
  unique (reservation_id, seat_id)
);

create index reservation_seats_seat_idx on public.reservation_seats(seat_id);

create table public.payment_proofs (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id) on delete cascade,
  storage_path text not null unique,
  original_filename text not null,
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'application/pdf')),
  size_bytes bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  uploaded_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  review_notes text
);

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.admin_users
    where user_id = auth.uid() and active = true
  );
$$;

create or replace function public.is_valid_cpf(value text)
returns boolean
language plpgsql
immutable
set search_path = public
as $$
declare
  cpf text := regexp_replace(coalesce(value, ''), '[^0-9]', '', 'g');
  total integer;
  digit integer;
  i integer;
begin
  if length(cpf) <> 11 or cpf = repeat(substring(cpf, 1, 1), 11) then return false; end if;
  total := 0;
  for i in 1..9 loop total := total + substring(cpf, i, 1)::int * (11 - i); end loop;
  digit := (total * 10) % 11;
  if digit = 10 then digit := 0; end if;
  if digit <> substring(cpf, 10, 1)::int then return false; end if;
  total := 0;
  for i in 1..10 loop total := total + substring(cpf, i, 1)::int * (12 - i); end loop;
  digit := (total * 10) % 11;
  if digit = 10 then digit := 0; end if;
  return digit = substring(cpf, 11, 1)::int;
end;
$$;

create or replace function public.is_valid_whatsapp(value text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select regexp_replace(coalesce(value, ''), '[^0-9]', '', 'g') ~ '^[1-9][1-9]9[0-9]{8}$';
$$;

create or replace function public.expire_stale_reservations()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  expired_count integer;
begin
  with expired as (
    update public.reservations
       set status = 'expired', updated_at = now()
     where status = 'held' and expires_at <= now()
     returning id
  ), released as (
    update public.seats s
       set status = 'available', updated_at = now()
      from public.reservation_seats rs
      join expired e on e.id = rs.reservation_id
     where s.id = rs.seat_id and s.status = 'held'
     returning s.id
  )
  select count(*) into expired_count from expired;
  return expired_count;
end;
$$;

create or replace function public.create_hold(
  p_event_slug text,
  p_access_token text,
  p_buyer_name text,
  p_buyer_cpf text,
  p_buyer_whatsapp text,
  p_buyer_email text,
  p_participants jsonb
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
  selected_seat public.seats%rowtype;
  participant_birth date;
  participant_age integer;
  participant_price numeric(10,2);
  participant_category text;
  total numeric(10,2) := 0;
  item_count integer;
  unique_count integer;
begin
  perform public.expire_stale_reservations();

  if length(coalesce(p_access_token, '')) < 32 then raise exception 'invalid_access_token'; end if;
  if length(trim(coalesce(p_buyer_name, ''))) < 3 then raise exception 'invalid_buyer_name'; end if;
  if not public.is_valid_cpf(p_buyer_cpf) then raise exception 'invalid_buyer_cpf'; end if;
  if not public.is_valid_whatsapp(p_buyer_whatsapp) then raise exception 'invalid_buyer_whatsapp'; end if;
  if trim(coalesce(p_buyer_email, '')) !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}$' then raise exception 'invalid_buyer_email'; end if;
  if jsonb_typeof(p_participants) <> 'array' then raise exception 'invalid_participants'; end if;

  item_count := jsonb_array_length(p_participants);
  if item_count < 1 or item_count > 20 then raise exception 'invalid_seat_count'; end if;
  select count(distinct item->>'seat_code') into unique_count from jsonb_array_elements(p_participants) item;
  if unique_count <> item_count then raise exception 'duplicate_seat'; end if;

  select * into selected_event
    from public.events
   where slug = p_event_slug and active = true;
  if not found then raise exception 'event_not_found'; end if;

  new_protocol := 'FV26-' || upper(encode(gen_random_bytes(4), 'hex'));
  insert into public.reservations (
    event_id, protocol, access_token_hash, buyer_name, buyer_cpf,
    buyer_whatsapp, buyer_email, expires_at
  ) values (
    selected_event.id, new_protocol, digest(p_access_token, 'sha256'), trim(p_buyer_name),
    regexp_replace(p_buyer_cpf, '[^0-9]', '', 'g'), regexp_replace(p_buyer_whatsapp, '[^0-9]', '', 'g'),
    lower(trim(p_buyer_email)), now() + make_interval(mins => selected_event.hold_minutes)
  ) returning id into new_reservation_id;

  for participant in select value from jsonb_array_elements(p_participants) loop
    select * into selected_seat
      from public.seats
     where event_id = selected_event.id and code = participant->>'seat_code'
     for update;
    if not found or selected_seat.status <> 'available' then
      raise exception 'unavailable:%', participant->>'seat_code';
    end if;
    if length(trim(coalesce(participant->>'name', ''))) < 2 then raise exception 'invalid_participant_name'; end if;
    if not public.is_valid_cpf(participant->>'cpf') then raise exception 'invalid_participant_cpf'; end if;
    if not public.is_valid_whatsapp(participant->>'whatsapp') then raise exception 'invalid_participant_whatsapp'; end if;

    begin participant_birth := (participant->>'birth_date')::date;
    exception when others then raise exception 'invalid_birth_date'; end;
    if participant_birth < date '1900-01-01' or participant_birth > selected_event.event_date then
      raise exception 'invalid_birth_date';
    end if;

    participant_age := extract(year from age(selected_event.event_date, participant_birth))::integer;
    if participant_age <= selected_event.free_max_age then
      participant_category := 'free'; participant_price := 0;
    elsif participant_age <= selected_event.half_max_age then
      participant_category := 'half'; participant_price := selected_event.half_price;
    else
      participant_category := 'full'; participant_price := selected_event.full_price;
    end if;

    insert into public.reservation_seats (
      reservation_id, seat_id, participant_name, participant_cpf, participant_whatsapp,
      birth_date, age_on_event, price_category, price
    ) values (
      new_reservation_id, selected_seat.id, trim(participant->>'name'),
      regexp_replace(participant->>'cpf', '[^0-9]', '', 'g'),
      regexp_replace(participant->>'whatsapp', '[^0-9]', '', 'g'),
      participant_birth, participant_age, participant_category, participant_price
    );
    update public.seats set status = 'held', updated_at = now() where id = selected_seat.id;
    total := total + participant_price;
  end loop;

  update public.reservations set total_amount = total where id = new_reservation_id;
  return jsonb_build_object(
    'reservation_id', new_reservation_id,
    'protocol', new_protocol,
    'status', 'held',
    'total_amount', total,
    'expires_at', now() + make_interval(mins => selected_event.hold_minutes)
  );
end;
$$;

create or replace function public.get_reservation(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  result jsonb;
begin
  perform public.expire_stale_reservations();
  select jsonb_build_object(
    'id', r.id,
    'protocol', r.protocol,
    'status', r.status,
    'total_amount', r.total_amount,
    'expires_at', r.expires_at,
    'seats', coalesce((
      select jsonb_agg(seat_item order by seat_code)
      from (
        select
          s.code as seat_code,
          jsonb_build_object(
            'code', s.code,
            'name', rs.participant_name,
            'category', rs.price_category,
            'price', rs.price
          ) as seat_item
        from public.reservation_seats rs
        join public.seats s on s.id = rs.seat_id
        where rs.reservation_id = r.id
      ) reservation_items
    ), '[]'::jsonb)
  ) into result
  from public.reservations r
  where r.access_token_hash = digest(p_access_token, 'sha256');
  return result;
end;
$$;

create or replace function public.admin_release_all_seats(p_event_slug text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare released integer;
begin
  if not public.is_admin() then raise exception 'admin_required'; end if;
  update public.reservations r
     set status = 'cancelled', cancelled_at = now(), updated_at = now()
    from public.events e
   where r.event_id = e.id and e.slug = p_event_slug
     and r.status in ('held', 'pending_review', 'confirmed');
  update public.seats s set status = 'available', updated_at = now()
   where s.event_id = (select id from public.events where slug = p_event_slug)
     and s.status <> 'blocked';
  get diagnostics released = row_count;
  return released;
end;
$$;

insert into public.events (
  slug, name, venue, event_date, full_price, half_price,
  free_max_age, half_max_age, hold_minutes
) values (
  'festa-da-virada-2026', 'Festa da Virada 2026', 'Salão Triunfo – Ipatinga/MG',
  date '2026-12-31', 180.00, 90.00, 5, 10, 15
);

with event_row as (
  select id from public.events where slug = 'festa-da-virada-2026'
), table_seed as (
  select 'salao'::text area, 'S'::text prefix, n, n sort_order from generate_series(1, 32) n
  union all select 'varanda', 'V', n, 32 + n from generate_series(1, 12) n
  union all select 'expansao', 'E', n, 44 + n from generate_series(1, 6) n
)
insert into public.event_tables (event_id, code, area, table_number, sort_order)
select e.id, t.prefix || lpad(t.n::text, 2, '0'), t.area, t.n, t.sort_order
from event_row e cross join table_seed t;

insert into public.seats (event_id, event_table_id, code, seat_number)
select t.event_id, t.id, t.code || '-' || lpad(n::text, 2, '0'), n
from public.event_tables t cross join generate_series(1, 8) n
join public.events e on e.id = t.event_id
where e.slug = 'festa-da-virada-2026';

alter table public.events enable row level security;
alter table public.event_tables enable row level security;
alter table public.seats enable row level security;
alter table public.admin_users enable row level security;
alter table public.reservations enable row level security;
alter table public.reservation_seats enable row level security;
alter table public.payment_proofs enable row level security;

create policy "public can read active events" on public.events for select
  to anon, authenticated using (active = true or public.is_admin());
create policy "public can read event tables" on public.event_tables for select
  to anon, authenticated using (true);
create policy "public can read seat status" on public.seats for select
  to anon, authenticated using (true);
create policy "admins manage events" on public.events for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage tables" on public.event_tables for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage seats" on public.seats for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins read admin users" on public.admin_users for select
  to authenticated using (public.is_admin());
create policy "admins manage reservations" on public.reservations for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage reservation seats" on public.reservation_seats for all
  to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admins manage payment proofs" on public.payment_proofs for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.admin_users, public.reservations, public.reservation_seats, public.payment_proofs from anon;
grant select on public.events, public.event_tables, public.seats to anon, authenticated;
grant execute on function public.create_hold(text,text,text,text,text,text,jsonb) to anon, authenticated;
grant execute on function public.get_reservation(text) to anon, authenticated;
revoke all on function public.expire_stale_reservations() from public;
grant execute on function public.expire_stale_reservations() to anon, authenticated;
revoke execute on function public.admin_release_all_seats(text) from public, anon;
grant execute on function public.admin_release_all_seats(text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'payment-proofs', 'payment-proofs', false, 10485760,
  array['image/jpeg', 'image/png', 'application/pdf']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "admins read payment files" on storage.objects for select
  to authenticated using (bucket_id = 'payment-proofs' and public.is_admin());

commit;

-- Conferência esperada após executar:
-- select count(*) as mesas from public.event_tables; -- 50
-- select count(*) as cadeiras from public.seats;      -- 400
