-- Corrige a normalização de CPF e WhatsApp da instalação inicial.
-- Execute este arquivo no SQL Editor após a migração 001.

begin;

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

commit;

-- Resultado esperado: true, true
select
  public.is_valid_cpf('111.444.777-35') as cpf_valido,
  public.is_valid_whatsapp('(31) 90000-0000') as whatsapp_valido;
