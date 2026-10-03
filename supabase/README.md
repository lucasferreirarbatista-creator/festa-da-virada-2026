# Configuração do Supabase

## Primeira instalação

1. Abra o projeto `festa-da-virada-2026` no Supabase.
2. Entre em **SQL Editor** e clique em **New query**.
3. Copie todo o conteúdo de `migrations/001_initial_schema.sql`.
4. Cole no editor e clique em **Run**.
5. Confira no **Table Editor** se existem 50 registros em `event_tables` e 400 em `seats`.

O script cria as tabelas, funções de reserva, regras de acesso e o bucket privado
`payment-proofs`. Dados pessoais, CPFs e comprovantes não ficam disponíveis para
visitantes do site.

## Dados que ainda serão configurados

- horário do evento;
- telefone e e-mail oficiais;
- código Pix copia e cola;
- nome do recebedor do Pix;
- imagem do QR Code Pix;
- primeiro usuário administrador.

Nunca salve a senha do banco ou a chave `service_role` no GitHub ou no navegador.
