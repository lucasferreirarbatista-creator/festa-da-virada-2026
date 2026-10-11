-- Festa da Virada 2026 - recuperação segura de inscrição por protocolo e CPF.
-- A função troca a chave privada da reserva depois de validar os dois dados.

begin;

create or replace function public.recover_reservation_access(
  p_protocol text,
  p_buyer_cpf text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  selected_reservation public.reservations%rowtype;
  clean_cpf text := regexp_replace(coalesce(p_buyer_cpf, ''), '[^0-9]', '', 'g');
  new_access_token text;
begin
  perform public.expire_stale_reservations();

  if length(trim(coalesce(p_protocol, ''))) < 6 or not public.is_valid_cpf(clean_cpf) then
    raise exception 'invalid_recovery_credentials';
  end if;

  select * into selected_reservation
  from public.reservations
  where upper(protocol) = upper(trim(p_protocol))
    and buyer_cpf = clean_cpf
  for update;

  if not found then
    raise exception 'invalid_recovery_credentials';
  end if;

  if selected_reservation.status in ('expired', 'cancelled', 'rejected') then
    raise exception 'reservation_not_active';
  end if;

  new_access_token := encode(gen_random_bytes(32), 'hex');

  update public.reservations
  set access_token_hash = digest(new_access_token, 'sha256'),
      updated_at = now()
  where id = selected_reservation.id;

  return jsonb_build_object(
    'access_token', new_access_token,
    'protocol', selected_reservation.protocol
  );
end;
$$;

revoke all on function public.recover_reservation_access(text, text) from public;
grant execute on function public.recover_reservation_access(text, text) to anon, authenticated;

commit;

select to_regprocedure('public.recover_reservation_access(text,text)') is not null
  as recuperacao_configurada;
