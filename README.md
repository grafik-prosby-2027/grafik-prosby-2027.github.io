# Grafik – Neurologia, odc. I

Prośby do grafiku na 2027 r. Każdy pracownik loguje się własnym kontem i widzi **tylko swoje**
prośby i swoje zmiany w grafiku. Administrator (oddziałowy) widzi prośby wszystkich i układa grafik.

- `index.html` – aplikacja (strona statyczna, działa na GitHub Pages).
- `supabase.js` – lokalna kopia `@supabase/supabase-js` 2.45.4 (UMD).
- `baza.sql` – schemat bazy i reguły dostępu (RLS) w projekcie Supabase `grafik-neurologia`.

Prywatność pilnuje baza danych (Row Level Security), a nie strona – nawet ktoś, kto obejrzy kod
strony albo wywoła API ręcznie, dostanie wyłącznie własne wiersze.

## Funkcje
- Pracownik: kalendarz miesiąca, prośba na dzień (Dzień / Noc / K / Wolne / Urlop / Opieka) + komentarz,
  podgląd własnych zmian w grafiku, zmiana hasła.
- Administrator: tabela próśb wszystkich, edytowalny grafik z kontrolą obsady (4 lub 3+K w dzień, 2–3 w nocy),
  błędów Noc → Dzień i >5 dni pracy z rzędu, wstawianie próśb do pustych pól, eksport CSV,
  zamykanie/otwieranie próśb na miesiąc, nadawanie nowego hasła pracownikowi.
