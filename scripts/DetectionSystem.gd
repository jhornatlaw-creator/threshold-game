extends RefCounted
## DetectionSystem -- Sensor sweeps, detection state, contact management,
## classification, SOSUS, sonobuoys, weather effects.
##
## Extracted from SimulationWorld. Operates on world state dictionaries.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

# ---------------------------------------------------------------------------
# Main detection tick -- called once per sim tick
# ---------------------------------------------------------------------------
func update_detections() -> void:
	for detector_id in _world.units:
		var detector: Dictionary = _world.units[detector_id]
		if not detector["is_alive"]:
			continue

		if detector_id not in _world.contacts:
			_world.contacts[detector_id] = {}

		for target_id in _world.units:
			if target_id == detector_id:
				continue
			var target: Dictionary = _world.units[target_id]
			if not target["is_alive"]:
				continue

			var detection: Dictionary = _compute_detection(detector, target)
			var prev_detected: bool = target_id in _world.contacts[detector_id]

			if detection["detected"]:
				detection["_stale_ticks"] = 0  # Reset grace period on re-acquisition

				# Phase 10: feed detection into ROE classification system
				if _world.get("_roe_system"):
					_world._roe_system.process_detection_for_classification(
						target_id, detection.get("method", ""),
						detection.get("confidence", 0.0), detector_id)

				# Feed bearing-only contacts into TMASystem for proper solution tracking
				if detection.get("bearing_only", false):
					_world._tma_system.feed_bearing(
						detector_id, target_id,
						detection["bearing"],
						detector["position"],
						detector["heading"],
						detector["speed_kts"]
					)
					# Inject TMA solution data into detection dict for HUD/RenderBridge
					var tma_data: Dictionary = _world._tma_system.get_contact_data(detector_id, target_id)
					if not tma_data.is_empty():
						detection["tma_quality"] = tma_data.get("solution_quality", 0.0)
						detection["tma_state"] = tma_data.get("solution_state", 0)
						detection["tma_estimated_position"] = tma_data.get("estimated_position", Vector2.ZERO)
						detection["tma_uncertainty_radius"] = tma_data.get("uncertainty_radius", 100.0)
						detection["tma_estimated_range"] = tma_data.get("estimated_range", 0.0)
						detection["tma_legs"] = tma_data.get("legs_count", 0)
						detection["tma_time_on_track"] = tma_data.get("time_on_track", 0.0)
						# Once TMA quality > 0.5, provide range estimate to downstream systems
						if tma_data.get("solution_quality", 0.0) >= 0.5 and tma_data.get("estimated_range", 0.0) > 0.0:
							detection["range_est"] = tma_data["estimated_range"]
						# Once TMA quality > 0.7, mark as no longer bearing-only
						if tma_data.get("solution_quality", 0.0) >= 0.7:
							detection["bearing_only"] = false
							detection["range_est"] = tma_data.get("estimated_range", 0.0)

				_world.contacts[detector_id][target_id] = detection
				detector["contacts"][target_id] = detection

				if not prev_detected:
					_world.unit_detected.emit(detector_id, target_id, detection)
				# Classification update
				if detection.get("confidence", 0.0) > 0.5:
					_world.contact_classified.emit(detector_id, target_id, detection)
			else:
				if prev_detected:
					# Contact persistence: hold for grace period before dropping.
					# Prevents per-tick detection flicker from breaking maintain_contact.
					var stale_ticks: int = _world.contacts[detector_id][target_id].get("_stale_ticks", 0) + 1
					if stale_ticks >= 10:  # 10 seconds grace before contact loss
						_world.contacts[detector_id].erase(target_id)
						detector["contacts"].erase(target_id)
						_world.detection_lost.emit(detector_id, target_id)
						# Notify TMA system of contact loss
						_world._tma_system.contact_lost(detector_id, target_id)
					else:
						_world.contacts[detector_id][target_id]["_stale_ticks"] = stale_ticks

	# SOSUS barrier detection (passive environmental sensor)
	_update_sosus_detections()

