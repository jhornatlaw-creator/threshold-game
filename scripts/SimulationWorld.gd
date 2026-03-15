extends Node
## SimulationWorld -- Core simulation singleton (Autoload)
##
## Owns ALL unit state as Dictionaries. Runs fixed-tick loop at 1Hz base
## with time_scale multiplier. Emits signals on every state change.
## NO visual nodes -- pure data. Renderers subscribe to signals.

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
	"thermal_layer_depth_m": 75.0,
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

# ---------------------------------------------------------------------------
# Tick pipeline
# ---------------------------------------------------------------------------
func _sim_tick() -> void:
	tick_count += 1
	sim_time += 1.0 / BASE_TICK_HZ
	_move_units()
	_run_ai_behaviors()
	_update_detections()
	_process_sonobuoy_detections()
	_move_weapons()
	_resolve_weapons()
	_check_scenario_conditions()
	_maybe_update_weather(sim_time)
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

	units[uid] = unit
	unit_spawned.emit(uid, unit.duplicate(true))
	return uid

func destroy_unit(unit_id: String) -> void:
	if unit_id in units:
		units[unit_id]["is_alive"] = false
		units[unit_id]["damage"] = 1.0
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
		units[unit_id]["emitting_radar"] = active

func set_unit_sonar_active(unit_id: String, active: bool) -> void:
	if unit_id in units:
		units[unit_id]["emitting_sonar_active"] = active

func launch_aircraft(parent_id: String, aircraft_platform_id: String = "", altitude_ft: float = 500.0) -> String:
	if parent_id not in units:
		return ""
	var parent: Dictionary = units[parent_id]

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
		_land_aircraft(aircraft_id, units[aircraft_id])

## Deploy a sonobuoy from an airborne ASW platform at its current position.
## Returns the buoy_id string, or "" if the drop cannot be made.
func deploy_sonobuoy(deployer_id: String) -> String:
	if deployer_id not in units:
		return ""
	var u: Dictionary = units[deployer_id]
	if not u["is_alive"] or not u.get("is_airborne", false):
		return ""
	var buoys_remaining: int = u.get("sonobuoys_remaining", 0)
	if buoys_remaining <= 0:
		return ""
	u["sonobuoys_remaining"] = buoys_remaining - 1

	var buoy_id: String = "BUOY_%d" % _next_buoy_id
	_next_buoy_id += 1

	sonobuoys[buoy_id] = {
		"position": Vector2(u["position"]),
		"faction": u["faction"],
		"deploy_time": sim_time,
		"battery_life": 2400.0,   # 40 minutes sim time
		"sensitivity_db": 75.0,   # Detection threshold (same role as sensor detection_threshold_db)
		"deployer_id": deployer_id,
	}

	sonobuoy_deployed.emit(buoy_id, u["position"], u["faction"])
	return buoy_id

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
# Movement
# ---------------------------------------------------------------------------
func _move_units() -> void:
	for uid in units:
		var u: Dictionary = units[uid]
		if not u["is_alive"]:
			continue

		# Depth adjustment (10m per tick toward ordered depth)
		var depth_diff: float = u["ordered_depth_m"] - u["depth_m"]
		if absf(depth_diff) > 0.5:
			u["depth_m"] += signf(depth_diff) * minf(10.0, absf(depth_diff))

		# Waypoint steering
		if u["waypoints"].size() > 0:
			var target: Vector2 = u["waypoints"][0]
			var to_target: Vector2 = target - u["position"]
			var dist_nm: float = to_target.length()

			if dist_nm < 0.1:  # Arrived at waypoint
				u["waypoints"].remove_at(0)
				if u["waypoints"].size() == 0:
					# EN-2: maintain loiter speed instead of dead stop
					u["speed_kts"] = u.get("ordered_speed_kts", u["max_speed_kts"] * 0.3)
			else:
				# Set heading toward waypoint
				var target_heading: float = rad_to_deg(atan2(to_target.x, to_target.y))
				if target_heading < 0:
					target_heading += 360.0
				var old_heading: float = u["heading"]
				u["heading"] = _turn_toward(old_heading, target_heading, 5.0)  # 5 deg/tick max turn
				if absf(old_heading - u["heading"]) > 0.01:
					unit_heading_changed.emit(uid, u["heading"])

				# Set speed if not already moving
				if u["speed_kts"] < 1.0:
					u["speed_kts"] = u["max_speed_kts"] * 0.5  # Default cruise

		# Altitude adjustment for airborne units (1000 ft per tick toward ordered altitude)
		if u.get("is_airborne", false):
			var alt_diff: float = u["ordered_altitude_ft"] - u["altitude_ft"]
			if absf(alt_diff) > 50.0:
				u["altitude_ft"] += signf(alt_diff) * minf(1000.0, absf(alt_diff))

		# Position update
		if u["speed_kts"] > 0.0:
			var old_pos: Vector2 = u["position"]
			var heading_rad: float = deg_to_rad(u["heading"])
			var distance_nm: float = u["speed_kts"] * KNOTS_TO_NM_PER_SEC * (1.0 / BASE_TICK_HZ)
			var movement := Vector2(sin(heading_rad), cos(heading_rad)) * distance_nm
			u["position"] += movement
			unit_moved.emit(uid, old_pos, u["position"])

		# Fuel consumption for airborne units
		if u.get("is_airborne", false) and u.get("max_endurance_hours", 0.0) > 0.0:
			var fuel_per_tick: float = (1.0 / BASE_TICK_HZ) / (u["max_endurance_hours"] * 3600.0)
			u["fuel_remaining"] -= fuel_per_tick
			# Bingo fuel -- auto RTB (only trigger once)
			if u["fuel_remaining"] <= 0.1 and u.get("behavior", "") != "rtb":
				u["fuel_remaining"] = maxf(u["fuel_remaining"], 0.0)
				_air_rtb(uid, u)
			# Out of fuel -- aircraft lost
			if u["fuel_remaining"] <= 0.0:
				u["fuel_remaining"] = 0.0
				if u.get("behavior", "") == "rtb":
					# Check if close enough to base to land
					var base_id: String = u.get("base_unit_id", "")
					if base_id != "" and base_id in units:
						var dist_to_base: float = u["position"].distance_to(units[base_id]["position"])
						if dist_to_base < 1.0:
							_land_aircraft(uid, u)
						else:
							_crash_aircraft(uid, u)
					else:
						_crash_aircraft(uid, u)
				else:
					_crash_aircraft(uid, u)

		# RTB arrival check -- land when reaching base ship, track moving base
		if u.get("is_airborne", false) and u.get("behavior", "") == "rtb":
			var base_id: String = u.get("base_unit_id", "")
			if base_id != "" and base_id in units and units[base_id]["is_alive"]:
				# Update waypoint to track moving base ship
				u["waypoints"] = [units[base_id]["position"]]
				var dist_to_base: float = u["position"].distance_to(units[base_id]["position"])
				if dist_to_base < 1.0:
					_land_aircraft(uid, u)

