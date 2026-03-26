extends RefCounted
## ESMSystem -- Electronic Support Measures (passive radar detection).
##
## Detects enemy radar emissions at 2-3x the radar's own detection range.
## One-way propagation (direct signal) vs round-trip (radar echo) means
## ESM always detects at greater range than the radar can see you.
##
## ESM provides:
##   - Bearing to emitter (NO range -- same ambiguity as passive sonar)
##   - Radar type classification (radar type = ship type, so instant ID)
##
## ESM only works if:
##   - Enemy is radiating (emitting_radar = true)
##   - Your ESM receiver is on (EMCON BRAVO or higher)
##   - Submarines: must be at periscope depth (depth_m > -20) for ESM mast
##
## ESM detections feed into TMASystem for bearing-over-time tracking
## (same as passive sonar bearings -- bearing only, no range).
##
## Standalone subsystem -- will be wired into SimulationWorld after Phase 4.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

## ESM detection range multiplier (how far ESM detects vs radar's own range).
## 2.5x is the midpoint of the 2-3x spec.
const ESM_RANGE_MULTIPLIER: float = 2.5

## ESM detections from the current tick.
## Array of {detector_id, emitter_id, bearing, radar_type, radar_name,
##           platform_type_hint, confidence, timestamp}
## Polled/consumed each tick by the integration layer.
var pending_esm_detections: Array = []

## Active ESM contacts per detector.
## Key: detector_id, Value: {emitter_id -> last_esm_detection_dict}
## Used for persistence -- ESM contacts don't flicker like radar detections.
var esm_contacts: Dictionary = {}

## Classified emitters -- once ESM identifies a radar type, it stays classified.
## Key: "detector_id:emitter_id", Value: classification dict
var _classified_emitters: Dictionary = {}

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Check if a unit has ESM capability AND is in a state to use it.
func can_use_esm(unit_id: String) -> bool:
	if unit_id not in _world.units:
		return false
	var unit: Dictionary = _world.units[unit_id]

	# Unit must have ESM or ECM capability (ECM implies ESM receiver)
	var platform: Dictionary = unit.get("platform", {})
	var has_esm: bool = platform.get("has_esm", false) or platform.get("has_ecm", false)
	if not has_esm:
		return false

	# Submarines must be at periscope depth for ESM mast
	if platform.get("type", "") == "SSN":
		if unit["depth_m"] < -20.0:
			return false

	# EMCON check: ESM receiver must be allowed in current EMCON state.
	# If EMCONSystem is available, query it. Otherwise, ESM is ON by default
	# (pre-integration fallback).
	var emcon_state: int = unit.get("emcon_state", 2)  # Default CHARLIE
	if emcon_state == 0:  # ALPHA -- ESM receiver off
		return false

	return true

## Get ESM contacts for a specific detector unit.
func get_esm_contacts(detector_id: String) -> Dictionary:
	return esm_contacts.get(detector_id, {})

## Get classification for a detected emitter.
func get_emitter_classification(detector_id: String, emitter_id: String) -> Dictionary:
	var key: String = detector_id + ":" + emitter_id
	return _classified_emitters.get(key, {})

## Clear all tracking (call on scenario load).
func reset() -> void:
	pending_esm_detections.clear()
	esm_contacts.clear()
	_classified_emitters.clear()

## Remove a unit from tracking (call on unit destruction).
func remove_unit(unit_id: String) -> void:
	esm_contacts.erase(unit_id)
	# Also remove this unit as an emitter from all other detector contacts
	for det_id in esm_contacts:
		esm_contacts[det_id].erase(unit_id)
	# Clean up classified emitters
	var keys_to_remove: Array = []
	for key in _classified_emitters:
		if key.begins_with(unit_id + ":") or key.ends_with(":" + unit_id):
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_classified_emitters.erase(key)

# ---------------------------------------------------------------------------
# Tick processing -- ESM detection sweep
# ---------------------------------------------------------------------------

