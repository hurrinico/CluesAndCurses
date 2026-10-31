#!/bin/sh
# Esporta Clues & Curses per il web e prepara due cartelle (GDD #07: browser game).
# Uso: GODOT=/percorso/godot ./build_web.sh
#
#   build/web_release/  -> da pubblicare su un hosting statico (Cloudflare Pages, Netlify,
#                          GitHub Pages, itch.io). È una PWA: installabile sulla schermata Home,
#                          a tutto schermo e in verticale, con pagina offline. Contiene _headers
#                          (Cloudflare Pages / Netlify) con tipi e cache corretti.
#   build/web_dist/     -> versione "impacchettata" per l'artifact di Claude: i binari hanno
#                          estensione .wasm (gli unici accettati, max 15 MB a file), il motore è
#                          compresso con gzip e decompresso nel browser. Niente PWA.
set -e
GODOT=${GODOT:-godot}
rm -rf build/web build/web_dist build/web_release
mkdir -p build/web build/web_dist build/web_release
"$GODOT" --headless --path . --export-release "Web" build/web/index.html

# --- Versione per l'hosting (PWA) ---
cp -R build/web/. build/web_release/
cp assets/title/logo_cc.png build/web_release/logo.png
# Cloudflare accetta file fino a 25 MiB: il motore (~35 MB) viaggia compresso (~8 MB)
# e lo decomprime il browser (shell.html, CC_ENGINE_GZ).
gzip -9 -c build/web_release/index.wasm > build/web_release/engine.gz.wasm
rm build/web_release/index.wasm
# Accesso (Supabase Auth): pannello HTML, libreria supabase-js inclusa (nessun CDN: funziona offline
# e la versione non cambia da sola) e configurazione presa dalle variabili d'ambiente:
#   CC_SUPABASE_URL, CC_SUPABASE_ANON_KEY, CC_AUTH_PROVIDERS ("google,apple")
# Senza URL e chiave l'accesso resta nascosto e il gioco è solo locale.
cp web/auth/ccauth.js web/auth/ccauth.css build/web_release/
cp web/auth/vendor/supabase-2.117.2.js build/web_release/supabase.js
cp assets/fonts/PixelifySans-Regular.ttf build/web_release/
python3 - <<'PY'
import json, os
cfg = {"supabaseUrl": os.environ.get("CC_SUPABASE_URL", ""),
       "supabaseAnonKey": os.environ.get("CC_SUPABASE_ANON_KEY", ""),
       "providers": [p.strip() for p in os.environ.get("CC_AUTH_PROVIDERS", "google").split(",") if p.strip()]}
open("build/web_release/cc.config.js", "w").write("window.CC_CONFIG = %s;\n" % json.dumps(cfg, indent=1))
print("accesso:", "configurato (%s)" % cfg["supabaseUrl"] if cfg["supabaseUrl"] else "non configurato, gioco solo locale")
PY
python3 - <<'PY'
import json, os, re
d = 'build/web_release'
sw_path = os.path.join(d, 'index.service.worker.js')
if os.path.exists(sw_path):
    sw = open(sw_path).read()
    # Godot 4.3 elenca index.worker.js anche senza thread: un file mancante fa fallire
    # l'installazione del service worker. Teniamo solo i file che esistono davvero.
    m = re.search(r'const CACHED_FILES = (\[.*?\]);', sw)
    files = [f for f in json.loads(m.group(1)) if os.path.exists(os.path.join(d, f))]
    files.append('logo.png')
    files += ['cc.config.js', 'supabase.js', 'ccauth.js', 'ccauth.css', 'PixelifySans-Regular.ttf']
    sw = sw.replace(m.group(0), 'const CACHED_FILES = %s;' % json.dumps(files))
    # il motore si chiama engine.gz.wasm: anche la cache offline deve conoscerlo
    m = re.search(r'const CACHABLE_FILES = (\[.*?\]);', sw)
    cachable = [('engine.gz.wasm' if f == 'index.wasm' else f) for f in json.loads(m.group(1))]
    sw = sw.replace(m.group(0), 'const CACHABLE_FILES = %s;' % json.dumps(cachable))
    for f in files + cachable:
        assert os.path.exists(os.path.join(d, f)), 'il service worker elenca un file assente: ' + f
    open(sw_path, 'w').write(sw)