## Initiate return-to-base for an airborne unit.
func _air_rtb(uid: String, u: Dictionary) -> void:
	var base_id: String = u.get("base_unit_id", "")
	if base_id != "" and base_id in units and units[base_id]["is_alive"]:
		u["waypoints"] = [units[base_id]["position"]]
		u["speed_kts"] = u["max_speed_kts"] * 0.8
		u["behavior"] = "rtb"
		aircraft_bingo.emit(uid, u.get("name", uid))
	elif base_id != "" and (base_id not in units or not units[base_id]["is_alive"]):
		# Base ship destroyed -- divert or crash when fuel runs out
		u["behavior"] = "rtb"
		aircraft_bingo.emit(uid, u.get("name", uid))

## Land aircraft on its base ship. Refuels and goes on deck for relaunch.
func _land_aircraft(uid: String, u: Dictionary) -> void:
	u["is_airborne"] = false
	u["altitude_ft"] = 0.0
	u["ordered_altitude_ft"] = 0.0
	u["fuel_remaining"] = 1.0
	u["speed_kts"] = 0.0
	u["behavior"] = "hold"
	u["waypoints"] = []
	u["visible"] = false
	var base_id: String = u.get("base_unit_id", "")
	if base_id != "" and base_id in units:
		u["position"] = units[base_id]["position"]
	aircraft_landed.emit(uid, u.get("name", uid))

## Aircraft ran out of fuel in flight -- lost.
func _crash_aircraft(uid: String, u: Dictionary) -> void:
	aircraft_crashed.emit(uid, u.get("name", uid))
	destroy_unit(uid)

func _turn_toward(current_deg: float, target_deg: float, max_turn: float) -> float:
	var diff: float = fmod(target_deg - current_deg + 540.0, 360.0) - 180.0
	var turn: float = clampf(diff, -max_turn, max_turn)
	return fmod(current_deg + turn + 360.0, 360.0)

# ---------------------------------------------------------------------------
# AI behaviors (enemy units)
# ---------------------------------------------------------------------------
func _run_ai_behaviors() -> void:
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

func is_weapon_valid_for_target(wdata: Dictionary, target: Dictionary) -> bool:
	var wtype: String = wdata.get("type", "")
	var ttype: String = target["platform"].get("type", "")
	var target_submerged: bool = target["depth_m"] < -5.0

	match wtype:
		"ASM":  # Anti-ship missile -- surface targets only
			return not target_submerged
		"SAM":  # Surface-to-air -- not useful against ships/subs
			return false
		"torpedo":
			return true  # Torpedoes work against surface and submerged
		_:
			return true

func _get_best_weapon_range(u: Dictionary) -> float:
	var best: float = 10.0
	for weapon_id in u["weapons_remaining"]:
		var wrec: Dictionary = u["weapons_remaining"][weapon_id]
		if wrec["count"] > 0:
			var r: float = wrec["data"].get("max_range_nm", 10.0)
			if r > best:
				best = r
	return best

# ---------------------------------------------------------------------------
# Detection model
# ---------------------------------------------------------------------------
func _update_detections() -> void:
	for detector_id in units:
		var detector: Dictionary = units[detector_id]
		if not detector["is_alive"]:
			continue

		if detector_id not in contacts:
			contacts[detector_id] = {}

		for target_id in units:
			if target_id == detector_id:
				continue
			var target: Dictionary = units[target_id]
			if not target["is_alive"]:
				continue

			var detection: Dictionary = _compute_detection(detector, target)
			var prev_detected: bool = target_id in contacts[detector_id]
			var prev_tma_ticks: int = 0
			if prev_detected:
				prev_tma_ticks = contacts[detector_id][target_id].get("tma_ticks", 0)

			if detection["detected"]:
				contacts[detector_id][target_id] = detection
				detector["contacts"][target_id] = detection
				# TMA: bearing-only contacts accumulate bearing observations over time
				if detection.get("bearing_only", false):
					var tma_ticks: int = prev_tma_ticks + 1
					var tma_progress: float = clampf(float(tma_ticks) / 900.0, 0.0, 1.0)  # 15 min to full TMA
					detection["tma_ticks"] = tma_ticks
					detection["tma_progress"] = tma_progress
					# Once TMA > 0.5, start providing range estimate (noisy at first, improving)
					if tma_progress >= 0.5:
						var true_range: float = detector["position"].distance_to(target["position"])
						var noise_factor: float = lerpf(0.4, 0.05, (tma_progress - 0.5) / 0.5)
						detection["range_est"] = true_range * _rng.randf_range(1.0 - noise_factor, 1.0 + noise_factor)
						detection["bearing_only"] = false
					contacts[detector_id][target_id] = detection
					detector["contacts"][target_id] = detection
				if not prev_detected:
					unit_detected.emit(detector_id, target_id, detection)
				# Classification update
				if detection.get("confidence", 0.0) > 0.5:
					contact_classified.emit(detector_id, target_id, detection)
			else:
				if prev_detected:
					contacts[detector_id].erase(target_id)
					detector["contacts"].erase(target_id)
					detection_lost.emit(detector_id, target_id)

	# SOSUS barrier detection (passive environmental sensor)
	_update_sosus_detections()

