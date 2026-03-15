extends Node
## PlatformLoader -- Loads and validates platform/weapon/sensor JSON databases.
##
## Autoload singleton. Reads data files on _ready(), validates required fields,
## and crashes loudly on missing data. Returns Dictionaries to callers.

var _platforms: Dictionary = {}
var _weapons: Dictionary = {}
var _sensors: Dictionary = {}
var _loaded: bool = false

const REQUIRED_PLATFORM_FIELDS := ["id", "name", "type", "max_speed_kts", "displacement_tons"]
const REQUIRED_WEAPON_FIELDS := ["id", "name", "type", "max_range_nm", "speed_kts", "pk_base", "warhead_kg"]
const REQUIRED_SENSOR_FIELDS := ["id", "name", "type"]

func _ready() -> void:
	_load_all()

func _load_all() -> void:
	_platforms = _load_json_file("res://data/platforms.json", "platforms", REQUIRED_PLATFORM_FIELDS)
	_weapons = _load_json_file("res://data/weapons.json", "weapons", REQUIRED_WEAPON_FIELDS)
	_sensors = _load_json_file("res://data/sensors.json", "sensors", REQUIRED_SENSOR_FIELDS)
	_loaded = true
	print("[PlatformLoader] Loaded %d platforms, %d weapons, %d sensors" % [
		_platforms.size(), _weapons.size(), _sensors.size()
	])

func _load_json_file(path: String, array_key: String, required_fields: Array) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("PlatformLoader: MISSING DATA FILE: %s -- game cannot continue without data." % path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("PlatformLoader: CANNOT OPEN: %s (error %d)" % [path, FileAccess.get_open_error()])
		return {}

	var text: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	var err: Error = json.parse(text)
	if err != OK:
		push_error("PlatformLoader: JSON PARSE ERROR in %s at line %d: %s" % [
			path, json.get_error_line(), json.get_error_message()
		])
		return {}

	var data = json.data
	if not data is Dictionary or not data.has(array_key):
		push_error("PlatformLoader: %s missing root key '%s'" % [path, array_key])
		return {}

	var result: Dictionary = {}
	for entry in data[array_key]:
		if not entry is Dictionary:
			push_error("PlatformLoader: non-dict entry in %s.%s" % [path, array_key])
			continue

		# Validate required fields
		var missing_field: bool = false
		for field in required_fields:
			if not entry.has(field):
				push_error("PlatformLoader: entry in %s missing required field '%s': %s" % [
					path, field, str(entry)
				])
				missing_field = true
		if missing_field:
			continue

		var entry_id: String = entry.get("id", "")
		if entry_id == "":
			push_error("PlatformLoader: entry in %s has empty id" % path)
			continue

		result[entry_id] = entry

	return result

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
func get_platform(platform_id: String) -> Dictionary:
	if platform_id in _platforms:
		return _platforms[platform_id].duplicate(true)
	push_warning("PlatformLoader: unknown platform '%s'" % platform_id)
	return {}

func get_weapon(weapon_id: String) -> Dictionary:
	if weapon_id in _weapons:
		return _weapons[weapon_id].duplicate(true)
	push_warning("PlatformLoader: unknown weapon '%s'" % weapon_id)
	return {}

func get_sensor(sensor_id: String) -> Dictionary:
	if sensor_id in _sensors:
		return _sensors[sensor_id].duplicate(true)
	push_warning("PlatformLoader: unknown sensor '%s'" % sensor_id)
	return {}

func get_all_platforms() -> Dictionary:
	return _platforms.duplicate(true)

func get_all_weapons() -> Dictionary:
	return _weapons.duplicate(true)

func get_all_sensors() -> Dictionary:
	return _sensors.duplicate(true)

func get_platforms_by_type(type: String) -> Array:
	var result := []
	for pid in _platforms:
		if _platforms[pid].get("type", "") == type:
			result.append(_platforms[pid].duplicate(true))
	return result

func is_loaded() -> bool:
	return _loaded
