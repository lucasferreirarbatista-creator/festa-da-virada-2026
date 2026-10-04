-- Corrige a validação de e-mail dentro da criação da reserva.
-- Execute este arquivo no SQL Editor após a migração 002.

begin;

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

commit;

-- Resultado esperado: true
select 'teste.tecnico@example.com' ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+[.][A-Z]{2,}$' as email_valido;