func _compute_detection(detector: Dictionary, target: Dictionary) -> Dictionary:
	var range_nm: float = detector["position"].distance_to(target["position"])
	var target_submerged: bool = target["depth_m"] < -5.0
	var detector_submerged: bool = detector["depth_m"] < -5.0

	var best_result := {"detected": false, "confidence": 0.0, "method": "none", "bearing": 0.0, "range_est": 0.0}

	# Bearing from detector to target (always computable for result dict)
	var to_target: Vector2 = target["position"] - detector["position"]
	var bearing: float = rad_to_deg(atan2(to_target.x, to_target.y))
	if bearing < 0:
		bearing += 360.0
	best_result["bearing"] = bearing
	best_result["range_est"] = range_nm

	# RADAR detection (surface units detecting surface/surfaced targets)
	if detector["emitting_radar"] and not target_submerged and not detector_submerged:
		var radar_result: Dictionary = _radar_detection(detector, target, range_nm)
		if radar_result["p_detect"] > best_result["confidence"]:
			best_result["confidence"] = radar_result["p_detect"]
			best_result["method"] = "radar"
			best_result["detected"] = radar_result["p_detect"] > 0.1
			best_result["range_est"] = range_nm + _rng.randf_range(-0.5, 0.5)  # Range noise
			best_result["radar_data"] = radar_result

	# SONAR detection (passive -- always running)
	var sonar_result: Dictionary = _sonar_detection_passive(detector, target, range_nm)
	if sonar_result["snr_db"] > 0.0:
		var p_sonar: float = _snr_to_probability(sonar_result["snr_db"])
		if p_sonar > best_result["confidence"]:
			best_result["confidence"] = p_sonar
			best_result["method"] = "sonar_passive"
			best_result["detected"] = p_sonar > 0.1
			best_result["range_est"] = 0.0  # Passive sonar: bearing only, no range
			best_result["bearing_only"] = true
			best_result["sonar_data"] = sonar_result

	# SONAR detection (active -- if enabled)
	if detector["emitting_sonar_active"]:
		var active_result: Dictionary = _sonar_detection_active(detector, target, range_nm)
		if active_result["snr_db"] > 0.0:
			var p_active: float = _snr_to_probability(active_result["snr_db"])
			if p_active > best_result["confidence"]:
				best_result["confidence"] = p_active
				best_result["method"] = "sonar_active"
				best_result["detected"] = p_active > 0.1
				best_result["range_est"] = range_nm + _rng.randf_range(-0.2, 0.2)
				best_result["sonar_data"] = active_result

	# Item 12: ESM -- passively detect radar emitters at extended range
	# ESM works if detector has ESM and target is emitting radar
	# Submarines need periscope depth (depth_m > -20) for ESM
	var detector_has_esm: bool = detector["platform"].get("has_esm", false) or detector["platform"].get("has_ecm", false)
	if detector_has_esm and target.get("emitting_radar", false):
		# Subs only get ESM at periscope depth
		var sub_esm_ok: bool = true
		if detector["depth_m"] < -20.0:
			sub_esm_ok = false
		if sub_esm_ok:
			# ESM detection range = 2x target's best radar max_range_nm
			var target_best_radar_range: float = 0.0
			for sensor in target.get("sensors", []):
				if sensor is Dictionary and sensor.get("type", "") == "radar":
					var sr: float = sensor.get("max_range_nm", 0.0)
					if sr > target_best_radar_range:
						target_best_radar_range = sr
			if target_best_radar_range > 0.0:
				var esm_range: float = 2.0 * target_best_radar_range
				var p_esm: float = 0.0
				if range_nm <= esm_range:
					p_esm = 0.85
				elif range_nm <= esm_range * 1.5:
					# Linear falloff from 0.85 to 0.1 between esm_range and 1.5*esm_range
					var t: float = (range_nm - esm_range) / (esm_range * 0.5)
					p_esm = lerpf(0.85, 0.1, t)
				if p_esm > best_result["confidence"]:
					best_result["confidence"] = p_esm
					best_result["method"] = "esm"
					best_result["detected"] = p_esm > 0.1
					best_result["range_est"] = 0.0  # ESM: bearing only
					best_result["bearing_only"] = true

	# Item 13: Active sonar counter-detection -- detect active sonar emitters at extended range
	if target.get("emitting_sonar_active", false):
		# Detector needs any sonar sensor to intercept the ping
		var detector_has_sonar: bool = false
		var detector_best_active_range: float = 0.0
		for sensor in detector["sensors"]:
			if sensor.get("type", "") == "sonar":
				detector_has_sonar = true
				var ar: float = sensor.get("max_range_nm_active", 0.0)
				if ar > detector_best_active_range:
					detector_best_active_range = ar
		if detector_has_sonar:
			# Active sonar emission detectable at 3x the sonar's own active range
			# Use target's sonar active range as basis
			var target_active_range: float = 0.0
			for sensor in target.get("sensors", []):
				if sensor is Dictionary and sensor.get("type", "") == "sonar":
					var tar: float = sensor.get("max_range_nm_active", 0.0)
					if tar > target_active_range:
						target_active_range = tar
			if target_active_range > 0.0:
				var intercept_range: float = 3.0 * target_active_range
				if range_nm <= intercept_range:
					var p_intercept: float = 0.80
					# Thermal layer: apply only half penalty (ping is very loud)
					var thermal_depth: float = environment.get("thermal_layer_depth_m", 75.0)
					var det_depth_i: float = absf(detector["depth_m"])
					var tgt_depth_i: float = absf(target["depth_m"])
					if (det_depth_i < thermal_depth and tgt_depth_i > thermal_depth) or \
						(det_depth_i > thermal_depth and tgt_depth_i < thermal_depth):
						p_intercept *= 0.7  # Half the normal 15dB penalty effect
					if p_intercept > best_result["confidence"]:
						best_result["confidence"] = p_intercept
						best_result["method"] = "sonar_intercept"
						best_result["detected"] = true
						best_result["range_est"] = 0.0  # Sonar intercept: bearing only
						best_result["bearing_only"] = true

	# Apply random roll against probability
	if best_result["detected"]:
		var roll: float = _rng.randf()
		if roll > best_result["confidence"]:
			best_result["detected"] = false

	# Add classification data
	if best_result["detected"]:
		best_result["classification"] = _classify_contact(detector, target, best_result)

	return best_result

