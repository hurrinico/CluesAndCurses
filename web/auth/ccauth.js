/*
 * Clues & Curses - accesso e profilo del giocatore (Supabase Auth).
 *
 * Il pannello è HTML sopra il gioco, non un'interfaccia Godot: così su telefono funzionano
 * la tastiera, il riempimento automatico e i gestori di password del sistema.
 *
 * Accesso con Google, Apple (se attivato nella configurazione) o email e password.
 * Il gioco resta giocabile da ospite: l'accesso serve a salvare i progressi nel cloud.
 *
 * Interfaccia per Godot (AuthService.gd, via JavaScriptBridge), tutto con stringhe JSON:
 *   CCAuth.available            true se la configurazione Supabase c'è
 *   CCAuth.state()              {"signed_in", "user_id", "email", "name", "provider", "providers"}
 *   CCAuth.onChange(cb)         cb(stateJson) a ogni cambio di stato
 *   CCAuth.open(view)           "login" | "profile" (o "" = quello giusto per lo stato)
 *   CCAuth.saveCloud(json)      salva (raggruppando le scritture ravvicinate) nel cloud
 *   CCAuth.loadCloud(cb)        cb('{"data": {...} | null, "updated_at": ...}') oppure cb('{"error": "..."}')
 *
 * Configurazione: window.CC_CONFIG = { supabaseUrl, supabaseAnonKey, providers: ["google", "apple"] }
 * (file cc.config.js scritto da build_web.sh). La chiave "anon" è pubblica per natura:
 * i permessi li decidono le regole RLS del database.
 */
