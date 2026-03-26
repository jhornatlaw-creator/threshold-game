extends RefCounted
## SonobuoySystem -- Sonobuoy deployment, lifecycle, detection processing,
## and pattern drops for ASW helicopters and P-3C Orion.
##
## Phase 7: Helicopter + P-3C Operations.
##
## Buoy types:
## - DIFAR (passive): directional passive sonobuoy. Listens. Reports bearing.
##   Does NOT alert the target. Battery 30-60 min.
## - DICASS (active): directional active sonobuoy. Pings. Reports bearing + range.
##   ALERTS the target submarine (AI should react). Battery ~30 min.
##
## Drop patterns:
## - SINGLE: one buoy at a point.
## - LINE: 3-5 buoys spaced 2-3nm along a heading.
## - FIELD: 6-8 buoys in a grid pattern.
##
## Integration point with Phase 6 (AIDoctrineSystem.gd):
##   When a DICASS buoy pings and detects a submarine, the sub gets a
##   counter-detection bearing on the buoy position. The AI should treat
##   this as a threat and potentially evade. This is signaled via
##   `dicass_alert_submarine(sub_id, buoy_position, bearing_to_buoy)`.
##   Phase 6 should connect to the `sonobuoy_dicass_alert` signal on
##   SimulationWorld and feed it into the AI doctrine evasion logic.

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

## Sonobuoy type enum
enum BuoyType { DIFAR = 0, DICASS = 1 }

## Drop pattern enum
enum DropPattern { SINGLE = 0, LINE = 1, FIELD = 2 }

## Default battery life in seconds (sim time)
const DIFAR_BATTERY_LIFE: float = 2400.0   # 40 minutes
const DICASS_BATTERY_LIFE: float = 1800.0  # 30 minutes

## Detection ranges (nm) -- base values, modified by SNR calculations
const DIFAR_BASE_DETECTION_RADIUS: float = 5.0   # passive, shorter range
const DICASS_BASE_DETECTION_RADIUS: float = 8.0   # active, longer range

## DICASS ping interval (seconds sim time) -- active buoys ping periodically
const DICASS_PING_INTERVAL: float = 30.0

## Line pattern: spacing between buoys (nm)
const LINE_SPACING_NM: float = 2.5
## Field pattern: grid spacing (nm)
const FIELD_SPACING_NM: float = 2.0

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

# ---------------------------------------------------------------------------
# Deploy a sonobuoy at a specific position with type selection
# ---------------------------------------------------------------------------

## Deploy a single sonobuoy from an airborne ASW platform.
## buoy_type: BuoyType.DIFAR or BuoyType.DICASS
## Returns the buoy_id string, or "" if the drop cannot be made.
func deploy_sonobuoy_typed(deployer_id: String, buoy_type: int,
		drop_position: Vector2 = Vector2.INF) -> String:
	if deployer_id not in _world.units:
		return ""
	var u: Dictionary = _world.units[deployer_id]
	if not u["is_alive"] or not u.get("is_airborne", false):
		return ""

	# Check inventory based on buoy type
	var difar_remaining: int = u.get("sonobuoys_difar", 0)
	var dicass_remaining: int = u.get("sonobuoys_dicass", 0)

	if buoy_type == BuoyType.DIFAR:
		if difar_remaining <= 0:
			return ""
		u["sonobuoys_difar"] = difar_remaining - 1
	elif buoy_type == BuoyType.DICASS:
		if dicass_remaining <= 0:
			return ""
		u["sonobuoys_dicass"] = dicass_remaining - 1
	else:
		return ""

	# Also decrement total count for backward compat
	var total: int = u.get("sonobuoys_remaining", 0)
	if total > 0:
		u["sonobuoys_remaining"] = total - 1

	# Use deployer position if no explicit drop position
	var pos: Vector2 = drop_position if drop_position != Vector2.INF else Vector2(u["position"])

	var buoy_id: String = "BUOY_%d" % _world._next_buoy_id
	_world._next_buoy_id += 1

	var battery_life: float = DIFAR_BATTERY_LIFE if buoy_type == BuoyType.DIFAR else DICASS_BATTERY_LIFE
	var sensitivity: float = 75.0 if buoy_type == BuoyType.DIFAR else 70.0  # DICASS slightly less sensitive passively

	_world.sonobuoys[buoy_id] = {
		"position": pos,
		"faction": u["faction"],
		"deploy_time": _world.sim_time,
		"battery_life": battery_life,
		"sensitivity_db": sensitivity,
		"deployer_id": deployer_id,
		"buoy_type": buoy_type,  # 0=DIFAR, 1=DICASS
		"last_ping_time": 0.0 if buoy_type == BuoyType.DICASS else -1.0,
		"contacts": {},  # target_id -> {bearing, range (DICASS only), snr, last_update}
	}

	_world.sonobuoy_deployed.emit(buoy_id, pos, u["faction"])
	return buoy_id