# ---------------------------------------------------------------------------
# Sonobuoy detection processing -- runs each tick for all active buoys
# ---------------------------------------------------------------------------
func process_sonobuoy_detections() -> void:
	var expired: Array = []

	for buoy_id in _world.sonobuoys:
		var buoy: Dictionary = _world.sonobuoys[buoy_id]

		# Battery check
		var age: float = _world.sim_time - buoy["deploy_time"]
		if age > buoy["battery_life"]:
			expired.append(buoy_id)
			continue

		# Determine enemy faction relative to this buoy's faction
		var enemy_faction: String = "enemy" if buoy["faction"] == "player" else "player"

		for uid in _world.units:
			var target: Dictionary = _world.units[uid]
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
			# below the thermal layer incur the full cross-layer penalty.
			# XBT mechanic: player buoys use estimated depth until XBT reveals actual.
			var thermal_depth: float = _world.get_thermal_depth_for_faction(buoy["faction"])
			var thermal_strength_b: float = _world.environment.get("thermal_layer_strength", 0.8)
			var tgt_depth: float = absf(target["depth_m"])
			if tgt_depth > thermal_depth:
				tl_db += 15.0 + 5.0 * thermal_strength_b

			# Convergence zone (uses bottom_depth_m for proper deep-water check)
			var bottom_depth_b: float = _world.environment.get("bottom_depth_m", _world.environment.get("water_depth_m", 200.0))
			if bottom_depth_b >= 3600.0:
				var cz_interval: float = 33.0
				var cz_width: float = 3.0
				for cz_idx in range(1, 3):
					var cz_center: float = cz_interval * float(cz_idx)
					var cz_dist_b: float = absf(dist_nm - cz_center)
					if cz_dist_b < cz_width and dist_nm > 20.0:
						tl_db -= 15.0
						break

			# --- Noise Level (same formula as _sonar_detection_passive) ---
			var nl_db: float = 40.0 + 3.0 * _world.weather_sea_state + _sea_state_noise_modifier(_world.weather_sea_state)

			# --- Detection Threshold (buoy sensitivity, no array gain -- single omnidirectional hydrophone) ---
			var dt_db: float = buoy["sensitivity_db"]

			# SNR = SL - TL - NL - DT  (passive, no target strength, no array gain)
			var snr: float = sl_db - tl_db - nl_db - dt_db

			# Difficulty scaling (same as _sonar_detection_passive)
			var det_mult: float = _world.difficulty.get("detection_mult", 1.0)
			if det_mult > 0.0 and det_mult != 1.0:
				snr += 10.0 * log(det_mult) / log(10.0)

			if snr > 0.0 and _world.tick_count % 10 == 0:  # Throttle: emit every 10 ticks
				var bearing: float = rad_to_deg(atan2(
					target["position"].x - buoy["position"].x,
					target["position"].y - buoy["position"].y
				))
				if bearing < 0.0:
					bearing += 360.0
				_world.sonobuoy_contact.emit(buoy_id, uid, bearing, snr)

	# Remove expired buoys after iteration
	for buoy_id in expired:
		_world.sonobuoy_expired.emit(buoy_id)
		_world.sonobuoys.erase(buoy_id)

