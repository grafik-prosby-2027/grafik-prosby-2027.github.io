/**
 * Synchronizacja: Arkusz Google „Grafik 2027” <-> aplikacja z prośbami (Supabase).
 *
 *  - grafik z arkuszy miesięcznych  -> aplikacja (każdy pracownik widzi tam swoje zmiany),
 *  - prośby z aplikacji             -> zakładka „Prośby z aplikacji” + notatki w komórkach grafiku.
 *
 * Instalacja: Rozszerzenia -> Apps Script, wklej ten plik, wpisz TOKEN, zapisz,
 * uruchom funkcję `instaluj` (raz, zaakceptuj uprawnienia). Potem działa samo co 5 minut,
 * a w arkuszu pojawia się menu „Grafik” -> „Synchronizuj teraz”.
 *
 * UWAGA: TOKEN daje dostęp do próśb wszystkich pracowników. Nie udostępniaj tego arkusza
 * do edycji osobom, które nie powinny ich widzieć.
 */
const SB_URL = 'https://egcawtzhydvadzmhfldj.supabase.co';
const SB_KEY = 'sb_publishable_smKCj8aeeKuPBO8Ynj7wGA_lPPx0oXO';
const TOKEN  = 'WKLEJ_TUTAJ_TOKEN';

const WIERSZ_DAT = 4;          // wiersz z datami (C4:AG4)
const PIERWSZY_PRAC = 6;       // pierwszy wiersz pracownika
const OSTATNI_PRAC = 19;       // ostatni wiersz pracownika
const KOL_DNI = 3;             // kolumna C = 1. dzień
const DOZWOLONE = ['Dzień', 'Noc', 'Wolne', 'Urlop', 'Opieka', 'K'];
const ARKUSZ_PROSB = 'Prośby z aplikacji';

function onOpen() {
  SpreadsheetApp.getUi().createMenu('Grafik')
    .addItem('Synchronizuj teraz', 'synchronizuj')
    .addToUi();
}

function instaluj() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'synchronizuj')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('synchronizuj').timeBased().everyMinutes(5).create();
  synchronizuj();
}

function rpc_(nazwa, dane) {
  const res = UrlFetchApp.fetch(SB_URL + '/rest/v1/rpc/' + nazwa, {
    method: 'post',
    contentType: 'application/json',
    headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY },
    payload: JSON.stringify(Object.assign({ p_token: TOKEN }, dane)),
    muteHttpExceptions: true,
  });
  if (res.getResponseCode() >= 300) throw new Error(nazwa + ': ' + res.getContentText());
  return JSON.parse(res.getContentText());
}

const iso_ = d => Utilities.formatDate(d, 'Europe/Warsaw', 'yyyy-MM-dd');

/** Zwraca arkusze miesięczne: [{arkusz, daty:[{kol, iso}], od, do}] */
function miesiace_() {
  const wynik = [];
  SpreadsheetApp.getActive().getSheets().forEach(sh => {
    if (sh.getLastColumn() < KOL_DNI) return;
    const wiersz = sh.getRange(WIERSZ_DAT, KOL_DNI, 1, 31).getValues()[0];
    const daty = [];
    wiersz.forEach((v, i) => { if (v instanceof Date) daty.push({ kol: KOL_DNI + i, iso: iso_(v) }); });
    if (daty.length >= 28) wynik.push({ arkusz: sh, daty, od: daty[0].iso, do: daty[daty.length - 1].iso });
  });
  return wynik;
}

function synchronizuj() {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) return;
  try {
    const mies = miesiace_();
    const n = OSTATNI_PRAC - PIERWSZY_PRAC + 1;

    // 1) grafik z arkusza -> aplikacja
    mies.forEach(m => {
      const zakres = m.arkusz.getRange(PIERWSZY_PRAC, 1, n, KOL_DNI + 30).getValues();
      const wiersze = [];
      zakres.forEach(r => {
        const nazw = String(r[0] || '').trim();
        if (!nazw) return;
        m.daty.forEach(d => {
          const v = String(r[d.kol - 1] || '').trim();
          if (DOZWOLONE.indexOf(v) >= 0) wiersze.push({ n: nazw, d: d.iso, v: v });
        });
      });
      rpc_('sync_grafik', { p_od: m.od, p_do: m.do, p_wiersze: wiersze });
    });

    // 2) prośby z aplikacji -> arkusz
    const prosby = rpc_('sync_prosby', {});
    const ss = SpreadsheetApp.getActive();
    let sh = ss.getSheetByName(ARKUSZ_PROSB) || ss.insertSheet(ARKUSZ_PROSB);
    sh.clearContents();
    const tab = [['Pracownik', 'Data', 'Prośba', 'Komentarz', 'Zmieniono']];
    prosby.forEach(p => tab.push([p.nazwisko, p.dzien, p.wartosc || '', p.komentarz || '',
      Utilities.formatDate(new Date(p.updated_at), 'Europe/Warsaw', 'yyyy-MM-dd HH:mm')]));
    sh.getRange(1, 1, tab.length, 5).setValues(tab);
    sh.getRange(1, 1, 1, 5).setFontWeight('bold');
    sh.setFrozenRows(1);
    sh.getRange(1, 7).setValue('Ostatnia synchronizacja: ' +
      Utilities.formatDate(new Date(), 'Europe/Warsaw', 'yyyy-MM-dd HH:mm'));

    // notatki z prośbami w komórkach grafiku (najedź na komórkę, aby zobaczyć)
    const mapa = {};
    prosby.forEach(p => { mapa[String(p.nazwisko).trim().toLowerCase() + '|' + p.dzien] =
      'Prośba: ' + (p.wartosc || '—') + (p.komentarz ? '\n' + p.komentarz : ''); });
    mies.forEach(m => {
      const nazwiska = m.arkusz.getRange(PIERWSZY_PRAC, 1, n, 1).getValues();
      const notatki = nazwiska.map(r => {
        const nazw = String(r[0] || '').trim().toLowerCase();
        const wiersz = new Array(31).fill('');
        m.daty.forEach(d => { wiersz[d.kol - KOL_DNI] = mapa[nazw + '|' + d.iso] || ''; });
        return wiersz;
      });
      m.arkusz.getRange(PIERWSZY_PRAC, KOL_DNI, n, 31).setNotes(notatki);
    });
  } finally {
    lock.releaseLock();
  }
}