## Main tick update. Call once per sim tick.
## Scans all units for radar emissions and checks if any ESM-equipped unit
## can detect them.
func process_esm_detections() -> void:
	pending_esm_detections.clear()

	# Build list of all units currently emitting radar
	var emitters: Array = []
	for uid in _world.units:
		var u: Dictionary = _world.units[uid]
		if u["is_alive"] and u.get("emitting_radar", false):
			emitters.append(uid)

	if emitters.is_empty():
		return

	# For each ESM-capable detector, check each emitter
	for detector_id in _world.units:
		var detector: Dictionary = _world.units[detector_id]
		if not detector["is_alive"]:
			continue
		if not can_use_esm(detector_id):
			# If ESM is off, clear any existing ESM contacts for this detector
			if detector_id in esm_contacts and not esm_contacts[detector_id].is_empty():
				esm_contacts[detector_id].clear()
			continue

		if detector_id not in esm_contacts:
			esm_contacts[detector_id] = {}

		for emitter_id in emitters:
			if emitter_id == detector_id:
				continue
			var emitter: Dictionary = _world.units[emitter_id]

			# Same faction check -- ESM detects ALL radar emitters regardless of faction,
			# but we only generate actionable contacts for enemy/neutral emitters.
			# (Friendly radar is recognized and filtered by IFF)
			if emitter["faction"] == detector["faction"]:
				continue

			# Get the best (longest-range) radar on the emitter
			var best_radar: Dictionary = {}
			for sensor in emitter.get("sensors", []):
				if sensor is Dictionary and sensor.get("type", "") == "radar":
					if best_radar.is_empty() or sensor.get("max_range_nm", 0.0) > best_radar.get("max_range_nm", 0.0):
						best_radar = sensor

			if best_radar.is_empty():
				continue

			var radar_max_range: float = best_radar.get("max_range_nm", 0.0)
			if radar_max_range <= 0.0:
				continue

			# ESM detection range = radar's own range * multiplier
			var esm_detect_range: float = radar_max_range * ESM_RANGE_MULTIPLIER

			# EMCON signature multiplier -- if emitter is in a reduced EMCON state,
			# ESM detection range is proportionally reduced. This handles EMCON BRAVO
			# (nav radar only) where the transmitted power is much lower.
			var emitter_emcon_state: int = emitter.get("emcon_state", 2)  # Default CHARLIE
			var signature_mult: float = 1.0
			match emitter_emcon_state:
				0:  # ALPHA -- no radar, shouldn't be emitting
					continue
				1:  # BRAVO -- nav radar only, very low power
					# Use nav radar range instead of best radar
					var nav_range: float = 0.0
					for sensor in emitter.get("sensors", []):
						if sensor is Dictionary and sensor.get("type", "") == "radar":
							if sensor.get("subtype", "") == "navigation":
								nav_range = sensor.get("max_range_nm", 0.0)
					if nav_range > 0.0:
						esm_detect_range = nav_range * ESM_RANGE_MULTIPLIER
					else:
						esm_detect_range *= 0.3  # Fallback: assume low power
					signature_mult = 0.3
				2:  # CHARLIE -- most active
					signature_mult = 0.8
				3:  # DELTA -- full power
					signature_mult = 1.0

			# Range check
			var dist_nm: float = detector["position"].distance_to(emitter["position"])
			if dist_nm > esm_detect_range:
				# Contact lost
				if emitter_id in esm_contacts[detector_id]:
					esm_contacts[detector_id].erase(emitter_id)
				continue

			# ESM detection probability -- very high at close range, degrades toward edge
			var range_ratio: float = dist_nm / esm_detect_range
			var p_detect: float
			if range_ratio < 0.7:
				p_detect = 0.95  # Near-certain within 70% of ESM range
			else:
				# Linear falloff from 0.95 to 0.3 between 70% and 100% of ESM range
				p_detect = lerpf(0.95, 0.3, (range_ratio - 0.7) / 0.3)

			# Roll against probability (but throttle -- only roll every 5 ticks
			# to prevent detection flickering)
			if _world.tick_count % 5 != 0 and emitter_id in esm_contacts[detector_id]:
				# Already have contact -- maintain it without re-rolling
				continue
			elif _world.tick_count % 5 != 0:
				continue

			if _rng.randf() > p_detect:
				continue

			# Detection succeeds -- compute bearing
			var to_emitter: Vector2 = emitter["position"] - detector["position"]
			var bearing: float = rad_to_deg(atan2(to_emitter.x, to_emitter.y))
			if bearing < 0.0:
				bearing += 360.0

			# Bearing noise: ESM bearing accuracy is moderate -- +/- 2 to 5 degrees
			var noise_deg: float = lerpf(2.0, 5.0, range_ratio)
			bearing += _rng.randf_range(-noise_deg, noise_deg)
			bearing = fmod(bearing + 360.0, 360.0)

			# Classify the radar type -- ESM provides instant radar identification
			var radar_type: String = best_radar.get("id", "unknown")
			var radar_name: String = best_radar.get("name", "Unknown Radar")
			var radar_subtype: String = best_radar.get("subtype", "")
			var platform_type: String = emitter.get("platform", {}).get("type", "")

			# Classification confidence -- radar type = ship type, so ESM is very
			# good at classification once it locks on
			var class_confidence: float = 0.0
			if range_ratio < 0.5:
				class_confidence = 0.9  # Very confident at close range
			elif range_ratio < 0.8:
				class_confidence = 0.7
			else:
				class_confidence = 0.4  # Can tell it's a radar, less sure what type

			# Build detection event
			var detection := {
				"detector_id": detector_id,
				"emitter_id": emitter_id,
				"bearing": bearing,
				"radar_type": radar_type,
				"radar_name": radar_name,
				"radar_subtype": radar_subtype,
				"platform_type_hint": platform_type if class_confidence > 0.6 else "UNKNOWN",
				"confidence": p_detect,
				"classification_confidence": class_confidence,
				"distance_nm": dist_nm,
				"esm_detect_range": esm_detect_range,
				"timestamp": _world.sim_time,
				"bearing_only": true,
				"method": "esm",
			}

			pending_esm_detections.append(detection)

			# Update persistent ESM contacts
			esm_contacts[detector_id][emitter_id] = detection

			# Store classification (persists even if contact is temporarily lost)
			var class_key: String = detector_id + ":" + emitter_id
			if class_confidence > _classified_emitters.get(class_key, {}).get("confidence", 0.0):
				_classified_emitters[class_key] = {
					"radar_type": radar_type,
					"radar_name": radar_name,
					"platform_type": platform_type,
					"confidence": class_confidence,
				}

			# Feed ESM bearing into TMA system for tracking
			if _world.get("_tma_system") and _world._tma_system:
				_world._tma_system.feed_bearing(
					detector_id, emitter_id,
					bearing,
					detector["position"],
					detector["heading"],
					detector["speed_kts"]
				)

	# Prune stale ESM contacts (emitter stopped radiating or moved out of range)
	for det_id in esm_contacts:
		var to_remove: Array = []
		for em_id in esm_contacts[det_id]:
			var contact: Dictionary = esm_contacts[det_id][em_id]
			# Stale if older than 30 seconds with no refresh
			if _world.sim_time - contact["timestamp"] > 30.0:
				to_remove.append(em_id)
		for em_id in to_remove:
			esm_contacts[det_id].erase(em_id)
