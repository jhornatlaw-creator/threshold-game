extends Node
## SimulationWorld -- Core simulation orchestrator (Autoload)
##
## Owns ALL unit state as Dictionaries. Runs fixed-tick loop at 1Hz base
## with time_scale multiplier. Emits signals on every state change.
## NO visual nodes -- pure data. Renderers subscribe to signals.
##
## Delegates to subsystems: MovementSystem, DetectionSystem, WeaponSystem, DamageSystem.

const MovementSystemScript = preload("res://scripts/MovementSystem.gd")
const DetectionSystemScript = preload("res://scripts/DetectionSystem.gd")
const WeaponSystemScript = preload("res://scripts/WeaponSystem.gd")
const DamageSystemScript = preload("res://scripts/DamageSystem.gd")
const TMASystemScript = preload("res://scripts/TMASystem.gd")
const SonobuoySystemScript = preload("res://scripts/SonobuoySystem.gd")
const AIDoctrineSystemScript = preload("res://scripts/AIDoctrineSystem.gd")
const ROESystemScript = preload("res://scripts/ROESystem.gd")
const CounterDetectionSystemScript = preload("res://scripts/CounterDetectionSystem.gd")
const EMCONSystemScript = preload("res://scripts/EMCONSystem.gd")
const ESMSystemScript = preload("res://scripts/ESMSystem.gd")
const RadarHorizonSystemScript = preload("res://scripts/RadarHorizonSystem.gd")

var _movement_system: RefCounted
var _detection_system: RefCounted
var _weapon_system: RefCounted
var _damage_system: RefCounted
var _tma_system: RefCounted
var _sonobuoy_system: RefCounted
var _ai_doctrine_system: RefCounted
var _roe_system: RefCounted
var _counter_detection_system: RefCounted
var _emcon_system: RefCounted
var _esm_system: RefCounted
var _radar_horizon_system: RefCounted

# ---------------------------------------------------------------------------
# Signals -- the ONLY interface renderers and UI may use
# ---------------------------------------------------------------------------
signal unit_spawned(unit_id: String, unit_data: Dictionary)
signal unit_moved(unit_id: String, old_pos: Vector2, new_pos: Vector2)
signal unit_heading_changed(unit_id: String, heading_deg: float)
signal unit_destroyed(unit_id: String)
signal unit_detected(detector_id: String, target_id: String, detection: Dictionary)
signal detection_lost(detector_id: String, target_id: String)
signal weapon_fired(weapon_id: String, shooter_id: String, target_id: String, weapon_data: Dictionary)
signal weapon_moved(weapon_id: String, old_pos: Vector2, new_pos: Vector2)
signal weapon_resolved(weapon_id: String, target_id: String, hit: bool, damage: float)
signal weapon_removed(weapon_id: String)
signal scenario_started(scenario_name: String)
signal scenario_ended(result: String)  # "victory" | "defeat" | "draw"
signal sim_tick(tick_number: int, sim_time: float)
signal time_scale_changed(new_scale: float)
signal contact_classified(detector_id: String, target_id: String, classification: Dictionary)
signal sosus_contact(barrier_id: String, bearing_deg: float, confidence: float)
signal helicopter_launched(parent_id: String, helo_id: String)
signal aircraft_bingo(aircraft_id: String, aircraft_name: String)
signal aircraft_landed(aircraft_id: String, aircraft_name: String)
signal aircraft_crashed(aircraft_id: String, aircraft_name: String)
signal weather_changed(sea_state: int, weather: String, visibility: float)
signal sonobuoy_deployed(buoy_id: String, position: Vector2, faction: String)
signal sonobuoy_contact(buoy_id: String, target_id: String, bearing_deg: float, snr: float)
signal sonobuoy_expired(buoy_id: String)
signal sonobuoy_dicass_contact(buoy_id: String, target_id: String, bearing_deg: float, range_nm: float, snr: float)
signal sonobuoy_dicass_alert(sub_id: String, buoy_id: String, bearing_to_buoy: float)
signal tma_contact_created(contact_id: String, bearing: float)
signal tma_solution_updated(contact_id: String, quality: float, estimated_pos: Vector2, uncertainty_radius: float)
signal tma_contact_lost(contact_id: String)
signal tma_solution_regressed(contact_id: String, old_quality: float, new_quality: float)
signal xbt_dropped(unit_id: String, position: Vector2, thermal_layer_depth_m: float)
signal submarine_went_deep(unit_id: String, ordered_depth_m: float)

# Phase 8/9: weapon lifecycle + countermeasure signals (emitted by WeaponSystem)
signal torpedo_launched(weapon_id: String, shooter_id: String)
signal weapon_impact(weapon_id: String, target_id: String, hit: bool)
signal kill_confirmed(target_id: String)
signal countermeasure_deployed(unit_id: String, cm_type: String)
signal countermeasure_recovered(unit_id: String, cm_type: String)
signal wire_cut(weapon_id: String)

# Phase 10: ROE + Classification + Crisis Temperature signals
signal roe_changed(new_state: int, old_state: int)
signal roe_blocked(shooter_id: String, target_id: String, reason: String)
signal contact_classification_changed(target_id: String, new_level: int, old_level: int)
signal crisis_temperature_changed(new_temp: float, old_temp: float, reason: String)

# Phase 5: Counter-Detection + EMCON + ESM + Radar Horizon signals
signal emcon_state_changed(unit_id: String, old_state: int, new_state: int)
signal counter_detection_event(detector_id: String, emitter_id: String, bearing: float)
signal esm_contact_detected(detector_id: String, emitter_id: String, bearing: float, radar_type: String)
signal radar_horizon_blocked(unit_id: String, target_id: String)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
const BASE_TICK_HZ: float = 1.0  # 1 Hz base tick rate
const MAX_TICKS_PER_FRAME: int = 20
const NM_TO_PIXELS: float = 10.0  # 1 nautical mile = 10 pixels (adjustable)
const KNOTS_TO_NM_PER_SEC: float = 1.0 / 3600.0  # 1 knot = 1 NM/hr