# ---------------------------------------------------------------------------
# Radar equation: P(detect) = f(power, RCS, range, sea_state, countermeasures)
# ---------------------------------------------------------------------------
func _radar_detection(detector: Dictionary, target: Dictionary, range_nm: float) -> Dictionary:
	# Find best radar sensor on detector
	var best_radar: Dictionary = {}
	for sensor in detector["sensors"]:
		if sensor.get("type", "") == "radar":
			if best_radar.is_empty() or sensor.get("peak_power_kw", 0) > best_radar.get("peak_power_kw", 0):
				best_radar = sensor

	if best_radar.is_empty():
		return {"p_detect": 0.0}

	# Item 11: Radar horizon check -- Earth curvature limits surface radar vs surface targets
	# Airborne units use their flight altitude instead of platform antenna height
	var antenna_height_ft: float
	if detector.get("is_airborne", false):
		antenna_height_ft = detector.get("altitude_ft", 0.0)
	else:
		antenna_height_ft = detector["platform"].get("antenna_height_ft", 80.0)
	var target_submerged_local: bool = target["depth_m"] < -5.0
	var target_height_ft: float
	if target.get("is_airborne", false):
		target_height_ft = target.get("altitude_ft", 0.0)
	elif target_submerged_local:
		target_height_ft = 0.0
	else:
		target_height_ft = target["platform"].get("antenna_height_ft", 50.0)
	var radar_horizon_nm: float = 1.23 * (sqrt(antenna_height_ft) + sqrt(target_height_ft))
	if range_nm > radar_horizon_nm:
		return {"p_detect": 0.0}

	# Radar equation (simplified): detection range proportional to (P * G^2 * lambda^2 * sigma)^(1/4)
	# We normalize to the sensor's max_range_nm as the reference detection range for a 10000 m^2 target
	var peak_power_kw: float = best_radar.get("peak_power_kw", 1000.0)
	var max_range_nm: float = best_radar.get("max_range_nm", 200.0)
	var ref_rcs: float = 10000.0  # Reference RCS in m^2 (large ship)

	var target_rcs: float = target["platform"].get("rcs_m2", 5000.0)

	# Detection range scales as (RCS / ref_RCS)^(1/4) * max_range
	var effective_range: float = max_range_nm * pow(target_rcs / ref_rcs, 0.25)

	# Sea state clutter degrades radar (use weather_sea_state as authoritative)
	var clutter_factor: float = 1.0 - SEA_STATE_RADAR_CLUTTER.get(weather_sea_state, 0.2)
	effective_range *= maxf(clutter_factor, 0.05)  # Floor at 5% to prevent div-by-zero

	# ECM/countermeasures (placeholder -- reduce effective range by 30% if target has ECM)
	if target["platform"].get("has_ecm", false):
		effective_range *= 0.7

	# Weather / sea state clutter modifier (rain + high sea state mask surface contacts)
	effective_range *= _weather_radar_modifier()

	# Probability based on range vs effective range
	var p_detect: float = 0.0
	if effective_range < 0.01:
		return {"p_detect": 0.0}  # Radar completely degraded
	if range_nm <= 0.1:
		p_detect = 1.0
	elif range_nm < effective_range:
		var ratio: float = range_nm / effective_range
		p_detect = clampf(1.0 - pow(ratio, 4.0), 0.0, 1.0)
	else:
		var overshoot: float = range_nm / effective_range
		if overshoot < 1.3:
			p_detect = clampf(0.1 * (1.3 - overshoot) / 0.3, 0.0, 0.1)

	return {
		"p_detect": p_detect,
		"effective_range_nm": effective_range,
		"target_rcs": target_rcs,
		"clutter_factor": clutter_factor,
		"sensor": best_radar.get("id", "unknown"),
	}

# ---------------------------------------------------------------------------
# Sonar equations: SNR = SL - TL + TS - NL - DT
# Passive sonar -- listens for target noise
# ---------------------------------------------------------------------------
func _sonar_detection_passive(detector: Dictionary, target: Dictionary, range_nm: float) -> Dictionary:
	# Find best sonar sensor
	var best_sonar: Dictionary = {}
	for sensor in detector["sensors"]:
		if sensor.get("type", "") == "sonar":
			# Dipping sonar only works when helicopter is hovering (speed < 5 kts)
			if sensor.get("subtype", "") == "dipping" and detector.get("speed_kts", 0.0) >= 5.0:
				continue
			if best_sonar.is_empty() or sensor.get("sensitivity_db", 0) > best_sonar.get("sensitivity_db", 0):
				best_sonar = sensor

	if best_sonar.is_empty():
		return {"snr_db": -999.0}

	# Source Level: target's noise output (speed-dependent)
	var base_noise_db: float = target["platform"].get("noise_db_cruise", 120.0)
	var speed_ratio: float = target["speed_kts"] / maxf(target["max_speed_kts"], 1.0)
	# Noise increases ~6dB per doubling of speed
	var sl_db: float = base_noise_db + 20.0 * log(maxf(speed_ratio, 0.01)) / log(10.0)

	# If target is not moving, very quiet
	if target["speed_kts"] < 1.0:
		sl_db = base_noise_db - 30.0

	# Transmission Loss: TL = 20*log10(range_m) + alpha*range_m/1000
	# (spherical spreading + absorption)
	var range_m: float = range_nm * 1852.0
	var alpha: float = 0.0002  # dB per meter (mid-frequency, ~0.2 dB/km at 3.5 kHz)
	var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0

	# Target Strength (TS) -- not used in passive, set to 0
	var ts_db: float = 0.0

	# Noise Level at detector: ambient baseline (linear) + Wenz-curve modifier (non-linear)
	# weather_sea_state is authoritative — synced with environment.sea_state on every update
	var ambient_noise: float = 40.0 + 3.0 * weather_sea_state
	var nl_db: float = ambient_noise + _sea_state_noise_modifier(weather_sea_state)

	# Thermal layer: if target is below thermal layer and detector is above (or vice versa),
	# add 15dB loss
	var thermal_depth: float = environment.get("thermal_layer_depth_m", 75.0)
	var det_depth: float = absf(detector["depth_m"])
	var tgt_depth: float = absf(target["depth_m"])
	if (det_depth < thermal_depth and tgt_depth > thermal_depth) or \
		(det_depth > thermal_depth and tgt_depth < thermal_depth):
		tl_db += 15.0

	# Convergence zone: in deep water, sound refocuses at ~33nm intervals
	# This creates detection opportunities at CZ ranges even through the thermal layer
	var water_depth: float = environment.get("water_depth_m", 200.0)
	if water_depth >= 250.0:  # CZ only forms in deep water
		var cz_interval: float = 33.0  # nautical miles between convergence zones
		var cz_width: float = 3.0  # width of CZ ring in NM
		# Check if target is in a convergence zone
		var cz_number: float = range_nm / cz_interval
		var cz_remainder: float = absf(cz_number - roundf(cz_number)) * cz_interval
		if cz_remainder < cz_width and range_nm > 20.0:  # CZ starts beyond direct path
			# In CZ: reduce TL by 15dB (refocused energy)
			tl_db -= 15.0

	# Detection Threshold from sensor
	var dt_db: float = best_sonar.get("detection_threshold_db", 10.0)

	# SNR = SL - TL + TS - NL - DT
	var snr: float = sl_db - tl_db + ts_db - nl_db - dt_db

	# Detector gain (array gain)
	var array_gain: float = best_sonar.get("array_gain_db", 20.0)
	snr += array_gain

	# Item 16: difficulty scaling -- detection_mult adjusts SNR in dB
	var det_mult: float = difficulty.get("detection_mult", 1.0)
	if det_mult > 0.0 and det_mult != 1.0:
		snr += 10.0 * log(det_mult) / log(10.0)

	return {
		"snr_db": snr,
		"sl_db": sl_db,
		"tl_db": tl_db,
		"nl_db": nl_db,
		"dt_db": dt_db,
		"sensor": best_sonar.get("id", "unknown"),
	}

