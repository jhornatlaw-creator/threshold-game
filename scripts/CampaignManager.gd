extends Node
## CampaignManager -- Campaign state persistence and mission flow.

const CAMPAIGN_FILE := "user://campaign_state.json"

var campaign_active: bool = false
var current_mission: int = 0
var missions: Array = []
var fleet_status: Dictionary = {}  # ship_id -> {alive, damage, name, class}
var mission_history: Array = []  # Array of {mission_index, result, score, grade, losses}

signal campaign_updated

func start_campaign(mission_list: Array) -> void:
	campaign_active = true
	current_mission = 0
	missions = mission_list
	fleet_status = {}
	mission_history = []
	_save()

func get_current_mission_path() -> String:
	if current_mission < missions.size():
		return missions[current_mission]
	return ""

func get_current_mission_number() -> int:
	return current_mission + 1

func get_total_missions() -> int:
	return missions.size()

func is_campaign_complete() -> bool:
	return current_mission >= missions.size()

func record_mission_result(result: String, score: int, grade: String, units_lost: Array, units_surviving: Array) -> void:
	mission_history.append({
		"mission_index": current_mission,
		"result": result,
		"score": score,
		"grade": grade,
		"losses": units_lost,
	})

	# Update fleet status -- mark lost ships (including first-mission units)
	for unit_id in units_lost:
		if unit_id in fleet_status:
			fleet_status[unit_id]["alive"] = false
			fleet_status[unit_id]["lost_mission"] = current_mission
		else:
			fleet_status[unit_id] = {"alive": false, "damage": 1.0, "name": unit_id, "class": "", "lost_mission": current_mission}

	# Update surviving ships
	for uid in units_surviving:
		if uid not in fleet_status:
			fleet_status[uid] = {"alive": true, "damage": 0.0, "name": uid, "class": ""}

	# Only advance on victory — defeat/draw means retry the same mission
	if result == "victory":
		current_mission += 1
	_save()
	campaign_updated.emit()

func get_surviving_player_ships() -> Array:
	var result := []
	for ship_id in fleet_status:
		if fleet_status[ship_id].get("alive", true):
			result.append(ship_id)
	return result

func get_lost_ships() -> Array:
	var result := []
	for ship_id in fleet_status:
		if not fleet_status[ship_id].get("alive", true):
			result.append(fleet_status[ship_id])
	return result

func _save() -> void:
	var data := {
		"campaign_active": campaign_active,
		"current_mission": current_mission,
		"missions": missions,
		"fleet_status": fleet_status,
		"mission_history": mission_history,
	}
	var file := FileAccess.open(CAMPAIGN_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
	else:
		push_error("CampaignManager: cannot write campaign state, error %d" % FileAccess.get_open_error())

func load_campaign() -> bool:
	if not FileAccess.file_exists(CAMPAIGN_FILE):
		return false
	var file := FileAccess.open(CAMPAIGN_FILE, FileAccess.READ)
	if not file:
		return false
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return false
	if not json.data is Dictionary:
		push_error("CampaignManager: save file root is not a Dictionary")
		return false
	var data: Dictionary = json.data
	campaign_active = data.get("campaign_active", false)
	current_mission = data.get("current_mission", 0)
	if not (current_mission is int) or current_mission < 0:
		current_mission = 0
	missions = data.get("missions", [])
	if not missions is Array:
		missions = []
	fleet_status = data.get("fleet_status", {})
	if not fleet_status is Dictionary:
		fleet_status = {}
	mission_history = data.get("mission_history", [])
	return campaign_active

func reset_campaign() -> void:
	campaign_active = false
	current_mission = 0
	missions = []
	fleet_status = {}
	mission_history = []
	if FileAccess.file_exists(CAMPAIGN_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CAMPAIGN_FILE))
