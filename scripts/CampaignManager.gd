extends Node
## CampaignManager -- Campaign state persistence, mission flow, crew manifests.
##
## Phase 3 additions:
## - Crew manifest generation per ship (random names stored for memorial scroll)
## - Real crew counts from platforms.json
## - Enemy kill tracking with hull numbers and crew counts
## - Mission name lookup for campaign-persistent grief display
## - Interlude tracking (which interludes have been shown)

const CAMPAIGN_FILE := "user://campaign_state.json"

var campaign_active: bool = false
var current_mission: int = 0
var missions: Array = []
var fleet_status: Dictionary = {}  # ship_id -> {alive, damage, name, class, crew, crew_manifest, lost_mission, lost_mission_name}
var mission_history: Array = []  # Array of {mission_index, mission_name, result, score, grade, losses, enemy_kills}
var enemy_kills_campaign: Array = []  # Array of {name, class, crew, mission_index, mission_name, hull_number}
var shown_interludes: Dictionary = {}  # interlude_id -> true

# Phase 10: Crisis temperature, crew readiness, patrol log
var crisis_temperature: float = 20.0  # 0 (peace) to 100 (war), starts at 20
var ship_readiness: Dictionary = {}  # ship_id -> float (1.0 = fresh, 0.3 = exhausted)
var patrol_log: Dictionary = {  # Accumulated across campaign
	"contacts": [],
	"weapons": [],
	"losses": [],
	"temperature_events": [],
}

# --- Crew manifest ---
var _crew_manifests: Dictionary = {}  # ship_id -> Array of "J. LASTNAME"

# Mission name map (campaign_mission 1-based -> mission name)
const MISSION_NAMES := {
	1: "THRESHOLD",
	2: "COLD PASSAGE",
	3: "SOSUS GHOST",
	4: "NORTHERN WATCH",
	5: "CROSSING THE LINE",
	6: "REYKJANES RIDGE",
	7: "SILENT WATCH",
}

# Name pools for crew generation
const LAST_NAMES := [
	"ADAMS", "BAKER", "BROOKS", "CARTER", "CHEN", "CLARK", "COLE", "COLLINS",
	"COOPER", "CRUZ", "DAVIS", "DIAZ", "EDWARDS", "EVANS", "FISHER", "FLORES",
	"FORD", "FOSTER", "GARCIA", "GIBSON", "GONZALEZ", "GRANT", "GREEN", "GRIFFIN",
	"HALL", "HAMILTON", "HARRIS", "HAYES", "HENDERSON", "HERNANDEZ", "HILL", "HOWARD",
	"HUGHES", "JACKSON", "JAMES", "JENKINS", "JOHNSON", "JONES", "KELLY", "KENNEDY",
	"KIM", "KING", "KNIGHT", "LEE", "LEWIS", "LONG", "LOPEZ", "MARTIN",
	"MARTINEZ", "MASON", "MILLER", "MITCHELL", "MOORE", "MORGAN", "MORRIS", "MURPHY",
	"NELSON", "NGUYEN", "OLIVER", "OWENS", "PARKER", "PATEL", "PATTERSON", "PEREZ",
	"PERRY", "PETERSON", "PHILLIPS", "POWELL", "PRICE", "RAMIREZ", "REED", "REYES",
	"REYNOLDS", "RICHARDSON", "RIVERA", "ROBERTS", "ROBINSON", "RODRIGUEZ", "ROGERS", "ROSS",
	"RUSSELL", "SANDERS", "SANTIAGO", "SCOTT", "SHAW", "SIMMONS", "SMITH", "STEWART",
	"SULLIVAN", "TAYLOR", "THOMAS", "THOMPSON", "TORRES", "TURNER", "WALKER", "WARD",
	"WASHINGTON", "WATSON", "WHITE", "WILLIAMS", "WILSON", "WOOD", "WRIGHT", "YOUNG",
]
const FIRST_INITIALS := "ABCDEFGHJKLMNPRSTW"

signal campaign_updated

func start_campaign(mission_list: Array) -> void:
	campaign_active = true
	current_mission = 0
	missions = mission_list
	fleet_status = {}
	mission_history = []
	enemy_kills_campaign = []
	shown_interludes = {}
	_crew_manifests = {}
	crisis_temperature = 20.0
	ship_readiness = {}
	patrol_log = {"contacts": [], "weapons": [], "losses": [], "temperature_events": []}
	_save()

func get_current_mission_path() -> String:
	if current_mission < missions.size():
		return missions[current_mission]
	return ""

func get_current_mission_number() -> int:
	return current_mission + 1

func get_total_missions() -> int:
	return missions.size()

func get_current_mission_name() -> String:
	return MISSION_NAMES.get(get_current_mission_number(), "UNKNOWN")

func is_campaign_complete() -> bool:
	return current_mission >= missions.size()

# ---------------------------------------------------------------------------
# Crew manifest generation
# ---------------------------------------------------------------------------