# ---------------------------------------------------------------------------
# Active sonar: SNR = SL - 2*TL + TS - NL - DT
# ---------------------------------------------------------------------------
func _sonar_detection_active(detector: Dictionary, target: Dictionary, range_nm: float) -> Dictionary:
	var best_sonar: Dictionary = {}
	for sensor in detector["sensors"]:
		if sensor.get("type", "") == "sonar":
			# Dipping sonar only works when helicopter is hovering (speed < 5 kts)
			if sensor.get("subtype", "") == "dipping" and detector.get("speed_kts", 0.0) >= 5.0:
				continue
			if best_sonar.is_empty() or sensor.get("source_level_db", 0) > best_sonar.get("source_level_db", 0):
				best_sonar = sensor

	if best_sonar.is_empty():
		return {"snr_db": -999.0}

	# Source Level: the sonar's own emission power
	var sl_db: float = best_sonar.get("source_level_db", 220.0)

	# Transmission Loss (two-way for active)
	var range_m: float = range_nm * 1852.0
	var alpha: float = 0.0002  # dB per meter (mid-frequency, ~0.2 dB/km at 3.5 kHz)
	var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0

	# Target Strength
	var ts_db: float = target["platform"].get("target_strength_db", 15.0)

	# Noise Level + active sonar reverb modifier (weather_sea_state is authoritative)
	var nl_db: float = 40.0 + 3.0 * weather_sea_state + _sea_state_active_sonar_modifier(weather_sea_state)

	# Thermal layer penalty
	var thermal_depth: float = environment.get("thermal_layer_depth_m", 75.0)
	var det_depth: float = absf(detector["depth_m"])
	var tgt_depth: float = absf(target["depth_m"])
	if (det_depth < thermal_depth and tgt_depth > thermal_depth) or \
		(det_depth > thermal_depth and tgt_depth < thermal_depth):
		tl_db += 15.0

	var dt_db: float = best_sonar.get("detection_threshold_db", 10.0)
	var array_gain: float = best_sonar.get("array_gain_db", 20.0)

	# SNR = SL - 2*TL + TS - NL - DT + ArrayGain
	var snr: float = sl_db - 2.0 * tl_db + ts_db - nl_db - dt_db + array_gain

	# Item 16: difficulty scaling -- detection_mult adjusts SNR in dB
	var det_mult_a: float = difficulty.get("detection_mult", 1.0)
	if det_mult_a > 0.0 and det_mult_a != 1.0:
		snr += 10.0 * log(det_mult_a) / log(10.0)

	return {
		"snr_db": snr,
		"sl_db": sl_db,
		"tl_db": tl_db,
		"ts_db": ts_db,
		"nl_db": nl_db,
		"dt_db": dt_db,
		"sensor": best_sonar.get("id", "unknown"),
	}

# ---------------------------------------------------------------------------
# SOSUS barrier detection -- passive seabed hydrophone array
# ---------------------------------------------------------------------------
func _update_sosus_detections() -> void:
	for barrier in sosus_barriers:
		for target_id in units:
			var target: Dictionary = units[target_id]
			if not target["is_alive"] or target["faction"] != "enemy":
				continue
			if target["depth_m"] >= -5.0:
				continue  # SOSUS detects submerged contacts only

			# Check if target is within detection range of the barrier line
			var target_pos: Vector2 = target["position"]
			var closest: Vector2 = _closest_point_on_line(barrier["start_pos"], barrier["end_pos"], target_pos)
			var dist_nm: float = target_pos.distance_to(closest)

			# SOSUS detection: target noise vs distance, very long range
			var target_noise: float = target["platform"].get("noise_db_cruise", 120.0)
			var speed_ratio: float = target["speed_kts"] / maxf(target["max_speed_kts"], 1.0)
			var sl: float = target_noise + 20.0 * log(maxf(speed_ratio, 0.01)) / log(10.0)
			if target["speed_kts"] < 1.0:
				sl = target_noise - 30.0

			# SOSUS uses very low frequency, long range -- less TL than tactical sonar
			var range_m: float = dist_nm * 1852.0
			var tl: float = 10.0 * log(maxf(range_m, 1.0)) / log(10.0)  # Cylindrical spreading (SOFAR channel)

			var snr: float = sl - tl - 50.0 + barrier["sensitivity_db"] - 70.0  # NL~50, DT~70 for SOSUS

			if snr > 0.0:
				# SOSUS gives bearing only, with +/- 5-10 degree error
				var to_target: Vector2 = target_pos - closest
				var bearing: float = rad_to_deg(atan2(to_target.x, to_target.y))
				if bearing < 0:
					bearing += 360.0
				bearing += _rng.randf_range(-8.0, 8.0)  # Bearing error
				bearing = fmod(bearing + 360.0, 360.0)

				var confidence: float = clampf(snr / 20.0, 0.2, 0.6)  # SOSUS never gives high confidence

				# Emit every 30 ticks (not every tick)
				if tick_count % 30 == 0:
					sosus_contact.emit(barrier["id"], bearing, confidence)

