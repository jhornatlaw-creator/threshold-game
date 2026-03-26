extends RefCounted
## AIDoctrineSystem -- Soviet naval doctrine state machine for AI units.
##
## Submarine doctrine: sprint-and-drift, baffle-clearing turns, DETECTED evasion,
## shoot-and-run ATTACK, deep evasion with countermeasures.
##
## Surface group doctrine: Udaloys screen Kirov, radar always active,
## coordinated P-700 salvo response, Udaloys prosecute sub contacts with active sonar.
##
## Difficulty controls AI BEHAVIOR, not physics:
##   Easy:    Predictable transit, no counterattack, slow reaction
##   Normal:  Sprint-and-drift, baffle clears, evade when detected, cornered-only attack
##   Hard:    Full doctrine. Aggressive baffle clears, counterattack on good solution, coordination
##   Elite:   Hard + terrain exploitation, ambush positioning near predicted player track
##
## Follows existing subsystem pattern: extends RefCounted, _world reference,
## initialize(world), signals emit through _world.

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

# ---------------------------------------------------------------------------
# Doctrine state enum -- per-unit state machine
# ---------------------------------------------------------------------------
enum DoctrineState {
	TRANSIT = 0,
	DETECTED = 1,
	ATTACK = 2,
	EVASION = 3,
}

# Difficulty presets -- controls AI behavior parameters
enum DifficultyLevel {
	EASY = 0,
	NORMAL = 1,
	HARD = 2,
	ELITE = 3,
}

# ---------------------------------------------------------------------------
# Per-unit doctrine state. Key: unit_id, Value: Dictionary
# ---------------------------------------------------------------------------
var _unit_doctrine: Dictionary = {}

# ---------------------------------------------------------------------------
# Difficulty parameters (loaded from scenario or set globally)
# ---------------------------------------------------------------------------
var _difficulty_level: int = DifficultyLevel.NORMAL

# Difficulty-dependent behavior parameters
var _params: Dictionary = {}

const DIFFICULTY_PARAMS := {
	DifficultyLevel.EASY: {
		"sprint_drift_enabled": false,
		"baffle_clear_enabled": false,
		"counterattack_enabled": false,
		"evasion_sprint_perpendicular": false,
		"reaction_delay_ticks": 30,      # 30 seconds before responding to detection
		"attack_solution_threshold": 0.9, # Very high -- almost never attacks
		"formation_discipline": false,
		"terrain_exploitation": false,
		"ambush_positioning": false,
		"noisemaker_on_evasion": false,
	},
	DifficultyLevel.NORMAL: {
		"sprint_drift_enabled": true,
		"baffle_clear_enabled": true,
		"counterattack_enabled": true,    # Only when cornered
		"evasion_sprint_perpendicular": true,
		"reaction_delay_ticks": 10,
		"attack_solution_threshold": 0.65, # Moderate -- attacks when cornered with decent solution
		"formation_discipline": true,
		"terrain_exploitation": false,
		"ambush_positioning": false,
		"noisemaker_on_evasion": true,
	},
	DifficultyLevel.HARD: {
		"sprint_drift_enabled": true,
		"baffle_clear_enabled": true,
		"counterattack_enabled": true,
		"evasion_sprint_perpendicular": true,
		"reaction_delay_ticks": 3,
		"attack_solution_threshold": 0.45, # Aggressive -- attacks with moderate solution
		"formation_discipline": true,
		"terrain_exploitation": false,
		"ambush_positioning": false,
		"noisemaker_on_evasion": true,
	},
	DifficultyLevel.ELITE: {
		"sprint_drift_enabled": true,
		"baffle_clear_enabled": true,
		"counterattack_enabled": true,
		"evasion_sprint_perpendicular": true,
		"reaction_delay_ticks": 1,
		"attack_solution_threshold": 0.35, # Very aggressive
		"formation_discipline": true,
		"terrain_exploitation": true,
		"ambush_positioning": true,
		"noisemaker_on_evasion": true,
	},
}

# ---------------------------------------------------------------------------
# Sprint-and-drift timing constants (sim seconds)
# ---------------------------------------------------------------------------
const SPRINT_SPEED_MIN_KTS: float = 12.0
const SPRINT_SPEED_MAX_KTS: float = 18.0
const SPRINT_DURATION_MIN: float = 480.0   # 8 minutes
const SPRINT_DURATION_MAX: float = 900.0   # 15 minutes
const DRIFT_SPEED_MIN_KTS: float = 3.0
const DRIFT_SPEED_MAX_KTS: float = 5.0
const DRIFT_DURATION_MIN: float = 900.0    # 15 minutes
const DRIFT_DURATION_MAX: float = 1200.0   # 20 minutes
const BAFFLE_CLEAR_TURN_DEG_MIN: float = 90.0
const BAFFLE_CLEAR_TURN_DEG_MAX: float = 120.0

# Evasion constants
const EVASION_SPRINT_SPEED_MIN_KTS: float = 15.0
const EVASION_SPRINT_SPEED_MAX_KTS: float = 18.0
const EVASION_SPRINT_DURATION_MIN: float = 300.0  # 5 minutes
const EVASION_SPRINT_DURATION_MAX: float = 600.0  # 10 minutes
const EVASION_REASSESS_DURATION_MIN: float = 600.0  # 10 minutes
const EVASION_REASSESS_DURATION_MAX: float = 900.0  # 15 minutes
const EVASION_CREEP_SPEED_KTS: float = 3.0

# Surface formation constants
const SCREEN_DISTANCE_NM_MIN: float = 5.0
const SCREEN_DISTANCE_NM_MAX: float = 10.0

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