# ---------------------------------------------------------------------------
# Pattern drops -- deploy multiple buoys in formation
# ---------------------------------------------------------------------------

## Deploy a line pattern: buoys spaced along a heading from the start point.
## Returns array of buoy_id strings.
func deploy_pattern_line(deployer_id: String, center: Vector2,
		heading_deg: float, buoy_count: int, buoy_type: int) -> Array:
	var deployed: Array = []
	if buoy_count < 1:
		return deployed

	# Calculate start offset so pattern is centered
	var heading_rad: float = deg_to_rad(heading_deg)
	var dir: Vector2 = Vector2(sin(heading_rad), cos(heading_rad))
	var total_length: float = LINE_SPACING_NM * float(buoy_count - 1)
	var start_pos: Vector2 = center - dir * (total_length / 2.0)

	for i in range(buoy_count):
		var pos: Vector2 = start_pos + dir * (LINE_SPACING_NM * float(i))
		var bid: String = deploy_sonobuoy_typed(deployer_id, buoy_type, pos)
		if bid != "":
			deployed.append(bid)
		else:
			break  # Out of buoys
	return deployed

## Deploy a field pattern: buoys in a grid around a center point.
## Returns array of buoy_id strings.
func deploy_pattern_field(deployer_id: String, center: Vector2,
		buoy_type: int) -> Array:
	var deployed: Array = []
	# 3x3 grid minus corners = cross pattern (5 buoys) or full grid (8 buoys)
	# Use full grid for maximum coverage
	var offsets: Array = [
		Vector2(-1, -1), Vector2(0, -1), Vector2(1, -1),
		Vector2(-1, 0),                  Vector2(1, 0),
		Vector2(-1, 1),  Vector2(0, 1),  Vector2(1, 1),
	]
	for offset in offsets:
		var pos: Vector2 = center + offset * FIELD_SPACING_NM
		var bid: String = deploy_sonobuoy_typed(deployer_id, buoy_type, pos)
		if bid != "":
			deployed.append(bid)
		else:
			break  # Out of buoys
	return deployed

# ---------------------------------------------------------------------------
# Process sonobuoy detections -- called each tick by SimulationWorld
# ---------------------------------------------------------------------------

## Main tick: process all active sonobuoys for detection and expiry.
## This REPLACES the basic process_sonobuoy_detections() in DetectionSystem
## when the SonobuoySystem is active.
func process_sonobuoys() -> void:
	var expired: Array = []

	for buoy_id in _world.sonobuoys:
		var buoy: Dictionary = _world.sonobuoys[buoy_id]

		# Battery check
		var age: float = _world.sim_time - buoy["deploy_time"]
		if age > buoy["battery_life"]:
			expired.append(buoy_id)
			continue

		var buoy_type: int = buoy.get("buoy_type", BuoyType.DIFAR)

		# Determine enemy faction relative to this buoy's faction
		var enemy_faction: String = "enemy" if buoy["faction"] == "player" else "player"

		for uid in _world.units:
			var target: Dictionary = _world.units[uid]
			if not target["is_alive"] or target["faction"] != enemy_faction:
				continue
			# Sonobuoys detect underwater contacts only -- skip airborne units
			if target.get("is_airborne", false):
				continue

			if buoy_type == BuoyType.DIFAR:
				_process_difar(buoy_id, buoy, uid, target)
			elif buoy_type == BuoyType.DICASS:
				_process_dicass(buoy_id, buoy, uid, target)

	# Remove expired buoys after iteration
	for buoy_id in expired:
		_world.sonobuoy_expired.emit(buoy_id)
		_world.sonobuoys.erase(buoy_id)

