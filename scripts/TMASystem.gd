extends RefCounted
## TMASystem -- Target Motion Analysis subsystem.
##
## Tracks bearing-only contacts over time to estimate range and position.
## Uses bearing rate, ownship maneuvers, and geometry to build a solution.
##
## State machine per contact: NO_CONTACT -> DETECTING -> TRACKING -> SOLUTION
## Solution quality regresses if target maneuvers (unexpected bearing rate change).
##
## Kerrigan-corrected formula:
##   geometry * 0.35 + bearing_spread * 0.30 + time_score * 0.20 + leg_bonus * 0.15
##   all multiplied by ownship speed penalty (flow noise degrades sonar).
##
## Extracted from SimulationWorld. Operates on world state dictionaries.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

## Per-contact TMA tracking data.
## Key: "detector_id:target_id" -> TMAContact dictionary
var tma_contacts: Dictionary = {}

## TMAContact solution states
enum SolutionState {
	NO_CONTACT = 0,
	DETECTING = 1,
	TRACKING = 2,
	SOLUTION = 3,
}

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

## Reset all TMA state (call on scenario load).
func reset() -> void:
	tma_contacts.clear()

# ---------------------------------------------------------------------------
# Public API -- called by DetectionSystem when a passive bearing arrives
# ---------------------------------------------------------------------------

## Feed a new bearing observation into the TMA tracker.
## Called each tick that a passive sonar contact is held.
func feed_bearing(detector_id: String, target_id: String, bearing_deg: float,
		ownship_pos: Vector2, ownship_heading: float, ownship_speed_kts: float) -> void:
	var key: String = _contact_key(detector_id, target_id)
	var now: float = _world.sim_time

	if key not in tma_contacts:
		# First bearing -- create contact in DETECTING state
		var contact := _create_contact(detector_id, target_id)
		tma_contacts[key] = contact
		_world.tma_contact_created.emit(target_id, bearing_deg)

	var contact: Dictionary = tma_contacts[key]
	var prev_state: int = contact["solution_state"]

	# Record bearing observation
	var obs := {
		"bearing": bearing_deg,
		"timestamp": now,
		"ownship_pos": Vector2(ownship_pos),
		"ownship_heading": ownship_heading,
	}

	var history: Array = contact["bearing_history"]

	# Update running bearing spread: add delta from new observation
	if not history.is_empty():
		var delta: float = absf(_bearing_delta(history[-1]["bearing"], bearing_deg))
		contact["_bearing_spread_running"] += delta

	history.append(obs)

	# Cap bearing history to last 1800 observations (30 min at 1Hz)
	if history.size() > 1800:
		# Subtract the delta contributed by the popped observation
		if history.size() >= 2:
			var popped_delta: float = absf(_bearing_delta(history[0]["bearing"], history[1]["bearing"]))
			contact["_bearing_spread_running"] -= popped_delta
			# Guard against negative drift from float imprecision
			if contact["_bearing_spread_running"] < 0.0:
				contact["_bearing_spread_running"] = 0.0
		history.pop_front()

	# Update time on track
	if history.size() >= 2:
		contact["time_on_track"] = now - history[0]["timestamp"]
	else:
		contact["time_on_track"] = 0.0

	# Sync total bearing spread from running total
	contact["total_bearing_spread"] = contact["_bearing_spread_running"]

	# Detect course legs (distinct bearing rate changes)
	_update_legs(contact)

	# Check for target maneuver (bearing rate change) -- regress solution if detected
	_check_target_maneuver(contact, target_id)

	# Compute solution quality (Kerrigan formula)
	var old_quality: float = contact["solution_quality"]
	_compute_solution_quality(contact, ownship_speed_kts)

	# State machine transitions
	_update_state(contact, prev_state, target_id)

	# Estimate position when quality is sufficient
	_estimate_position(contact, detector_id, target_id)

	# Emit solution update signal
	_world.tma_solution_updated.emit(
		target_id,
		contact["solution_quality"],
		contact["estimated_position"],
		contact["uncertainty_radius"]
	)

