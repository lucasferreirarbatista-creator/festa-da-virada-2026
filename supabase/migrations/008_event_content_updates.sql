-- Festa da Virada 2026 - correções de contato e endereço oficial.
-- A data de referência para cálculo das categorias permanece em 31/12/2026.

begin;

update public.events
set venue = 'Salão Triunfo - Rua dos Filipenses, 85 - Canaã, Ipatinga/MG - CEP 35164-163',
    contact_phone = '(31) 98741-7442',
    updated_at = now()
where slug = 'festa-da-virada-2026';

commit;

select venue, contact_phone
from public.events
where slug = 'festa-da-virada-2026';