## Set difficulty level from scenario data.
func set_difficulty(level: int) -> void:
	_difficulty_level = clampi(level, DifficultyLevel.EASY, DifficultyLevel.ELITE)
	_params = DIFFICULTY_PARAMS.get(_difficulty_level, DIFFICULTY_PARAMS[DifficultyLevel.NORMAL]).duplicate()

## Map scenario difficulty dict to a DifficultyLevel.
## Reads "ai_doctrine_level" key. Falls back to inferring from ai_attack_threshold.
func set_difficulty_from_scenario(diff_dict: Dictionary) -> void:
	if diff_dict.has("ai_doctrine_level"):
		set_difficulty(diff_dict["ai_doctrine_level"])
		return
	# Infer from existing attack threshold: lower threshold = harder AI
	var threshold: float = diff_dict.get("ai_attack_threshold", 0.3)
	if threshold >= 0.4:
		set_difficulty(DifficultyLevel.EASY)
	elif threshold >= 0.25:
		set_difficulty(DifficultyLevel.NORMAL)
	elif threshold >= 0.15:
		set_difficulty(DifficultyLevel.HARD)
	else:
		set_difficulty(DifficultyLevel.ELITE)

# ---------------------------------------------------------------------------
# Per-unit initialization and cleanup
# ---------------------------------------------------------------------------

## Initialize doctrine state for a newly spawned enemy unit.
## Only registers combat vessels (SSN, DDG, CGN, DD, FFG). Helicopters, MPA,
## and merchant vessels are NOT registered -- they keep legacy AI behavior.
func init_unit_doctrine(unit_id: String) -> void:
	if unit_id not in _world.units:
		return
	var u: Dictionary = _world.units[unit_id]
	if u["faction"] == "player":
		return  # Player units don't get AI doctrine
	# Only register combat platform types
	var combat_types := ["SSN", "DDG", "CGN", "DD", "FFG"]
	var platform_type: String = u["platform"].get("type", "")
	if platform_type not in combat_types:
		return  # Helos, MPA, merchants keep legacy AI

	var doctrine := {
		"state": DoctrineState.TRANSIT,
		"platform_type": platform_type,
		# Sprint-and-drift state (submarines)
		"sprint_drift_phase": "sprint",  # "sprint" | "drift" | "baffle_clear"
		"phase_end_tick": 0,
		"baffle_clear_target_heading": 0.0,
		"baffle_clear_complete": false,
		# Detection/evasion state
		"detected_tick": 0,           # When counter-detection was first noticed
		"threat_bearing": 0.0,        # Bearing TO the threat
		"evasion_end_tick": 0,        # When evasion sprint ends
		"reassess_end_tick": 0,       # When reassessment period ends
		# Attack state
		"attack_target_id": "",
		"has_fired": false,
		"fire_tick": 0,
		# Surface group state
		"formation_leader_id": "",    # Kirov ID for Udaloy escorts
		"formation_bearing": 0.0,    # Bearing FROM leader to this unit
		"prosecuting_sub": false,     # Udaloy actively hunting sub
		"prosecution_target_id": "",
		# Pause before adaptation (Soviet captains don't freelance)
		"adaptation_pause_until": 0,
	}

	_unit_doctrine[unit_id] = doctrine

	# Set up initial sprint-and-drift for submarines
	if platform_type == "SSN" and _params.get("sprint_drift_enabled", false):
		_start_sprint_phase(unit_id, doctrine)
	elif platform_type == "SSN":
		# Easy mode: just patrol at steady speed
		u["speed_kts"] = u["max_speed_kts"] * 0.3

## Remove a unit from doctrine tracking.
func remove_unit(unit_id: String) -> void:
	_unit_doctrine.erase(unit_id)

## Reset all doctrine state (scenario load).
func reset() -> void:
	_unit_doctrine.clear()
	_params = DIFFICULTY_PARAMS.get(_difficulty_level, DIFFICULTY_PARAMS[DifficultyLevel.NORMAL]).duplicate()

# ---------------------------------------------------------------------------
# Main tick -- called once per sim tick from SimulationWorld._run_ai_behaviors()
# ---------------------------------------------------------------------------

## Process all AI doctrine behaviors for one tick.
## Call this INSTEAD of the old per-unit behavior match in _run_ai_behaviors().
func tick_update() -> void:
	_process_surface_group_formations()

	for unit_id in _unit_doctrine:
		if unit_id not in _world.units:
			continue
		var u: Dictionary = _world.units[unit_id]
		if not u["is_alive"] or u["faction"] == "player":
			continue

		var doctrine: Dictionary = _unit_doctrine[unit_id]
		var platform_type: String = doctrine["platform_type"]

		# Skip airborne units -- they keep existing helo AI behavior
		if u.get("is_airborne", false):
			continue

		# Skip units with special behaviors that doctrine should not override
		# evasive_patrol = ceasefire behavior, hold = stationary, rtb = returning home
		var unit_behavior: String = u.get("behavior", "")
		if unit_behavior == "evasive_patrol" or unit_behavior == "hold" or unit_behavior == "rtb":
			continue

		# Adaptation pause: Soviet captains don't freelance. When plans fail,
		# there's a pause before adaptation.
		if doctrine["adaptation_pause_until"] > 0 and _world.tick_count < doctrine["adaptation_pause_until"]:
			continue

		# Check for state transitions based on external events
		_check_state_transitions(unit_id, u, doctrine)

		# Execute current state behavior
		match doctrine["state"]:
			DoctrineState.TRANSIT:
				if platform_type == "SSN":
					_submarine_transit(unit_id, u, doctrine)
				else:
					_surface_transit(unit_id, u, doctrine)
			DoctrineState.DETECTED:
				if platform_type == "SSN":
					_submarine_detected(unit_id, u, doctrine)
				else:
					_surface_detected(unit_id, u, doctrine)
			DoctrineState.ATTACK:
				if platform_type == "SSN":
					_submarine_attack(unit_id, u, doctrine)
				else:
					_surface_attack(unit_id, u, doctrine)
			DoctrineState.EVASION:
				if platform_type == "SSN":
					_submarine_evasion(unit_id, u, doctrine)
				else:
					_surface_evasion(unit_id, u, doctrine)