# ---------------------------------------------------------------------------
# DIFAR (passive) processing
# ---------------------------------------------------------------------------
func _process_difar(buoy_id: String, buoy: Dictionary,
		target_id: String, target: Dictionary) -> void:
	var snr: float = _compute_passive_snr(buoy, target)

	# Throttle emissions to every 10 ticks
	if snr > 0.0 and _world.tick_count % 10 == 0:
		var bearing: float = _compute_bearing(buoy["position"], target["position"])

		# DIFAR: bearing only, no range
		buoy["contacts"][target_id] = {
			"bearing": bearing,
			"snr": snr,
			"last_update": _world.sim_time,
			"has_range": false,
		}

		# Emit sonobuoy_contact signal (bearing only)
		_world.sonobuoy_contact.emit(buoy_id, target_id, bearing, snr)

		# Feed bearing into deployer's helicopter/P-3C contact awareness
		_feed_aircraft_contact(buoy, target_id, bearing, -1.0, snr)

# ---------------------------------------------------------------------------
# DICASS (active) processing
# ---------------------------------------------------------------------------
func _process_dicass(buoy_id: String, buoy: Dictionary,
		target_id: String, target: Dictionary) -> void:
	# DICASS pings periodically -- check if it's time to ping
	var time_since_ping: float = _world.sim_time - buoy.get("last_ping_time", 0.0)
	if time_since_ping < DICASS_PING_INTERVAL:
		# Between pings: still process passive detection (like DIFAR)
		var passive_snr: float = _compute_passive_snr(buoy, target)
		if passive_snr > 0.0 and _world.tick_count % 10 == 0:
			var bearing: float = _compute_bearing(buoy["position"], target["position"])
			buoy["contacts"][target_id] = {
				"bearing": bearing,
				"snr": passive_snr,
				"last_update": _world.sim_time,
				"has_range": false,
			}
			_world.sonobuoy_contact.emit(buoy_id, target_id, bearing, passive_snr)
			_feed_aircraft_contact(buoy, target_id, bearing, -1.0, passive_snr)
		return

	# PING! Active detection
	buoy["last_ping_time"] = _world.sim_time

	var dist_nm: float = buoy["position"].distance_to(target["position"])
	var snr: float = _compute_active_snr(buoy, target, dist_nm)

	if snr > 0.0:
		var bearing: float = _compute_bearing(buoy["position"], target["position"])
		var range_est: float = dist_nm + _rng.randf_range(-0.3, 0.3)  # Small range error

		# DICASS: bearing AND range
		buoy["contacts"][target_id] = {
			"bearing": bearing,
			"range_nm": range_est,
			"snr": snr,
			"last_update": _world.sim_time,
			"has_range": true,
		}

		# Emit sonobuoy_contact signal with range encoded in snr
		_world.sonobuoy_contact.emit(buoy_id, target_id, bearing, snr)

		# Emit DICASS-specific signal with range data
		_world.sonobuoy_dicass_contact.emit(buoy_id, target_id, bearing, range_est, snr)

		# Feed bearing + range to deployer aircraft
		_feed_aircraft_contact(buoy, target_id, bearing, range_est, snr)

	# CRITICAL: DICASS ping ALERTS the target submarine
	# Any submarine within detection radius gets a bearing on the buoy
	_dicass_alert_targets(buoy_id, buoy)

# ---------------------------------------------------------------------------
# DICASS alert -- submarine counter-detection on active ping
# ---------------------------------------------------------------------------
func _dicass_alert_targets(buoy_id: String, buoy: Dictionary) -> void:
	## When a DICASS buoy pings, any submarine within 2x the detection radius
	## gets a bearing on the buoy's position. This feeds into the AI's
	## counter-detection awareness.
	##
	## PHASE 6 INTEGRATION POINT:
	## AIDoctrineSystem should connect to `sonobuoy_dicass_alert` signal
	## and treat it as a counter-detection event, potentially triggering
	## evasion behavior (go deep, change course, etc.).
	var alert_radius: float = DICASS_BASE_DETECTION_RADIUS * 2.0  # Ping is loud
	var target_faction: String = "player" if buoy["faction"] == "enemy" else "enemy"

	for uid in _world.units:
		var target: Dictionary = _world.units[uid]
		if not target["is_alive"] or target["faction"] != target_faction:
			continue
		# Only submarines can hear the ping underwater
		if target.get("is_airborne", false) or target["depth_m"] >= -5.0:
			continue
		if target["platform"].get("type", "") != "SSN":
			continue

		var dist_nm: float = buoy["position"].distance_to(target["position"])
		if dist_nm <= alert_radius:
			var bearing_to_buoy: float = _compute_bearing(target["position"], buoy["position"])
			_world.sonobuoy_dicass_alert.emit(uid, buoy_id, bearing_to_buoy)

