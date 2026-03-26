extends RefCounted
## CounterDetectionSystem -- Active sonar counter-detection and active sonar modes.
##
## When any unit goes active on sonar, every unit within counter-detection
## range gets a bearing on the emitter. The enemy ALWAYS hears your ping
## before you hear the return (one-way propagation is faster than round-trip).
##
## Two active sonar modes:
##   QUIET: short pulse, reduced range (50% of base), counter-detection at 1.5x
##   FULL_POWER: maximum range, counter-detection at 2.5x. Screams your position.
##
## Counter-detection range = active_detection_range * multiplier (mode-dependent).
##
## Standalone subsystem -- will be wired into SimulationWorld after Phase 4.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

## Active sonar modes
enum ActiveSonarMode {
	OFF = 0,
	QUIET = 1,       # Short pulse, 50% range, 1.5x counter-detection
	FULL_POWER = 2,  # Maximum range, 2.5x counter-detection
}

## Mode parameters
const MODE_PARAMS := {
	ActiveSonarMode.OFF: {
		"range_mult": 0.0,
		"counter_detect_mult": 0.0,
		"display_name": "OFF",
	},
	ActiveSonarMode.QUIET: {
		"range_mult": 0.5,
		"counter_detect_mult": 1.5,
		"display_name": "QUIET",
	},
	ActiveSonarMode.FULL_POWER: {
		"range_mult": 1.0,
		"counter_detect_mult": 2.5,
		"display_name": "FULL POWER",
	},
}

## Per-unit active sonar mode. Key: unit_id, Value: ActiveSonarMode int
var _unit_sonar_mode: Dictionary = {}

## Counter-detection events from the current tick.
## Array of {detector_id, emitter_id, bearing, timestamp}
## Polled/consumed each tick by the integration layer.
var pending_counter_detections: Array = []

## Cumulative counter-detection log for AI notification (Phase 6).
## Key: unit_id (the unit that was counter-detected upon).
## Value: Array of {emitter_id, bearing, timestamp}
var counter_detection_log: Dictionary = {}

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Set active sonar mode for a unit.
## Returns true if mode changed, false if already in that mode or unit unknown.
func set_active_sonar_mode(unit_id: String, mode: int) -> bool:
	if unit_id not in _world.units:
		return false

	var old_mode: int = _unit_sonar_mode.get(unit_id, ActiveSonarMode.OFF)
	if old_mode == mode:
		return false

	_unit_sonar_mode[unit_id] = mode

	# Update the unit's emitting_sonar_active flag
	var unit: Dictionary = _world.units[unit_id]
	if mode == ActiveSonarMode.OFF:
		unit["emitting_sonar_active"] = false
	else:
		unit["emitting_sonar_active"] = true

	# Store mode on unit dict for DetectionSystem to read
	unit["active_sonar_mode"] = mode

	return true

## Get the active sonar mode for a unit. Defaults to OFF.
func get_active_sonar_mode(unit_id: String) -> int:
	return _unit_sonar_mode.get(unit_id, ActiveSonarMode.OFF)

## Get the display name for a unit's active sonar mode.
func get_mode_display_name(unit_id: String) -> String:
	var mode: int = get_active_sonar_mode(unit_id)
	return MODE_PARAMS.get(mode, MODE_PARAMS[ActiveSonarMode.OFF])["display_name"]

## Get the range multiplier for a unit's current active sonar mode.
## DetectionSystem should multiply the sensor's max_range_nm_active by this.
func get_range_multiplier(unit_id: String) -> float:
	var mode: int = get_active_sonar_mode(unit_id)
	return MODE_PARAMS.get(mode, MODE_PARAMS[ActiveSonarMode.OFF])["range_mult"]

## Get the counter-detection range multiplier for a unit's current mode.
func get_counter_detection_multiplier(unit_id: String) -> float:
	var mode: int = get_active_sonar_mode(unit_id)
	return MODE_PARAMS.get(mode, MODE_PARAMS[ActiveSonarMode.OFF])["counter_detect_mult"]

## Initialize sonar mode for a newly spawned unit. All start OFF.
func init_unit_sonar(unit_id: String) -> void:
	_unit_sonar_mode[unit_id] = ActiveSonarMode.OFF
	if unit_id in _world.units:
		_world.units[unit_id]["active_sonar_mode"] = ActiveSonarMode.OFF

## Remove a unit from tracking (call on unit destruction).
func remove_unit(unit_id: String) -> void:
	_unit_sonar_mode.erase(unit_id)
	counter_detection_log.erase(unit_id)

## Clear all tracking (call on scenario load).
func reset() -> void:
	_unit_sonar_mode.clear()
	pending_counter_detections.clear()
	counter_detection_log.clear()

# ---------------------------------------------------------------------------
# Tick processing -- counter-detection sweep
# ---------------------------------------------------------------------------