## Generate a crew manifest for a ship. Call this when a ship first appears in the campaign.
## crew_count comes from platforms.json. Returns the manifest array.
func generate_crew_manifest(ship_id: String, crew_count: int) -> Array:
	if ship_id in _crew_manifests:
		return _crew_manifests[ship_id]

	var manifest: Array = []
	var rng := RandomNumberGenerator.new()
	# Seed from ship_id hash for reproducibility within a campaign
	rng.seed = hash(ship_id) + hash("threshold_1985")

	var used_names: Dictionary = {}
	for i in range(crew_count):
		var name_str: String = ""
		var attempts: int = 0
		while attempts < 50:
			var initial: String = FIRST_INITIALS[rng.randi() % FIRST_INITIALS.length()]
			var last: String = LAST_NAMES[rng.randi() % LAST_NAMES.size()]
			name_str = "%s. %s" % [initial, last]
			if name_str not in used_names:
				used_names[name_str] = true
				break
			attempts += 1
		manifest.append(name_str)

	_crew_manifests[ship_id] = manifest
	return manifest

## Get the crew manifest for a ship, or empty array if not generated.
func get_crew_manifest(ship_id: String) -> Array:
	return _crew_manifests.get(ship_id, [])

# ---------------------------------------------------------------------------
# Fleet registration with real data
# ---------------------------------------------------------------------------

## Register a ship in the fleet with real crew count and class name.
## Called by Main.gd when the scenario loads.
func register_ship(ship_id: String, ship_name: String, class_name_str: String, crew_count: int) -> void:
	if ship_id not in fleet_status:
		fleet_status[ship_id] = {
			"alive": true,
			"damage": 0.0,
			"name": ship_name,
			"class": class_name_str,
			"crew": crew_count,
		}
		# Generate crew manifest on first registration
		generate_crew_manifest(ship_id, crew_count)
	elif fleet_status[ship_id].get("alive", true):
		# Update metadata but don't overwrite lost_mission data
		fleet_status[ship_id]["name"] = ship_name
		fleet_status[ship_id]["class"] = class_name_str
		fleet_status[ship_id]["crew"] = crew_count

# ---------------------------------------------------------------------------
# Mission results
# ---------------------------------------------------------------------------

