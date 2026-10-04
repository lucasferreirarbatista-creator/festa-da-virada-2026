-- Permite que as funções de reserva acessem o pgcrypto do Supabase.
-- Execute este arquivo no SQL Editor após a migração 003.

begin;

alter function public.create_hold(text, text, text, text, text, text, jsonb)
  set search_path = public, extensions;

alter function public.get_reservation(text)
  set search_path = public, extensions;

commit;

-- Resultado esperado: true, true
select
  to_regprocedure('extensions.gen_random_bytes(integer)') is not null as gerador_disponivel,
  to_regprocedure('extensions.digest(text,text)') is not null as hash_disponivel;