## Called when a target goes below the thermal layer, degrading hull sonar tracking.
## TMA quality regresses significantly because bearing data stops flowing from hull sonar.
## Towed array contacts are NOT affected (they can still see below the layer).
func target_went_deep(target_id: String) -> void:
	for key in tma_contacts:
		var contact: Dictionary = tma_contacts[key]
		if contact["target_id"] != target_id:
			continue
		var old_quality: float = contact["solution_quality"]
		# Regress quality by 40% -- going deep breaks most tracking geometry
		contact["solution_quality"] = maxf(0.0, contact["solution_quality"] * 0.6)
		# Widen uncertainty radius
		contact["uncertainty_radius"] = clampf(
			contact["uncertainty_radius"] * 2.0, 1.0, 100.0
		)
		# Regress state if quality dropped below thresholds
		if contact["solution_quality"] < 0.7 and contact["solution_state"] == SolutionState.SOLUTION:
			contact["solution_state"] = SolutionState.TRACKING
		if contact["solution_quality"] < 0.3 and contact["solution_state"] == SolutionState.TRACKING:
			contact["solution_state"] = SolutionState.DETECTING
		if contact["solution_quality"] < old_quality:
			_world.tma_solution_regressed.emit(target_id, old_quality, contact["solution_quality"])

## Remove ALL TMA contacts tracking a given unit (e.g., on unit destruction).
## Prevents ghost TMA contacts from persisting after the target is destroyed.
func remove_target(unit_id: String) -> void:
	var keys_to_erase: Array = []
	for key in tma_contacts:
		var contact: Dictionary = tma_contacts[key]
		if contact["target_id"] == unit_id:
			keys_to_erase.append(key)
	for key in keys_to_erase:
		tma_contacts.erase(key)
		_world.tma_contact_lost.emit(unit_id)

## Called when a passive contact is lost (no bearing for grace period).
func contact_lost(detector_id: String, target_id: String) -> void:
	var key: String = _contact_key(detector_id, target_id)
	if key in tma_contacts:
		tma_contacts.erase(key)
		_world.tma_contact_lost.emit(target_id)

## Get TMA data for a specific contact (used by HUD/RenderBridge via detection dict).
func get_contact_data(detector_id: String, target_id: String) -> Dictionary:
	var key: String = _contact_key(detector_id, target_id)
	if key in tma_contacts:
		return tma_contacts[key]
	return {}

## Get the best TMA data for a target across all detectors.
func get_best_contact(target_id: String) -> Dictionary:
	var best: Dictionary = {}
	var best_quality: float = -1.0
	for key in tma_contacts:
		var contact: Dictionary = tma_contacts[key]
		if contact["target_id"] == target_id and contact["solution_quality"] > best_quality:
			best_quality = contact["solution_quality"]
			best = contact
	return best

## Periodic cleanup -- call once per tick to prune stale contacts
func tick_cleanup() -> void:
	var to_remove: Array = []
	for key in tma_contacts:
		var contact: Dictionary = tma_contacts[key]
		# Remove contacts with no bearing update for 120 seconds
		if contact["bearing_history"].is_empty():
			to_remove.append(key)
			continue
		var last_obs: Dictionary = contact["bearing_history"][-1]
		if _world.sim_time - last_obs["timestamp"] > 120.0:
			to_remove.append(key)

	for key in to_remove:
		var contact: Dictionary = tma_contacts[key]
		_world.tma_contact_lost.emit(contact["target_id"])
		tma_contacts.erase(key)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

func _contact_key(detector_id: String, target_id: String) -> String:
	return detector_id + ":" + target_id

func _create_contact(detector_id: String, target_id: String) -> Dictionary:
	return {
		"detector_id": detector_id,
		"target_id": target_id,
		"bearing_history": [],
		"solution_state": SolutionState.DETECTING,
		"solution_quality": 0.0,
		"estimated_range": 0.0,
		"estimated_position": Vector2.ZERO,
		"uncertainty_radius": 100.0,  # NM -- starts very wide
		"legs_count": 0,
		"total_bearing_spread": 0.0,
		"_bearing_spread_running": 0.0,  # Running total for O(1) spread updates
		"time_on_track": 0.0,
		"_last_bearing_rate": 0.0,
		"_leg_change_timestamps": [],
		"_maneuver_detected_time": 0.0,
	}

## _update_bearing_spread is now O(1) via running total maintained inline in feed_bearing().
## The running total (_bearing_spread_running) is incremented on append and decremented on pop.
## This replaces the old O(n) full-history scan that iterated up to 1800 entries per tick.

