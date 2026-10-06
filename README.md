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

## Próximas etapas

- Criar a confirmação/cancelamento pela organização.
- Área administrativa da organização.

## Migrações

Execute os arquivos de `supabase/migrations` em ordem numérica no SQL Editor do Supabase. Em uma base já configurada até a etapa anterior, execute apenas `006_payment_and_proof_flow.sql`.

## Visualização local

Sirva esta pasta com um servidor HTTP estático. Por exemplo:

```bash
python3 -m http.server 4173
```

Depois abra `http://localhost:4173`.