# ---------------------------------------------------------------------------
# State transition checks
# ---------------------------------------------------------------------------

## Check if the unit should transition to a different doctrine state.
func _check_state_transitions(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var platform_type: String = doctrine["platform_type"]
	var current_state: int = doctrine["state"]

	# 1. Check for counter-detection events (TRANSIT -> DETECTED)
	if current_state == DoctrineState.TRANSIT:
		if _is_unit_counter_detected(unit_id, u):
			var delay: int = _params.get("reaction_delay_ticks", 10)
			if doctrine["detected_tick"] == 0:
				# First detection -- start reaction delay
				doctrine["detected_tick"] = _world.tick_count
			elif _world.tick_count - doctrine["detected_tick"] >= delay:
				# Reaction delay elapsed -- transition to DETECTED
				_transition_to_detected(unit_id, u, doctrine)

	# 2. Check for attack opportunity (any state -> ATTACK)
	if current_state != DoctrineState.ATTACK and current_state != DoctrineState.EVASION:
		if _params.get("counterattack_enabled", false):
			_check_attack_opportunity(unit_id, u, doctrine)

	# 3. Incoming weapon detection (any state -> EVASION for subs, surface ships handle differently)
	if current_state != DoctrineState.EVASION:
		if _is_weapon_incoming(unit_id):
			if platform_type == "SSN":
				_transition_to_evasion(unit_id, u, doctrine, doctrine.get("threat_bearing", 0.0))

# ---------------------------------------------------------------------------
# TRANSIT state behaviors
# ---------------------------------------------------------------------------

## Submarine TRANSIT: sprint-and-drift with baffle-clearing turns.
func _submarine_transit(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	if not _params.get("sprint_drift_enabled", false):
		# Easy mode: straight-line patrol at constant speed
		_easy_submarine_patrol(unit_id, u, doctrine)
		return

	var phase: String = doctrine["sprint_drift_phase"]
	var phase_end: int = doctrine["phase_end_tick"]

	match phase:
		"sprint":
			if _world.tick_count >= phase_end:
				# Sprint complete -- transition to drift/listen
				_start_drift_phase(unit_id, u, doctrine)
			# else: maintain sprint speed and heading (waypoints handle course)

		"drift":
			if _world.tick_count >= phase_end:
				# Drift complete -- execute baffle-clearing turn
				if _params.get("baffle_clear_enabled", false):
					_start_baffle_clear(unit_id, u, doctrine)
				else:
					# No baffle clear -- go straight to sprint
					_start_sprint_phase(unit_id, doctrine)
			else:
				# During drift: slow speed, listen
				u["speed_kts"] = clampf(u["speed_kts"], DRIFT_SPEED_MIN_KTS, DRIFT_SPEED_MAX_KTS)

		"baffle_clear":
			# Execute the turn, then resume sprint
			_execute_baffle_clear(unit_id, u, doctrine)

## Surface TRANSIT: maintain course, formation if applicable.
func _surface_transit(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	# Surface units in transit just follow their patrol waypoints
	# Formation keeping is handled by _process_surface_group_formations()

	# Check contacts -- if we detect a player unit, evaluate for attack
	var attack_threshold: float = _world.difficulty.get("ai_attack_threshold", 0.3)
	for target_id in u.get("contacts", {}):
		if target_id in _world.units and _world.units[target_id]["faction"] == "player":
			var det: Dictionary = u["contacts"][target_id]
			if det.get("confidence", 0.0) > attack_threshold:
				_transition_to_attack(unit_id, u, doctrine, target_id)
				return

	# Patrol behavior (reuse existing patrol logic for waypoint management)
	if u["waypoints"].size() == 0:
		if not doctrine.has("home") or doctrine["home"] == Vector2.ZERO:
			doctrine["home"] = Vector2(u["position"])
		var home: Vector2 = doctrine.get("home", u["position"])
		var offset := Vector2(
			_rng.randf_range(-20.0, 20.0),
			_rng.randf_range(-20.0, 20.0)
		)
		var candidate: Vector2 = u["position"] + offset
		if candidate.distance_to(home) > 25.0:
			candidate = home + (candidate - home).normalized() * 25.0
		u["waypoints"] = [candidate]
		u["speed_kts"] = u["max_speed_kts"] * 0.3

## Easy-mode submarine patrol: straight line, constant speed, no sprint-and-drift.
func _easy_submarine_patrol(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	if u["waypoints"].size() == 0:
		if not doctrine.has("home") or doctrine["home"] == Vector2.ZERO:
			doctrine["home"] = Vector2(u["position"])
		var home: Vector2 = doctrine.get("home", u["position"])
		var offset := Vector2(
			_rng.randf_range(-20.0, 20.0),
			_rng.randf_range(-20.0, 20.0)
		)
		var candidate: Vector2 = u["position"] + offset
		if candidate.distance_to(home) > 25.0:
			candidate = home + (candidate - home).normalized() * 25.0
		u["waypoints"] = [candidate]
	u["speed_kts"] = u["max_speed_kts"] * 0.3  # Constant slow speed

# ---------------------------------------------------------------------------
# Sprint-and-drift phase management
# ---------------------------------------------------------------------------

func _start_sprint_phase(unit_id: String, doctrine: Dictionary) -> void:
	doctrine["sprint_drift_phase"] = "sprint"
	var duration: float = _rng.randf_range(SPRINT_DURATION_MIN, SPRINT_DURATION_MAX)
	doctrine["phase_end_tick"] = _world.tick_count + int(duration)
	# Set sprint speed
	if unit_id in _world.units:
		var u: Dictionary = _world.units[unit_id]
		var sprint_speed: float = _rng.randf_range(SPRINT_SPEED_MIN_KTS, SPRINT_SPEED_MAX_KTS)
		u["speed_kts"] = minf(sprint_speed, u["max_speed_kts"])

func _start_drift_phase(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	doctrine["sprint_drift_phase"] = "drift"
	var duration: float = _rng.randf_range(DRIFT_DURATION_MIN, DRIFT_DURATION_MAX)
	doctrine["phase_end_tick"] = _world.tick_count + int(duration)
	# Slow to drift speed
	u["speed_kts"] = _rng.randf_range(DRIFT_SPEED_MIN_KTS, DRIFT_SPEED_MAX_KTS)

func _start_baffle_clear(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	doctrine["sprint_drift_phase"] = "baffle_clear"
	doctrine["baffle_clear_complete"] = false
	# Turn 90-120 degrees from current heading to sweep the blind zone astern
	var turn_angle: float = _rng.randf_range(BAFFLE_CLEAR_TURN_DEG_MIN, BAFFLE_CLEAR_TURN_DEG_MAX)
	# Randomly turn left or right
	if _rng.randf() > 0.5:
		turn_angle = -turn_angle
	var target_heading: float = fmod(u["heading"] + turn_angle + 360.0, 360.0)
	doctrine["baffle_clear_target_heading"] = target_heading
	# Maintain drift speed during baffle clear
	u["speed_kts"] = _rng.randf_range(DRIFT_SPEED_MIN_KTS, DRIFT_SPEED_MAX_KTS)

func _execute_baffle_clear(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var target_heading: float = doctrine["baffle_clear_target_heading"]
	var current_heading: float = u["heading"]

	# Turn toward target heading at 3 deg/tick (slower than waypoint steering)
	var diff: float = fmod(target_heading - current_heading + 540.0, 360.0) - 180.0
	if absf(diff) < 3.0:
		# Baffle clear turn complete
		u["heading"] = target_heading
		_world.unit_heading_changed.emit(unit_id, u["heading"])
		# Resume sprint
		_start_sprint_phase(unit_id, doctrine)
	else:
		var turn: float = clampf(diff, -3.0, 3.0)
		u["heading"] = fmod(current_heading + turn + 360.0, 360.0)
		_world.unit_heading_changed.emit(unit_id, u["heading"])
		# Clear waypoints during baffle clear so waypoint steering doesn't interfere
		u["waypoints"] = []

# ---------------------------------------------------------------------------
# DETECTED state behaviors
# ---------------------------------------------------------------------------

## Submarine DETECTED: go deep below thermal layer, sprint perpendicular, deploy countermeasures.
func _submarine_detected(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var thermal_depth: float = _world.environment.get("thermal_layer_depth_m", 75.0)

	# Step 1: Go deep below thermal layer (Phase 4 built this -- reuse the pattern)
	if absf(u["depth_m"]) < thermal_depth + 50.0:
		var deep_depth: float = -(thermal_depth + 100.0)
		u["ordered_depth_m"] = deep_depth
		if absf(u["depth_m"]) < thermal_depth:
			# Still above thermal layer -- emit the going-deep signal
			_world.submarine_went_deep.emit(unit_id, deep_depth)
			# Degrade TMA tracking on this unit
			if _world.get("_tma_system") and _world._tma_system:
				_world._tma_system.target_went_deep(unit_id)

	# Step 2: Sprint perpendicular to threat bearing
	if _params.get("evasion_sprint_perpendicular", true):
		var threat_brg: float = doctrine["threat_bearing"]
		# Perpendicular = threat bearing +/- 90
		var perp_heading: float
		if _rng.randf() > 0.5:
			perp_heading = fmod(threat_brg + 90.0, 360.0)
		else:
			perp_heading = fmod(threat_brg - 90.0 + 360.0, 360.0)
		var sprint_speed: float = _rng.randf_range(EVASION_SPRINT_SPEED_MIN_KTS, EVASION_SPRINT_SPEED_MAX_KTS)
		u["speed_kts"] = minf(sprint_speed, u["max_speed_kts"])
		# Set waypoint along perpendicular heading
		var heading_rad: float = deg_to_rad(perp_heading)
		var run_distance: float = 15.0  # Run 15 NM perpendicular
		u["waypoints"] = [u["position"] + Vector2(sin(heading_rad), cos(heading_rad)) * run_distance]
	else:
		# Non-perpendicular evasion: just run away from threat
		var away_heading: float = fmod(doctrine["threat_bearing"] + 180.0, 360.0)
		var heading_rad: float = deg_to_rad(away_heading)
		u["waypoints"] = [u["position"] + Vector2(sin(heading_rad), cos(heading_rad)) * 15.0]
		u["speed_kts"] = u["max_speed_kts"] * 0.5

	# Step 3: Deploy noisemaker if available
	if _params.get("noisemaker_on_evasion", true):
		if _world.get("_weapon_system") and _world._weapon_system:
			_world._weapon_system.launch_noisemaker(unit_id)

	# Step 4: After evasion sprint duration, transition to slow/listen/reassess
	if doctrine["evasion_end_tick"] == 0:
		var sprint_duration: float = _rng.randf_range(EVASION_SPRINT_DURATION_MIN, EVASION_SPRINT_DURATION_MAX)
		doctrine["evasion_end_tick"] = _world.tick_count + int(sprint_duration)
	elif _world.tick_count >= doctrine["evasion_end_tick"]:
		# Sprint complete -- slow down, go silent, reassess
		u["speed_kts"] = EVASION_CREEP_SPEED_KTS
		u["waypoints"] = []
		# Soviet captain pause: 5-10 second hesitation before deciding next action
		doctrine["adaptation_pause_until"] = _world.tick_count + _rng.randi_range(5, 10)
		# Transition to EVASION state for reassessment phase
		_transition_to_evasion(unit_id, u, doctrine, doctrine["threat_bearing"])

## Surface DETECTED: launch P-700 salvo (Kirov), prosecute with active sonar (Udaloy).
func _surface_detected(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var platform_type: String = u["platform"].get("type", "")

	if platform_type == "CGN":
		# Kirov: maneuver away from threat axis
		var threat_brg: float = doctrine["threat_bearing"]
		var away_heading: float = fmod(threat_brg + 180.0, 360.0)
		var heading_rad: float = deg_to_rad(away_heading)
		u["waypoints"] = [u["position"] + Vector2(sin(heading_rad), cos(heading_rad)) * 20.0]
		u["speed_kts"] = u["max_speed_kts"] * 0.8
		# Transition to attack -- Kirov fires on detection
		_transition_to_attack(unit_id, u, doctrine, doctrine.get("attack_target_id", ""))
	else:
		# Udaloy: close to prosecute submarine contact with active sonar
		doctrine["prosecuting_sub"] = true
		u["emitting_sonar_active"] = true
		var target_id: String = doctrine.get("prosecution_target_id", "")
		if target_id != "" and target_id in _world.units:
			u["waypoints"] = [_world.units[target_id]["position"]]
			u["speed_kts"] = u["max_speed_kts"] * 0.7
		# Transition to attack state once closing
		_transition_to_attack(unit_id, u, doctrine, target_id)

# ---------------------------------------------------------------------------
# ATTACK state behaviors
# ---------------------------------------------------------------------------

## Submarine ATTACK: fire torpedo at estimated position, then immediately evade.
func _submarine_attack(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var target_id: String = doctrine["attack_target_id"]
	if target_id == "" or target_id not in _world.units or not _world.units[target_id]["is_alive"]:
		# Target gone -- return to transit
		_transition_to_transit(unit_id, u, doctrine)
		return

	if not doctrine["has_fired"]:
		# Fire weapon at target
		var dist: float = u["position"].distance_to(_world.units[target_id]["position"])
		_ai_try_fire_torpedo(unit_id, u, target_id, dist)
		doctrine["has_fired"] = true
		doctrine["fire_tick"] = _world.tick_count

		# Immediately transition to EVASION: shoot and run
		# Do NOT loiter after firing
		var threat_brg: float = _bearing_to(u["position"], _world.units[target_id]["position"])
		# Soviet captain pause: brief hesitation after firing before executing evasion plan
		doctrine["adaptation_pause_until"] = _world.tick_count + _rng.randi_range(3, 8)
		_transition_to_evasion(unit_id, u, doctrine, threat_brg)
	else:
		# Already fired -- should be in evasion, but if we somehow are still in ATTACK, evade
		var threat_brg: float = doctrine.get("threat_bearing", 0.0)
		_transition_to_evasion(unit_id, u, doctrine, threat_brg)

## Surface ATTACK: fire weapons at detected targets, coordinate salvos.
func _surface_attack(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var target_id: String = doctrine["attack_target_id"]
	if target_id == "" or target_id not in _world.units or not _world.units[target_id]["is_alive"]:
		# Target gone -- return to transit
		_transition_to_transit(unit_id, u, doctrine)
		return

	var target: Dictionary = _world.units[target_id]
	var dist: float = u["position"].distance_to(target["position"])

	# Fire at target (using existing fire logic but through doctrine)
	if (_world.tick_count + unit_id.hash()) % 5 == 0:
		_ai_try_fire_weapon(unit_id, u, target_id, dist)

	# Post-fire evasion for surface ships
	var evade_until: int = doctrine.get("post_fire_evade_tick", 0)
	if evade_until > 0 and _world.tick_count < evade_until:
		var away: Vector2 = (u["position"] - target["position"]).normalized()
		u["waypoints"] = [u["position"] + away * 10.0]
		u["speed_kts"] = u["max_speed_kts"]
		return
	elif evade_until > 0:
		doctrine.erase("post_fire_evade_tick")

	# Udaloy prosecuting a sub: close with active sonar
	var platform_type: String = u["platform"].get("type", "")
	if platform_type == "DDG" and doctrine.get("prosecuting_sub", false):
		u["emitting_sonar_active"] = true
		u["waypoints"] = [target["position"]]
		u["speed_kts"] = u["max_speed_kts"] * 0.7
		return

	# Standard surface engagement: close to weapon range, maintain standoff
	var best_range: float = _world._weapon_system.get_best_weapon_range(u)
	if dist > best_range * 0.8:
		u["waypoints"] = [target["position"]]
		u["speed_kts"] = u["max_speed_kts"] * 0.7
	else:
		var away: Vector2 = (u["position"] - target["position"]).normalized()
		u["waypoints"] = [target["position"] + away * best_range * 0.6]
		u["speed_kts"] = u["max_speed_kts"] * 0.5

# ---------------------------------------------------------------------------
# EVASION state behaviors
# ---------------------------------------------------------------------------

## Submarine EVASION: sprint perpendicular, deep, deploy countermeasures, reassess.
func _submarine_evasion(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var thermal_depth: float = _world.environment.get("thermal_layer_depth_m", 75.0)

	# Ensure we stay deep
	if absf(u["depth_m"]) < thermal_depth + 50.0:
		u["ordered_depth_m"] = -(thermal_depth + 100.0)

	# Reassessment period: slow, listen
	if doctrine["reassess_end_tick"] == 0:
		var reassess_duration: float = _rng.randf_range(EVASION_REASSESS_DURATION_MIN, EVASION_REASSESS_DURATION_MAX)
		doctrine["reassess_end_tick"] = _world.tick_count + int(reassess_duration)
		u["speed_kts"] = EVASION_CREEP_SPEED_KTS
		u["waypoints"] = []

	if _world.tick_count >= doctrine["reassess_end_tick"]:
		# Reassessment complete -- check if still being tracked
		if _is_unit_counter_detected(unit_id, u):
			# Still tracked -- continue evasion on new bearing
			var new_threat_brg: float = _get_latest_threat_bearing(unit_id, u)
			doctrine["threat_bearing"] = new_threat_brg
			doctrine["reassess_end_tick"] = 0
			doctrine["evasion_end_tick"] = 0
			# Sprint perpendicular again
			_transition_to_detected(unit_id, u, doctrine)
		else:
			# Clear -- return to transit
			# Soviet captain pause before resuming normal ops
			doctrine["adaptation_pause_until"] = _world.tick_count + _rng.randi_range(10, 20)
			_transition_to_transit(unit_id, u, doctrine)

## Surface EVASION: run from threat.
func _surface_evasion(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	# Surface ships evade: run away from nearest threat
	var nearest_threat_pos: Vector2 = Vector2.ZERO
	var nearest_dist: float = 999999.0
	for target_id in u.get("contacts", {}):
		if target_id in _world.units and _world.units[target_id]["faction"] == "player":
			var d: float = u["position"].distance_to(_world.units[target_id]["position"])
			if d < nearest_dist:
				nearest_dist = d
				nearest_threat_pos = _world.units[target_id]["position"]

	if nearest_dist < 999999.0:
		var away: Vector2 = (u["position"] - nearest_threat_pos).normalized()
		u["waypoints"] = [u["position"] + away * 30.0]
		u["speed_kts"] = u["max_speed_kts"]
	else:
		# No contacts -- return to transit
		_transition_to_transit(unit_id, u, doctrine)

# ---------------------------------------------------------------------------
# State transitions
# ---------------------------------------------------------------------------

func _transition_to_transit(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	doctrine["state"] = DoctrineState.TRANSIT
	doctrine["detected_tick"] = 0
	doctrine["evasion_end_tick"] = 0
	doctrine["reassess_end_tick"] = 0
	doctrine["has_fired"] = false
	doctrine["attack_target_id"] = ""
	doctrine["prosecuting_sub"] = false
	doctrine["prosecution_target_id"] = ""
	# Re-initialize sprint-and-drift for submarines
	if doctrine["platform_type"] == "SSN" and _params.get("sprint_drift_enabled", false):
		_start_sprint_phase(unit_id, doctrine)

func _transition_to_detected(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	doctrine["state"] = DoctrineState.DETECTED
	doctrine["evasion_end_tick"] = 0
	doctrine["reassess_end_tick"] = 0
	if doctrine["threat_bearing"] == 0.0:
		doctrine["threat_bearing"] = _get_latest_threat_bearing(unit_id, u)

func _transition_to_attack(unit_id: String, u: Dictionary, doctrine: Dictionary, target_id: String) -> void:
	doctrine["state"] = DoctrineState.ATTACK
	doctrine["attack_target_id"] = target_id
	doctrine["has_fired"] = false

func _transition_to_evasion(unit_id: String, u: Dictionary, doctrine: Dictionary, threat_bearing: float) -> void:
	doctrine["state"] = DoctrineState.EVASION
	doctrine["threat_bearing"] = threat_bearing
	doctrine["evasion_end_tick"] = 0
	doctrine["reassess_end_tick"] = 0

	# Deploy countermeasures on evasion entry
	if _params.get("noisemaker_on_evasion", true) and doctrine["platform_type"] == "SSN":
		if _world.get("_weapon_system") and _world._weapon_system:
			_world._weapon_system.launch_noisemaker(unit_id)

	# Sprint perpendicular to threat, deep
	if doctrine["platform_type"] == "SSN":
		var thermal_depth: float = _world.environment.get("thermal_layer_depth_m", 75.0)
		u["ordered_depth_m"] = -(thermal_depth + 100.0)

		if _params.get("evasion_sprint_perpendicular", true):
			var perp_heading: float
			if _rng.randf() > 0.5:
				perp_heading = fmod(threat_bearing + 90.0, 360.0)
			else:
				perp_heading = fmod(threat_bearing - 90.0 + 360.0, 360.0)
			var heading_rad: float = deg_to_rad(perp_heading)
			u["waypoints"] = [u["position"] + Vector2(sin(heading_rad), cos(heading_rad)) * 15.0]
		u["speed_kts"] = minf(
			_rng.randf_range(EVASION_SPRINT_SPEED_MIN_KTS, EVASION_SPRINT_SPEED_MAX_KTS),
			u["max_speed_kts"]
		)

# ---------------------------------------------------------------------------
# Soviet Surface Group Doctrine
# ---------------------------------------------------------------------------

## Process formation keeping for Soviet surface groups.
## Udaloys screen Kirov at 5-10nm formation distance.
## Radar active continuously (they don't care about being seen).
func _process_surface_group_formations() -> void:
	if not _params.get("formation_discipline", false):
		return

	# Find all Kirov-class units (formation leaders)
	var kirov_ids: Array = []
	for unit_id in _unit_doctrine:
		if unit_id not in _world.units:
			continue
		var u: Dictionary = _world.units[unit_id]
		if u["is_alive"] and u["platform"].get("type", "") == "CGN":
			kirov_ids.append(unit_id)

	# For each Kirov, assign nearby Udaloys as escorts
	for kirov_id in kirov_ids:
		var kirov: Dictionary = _world.units[kirov_id]
		var kirov_doctrine: Dictionary = _unit_doctrine.get(kirov_id, {})

		# Kirov: radar always active
		kirov["emitting_radar"] = true

		for unit_id in _unit_doctrine:
			if unit_id == kirov_id or unit_id not in _world.units:
				continue
			var u: Dictionary = _world.units[unit_id]
			var doctrine: Dictionary = _unit_doctrine[unit_id]

			if not u["is_alive"] or u["platform"].get("type", "") != "DDG":
				continue

			# Only escort if in TRANSIT state and not prosecuting a sub
			if doctrine["state"] != DoctrineState.TRANSIT or doctrine.get("prosecuting_sub", false):
				continue

			# Udaloys: radar always active
			u["emitting_radar"] = true

			# Maintain screen distance from Kirov
			var dist: float = u["position"].distance_to(kirov["position"])
			var screen_dist: float = _rng.randf_range(SCREEN_DISTANCE_NM_MIN, SCREEN_DISTANCE_NM_MAX)

			if dist > screen_dist * 1.5:
				# Too far from Kirov -- close up
				u["waypoints"] = [kirov["position"]]
				u["speed_kts"] = u["max_speed_kts"] * 0.7
				doctrine["formation_leader_id"] = kirov_id
			elif dist < screen_dist * 0.5:
				# Too close -- spread out
				var away: Vector2 = (u["position"] - kirov["position"]).normalized()
				u["waypoints"] = [u["position"] + away * 5.0]
				u["speed_kts"] = kirov.get("speed_kts", 15.0)
			else:
				# Good position -- match Kirov speed and heading
				u["speed_kts"] = kirov.get("speed_kts", 15.0)
				doctrine["formation_leader_id"] = kirov_id

		# On attack detection: all units in formation fire at detected launcher position
		if kirov_doctrine.get("state", DoctrineState.TRANSIT) == DoctrineState.ATTACK:
			_coordinate_surface_group_attack(kirov_id, kirov)

## Coordinate a surface group salvo attack.
## On attack detection: all units fire P-700/torpedoes at detected launcher position.
func _coordinate_surface_group_attack(kirov_id: String, kirov: Dictionary) -> void:
	var kirov_doctrine: Dictionary = _unit_doctrine.get(kirov_id, {})
	var target_id: String = kirov_doctrine.get("attack_target_id", "")
	if target_id == "" or target_id not in _world.units:
		return

	# Signal all Udaloys in formation to attack the same target
	for unit_id in _unit_doctrine:
		if unit_id == kirov_id or unit_id not in _world.units:
			continue
		var u: Dictionary = _world.units[unit_id]
		var doctrine: Dictionary = _unit_doctrine[unit_id]
		if not u["is_alive"] or u["platform"].get("type", "") != "DDG":
			continue
		if doctrine.get("formation_leader_id", "") != kirov_id:
			continue

		# Udaloy closes to prosecute submarine contact with active sonar
		if _world.units[target_id]["platform"].get("type", "") == "SSN":
			doctrine["prosecuting_sub"] = true
			doctrine["prosecution_target_id"] = target_id
			_transition_to_attack(unit_id, u, doctrine, target_id)
		else:
			_transition_to_attack(unit_id, u, doctrine, target_id)

# ---------------------------------------------------------------------------
# Detection and threat assessment helpers
# ---------------------------------------------------------------------------

## Check if the AI unit has been counter-detected (player is tracking it).
## Uses CounterDetectionSystem log if available, falls back to contact check.
func _is_unit_counter_detected(unit_id: String, u: Dictionary) -> bool:
	# Method 1: Check CounterDetectionSystem (Phase 5) if integrated
	if _world.get("_counter_detection_system") and _world._counter_detection_system:
		if _world._counter_detection_system.was_counter_detected(unit_id, 60.0):
			return true

	# Method 2: Check if any player unit has a detection on this unit
	for player_uid in _world.units:
		var pu: Dictionary = _world.units[player_uid]
		if pu.get("faction", "") != "player" or not pu["is_alive"]:
			continue
		if unit_id in pu.get("contacts", {}):
			var det: Dictionary = pu["contacts"][unit_id]
			if det.get("confidence", 0.0) > 0.4:
				return true

	return false

## Get the bearing TO the most recent threat source.
func _get_latest_threat_bearing(unit_id: String, u: Dictionary) -> float:
	# Check CounterDetectionSystem for latest bearing
	if _world.get("_counter_detection_system") and _world._counter_detection_system:
		var latest: Dictionary = _world._counter_detection_system.get_latest_counter_detection(unit_id)
		if not latest.is_empty():
			# The bearing in counter-detection is FROM detector TO emitter
			# We want bearing FROM us TO the threat
			var emitter_id: String = latest.get("emitter_id", "")
			if emitter_id in _world.units:
				return _bearing_to(u["position"], _world.units[emitter_id]["position"])

	# Fallback: bearing to nearest player unit that has contact on us
	var nearest_dist: float = 999999.0
	var nearest_bearing: float = 0.0
	for player_uid in _world.units:
		var pu: Dictionary = _world.units[player_uid]
		if pu.get("faction", "") != "player" or not pu["is_alive"]:
			continue
		if unit_id in pu.get("contacts", {}):
			var d: float = u["position"].distance_to(pu["position"])
			if d < nearest_dist:
				nearest_dist = d
				nearest_bearing = _bearing_to(u["position"], pu["position"])
	return nearest_bearing

## Check if there is an incoming weapon targeting this unit.
func _is_weapon_incoming(unit_id: String) -> bool:
	for wid in _world.weapons_in_flight:
		var w: Dictionary = _world.weapons_in_flight[wid]
		if w["target_id"] == unit_id and not w["resolved"]:
			return true
	return false

## Check if the AI should initiate an attack (has good enough solution on a player unit).
func _check_attack_opportunity(unit_id: String, u: Dictionary, doctrine: Dictionary) -> void:
	var solution_threshold: float = _params.get("attack_solution_threshold", 0.65)

	for target_id in u.get("contacts", {}):
		if target_id not in _world.units:
			continue
		if _world.units[target_id]["faction"] != "player":
			continue
		if not _world.units[target_id]["is_alive"]:
			continue

		var det: Dictionary = u["contacts"][target_id]
		var confidence: float = det.get("confidence", 0.0)
		var tma_quality: float = det.get("tma_quality", 0.0)

		# Submarines use TMA quality for attack decision
		if doctrine["platform_type"] == "SSN":
			if tma_quality >= solution_threshold:
				_transition_to_attack(unit_id, u, doctrine, target_id)
				return
		else:
			# Surface ships use confidence
			if confidence >= solution_threshold:
				_transition_to_attack(unit_id, u, doctrine, target_id)
				return

# ---------------------------------------------------------------------------
# Weapon firing helpers
# ---------------------------------------------------------------------------

## AI submarine fires a torpedo at the target.
func _ai_try_fire_torpedo(unit_id: String, u: Dictionary, target_id: String, dist_nm: float) -> void:
	# Torpedo cooldown: 60 sim-seconds between shots
	var last_fire_tick: int = u["behavior_data"].get("last_fire_tick", 0)
	if _world.tick_count - last_fire_tick < 60:
		return

	for weapon_id in u["weapons_remaining"]:
		var wrec: Dictionary = u["weapons_remaining"][weapon_id]
		if wrec["count"] <= 0:
			continue
		var wdata: Dictionary = wrec["data"]
		if wdata.get("type", "") != "torpedo":
			continue
		var max_range: float = wdata.get("max_range_nm", 10.0)
		if dist_nm <= max_range:
			if _world._weapon_system.is_weapon_valid_for_target(wdata, _world.units[target_id]):
				_world.fire_weapon(unit_id, target_id, weapon_id)
				u["behavior_data"]["last_fire_tick"] = _world.tick_count
				return

## AI surface ship fires at the target (any valid weapon).
func _ai_try_fire_weapon(unit_id: String, u: Dictionary, target_id: String, dist_nm: float) -> void:
	var last_fire_tick: int = u["behavior_data"].get("last_fire_tick", 0)
	if _world.tick_count - last_fire_tick < 60:
		return

	for weapon_id in u["weapons_remaining"]:
		var wrec: Dictionary = u["weapons_remaining"][weapon_id]
		if wrec["count"] <= 0:
			continue
		var wdata: Dictionary = wrec["data"]
		var max_range: float = wdata.get("max_range_nm", 50.0)
		if dist_nm <= max_range:
			if _world._weapon_system.is_weapon_valid_for_target(wdata, _world.units[target_id]):
				_world.fire_weapon(unit_id, target_id, weapon_id)
				u["behavior_data"]["last_fire_tick"] = _world.tick_count
				# Surface fire-and-maneuver: evade for 30 ticks after firing
				if unit_id in _unit_doctrine:
					_unit_doctrine[unit_id]["post_fire_evade_tick"] = _world.tick_count + 30
				return

# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

## Compute bearing from point A to point B (degrees, 0=North, clockwise).
func _bearing_to(from_pos: Vector2, to_pos: Vector2) -> float:
	var delta: Vector2 = to_pos - from_pos
	var bearing: float = rad_to_deg(atan2(delta.x, delta.y))
	if bearing < 0.0:
		bearing += 360.0
	return bearing

# ---------------------------------------------------------------------------
# Query API for external systems
# ---------------------------------------------------------------------------

## Get the current doctrine state for a unit.
func get_doctrine_state(unit_id: String) -> int:
	if unit_id in _unit_doctrine:
		return _unit_doctrine[unit_id]["state"]
	return -1

## Get the sprint-and-drift phase for a submarine.
func get_sprint_drift_phase(unit_id: String) -> String:
	if unit_id in _unit_doctrine:
		return _unit_doctrine[unit_id].get("sprint_drift_phase", "")
	return ""

## Get the full doctrine dictionary for a unit (read-only copy).
func get_unit_doctrine(unit_id: String) -> Dictionary:
	if unit_id in _unit_doctrine:
		return _unit_doctrine[unit_id].duplicate()
	return {}

## Check if a unit is managed by the doctrine system.
func has_unit(unit_id: String) -> bool:
	return unit_id in _unit_doctrine

## Get doctrine state name for display/debug.
func get_state_name(state: int) -> String:
	match state:
		DoctrineState.TRANSIT: return "TRANSIT"
		DoctrineState.DETECTED: return "DETECTED"
		DoctrineState.ATTACK: return "ATTACK"
		DoctrineState.EVASION: return "EVASION"
		_: return "UNKNOWN"

## Get difficulty level name for display/debug.
func get_difficulty_name() -> String:
	match _difficulty_level:
		DifficultyLevel.EASY: return "EASY"
		DifficultyLevel.NORMAL: return "NORMAL"
		DifficultyLevel.HARD: return "HARD"
		DifficultyLevel.ELITE: return "ELITE"
		_: return "UNKNOWN"
