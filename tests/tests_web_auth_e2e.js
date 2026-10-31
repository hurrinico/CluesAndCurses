// Prova dell'accesso nel browser vero (Chromium + Playwright) contro il Supabase finto
// (engine/db/fake_supabase.py su :54321, Postgres con schema vero) e la build web su :8765.
// Uso: node auth_e2e.js <dsn postgres> <cartella screenshot>
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');

const GAME = 'http://127.0.0.1:8765/index.html';
const API = 'http://127.0.0.1:54321';
const DSN = process.argv[2];
const SHOTS = process.argv[3] || '.';
let fails = 0;
const check = (cond, msg) => { console.log((cond ? '  OK   ' : '  FAIL ') + msg); if (!cond) fails++; };
const sqlq = (q) => execFileSync('psql', [DSN, '-At', '-c', q]).toString().trim();

(async () => {
  const browser = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, hasTouch: false });
  const page = await ctx.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));
  page.on('pageerror', (e) => logs.push('pageerror: ' + e.message));
  const waitLog = async (re, ms = 20000) => {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const hit = logs.find((l) => re.test(l));
      if (hit) return hit;
      await page.waitForTimeout(150);
    }
    return null;
  };
  const clearLogs = () => logs.splice(0, logs.length);
  const panelText = () => page.locator('.ra-box').innerText();
  const status = async () => (await page.locator('.ra-status').innerText()).trim();

  console.log('== Avvio');
  await page.goto(GAME);
  check(!!(await waitLog(/\[AuthService\] ospite/, 30000)), 'il gioco parte da ospite e vede il servizio di accesso');

  // nella mappa dei casi compare il pulsante di accesso (verifica visiva)
  await page.waitForTimeout(4500);
  const canvas = page.locator('#canvas');
  await canvas.click({ position: { x: 195, y: 600 } });   // salta l'introduzione
  await page.waitForTimeout(400);
  await canvas.click({ position: { x: 195, y: 600 } });   // "Tocca per iniziare"
  await page.waitForTimeout(2000);
  await page.screenshot({ path: SHOTS + '/auth_01_mappa_ospite.png' });

  console.log('== Registrazione con email');
  await page.evaluate(() => CCAuth.open());
  await page.waitForSelector('.ra-box');
  check((await panelText()).includes('Continua con Google') && (await panelText()).includes('Continua con Apple'), 'pannello di accesso con Google e Apple');
  await page.screenshot({ path: SHOTS + '/auth_02_accesso.png' });
  await page.click('text=Crea un account');
  await page.fill('#ra-name', 'Nicola');
  await page.fill('#ra-email', 'nicola@test.it');
  await page.fill('#ra-password', 'corto');
  await page.fill('#ra-password2', 'corto');
  await page.click('.ra-primary');
  await page.waitForTimeout(300);
  check((await status()).startsWith('Password troppo debole'), 'password corta rifiutata prima di chiamare il server');
  await page.fill('#ra-password', 'inchiostro-42');
  await page.fill('#ra-password2', 'inchiostro-43');
  await page.click('.ra-primary');
  await page.waitForTimeout(300);
  check((await status()).includes('non coincidono'), 'password ripetuta diversa rifiutata');
  await page.fill('#ra-password2', 'inchiostro-42');
  clearLogs();
  await page.click('.ra-primary');
  check(!!(await waitLog(/dentro come Nicola \(email\)/)), 'registrato e dentro: Godot riceve il nome');
  check(!!(await waitLog(/sincronizzazione: push_local/)), 'primo accesso: il salvataggio locale va nel cloud');
  await page.waitForTimeout(1500);
  const uid = sqlq("select id from auth.users where email='nicola@test.it'");
  check(sqlq(`select display_name from profiles where id='${uid}'`) === 'Nicola', 'profilo creato con il nome scelto');
  check(sqlq(`select count(*) from cloud_saves where user_id='${uid}'`) === '1', 'salvataggio presente nel cloud');
  check(await page.locator('.ra-overlay').count() === 0, 'il pannello si chiude dopo la registrazione');
  await page.waitForTimeout(300);
  await page.screenshot({ path: SHOTS + '/auth_03_mappa_dentro.png' });

  console.log('== Sessione dopo una ricarica');
  clearLogs();
  await page.reload();
  check(!!(await waitLog(/dentro come Nicola/, 30000)), 'ricaricando la pagina si resta dentro');
  check(!!(await waitLog(/sincronizzazione: same/)), 'locale e cloud già allineati');

  console.log('== Profilo');
  await page.evaluate(() => CCAuth.open());
  await page.waitForSelector('#ra-name');
  check((await panelText()).includes('nicola@test.it'), 'il profilo mostra email e metodo di accesso');
  await page.screenshot({ path: SHOTS + '/auth_04_profilo.png' });
  await page.fill('#ra-name', 'Nicola M.');
  clearLogs();
  await page.click('text=Salva il nome');
  check(!!(await waitLog(/dentro come Nicola M\./)), 'nome cambiato: il gioco si aggiorna');
  check(sqlq(`select display_name from profiles where id='${uid}'`) === 'Nicola M.', 'nome salvato nel database');
  clearLogs();
  await page.click('text=Esci');
  check(!!(await waitLog(/\[AuthService\] ospite/)), 'uscita: di nuovo ospite');

  console.log('== Accesso con email');
  await page.evaluate(() => CCAuth.open());
  await page.fill('#ra-email', 'nicola@test.it');
  await page.fill('#ra-password', 'sbagliata-1');
  await page.click('.ra-primary');
  await page.waitForTimeout(800);
  check((await status()) === 'Email o password non corretti.', 'password sbagliata: messaggio in italiano');
  // il cloud è più recente del dispositivo: deve vincere il cloud
  sqlq(`update cloud_saves set data = jsonb_set(jsonb_set(data, '{saved_at}', '9999999999'), '{gold}', '999') where user_id='${uid}'`);
  await page.fill('#ra-password', 'inchiostro-42');
  clearLogs();
  await page.click('.ra-primary');
  check(!!(await waitLog(/dentro come Nicola M\./)), 'accesso con email e password');
  check(!!(await waitLog(/sincronizzazione: use_cloud/)), 'cloud più recente: i progressi arrivano dal cloud');
  await page.evaluate(() => CCAuth.open());
  await page.click('text=Esci');
  await waitLog(/ospite/);

  console.log('== Accesso con Google (provider simulato)');
  await page.evaluate(() => CCAuth.open());
  clearLogs();
  await page.click('.ra-google');
  check(!!(await waitLog(/dentro come Giulia Rossi \(google\)/, 30000)), 'ritorno da Google: dentro con il nome del provider');
  check(!page.url().includes('code='), 'il codice di ritorno sparisce dall\'indirizzo');
  await page.evaluate(() => CCAuth.open());
  check(!(await panelText()).includes('Cambia password'), 'con Google non si offre il cambio password');
  await page.click('text=Esci');
  await waitLog(/ospite/);

  console.log('== Password dimenticata');
  await page.evaluate(() => CCAuth.open());
  await page.click('text=Password dimenticata?');
  await page.fill('#ra-email', 'nicola@test.it');
  await page.click('.ra-primary');
  await page.waitForTimeout(800);
  check((await status()).startsWith('Se l\'indirizzo ha un account'), 'richiesta inviata, senza rivelare se l\'account esiste');
  const link = JSON.parse(execFileSync('curl', ['-s', API + '/__test/last_link']).toString()).url;
  check(link.includes('code='), 'link di recupero "inviato per email"');
  clearLogs();
  await page.goto(link);
  await page.waitForSelector('#ra-password', { timeout: 30000 });
  check((await panelText()).includes('Nuova password'), 'aprendo il link si sceglie la nuova password');
  await page.fill('#ra-password', 'nuovo-sigillo-7');
  await page.click('.ra-primary');
  await page.waitForTimeout(1500);
  await page.evaluate(() => CCAuth.open());
  await page.click('text=Esci');
  await waitLog(/ospite/);
  await page.evaluate(() => CCAuth.open());
  await page.fill('#ra-email', 'nicola@test.it');
  await page.fill('#ra-password', 'nuovo-sigillo-7');
  clearLogs();
  await page.click('.ra-primary');
  check(!!(await waitLog(/dentro come Nicola M\./)), 'accesso con la nuova password');

  console.log('== Cancellazione dell\'account');
  await page.evaluate(() => CCAuth.open());
  await page.click('text=Cancella l\'account');
  await page.fill('#ra-confirm', 'elimina');
  await page.click('.ra-primary');
  await page.waitForTimeout(300);
  check((await status()).includes('ELIMINA'), 'serve scrivere ELIMINA');
  await page.screenshot({ path: SHOTS + '/auth_05_cancella.png' });
  await page.fill('#ra-confirm', 'ELIMINA');
  clearLogs();
  await page.click('.ra-primary');
  check(!!(await waitLog(/\[AuthService\] ospite/)), 'account cancellato: di nuovo ospite');
  check(sqlq(`select count(*) from auth.users where id='${uid}'`) === '0' && sqlq(`select count(*) from cloud_saves where user_id='${uid}'`) === '0',
    'utente e salvataggi cancellati dal database');

  console.log('== Registrazione con conferma via email');
  execFileSync('curl', ['-s', API + '/__test/config?confirm=1']);
  await page.waitForTimeout(1000);
  await page.evaluate(() => CCAuth.open());
  await page.click('text=Crea un account');
  await page.fill('#ra-name', 'Vey');
  await page.fill('#ra-email', 'vey@test.it');
  await page.fill('#ra-password', 'pioggia-su-oakhaven');
  await page.fill('#ra-password2', 'pioggia-su-oakhaven');
  await page.click('.ra-primary');
  await page.waitForTimeout(1000);
  check((await panelText()).includes('Controlla la posta'), 'con la conferma attiva si chiede di aprire l\'email');
  await page.screenshot({ path: SHOTS + '/auth_06_conferma.png' });

  const errors = logs.filter((l) => /pageerror|Uncaught|SCRIPT ERROR/.test(l));
  check(errors.length === 0, 'nessun errore JavaScript o Godot' + (errors.length ? ': ' + errors.slice(0, 3).join(' | ') : ''));
  await browser.close();
  console.log('\nRISULTATO: ' + (fails === 0 ? 'TUTTO OK' : fails + ' FALLIMENTI'));
  process.exit(fails);
})().catch((e) => { console.error(e); process.exit(99); });