func _closest_point_on_line(a: Vector2, b: Vector2, p: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	if ab.dot(ab) < 0.0001:
		return a  # Zero-length line guard
	var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
	return a + ab * t

# ---------------------------------------------------------------------------
# Sonobuoy detection processing -- runs each tick for all active buoys
# ---------------------------------------------------------------------------
func _process_sonobuoy_detections() -> void:
	var expired: Array = []

	for buoy_id in sonobuoys:
		var buoy: Dictionary = sonobuoys[buoy_id]

		# Battery check
		var age: float = sim_time - buoy["deploy_time"]
		if age > buoy["battery_life"]:
			expired.append(buoy_id)
			continue

		# Determine enemy faction relative to this buoy's faction
		var enemy_faction: String = "enemy" if buoy["faction"] == "player" else "player"

		for uid in units:
			var target: Dictionary = units[uid]
			if not target["is_alive"] or target["faction"] != enemy_faction:
				continue
			# Sonobuoys detect underwater contacts only (submarines and surface ships below waterline)
			# Skip airborne units -- they make no underwater sound
			if target.get("is_airborne", false):
				continue

			var dist_nm: float = buoy["position"].distance_to(target["position"])

			# --- Source Level (same formula as _sonar_detection_passive) ---
			var base_noise_db: float = target["platform"].get("noise_db_cruise", 120.0)
			var speed_ratio: float = target["speed_kts"] / maxf(target["max_speed_kts"], 1.0)
			var sl_db: float = base_noise_db + 20.0 * log(maxf(speed_ratio, 0.01)) / log(10.0)
			if target["speed_kts"] < 1.0:
				sl_db = base_noise_db - 30.0

			# --- Transmission Loss (same formula as _sonar_detection_passive) ---
			var range_m: float = dist_nm * 1852.0
			var alpha: float = 0.0002  # dB per meter (mid-frequency, ~0.2 dB/km at 3.5 kHz)
			var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0

			# Thermal layer penalty: buoys float on the surface (depth 0), so submarines
			# below the thermal layer incur the same 15dB cross-layer penalty
			var thermal_depth: float = environment.get("thermal_layer_depth_m", 75.0)
			var tgt_depth: float = absf(target["depth_m"])
			if tgt_depth > thermal_depth:
				tl_db += 15.0

			# Convergence zone (same as _sonar_detection_passive)
			var water_depth: float = environment.get("water_depth_m", 200.0)
			if water_depth >= 250.0:
				var cz_interval: float = 33.0
				var cz_width: float = 3.0
				var cz_number: float = dist_nm / cz_interval
				var cz_remainder: float = absf(cz_number - roundf(cz_number)) * cz_interval
				if cz_remainder < cz_width and dist_nm > 20.0:
					tl_db -= 15.0

			# --- Noise Level (same formula as _sonar_detection_passive) ---
			var nl_db: float = 40.0 + 3.0 * weather_sea_state + _sea_state_noise_modifier(weather_sea_state)

			# --- Detection Threshold (buoy sensitivity, no array gain -- single omnidirectional hydrophone) ---
			var dt_db: float = buoy["sensitivity_db"]

			# SNR = SL - TL - NL - DT  (passive, no target strength, no array gain)
			var snr: float = sl_db - tl_db - nl_db - dt_db

			# Difficulty scaling (same as _sonar_detection_passive)
			var det_mult: float = difficulty.get("detection_mult", 1.0)
			if det_mult > 0.0 and det_mult != 1.0:
				snr += 10.0 * log(det_mult) / log(10.0)

			if snr > 0.0 and tick_count % 10 == 0:  # Throttle: emit every 10 ticks
				var bearing: float = rad_to_deg(atan2(
					target["position"].x - buoy["position"].x,
					target["position"].y - buoy["position"].y
				))
				if bearing < 0.0:
					bearing += 360.0
				sonobuoy_contact.emit(buoy_id, uid, bearing, snr)

	# Remove expired buoys after iteration
	for buoy_id in expired:
		sonobuoy_expired.emit(buoy_id)
		sonobuoys.erase(buoy_id)

func _snr_to_probability(snr_db: float) -> float:
	# Sigmoid mapping: SNR -> probability
	# At SNR=0dB -> ~50% detection, SNR=10dB -> ~93%, SNR=-10dB -> ~7%
	return 1.0 / (1.0 + exp(-0.5 * snr_db))

# ---------------------------------------------------------------------------
# Weather helper functions
# ---------------------------------------------------------------------------

## Returns wind speed in knots from Beaufort-scale sea state approximation.
func _sea_state_to_wind(ss: int) -> float:
	match ss:
		1: return 5.0
		2: return 10.0
		3: return 15.0
		4: return 20.0
		5: return 30.0
		6: return 40.0
		_: return 20.0

## Returns visibility in nautical miles based on weather type and sea state.
func _weather_to_visibility(weather: String, ss: int) -> float:
	var base: float
	match weather:
		"clear": base = 30.0
		"overcast": base = 20.0
		"rain": base = 8.0
		"storm": base = 3.0
		_: base = 20.0
	# High sea state reduces visibility further
	if ss >= 5:
		base *= 0.7
	return base

## Returns ambient noise modifier in dB for passive sonar based on sea state.
## Based on Wenz curves for wind-driven ocean noise.
## SS1-2: quieter ocean improves passive sonar; SS5-6: nearly unusable.
func _sea_state_noise_modifier(ss: int) -> float:
	match ss:
		1: return -6.0  # Very calm, excellent passive sonar conditions
		2: return -3.0
		3: return 0.0   # Baseline
		4: return 3.0   # Moderate degradation
		5: return 8.0   # Significant noise, passive sonar struggling
		6: return 14.0  # Awful conditions, nearly blind
		_: return 0.0

## Returns active sonar reverb penalty in dB based on sea state.
## Active sonar less affected by ambient noise but reverb increases with sea state.
func _sea_state_active_sonar_modifier(ss: int) -> float:
	match ss:
		1: return -2.0
		2: return -1.0
		3: return 0.0
		4: return 1.0
		5: return 3.0
		6: return 5.0
		_: return 0.0

## Returns a range multiplier for radar effective detection range.
## Rain and high sea state cause clutter that masks contacts.
func _weather_radar_modifier() -> float:
	var mult: float = 1.0
	match weather_type:
		"clear": mult = 1.0
		"overcast": mult = 0.95
		"rain": mult = 0.7   # Rain clutter significant
		"storm": mult = 0.4  # Severe clutter, radar nearly useless
	# Sea state clutter (affects surface radar)
	if weather_sea_state >= 5:
		mult *= 0.8
	if weather_sea_state >= 6:
		mult *= 0.7
	return maxf(mult, 0.05)  # Floor to prevent zero effective range

## Checks for gradual weather shifts every 30 minutes of sim time.
## 30% cumulative chance per interval that sea state shifts ±1.
## Emits weather_changed signal if conditions change.
const WEATHER_CHECK_INTERVAL: float = 1800.0  # 30 minutes sim time

func _maybe_update_weather(sim_time_now: float) -> void:
	if sim_time_now - _last_weather_check_time < WEATHER_CHECK_INTERVAL:
		return
	_last_weather_check_time = sim_time_now
	# 30% chance of sea state shift (15% up, 15% down)
	var roll: float = _rng.randf()  # Use seeded RNG, not global randf()
	if roll < 0.15:
		weather_sea_state = mini(weather_sea_state + 1, 6)
	elif roll < 0.30:
		weather_sea_state = maxi(weather_sea_state - 1, 1)
	else:
		return  # No change
	# Sync environment dict so all systems use same sea state
	environment["sea_state"] = weather_sea_state
	weather_wind_kts = _sea_state_to_wind(weather_sea_state)
	weather_visibility_nm = _weather_to_visibility(weather_type, weather_sea_state)
	weather_changed.emit(weather_sea_state, weather_type, weather_visibility_nm)

# ---------------------------------------------------------------------------
# Contact classification
# ---------------------------------------------------------------------------
func _classify_contact(detector: Dictionary, target: Dictionary, detection: Dictionary) -> Dictionary:
	var confidence: float = detection["confidence"]
	var result := {
		"type": "UNKNOWN",
		"class": "",
		"designator": "",
		"confidence": confidence,
	}

	# Generate NATO-style contact designator
	var platform_type: String = target["platform"].get("type", "")
	var prefix: String
	match platform_type:
		"DDG", "FFG", "CGN":
			prefix = "SIERRA"  # Surface contact
		"SSN":
			prefix = "GOBLIN" if target["depth_m"] < -5.0 else "SIERRA"
		"HELO", "MPA":
			prefix = "BOGEY"  # Air contact
		_:
			prefix = "SIERRA"

	# N-4: use incrementing counter to avoid designator collisions
	if target["id"] not in _unit_designators:
		_unit_designators[target["id"]] = "%s-%02d" % [prefix, _next_designator]
		_next_designator += 1
	result["designator"] = _unit_designators[target["id"]]

	# Classification improves with confidence
	if confidence > 0.8:
		result["type"] = platform_type
		result["class"] = target["platform"].get("class_name", "Unknown Class")
	elif confidence > 0.5:
		match platform_type:
			"DDG", "FFG", "CGN":
				result["type"] = "SURFACE"
			"SSN":
				result["type"] = "SUBSURFACE" if target["depth_m"] < -5.0 else "SURFACE"
			"HELO", "MPA":
				result["type"] = "AIR"
	# Below 0.5: stays UNKNOWN

	return result

# ---------------------------------------------------------------------------
# Weapon firing
# ---------------------------------------------------------------------------
func fire_weapon(shooter_id: String, target_id: String, weapon_type_id: String) -> String:
	if _game_over:
		return ""
	# ROE enforcement: maintain_contact scenarios = weapons hold
	var victory_type: String = scenario.get("victory_condition", {}).get("type", "")
	if victory_type == "maintain_contact" and shooter_id in units and units[shooter_id]["faction"] == "player":
		_game_over = true
		scenario_ended.emit("defeat")
		is_paused = true
		return ""

	if shooter_id not in units or target_id not in units:
		return ""

	var shooter: Dictionary = units[shooter_id]
	var target: Dictionary = units[target_id]

	if weapon_type_id not in shooter["weapons_remaining"]:
		return ""

	var wrec: Dictionary = shooter["weapons_remaining"][weapon_type_id]
	if wrec["count"] <= 0:
		return ""

	var wdata: Dictionary = wrec["data"]

	# Check range
	var dist: float = shooter["position"].distance_to(target["position"])
	var max_range: float = wdata.get("max_range_nm", 50.0)
	if dist > max_range * 1.1:  # 10% grace for edge cases
		return ""
	if dist < wdata.get("min_range_nm", 0.0):  # M-1: minimum range check
		return ""

	# Decrement ammo
	wrec["count"] -= 1

	# Create weapon in flight
	_next_weapon_id += 1
	var wid: String = "WPN_%04d" % _next_weapon_id
	var weapon_instance := {
		"id": wid,
		"weapon_type_id": weapon_type_id,
		"data": wdata,
		"shooter_id": shooter_id,
		"target_id": target_id,
		"position": shooter["position"],
		"launch_position": Vector2(shooter["position"]),  # M-7: store launch position for Pk calc
		"speed_kts": wdata.get("speed_kts", 600.0),
		"time_of_flight": 0.0,
		"max_flight_time": max_range / maxf(wdata.get("speed_kts", 600.0) * KNOTS_TO_NM_PER_SEC, 0.001),
		"resolved": false,
	}
	weapons_in_flight[wid] = weapon_instance
	weapon_fired.emit(wid, shooter_id, target_id, wdata)
	return wid

# ---------------------------------------------------------------------------
# Weapon movement and resolution
# ---------------------------------------------------------------------------
func _move_weapons() -> void:
	for wid in weapons_in_flight:
		var w: Dictionary = weapons_in_flight[wid]
		if w["resolved"]:
			continue

		var target_id: String = w["target_id"]
		if target_id not in units or not units[target_id]["is_alive"]:
			w["resolved"] = true  # B-1: mark resolved BEFORE emitting
			weapon_resolved.emit(wid, target_id, false, 0.0)  # Miss feedback for target-gone
			weapon_removed.emit(wid)
			continue

		var target_pos: Vector2 = units[target_id]["position"]
		var old_pos: Vector2 = w["position"]
		var to_target: Vector2 = target_pos - old_pos
		var dist_nm: float = to_target.length()

		var move_dist: float = w["speed_kts"] * KNOTS_TO_NM_PER_SEC * (1.0 / BASE_TICK_HZ)

		if dist_nm <= move_dist:
			# Weapon arrives at target -- resolve
			w["position"] = target_pos
			weapon_moved.emit(wid, old_pos, target_pos)
		else:
			# Move toward target
			w["position"] = old_pos + to_target.normalized() * move_dist
			weapon_moved.emit(wid, old_pos, w["position"])

		w["time_of_flight"] += 1.0 / BASE_TICK_HZ

		# Timeout
		if w["time_of_flight"] > w["max_flight_time"]:
			w["resolved"] = true  # B-1: mark resolved BEFORE emitting
			# Fix 7: emit weapon_resolved (miss) on timeout so player sees feedback
			weapon_resolved.emit(wid, w["target_id"], false, 0.0)
			weapon_removed.emit(wid)

func _resolve_weapons() -> void:
	var to_remove := []
	for wid in weapons_in_flight:
		var w: Dictionary = weapons_in_flight[wid]
		if w["resolved"]:
			to_remove.append(wid)
			continue

		var target_id: String = w["target_id"]
		if target_id not in units:
			w["resolved"] = true
			to_remove.append(wid)
			continue

		var target: Dictionary = units[target_id]
		var dist: float = w["position"].distance_to(target["position"])

		# Close enough to resolve
		if dist < 0.5:  # Within 0.5 NM
			var hit: bool = _compute_weapon_hit(w, target)
			var damage: float = 0.0
			if hit:
				damage = _compute_weapon_damage(w, target)
				target["damage"] = minf(target["damage"] + damage, 1.0)
				if target["damage"] >= 1.0:
					destroy_unit(target_id)

			weapon_resolved.emit(wid, target_id, hit, damage)
			w["resolved"] = true
			to_remove.append(wid)

	for wid in to_remove:
		weapons_in_flight.erase(wid)

# ---------------------------------------------------------------------------
# Weapon Pk model: Pk(range, countermeasures, aspect)
# ---------------------------------------------------------------------------
func _compute_weapon_hit(w: Dictionary, target: Dictionary) -> bool:
	var wdata: Dictionary = w["data"]
	var base_pk: float = wdata.get("pk_base", 0.7)
	var max_range: float = wdata.get("max_range_nm", 50.0)

	# Range factor: Pk degrades at long range (M-7: use launch position, not current)
	var launch_pos: Vector2 = w.get("launch_position", w["position"])
	var launch_range: float = launch_pos.distance_to(target["position"])
	var range_ratio: float = launch_range / max_range
	var range_factor: float = clampf(1.0 - 0.5 * pow(range_ratio, 2.0), 0.3, 1.0)

	# Countermeasures factor (unit-level override_countermeasures takes priority)
	var cm_source: Dictionary = target.get("override_countermeasures", target["platform"])
	var cm_factor: float = 1.0
	if cm_source.get("has_ciws", false):
		cm_factor *= 0.6  # CIWS reduces Pk by 40%
	if cm_source.get("has_chaff", false) and wdata.get("guidance", "") == "radar":
		cm_factor *= 0.7  # Chaff vs radar-guided
	if cm_source.get("has_decoy", false) and wdata.get("type", "") == "torpedo":
		cm_factor *= 0.75  # Acoustic decoys vs torpedoes

	# Speed factor for torpedoes (faster targets harder to hit)
	var speed_factor: float = 1.0
	if wdata.get("type", "") == "torpedo":
		var target_speed: float = target["speed_kts"]
		if target_speed > 20.0:
			speed_factor = clampf(1.0 - (target_speed - 20.0) / 40.0, 0.4, 1.0)

	var final_pk: float = base_pk * range_factor * cm_factor * speed_factor

	# Item 16: difficulty scaling -- player Pk multiplier
	var shooter_id: String = w.get("shooter_id", "")
	if shooter_id in units and units[shooter_id]["faction"] == "player":
		final_pk *= difficulty.get("player_pk_mult", 1.0)

	var roll: float = _rng.randf()
	return roll <= final_pk

func _compute_weapon_damage(w: Dictionary, target: Dictionary) -> float:
	var wdata: Dictionary = w["data"]

	# Torpedoes vs submerged targets use fixed damage (pressure hull breach)
	if wdata.get("type", "") == "torpedo" and target["depth_m"] < -5.0:
		var sub_base: float = wdata.get("sub_damage", 0.45)
		return clampf(sub_base * _rng.randf_range(0.7, 1.3), 0.05, 1.0)

	var warhead_kg: float = wdata.get("warhead_kg", 200.0)
	var displacement: float = maxf(target["platform"].get("displacement_tons", 5000.0), 1.0)

	# Damage proportional to warhead vs displacement
	# 500kg warhead vs 8000 ton ship ~ 0.4 damage
	var base_damage: float = (warhead_kg / displacement) * 6.0
	# Add some randomness
	base_damage *= _rng.randf_range(0.7, 1.3)
	return clampf(base_damage, 0.05, 1.0)

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

	scenario = scenario_data
	environment = scenario_data.get("environment", environment)
	difficulty = scenario_data.get("difficulty", {})  # Item 16: load difficulty scaling

	# Initialize weather state from scenario environment block
	var env: Dictionary = scenario_data.get("environment", {})
	weather_sea_state = env.get("sea_state", 4)
	weather_type = env.get("weather", "overcast")
	weather_wind_kts = _sea_state_to_wind(weather_sea_state)
	weather_visibility_nm = _weather_to_visibility(weather_type, weather_sea_state)
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