## Main tick update. Call once per sim tick AFTER movement but BEFORE detection.
## This way, counter-detections from this tick's active pings arrive before
## the pinger gets their own return (enemy hears you first).
func process_counter_detections() -> void:
	pending_counter_detections.clear()

	for emitter_id in _world.units:
		var emitter: Dictionary = _world.units[emitter_id]
		if not emitter["is_alive"]:
			continue
		if not emitter.get("emitting_sonar_active", false):
			continue

		# Get emitter's active sonar mode and base range
		var mode: int = _unit_sonar_mode.get(emitter_id, ActiveSonarMode.FULL_POWER)
		if mode == ActiveSonarMode.OFF:
			continue  # Shouldn't happen if emitting_sonar_active is true, but guard

		var params: Dictionary = MODE_PARAMS.get(mode, MODE_PARAMS[ActiveSonarMode.FULL_POWER])
		var cd_mult: float = params["counter_detect_mult"]
		var range_mult: float = params["range_mult"]

		# Find best active sonar sensor on the emitter
		var best_active_range: float = 0.0
		for sensor in emitter.get("sensors", []):
			if sensor.get("type", "") == "sonar":
				var ar: float = sensor.get("max_range_nm_active", 0.0)
				if ar > best_active_range:
					best_active_range = ar

		if best_active_range <= 0.0:
			continue

		# Effective active sonar range for this mode
		var effective_active_range: float = best_active_range * range_mult

		# Counter-detection range: the range at which OTHER units can hear this ping
		var counter_detect_range: float = effective_active_range * cd_mult

		# Check every other unit to see if they can hear the ping
		for detector_id in _world.units:
			if detector_id == emitter_id:
				continue
			var detector: Dictionary = _world.units[detector_id]
			if not detector["is_alive"]:
				continue

			# Detector must have sonar capability (any sonar sensor) to intercept
			var has_sonar: bool = false
			for sensor in detector.get("sensors", []):
				if sensor.get("type", "") == "sonar":
					has_sonar = true
					break
			if not has_sonar:
				continue

			# Range check
			var dist_nm: float = emitter["position"].distance_to(detector["position"])
			if dist_nm > counter_detect_range:
				continue

			# Thermal layer attenuation: if emitter and detector are on opposite
			# sides of the thermal layer, counter-detection range is reduced
			# (but less than normal detection -- active ping is very loud)
			var thermal_depth: float = _world.environment.get("thermal_layer_depth_m", 75.0)
			var emitter_depth: float = absf(emitter["depth_m"])
			var detector_depth: float = absf(detector["depth_m"])
			var cross_layer: bool = (
				(emitter_depth < thermal_depth and detector_depth > thermal_depth) or
				(emitter_depth > thermal_depth and detector_depth < thermal_depth)
			)
			if cross_layer:
				# Reduce effective counter-detection range by 30% across thermal layer
				# (ping is loud enough to partially penetrate)
				var reduced_cd_range: float = counter_detect_range * 0.7
				if dist_nm > reduced_cd_range:
					continue

			# Counter-detection succeeds -- compute bearing from detector to emitter
			var to_emitter: Vector2 = emitter["position"] - detector["position"]
			var bearing: float = rad_to_deg(atan2(to_emitter.x, to_emitter.y))
			if bearing < 0.0:
				bearing += 360.0

			# Add bearing noise (counter-detection bearing is less precise than direct sonar)
			# +/- 3 degrees at close range, +/- 8 degrees at max range
			var range_ratio: float = dist_nm / counter_detect_range
			var noise_deg: float = lerpf(3.0, 8.0, range_ratio)
			bearing += _rng.randf_range(-noise_deg, noise_deg)
			bearing = fmod(bearing + 360.0, 360.0)

			var event := {
				"detector_id": detector_id,
				"emitter_id": emitter_id,
				"bearing": bearing,
				"timestamp": _world.sim_time,
				"distance_nm": dist_nm,
				"counter_detect_range": counter_detect_range,
			}

			pending_counter_detections.append(event)

			# Log for AI notification (Phase 6 evasion behavior)
			if detector_id not in counter_detection_log:
				counter_detection_log[detector_id] = []
			counter_detection_log[detector_id].append({
				"emitter_id": emitter_id,
				"bearing": bearing,
				"timestamp": _world.sim_time,
			})
			# Cap log per unit to last 50 events
			if counter_detection_log[detector_id].size() > 50:
				counter_detection_log[detector_id].pop_front()

			# Feed counter-detection bearing into TMA system for tracking
			# (the active pinger becomes a trackable contact)
			if _world.get("_tma_system") and _world._tma_system:
				_world._tma_system.feed_bearing(
					detector_id, emitter_id,
					bearing,
					detector["position"],
					detector["heading"],
					detector["speed_kts"]
				)

## Check if a unit has been counter-detected recently (within last N seconds).
## Used by AI to trigger evasion behavior in Phase 6.
func was_counter_detected(unit_id: String, lookback_seconds: float = 30.0) -> bool:
	if unit_id not in counter_detection_log:
		return false
	var events: Array = counter_detection_log[unit_id]
	if events.is_empty():
		return false
	var latest: Dictionary = events[-1]
	return (_world.sim_time - latest["timestamp"]) <= lookback_seconds

## Get the most recent counter-detection bearing for a unit (for AI evasion).
func get_latest_counter_detection(unit_id: String) -> Dictionary:
	if unit_id not in counter_detection_log:
		return {}
	var events: Array = counter_detection_log[unit_id]
	if events.is_empty():
		return {}
	return events[-1]
