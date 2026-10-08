# Festa da Virada 2026

Aplicação web para inscrição, escolha de cadeiras e conferência de pagamentos da Festa da Virada da Igreja Batista Atos.

## Estado atual

- Landing page responsiva.
- Croqui com 50 mesas e 400 cadeiras.
- Divisão em Salão, Varanda e Expansão coberta.
- Seleção de cadeiras e filtros por área.
- Formulários do responsável e dos participantes.
- Cálculo de idade, categoria e preço.
- Resumo da inscrição e total.
- Estrutura inicial do Supabase em `supabase/migrations`.
- Mapa conectado aos 400 lugares do Supabase.
- Reserva transacional de cadeiras por 15 minutos.
- Protocolo e retomada da reserva após recarregar a página.
- Pix copia e cola com o valor exato da reserva e QR Code gerado no navegador.
- Upload privado de comprovantes JPG, PNG e PDF de até 10 MB.
- 350 vagas de inteira e 50 vagas de meia-entrada; crianças de até 5 anos são cadastradas sem cadeira.
- Pagamento integral ou entrada de 30%, com saldo previsto para 10/12/2026.
- Pagamento por Pix ou em dinheiro, com prazo de 48 horas para conferência do dinheiro.
- Status de aguardando conferência e tela final com protocolo.
- Painel administrativo protegido por login em `admin.html`.
- Indicadores de ocupação, valores confirmados e valores em análise.
- Busca e filtros de inscrições por status.
- Conferência privada de comprovantes e dados dos participantes.
- Aprovação, rejeição e cancelamento com liberação automática das cadeiras.
- Histórico das decisões administrativas.
- Cancelamento individual de cadeira com recálculo e indicação de eventual reembolso.
- Relatório de inscritos em CSV ou formato de impressão/PDF.
- Ingresso individual com QR Code para cada cadeira e criança sem cadeira.
- Check-in restrito à organização; a entrada só é liberada com o pagamento quitado.

## Ativação da versão atual

1. Execute `009_payments_tickets_and_capacity.sql` no SQL Editor do Supabase.
2. Publique os arquivos do site.
3. Faça uma reserva de teste com entrada de 30%, aprove o pagamento no painel e valide o QR Code.

## Migrações

Execute os arquivos de `supabase/migrations` em ordem numérica no SQL Editor do Supabase. Em uma base já configurada até a migração 008, execute apenas `009_payments_tickets_and_capacity.sql`.

## Primeiro administrador

1. Crie o usuário em **Authentication → Users → Add user** no Supabase.
2. Copie o UUID do usuário criado.
3. Execute no SQL Editor, substituindo os valores:

```sql
insert into public.admin_users (user_id, display_name)
values ('UUID-DO-USUARIO', 'Nome da pessoa');
```

Depois, acesse `/admin.html` com o e-mail e a senha cadastrados.

## Visualização local

Sirva esta pasta com um servidor HTTP estático. Por exemplo:

```bash
python3 -m http.server 4173
```

Depois abra `http://localhost:4173`.