func record_mission_result(result: String, score: int, grade: String, units_lost: Array, units_surviving: Array) -> void:
	var mission_name: String = MISSION_NAMES.get(current_mission + 1, "MISSION %d" % (current_mission + 1))

	mission_history.append({
		"mission_index": current_mission,
		"mission_name": mission_name,
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
			fleet_status[unit_id]["lost_mission_name"] = mission_name
		else:
			fleet_status[unit_id] = {
				"alive": false, "damage": 1.0, "name": unit_id, "class": "",
				"crew": 0, "lost_mission": current_mission, "lost_mission_name": mission_name,
			}

	# Update surviving ships
	for uid in units_surviving:
		if uid not in fleet_status:
			fleet_status[uid] = {"alive": true, "damage": 0.0, "name": uid, "class": "", "crew": 0}

	# Only advance on victory -- defeat/draw means retry the same mission
	if result == "victory":
		current_mission += 1
	_save()
	campaign_updated.emit()

## Record an enemy kill during a mission. Called by Main.gd.
func record_enemy_kill(enemy_name: String, enemy_class: String, enemy_crew: int, hull_number: String) -> void:
	var mission_name: String = MISSION_NAMES.get(current_mission + 1, "MISSION %d" % (current_mission + 1))
	enemy_kills_campaign.append({
		"name": enemy_name,
		"class": enemy_class,
		"crew": enemy_crew,
		"hull_number": hull_number,
		"mission_index": current_mission,
		"mission_name": mission_name,
	})

## Get enemy kills for the current mission only.
func get_current_mission_kills() -> Array:
	var result := []
	for kill in enemy_kills_campaign:
		if kill.get("mission_index", -1) == current_mission:
			result.append(kill)
	return result

## Get all enemy kills across the campaign.
func get_all_enemy_kills() -> Array:
	return enemy_kills_campaign

# ---------------------------------------------------------------------------
# Ship loss queries with real data
# ---------------------------------------------------------------------------

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

## Get ships lost specifically in the current mission.
func get_ships_lost_this_mission() -> Array:
	var result := []
	for ship_id in fleet_status:
		var ship: Dictionary = fleet_status[ship_id]
		if not ship.get("alive", true) and ship.get("lost_mission", -1) == current_mission:
			result.append(ship)
	return result

## Get ships lost in prior missions (for persistent grief display).
func get_ships_lost_prior() -> Array:
	var result := []
	for ship_id in fleet_status:
		var ship: Dictionary = fleet_status[ship_id]
		if not ship.get("alive", true) and ship.get("lost_mission", -1) < current_mission:
			result.append(ship)
	return result

# ---------------------------------------------------------------------------
# Interlude tracking
# ---------------------------------------------------------------------------

func mark_interlude_shown(interlude_id: String) -> void:
	shown_interludes[interlude_id] = true

func was_interlude_shown(after_mission: int) -> bool:
	var key := "between_%d_%d" % [after_mission, after_mission + 1]
	return key in shown_interludes

# ---------------------------------------------------------------------------
# Phase 10: Crisis Temperature + Crew Readiness + Patrol Log
# ---------------------------------------------------------------------------

## Update crisis temperature at end of mission. ROESystem calls this via Main.gd.
func update_crisis_temperature(new_temp: float) -> void:
	crisis_temperature = clampf(new_temp, 0.0, 100.0)
	_save()

## Apply between-mission temperature cooling.
func apply_mission_gap_cooling() -> void:
	crisis_temperature = clampf(crisis_temperature - 5.0, 0.0, 100.0)
	_save()

## Update ship readiness. Called at end of mission.
func update_ship_readiness(unit_id: String, readiness: float) -> void:
	ship_readiness[unit_id] = clampf(readiness, 0.3, 1.0)
	_save()

## Load all readiness values into ROESystem at mission start.
func get_ship_readiness() -> Dictionary:
	return ship_readiness.duplicate()

## Degrade readiness for all surviving ships at mission end.
func degrade_readiness_post_mission(units_surviving: Array, units_damaged: Array) -> void:
	for uid in units_surviving:
		var current: float = ship_readiness.get(uid, 1.0)
		current -= 0.05  # Base degradation per mission
		if uid in units_damaged:
			current -= 0.1  # Extra if ship took damage
		ship_readiness[uid] = clampf(current, 0.3, 1.0)
	_save()

## Recover readiness for all ships between missions.
func recover_readiness_between_missions() -> void:
	for uid in ship_readiness:
		var current: float = ship_readiness[uid]
		ship_readiness[uid] = clampf(current + 0.03, 0.3, 1.0)
	_save()

## Append patrol log entries from this mission into the campaign log.
func append_patrol_log(mission_log: Dictionary) -> void:
	for entry in mission_log.get("contacts", []):
		patrol_log["contacts"].append(entry)
	for entry in mission_log.get("weapons", []):
		patrol_log["weapons"].append(entry)
	for entry in mission_log.get("losses", []):
		patrol_log["losses"].append(entry)
	for entry in mission_log.get("temperature_events", []):
		patrol_log["temperature_events"].append(entry)
	_save()

## Get the full patrol log for end-of-campaign display.
func get_patrol_log() -> Dictionary:
	return patrol_log.duplicate(true)

# ---------------------------------------------------------------------------
# Struck-from-roster message for next mission briefing
# ---------------------------------------------------------------------------

## Returns a string like "Task Force strength reduced. USS Elrod struck from roster."
## Call at mission start to check if ships were lost in prior missions.
func get_roster_reduction_message() -> String:
	var lost_prior: Array = get_ships_lost_prior()
	if lost_prior.is_empty():
		return ""
	var lines: Array = ["Task Force strength reduced."]
	for ship in lost_prior:
		var sname: String = ship.get("name", "Unknown")
		lines.append("%s struck from roster." % sname)
	return "\n".join(lines)

# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _save() -> void:
	var data := {
		"campaign_active": campaign_active,
		"current_mission": current_mission,
		"missions": missions,
		"fleet_status": fleet_status,
		"mission_history": mission_history,
		"enemy_kills_campaign": enemy_kills_campaign,
		"shown_interludes": shown_interludes,
		"crew_manifests": _crew_manifests,
		"crisis_temperature": crisis_temperature,
		"ship_readiness": ship_readiness,
		"patrol_log": patrol_log,
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
	# Validate mission paths: only allow paths under res://scenarios/
	var valid_missions: Array = []
	for m in missions:
		if m is String and m.begins_with("res://scenarios/") and m.ends_with(".json"):
			valid_missions.append(m)
		else:
			push_warning("CampaignManager: rejected invalid mission path '%s'" % str(m))
	missions = valid_missions
	fleet_status = data.get("fleet_status", {})
	if not fleet_status is Dictionary:
		fleet_status = {}
	mission_history = data.get("mission_history", [])
	enemy_kills_campaign = data.get("enemy_kills_campaign", [])
	shown_interludes = data.get("shown_interludes", {})
	_crew_manifests = data.get("crew_manifests", {})
	crisis_temperature = data.get("crisis_temperature", 20.0)
	if typeof(crisis_temperature) != TYPE_FLOAT and typeof(crisis_temperature) != TYPE_INT:
		crisis_temperature = 20.0
	ship_readiness = data.get("ship_readiness", {})
	if not ship_readiness is Dictionary:
		ship_readiness = {}
	patrol_log = data.get("patrol_log", {"contacts": [], "weapons": [], "losses": [], "temperature_events": []})
	if not patrol_log is Dictionary:
		patrol_log = {"contacts": [], "weapons": [], "losses": [], "temperature_events": []}
	return campaign_active

func reset_campaign() -> void:
	campaign_active = false
	current_mission = 0
	missions = []
	fleet_status = {}
	mission_history = []
	enemy_kills_campaign = []
	shown_interludes = {}
	_crew_manifests = {}
	crisis_temperature = 20.0
	ship_readiness = {}
	patrol_log = {"contacts": [], "weapons": [], "losses": [], "temperature_events": []}
	if FileAccess.file_exists(CAMPAIGN_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(CAMPAIGN_FILE))