func _update_legs(contact: Dictionary) -> void:
	## Detect distinct course legs by finding sustained bearing rate changes.
	## A "leg" is a period of roughly constant bearing rate.
	## A rate change > 0.3 deg/sec sustained for 30+ seconds counts as a new leg.
	var history: Array = contact["bearing_history"]
	if history.size() < 60:
		# Need at least 60 seconds of data to detect legs
		contact["legs_count"] = 0
		return

	# Compute bearing rate in 30-second windows
	var window: int = 30
	var rates: Array = []
	var i: int = window
	while i < history.size():
		var dt: float = history[i]["timestamp"] - history[i - window]["timestamp"]
		if dt < 1.0:
			i += 1
			continue
		var db: float = _bearing_delta(history[i - window]["bearing"], history[i]["bearing"])
		rates.append(db / dt)
		i += window

	if rates.size() < 2:
		contact["legs_count"] = 1 if history.size() > 30 else 0
		return

	# Count significant rate changes
	var legs: int = 1
	for j in range(1, rates.size()):
		var rate_change: float = absf(rates[j] - rates[j - 1])
		if rate_change > 0.01:  # ~0.6 deg/min threshold for a meaningful change
			legs += 1

	contact["legs_count"] = legs

func _check_target_maneuver(contact: Dictionary, target_id: String) -> void:
	## If bearing rate changes abruptly, the target may have maneuvered.
	## This regresses the TMA solution (target is no longer where we thought).
	var history: Array = contact["bearing_history"]
	if history.size() < 20:
		return

	# Explicit index calculation to avoid negative array index issues
	var idx_last: int = history.size() - 1
	var idx10: int = history.size() - 10
	var idx20: int = history.size() - 20
	if idx10 < 0 or idx20 < 0:
		return

	# Current bearing rate (last 10 seconds)
	var recent_dt: float = history[idx_last]["timestamp"] - history[idx10]["timestamp"]
	if recent_dt < 1.0:
		return
	var recent_rate: float = _bearing_delta(history[idx10]["bearing"], history[idx_last]["bearing"]) / recent_dt

	# Previous bearing rate (10-20 seconds ago)
	var prev_dt: float = history[idx10]["timestamp"] - history[idx20]["timestamp"]
	if prev_dt < 1.0:
		return
	var prev_rate: float = _bearing_delta(history[idx20]["bearing"], history[idx10]["bearing"]) / prev_dt

	var rate_change: float = absf(recent_rate - prev_rate)

	# Significant rate change = potential target maneuver
	if rate_change > 0.03:  # ~1.8 deg/min -- meaningful course change
		var old_quality: float = contact["solution_quality"]
		# Regress quality by 20-40% depending on magnitude of change
		var regression: float = clampf(rate_change * 5.0, 0.2, 0.4)
		contact["solution_quality"] = maxf(0.0, contact["solution_quality"] - regression)
		contact["_maneuver_detected_time"] = _world.sim_time

		# Increase uncertainty radius
		contact["uncertainty_radius"] = clampf(
			contact["uncertainty_radius"] * 1.5,
			1.0, 100.0
		)

		if contact["solution_quality"] < old_quality:
			_world.tma_solution_regressed.emit(target_id, old_quality, contact["solution_quality"])

		# If quality drops below thresholds, regress state
		if contact["solution_quality"] < 0.7 and contact["solution_state"] == SolutionState.SOLUTION:
			contact["solution_state"] = SolutionState.TRACKING
		elif contact["solution_quality"] < 0.3 and contact["solution_state"] == SolutionState.TRACKING:
			contact["solution_state"] = SolutionState.DETECTING

