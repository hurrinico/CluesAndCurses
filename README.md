# Clues & Curses (C&C) - progetto Godot

Prototipo giocabile con due casi completi: schermata iniziale, Tavolo delle Mappe,
Caso #01 "L'Ultimo Calice di Mastro Aldous" e Caso #02 "Sangue di Pietra sui Moli".
Tre tipi di enigma: **Picross** (con Nebbia Arcanica), **Sigillo Runico** (sudoku con rune)
e **Cime Aggrovigliate** (frecce che scivolano fuori). Pensato come browser game adattivo
(telefono, tablet, PC). Nome precedente: RuneNoir.

## Avvio
1. Godot **4.3 o successivo** (va bene anche la 4.7: alla prima apertura converte il progetto).
2. Project Manager → **Importa** → seleziona `project.godot`. Al primo avvio Godot importa
   le immagini e crea la cartella `.godot/` (cache, non va salvata).
3. **F5**: parte `scenes/TitleScreen.tscn` → Tavolo delle Mappe → caso.
   Con **F6** si avviano da sole `PuzzleTest.tscn` (Picross del Caso #01),
   `RuneSudokuScene.tscn` (Sigillo del Caso #01) e `ArrowScene.tscn` (gaffa del Caso #02).

Risoluzione di base 360x640, si allarga su telefoni lunghi e tablet. Finestra di test 450x800.
Per azzerare i progressi: cancellare `cc_save.json` dalla cartella dati utente
(Progetto → Apri cartella dati utente; nel browser: dati del sito).

## Struttura
```
project.godot, export_presets.cfg, build_web.sh
scripts/   PicrossCore, PicrossGridUI, RuneSudokuCore, RuneGridUI, ArrowCore, ArrowGridUI,
           PuzzleSceneBase, CaseLoader, PackageInstaller,
           SaveManager e AuthService (Autoload)
scenes/    TitleScreen, CaseSelect, CaseScene, PuzzleTest, RuneSudokuScene, ArrowScene (.tscn + .gd)
data/      cases/case_01.json, case_02.json   (tutti i testi: la storia si cambia senza toccare il codice)
assets/    portraits/ (case02/), backgrounds/, clues/, ui/ (anche app_icon_*), tiles/ (runes/),
           title/ (title_bg.png, logo_cc.png), fonts/ (Pixelify Sans, Jacquard 24, licenza SIL OFL)
web/       shell.html, offline.html, auth/ccauth.js + ccauth.css, auth/vendor/supabase-2.117.2.js
tools/     validate_cases.py, clean_assets.py + assets_manifest.json, make_tiles.py, make_title_bg.py,
           make_logo.py, make_app_icon.py, rename_to_cc.py, palette CluesAndCurses.gpl / .hex
tests/     package_install.gd, tests_web_auth_e2e.js
```

## Rigenerare gli asset
```
python3 tools/make_tiles.py assets/tiles             # celle, icone, rune in 4 stati
python3 tools/make_title_bg.py assets/title          # sfondo della schermata iniziale
python3 tools/make_logo.py assets/fonts assets/title # logo "Clues & Curses"
python3 tools/make_app_icon.py assets/ui             # icone dell'app e della PWA
python3 tools/clean_assets.py batch tools/assets_manifest.json   # immagini Gemini -> pixel art
                                                     #  (originali in tools/raw/, risultati in tools/out/)
python3 tools/validate_cases.py -v data/cases/        # ogni enigma risolvibile per sola logica
```
Serve Python 3 con Pillow e NumPy (`pip install pillow numpy`).

## Versione web
`GODOT=/percorso/godot ./build_web.sh` (servono i template di esportazione Web della stessa
versione di Godot). Produce:
- `build/web_release/` — da pubblicare su un hosting statico; è una PWA installabile;
- `build/cloudflare/` — pronta per `npx wrangler deploy` (worker `clues-and-curses`);
- `build/web_dist/` — versione impacchettata per gli artifact di Claude.

Accesso con Supabase (facoltativo): variabili `CC_SUPABASE_URL`, `CC_SUPABASE_ANON_KEY`,
`CC_AUTH_PROVIDERS` ("google,apple"). Senza, il gioco resta solo locale e il pulsante di accesso non compare.

## Non incluso qui
- Il backend per i creatori (C&C Engine: schema dei casi v2, database, strumenti) resta nel Project di Claude.
- I test GDScript completi (run_tests, scene_smoke, puzzle_scenes, case_flow) sono nel Project
  con il vecchio schema di cartelle: da riportare in `tests/` quando servono.