# ---------------------------------------------------------------------------
# Core detection computation
# ---------------------------------------------------------------------------
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
			best_result["detected"] = p_sonar > 0.1
			best_result["bearing_only"] = true
			best_result["sonar_data"] = sonar_result
			# CZ detection: provides bearing with +/- 5 deg uncertainty and rough range band
			if sonar_result.get("is_cz", false):
				best_result["method"] = "sonar_cz"
				best_result["bearing"] += _rng.randf_range(-5.0, 5.0)
				best_result["bearing"] = fmod(best_result["bearing"] + 360.0, 360.0)
				# CZ range band: 30-36nm for first CZ, 60-70nm for second CZ
				var cz_center: float = sonar_result.get("cz_range_band_nm", 33.0)
				if cz_center < 50.0:
					best_result["range_est"] = cz_center + _rng.randf_range(-3.0, 3.0)
				else:
					best_result["range_est"] = cz_center + _rng.randf_range(-5.0, 5.0)
				best_result["cz_detection"] = true
				best_result["cz_range_band"] = cz_center
			else:
				best_result["method"] = "sonar_passive"
				best_result["range_est"] = 0.0  # Passive sonar: bearing only, no range

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
	# Phase 5: skip inline ESM if ESMSystem is handling it
	var _esm_handled: bool = _world.get("_esm_system") != null
	# ESM works if detector has ESM and target is emitting radar
	# Submarines need periscope depth (depth_m > -20) for ESM
	var detector_has_esm: bool = detector["platform"].get("has_esm", false) or detector["platform"].get("has_ecm", false)
	if not _esm_handled and detector_has_esm and target.get("emitting_radar", false):
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
	# Phase 5: skip inline counter-detection if CounterDetectionSystem is handling it
	var _cd_handled: bool = _world.get("_counter_detection_system") != null
	if not _cd_handled and target.get("emitting_sonar_active", false):
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
					# XBT mechanic: use faction-appropriate thermal depth
					var thermal_depth: float = _world.get_thermal_depth_for_faction(detector["faction"])
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
	var radar_horizon_nm: float = 1.23 * (sqrt(maxf(antenna_height_ft, 0.0)) + sqrt(maxf(target_height_ft, 0.0)))
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
	var clutter_factor: float = 1.0 - _world.SEA_STATE_RADAR_CLUTTER.get(_world.weather_sea_state, 0.2)
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
	var towed_penalty_db: float = 0.0
	for sensor in detector["sensors"]:
		if sensor.get("type", "") == "sonar":
			# Dipping sonar only works when helicopter is hovering (speed < 5 kts)
			if sensor.get("subtype", "") == "dipping" and detector.get("speed_kts", 0.0) >= 5.0:
				continue
			# Towed array degrades above 14 kts (own-ship noise drowns the array)
			if sensor.get("subtype", "") == "towed_array":
				var spd: float = detector.get("speed_kts", 0.0)
				if spd > 20.0:
					continue  # Completely ineffective above 20 kts
				elif spd > 14.0:
					towed_penalty_db = (spd - 14.0) * 3.0  # -3 dB per knot over 14
				# Towed array forward blind zone: ~30-degree cone ahead of the towing ship.
				# The array trails behind, so contacts directly ahead are in the blind zone.
				var to_target: Vector2 = target["position"] - detector["position"]
				var bearing_to_target: float = rad_to_deg(atan2(to_target.x, to_target.y))
				if bearing_to_target < 0:
					bearing_to_target += 360.0
				var detector_heading: float = detector.get("heading", 0.0)
				var angle_off_bow_ta: float = absf(fmod(bearing_to_target - detector_heading + 540.0, 360.0) - 180.0)
				if angle_off_bow_ta < 15.0:
					continue  # Inside 30-degree forward blind cone (15 deg each side)
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

	# Transmission Loss: TL = 15*log10(range_m) + alpha*range_m/1000
	# (cylindrical/spherical hybrid spreading + absorption)
	var range_m: float = range_nm * 1852.0
	var alpha: float = 0.0002  # dB per meter (mid-frequency, ~0.2 dB/km at 3.5 kHz)
	var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0

	# Target Strength (TS) -- not used in passive, set to 0
	var ts_db: float = 0.0

	# Noise Level at detector: ambient baseline (linear) + Wenz-curve modifier (non-linear)
	# weather_sea_state is authoritative -- synced with environment.sea_state on every update
	var ambient_noise: float = 40.0 + 3.0 * _world.weather_sea_state
	var nl_db: float = ambient_noise + _sea_state_noise_modifier(_world.weather_sea_state)

	# Thermal layer: cross-layer detection penalty depends on sensor type.
	# Hull-mounted sonar CANNOT detect below the thermal layer (massive penalty).
	# Towed array goes deep -- it bypasses the thermal layer.
	# Dipping sonar is lowered below the layer -- it bypasses too.
	# XBT mechanic: player uses estimated depth until XBT reveals actual.
	var thermal_depth: float = _world.get_thermal_depth_for_faction(detector["faction"])
	var thermal_strength: float = _world.environment.get("thermal_layer_strength", 0.8)
	var det_depth: float = absf(detector["depth_m"])
	var tgt_depth: float = absf(target["depth_m"])
	var cross_layer: bool = (det_depth < thermal_depth and tgt_depth > thermal_depth) or \
		(det_depth > thermal_depth and tgt_depth < thermal_depth)
	var sensor_subtype: String = best_sonar.get("subtype", "")
	if cross_layer:
		if sensor_subtype == "towed_array" or sensor_subtype == "dipping":
			# Towed array and dipping sonar operate below the layer -- minimal penalty
			tl_db += 3.0  # Small residual loss for non-ideal geometry
		elif sensor_subtype == "submarine_suite" or sensor_subtype == "submarine_bow" or sensor_subtype == "bow_array":
			# Submarine sonars: moderate penalty (sub can change depth to match)
			tl_db += 8.0 * thermal_strength
		else:
			# Hull-mounted sonar (SQS-53, SQS-56): full cross-layer penalty
			# Stronger thermal layer = worse detection. At strength 1.0, +20dB loss.
			tl_db += 15.0 + 5.0 * thermal_strength

	# Convergence zone: in deep water (bottom > 3600m / 12000ft), sound refocuses
	# at ~33nm intervals. CZ detection is weaker (0.3x base) and provides bearing
	# with uncertainty and a rough range band, not a precise range.
	var bottom_depth: float = _world.environment.get("bottom_depth_m", _world.environment.get("water_depth_m", 200.0))
	var is_cz_detection: bool = false
	var cz_range_band_nm: float = 0.0  # Rough range band center for CZ detections
	if bottom_depth >= 3600.0:  # CZ only forms in deep water (>12000 ft)
		var cz_interval: float = 33.0  # nautical miles between convergence zones
		var cz_width: float = 3.0  # width of CZ ring in NM
		# Check first CZ (~33nm) and second CZ (~66nm)
		for cz_index in range(1, 3):
			var cz_center: float = cz_interval * float(cz_index)
			var cz_dist: float = absf(range_nm - cz_center)
			if cz_dist < cz_width and range_nm > 20.0:
				# In CZ: reduce TL significantly (refocused energy)
				tl_db -= 15.0
				is_cz_detection = true
				cz_range_band_nm = cz_center
				break

	# Detection Threshold from sensor
	var dt_db: float = best_sonar.get("detection_threshold_db", 10.0)

	# SNR = SL - TL + TS - NL - DT
	var snr: float = sl_db - tl_db + ts_db - nl_db - dt_db

	# Detector gain (array gain)
	var array_gain: float = best_sonar.get("array_gain_db", 20.0)
	snr += array_gain

	# Towed array speed penalty (own-ship noise at high speed)
	if towed_penalty_db > 0.0 and sensor_subtype == "towed_array":
		snr -= towed_penalty_db

	# CZ detections are weaker: multiply effective SNR by 0.3
	if is_cz_detection:
		snr *= 0.3

	# Item 16: difficulty scaling -- detection_mult adjusts SNR in dB
	var det_mult: float = _world.difficulty.get("detection_mult", 1.0)
	if det_mult > 0.0 and det_mult != 1.0:
		snr += 10.0 * log(det_mult) / log(10.0)

	return {
		"snr_db": snr,
		"sl_db": sl_db,
		"tl_db": tl_db,
		"nl_db": nl_db,
		"dt_db": dt_db,
		"sensor": best_sonar.get("id", "unknown"),
		"is_cz": is_cz_detection,
		"cz_range_band_nm": cz_range_band_nm,
		"sensor_subtype": sensor_subtype,
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
	var nl_db: float = 40.0 + 3.0 * _world.weather_sea_state + _sea_state_active_sonar_modifier(_world.weather_sea_state)

	# Thermal layer penalty (active sonar -- two-way, so penalty is doubled for cross-layer)
	# XBT mechanic: player uses estimated depth until XBT reveals actual.
	var thermal_depth: float = _world.get_thermal_depth_for_faction(detector["faction"])
	var thermal_strength: float = _world.environment.get("thermal_layer_strength", 0.8)
	var det_depth: float = absf(detector["depth_m"])
	var tgt_depth: float = absf(target["depth_m"])
	var active_sensor_subtype: String = best_sonar.get("subtype", "")
	if (det_depth < thermal_depth and tgt_depth > thermal_depth) or \
		(det_depth > thermal_depth and tgt_depth < thermal_depth):
		if active_sensor_subtype == "dipping":
			tl_db += 3.0  # Dipping sonar goes below layer
		elif active_sensor_subtype in ["submarine_suite", "submarine_bow", "bow_array"]:
			tl_db += 8.0 * thermal_strength
		else:
			# Hull-mounted active sonar: full cross-layer penalty
			tl_db += 15.0 + 5.0 * thermal_strength

	var dt_db: float = best_sonar.get("detection_threshold_db", 10.0)
	var array_gain: float = best_sonar.get("array_gain_db", 20.0)

	# SNR = SL - 2*TL + TS - NL - DT + ArrayGain
	var snr: float = sl_db - 2.0 * tl_db + ts_db - nl_db - dt_db + array_gain

	# Item 16: difficulty scaling -- detection_mult adjusts SNR in dB
	var det_mult_a: float = _world.difficulty.get("detection_mult", 1.0)
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
	for barrier in _world.sosus_barriers:
		for target_id in _world.units:
			var target: Dictionary = _world.units[target_id]
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
				if _world.tick_count % 30 == 0:
					_world.sosus_contact.emit(barrier["id"], bearing, confidence)

func _closest_point_on_line(a: Vector2, b: Vector2, p: Vector2) -> Vector2:
	var ab: Vector2 = b - a
	if ab.dot(ab) < 0.0001:
		return a  # Zero-length line guard
	var t: float = clampf((p - a).dot(ab) / ab.dot(ab), 0.0, 1.0)
	return a + ab * t

# ---------------------------------------------------------------------------
# SNR to probability conversion
# ---------------------------------------------------------------------------
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
	match _world.weather_type:
		"clear": mult = 1.0
		"overcast": mult = 0.95
		"rain": mult = 0.7   # Rain clutter significant
		"storm": mult = 0.4  # Severe clutter, radar nearly useless
	# Sea state clutter (affects surface radar)
	if _world.weather_sea_state >= 5:
		mult *= 0.8
	if _world.weather_sea_state >= 6:
		mult *= 0.7
	return maxf(mult, 0.05)  # Floor to prevent zero effective range

## Checks for gradual weather shifts every 30 minutes of sim time.
## 30% cumulative chance per interval that sea state shifts +/-1.
## Emits weather_changed signal if conditions change.
const WEATHER_CHECK_INTERVAL: float = 1800.0  # 30 minutes sim time

func maybe_update_weather(sim_time_now: float) -> void:
	if sim_time_now - _world._last_weather_check_time < WEATHER_CHECK_INTERVAL:
		return
	_world._last_weather_check_time = sim_time_now
	# 30% chance of sea state shift (15% up, 15% down)
	var roll: float = _rng.randf()  # Use seeded RNG, not global randf()
	if roll < 0.15:
		_world.weather_sea_state = mini(_world.weather_sea_state + 1, 6)
	elif roll < 0.30:
		_world.weather_sea_state = maxi(_world.weather_sea_state - 1, 1)
	else:
		return  # No change
	# Sync environment dict so all systems use same sea state
	_world.environment["sea_state"] = _world.weather_sea_state
	_world.weather_wind_kts = _sea_state_to_wind(_world.weather_sea_state)
	_world.weather_visibility_nm = _weather_to_visibility(_world.weather_type, _world.weather_sea_state)
	_world.weather_changed.emit(_world.weather_sea_state, _world.weather_type, _world.weather_visibility_nm)

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
		"DD", "DDG", "FFG", "CGN":
			prefix = "SIERRA"  # Surface contact
		"SSN":
			prefix = "GOBLIN" if target["depth_m"] < -5.0 else "SIERRA"
		"HELO", "MPA":
			prefix = "BOGEY"  # Air contact
		_:
			prefix = "SIERRA"

	# N-4: use incrementing counter to avoid designator collisions
	if target["id"] not in _world._unit_designators:
		_world._unit_designators[target["id"]] = "%s-%02d" % [prefix, _world._next_designator]
		_world._next_designator += 1
	result["designator"] = _world._unit_designators[target["id"]]

	# Classification improves with confidence
	if confidence > 0.8:
		result["type"] = platform_type
		result["class"] = target["platform"].get("class_name", "Unknown Class")
	elif confidence > 0.5:
		match platform_type:
			"DD", "DDG", "FFG", "CGN":
				result["type"] = "SURFACE"
			"SSN":
				result["type"] = "SUBSURFACE" if target["depth_m"] < -5.0 else "SURFACE"
			"HELO", "MPA":
				result["type"] = "AIR"
	# Below 0.5: stays UNKNOWN

	return result
