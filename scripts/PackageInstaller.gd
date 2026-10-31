class_name PackageInstaller
extends RefCounted

## Installa un pacchetto .cccase nel gioco (C&C Engine, prototipo verificato del CatalogClient).
## Passi, tutti o nessuno:
##   1. impronta SHA-256 del file = quella del catalogo
##   2. lettura dello zip: nomi sicuri (niente "..", percorsi assoluti, barre rovesciate),
##      solo manifest.json, case.json e assets/*.png, limiti di numero e dimensione
##   3. manifest: formato, caso, impronta di ogni file
##   4. case.json: schema_version 2.x, min_game_version <= versione del gioco
##   5. scrittura in una cartella temporanea, poi rinomina atomica in user://cases/<case_id>/<version>
## Le immagini case:// si caricano poi con resolve_texture() (Image.load_from_file: in un gioco
## esportato le PNG non importate non passano da ResourceLoader).

const GAME_VERSION := "0.3.0"
const SCHEMA_MAJOR := 2
const ROOT := "user://cases"
const MAX_FILES := 200
const MAX_FILE_BYTES := 2 * 1024 * 1024
const MAX_TOTAL_BYTES := 8 * 1024 * 1024


## Restituisce {} se tutto va bene, altrimenti {"error": "<codice>", "detail": "..."}.
static func install(package_path: String, expected_sha256: String) -> Dictionary:
	var raw := FileAccess.get_file_as_bytes(package_path)
	if raw.is_empty():
		return _fail("read", "pacchetto illeggibile: " + package_path)
	if _sha256(raw) != expected_sha256.to_lower():
		return _fail("hash", "l'impronta del pacchetto non corrisponde al catalogo")

	var zip := ZIPReader.new()
	if zip.open(package_path) != OK:
		return _fail("zip", "il pacchetto non è uno zip valido")
	var names := zip.get_files()
	if names.size() > MAX_FILES:
		zip.close()
		return _fail("limits", "troppi file nel pacchetto: %d" % names.size())
	var contents := {}
	var total := 0
	for name in names:
		if not _safe_name(name):
			zip.close()
			return _fail("path", "nome di file non ammesso: " + name)
		if name.ends_with("/"):
			continue
		var data := zip.read_file(name)
		if data.size() > MAX_FILE_BYTES:
			zip.close()
			return _fail("limits", "file troppo grande: " + name)
		total += data.size()
		contents[name] = data
	zip.close()
	if total > MAX_TOTAL_BYTES:
		return _fail("limits", "pacchetto troppo grande una volta estratto")

	if not contents.has("manifest.json") or not contents.has("case.json"):
		return _fail("manifest", "mancano manifest.json o case.json")
	var manifest = JSON.parse_string(contents["manifest.json"].get_string_from_utf8())
	if typeof(manifest) != TYPE_DICTIONARY or manifest.get("format", "") != "cccase/1":
		return _fail("manifest", "formato del pacchetto sconosciuto")
	var listed: Dictionary = manifest.get("files", {})
	for name in contents:
		if name == "manifest.json":
			continue
		if not listed.has(name):
			return _fail("manifest", "file non dichiarato nel manifest: " + name)
		if _sha256(contents[name]) != String(listed[name]):
			return _fail("hash", "file alterato: " + name)
	for name in listed:
		if not contents.has(name):
			return _fail("manifest", "file dichiarato ma assente: " + name)

	var case_data = JSON.parse_string(contents["case.json"].get_string_from_utf8())
	if typeof(case_data) != TYPE_DICTIONARY:
		return _fail("case", "case.json non valido")
	var schema_major := int(String(case_data.get("schema_version", "0")).get_slice(".", 0))
	if schema_major != SCHEMA_MAJOR:
		return _fail("version", "formato del caso %s non supportato da questa versione del gioco" % case_data.get("schema_version", "?"))
	if compare_versions(String(case_data.get("min_game_version", "0.0.0")), GAME_VERSION) > 0:
		return _fail("version", "serve il gioco %s o successivo" % case_data["min_game_version"])
	var case_id := String(case_data.get("case_id", ""))
	var version := String(case_data.get("version", ""))
	if case_id != manifest.get("case_id") or version != manifest.get("version"):
		return _fail("manifest", "manifest e caso non coincidono")
	if not case_id.is_valid_identifier() or version.split(".").size() != 3:
		return _fail("case", "identificativo o versione del caso non validi")

	# scrittura atomica: cartella temporanea, poi rinomina
	var final_dir := "%s/%s/%s" % [ROOT, case_id, version]
	var tmp_dir := final_dir + ".tmp"
	_remove_tree(tmp_dir)
	for name in contents:
		var dst := tmp_dir.path_join(name)
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		var f := FileAccess.open(dst, FileAccess.WRITE)
		if f == null:
			_remove_tree(tmp_dir)
			return _fail("write", "impossibile scrivere " + dst)
		f.store_buffer(contents[name])
		f.close()
	_remove_tree(final_dir)
	if DirAccess.rename_absolute(tmp_dir, final_dir) != OK:
		_remove_tree(tmp_dir)
		return _fail("write", "impossibile completare l'installazione")
	return {}


## Percorso del case.json di un caso installato.
static func case_json_path(case_id: String, version: String) -> String:
	return "%s/%s/%s/case.json" % [ROOT, case_id, version]


## core://x -> res://assets/x ; case://x -> <cartella del caso>/assets/x
static func resolve_texture(uri: String, case_dir: String) -> Texture2D:
	if uri.begins_with("core://"):
		var p := "res://assets/" + uri.trim_prefix("core://")
		return load(p) if ResourceLoader.exists(p) else null
	if uri.begins_with("case://"):
		var img := Image.load_from_file(case_dir.path_join("assets").path_join(uri.trim_prefix("case://")))
		return ImageTexture.create_from_image(img) if img else null
	return null


## -1, 0, 1 come strcmp, per versioni "a.b.c".
static func compare_versions(a: String, b: String) -> int:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in 3:
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return -1 if x < y else 1
	return 0


static func _safe_name(name: String) -> bool:
	if name.is_empty() or name.begins_with("/") or name.contains("\\") or name.contains(":"):
		return false
	for part in name.split("/", false):
		if part == ".." or part == ".":
			return false
	if name in ["manifest.json", "case.json"]:
		return true
	return name.begins_with("assets/") and (name.ends_with(".png") or name.ends_with("/"))


static func _sha256(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()


static func _remove_tree(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		_remove_tree(path.path_join(sub))
	DirAccess.remove_absolute(path)


static func _fail(code: String, detail: String) -> Dictionary:
	return {"error": code, "detail": detail}