# ---------------------------------------------------------------------------
# Feed sonobuoy data to deployer aircraft's contact picture
# ---------------------------------------------------------------------------
func _feed_aircraft_contact(buoy: Dictionary, target_id: String,
		bearing: float, range_nm: float, snr: float) -> void:
	## Push sonobuoy contact data into the deployer aircraft's contacts dict.
	## This gives the helicopter/P-3C its own sensor picture built from
	## its deployed sonobuoys.
	var deployer_id: String = buoy.get("deployer_id", "")
	if deployer_id == "" or deployer_id not in _world.units:
		return
	var deployer: Dictionary = _world.units[deployer_id]
	if not deployer["is_alive"]:
		return

	# Build a detection dict that looks like a normal sensor contact
	var det: Dictionary = {
		"detected": true,
		"confidence": clampf(snr / 20.0, 0.2, 0.9),
		"method": "sonobuoy",
		"bearing": bearing,
		"bearing_only": range_nm < 0.0,
		"range_est": maxf(range_nm, 0.0),
		"sonobuoy_source": true,
		"_stale_ticks": 0,
	}

	# Check if this is a new contact BEFORE inserting (suppress signal spam)
	var is_new_contact: bool = target_id not in _world.contacts.get(deployer_id, {})

	# Insert into deployer's contact dict
	if deployer_id not in _world.contacts:
		_world.contacts[deployer_id] = {}
	_world.contacts[deployer_id][target_id] = det
	deployer["contacts"][target_id] = det

	# Emit detection only if this is a NEW contact for the deployer
	if is_new_contact:
		_world.unit_detected.emit(deployer_id, target_id, det)

	# Feed bearing into TMA for solution development
	if det["bearing_only"] and _world.get("_tma_system") and _world._tma_system:
		_world._tma_system.feed_bearing(
			deployer_id, target_id,
			bearing,
			deployer["position"],
			deployer["heading"],
			deployer["speed_kts"]
		)

# ---------------------------------------------------------------------------
# SNR computation helpers
# ---------------------------------------------------------------------------

## Compute passive SNR for a sonobuoy (same physics as DetectionSystem sonobuoy)
func _compute_passive_snr(buoy: Dictionary, target: Dictionary) -> float:
	var dist_nm: float = buoy["position"].distance_to(target["position"])

	# Source Level
	var base_noise_db: float = target["platform"].get("noise_db_cruise", 120.0)
	var speed_ratio: float = target["speed_kts"] / maxf(target["max_speed_kts"], 1.0)
	var sl_db: float = base_noise_db + 20.0 * log(maxf(speed_ratio, 0.01)) / log(10.0)
	if target["speed_kts"] < 1.0:
		sl_db = base_noise_db - 30.0

	# Transmission Loss
	var range_m: float = dist_nm * 1852.0
	var alpha: float = 0.0002
	var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0

	# Thermal layer penalty: buoys float on the surface
	var thermal_depth: float = _world.environment.get("thermal_layer_depth_m", 75.0)
	var thermal_strength: float = _world.environment.get("thermal_layer_strength", 0.8)
	var tgt_depth: float = absf(target["depth_m"])
	if tgt_depth > thermal_depth:
		tl_db += 15.0 + 5.0 * thermal_strength

	# Noise Level
	var nl_db: float = 40.0 + 3.0 * _world.weather_sea_state + _sea_state_noise_modifier(_world.weather_sea_state)

	# Detection Threshold
	var dt_db: float = buoy["sensitivity_db"]

	# SNR = SL - TL - NL - DT (passive, no target strength, no array gain)
	var snr: float = sl_db - tl_db - nl_db - dt_db

	# Difficulty scaling
	var det_mult: float = _world.difficulty.get("detection_mult", 1.0)
	if det_mult > 0.0 and det_mult != 1.0:
		snr += 10.0 * log(det_mult) / log(10.0)

	return snr