func _compute_solution_quality(contact: Dictionary, ownship_speed_kts: float) -> void:
	## Kerrigan-corrected TMA quality formula.
	var history: Array = contact["bearing_history"]
	if history.size() < 2:
		contact["solution_quality"] = 0.0
		return

	# 1. Geometry: sin(angle_off_bow)^1.5 -- craters near bow/stern
	var latest_bearing: float = history[-1]["bearing"]
	var ownship_heading: float = history[-1]["ownship_heading"]
	var angle_off_bow: float = absf(_bearing_delta(ownship_heading, latest_bearing))
	# Normalize to 0-180 (angle off bow is symmetric)
	if angle_off_bow > 180.0:
		angle_off_bow = 360.0 - angle_off_bow
	var geometry: float = pow(sin(deg_to_rad(angle_off_bow)), 1.5)

	# 2. Bearing spread score: total bearing change / 15 degrees
	var bearing_spread_score: float = clampf(contact["total_bearing_spread"] / 15.0, 0.0, 1.0)

	# 3. Time score: seconds tracked / 1200 (20 min = 1.0)
	var time_score: float = clampf(contact["time_on_track"] / 1200.0, 0.0, 1.0)

	# 4. Leg bonus
	var legs: int = contact["legs_count"]
	var leg_bonus: float
	if legs < 2:
		leg_bonus = 0.0
	elif legs == 2:
		leg_bonus = 0.5
	elif legs == 3:
		leg_bonus = 0.8
	else:
		leg_bonus = 1.0

	# 5. Ownship speed penalty -- flow noise degrades sonar
	var speed_penalty: float = clampf(1.0 - (ownship_speed_kts / 25.0) * 0.5, 0.5, 1.0)

	# Combined quality
	var raw_quality: float = (
		geometry * 0.35
		+ bearing_spread_score * 0.30
		+ time_score * 0.20
		+ leg_bonus * 0.15
	) * speed_penalty

	# Quality only increases gradually (0.005 per tick max) to prevent jumps,
	# but can decrease rapidly on maneuver detection (handled in _check_target_maneuver)
	var max_increase: float = 0.005
	if raw_quality > contact["solution_quality"]:
		contact["solution_quality"] = minf(
			contact["solution_quality"] + max_increase,
			raw_quality
		)
	else:
		# Allow slow natural decay (bearing data aging)
		contact["solution_quality"] = lerpf(contact["solution_quality"], raw_quality, 0.01)

func _update_state(contact: Dictionary, prev_state: int, target_id: String) -> void:
	var quality: float = contact["solution_quality"]

	match prev_state:
		SolutionState.DETECTING:
			if quality > 0.2 and contact["time_on_track"] > 30.0:
				contact["solution_state"] = SolutionState.TRACKING
		SolutionState.TRACKING:
			if quality > 0.7:
				contact["solution_state"] = SolutionState.SOLUTION
			elif quality < 0.1 and contact["time_on_track"] < 10.0:
				contact["solution_state"] = SolutionState.DETECTING
		SolutionState.SOLUTION:
			if quality < 0.5:
				contact["solution_state"] = SolutionState.TRACKING

