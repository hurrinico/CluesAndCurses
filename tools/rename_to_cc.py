#!/usr/bin/env python3
"""
Clues & Curses (C&C) - migrazione dal vecchio nome RuneNoir.

Applica in un colpo solo, a tutto il progetto, la stessa tabella di sostituzioni:
nomi visibili, identificatori del codice, nomi di file. Prima mostra cosa cambierebbe,
poi (con --apply) scrive.

Uso:
  python3 tools/rename_to_cc.py <cartella del progetto>            # solo anteprima
  python3 tools/rename_to_cc.py <cartella del progetto> --apply    # applica

Cosa NON tocca: immagini e binari (tranne la rinomina dei file), la cartella .godot/
(cache dell'editor, si rigenera) e build/. Dopo la migrazione:
  - rigenerare il logo:  python3 tools/make_logo.py assets/fonts assets/title
  - i vecchi salvataggi (runenoir_save.json) non vengono più letti: è voluto.
"""
import argparse
import re
import sys
from pathlib import Path

# Ordine importante: prima le forme più specifiche.
TEXT_RULES = [
    # file e percorsi
    (r"logo_runenoir\.png", "logo_cc.png"),
    (r"runenoir_save", "cc_save"),          # .json, .tmp, .before_cloud.json
    (r"runenoir\.config\.js", "cc.config.js"),
    (r"web_auth_runeauth", "web_auth_ccauth"),
    (r"runeauth\.(js|css)", r"ccauth.\1"),
    (r"RuneNoir\.(gpl|hex)", r"CluesAndCurses.\1"),
    (r"build_rncase", "build_cccase"),
    (r"rncase/1", "cccase/1"),
    (r"\.rncase\b", ".cccase"),
    (r"runenoir\.app", "cluesandcurses.app"),
    # identificatori
    (r"RUNENOIR_", "CC_"),
    (r"<!--RUNENOIR_AUTH-->", "<!--CC_AUTH-->"),
    (r"\bRuneAuth\b", "CCAuth"),
    (r"'runenoir-auth'", "'cc-auth'"),
    (r'"name": "runenoir"', '"name": "clues-and-curses"'),
    # nomi visibili
    (r"RuneNoir Engine", "C&C Engine"),
    (r"RUNENOIR\b", "CLUES & CURSES"),
    (r"RuneNoir_GameDev", "CluesAndCurses_GameDev"),
    (r"\bRuneNoir\b", "Clues & Curses"),
]

FILE_RENAMES = [
    (re.compile(r"logo_runenoir\.png$"), "logo_cc.png"),
    (re.compile(r"web_auth_runeauth\.(js|css)$"), r"web_auth_ccauth.\1"),
    (re.compile(r"^runeauth\.(js|css)$"), r"ccauth.\1"),
    (re.compile(r"^RuneNoir\.(gpl|hex)$"), r"CluesAndCurses.\1"),
    (re.compile(r"^build_rncase\.py$"), "build_cccase.py"),
    (re.compile(r"\.rncase$"), ".cccase"),
]

TEXT_EXT = {".gd", ".py", ".js", ".css", ".html", ".sh", ".json", ".jsonc", ".md", ".sql",
            ".cfg", ".godot", ".tscn", ".tres", ".gpl", ".hex", ".txt", ".toml", ".yml", ".yaml"}
SKIP_DIRS = {".godot", ".git", "build", "node_modules", "__pycache__"}
SELF = Path(__file__).resolve()


def migrate_text(text: str) -> str:
    for pat, rep in TEXT_RULES:
        text = re.sub(pat, rep, text)
    return text


def iter_files(root: Path):
    for p in sorted(root.rglob("*")):
        if p.is_file() and not (set(p.relative_to(root).parts[:-1]) & SKIP_DIRS):
            yield p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()
    root = Path(a.root).resolve()
    if not root.is_dir():
        sys.exit(f"cartella non trovata: {root}")

    changed, renamed = 0, 0
    for p in list(iter_files(root)):
        if p.resolve() == SELF:
            continue
        if p.suffix in TEXT_EXT:
            try:
                old = p.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                old = None
            if old is not None:
                new = migrate_text(old)
                if new != old:
                    changed += 1
                    n = sum(1 for x, y in zip(old.splitlines(), new.splitlines()) if x != y)
                    print(f"modifica  {p.relative_to(root)}  ({n} righe)")
                    if a.apply:
                        p.write_text(new, encoding="utf-8")
        for pat, rep in FILE_RENAMES:
            if pat.search(p.name):
                dst = p.with_name(pat.sub(rep, p.name))
                renamed += 1
                print(f"rinomina  {p.relative_to(root)} -> {dst.name}")
                if a.apply:
                    if dst.exists():
                        sys.exit(f"esiste già: {dst}")
                    p.rename(dst)
                    imp = p.with_name(p.name + ".import")      # file .import di Godot
                    if imp.exists():
                        imp.rename(dst.with_name(dst.name + ".import"))
                break

    print(f"\n{changed} file da modificare, {renamed} da rinominare.")
    if not a.apply:
        print("Anteprima: niente è stato scritto. Rilancia con --apply per applicare.")
    else:
        print("Fatto. Riapri il progetto in Godot (reimporta le risorse rinominate) e rigenera il logo.")


if __name__ == "__main__":
    main()
