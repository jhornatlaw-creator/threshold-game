extends RefCounted
## ROESystem -- Rules of Engagement, Contact Classification, Crisis Temperature,
## Crew Fatigue, and Patrol Log.
##
## Phase 10: Classification ladder (UNKNOWN -> CERTAIN_HOSTILE), ROE states
## (WEAPONS_TIGHT / WEAPONS_HOLD / WEAPONS_FREE), crisis temperature (0-100),
## crew fatigue (readiness 0.3-1.0), patrol log (after-action report).
##
## Classification determines what the player KNOWS about a contact.
## ROE determines what the player MAY DO to a contact.
## Crisis temperature is a hidden campaign-spanning escalation variable.
## Crew fatigue degrades sensor performance and reaction time over sustained ops.
##
## Operates on world state dictionaries via _world reference.

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

# ---------------------------------------------------------------------------
# Enums -- Classification ladder
# ---------------------------------------------------------------------------
enum Classification {
	UNKNOWN = 0,        # Something is there -- bearing line, faint contact
	SUSPECT = 1,        # Probably hostile -- partial acoustic match
	PROBABLE_HOSTILE = 2, # High confidence hostile -- multiple sensor matches
	CERTAIN_HOSTILE = 3,  # Positively identified -- visual, full acoustic, ESM
}

# ---------------------------------------------------------------------------
# Enums -- ROE states
# ---------------------------------------------------------------------------
enum ROEState {
	WEAPONS_TIGHT = 0,  # Cannot fire. Fire button disabled/locked.
	WEAPONS_HOLD = 1,   # Fire ONLY if CERTAIN_HOSTILE AND immediate threat.
	WEAPONS_FREE = 2,   # Fire at PROBABLE_HOSTILE or CERTAIN_HOSTILE.
}

# ---------------------------------------------------------------------------
# Classification names for display
# ---------------------------------------------------------------------------
const CLASSIFICATION_NAMES := {
	Classification.UNKNOWN: "UNKNOWN",
	Classification.SUSPECT: "SUSPECT",
	Classification.PROBABLE_HOSTILE: "PROB HOSTILE",
	Classification.CERTAIN_HOSTILE: "HOSTILE",
}