html_path = os.path.join(d, 'index.html')
h = open(html_path).read()
h = h.replace('<script>\n// Versione "impacchettata"', '<script>window.CC_ENGINE_GZ = true;</script>\n<script>\n// Versione "impacchettata"', 1)
assert 'CC_ENGINE_GZ = true' in h, 'shell.html: punto di inserimento non trovato'
assert '<!--CC_AUTH-->' in h, 'shell.html: manca il segnaposto dell accesso'
h = h.replace('<!--CC_AUTH-->', '<link rel="stylesheet" href="ccauth.css">\n'
              '<script src="cc.config.js"></script>\n<script defer src="supabase.js"></script>\n'
              '<script defer src="ccauth.js"></script>', 1)
open(html_path, 'w').write(h)
big = [f for f in os.listdir(d) if os.path.getsize(os.path.join(d, f)) > 25 * 1024 * 1024]
assert not big, 'file oltre 25 MiB, Cloudflare li rifiuterebbe: %s' % big
man_path = os.path.join(d, 'index.manifest.json')
if os.path.exists(man_path):
    man = json.load(open(man_path))
    man.update({"name": "Clues & Curses", "short_name": "Clues&Curses", "lang": "it", "theme_color": "#0b0a12",
                "description": "Casi misteriosi a Oakhaven, risolti a colpi di enigmi."})
    for icon in man.get("icons", []):
        icon["purpose"] = "any maskable"
    json.dump(man, open(man_path, 'w'), indent=1)
open(os.path.join(d, '_headers'), 'w').write("""/*
  X-Content-Type-Options: nosniff
/*.wasm
  Content-Type: application/wasm
  Cache-Control: public, max-age=86400
/*.pck
  Content-Type: application/octet-stream
  Cache-Control: public, max-age=86400
/index.html
  Cache-Control: no-cache
/index.service.worker.js
  Cache-Control: no-cache
/cc.config.js
  Cache-Control: no-cache
""")
PY

# --- Versione per l'artifact di Claude ---
cd build/web
gzip -9 -c index.wasm > ../web_dist/engine.gz.wasm      # ~35 MB -> ~8 MB
cp index.pck ../web_dist/game.pck.wasm
cp index.html index.js index.audio.worklet.js ../web_dist/
cp ../../assets/title/logo_cc.png ../web_dist/logo.png
cd ../web_dist
python3 - <<'PY'
import re
s = open('index.html').read()
# Niente PWA nell'artifact: via manifest e icone, e attiva il caricamento "impacchettato"
s = re.sub(r'<link[^>]*(manifest|icon)[^>]*>\s*', '', s)
s = s.replace('<script>\n// Versione "impacchettata"', '<script>window.CC_PACKED = true;</script>\n<script>\n// Versione "impacchettata"', 1)
open('index.html', 'w').write(s)
a = re.sub(r'<!DOCTYPE html>\s*<html lang="it">\s*<head>\s*<meta charset="utf-8">\s*', '', s)
a = a.replace('</head>\n<body>\n', '').replace('</body>\n</html>', '')
open('artifact.html', 'w').write(a)
PY
ls -la
cd ../web_release && ls -la

# --- Cartella pronta per Cloudflare (Workers con risorse statiche) ---
cd ../..
rm -rf build/cloudflare && mkdir -p build/cloudflare
cp -R build/web_release build/cloudflare/public
cat > build/cloudflare/wrangler.jsonc <<'JSON'
{
  // Clues & Curses su Cloudflare Workers, solo file statici (nessun codice sul server).
  // Pubblicazione: npx wrangler deploy   (dalla cartella che contiene questo file)
  "name": "clues-and-curses",
  "compatibility_date": "2026-10-01",
  "assets": {
    "directory": "./public",
    "not_found_handling": "404-page"
  }
}
JSON
cp web/offline.html build/cloudflare/public/404.html