## Compute active SNR for a DICASS sonobuoy
func _compute_active_snr(buoy: Dictionary, target: Dictionary, dist_nm: float) -> float:
	# Active sonar: SNR = SL - 2*TL + TS - NL - DT
	var sl_db: float = 215.0  # DICASS source level (lower than ship-mounted)
	var range_m: float = dist_nm * 1852.0
	var alpha: float = 0.0002
	var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0

	# Target Strength
	var ts_db: float = target["platform"].get("target_strength_db", 15.0)

	# Thermal layer penalty (buoy on surface, target may be deep)
	var thermal_depth: float = _world.environment.get("thermal_layer_depth_m", 75.0)
	var thermal_strength: float = _world.environment.get("thermal_layer_strength", 0.8)
	var tgt_depth: float = absf(target["depth_m"])
	if tgt_depth > thermal_depth:
		tl_db += 15.0 + 5.0 * thermal_strength

	# Noise Level + active reverb
	var nl_db: float = 40.0 + 3.0 * _world.weather_sea_state + _sea_state_active_modifier(_world.weather_sea_state)

	var dt_db: float = buoy["sensitivity_db"]

	# SNR = SL - 2*TL + TS - NL - DT (no array gain for sonobuoy)
	var snr: float = sl_db - 2.0 * tl_db + ts_db - nl_db - dt_db

	# Difficulty scaling
	var det_mult: float = _world.difficulty.get("detection_mult", 1.0)
	if det_mult > 0.0 and det_mult != 1.0:
		snr += 10.0 * log(det_mult) / log(10.0)

	return snr

# ---------------------------------------------------------------------------
# Bearing computation
# ---------------------------------------------------------------------------
func _compute_bearing(from_pos: Vector2, to_pos: Vector2) -> float:
	var bearing: float = rad_to_deg(atan2(
		to_pos.x - from_pos.x,
		to_pos.y - from_pos.y
	))
	if bearing < 0.0:
		bearing += 360.0
	return bearing

# ---------------------------------------------------------------------------
# Weather helpers (mirrored from DetectionSystem for standalone use)
# ---------------------------------------------------------------------------
func _sea_state_noise_modifier(ss: int) -> float:
	match ss:
		1: return -6.0
		2: return -3.0
		3: return 0.0
		4: return 3.0
		5: return 8.0
		6: return 14.0
		_: return 0.0

func _sea_state_active_modifier(ss: int) -> float:
	match ss:
		1: return -2.0
		2: return -1.0
		3: return 0.0
		4: return 1.0
		5: return 3.0
		6: return 5.0
		_: return 0.0

# ---------------------------------------------------------------------------
# Utility: get sonobuoy inventory summary for HUD display
# ---------------------------------------------------------------------------

## Returns a dictionary with inventory counts for a given aircraft unit.
func get_inventory(unit_id: String) -> Dictionary:
	if unit_id not in _world.units:
		return {"difar": 0, "dicass": 0, "total": 0}
	var u: Dictionary = _world.units[unit_id]
	return {
		"difar": u.get("sonobuoys_difar", 0),
		"dicass": u.get("sonobuoys_dicass", 0),
		"total": u.get("sonobuoys_remaining", 0),
	}

## Returns an array of active buoy status dicts for display.
## Each: {id, position, buoy_type, age_seconds, battery_remaining_pct, contact_count}
func get_active_buoys(faction: String = "player") -> Array:
	var result: Array = []
	for buoy_id in _world.sonobuoys:
		var buoy: Dictionary = _world.sonobuoys[buoy_id]
		if buoy["faction"] != faction:
			continue
		var age: float = _world.sim_time - buoy["deploy_time"]
		var battery_pct: float = clampf(1.0 - age / buoy["battery_life"], 0.0, 1.0)
		result.append({
			"id": buoy_id,
			"position": buoy["position"],
			"buoy_type": buoy.get("buoy_type", BuoyType.DIFAR),
			"age_seconds": age,
			"battery_remaining_pct": battery_pct,
			"contact_count": buoy.get("contacts", {}).size(),
		})
	return result

## Reset all sonobuoy state (called on scenario load).
func reset() -> void:
	# State is owned by SimulationWorld.sonobuoys dict -- just clear our RNG seed
	_rng.randomize()