const ROE_STATE_NAMES := {
	ROEState.WEAPONS_TIGHT: "WEAPONS TIGHT",
	ROEState.WEAPONS_HOLD: "WEAPONS HOLD",
	ROEState.WEAPONS_FREE: "WEAPONS FREE",
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

## Current ROE state for the mission (set from scenario JSON, can change mid-mission)
var current_roe: int = ROEState.WEAPONS_FREE

## Per-contact classification: target_id -> Classification enum value
var _classifications: Dictionary = {}

## Per-contact classification evidence: target_id -> {methods: Array, confidence_sum: float}
var _classification_evidence: Dictionary = {}

## Neutral contacts (set per scenario) -- contacts that are actually friendly/neutral
## Used to detect wrong-classification penalties. unit_id -> true
var _neutral_contacts: Dictionary = {}

# ---------------------------------------------------------------------------
# Crisis Temperature (campaign-spanning hidden variable)
# ---------------------------------------------------------------------------

## Range: 0 (peace) to 100 (war). Stored in CampaignManager between missions.
var crisis_temperature: float = 20.0

# Temperature change events during current mission (for patrol log)
var _temp_events: Array = []  # {time, delta, reason}

# ---------------------------------------------------------------------------
# Crew Fatigue / Readiness
# ---------------------------------------------------------------------------

## Per-ship readiness: unit_id -> float (1.0 = fresh, 0.3 = exhausted)
## Stored in CampaignManager between missions.
var _ship_readiness: Dictionary = {}

## False contact tracking: unit_id -> next false contact time
var _false_contact_schedule: Dictionary = {}

# ---------------------------------------------------------------------------
# Patrol Log (After-Action Report)
# ---------------------------------------------------------------------------

## Events logged during each mission, persisted across campaign in CampaignManager.
var _patrol_log_contacts: Array = []   # {time, bearing, classification, unit_name, outcome}
var _patrol_log_weapons: Array = []    # {time, weapon_type, target_name, result}
var _patrol_log_losses: Array = []     # {time, ship_name, crew_count, mission_name}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

func reset() -> void:
	current_roe = ROEState.WEAPONS_FREE
	_classifications.clear()
	_classification_evidence.clear()
	_neutral_contacts.clear()
	_ship_readiness.clear()
	_false_contact_schedule.clear()
	_patrol_log_contacts.clear()
	_patrol_log_weapons.clear()
	_patrol_log_losses.clear()
	_temp_events.clear()

# ---------------------------------------------------------------------------
# ROE -- Set from scenario or mid-mission trigger
# ---------------------------------------------------------------------------

## Set ROE state. Called by load_scenario or NarrativeDirector comm trigger.
func set_roe_state(state: int) -> void:
	var old_roe: int = current_roe
	current_roe = clampi(state, ROEState.WEAPONS_TIGHT, ROEState.WEAPONS_FREE)
	if old_roe != current_roe:
		_safe_emit("roe_changed", [current_roe, old_roe])

## Parse ROE string from scenario JSON into enum value.
func parse_roe_string(roe_str: String) -> int:
	match roe_str.to_upper().strip_edges():
		"WEAPONS_TIGHT", "TIGHT":
			return ROEState.WEAPONS_TIGHT
		"WEAPONS_HOLD", "HOLD":
			return ROEState.WEAPONS_HOLD
		"WEAPONS_FREE", "FREE":
			return ROEState.WEAPONS_FREE
		_:
			push_warning("ROESystem: unknown roe_state '%s', defaulting to WEAPONS_FREE" % roe_str)
			return ROEState.WEAPONS_FREE

## Get human-readable ROE state name.
func get_roe_name() -> String:
	return ROE_STATE_NAMES.get(current_roe, "UNKNOWN")

# ---------------------------------------------------------------------------
# Classification -- Ladder management
# ---------------------------------------------------------------------------

## Get the current classification for a contact.
func get_classification(target_id: String) -> int:
	return _classifications.get(target_id, Classification.UNKNOWN)

## Get the classification name string for display.
func get_classification_name(target_id: String) -> String:
	var cls: int = get_classification(target_id)
	return CLASSIFICATION_NAMES.get(cls, "UNKNOWN")

## Upgrade a contact's classification. Classifications only go UP, never down.
## Returns the new classification level.
func upgrade_classification(target_id: String, new_level: int) -> int:
	var current: int = _classifications.get(target_id, Classification.UNKNOWN)
	if new_level > current:
		_classifications[target_id] = new_level
		_safe_emit("contact_classification_changed", [target_id, new_level, current])
		# Log to patrol log
		_log_contact_classification(target_id, new_level)
	return _classifications.get(target_id, Classification.UNKNOWN)

## Process a detection event and potentially upgrade classification.
## Called by DetectionSystem or SimulationWorld when a new detection occurs.
## method: "sonar_passive", "sonar_active", "radar", "esm", "visual", "sonar_cz"
## confidence: 0.0-1.0 from detection strength
func process_detection_for_classification(target_id: String, method: String,
		confidence: float, detector_id: String) -> void:
	# Initialize evidence tracking
	if target_id not in _classification_evidence:
		_classification_evidence[target_id] = {
			"methods": [],
			"confidence_sum": 0.0,
			"detection_count": 0,
		}

	var evidence: Dictionary = _classification_evidence[target_id]
	if method not in evidence["methods"]:
		evidence["methods"].append(method)
	evidence["confidence_sum"] = minf(evidence["confidence_sum"] + confidence, 1000.0)
	evidence["detection_count"] = mini(evidence["detection_count"] + 1, 1000)

	# Classification upgrade logic:
	# UNKNOWN -> SUSPECT: any detection with confidence > 0.3
	# SUSPECT -> PROBABLE_HOSTILE: confidence > 0.6 OR 2+ detection methods
	# PROBABLE_HOSTILE -> CERTAIN_HOSTILE: confidence > 0.85 AND 2+ methods,
	#   OR active sonar confirmation, OR ESM + passive match, OR visual ID
	var current: int = get_classification(target_id)
	var methods_count: int = evidence["methods"].size()
	var avg_confidence: float = evidence["confidence_sum"] / maxf(evidence["detection_count"], 1.0)

	if current == Classification.UNKNOWN:
		if confidence > 0.3 or evidence["detection_count"] >= 2:
			upgrade_classification(target_id, Classification.SUSPECT)
			current = get_classification(target_id)

	if current <= Classification.SUSPECT:
		if avg_confidence > 0.6 or methods_count >= 2:
			upgrade_classification(target_id, Classification.PROBABLE_HOSTILE)
			current = get_classification(target_id)

	if current <= Classification.PROBABLE_HOSTILE:
		# Certain hostile requires strong evidence
		var has_active_confirm: bool = "sonar_active" in evidence["methods"]
		var has_esm_passive: bool = "esm" in evidence["methods"] and "sonar_passive" in evidence["methods"]
		var has_visual: bool = "visual" in evidence["methods"]
		var has_radar_passive: bool = "radar" in evidence["methods"] and "sonar_passive" in evidence["methods"]

		if has_active_confirm or has_visual:
			upgrade_classification(target_id, Classification.CERTAIN_HOSTILE)
		elif has_esm_passive and avg_confidence > 0.7:
			upgrade_classification(target_id, Classification.CERTAIN_HOSTILE)
		elif has_radar_passive and avg_confidence > 0.7:
			upgrade_classification(target_id, Classification.CERTAIN_HOSTILE)
		elif avg_confidence > 0.85 and methods_count >= 2:
			upgrade_classification(target_id, Classification.CERTAIN_HOSTILE)

## Mark a unit as neutral (for waterspace management scenarios).
## If the player fires on this contact, it triggers MISSION FAILURE.
func mark_neutral(unit_id: String) -> void:
	_neutral_contacts[unit_id] = true

## Check if a contact is actually neutral (for ROE violation check).
func is_neutral(unit_id: String) -> bool:
	return unit_id in _neutral_contacts

# ---------------------------------------------------------------------------
# ROE Authorization -- Called before weapon fire
# ---------------------------------------------------------------------------

## Check if firing on a target is authorized under current ROE.
## Returns a Dictionary: {authorized: bool, reason: String}
func check_fire_authorization(shooter_id: String, target_id: String) -> Dictionary:
	# Only enforce ROE on player units
	if shooter_id in _world.units and _world.units[shooter_id]["faction"] != "player":
		return {"authorized": true, "reason": "AI unit -- ROE not enforced"}

	var cls: int = get_classification(target_id)
	var cls_name: String = CLASSIFICATION_NAMES.get(cls, "UNKNOWN")

	match current_roe:
		ROEState.WEAPONS_TIGHT:
			# Cannot fire at all
			return {
				"authorized": false,
				"reason": "WEAPONS TIGHT -- all weapons locked. ROE prohibits engagement."
			}

		ROEState.WEAPONS_HOLD:
			# Must be CERTAIN_HOSTILE AND immediate threat
			if cls < Classification.CERTAIN_HOSTILE:
				return {
					"authorized": false,
					"reason": "WEAPONS HOLD -- contact classified %s. Requires HOSTILE and immediate threat." % cls_name
				}
			# Check if target is an immediate threat (torpedo in water or closing inside weapon range)
			var is_threat: bool = _is_immediate_threat(target_id, shooter_id)
			if not is_threat:
				return {
					"authorized": false,
					"reason": "WEAPONS HOLD -- contact is HOSTILE but not an immediate threat."
				}
			return {"authorized": true, "reason": "WEAPONS HOLD -- HOSTILE contact, immediate threat confirmed."}

		ROEState.WEAPONS_FREE:
			# Must be at least PROBABLE_HOSTILE
			if cls < Classification.PROBABLE_HOSTILE:
				return {
					"authorized": false,
					"reason": "WEAPONS FREE -- contact classified %s. Requires PROB HOSTILE or HOSTILE." % cls_name
				}
			return {"authorized": true, "reason": "WEAPONS FREE -- engagement authorized."}

	return {"authorized": false, "reason": "ROE state unknown."}

## Check if firing on a neutral contact should trigger mission failure.
## Called AFTER a weapon is fired (too late to block -- the damage is done).
func check_roe_violation(target_id: String) -> bool:
	if is_neutral(target_id):
		# ROE VIOLATION: fired on a neutral/friendly contact
		_adjust_crisis_temperature(25.0, "ROE VIOLATION -- fired on neutral contact")
		return true
	return false

## Check if a target is an immediate threat to the shooter (WEAPONS_HOLD requirement).
func _is_immediate_threat(target_id: String, shooter_id: String) -> bool:
	if target_id not in _world.units or shooter_id not in _world.units:
		return false
	var target: Dictionary = _world.units[target_id]
	var shooter: Dictionary = _world.units[shooter_id]

	# Check if any weapon in flight is targeting the shooter or a friendly
	for wid in _world.weapons_in_flight:
		var w: Dictionary = _world.weapons_in_flight[wid]
		if w["shooter_id"] == target_id and not w["resolved"]:
			# Target has a weapon in flight -- immediate threat
			return true
		# Also check if weapon targets any friendly unit
		if w["shooter_id"] == target_id:
			var wpn_target: String = w["target_id"]
			if wpn_target in _world.units and _world.units[wpn_target]["faction"] == "player":
				return true

	# Check if target is closing on shooter inside weapon range
	var dist: float = shooter["position"].distance_to(target["position"])
	# Get target's best weapon range
	var target_weapon_range: float = 10.0  # conservative default
	for weapon_id in target.get("weapons_remaining", {}):
		var wrec: Dictionary = target["weapons_remaining"][weapon_id]
		if wrec["count"] > 0:
			var r: float = wrec["data"].get("max_range_nm", 10.0)
			if r > target_weapon_range:
				target_weapon_range = r
	# Target is inside weapon range and closing (heading toward shooter)
	if dist < target_weapon_range:
		var to_shooter: Vector2 = shooter["position"] - target["position"]
		var target_heading_rad: float = deg_to_rad(target["heading"])
		var target_dir := Vector2(sin(target_heading_rad), -cos(target_heading_rad))
		var dot: float = to_shooter.normalized().dot(target_dir)
		if dot > 0.3:  # Roughly heading toward shooter (within ~70 degrees)
			return true

	return false

# ---------------------------------------------------------------------------
# Crisis Temperature
# ---------------------------------------------------------------------------

## Initialize crisis temperature from CampaignManager at mission start.
func set_crisis_temperature(temp: float) -> void:
	crisis_temperature = clampf(temp, 0.0, 100.0)

## Get the current crisis temperature.
func get_crisis_temperature() -> float:
	return crisis_temperature

## Adjust crisis temperature by a delta amount. Positive = escalation, negative = de-escalation.
func _adjust_crisis_temperature(delta: float, reason: String) -> void:
	var old_temp: float = crisis_temperature
	crisis_temperature = clampf(crisis_temperature + delta, 0.0, 100.0)
	if absf(delta) > 0.01:
		_temp_events.append({
			"time": _world.sim_time if _world else 0.0,
			"delta": delta,
			"old": old_temp,
			"new": crisis_temperature,
			"reason": reason,
		})
		_safe_emit("crisis_temperature_changed", [crisis_temperature, old_temp, reason])

## Called when player goes active sonar.
func on_player_active_sonar() -> void:
	_adjust_crisis_temperature(2.0, "Player active sonar ping")

## Called when player fires a weapon.
func on_player_weapon_fired() -> void:
	_adjust_crisis_temperature(8.0, "Player fired weapon")

## Called when player sinks an enemy ship.
func on_player_sinks_enemy(enemy_name: String) -> void:
	_adjust_crisis_temperature(12.0, "Player sank %s" % enemy_name)

## Called when enemy fires on player (not player's fault, but escalates).
func on_enemy_fires_on_player() -> void:
	_adjust_crisis_temperature(15.0, "Enemy fired on player forces")

## Called for scripted geopolitical events (e.g., Hayler sinking).
func on_scripted_event(delta: float, reason: String) -> void:
	_adjust_crisis_temperature(delta, reason)

## Called at mission end: no weapons fired = de-escalation.
func on_mission_complete_no_fire(weapons_fired: int) -> void:
	if weapons_fired == 0:
		_adjust_crisis_temperature(-5.0, "Mission completed without firing")

## Called at mission end: maintained contact without engagement.
func on_maintained_contact_no_engagement() -> void:
	_adjust_crisis_temperature(-3.0, "Maintained contact without engagement")

## Called between missions: time passing lowers temperature.
func on_mission_gap() -> void:
	_adjust_crisis_temperature(-5.0, "Time between missions")

## Get the suggested initial ROE based on crisis temperature.
## Scenarios can override this, but this is the default if no roe_state is specified.
func get_roe_for_temperature() -> int:
	if crisis_temperature <= 30.0:
		return ROEState.WEAPONS_TIGHT
	elif crisis_temperature <= 60.0:
		return ROEState.WEAPONS_HOLD
	else:
		return ROEState.WEAPONS_FREE

## Check if Mission 7 ceasefire holds based on temperature.
## If temperature > 85 at Mission 7 start, the Akulas attack instead of withdrawing.
func does_ceasefire_hold() -> bool:
	return crisis_temperature <= 85.0

## Get temperature events for patrol log.
func get_temperature_events() -> Array:
	return _temp_events.duplicate()

# ---------------------------------------------------------------------------
# Crew Fatigue / Readiness
# ---------------------------------------------------------------------------

## Initialize readiness for a ship. Called when loading from CampaignManager.
func set_ship_readiness(unit_id: String, readiness: float) -> void:
	_ship_readiness[unit_id] = clampf(readiness, 0.3, 1.0)

## Get readiness for a ship. Returns 1.0 (fresh) if not tracked.
func get_ship_readiness(unit_id: String) -> float:
	return _ship_readiness.get(unit_id, 1.0)

## Apply readiness to a detection range. Returns modified range.
func apply_readiness_to_detection(unit_id: String, base_range: float) -> float:
	var readiness: float = get_ship_readiness(unit_id)
	return base_range * readiness

## Apply readiness to TMA classification time (divided by readiness = takes longer).
func apply_readiness_to_tma(unit_id: String, base_time_score: float) -> float:
	var readiness: float = get_ship_readiness(unit_id)
	if readiness < 0.01:
		readiness = 0.3  # Floor
	return base_time_score / readiness

## Apply readiness to torpedo warning delay. Returns additional delay in seconds.
func get_torpedo_warning_delay(unit_id: String) -> float:
	var readiness: float = get_ship_readiness(unit_id)
	if readiness >= 0.8:
		return 0.0  # Fresh crew, no delay
	elif readiness >= 0.6:
		return 1.0  # Slightly tired
	else:
		return 2.0  # Exhausted -- 2 second delay on torpedo warning

## Check if a false contact should be generated for a fatigued crew.
## Returns true if a false contact event should fire this tick.
func check_false_contact(unit_id: String) -> bool:
	var readiness: float = get_ship_readiness(unit_id)
	if readiness >= 0.6:
		return false  # Fresh enough, no false contacts

	# Schedule false contacts at intervals based on readiness
	if unit_id not in _false_contact_schedule:
		# Random interval: 300-600 seconds at readiness 0.3, 600-1200 at readiness 0.5
		var interval: float = _rng.randf_range(300.0, 600.0) * (readiness / 0.3)
		_false_contact_schedule[unit_id] = _world.sim_time + interval

	if _world.sim_time >= _false_contact_schedule[unit_id]:
		# Time for a false contact -- reschedule next one
		var interval: float = _rng.randf_range(300.0, 600.0) * (readiness / 0.3)
		_false_contact_schedule[unit_id] = _world.sim_time + interval
		return true

	return false

## Degrade readiness at mission end. Called by CampaignManager.
func degrade_readiness_post_mission(unit_id: String, took_damage: bool) -> float:
	var readiness: float = get_ship_readiness(unit_id)
	readiness -= 0.05  # Base degradation per mission
	if took_damage:
		readiness -= 0.1  # Additional degradation if ship took damage
	readiness = clampf(readiness, 0.3, 1.0)
	_ship_readiness[unit_id] = readiness
	return readiness

## Recover readiness between missions. Called by CampaignManager.
func recover_readiness_between_missions(unit_id: String) -> float:
	var readiness: float = get_ship_readiness(unit_id)
	readiness += 0.03  # Partial recovery per mission gap
	readiness = clampf(readiness, 0.3, 1.0)
	_ship_readiness[unit_id] = readiness
	return readiness

## Get all ship readiness values (for CampaignManager persistence).
func get_all_readiness() -> Dictionary:
	return _ship_readiness.duplicate()

## Load readiness from CampaignManager save data.
func load_readiness(data: Dictionary) -> void:
	_ship_readiness.clear()
	for uid in data:
		_ship_readiness[uid] = clampf(float(data[uid]), 0.3, 1.0)

# ---------------------------------------------------------------------------
# Patrol Log -- Event Recording
# ---------------------------------------------------------------------------

## Log a contact detection/classification event.
func _log_contact_classification(target_id: String, classification: int) -> void:
	var unit_name: String = "Unknown"
	if target_id in _world.units:
		unit_name = _world.units[target_id].get("name", target_id)
	var bearing: float = 0.0
	# Try to get bearing from a player detection
	for player_uid in _world.units:
		if _world.units[player_uid].get("faction", "") != "player":
			continue
		var player_contacts: Dictionary = _world.contacts.get(player_uid, {})
		if target_id in player_contacts:
			bearing = player_contacts[target_id].get("bearing", 0.0)
			break

	_patrol_log_contacts.append({
		"time": _world.sim_time,
		"bearing": bearing,
		"classification": CLASSIFICATION_NAMES.get(classification, "UNKNOWN"),
		"unit_name": unit_name,
		"target_id": target_id,
	})

## Log a weapon fired event.
func log_weapon_fired(weapon_type: String, target_name: String, shooter_name: String) -> void:
	_patrol_log_weapons.append({
		"time": _world.sim_time,
		"weapon_type": weapon_type,
		"target_name": target_name,
		"shooter_name": shooter_name,
		"result": "PENDING",  # Updated later when resolved
	})

## Update the most recent weapon log entry with the result.
func log_weapon_result(target_name: String, result: String) -> void:
	# Find the most recent weapon entry for this target and update it
	for i in range(_patrol_log_weapons.size() - 1, -1, -1):
		if _patrol_log_weapons[i]["target_name"] == target_name and _patrol_log_weapons[i]["result"] == "PENDING":
			_patrol_log_weapons[i]["result"] = result
			break

## Log a ship loss event.
func log_ship_loss(ship_name: String, crew_count: int, mission_name: String) -> void:
	_patrol_log_losses.append({
		"time": _world.sim_time,
		"ship_name": ship_name,
		"crew_count": crew_count,
		"mission_name": mission_name,
	})

## Get patrol log data (for CampaignManager persistence and end-of-campaign display).
func get_patrol_log() -> Dictionary:
	return {
		"contacts": _patrol_log_contacts.duplicate(true),
		"weapons": _patrol_log_weapons.duplicate(true),
		"losses": _patrol_log_losses.duplicate(true),
		"temperature_events": _temp_events.duplicate(true),
	}

## Load patrol log from CampaignManager save data.
func load_patrol_log(data: Dictionary) -> void:
	_patrol_log_contacts = data.get("contacts", []).duplicate(true)
	_patrol_log_weapons = data.get("weapons", []).duplicate(true)
	_patrol_log_losses = data.get("losses", []).duplicate(true)
	_temp_events = data.get("temperature_events", []).duplicate(true)

## Generate the declassified after-action report for campaign end screen.
## Returns structured text suitable for screenshotting.
func generate_after_action_report(campaign_manager) -> String:
	var lines: Array = []
	lines.append("=" .repeat(60))
	lines.append("DECLASSIFIED")
	lines.append("AFTER-ACTION REPORT -- PATROL GROUP DELTA")
	lines.append("NOVEMBER 1985")
	lines.append("=" .repeat(60))
	lines.append("")

	# --- Contact Summary ---
	lines.append("--- CONTACT LOG ---")
	if _patrol_log_contacts.is_empty():
		lines.append("  No contacts logged.")
	else:
		for entry in _patrol_log_contacts:
			var time_str: String = _format_sim_time(entry.get("time", 0.0))
			var brg: float = entry.get("bearing", 0.0)
			var cls: String = entry.get("classification", "UNKNOWN")
			var name_str: String = entry.get("unit_name", "Unknown")
			lines.append("  %s  BRG %03d  %s  %s" % [time_str, int(brg), cls, name_str])
	lines.append("")

	# --- Weapons Expenditure ---
	lines.append("--- WEAPONS EXPENDITURE ---")
	if _patrol_log_weapons.is_empty():
		lines.append("  No weapons fired.")
	else:
		for entry in _patrol_log_weapons:
			var time_str: String = _format_sim_time(entry.get("time", 0.0))
			var wtype: String = entry.get("weapon_type", "Unknown")
			var target: String = entry.get("target_name", "Unknown")
			var result: String = entry.get("result", "PENDING")
			lines.append("  %s  %s -> %s  [%s]" % [time_str, wtype, target, result])
	lines.append("")

	# --- Losses ---
	lines.append("--- LOSSES ---")
	if campaign_manager:
		var lost_ships: Array = campaign_manager.get_lost_ships()
		if lost_ships.is_empty():
			lines.append("  No ships lost.")
		else:
			var total_crew_lost: int = 0
			for ship in lost_ships:
				var sname: String = ship.get("name", "Unknown")
				var crew: int = ship.get("crew", 0)
				var mission: String = ship.get("lost_mission_name", "Unknown")
				lines.append("  %s -- %d crew -- Lost during %s" % [sname, crew, mission])
				total_crew_lost += crew
			lines.append("  TOTAL CREW LOST: %d" % total_crew_lost)
	elif not _patrol_log_losses.is_empty():
		for entry in _patrol_log_losses:
			lines.append("  %s -- %d crew -- %s" % [
				entry.get("ship_name", "Unknown"),
				entry.get("crew_count", 0),
				entry.get("mission_name", "Unknown"),
			])
	else:
		lines.append("  No ships lost.")
	lines.append("")

	# --- Mission Grades ---
	lines.append("--- MISSION GRADES ---")
	if campaign_manager:
		for entry in campaign_manager.mission_history:
			var mname: String = entry.get("mission_name", "Unknown")
			var grade: String = entry.get("grade", "?")
			var score: int = entry.get("score", 0)
			var result: String = entry.get("result", "?").to_upper()
			lines.append("  %s: %s (%d pts) -- %s" % [mname, grade, score, result])
	lines.append("")

	# --- Crisis Temperature Arc ---
	lines.append("--- ESCALATION TIMELINE ---")
	lines.append("  Starting temperature: 20")
	if not _temp_events.is_empty():
		for evt in _temp_events:
			var time_str: String = _format_sim_time(evt.get("time", 0.0))
			var delta: float = evt.get("delta", 0.0)
			var sign: String = "+" if delta > 0 else ""
			var new_temp: float = evt.get("new", 0.0)
			var reason: String = evt.get("reason", "")
			lines.append("  %s  %s%.0f -> %.0f  %s" % [time_str, sign, delta, new_temp, reason])
	lines.append("  Final temperature: %.0f" % crisis_temperature)
	lines.append("")

	# --- Enemy Kills ---
	lines.append("--- ENEMY VESSELS DESTROYED ---")
	if campaign_manager:
		var kills: Array = campaign_manager.get_all_enemy_kills()
		if kills.is_empty():
			lines.append("  None.")
		else:
			var total_enemy_crew: int = 0
			for kill in kills:
				var ename: String = kill.get("name", "Unknown")
				var eclass: String = kill.get("class", "Unknown")
				var ecrew: int = kill.get("crew", 0)
				var mission: String = kill.get("mission_name", "Unknown")
				lines.append("  %s (%s) -- %d crew -- %s" % [ename, eclass, ecrew, mission])
				total_enemy_crew += ecrew
			lines.append("  TOTAL ENEMY CREW: %d" % total_enemy_crew)
	lines.append("")

	lines.append("=" .repeat(60))
	lines.append("END OF REPORT")
	lines.append("=" .repeat(60))

	return "\n".join(lines)

## Format sim_time (seconds) as HH:MM:SS.
func _format_sim_time(t: float) -> String:
	var total_seconds: int = int(t)
	var hours: int = total_seconds / 3600
	var minutes: int = (total_seconds % 3600) / 60
	var seconds: int = total_seconds % 60
	return "%02d:%02d:%02d" % [hours, minutes, seconds]

# ---------------------------------------------------------------------------
# Safe signal emission (same pattern as WeaponSystem)
# ---------------------------------------------------------------------------

func _safe_emit(signal_name: String, args: Array) -> void:
	if _world and _world.has_signal(signal_name):
		match args.size():
			0: _world.emit_signal(signal_name)
			1: _world.emit_signal(signal_name, args[0])
			2: _world.emit_signal(signal_name, args[0], args[1])
			3: _world.emit_signal(signal_name, args[0], args[1], args[2])
