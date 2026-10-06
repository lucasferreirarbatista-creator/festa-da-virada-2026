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
- Finalização sem comprovante para inscrições totalmente gratuitas.
- Status de aguardando conferência e tela final com protocolo.
- Painel administrativo protegido por login em `admin.html`.
- Indicadores de ocupação, valores confirmados e valores em análise.
- Busca e filtros de inscrições por status.
- Conferência privada de comprovantes e dados dos participantes.
- Aprovação, rejeição e cancelamento com liberação automática das cadeiras.
- Histórico das decisões administrativas.

## Próximas etapas

- Criar os usuários autorizados da equipe no Supabase Auth.
- Configurar o primeiro usuário na tabela `admin_users`.
- Validar o painel em produção com uma conta administrativa.

## Migrações

Execute os arquivos de `supabase/migrations` em ordem numérica no SQL Editor do Supabase. Em uma base já configurada até a etapa de pagamento, execute apenas `007_admin_panel.sql`.

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
