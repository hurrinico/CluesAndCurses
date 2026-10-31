extends Node

## AuthService - Autoload (Nome Nodo: "AuthService"). Ponte tra il gioco e l'accesso
## del browser (web/auth/ccauth.js, Supabase Auth). Fuori dal browser, o senza
## configurazione Supabase, is_available() è falso e il gioco resta solo locale.
##
## Salvataggi nel cloud (un solo slot):
##   - a ogni salvataggio locale, se si è dentro, il JSON parte verso il cloud
##     (ccauth.js raggruppa le scritture ravvicinate)
##   - all'accesso si confrontano locale e cloud con "saved_at": vince il più recente;
##     se vince il cloud, il locale viene copiato in user://cc_save.before_cloud.json
##
## Nessuna class_name: è un Autoload (vedi la nota in SaveManager.gd).

signal state_changed(state: Dictionary)
## Il salvataggio locale è stato sostituito da quello del cloud: le scene aggiornano ciò che mostrano.
signal save_replaced

const BACKUP_PATH := "user://cc_save.before_cloud.json"

var state: Dictionary = {"available": false, "signed_in": false, "name": "", "email": "", "provider": "", "user_id": ""}

var _auth: JavaScriptObject
var _on_change_cb: JavaScriptObject
var _on_load_cb: JavaScriptObject
var _synced_user := ""      # utente per cui la sincronizzazione iniziale è già stata fatta
var _syncing := false


func _ready() -> void:
	if not OS.has_feature("web"):
		return
	# ccauth.js è caricato con "defer": di norma c'è già, ma diamogli qualche istante
	for i in 20:
		_auth = JavaScriptBridge.get_interface("CCAuth")
		if _auth != null:
			break
		await get_tree().create_timer(0.25).timeout
	if _auth == null or not bool(_auth.available):
		return
	_on_change_cb = JavaScriptBridge.create_callback(_on_js_change)
	_on_load_cb = JavaScriptBridge.create_callback(_on_js_loaded)
	_auth.onChange(_on_change_cb)
	_apply(String(_auth.state()))
	SaveManager.saved.connect(_on_local_saved)


func is_available() -> bool:
	return bool(state.get("available", false))


func is_signed_in() -> bool:
	return bool(state.get("signed_in", false))


func display_name() -> String:
	return String(state.get("name", ""))


## Apre il pannello: accesso se fuori, profilo se dentro.
func open_panel(view: String = "") -> void:
	if _auth != null:
		_auth.open(view)


# ------------------------------------------------------------------ interni
func _on_js_change(args: Array) -> void:
	_apply(String(args[0]) if args.size() > 0 else "{}")


func _apply(json: String) -> void:
	var parsed = JSON.parse_string(json)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	state = parsed
	print("[AuthService] ", "dentro come %s (%s)" % [display_name(), state.get("provider", "")] if is_signed_in() else "ospite")
	state_changed.emit(state)
	if is_signed_in() and _synced_user != String(state.get("user_id", "")) and not _syncing:
		_syncing = true
		_auth.loadCloud(_on_load_cb)
	elif not is_signed_in():
		_synced_user = ""


func _on_js_loaded(args: Array) -> void:
	_syncing = false
	var res = JSON.parse_string(String(args[0]) if args.size() > 0 else "{}")
	if typeof(res) != TYPE_DICTIONARY or res.has("error"):
		push_warning("[AuthService] salvataggio nel cloud non letto: %s" % (res.get("error", "?") if res is Dictionary else "?"))
		return
	_synced_user = String(state.get("user_id", ""))
	var remote = res.get("data")
	var decision := decide(SaveManager.game_data, remote)
	print("[AuthService] sincronizzazione: ", decision)
	match decision:
		"use_cloud":
			_backup_local()
			SaveManager.replace_data(remote)
			save_replaced.emit()
		"push_local":
			_auth.saveCloud(JSON.stringify(SaveManager.game_data))
			_auth.flushSave()


## "use_cloud", "push_local" o "same". Statico per le prove.
static func decide(local: Dictionary, remote) -> String:
	if typeof(remote) != TYPE_DICTIONARY or remote.is_empty():
		return "push_local"
	var l := float(local.get("saved_at", 0))
	var r := float(remote.get("saved_at", 0))
	if r > l:
		return "use_cloud"
	if l > r:
		return "push_local"
	return "same"


func _on_local_saved() -> void:
	if is_signed_in() and _synced_user != "":
		_auth.saveCloud(JSON.stringify(SaveManager.game_data))


func _backup_local() -> void:
	var f := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(SaveManager.game_data))
		f.close()