# Sea state effects on detection (multiplier on noise/clutter)
const SEA_STATE_RADAR_CLUTTER := {
	0: 0.0, 1: 0.05, 2: 0.10, 3: 0.20, 4: 0.35, 5: 0.50, 6: 0.70, 7: 0.90, 8: 1.0
}
const SEA_STATE_SONAR_NOISE := {
	0: 0.0, 1: 0.02, 2: 0.05, 3: 0.10, 4: 0.20, 5: 0.35, 6: 0.55, 7: 0.80, 8: 1.0
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var units: Dictionary = {}          # unit_id -> Dictionary
var weapons_in_flight: Dictionary = {}  # weapon_instance_id -> Dictionary
var contacts: Dictionary = {}       # detector_id -> { target_id -> detection_dict }
var scenario: Dictionary = {}       # current scenario data
var environment: Dictionary = {
	"sea_state": 3,
	"time_of_day": 12.0,  # 24hr clock
	"weather": "clear",
	"water_depth_m": 200.0,
	"bottom_depth_m": 200.0,
	"thermal_layer_depth_m": 75.0,
	"thermal_layer_strength": 0.8,
}

var sim_time: float = 0.0
var tick_count: int = 0
var time_scale: float = 1.0
var is_paused: bool = true
var _tick_accumulator: float = 0.0
var _next_weapon_id: int = 0
var _next_unit_id: int = 0
var _rng := RandomNumberGenerator.new()
var _next_designator: int = 1  # N-4: incrementing contact designator counter
var _unit_designators: Dictionary = {}  # target_id -> assigned designator string
var _game_over: bool = false  # Fix 4: prevent double scenario_ended emission
var _contact_accumulator: float = 0.0  # Cumulative seconds of contact for maintain_contact victory
var difficulty: Dictionary = {}  # Item 16: difficulty scaling from scenario
var sosus_barriers: Array = []  # Array of {id, start_pos, end_pos, sensitivity_db}
var sonobuoys: Dictionary = {}  # buoy_id -> {position, faction, deploy_time, battery_life, sensitivity_db, deployer_id}
var _next_buoy_id: int = 0

# XBT discovery mechanic: player starts with a briefing estimate of thermal layer depth.
# Actual depth is revealed only after dropping an XBT. Detection calculations for
# player units use the estimated value until XBT reveals the truth.
var _player_xbt_dropped: bool = false
var _estimated_thermal_depth_m: float = 75.0  # Briefing estimate (offset from actual)

# Weather / environment state
var weather_sea_state: int = 4
var weather_type: String = "overcast"  # clear, overcast, rain, storm
var weather_wind_kts: float = 15.0
var weather_visibility_nm: float = 20.0  # affects radar max range
var _last_weather_check_time: float = 0.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_rng.randomize()
	_movement_system = MovementSystemScript.new()
	_movement_system.initialize(self)
	_detection_system = DetectionSystemScript.new()
	_detection_system.initialize(self)
	_weapon_system = WeaponSystemScript.new()
	_weapon_system.initialize(self)
	_damage_system = DamageSystemScript.new()
	_damage_system.initialize(self)
	_tma_system = TMASystemScript.new()
	_tma_system.initialize(self)
	_sonobuoy_system = SonobuoySystemScript.new()
	_sonobuoy_system.initialize(self)
	_ai_doctrine_system = AIDoctrineSystemScript.new()
	_ai_doctrine_system.initialize(self)
	_roe_system = ROESystemScript.new()
	_roe_system.initialize(self)
	_counter_detection_system = CounterDetectionSystemScript.new()
	_counter_detection_system.initialize(self)
	_emcon_system = EMCONSystemScript.new()
	_emcon_system.initialize(self)
	_esm_system = ESMSystemScript.new()
	_esm_system.initialize(self)
	_radar_horizon_system = RadarHorizonSystemScript.new()
	_radar_horizon_system.initialize(self)
	# Phase 7: DICASS alert triggers AI evasion for alerted submarines
	sonobuoy_dicass_alert.connect(_on_dicass_alert_sub)
	set_process(true)

func _process(delta: float) -> void:
	if is_paused:
		return
	_tick_accumulator += delta * time_scale
	var tick_interval := 1.0 / BASE_TICK_HZ
	var ticks_this_frame: int = 0
	while _tick_accumulator >= tick_interval and ticks_this_frame < MAX_TICKS_PER_FRAME:
		_tick_accumulator -= tick_interval
		_sim_tick()
		ticks_this_frame += 1
	# Clamp accumulated deficit to prevent burst playback after lag spikes
	_tick_accumulator = minf(_tick_accumulator, tick_interval * MAX_TICKS_PER_FRAME)

# ---------------------------------------------------------------------------
# Tick pipeline
# ---------------------------------------------------------------------------
func _sim_tick() -> void:
	tick_count += 1
	sim_time += 1.0 / BASE_TICK_HZ
	_movement_system.move_units()
	_counter_detection_system.process_counter_detections()
	_run_ai_behaviors()
	_emcon_system.tick_update()
	_esm_system.process_esm_detections()
	_detection_system.update_detections()
	_sonobuoy_system.process_sonobuoys()
	_tma_system.tick_cleanup()
	_radar_horizon_system.tick_update()
	_emit_phase5_signals()
	_weapon_system.move_weapons()
	_weapon_system.resolve_weapons(_damage_system)
	_check_scenario_conditions()
	_detection_system.maybe_update_weather(sim_time)
	sim_tick.emit(tick_count, sim_time)

# ---------------------------------------------------------------------------
# Unit management
# ---------------------------------------------------------------------------
func spawn_unit(platform_id: String, pos: Vector2, heading: float,
		faction: String, custom_name: String = "", custom_id: String = "") -> String:
	_next_unit_id += 1
	var uid: String = custom_id if custom_id != "" else "UNIT_%04d" % _next_unit_id
	var platform_data: Dictionary = PlatformLoader.get_platform(platform_id)
	if platform_data.is_empty():
		push_error("SimulationWorld: unknown platform_id '%s'" % platform_id)
		return ""

	var unit := {
		"id": uid,
		"platform_id": platform_id,
		"platform": platform_data,
		"faction": faction,  # "player" | "enemy" | "neutral"
		"name": custom_name if custom_name != "" else platform_data.get("name", platform_id),
		"position": pos,  # Vector2 in NM from origin
		"heading": heading,  # degrees, 0 = North, clockwise
		"speed_kts": 0.0,
		"max_speed_kts": platform_data.get("max_speed_kts", 30.0),
		"depth_m": 0.0,  # 0 = surface, negative = submerged
		"ordered_depth_m": 0.0,
		"waypoints": [] as Array[Vector2],
		"weapons_remaining": _init_weapons(platform_data),
		"sensors": _init_sensors(platform_data),
		"damage": 0.0,  # 0.0 = pristine, 1.0 = destroyed
		"is_alive": true,
		"ordered_speed_kts": platform_data.get("max_speed_kts", 30.0) * 0.3,  # EN-2: loiter speed default
		"behavior": "patrol",  # "patrol" | "attack" | "evade" | "hold"
		"behavior_data": {},
		"contacts": {},  # target_id -> last known detection dict
		"emitting_radar": platform_data.get("type", "") != "SSN",  # subs start silent
		"emitting_sonar_active": false,
		# Air unit fields (surface/sub get defaults: altitude=0, fuel=1.0, endurance=0 = unlimited)
		"altitude_ft": 0.0,
		"ordered_altitude_ft": 0.0,
		"fuel_remaining": 1.0,
		"max_endurance_hours": platform_data.get("max_endurance_hours", 0.0),
		"base_unit_id": "",
		"is_airborne": false,
	}

	# Phase 5: EMCON and active sonar mode defaults
	unit["emcon_state"] = 2  # CHARLIE (normal operations)
	unit["active_sonar_mode"] = 0  # OFF
	unit["kill_status"] = "none"  # Phase 8: "none" | "probable" | "confirmed"

	# Submarines start submerged
	if platform_data.get("type", "") == "SSN":
		unit["depth_m"] = -100.0
		unit["ordered_depth_m"] = -100.0

	# Sonobuoy inventory: read from platform data, default 0 for non-ASW platforms
	var buoy_count: int = platform_data.get("sonobuoy_count", 0)
	if buoy_count == 0:
		match platform_data.get("type", ""):
			"MPA": buoy_count = 48
	unit["sonobuoys_remaining"] = buoy_count
	# Phase 7: typed sonobuoy inventory (DIFAR passive + DICASS active)
	# Default split: 75% DIFAR, 25% DICASS (rounded)
	var difar_count: int = platform_data.get("sonobuoy_difar", int(buoy_count * 0.75))
	var dicass_count: int = platform_data.get("sonobuoy_dicass", buoy_count - difar_count)
	unit["sonobuoys_difar"] = difar_count
	unit["sonobuoys_dicass"] = dicass_count

	# XBT (Expendable Bathythermograph) inventory: surface ships only
	unit["xbt_remaining"] = platform_data.get("xbt_count", 0)
	# Player's knowledge of thermal layer: starts with briefing estimate only
	unit["xbt_revealed_thermal_depth"] = -1.0  # -1 = not yet measured

	units[uid] = unit
	# Phase 5: register unit with EMCON and counter-detection systems
	_emcon_system.init_unit_emcon(uid)
	_counter_detection_system.init_unit_sonar(uid)
	# Phase 6: register enemy units with AI Doctrine System
	if faction == "enemy":
		_ai_doctrine_system.init_unit_doctrine(uid)
	unit_spawned.emit(uid, unit.duplicate(true))
	return uid

func destroy_unit(unit_id: String) -> void:
	if unit_id in units:
		units[unit_id]["is_alive"] = false
		units[unit_id]["damage"] = 1.0
		_ai_doctrine_system.remove_unit(unit_id)
		_emcon_system.remove_unit(unit_id)
		_counter_detection_system.remove_unit(unit_id)
		_esm_system.remove_unit(unit_id)
		_tma_system.remove_target(unit_id)
		unit_destroyed.emit(unit_id)

func set_unit_waypoint(unit_id: String, waypoint: Vector2) -> void:
	if unit_id in units:
		units[unit_id]["waypoints"] = [waypoint]

func add_unit_waypoint(unit_id: String, waypoint: Vector2) -> void:
	if unit_id in units:
		units[unit_id]["waypoints"].append(waypoint)

func set_unit_speed(unit_id: String, speed_kts: float) -> void:
	if unit_id in units:
		var max_spd: float = units[unit_id]["max_speed_kts"]
		# Phase 8: wire guidance speed constraint
		var wire_constraints: Dictionary = _weapon_system.get_wire_constraints(unit_id)
		if not wire_constraints.is_empty():
			max_spd = minf(max_spd, wire_constraints["max_speed_kts"])
		units[unit_id]["speed_kts"] = clampf(speed_kts, 0.0, max_spd)

func set_unit_depth(unit_id: String, depth_m: float) -> void:
	if unit_id in units:
		# Fix 15: only submarines may change depth
		if units[unit_id]["platform"].get("type", "") != "SSN":
			return
		units[unit_id]["ordered_depth_m"] = minf(depth_m, 0.0)  # 0 or negative

func set_unit_behavior(unit_id: String, behavior: String, data: Dictionary = {}) -> void:
	if unit_id in units:
		units[unit_id]["behavior"] = behavior
		units[unit_id]["behavior_data"] = data

func set_unit_radar(unit_id: String, active: bool) -> void:
	if unit_id in units:
		# Phase 5: EMCON gate -- block radar if EMCON doesn't allow it
		if active and not _emcon_system.is_emission_allowed(unit_id, "radar_search"):
			return
		units[unit_id]["emitting_radar"] = active

func set_unit_sonar_active(unit_id: String, active: bool) -> void:
	if unit_id in units:
		# Phase 5: EMCON gate -- block active sonar if EMCON doesn't allow it
		if active and not _emcon_system.is_emission_allowed(unit_id, "sonar_active"):
			return
		units[unit_id]["emitting_sonar_active"] = active
		# Phase 5: sync counter-detection system mode
		if active:
			_counter_detection_system.set_active_sonar_mode(unit_id, 2)  # FULL_POWER default
		else:
			_counter_detection_system.set_active_sonar_mode(unit_id, 0)  # OFF

func launch_aircraft(parent_id: String, aircraft_platform_id: String = "", altitude_ft: float = 500.0) -> String:
	if parent_id not in units:
		return ""
	var parent: Dictionary = units[parent_id]

	# Sea State 6+: helicopters cannot launch or recover
	if weather_sea_state >= 6:
		return ""

	# Check for an on-deck helicopter belonging to this parent
	for uid in units:
		var u: Dictionary = units[uid]
		if u.get("base_unit_id", "") == parent_id and not u.get("is_airborne", false) and u["is_alive"]:
			# Launch this existing on-deck helo
			u["is_airborne"] = true
			u["altitude_ft"] = altitude_ft
			u["ordered_altitude_ft"] = altitude_ft
			u["fuel_remaining"] = 1.0
			u["visible"] = true
			u["speed_kts"] = u["max_speed_kts"] * 0.6
			u["position"] = parent["position"]
			helicopter_launched.emit(parent_id, uid)
			return uid

	# No on-deck helo found -- spawn a new one (fallback for scenarios without auto-spawn)
	if aircraft_platform_id == "":
		aircraft_platform_id = parent.get("platform", {}).get("helicopter_type", "")
	if aircraft_platform_id == "":
		return ""
	var uid: String = spawn_unit(aircraft_platform_id, parent["position"], parent["heading"], parent["faction"], "", "")
	if uid == "":
		return ""
	units[uid]["is_airborne"] = true
	units[uid]["altitude_ft"] = altitude_ft
	units[uid]["ordered_altitude_ft"] = altitude_ft
	units[uid]["fuel_remaining"] = 1.0
	units[uid]["base_unit_id"] = parent_id
	units[uid]["speed_kts"] = units[uid]["max_speed_kts"] * 0.6
	helicopter_launched.emit(parent_id, uid)
	return uid

func recover_aircraft(aircraft_id: String) -> void:
	if aircraft_id in units and units[aircraft_id].get("is_airborne", false):
		_movement_system._land_aircraft(aircraft_id, units[aircraft_id])

## Deploy a sonobuoy from an airborne ASW platform at its current position.
## buoy_type: 0=DIFAR (passive), 1=DICASS (active). Default DIFAR.
## Returns the buoy_id string, or "" if the drop cannot be made.
func deploy_sonobuoy(deployer_id: String, buoy_type: int = 0) -> String:
	return _sonobuoy_system.deploy_sonobuoy_typed(deployer_id, buoy_type)

## Deploy a pattern of sonobuoys (line or field).
## pattern: 0=SINGLE, 1=LINE, 2=FIELD
## Returns array of buoy_id strings.
func deploy_sonobuoy_pattern(deployer_id: String, center: Vector2,
		pattern: int, buoy_type: int = 0, heading_deg: float = 0.0,
		buoy_count: int = 3) -> Array:
	match pattern:
		1:  # LINE
			return _sonobuoy_system.deploy_pattern_line(
				deployer_id, center, heading_deg, buoy_count, buoy_type)
		2:  # FIELD
			return _sonobuoy_system.deploy_pattern_field(
				deployer_id, center, buoy_type)
		_:  # SINGLE
			var bid: String = _sonobuoy_system.deploy_sonobuoy_typed(
				deployer_id, buoy_type, center)
			return [bid] if bid != "" else []

## Drop an Expendable Bathythermograph (XBT) from a surface ship.
## Reveals the actual thermal layer depth at the ship's location.
## Returns true if the drop succeeded.
func drop_xbt(unit_id: String) -> bool:
	if unit_id not in units:
		return false
	var u: Dictionary = units[unit_id]
	if not u["is_alive"]:
		return false
	# Only surface ships can drop XBTs (not subs, not aircraft)
	if u.get("is_airborne", false) or u["depth_m"] < -5.0:
		return false
	var xbt_remaining: int = u.get("xbt_remaining", 0)
	if xbt_remaining <= 0:
		return false
	u["xbt_remaining"] = xbt_remaining - 1

	# Reveal the actual thermal layer depth (from scenario environment data)
	var actual_depth: float = environment.get("thermal_layer_depth_m", 75.0)
	u["xbt_revealed_thermal_depth"] = actual_depth

	# XBT discovery: player now knows the real thermal layer depth
	_player_xbt_dropped = true

	xbt_dropped.emit(unit_id, u["position"], actual_depth)
	return true

## Returns the thermal layer depth for detection calculations.
## Player-faction units use the briefing estimate until an XBT is dropped.
## Enemy/AI units always know the actual depth (they operate in their own waters).
func get_thermal_depth_for_faction(faction: String) -> float:
	if faction == "player" and not _player_xbt_dropped:
		return _estimated_thermal_depth_m
	return environment.get("thermal_layer_depth_m", 75.0)

# ---------------------------------------------------------------------------
# Weapon initialization helpers
# ---------------------------------------------------------------------------
func _init_weapons(platform_data: Dictionary) -> Dictionary:
	var result := {}
	for weapon_id in platform_data.get("weapons", []):
		var wdata: Dictionary = PlatformLoader.get_weapon(weapon_id)
		if not wdata.is_empty():
			result[weapon_id] = {
				"count": wdata.get("loadout_default", 8),
				"data": wdata,
			}
	return result

func _init_sensors(platform_data: Dictionary) -> Array:
	var result := []
	for sensor_id in platform_data.get("sensors", []):
		var sdata: Dictionary = PlatformLoader.get_sensor(sensor_id)
		if not sdata.is_empty():
			result.append(sdata.duplicate(true))
	return result

# ---------------------------------------------------------------------------
# AI behaviors (enemy units)
# ---------------------------------------------------------------------------
func _run_ai_behaviors() -> void:
	# Phase 6: AI Doctrine System handles enemy unit behavior via state machine.
	# Units managed by doctrine skip the legacy behavior match.
	# Legacy behaviors remain for: evasive_patrol (ceasefire), hold, rtb,
	# airborne units (helo AI), and any unit not registered with doctrine.
	_ai_doctrine_system.tick_update()

	var pending_helo_launches: Array = []  # Collect to avoid dict mutation during iteration
	for uid in units:
		var u: Dictionary = units[uid]
		if not u["is_alive"] or u["faction"] == "player":
			continue

		# AI: auto-launch on-deck helicopters when the ship detects a player contact
		if u.get("contacts", {}).size() > 0 and not u.get("is_airborne", false):
			var platform: Dictionary = u.get("platform", {})
			if platform.get("helicopter_type", "") != "":
				# Check if this ship has unlaunched helos
				for huid in units:
					var hu: Dictionary = units[huid]
					if hu.get("base_unit_id", "") == uid and not hu.get("is_airborne", false) and hu["is_alive"]:
						pending_helo_launches.append(uid)
						break  # One launch per tick per ship

		# Skip units managed by doctrine system (they already ran above)
		if _ai_doctrine_system.has_unit(uid):
			# Exception: airborne units still use legacy helo AI (dipping sonar etc.)
			if not u.get("is_airborne", false):
				continue

		match u["behavior"]:
			"patrol":
				_ai_patrol(uid, u)
			"attack":
				_ai_attack(uid, u)
			"evade":
				_ai_evade(uid, u)
			"evasive_patrol":
				_ai_evasive_patrol(uid, u)
			"hold":
				pass
			"rtb":
				pass  # RTB units just follow their waypoint home

	# Execute deferred helicopter launches (after iteration to avoid dict mutation)
	for parent_id in pending_helo_launches:
		launch_aircraft(parent_id)

func _ai_patrol(uid: String, u: Dictionary) -> void:
	# Submarine counter-detection: if a player unit is tracking us, go deep below the thermal layer
	if u["platform"].get("type", "") == "SSN":
		if _ai_sub_check_counter_detection(uid, u):
			return  # Sub is executing evasive deep dive

	# If no waypoints, pick a random nearby point
	if u["waypoints"].size() == 0:
		# Fix 5: store home position on first patrol call, clamp to 25 NM of home
		if not u["behavior_data"].has("home"):
			u["behavior_data"]["home"] = Vector2(u["position"])
		var home: Vector2 = u["behavior_data"]["home"]
		var offset := Vector2(
			_rng.randf_range(-20.0, 20.0),
			_rng.randf_range(-20.0, 20.0)
		)
		var candidate: Vector2 = u["position"] + offset
		# Clamp to within 25 NM of home position
		if candidate.distance_to(home) > 25.0:
			candidate = home + (candidate - home).normalized() * 25.0
		u["waypoints"] = [candidate]
		u["speed_kts"] = u["max_speed_kts"] * 0.3

	# Check contacts -- if we detect a player unit, switch to attack
	var attack_threshold: float = difficulty.get("ai_attack_threshold", 0.3)
	for target_id in u.get("contacts", {}):
		if target_id in units and units[target_id]["faction"] == "player":
			var det: Dictionary = u["contacts"][target_id]
			if det.get("confidence", 0.0) > attack_threshold:
				u["behavior"] = "attack"
				u["behavior_data"] = {"target_id": target_id}
				return

func _ai_attack(uid: String, u: Dictionary) -> void:
	# Submarine counter-detection: if being tracked, go deep first
	if u["platform"].get("type", "") == "SSN":
		if _ai_sub_check_counter_detection(uid, u):
			return

	var target_id: String = u["behavior_data"].get("target_id", "")
	if target_id == "" or target_id not in units or not units[target_id]["is_alive"]:
		u["behavior"] = "patrol"
		u["behavior_data"] = {}
		return

	# Item 13: check if in post-fire evasion phase
	var evade_until: int = u["behavior_data"].get("evade_until_tick", 0)
	if evade_until > 0 and tick_count < evade_until:
		# Fire-and-maneuver: evade for 30 ticks after firing
		var target: Dictionary = units[target_id]
		var away: Vector2 = (u["position"] - target["position"]).normalized()
		u["waypoints"] = [u["position"] + away * 10.0]
		u["speed_kts"] = u["max_speed_kts"]
		return
	elif evade_until > 0:
		# Evasion phase complete, clear it
		u["behavior_data"].erase("evade_until_tick")

	var target: Dictionary = units[target_id]
	var dist: float = u["position"].distance_to(target["position"])

	# Try to fire a weapon if in range
	# Fix 6: per-unit offset so enemies don't fire synchronized salvos
	if (tick_count + uid.hash()) % 5 == 0:  # Check every 5 ticks, staggered per unit
		_ai_try_fire(uid, u, target_id, dist)

	# AI helicopter with dipping sonar: hover periodically to get sonar contact
	var has_dipping: bool = false
	if u.get("is_airborne", false):
		for sensor in u.get("sensors", []):
			if sensor.get("subtype", "") == "dipping":
				has_dipping = true
				break
	if has_dipping:
		# Hover for 30 seconds, then reposition for 30 seconds
		var dip_phase: int = (tick_count + uid.hash()) % 60
		if dip_phase < 30:
			# Hovering -- dipping sonar active (speed < 5 kts)
			u["speed_kts"] = 0.0
			return
		else:
			# Reposition toward target for next dip
			u["waypoints"] = [target["position"]]
			u["speed_kts"] = u["max_speed_kts"] * 0.5
			return

	# Close to weapons range
	var best_range: float = _get_best_weapon_range(u)
	if dist > best_range * 0.8:
		u["waypoints"] = [target["position"]]
		u["speed_kts"] = u["max_speed_kts"] * 0.7
	else:
		# Maintain standoff distance
		var away: Vector2 = (u["position"] - target["position"]).normalized()
		u["waypoints"] = [target["position"] + away * best_range * 0.6]
		u["speed_kts"] = u["max_speed_kts"] * 0.5

func _ai_evade(uid: String, u: Dictionary) -> void:
	# Run away from nearest known threat
	var nearest_threat_pos: Vector2 = Vector2.ZERO
	var nearest_dist: float = 999999.0
	for target_id in u.get("contacts", {}):
		if target_id in units and units[target_id]["faction"] == "player":
			var d: float = u["position"].distance_to(units[target_id]["position"])
			if d < nearest_dist:
				nearest_dist = d
				nearest_threat_pos = units[target_id]["position"]

	if nearest_dist < 999999.0:
		var away: Vector2 = (u["position"] - nearest_threat_pos).normalized()
		u["waypoints"] = [u["position"] + away * 30.0]
		u["speed_kts"] = u["max_speed_kts"]
	else:
		u["behavior"] = "patrol"

func _ai_evasive_patrol(uid: String, u: Dictionary) -> void:
	## Evasive patrol: follow waypoints but vary speed and heading to break tracking.
	## Will NOT switch to attack -- ceasefire behavior.

	# Move along waypoints at variable slow speed
	if u["waypoints"].size() == 0:
		# Loop back to first waypoint if we have behavior_data with original waypoints
		var orig_wps: Array = u["behavior_data"].get("original_waypoints", [])
		if not orig_wps.is_empty():
			u["waypoints"] = orig_wps.duplicate()
		else:
			# Random evasive movement
			var offset := Vector2(
				_rng.randf_range(-15.0, 15.0),
				_rng.randf_range(-15.0, 15.0)
			)
			u["waypoints"] = [u["position"] + offset]

	# Vary speed to make TMA harder (speed changes break bearing rate solutions)
	if tick_count % 120 == (uid.hash() % 120):  # Every ~2 minutes, staggered
		u["speed_kts"] = _rng.randf_range(3.0, 8.0)

	# Occasional random course deviation to break tracking
	if tick_count % 300 == (uid.hash() % 300):  # Every ~5 minutes
		if u["waypoints"].size() > 0:
			var current_wp: Vector2 = u["waypoints"][0]
			var deviation := Vector2(
				_rng.randf_range(-5.0, 5.0),
				_rng.randf_range(-5.0, 5.0)
			)
			u["waypoints"][0] = current_wp + deviation

	# Do NOT check contacts or switch to attack -- ceasefire

## Submarine AI: check if any player unit is tracking this sub (counter-detection).
## If detected, dive below the thermal layer to break contact.
## Returns true if the sub is executing or continuing an evasive dive.
func _ai_sub_check_counter_detection(uid: String, u: Dictionary) -> bool:
	# Check if already deep below thermal layer and in evasive cooldown
	var thermal_depth: float = environment.get("thermal_layer_depth_m", 75.0)
	var dive_until_tick: int = u["behavior_data"].get("dive_evasion_until", 0)
	if dive_until_tick > 0 and tick_count < dive_until_tick:
		# Still in evasive dive -- maintain deep depth, slow speed
		if absf(u["depth_m"]) < thermal_depth + 50.0:
			u["ordered_depth_m"] = -(thermal_depth + 100.0)
		u["speed_kts"] = 3.0  # Creep speed to minimize noise
		return true
	elif dive_until_tick > 0:
		# Evasion period expired -- clear it and resume normal behavior
		u["behavior_data"].erase("dive_evasion_until")

	# Check if any player unit is actively tracking this sub
	var is_being_tracked: bool = false
	for player_uid in units:
		var pu: Dictionary = units[player_uid]
		if pu.get("faction", "") != "player" or not pu["is_alive"]:
			continue
		if uid in pu.get("contacts", {}):
			var det: Dictionary = pu["contacts"][uid]
			# Counter-detect: the sub "knows" it's being tracked at confidence > 0.4
			if det.get("confidence", 0.0) > 0.4:
				is_being_tracked = true
				break

	if is_being_tracked and absf(u["depth_m"]) < thermal_depth + 20.0:
		# GO DEEP: dive below the thermal layer to break hull sonar contact
		var deep_depth: float = -(thermal_depth + 100.0)
		u["ordered_depth_m"] = deep_depth
		u["speed_kts"] = u["max_speed_kts"] * 0.5  # Sprint to depth, then slow
		# Evasion period: stay deep for 120-300 seconds (2-5 minutes)
		u["behavior_data"]["dive_evasion_until"] = tick_count + 120 + (_rng.randi() % 180)
		submarine_went_deep.emit(uid, deep_depth)
		# Notify TMA system: target going deep degrades tracking solutions
		_tma_system.target_went_deep(uid)
		return true

	return false

## Phase 7: DICASS active sonobuoy alerted a submarine -- trigger evasive dive.
## This bridges the sonobuoy system into the existing AI counter-detection logic.
## When AIDoctrineSystem (Phase 6) is fully integrated, it should handle this
## via the sonobuoy_dicass_alert signal directly.
func _on_dicass_alert_sub(sub_id: String, _buoy_id: String, _bearing: float) -> void:
	if sub_id not in units:
		return
	var u: Dictionary = units[sub_id]
	if not u["is_alive"] or u["faction"] == "player":
		return
	if u["platform"].get("type", "") != "SSN":
		return
	# Only react if not already in evasive dive
	var dive_until: int = u["behavior_data"].get("dive_evasion_until", 0)
	if dive_until > 0 and tick_count < dive_until:
		return  # Already evading
	# Trigger evasive dive below thermal layer
	var thermal_depth: float = environment.get("thermal_layer_depth_m", 75.0)
	if absf(u["depth_m"]) < thermal_depth + 20.0:
		var deep_depth: float = -(thermal_depth + 100.0)
		u["ordered_depth_m"] = deep_depth
		u["speed_kts"] = u["max_speed_kts"] * 0.5
		u["behavior_data"]["dive_evasion_until"] = tick_count + 120 + (_rng.randi() % 180)
		submarine_went_deep.emit(sub_id, deep_depth)
		_tma_system.target_went_deep(sub_id)

func _ai_try_fire(uid: String, u: Dictionary, target_id: String, dist_nm: float) -> void:
	# Item 2: AI torpedo cooldown -- enforce 60 sim-second minimum between shots
	var last_fire_tick: int = u["behavior_data"].get("last_fire_tick", 0)
	if tick_count - last_fire_tick < 60:
		return

	for weapon_id in u["weapons_remaining"]:
		var wrec: Dictionary = u["weapons_remaining"][weapon_id]
		if wrec["count"] <= 0:
			continue
		var wdata: Dictionary = wrec["data"]
		var max_range: float = wdata.get("max_range_nm", 50.0)
		if dist_nm <= max_range:
			# Check weapon type vs target type
			if is_weapon_valid_for_target(wdata, units[target_id]):
				fire_weapon(uid, target_id, weapon_id)
				u["behavior_data"]["last_fire_tick"] = tick_count
				# Item 13: fire-and-maneuver -- evade for 30 ticks after firing
				u["behavior_data"]["evade_until_tick"] = tick_count + 30
				return

# ---------------------------------------------------------------------------
# Weapon / damage passthroughs to subsystems
# ---------------------------------------------------------------------------
func is_weapon_valid_for_target(wdata: Dictionary, target: Dictionary) -> bool:
	return _weapon_system.is_weapon_valid_for_target(wdata, target)

func _get_best_weapon_range(u: Dictionary) -> float:
	return _weapon_system.get_best_weapon_range(u)

func fire_weapon(shooter_id: String, target_id: String, weapon_type_id: String) -> String:
	return _weapon_system.fire_weapon(shooter_id, target_id, weapon_type_id)

## Phase 10: Public accessor for ROESystem (used by WeaponSystem for fire authorization).
func get_roe_system():
	return _roe_system

## Phase 5: EMCON state management
func set_unit_emcon(unit_id: String, emcon_state: int) -> void:
	_emcon_system.set_emcon_state(unit_id, emcon_state)

func get_unit_emcon(unit_id: String) -> int:
	return _emcon_system.get_emcon_state(unit_id)

func set_active_sonar_mode(unit_id: String, mode: int) -> void:
	_counter_detection_system.set_active_sonar_mode(unit_id, mode)

func get_active_sonar_mode(unit_id: String) -> int:
	return _counter_detection_system.get_active_sonar_mode(unit_id)

## Phase 5: Emit pending events from Phase 5 subsystems as signals.
func _emit_phase5_signals() -> void:
	for evt in _counter_detection_system.pending_counter_detections:
		counter_detection_event.emit(evt["detector_id"], evt["emitter_id"], evt["bearing"])
	for evt in _esm_system.pending_esm_detections:
		esm_contact_detected.emit(evt["detector_id"], evt["emitter_id"], evt["bearing"], evt["radar_type"])
	for evt in _radar_horizon_system.pending_horizon_blocks:
		radar_horizon_blocked.emit(evt["unit_id"], evt["target_id"])
	for e in _emcon_system._last_emcon_events:
		emcon_state_changed.emit(e["unit_id"], e["old_state"], e["new_state"])
	_emcon_system._last_emcon_events.clear()

# ---------------------------------------------------------------------------
# Scenario conditions
# ---------------------------------------------------------------------------
func _check_scenario_conditions() -> void:
	# Fix 4: prevent double scenario_ended emission
	if _game_over:
		return
	if scenario.is_empty():
		return

	var victory_type: String = scenario.get("victory_condition", {}).get("type", "")

	match victory_type:
		"destroy_all_enemies":
			var enemies_alive := 0
			var player_alive := 0
			for uid in units:
				if units[uid]["is_alive"]:
					if units[uid]["faction"] == "enemy":
						enemies_alive += 1
					elif units[uid]["faction"] == "player":
						player_alive += 1

			if player_alive == 0:
				_game_over = true
				scenario_ended.emit("defeat")
				is_paused = true
			elif enemies_alive == 0:
				_game_over = true
				scenario_ended.emit("victory")
				is_paused = true
			else:
				# EN-5: time limit -- draw if enemies survive past deadline
				var time_limit: float = scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
				if time_limit > 0.0 and sim_time >= time_limit:
					_game_over = true
					scenario_ended.emit("draw")
					is_paused = true

		"survive_time":
			var required_time: float = scenario.get("victory_condition", {}).get("time_seconds", 3600.0)
			var player_alive := 0
			for uid in units:
				if units[uid]["is_alive"] and units[uid]["faction"] == "player":
					player_alive += 1
			if player_alive == 0:
				_game_over = true
				scenario_ended.emit("defeat")
				is_paused = true
			elif sim_time >= required_time:
				_game_over = true
				scenario_ended.emit("victory")
				is_paused = true

		"protect_convoy":
			# Kill all enemies, but defeat if any merchant is destroyed
			var conv_enemies_alive := 0
			var conv_player_combat := 0
			var convoy_alive := true
			for uid in units:
				if not units[uid]["is_alive"]:
					# Check if a dead unit was a merchant
					if units[uid]["platform"].get("id", "") == "merchant_vessel":
						convoy_alive = false
					continue
				if units[uid]["faction"] == "enemy":
					conv_enemies_alive += 1
				elif units[uid]["faction"] == "player":
					conv_player_combat += 1

			if not convoy_alive:
				_game_over = true
				scenario_ended.emit("defeat")
				is_paused = true
			elif conv_player_combat == 0:
				_game_over = true
				scenario_ended.emit("defeat")
				is_paused = true
			elif conv_enemies_alive == 0:
				_game_over = true
				scenario_ended.emit("victory")
				is_paused = true
			else:
				var conv_time_limit: float = scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
				if conv_time_limit > 0.0 and sim_time >= conv_time_limit:
					_game_over = true
					scenario_ended.emit("draw")
					is_paused = true

		"maintain_contact":
			# Player must maintain cumulative passive contact on all enemies
			var required_seconds: float = scenario.get("victory_condition", {}).get("contact_duration_seconds", 1800.0)
			var time_limit: float = scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
			var player_alive := 0
			var enemies_alive := 0
			var all_tracked: bool = true
			for uid in units:
				if not units[uid]["is_alive"]:
					continue
				if units[uid]["faction"] == "player":
					player_alive += 1
				elif units[uid]["faction"] == "enemy":
					enemies_alive += 1
					# Check if ANY player unit has contact on this enemy
					var tracked: bool = false
					for puid in units:
						if units[puid]["is_alive"] and units[puid]["faction"] == "player":
							if uid in units[puid].get("contacts", {}):
								tracked = true
								break
					if not tracked:
						all_tracked = false

			if player_alive == 0:
				_game_over = true
				scenario_ended.emit("defeat")
				is_paused = true
			elif enemies_alive == 0:
				# All enemies somehow destroyed (shouldn't happen in weapons hold, but handle it)
				_game_over = true
				scenario_ended.emit("victory")
				is_paused = true
			else:
				# Accumulate contact time when all enemies are tracked
				if all_tracked:
					_contact_accumulator += 1.0  # 1 second per tick at 1Hz base
				else:
					# Lose progress when contact is broken (but don't reset fully)
					_contact_accumulator = maxf(_contact_accumulator - 0.5, 0.0)

				if _contact_accumulator >= required_seconds:
					_game_over = true
					scenario_ended.emit("victory")
					is_paused = true
				elif time_limit > 0.0 and sim_time >= time_limit:
					_game_over = true
					scenario_ended.emit("draw")
					is_paused = true

# ---------------------------------------------------------------------------
# Public API -- time control
# ---------------------------------------------------------------------------
func set_time_scale(new_scale: float) -> void:
	time_scale = clampf(new_scale, 0.0, 60.0)
	time_scale_changed.emit(time_scale)

func pause() -> void:
	is_paused = true

func unpause() -> void:
	is_paused = false

func toggle_pause() -> void:
	is_paused = not is_paused

# ---------------------------------------------------------------------------
# Scenario loading
# ---------------------------------------------------------------------------
func load_scenario(scenario_data: Dictionary) -> void:
	# Reset state
	units.clear()
	weapons_in_flight.clear()
	contacts.clear()
	sim_time = 0.0
	tick_count = 0
	_tick_accumulator = 0.0
	is_paused = true
	_next_designator = 1  # Fix 1: reset designators on scenario load
	_unit_designators.clear()  # Fix 1: clear stale designator mappings
	_game_over = false  # Fix 4: reset game-over flag on scenario load
	_contact_accumulator = 0.0
	sosus_barriers.clear()
	sonobuoys.clear()
	_next_buoy_id = 0
	_next_unit_id = 0
	_next_weapon_id = 0
	_sonobuoy_system.reset()
	_tma_system.reset()
	_ai_doctrine_system.reset()
	_roe_system.reset()
	_counter_detection_system.reset()
	_emcon_system.reset()
	_esm_system.reset()
	_radar_horizon_system.reset()
	_weapon_system.reset()

	scenario = scenario_data
	environment = scenario_data.get("environment", environment)
	difficulty = scenario_data.get("difficulty", {})  # Item 16: load difficulty scaling

	# XBT discovery mechanic: generate briefing estimate with +/- 10-20m uncertainty
	_player_xbt_dropped = false
	var actual_thermal: float = environment.get("thermal_layer_depth_m", 75.0)
	var offset_range: float = _rng.randf_range(10.0, 20.0)
	var offset_sign: float = 1.0 if _rng.randf() > 0.5 else -1.0
	_estimated_thermal_depth_m = maxf(10.0, actual_thermal + offset_sign * offset_range)
	# Phase 6: set AI doctrine difficulty from scenario
	_ai_doctrine_system.set_difficulty_from_scenario(difficulty)

	# Phase 10: Load ROE state from scenario JSON
	if scenario_data.has("roe_state"):
		_roe_system.set_roe_state(_roe_system.parse_roe_string(scenario_data["roe_state"]))
	else:
		# Default: WEAPONS_FREE (backward compatibility with scenarios that don't specify)
		_roe_system.set_roe_state(_roe_system.ROEState.WEAPONS_FREE)
	# Sync crisis temperature from campaign into ROE system
	_roe_system.set_crisis_temperature(CampaignManager.crisis_temperature)

	# Load neutral contacts from scenario
	for unit_def in scenario_data.get("units", []):
		if unit_def.get("faction", "") == "neutral":
			_roe_system.mark_neutral(unit_def.get("id", ""))

	# Initialize weather state from scenario environment block
	var env: Dictionary = scenario_data.get("environment", {})
	weather_sea_state = env.get("sea_state", 4)
	weather_type = env.get("weather", "overcast")
	weather_wind_kts = _detection_system._sea_state_to_wind(weather_sea_state)
	weather_visibility_nm = _detection_system._weather_to_visibility(weather_type, weather_sea_state)
	_last_weather_check_time = 0.0

	# Spawn units defined in scenario
	for unit_def in scenario_data.get("units", []):
		var pid: String = unit_def.get("platform_id", "")
		if pid == "":
			push_error("load_scenario: unit entry missing platform_id: %s" % str(unit_def))
			continue
		var pos := Vector2(unit_def.get("x", 0.0), unit_def.get("y", 0.0))
		var spawned_uid: String = spawn_unit(
			pid,
			pos,
			unit_def.get("heading", 0.0),
			unit_def.get("faction", "neutral"),
			unit_def.get("name", ""),
			unit_def.get("id", "")
		)
		if spawned_uid == "":
			push_error("load_scenario: failed to spawn unit with platform_id '%s'" % pid)
			continue
		set_unit_speed(spawned_uid, unit_def.get("speed_kts", 0.0))
		if unit_def.has("behavior"):
			set_unit_behavior(spawned_uid, unit_def["behavior"], unit_def.get("behavior_data", {}))
		if unit_def.has("waypoints"):
			for wp in unit_def.get("waypoints", []):
				if wp is Array and wp.size() >= 2:
					add_unit_waypoint(spawned_uid, Vector2(wp[0], wp[1]))
				else:
					push_error("load_scenario: malformed waypoint for unit '%s': %s" % [spawned_uid, str(wp)])
		if unit_def.has("override_countermeasures"):
			units[spawned_uid]["override_countermeasures"] = unit_def["override_countermeasures"]
		# Handle pre-airborne units (P-3C, etc.)
		if unit_def.get("is_airborne", false):
			units[spawned_uid]["is_airborne"] = true
			units[spawned_uid]["altitude_ft"] = unit_def.get("altitude_ft", 500.0)
			units[spawned_uid]["ordered_altitude_ft"] = unit_def.get("altitude_ft", 500.0)
			units[spawned_uid]["fuel_remaining"] = 1.0
		# Store original waypoints for evasive_patrol behavior (needs to loop back)
		if unit_def.get("behavior", "") == "evasive_patrol" and unit_def.has("waypoints"):
			var orig_wps: Array = []
			for wp in unit_def.get("waypoints", []):
				if wp is Array and wp.size() >= 2:
					orig_wps.append(Vector2(wp[0], wp[1]))
			if spawned_uid in units:
				units[spawned_uid]["behavior_data"]["original_waypoints"] = orig_wps

	# Load SOSUS barriers from scenario
	for sosus_def in scenario_data.get("sosus", []):
		if not sosus_def.has("x1") or not sosus_def.has("y1") or not sosus_def.has("x2") or not sosus_def.has("y2"):
			push_error("load_scenario: SOSUS entry missing coordinate keys: %s" % str(sosus_def))
			continue
		sosus_barriers.append({
			"id": sosus_def.get("id", "SOSUS_%d" % sosus_barriers.size()),
			"start_pos": Vector2(sosus_def.get("x1", 0.0), sosus_def.get("y1", 0.0)),
			"end_pos": Vector2(sosus_def.get("x2", 0.0), sosus_def.get("y2", 0.0)),
			"sensitivity_db": clampf(sosus_def.get("sensitivity_db", 90.0), 0.0, 120.0),
		})

	# Auto-spawn helicopters for ships that carry them (on deck, not airborne)
	var helo_spawns: Array = []  # Collect to avoid modifying units dict while iterating
	for uid in units:
		var u: Dictionary = units[uid]
		var platform: Dictionary = u.get("platform", {})
		var helo_type: String = platform.get("helicopter_type", "")
		var helo_count: int = platform.get("helicopter_count", 0)
		if helo_type != "" and helo_count > 0:
			for i in range(helo_count):
				helo_spawns.append({"parent_id": uid, "platform_id": helo_type, "faction": u["faction"], "index": i + 1, "parent_name": u.get("name", uid)})

	for hs in helo_spawns:
		var helo_uid: String = spawn_unit(hs["platform_id"], units[hs["parent_id"]]["position"], units[hs["parent_id"]]["heading"], hs["faction"], "", "")
		if helo_uid != "":
			units[helo_uid]["base_unit_id"] = hs["parent_id"]
			units[helo_uid]["is_airborne"] = false
			units[helo_uid]["altitude_ft"] = 0.0
			units[helo_uid]["name"] = "%s HELO %d" % [hs["parent_name"], hs["index"]]
			# On-deck: not visible as a separate unit until launched
			units[helo_uid]["visible"] = false

	scenario_started.emit(scenario_data.get("name", "Unknown Scenario"))

# ---------------------------------------------------------------------------
# Mid-Mission Save/Load System
# ---------------------------------------------------------------------------

## Serialize full simulation state to a Dictionary for JSON save.
func get_save_state() -> Dictionary:
	var save := {
		"version": 1,
		"sim_time": sim_time,
		"tick_count": tick_count,
		"time_scale": time_scale,
		"scenario": scenario.duplicate(true),
		"environment": environment.duplicate(true),
		"difficulty": difficulty.duplicate(true),
		"weather_sea_state": weather_sea_state,
		"weather_type": weather_type,
		"weather_wind_kts": weather_wind_kts,
		"weather_visibility_nm": weather_visibility_nm,
		"_last_weather_check_time": _last_weather_check_time,
		"_contact_accumulator": _contact_accumulator,
		"_next_unit_id": _next_unit_id,
		"_next_weapon_id": _next_weapon_id,
		"_next_designator": _next_designator,
		"_next_buoy_id": _next_buoy_id,
		"_player_xbt_dropped": _player_xbt_dropped,
		"_estimated_thermal_depth_m": _estimated_thermal_depth_m,
	}

	# Units
	var units_data: Dictionary = {}
	for uid in units:
		var u: Dictionary = units[uid].duplicate(true)
		# Convert Vector2 fields to arrays for JSON
		u["position"] = [u["position"].x, u["position"].y]
		var wp_arr: Array = []
		for wp in u.get("waypoints", []):
			if wp is Vector2:
				wp_arr.append([wp.x, wp.y])
		u["waypoints"] = wp_arr
		# Remove non-serializable refs (platform data will be rebuilt from platform_id)
		u.erase("platform")
		u.erase("sensors")
		u.erase("contacts")
		units_data[uid] = u
	save["units"] = units_data

	# Weapons in flight
	var weapons_data: Dictionary = {}
	for wid in weapons_in_flight:
		var w: Dictionary = weapons_in_flight[wid].duplicate(true)
		w["position"] = [w["position"].x, w["position"].y]
		if w.has("target_last_pos") and w["target_last_pos"] is Vector2:
			w["target_last_pos"] = [w["target_last_pos"].x, w["target_last_pos"].y]
		weapons_data[wid] = w
	save["weapons_in_flight"] = weapons_data

	# Sonobuoys
	var buoys_data: Dictionary = {}
	for bid in sonobuoys:
		var b: Dictionary = sonobuoys[bid].duplicate(true)
		b["position"] = [b["position"].x, b["position"].y]
		buoys_data[bid] = b
	save["sonobuoys"] = buoys_data

	# SOSUS barriers
	var sosus_data: Array = []
	for barrier in sosus_barriers:
		var bd: Dictionary = barrier.duplicate(true)
		bd["start_pos"] = [bd["start_pos"].x, bd["start_pos"].y]
		bd["end_pos"] = [bd["end_pos"].x, bd["end_pos"].y]
		sosus_data.append(bd)
	save["sosus_barriers"] = sosus_data

	# Designators
	save["_unit_designators"] = _unit_designators.duplicate(true)

	# Campaign state saved separately via CampaignManager._save()
	if CampaignManager.campaign_active:
		CampaignManager._save()

	return save

## Save current state to user://saves/threshold_save.json
func save_game() -> bool:
	var save_data: Dictionary = get_save_state()
	var json_str: String = JSON.stringify(save_data, "\t")
	DirAccess.make_dir_recursive_absolute("user://saves")
	var file := FileAccess.open("user://saves/threshold_save.json", FileAccess.WRITE)
	if file == null:
		push_error("Failed to open save file for writing")
		return false
	file.store_string(json_str)
	file.close()
	print("[THRESHOLD] Game saved to user://saves/threshold_save.json")
	return true

## Load state from user://saves/threshold_save.json
func load_game() -> bool:
	if not FileAccess.file_exists("user://saves/threshold_save.json"):
		push_error("No save file found")
		return false
	var file := FileAccess.open("user://saves/threshold_save.json", FileAccess.READ)
	if file == null:
		push_error("Failed to open save file for reading")
		return false
	var json_str: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_result: int = json.parse(json_str)
	if parse_result != OK:
		push_error("Failed to parse save file: %s" % json.get_error_message())
		return false
	var save_data: Dictionary = json.data

	# Reset state
	units.clear()
	weapons_in_flight.clear()
	contacts.clear()
	sonobuoys.clear()
	sosus_barriers.clear()
	_game_over = false

	# Restore scalar state
	sim_time = save_data.get("sim_time", 0.0)
	tick_count = save_data.get("tick_count", 0)
	time_scale = save_data.get("time_scale", 1.0)
	scenario = save_data.get("scenario", {})
	environment = save_data.get("environment", environment)
	difficulty = save_data.get("difficulty", {})
	weather_sea_state = save_data.get("weather_sea_state", 4)
	weather_type = save_data.get("weather_type", "overcast")
	weather_wind_kts = save_data.get("weather_wind_kts", 15.0)
	weather_visibility_nm = save_data.get("weather_visibility_nm", 20.0)
	_last_weather_check_time = save_data.get("_last_weather_check_time", 0.0)
	_contact_accumulator = save_data.get("_contact_accumulator", 0.0)
	_next_unit_id = save_data.get("_next_unit_id", 0)
	_next_weapon_id = save_data.get("_next_weapon_id", 0)
	_next_designator = save_data.get("_next_designator", 1)
	_next_buoy_id = save_data.get("_next_buoy_id", 0)
	_player_xbt_dropped = save_data.get("_player_xbt_dropped", false)
	_estimated_thermal_depth_m = save_data.get("_estimated_thermal_depth_m", 75.0)
	_unit_designators = save_data.get("_unit_designators", {})

	# Reset subsystems
	_sonobuoy_system.reset()
	_tma_system.reset()
	_ai_doctrine_system.reset()
	_roe_system.reset()
	_counter_detection_system.reset()
	_emcon_system.reset()
	_esm_system.reset()
	_radar_horizon_system.reset()
	_weapon_system.reset()

	# Restore units
	var units_data: Dictionary = save_data.get("units", {})
	for uid in units_data:
		var u: Dictionary = units_data[uid]
		var platform_id: String = u.get("platform_id", "")
		var platform_data: Dictionary = PlatformLoader.get_platform(platform_id)
		if platform_data.is_empty():
			push_error("load_game: unknown platform_id '%s'" % platform_id)
			continue
		u["platform"] = platform_data
		u["sensors"] = _init_sensors(platform_data)
		u["contacts"] = {}
		# Restore Vector2 fields
		if u["position"] is Array:
			u["position"] = Vector2(u["position"][0], u["position"][1])
		var wp_arr: Array = []
		for wp in u.get("waypoints", []):
			if wp is Array and wp.size() >= 2:
				wp_arr.append(Vector2(wp[0], wp[1]))
		u["waypoints"] = wp_arr
		units[uid] = u
		# Re-register with subsystems -- restore saved EMCON state instead of defaults
		var saved_emcon: int = u.get("emcon_state", 2)  # Default CHARLIE
		_emcon_system.restore_unit_emcon(uid, saved_emcon)
		_counter_detection_system.init_unit_sonar(uid)
		if u.get("faction", "") == "enemy":
			_ai_doctrine_system.init_unit_doctrine(uid)

	# Restore SOSUS
	for sd in save_data.get("sosus_barriers", []):
		var barrier := {
			"id": sd.get("id", ""),
			"start_pos": Vector2(sd["start_pos"][0], sd["start_pos"][1]),
			"end_pos": Vector2(sd["end_pos"][0], sd["end_pos"][1]),
			"sensitivity_db": sd.get("sensitivity_db", 90.0),
		}
		sosus_barriers.append(barrier)

	# Restore sonobuoys
	for bid in save_data.get("sonobuoys", {}):
		var b: Dictionary = save_data["sonobuoys"][bid]
		if b["position"] is Array:
			b["position"] = Vector2(b["position"][0], b["position"][1])
		sonobuoys[bid] = b

	# Restore ROE from scenario
	if scenario.has("roe_state"):
		_roe_system.set_roe_state(_roe_system.parse_roe_string(scenario["roe_state"]))
	_ai_doctrine_system.set_difficulty_from_scenario(difficulty)

	# Campaign state loaded separately
	CampaignManager.load_campaign()
	_roe_system.set_crisis_temperature(CampaignManager.crisis_temperature)

	is_paused = true
	print("[THRESHOLD] Game loaded from save file")
	scenario_started.emit(scenario.get("name", "Loaded Save"))
	return true
