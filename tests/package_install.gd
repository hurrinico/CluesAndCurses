extends SceneTree

## Prova dell'installazione dei pacchetti .cccase (C&C Engine).
## Uso: godot --headless --path <progetto> -s res://tests/package_install.gd -- <cartella dei pacchetti di prova>
## La cartella contiene case_demo-1.0.0.cccase (buono) e bad/*.cccase (manomessi),
## e il file hashes.json con l'impronta "di catalogo" di ognuno.

var fails := 0

func check(cond: bool, msg: String) -> void:
	print(("  OK   " if cond else "  FAIL ") + msg)
	if not cond:
		fails += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var dir: String = OS.get_cmdline_user_args()[0]
	var hashes = JSON.parse_string(FileAccess.get_file_as_string(dir.path_join("hashes.json")))
	var good := dir.path_join("case_demo-1.0.0.cccase")

	print("== Pacchetto buono")
	var r := PackageInstaller.install(good, "0".repeat(64))
	check(r.get("error", "") == "hash", "impronta diversa dal catalogo: rifiutato (%s)" % r.get("detail", ""))
	var t0 := Time.get_ticks_usec()
	r = PackageInstaller.install(good, hashes["case_demo-1.0.0.cccase"])
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(r.is_empty(), "installato in %.1f ms %s" % [ms, str(r)])
	var path := PackageInstaller.case_json_path("case_demo", "1.0.0")
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(data is Dictionary and data["case_id"] == "case_demo", "case.json leggibile da " + path)
	check(not data.has("truth"), "la verità del caso non è nel pacchetto")
	var case_dir := path.get_base_dir()
	var tex := PackageInstaller.resolve_texture(data["characters"]["orla"]["portraits"]["neutral"], case_dir)
	check(tex != null and tex.get_size() == Vector2(160, 200), "ritratto case:// caricato dal pacchetto: %s" % str(tex.get_size() if tex else null))
	var bg := PackageInstaller.resolve_texture(data["backgrounds"]["moli"], case_dir)
	check(bg != null and bg.get_size() == Vector2(360, 640), "sfondo case:// caricato dal pacchetto")
	var core := PackageInstaller.resolve_texture(data["characters"]["alaric"]["portraits"]["neutral"], case_dir)
	check(core != null and core.get_size() == Vector2(160, 200), "ritratto core:// risolto sulle risorse del gioco")
	r = PackageInstaller.install(good, hashes["case_demo-1.0.0.cccase"])
	check(r.is_empty() and FileAccess.file_exists(path), "reinstallazione della stessa versione")
	check(not DirAccess.dir_exists_absolute(path.get_base_dir() + ".tmp"), "nessuna cartella temporanea rimasta")

	print("== Pacchetti manomessi (impronta del file stesso, come se il catalogo fosse d'accordo)")
	var expect := {"slip.cccase": "path", "tampered.cccase": "hash", "newer.cccase": "version", "script.cccase": "path"}
	for name in expect:
		var res := PackageInstaller.install(dir.path_join("bad").path_join(name), hashes[name])
		check(res.get("error", "") == expect[name], "%s rifiutato con '%s': %s" % [name, res.get("error", "-"), res.get("detail", "")])
	check(not FileAccess.file_exists("user://evil.json") and not FileAccess.file_exists("user://cases/evil.json"), "nessun file scritto fuori dalla cartella dei casi")

	print("== Versioni")
	check(PackageInstaller.compare_versions("0.3.0", "0.3.0") == 0, "0.3.0 = 0.3.0")
	check(PackageInstaller.compare_versions("0.10.0", "0.9.9") == 1, "0.10.0 > 0.9.9 (confronto numerico, non alfabetico)")
	check(PackageInstaller.compare_versions("1.0.0", "1.0.1") == -1, "1.0.0 < 1.0.1")

	print("\nRISULTATO: ", "TUTTO OK" if fails == 0 else "%d FALLIMENTI" % fails)
	quit(fails)
