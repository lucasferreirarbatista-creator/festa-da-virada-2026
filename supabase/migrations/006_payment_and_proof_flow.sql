begin;

update public.events
set event_time = time '00:20',
    pix_copy_paste = '00020126430014br.gov.bcb.pix0114265648990001690203Pix5204000053039865802BR5925IGREJA BATISTA ATOS NA CO6008IPATINGA62290525C8NG06XTux4mdr3cyM2AnYAjT63041FC1',
    pix_receiver_name = 'Igreja Batista Atos - Na comunhão e no partir do pão',
    contact_phone = '(31) 8741-7442',
    contact_email = 'iba.igrejabatistaatos@gmail.com',
    updated_at = now()
where slug = 'festa-da-virada-2026';

create unique index if not exists payment_proofs_reservation_unique_idx
  on public.payment_proofs(reservation_id);

create or replace function public.can_upload_payment_proof(p_object_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.reservations r
    where encode(r.access_token_hash, 'hex') = split_part(p_object_name, '/', 1)
      and split_part(p_object_name, '/', 1) ~ '^[0-9a-f]{64}$'
      and r.status = 'held'
      and r.expires_at > now()
  );
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
  selected_reservation public.reservations%rowtype;
  stored_mime text;
  stored_size bigint;
  result jsonb;
begin
  perform public.expire_stale_reservations();

  select * into selected_reservation
  from public.reservations
  where access_token_hash = digest(p_access_token, 'sha256')
  for update;

  if not found then raise exception 'reservation_not_found'; end if;

  if selected_reservation.status = 'pending_review'
     and exists (select 1 from public.payment_proofs where reservation_id = selected_reservation.id) then
    select jsonb_build_object(
      'status', selected_reservation.status,
      'protocol', selected_reservation.protocol,
      'total_amount', selected_reservation.total_amount,
      'seats', coalesce(jsonb_agg(jsonb_build_object('code', s.code) order by s.code), '[]'::jsonb)
    ) into result
    from public.reservation_seats rs
    join public.seats s on s.id = rs.seat_id
    where rs.reservation_id = selected_reservation.id;
    return result;
  end if;

  if selected_reservation.status <> 'held' or selected_reservation.expires_at <= now() then
    raise exception 'reservation_expired';
  end if;
  if selected_reservation.total_amount <= 0 then raise exception 'payment_not_required'; end if;
  if split_part(p_storage_path, '/', 1) <> encode(selected_reservation.access_token_hash, 'hex') then
    raise exception 'invalid_storage_path';
  end if;
  if length(trim(coalesce(p_original_filename, ''))) < 1 or length(p_original_filename) > 255 then
    raise exception 'invalid_filename';
  end if;

  select metadata->>'mimetype', nullif(metadata->>'size', '')::bigint
    into stored_mime, stored_size
  from storage.objects
  where bucket_id = 'payment-proofs' and name = p_storage_path;

  if not found then raise exception 'payment_file_not_found'; end if;
  if stored_mime is null or stored_mime not in ('image/jpeg', 'image/png', 'application/pdf') then raise exception 'invalid_file_type'; end if;
  if stored_size is null or stored_size <= 0 or stored_size > 10485760 then raise exception 'invalid_file_size'; end if;

  insert into public.payment_proofs (
    reservation_id, storage_path, original_filename, mime_type, size_bytes
  ) values (
    selected_reservation.id, p_storage_path, trim(p_original_filename), stored_mime, stored_size
  );

  update public.reservations
  set status = 'pending_review', updated_at = now()
  where id = selected_reservation.id;

  update public.seats s
  set status = 'pending_review', updated_at = now()
  from public.reservation_seats rs
  where rs.reservation_id = selected_reservation.id
    and rs.seat_id = s.id
    and s.status = 'held';

  select jsonb_build_object(
    'status', 'pending_review',
    'protocol', selected_reservation.protocol,
    'total_amount', selected_reservation.total_amount,
    'seats', coalesce(jsonb_agg(jsonb_build_object('code', s.code) order by s.code), '[]'::jsonb)
  ) into result
  from public.reservation_seats rs
  join public.seats s on s.id = rs.seat_id
  where rs.reservation_id = selected_reservation.id;
  return result;
end;
$$;

create or replace function public.finalize_free_reservation(p_access_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  selected_reservation public.reservations%rowtype;
  result jsonb;
begin
  perform public.expire_stale_reservations();

  select * into selected_reservation
  from public.reservations
  where access_token_hash = digest(p_access_token, 'sha256')
  for update;

  if not found then raise exception 'reservation_not_found'; end if;
  if selected_reservation.status = 'pending_review' and selected_reservation.total_amount = 0 then
    select jsonb_build_object(
      'status', selected_reservation.status,
      'protocol', selected_reservation.protocol,
      'total_amount', selected_reservation.total_amount,
      'seats', coalesce(jsonb_agg(jsonb_build_object('code', s.code) order by s.code), '[]'::jsonb)
    ) into result
    from public.reservation_seats rs
    join public.seats s on s.id = rs.seat_id
    where rs.reservation_id = selected_reservation.id;
    return result;
  end if;
  if selected_reservation.status <> 'held' or selected_reservation.expires_at <= now() then
    raise exception 'reservation_expired';
  end if;
  if selected_reservation.total_amount <> 0 then raise exception 'payment_required'; end if;

  update public.reservations set status = 'pending_review', updated_at = now()
  where id = selected_reservation.id;
  update public.seats s set status = 'pending_review', updated_at = now()
  from public.reservation_seats rs
  where rs.reservation_id = selected_reservation.id and rs.seat_id = s.id and s.status = 'held';

  select jsonb_build_object(
    'status', 'pending_review',
    'protocol', selected_reservation.protocol,
    'total_amount', selected_reservation.total_amount,
    'seats', coalesce(jsonb_agg(jsonb_build_object('code', s.code) order by s.code), '[]'::jsonb)
  ) into result
  from public.reservation_seats rs
  join public.seats s on s.id = rs.seat_id
  where rs.reservation_id = selected_reservation.id;
  return result;
end;
$$;

revoke all on function public.can_upload_payment_proof(text) from public;
grant execute on function public.can_upload_payment_proof(text) to anon, authenticated;
revoke all on function public.record_payment_proof(text, text, text) from public;
grant execute on function public.record_payment_proof(text, text, text) to anon, authenticated;
revoke all on function public.finalize_free_reservation(text) from public;
grant execute on function public.finalize_free_reservation(text) to anon, authenticated;

drop policy if exists "visitors upload own payment proofs" on storage.objects;
create policy "visitors upload own payment proofs" on storage.objects for insert
  to anon, authenticated
  with check (
    bucket_id = 'payment-proofs'
    and public.can_upload_payment_proof(name)
  );

commit;

select
  (select event_time from public.events where slug = 'festa-da-virada-2026') as horario,
  to_regprocedure('public.record_payment_proof(text,text,text)') is not null as envio_configurado,
  to_regprocedure('public.finalize_free_reservation(text)') is not null as gratuidade_configurada;