func _estimate_position(contact: Dictionary, detector_id: String, target_id: String) -> void:
	## Estimate target position based on bearing history and ownship movement.
	## Only valid when solution_quality > 0.5.
	var quality: float = contact["solution_quality"]
	var history: Array = contact["bearing_history"]

	if quality < 0.5 or history.size() < 10:
		# Not enough data for a position estimate
		contact["estimated_range"] = 0.0
		contact["estimated_position"] = Vector2.ZERO
		contact["uncertainty_radius"] = clampf(100.0 - quality * 80.0, 5.0, 100.0)
		return

	# Triangulation: use two bearing observations from different ownship positions
	# Pick observations separated in time for best geometry
	var obs_early: Dictionary = history[0]
	var obs_late: Dictionary = history[-1]

	# Ownship must have moved -- if it hasn't, triangulation is impossible
	var ownship_displacement: float = obs_early["ownship_pos"].distance_to(obs_late["ownship_pos"])
	if ownship_displacement < 0.5:
		# Not enough ownship movement for triangulation
		# Use current bearing + rough range estimate from bearing rate
		var range_est: float = _estimate_range_from_bearing_rate(contact)
		contact["estimated_range"] = range_est
		var latest_bearing_rad: float = deg_to_rad(history[-1]["bearing"])
		contact["estimated_position"] = history[-1]["ownship_pos"] + \
			Vector2(sin(latest_bearing_rad), -cos(latest_bearing_rad)) * range_est
		contact["uncertainty_radius"] = clampf(50.0 - quality * 40.0, 5.0, 50.0)
		return

	# Bearing intersection
	var p1: Vector2 = obs_early["ownship_pos"]
	var b1_rad: float = deg_to_rad(obs_early["bearing"])
	var d1: Vector2 = Vector2(sin(b1_rad), -cos(b1_rad))

	var p2: Vector2 = obs_late["ownship_pos"]
	var b2_rad: float = deg_to_rad(obs_late["bearing"])
	var d2: Vector2 = Vector2(sin(b2_rad), -cos(b2_rad))

	# Solve intersection of two rays: p1 + t*d1 = p2 + s*d2
	var cross: float = d1.x * d2.y - d1.y * d2.x
	if absf(cross) < 0.001:
		# Parallel bearings -- use bearing rate estimate instead
		var range_est: float = _estimate_range_from_bearing_rate(contact)
		contact["estimated_range"] = range_est
		var latest_bearing_rad: float = deg_to_rad(history[-1]["bearing"])
		contact["estimated_position"] = history[-1]["ownship_pos"] + \
			Vector2(sin(latest_bearing_rad), -cos(latest_bearing_rad)) * range_est
		contact["uncertainty_radius"] = clampf(40.0 - quality * 30.0, 5.0, 40.0)
		return

	var diff: Vector2 = p2 - p1
	var t: float = (diff.x * d2.y - diff.y * d2.x) / cross

	if t < 0.0:
		# Intersection is behind the observer -- invalid
		var range_est: float = _estimate_range_from_bearing_rate(contact)
		contact["estimated_range"] = range_est
		var latest_bearing_rad: float = deg_to_rad(history[-1]["bearing"])
		contact["estimated_position"] = history[-1]["ownship_pos"] + \
			Vector2(sin(latest_bearing_rad), -cos(latest_bearing_rad)) * range_est
		contact["uncertainty_radius"] = clampf(40.0 - quality * 30.0, 5.0, 40.0)
		return

	var estimated_pos: Vector2 = p1 + d1 * t
	var estimated_range: float = history[-1]["ownship_pos"].distance_to(estimated_pos)

	# Sanity check: reject absurd ranges (> 200 NM)
	if estimated_range > 200.0:
		estimated_range = clampf(estimated_range, 5.0, 200.0)
		var latest_bearing_rad: float = deg_to_rad(history[-1]["bearing"])
		estimated_pos = history[-1]["ownship_pos"] + \
			Vector2(sin(latest_bearing_rad), -cos(latest_bearing_rad)) * estimated_range

	# Add noise proportional to inverse quality
	var noise_factor: float = lerpf(0.3, 0.02, clampf((quality - 0.5) / 0.5, 0.0, 1.0))
	estimated_pos += Vector2(
		_rng.randf_range(-1.0, 1.0) * estimated_range * noise_factor,
		_rng.randf_range(-1.0, 1.0) * estimated_range * noise_factor
	)

	contact["estimated_range"] = estimated_range
	contact["estimated_position"] = estimated_pos

	# Uncertainty radius: shrinks with quality
	# quality 0.5 = ~30 NM radius, quality 0.7 = ~10 NM, quality 0.9 = ~2 NM, quality 1.0 = ~1 NM
	contact["uncertainty_radius"] = clampf(
		lerpf(30.0, 1.0, clampf((quality - 0.5) / 0.5, 0.0, 1.0)),
		1.0, 50.0
	)

func _estimate_range_from_bearing_rate(contact: Dictionary) -> float:
	## Rough range estimate from bearing rate when triangulation fails.
	## Higher bearing rate = closer target (at a given speed).
	var history: Array = contact["bearing_history"]
	if history.size() < 10:
		return 30.0  # Default guess

	var dt: float = history[-1]["timestamp"] - history[-10]["timestamp"]
	if dt < 1.0:
		return 30.0

	var db: float = absf(_bearing_delta(history[-10]["bearing"], history[-1]["bearing"]))
	var rate_deg_per_sec: float = db / dt

	if rate_deg_per_sec < 0.001:
		return 50.0  # Very slow rate = far away

	# Approximate: range ~ ownship_speed / bearing_rate (in radians/sec)
	# This is a very rough heuristic
	var rate_rad_per_sec: float = deg_to_rad(rate_deg_per_sec)
	var estimated_range: float = clampf(5.0 / rate_rad_per_sec, 5.0, 100.0)

	return estimated_range

func _bearing_delta(from_deg: float, to_deg: float) -> float:
	## Shortest angular difference between two bearings (-180 to +180).
	var delta: float = fmod(to_deg - from_deg + 540.0, 360.0) - 180.0
	return delta
