-- Schemat bazy grafiku (Supabase / PostgreSQL, projekt "grafik-neurologia").
-- Konta pracowników zakładane są osobno (auth.users) i łączone przez pracownicy.user_id.
-- Dane osobowe (e-maile, hasła) NIE są przechowywane w repozytorium.

create extension if not exists pgcrypto with schema extensions;

create table public.pracownicy (
  id smallint primary key,
  nazwisko text not null,
  etat numeric(3,2) not null default 1,
  user_id uuid unique references auth.users(id) on delete set null,
  is_admin boolean not null default false
);

create table public.miesiace (
  miesiac date primary key check (extract(day from miesiac) = 1),
  prosby_otwarte boolean not null default true
);

create table public.prosby (
  pracownik_id smallint not null references public.pracownicy(id) on delete cascade,
  dzien date not null,
  wartosc text check (wartosc in ('Dzień','Noc','Wolne','Urlop','Opieka','K')),
  komentarz text check (char_length(komentarz) <= 300),
  updated_at timestamptz not null default now(),
  primary key (pracownik_id, dzien),
  check (wartosc is not null or komentarz is not null)
);

create table public.grafik (
  pracownik_id smallint not null references public.pracownicy(id) on delete cascade,
  dzien date not null,
  wartosc text not null check (wartosc in ('Dzień','Noc','Wolne','Urlop','Opieka','K')),
  primary key (pracownik_id, dzien)
);

create or replace function public.moje_id() returns smallint
language sql stable security definer set search_path = '' as $$
  select id from public.pracownicy where user_id = auth.uid()
$$;

create or replace function public.jestem_adminem() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select is_admin from public.pracownicy where user_id = auth.uid()), false)
$$;

create or replace function public.miesiac_otwarty(d date) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select prosby_otwarte from public.miesiace where miesiac = date_trunc('month', d)::date), false)
$$;

revoke execute on function public.moje_id(), public.jestem_adminem(), public.miesiac_otwarty(date) from public, anon;
grant execute on function public.moje_id(), public.jestem_adminem(), public.miesiac_otwarty(date) to authenticated;

alter table public.pracownicy enable row level security;
alter table public.miesiace  enable row level security;
alter table public.prosby    enable row level security;
alter table public.grafik    enable row level security;

revoke all on public.pracownicy, public.miesiace, public.prosby, public.grafik from anon;

-- pracownicy: każdy widzi tylko siebie, admin wszystkich
create policy pracownicy_select on public.pracownicy for select to authenticated
  using (user_id = (select auth.uid()) or (select public.jestem_adminem()));

-- miesiące: status widzą wszyscy zalogowani, zmienia admin
create policy miesiace_select on public.miesiace for select to authenticated using (true);
create policy miesiace_admin on public.miesiace for all to authenticated
  using ((select public.jestem_adminem())) with check ((select public.jestem_adminem()));

-- prośby: tylko własne (i tylko w otwartym miesiącu); admin widzi i poprawia wszystkie
create policy prosby_select on public.prosby for select to authenticated
  using (pracownik_id = (select public.moje_id()) or (select public.jestem_adminem()));
create policy prosby_insert on public.prosby for insert to authenticated
  with check ((select public.jestem_adminem())
    or (pracownik_id = (select public.moje_id()) and public.miesiac_otwarty(dzien)));
create policy prosby_update on public.prosby for update to authenticated
  using ((select public.jestem_adminem())
    or (pracownik_id = (select public.moje_id()) and public.miesiac_otwarty(dzien)))
  with check ((select public.jestem_adminem())
    or (pracownik_id = (select public.moje_id()) and public.miesiac_otwarty(dzien)));
create policy prosby_delete on public.prosby for delete to authenticated
  using ((select public.jestem_adminem())
    or (pracownik_id = (select public.moje_id()) and public.miesiac_otwarty(dzien)));

-- grafik: pracownik widzi tylko swój wiersz, pisze tylko admin
create policy grafik_select on public.grafik for select to authenticated
  using (pracownik_id = (select public.moje_id()) or (select public.jestem_adminem()));
create policy grafik_admin on public.grafik for all to authenticated
  using ((select public.jestem_adminem())) with check ((select public.jestem_adminem()));

-- admin może nadać nowe hasło pracownikowi (gdy ktoś zapomni)
create or replace function public.admin_resetuj_haslo(p_pracownik smallint, p_haslo text)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid;
begin
  if not public.jestem_adminem() then raise exception 'Brak uprawnień'; end if;
  if char_length(p_haslo) < 8 then raise exception 'Hasło musi mieć min. 8 znaków'; end if;
  select user_id into uid from public.pracownicy where id = p_pracownik;
  if uid is null then raise exception 'Pracownik nie ma konta'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_haslo, extensions.gen_salt('bf')),
    updated_at = now() where id = uid;
end $$;
revoke execute on function public.admin_resetuj_haslo(smallint, text) from public, anon;
grant execute on function public.admin_resetuj_haslo(smallint, text) to authenticated;

insert into public.miesiace (miesiac)
select generate_series('2027-01-01'::date, '2027-12-01'::date, interval '1 month')::date;

-- ===== Synchronizacja z Arkuszem Google (Apps Script: apps-script.gs) =====
-- Token przechowywany jako skrót SHA-256 w schemacie niedostępnym przez API.
create schema if not exists prywatne;
revoke all on schema prywatne from public, anon, authenticated;
create table prywatne.sync_token (id int primary key default 1 check (id = 1), hash text not null);
-- insert into prywatne.sync_token (hash) values (encode(extensions.digest('<TOKEN>', 'sha256'), 'hex'));

create or replace function prywatne.sprawdz_token(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_token is null or not exists (select 1 from prywatne.sync_token
     where hash = encode(extensions.digest(p_token, 'sha256'), 'hex')) then
    raise exception 'Nieprawidłowy token synchronizacji';
  end if;
end $$;

create or replace function public.sync_prosby(p_token text)
returns table (nazwisko text, dzien date, wartosc text, komentarz text, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  perform prywatne.sprawdz_token(p_token);
  return query select p.nazwisko, r.dzien, r.wartosc, r.komentarz, r.updated_at
    from public.prosby r join public.pracownicy p on p.id = r.pracownik_id
    order by r.dzien, p.nazwisko;
end $$;

create or replace function public.sync_grafik(p_token text, p_od date, p_do date, p_wiersze jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  perform prywatne.sprawdz_token(p_token);
  if p_do < p_od or p_do - p_od > 31 then raise exception 'Zły zakres dat'; end if;
  delete from public.grafik where dzien between p_od and p_do;
  insert into public.grafik (pracownik_id, dzien, wartosc)
  select p.id, (w->>'d')::date, w->>'v'
  from jsonb_array_elements(p_wiersze) w
  join public.pracownicy p on lower(trim(p.nazwisko)) = lower(trim(w->>'n'))
  where (w->>'d')::date between p_od and p_do
    and w->>'v' in ('Dzień','Noc','Wolne','Urlop','Opieka','K')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.sync_prosby(text), public.sync_grafik(text, date, date, jsonb) from public;
grant execute on function public.sync_prosby(text), public.sync_grafik(text, date, date, jsonb) to anon, authenticated;
