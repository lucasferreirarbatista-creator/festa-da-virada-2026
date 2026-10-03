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

## Próximas etapas

- Executar a migração inicial no Supabase.
- Conectar a aplicação ao Supabase.
- Reserva temporária e sincronização em tempo real.
- Pix, comprovantes e protocolo.
- Área administrativa da organização.

## Visualização local

Sirva esta pasta com um servidor HTTP estático. Por exemplo:

```bash
python3 -m http.server 4173
```

Depois abra `http://localhost:4173`.