(function () {
  'use strict';

  const CFG = window.CC_CONFIG || {};
  const OK = !!(CFG.supabaseUrl && CFG.supabaseAnonKey && window.supabase && window.supabase.createClient);
  const PROVIDERS = (CFG.providers || ['google']).filter((p) => p === 'google' || p === 'apple');
  const SAVE_SLOT = 0;
  const SAVE_DELAY_MS = 4000;      // il gioco salva spesso: verso il cloud si raggruppa
  const MIN_PASSWORD = 8;

  const ERRORS = {
    invalid_credentials: 'Email o password non corretti.',
    email_not_confirmed: 'Conferma prima l\'indirizzo email: controlla la posta (anche lo spam).',
    user_already_exists: 'Esiste già un account con questa email. Prova ad accedere.',
    email_exists: 'Esiste già un account con questa email. Prova ad accedere.',
    weak_password: 'Password troppo debole: almeno ' + MIN_PASSWORD + ' caratteri, meglio con numeri e simboli.',
    same_password: 'La nuova password è uguale a quella attuale.',
    over_email_send_rate_limit: 'Troppe email in poco tempo. Riprova tra qualche minuto.',
    over_request_rate_limit: 'Troppi tentativi. Riprova tra qualche minuto.',
    email_address_invalid: 'Indirizzo email non valido.',
    validation_failed: 'Controlla i dati inseriti.',
    signup_disabled: 'Le nuove registrazioni sono chiuse.',
    provider_disabled: 'Questo metodo di accesso non è attivo.',
    session_not_found: 'La sessione è scaduta: accedi di nuovo.',
  };

  let client = null;
  let session = null;
  let profileName = '';
  let listeners = [];
  let recovering = false;
  let saveTimer = null;
  let pendingSave = null;

  // ------------------------------------------------------------------ stato
  function provider() {
    const u = session && session.user;
    return (u && u.app_metadata && u.app_metadata.provider) || 'email';
  }

  function state() {
    const u = session && session.user;
    return {
      available: OK,
      signed_in: !!u,
      user_id: u ? u.id : '',
      email: u ? (u.email || '') : '',
      name: u ? (profileName || (u.user_metadata && (u.user_metadata.display_name || u.user_metadata.full_name)) || '') : '',
      provider: u ? provider() : '',
      providers: PROVIDERS.concat(['email']),
    };
  }

  function notify() {
    const s = JSON.stringify(state());
    listeners.forEach((cb) => { try { cb(s); } catch (e) { console.error('[CCAuth]', e); } });
    refreshPanel();
  }

  function message(err) {
    if (!err) return '';
    if (err.code && ERRORS[err.code]) return ERRORS[err.code];
    if (/fetch|network/i.test(err.message || '')) return 'Nessuna connessione con il server. Riprova.';
    return err.message || String(err);
  }

  async function loadProfile() {
    if (!session) { profileName = ''; return; }
    const { data, error } = await client.from('profiles').select('display_name').eq('id', session.user.id).maybeSingle();
    if (!error && data) profileName = data.display_name || '';
  }

  // ------------------------------------------------------------------ pannello
  let overlay = null;
  let view = 'login';
  let busy = false;

  function el(tag, attrs, children) {
    const n = document.createElement(tag);
    for (const k in (attrs || {})) {
      if (k === 'text') n.textContent = attrs[k];
      else if (k === 'on') for (const ev in attrs.on) n.addEventListener(ev, attrs.on[ev]);
      else n.setAttribute(k, attrs[k]);
    }
    (children || []).forEach((c) => c && n.appendChild(c));
    return n;
  }

  function field(id, label, type, autocomplete, value) {
    const input = el('input', { id: 'ra-' + id, type, autocomplete, required: '', spellcheck: 'false' });
    if (value) input.value = value;
    return el('label', { class: 'ra-field', for: 'ra-' + id }, [el('span', { text: label }), input]);
  }

  function val(id) {
    const n = document.getElementById('ra-' + id);
    return n ? n.value.trim() : '';
  }

  function status(text, kind) {
    const n = overlay && overlay.querySelector('.ra-status');
    if (!n) return;
    n.textContent = text || '';
    n.className = 'ra-status' + (kind ? ' ra-' + kind : '');
  }

  function link(text, to) {
    return el('button', { type: 'button', class: 'ra-link', text, on: { click: () => show(to) } });
  }

  function primary(text) {
    return el('button', { type: 'submit', class: 'ra-primary', text });
  }

  function form(onSubmit, children) {
    return el('form', { class: 'ra-form', novalidate: '', on: { submit: async (e) => {
      e.preventDefault();
      if (busy) return;
      busy = true;
      overlay.classList.add('ra-busy');
      status('Un momento…');
      try { await onSubmit(); } catch (err) { status(message(err), 'error'); }
      busy = false;
      if (overlay) overlay.classList.remove('ra-busy');
    } } }, children);
  }

  function oauthButtons() {
    return PROVIDERS.map((p) => el('button', {
      type: 'button', class: 'ra-oauth ra-' + p, 'data-provider': p,
      text: p === 'google' ? 'Continua con Google' : 'Continua con Apple',
      on: { click: async () => {
        status('Ti porto alla pagina di ' + (p === 'google' ? 'Google' : 'Apple') + '…');
        const { error } = await client.auth.signInWithOAuth({ provider: p, options: { redirectTo: returnUrl() } });
        if (error) status(message(error), 'error');
      } },
    }));
  }

  function returnUrl() {
    return location.origin + location.pathname;
  }

  const VIEWS = {
    login: () => [
      el('h2', { text: 'Accedi' }),
      el('p', { class: 'ra-lead', text: 'Salva le indagini nel cloud e riprendile da qualsiasi dispositivo.' }),
      ...oauthButtons(),
      el('div', { class: 'ra-sep', text: 'oppure con email' }),
      form(async () => {
        const { error } = await client.auth.signInWithPassword({ email: val('email'), password: document.getElementById('ra-password').value });
        if (error) throw error;
        close();
      }, [field('email', 'Email', 'email', 'email'), field('password', 'Password', 'password', 'current-password'), primary('Accedi')]),
      el('div', { class: 'ra-row' }, [link('Crea un account', 'signup'), link('Password dimenticata?', 'forgot')]),
    ],
    signup: () => [
      el('h2', { text: 'Nuovo Inquisitore' }),
      ...oauthButtons(),
      el('div', { class: 'ra-sep', text: 'oppure con email' }),
      form(async () => {
        const name = val('name');
        const password = document.getElementById('ra-password').value;
        if (!name) throw new Error('Scegli un nome da Inquisitore.');
        if (password.length < MIN_PASSWORD) throw { code: 'weak_password' };
        if (password !== document.getElementById('ra-password2').value) throw new Error('Le due password non coincidono.');
        const { data, error } = await client.auth.signUp({
          email: val('email'), password,
          options: { data: { display_name: name.slice(0, 60) }, emailRedirectTo: returnUrl() },
        });
        if (error) throw error;
        if (data.session) { close(); return; }
        show('check');
      }, [field('name', 'Nome da Inquisitore', 'text', 'nickname'), field('email', 'Email', 'email', 'email'),
          field('password', 'Password (almeno ' + MIN_PASSWORD + ' caratteri)', 'password', 'new-password'),
          field('password2', 'Ripeti la password', 'password', 'new-password'), primary('Crea l\'account')]),
      el('div', { class: 'ra-row' }, [link('Ho già un account', 'login')]),
    ],
    check: () => [
      el('h2', { text: 'Controlla la posta' }),
      el('p', { class: 'ra-lead', text: 'Ti abbiamo inviato un link per confermare l\'indirizzo. Aprilo da questo dispositivo e sarai dentro.' }),
      el('div', { class: 'ra-row' }, [link('Torna all\'accesso', 'login')]),
    ],
    forgot: () => [
      el('h2', { text: 'Password dimenticata' }),
      el('p', { class: 'ra-lead', text: 'Inserisci l\'email dell\'account: ti mandiamo un link per sceglierne una nuova.' }),
      form(async () => {
        const { error } = await client.auth.resetPasswordForEmail(val('email'), { redirectTo: returnUrl() });
        if (error) throw error;
        status('Se l\'indirizzo ha un account, il link è in arrivo. Aprilo da questo dispositivo.', 'ok');
      }, [field('email', 'Email', 'email', 'email'), primary('Invia il link')]),
      el('div', { class: 'ra-row' }, [link('Torna all\'accesso', 'login')]),
    ],
    newpass: () => [
      el('h2', { text: 'Nuova password' }),
      form(async () => {
        const password = document.getElementById('ra-password').value;
        if (password.length < MIN_PASSWORD) throw { code: 'weak_password' };
        const { error } = await client.auth.updateUser({ password });
        if (error) throw error;
        recovering = false;
        status('Password aggiornata.', 'ok');
        setTimeout(close, 900);
      }, [field('password', 'Nuova password', 'password', 'new-password'), primary('Salva')]),
    ],
    profile: () => {
      const s = state();
      const items = [
        el('h2', { text: 'Profilo' }),
        el('p', { class: 'ra-lead', text: (s.email || 'Account ' + s.provider) + ' · accesso con ' +
          ({ google: 'Google', apple: 'Apple', email: 'email' }[s.provider] || s.provider) }),
        form(async () => {
          const name = val('name');
          if (!name) throw new Error('Il nome non può essere vuoto.');
          const { error } = await client.from('profiles').update({ display_name: name.slice(0, 60) }).eq('id', s.user_id);
          if (error) throw error;
          profileName = name.slice(0, 60);
          notify();
          status('Nome salvato.', 'ok');
        }, [field('name', 'Nome da Inquisitore', 'text', 'nickname', s.name), primary('Salva il nome')]),
      ];
      if (s.provider === 'email') items.push(el('div', { class: 'ra-row' }, [link('Cambia password', 'newpass')]));
      items.push(
        el('button', { type: 'button', class: 'ra-secondary', text: 'Esci', on: { click: async () => {
          await flushSave();
          await client.auth.signOut();
          close();
        } } }),
        el('button', { type: 'button', class: 'ra-link ra-danger', text: 'Cancella l\'account', on: { click: () => show('delete') } }),
      );
      return items;
    },
    delete: () => [
      el('h2', { text: 'Cancella l\'account' }),
      el('p', { class: 'ra-lead', text: 'Profilo e salvataggi nel cloud vengono cancellati per sempre. I progressi su questo dispositivo restano. Scrivi ELIMINA per confermare.' }),
      form(async () => {
        if (val('confirm') !== 'ELIMINA') throw new Error('Scrivi ELIMINA in maiuscolo per confermare.');
        const { error } = await client.rpc('delete_my_account');
        if (error) throw error;
        await client.auth.signOut({ scope: 'local' });
        status('Account cancellato.', 'ok');
        setTimeout(close, 900);
      }, [field('confirm', 'Conferma', 'text', 'off'), primary('Cancella per sempre')]),
      el('div', { class: 'ra-row' }, [link('Annulla', 'profile')]),
    ],
  };

  function render() {
    if (!overlay) return;
    const box = overlay.querySelector('.ra-box');
    box.replaceChildren(
      el('button', { type: 'button', class: 'ra-close', 'aria-label': 'Chiudi', text: '×', on: { click: close } }),
      ...VIEWS[view](),
      el('p', { class: 'ra-status', role: 'status', 'aria-live': 'polite' }),
    );
    const first = box.querySelector('input');
    if (first && matchMedia('(pointer: fine)').matches) first.focus();
  }

  function show(v) {
    view = v;
    render();
  }

  function refreshPanel() {
    if (!overlay || busy) return;
    if (session && (view === 'login' || view === 'signup' || view === 'check')) show('profile');
    else if (!session && (view === 'profile' || view === 'delete')) show('login');
  }

  function open(v) {
    if (!OK) return;
    if (!v) v = recovering ? 'newpass' : (session ? 'profile' : 'login');
    if (!overlay) {
      overlay = el('div', { class: 'ra-overlay', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Account Clues & Curses',
        on: { click: (e) => { if (e.target === overlay) close(); }, keydown: (e) => { if (e.key === 'Escape') close(); } } },
        [el('div', { class: 'ra-box' })]);
      (document.getElementById('frame') || document.body).appendChild(overlay);
    }
    show(v);
  }

  function close() {
    if (overlay) { overlay.remove(); overlay = null; }
    const canvas = document.getElementById('canvas');
    if (canvas) canvas.focus();
  }

  // ------------------------------------------------------------------ salvataggi nel cloud
  async function writeSave(json) {
    if (!session) return;
    let data;
    try { data = JSON.parse(json); } catch (e) { console.error('[CCAuth] salvataggio non valido'); return; }
    const { error } = await client.from('cloud_saves').upsert(
      { user_id: session.user.id, slot: SAVE_SLOT, data, save_version: String(data.version || '') },
      { onConflict: 'user_id,slot' });
    if (error) console.warn('[CCAuth] salvataggio nel cloud non riuscito:', error.message);
  }

  function saveCloud(json) {
    if (!session) return;
    pendingSave = json;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(flushSave, SAVE_DELAY_MS);
  }

  async function flushSave() {
    clearTimeout(saveTimer);
    if (pendingSave === null) return;
    const json = pendingSave;
    pendingSave = null;
    await writeSave(json);
  }

  function loadCloud(cb) {
    if (!session) { cb(JSON.stringify({ error: 'not_signed_in' })); return; }
    client.from('cloud_saves').select('data, updated_at').eq('user_id', session.user.id).eq('slot', SAVE_SLOT).maybeSingle()
      .then(({ data, error }) => cb(JSON.stringify(error ? { error: message(error) } : { data: data ? data.data : null, updated_at: data ? data.updated_at : null })),
        (err) => cb(JSON.stringify({ error: message(err) })));
  }

  // scheda nascosta o chiusa: il salvataggio in sospeso parte subito
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flushSave(); });

  // ------------------------------------------------------------------ avvio
  if (OK) {
    client = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
      auth: { flowType: 'pkce', detectSessionInUrl: true, persistSession: true, autoRefreshToken: true, storageKey: 'cc-auth' },
    });
    client.auth.onAuthStateChange((event, s) => {
      session = s;
      if (event === 'PASSWORD_RECOVERY') { recovering = true; setTimeout(() => open('newpass'), 0); }
      // il codice di ritorno da Google/Apple o dall'email non deve restare nell'indirizzo
      if (/[?&](code|error)=/.test(location.search)) history.replaceState(null, '', returnUrl() + location.hash);
      // fuori dal callback: le chiamate al database dentro onAuthStateChange possono bloccarsi
      setTimeout(async () => { await loadProfile(); notify(); }, 0);
    });
    const err = new URLSearchParams(location.search).get('error_description');
    if (err) setTimeout(() => { open('login'); status('Accesso non riuscito: ' + err, 'error'); }, 0);
  }

  window.CCAuth = {
    available: OK,
    state: () => JSON.stringify(state()),
    onChange: (cb) => { listeners.push(cb); },
    open: (v) => open(v || ''),
    close,
    saveCloud,
    flushSave,
    loadCloud,
  };
})();
