extends RefCounted
## WeaponSystem -- Firing solutions, torpedo/missile lifecycle, weapon movement,
## wire guidance, solution quality linkage, countermeasures.
##
## Phase 8: effective_Pk = base_Pk * solution_quality * weapon_factors * cm_factor
## Wire guidance mechanic for Mk48 Mod 4. Kill confirmation delay.
## NIXIE towed decoy and noisemaker countermeasures.
##
## Extracted from SimulationWorld. Operates on world state dictionaries.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

## Pending kill confirmations: weapon_id -> {target_id, hit_time, confirm_time, actual_hit}
var _pending_confirmations: Dictionary = {}

## Active wire connections: weapon_id -> {shooter_id, wire_length_nm, broken}
var _active_wires: Dictionary = {}

## Active countermeasures per unit: unit_id -> {nixie_deployed, noisemakers_remaining, noisemakers_active_until}
var _unit_countermeasures: Dictionary = {}

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

## Safe emit: only emit Phase 8 signals if they exist on SimulationWorld.
## This prevents crashes before the integration plan is applied.
func _safe_emit(signal_name: String, args: Array) -> void:
	if _world.has_signal(signal_name):
		match args.size():
			0: _world.emit_signal(signal_name)
			1: _world.emit_signal(signal_name, args[0])
			2: _world.emit_signal(signal_name, args[0], args[1])
			3: _world.emit_signal(signal_name, args[0], args[1], args[2])

# ---------------------------------------------------------------------------
# Countermeasure management
# ---------------------------------------------------------------------------

## Initialize countermeasures for a unit based on platform capabilities.
func _ensure_countermeasures(unit_id: String) -> Dictionary:
	if unit_id in _unit_countermeasures:
		return _unit_countermeasures[unit_id]
	var u: Dictionary = _world.units.get(unit_id, {})
	var platform: Dictionary = u.get("platform", {})
	var cm := {
		"nixie_deployed": false,
		"noisemakers_remaining": 0,
		"noisemakers_active_until": 0.0,
	}
	# Submarines get noisemakers, surface ships get NIXIE
	if platform.get("type", "") == "SSN":
		cm["noisemakers_remaining"] = 8
	if platform.get("has_decoy", false) and platform.get("type", "") != "SSN":
		# Surface ships with decoy = NIXIE-capable
		cm["nixie_deployed"] = false
	_unit_countermeasures[unit_id] = cm
	return cm

## Deploy NIXIE towed torpedo decoy (surface ships).
## Returns true if deployed successfully.
func deploy_nixie(unit_id: String) -> bool:
	if unit_id not in _world.units:
		return false
	var u: Dictionary = _world.units[unit_id]
	if not u["is_alive"] or u["platform"].get("type", "") == "SSN":
		return false
	if not u["platform"].get("has_decoy", false):
		return false
	var cm: Dictionary = _ensure_countermeasures(unit_id)
	cm["nixie_deployed"] = true
	_safe_emit("countermeasure_deployed", [unit_id, "nixie"])
	return true

## Recover NIXIE (stop towing).
func recover_nixie(unit_id: String) -> void:
	if unit_id in _unit_countermeasures:
		_unit_countermeasures[unit_id]["nixie_deployed"] = false
		_safe_emit("countermeasure_recovered", [unit_id, "nixie"])

## Launch a noisemaker (submarines).
## Returns true if launched successfully.
func launch_noisemaker(unit_id: String) -> bool:
	if unit_id not in _world.units:
		return false
	var u: Dictionary = _world.units[unit_id]
	if not u["is_alive"] or u["platform"].get("type", "") != "SSN":
		return false
	var cm: Dictionary = _ensure_countermeasures(unit_id)
	if cm["noisemakers_remaining"] <= 0:
		return false
	cm["noisemakers_remaining"] -= 1
	# Noisemaker is effective for 60 seconds (1 minute game time)
	cm["noisemakers_active_until"] = _world.sim_time + 60.0
	_safe_emit("countermeasure_deployed", [unit_id, "noisemaker"])
	return true

## Check if NIXIE is deployed on a unit.
func is_nixie_deployed(unit_id: String) -> bool:
	if unit_id in _unit_countermeasures:
		return _unit_countermeasures[unit_id].get("nixie_deployed", false)
	return false

## Check if a noisemaker is currently active on a unit.
func is_noisemaker_active(unit_id: String) -> bool:
	if unit_id in _unit_countermeasures:
		return _world.sim_time < _unit_countermeasures[unit_id].get("noisemakers_active_until", 0.0)
	return false

# ---------------------------------------------------------------------------
# Wire guidance
# ---------------------------------------------------------------------------

## Cut wire on a weapon manually (player decision).
func cut_wire(weapon_id: String) -> void:
	if weapon_id in _active_wires:
		_active_wires[weapon_id]["broken"] = true
		_safe_emit("wire_cut", [weapon_id])

## Check if a unit is constrained by an active wire (speed/turn limits).
func is_unit_on_wire(unit_id: String) -> bool:
	for wid in _active_wires:
		var wire: Dictionary = _active_wires[wid]
		if wire["shooter_id"] == unit_id and not wire["broken"]:
			return true
	return false

## Get wire constraints for a unit (max_speed_kts, max_turn_deg).
## Returns empty dict if unit is not on wire.
func get_wire_constraints(unit_id: String) -> Dictionary:
	for wid in _active_wires:
		var wire: Dictionary = _active_wires[wid]
		if wire["shooter_id"] == unit_id and not wire["broken"]:
			return {"max_speed_kts": 10.0, "max_turn_deg": 30.0}
	return {}

# ---------------------------------------------------------------------------
# Solution quality for a target (reads from TMA or detection method)
# ---------------------------------------------------------------------------

## Get the effective solution quality for a target from the shooter's perspective.
## Passive contacts: use TMA quality (0.0-1.0).
## Active sonar / radar contacts: 0.95 (good but not perfect).
func _get_solution_quality(shooter_id: String, target_id: String) -> float:
	# Check if shooter has a detection on this target
	var detections: Dictionary = _world.contacts.get(shooter_id, {})
	if target_id not in detections:
		# No detection -- firing blind (should not happen in normal flow)
		return 0.1

	var detection: Dictionary = detections[target_id]
	var method: String = detection.get("method", "none")

	# Active sonar or radar: provides good range data, solution quality is high
	if method == "sonar_active" or method == "radar":
		return 0.95

	# Passive sonar: use TMA quality
	if detection.get("bearing_only", false) or method == "sonar_passive" or method == "sonar_cz" or method == "esm":
		var tma_quality: float = detection.get("tma_quality", 0.0)
		# CZ detection gives rough range, so bump quality slightly
		if method == "sonar_cz" and tma_quality < 0.5:
			tma_quality = maxf(tma_quality, 0.4)
		return tma_quality

	# Fallback: if we have range data, it's a decent solution
	if detection.get("range_est", 0.0) > 0.0:
		return 0.85

	return 0.3

# ---------------------------------------------------------------------------
# Weapon firing
# ---------------------------------------------------------------------------
func fire_weapon(shooter_id: String, target_id: String, weapon_type_id: String) -> String:
	if _world._game_over:
		return ""

	# Phase 10: ROE enforcement via ROESystem (replaces legacy maintain_contact check)
	if shooter_id in _world.units and _world.units[shooter_id]["faction"] == "player":
		# Legacy maintain_contact fallback (still triggers defeat on any player fire)
		var victory_type: String = _world.scenario.get("victory_condition", {}).get("type", "")
		if victory_type == "maintain_contact":
			_world._game_over = true
			_world.scenario_ended.emit("defeat")
			_world.is_paused = true
			return ""

		# ROE check via ROESystem
		if _world.has_method("get_roe_system"):
			var roe_system = _world.get_roe_system()
			if roe_system:
				var auth: Dictionary = roe_system.check_fire_authorization(shooter_id, target_id)
				if not auth.get("authorized", true):
					_safe_emit("roe_blocked", [shooter_id, target_id, auth.get("reason", "")])
					return ""

	if shooter_id not in _world.units or target_id not in _world.units:
		return ""

	var shooter: Dictionary = _world.units[shooter_id]
	var target: Dictionary = _world.units[target_id]

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

	# Wire constraint: cannot fire another wire-guided weapon while on wire
	if wdata.get("wire_guided", false) and is_unit_on_wire(shooter_id):
		return ""

	# Decrement ammo
	wrec["count"] -= 1

	# Compute solution quality at time of firing (locked in)
	var solution_quality: float = _get_solution_quality(shooter_id, target_id)

	# Create weapon in flight
	_world._next_weapon_id += 1
	var wid: String = "WPN_%04d" % _world._next_weapon_id
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
		"max_flight_time": max_range / (maxf(wdata.get("speed_kts", 600.0), 0.001) * _world.KNOTS_TO_NM_PER_SEC),
		"resolved": false,
		"solution_quality": solution_quality,
		"wire_guided": wdata.get("wire_guided", false),
		"on_wire": wdata.get("wire_guided", false),  # Starts on wire if wire-guided
	}
	_world.weapons_in_flight[wid] = weapon_instance

	# Set up wire guidance if applicable
	if wdata.get("wire_guided", false):
		var wire_length: float = wdata.get("wire_length_nm", 20.0)
		_active_wires[wid] = {
			"shooter_id": shooter_id,
			"wire_length_nm": wire_length,
			"broken": false,
		}

	_world.weapon_fired.emit(wid, shooter_id, target_id, wdata)

	# Emit torpedo run audio signal (Phase 9 handles actual audio)
	if wdata.get("type", "") == "torpedo":
		_safe_emit("torpedo_launched", [wid, shooter_id])

	return wid

# ---------------------------------------------------------------------------
# Weapon movement -- called once per sim tick
# ---------------------------------------------------------------------------
func move_weapons() -> void:
	for wid in _world.weapons_in_flight:
		var w: Dictionary = _world.weapons_in_flight[wid]
		if w["resolved"]:
			continue

		var target_id: String = w["target_id"]
		if target_id not in _world.units or not _world.units[target_id]["is_alive"]:
			w["resolved"] = true  # B-1: mark resolved BEFORE emitting
			_world.weapon_resolved.emit(wid, target_id, false, 0.0)  # Miss feedback for target-gone
			_world.weapon_removed.emit(wid)
			_cleanup_wire(wid)
			continue

		var target_pos: Vector2 = _world.units[target_id]["position"]
		var old_pos: Vector2 = w["position"]
		var to_target: Vector2 = target_pos - old_pos
		var dist_nm: float = to_target.length()

		var move_dist: float = w["speed_kts"] * _world.KNOTS_TO_NM_PER_SEC * (1.0 / _world.BASE_TICK_HZ)

		if dist_nm <= move_dist:
			# Weapon arrives at target -- resolve
			w["position"] = target_pos
			_world.weapon_moved.emit(wid, old_pos, target_pos)
		else:
			# Move toward target
			w["position"] = old_pos + to_target.normalized() * move_dist
			_world.weapon_moved.emit(wid, old_pos, w["position"])

		w["time_of_flight"] += 1.0 / _world.BASE_TICK_HZ

		# Wire guidance: check wire integrity
		if w.get("on_wire", false):
			_update_wire_state(wid, w)

		# Timeout
		if w["time_of_flight"] > w["max_flight_time"]:
			w["resolved"] = true  # B-1: mark resolved BEFORE emitting
			# Fix 7: emit weapon_resolved (miss) on timeout so player sees feedback
			_world.weapon_resolved.emit(wid, w["target_id"], false, 0.0)
			_world.weapon_removed.emit(wid)
			_cleanup_wire(wid)

## Update wire state: check if wire should break due to shooter maneuvers or range.
func _update_wire_state(wid: String, w: Dictionary) -> void:
	if wid not in _active_wires:
		w["on_wire"] = false
		return
	var wire: Dictionary = _active_wires[wid]
	if wire["broken"]:
		w["on_wire"] = false
		return

	var shooter_id: String = w["shooter_id"]
	if shooter_id not in _world.units:
		wire["broken"] = true
		w["on_wire"] = false
		return

	var shooter: Dictionary = _world.units[shooter_id]

	# Wire breaks if: range to weapon exceeds wire length
	var dist_to_weapon: float = shooter["position"].distance_to(w["position"])
	if dist_to_weapon > wire["wire_length_nm"]:
		wire["broken"] = true
		w["on_wire"] = false
		_safe_emit("wire_cut", [wid])
		return

	# Wire breaks if: shooter exceeds speed limit (10 kts)
	if shooter["speed_kts"] > 10.0:
		wire["broken"] = true
		w["on_wire"] = false
		_safe_emit("wire_cut", [wid])
		return

	# Wire breaks checked in MovementSystem for turn limit (>30 deg) -- would need
	# integration plan. For now, check via heading change over last few ticks.
	# This is a simplified check: if shooter is moving fast enough to matter,
	# the speed check above will catch most wire-breaking maneuvers.

	# While on wire: solution quality improves (weapon gets updated target data)
	# This is applied during resolution via the wire_guided Pk bonus.

func _cleanup_wire(wid: String) -> void:
	_active_wires.erase(wid)

# ---------------------------------------------------------------------------
# Weapon resolution -- called once per sim tick after movement
# ---------------------------------------------------------------------------
func resolve_weapons(damage_system) -> void:
	var to_remove := []
	for wid in _world.weapons_in_flight:
		var w: Dictionary = _world.weapons_in_flight[wid]
		if w["resolved"]:
			to_remove.append(wid)
			continue

		var target_id: String = w["target_id"]
		if target_id not in _world.units:
			w["resolved"] = true
			to_remove.append(wid)
			_cleanup_wire(wid)
			continue

		var target: Dictionary = _world.units[target_id]
		# Skip already-dead targets (two weapons arriving same tick)
		if not target["is_alive"]:
			w["resolved"] = true
			to_remove.append(wid)
			_world.weapon_resolved.emit(wid, target_id, false, 0.0)
			_cleanup_wire(wid)
			continue

		var dist: float = w["position"].distance_to(target["position"])

		# Close enough to resolve
		if dist < 0.5:  # Within 0.5 NM
			# ASROC splash-down warning: target gets brief warning reducing Pk
			var asroc_factor: float = 1.0
			if w["data"].get("guidance", "") == "rocket_acoustic":
				# Splash-down gives target time to maneuver
				asroc_factor = 1.0 - (w["data"].get("splash_warning_seconds", 0.0) / 100.0)
				asroc_factor = clampf(asroc_factor, 0.7, 1.0)

			# Countermeasure factor for target
			var cm_factor: float = _compute_countermeasure_factor(w, target_id, target)

			# Wake-homing countermeasure: speed/course change reduces Pk
			var wake_factor: float = _compute_wake_homing_factor(w, target)

			var hit: bool = damage_system.compute_weapon_hit_phase8(
				w, target, asroc_factor, cm_factor, wake_factor
			)
			var damage: float = 0.0
			if hit:
				damage = damage_system.compute_weapon_damage(w, target)
				target["damage"] = minf(target["damage"] + damage, 1.0)

			# Emit weapon_impact signal (audio event -- Phase 9)
			_safe_emit("weapon_impact", [wid, target_id, hit])

			if hit and target["damage"] >= 1.0:
				# Do NOT immediately destroy -- schedule kill confirmation
				_schedule_kill_confirmation(wid, target_id, true)
			elif hit:
				# Hit but not killed -- schedule damage confirmation
				_schedule_kill_confirmation(wid, target_id, false)

			_world.weapon_resolved.emit(wid, target_id, hit, damage)
			w["resolved"] = true
			to_remove.append(wid)
			_cleanup_wire(wid)

	for wid in to_remove:
		_world.weapons_in_flight.erase(wid)

	# Process pending kill confirmations
	_process_kill_confirmations()

# ---------------------------------------------------------------------------
# Kill confirmation delay -- no instant feedback
# ---------------------------------------------------------------------------

func _schedule_kill_confirmation(weapon_id: String, target_id: String, is_kill: bool) -> void:
	# Delay 20-30 game-minutes (1200-1800 sim seconds) before confirming kill
	var delay: float = _rng.randf_range(1200.0, 1800.0)
	_pending_confirmations[weapon_id] = {
		"target_id": target_id,
		"hit_time": _world.sim_time,
		"confirm_time": _world.sim_time + delay,
		"is_kill": is_kill,
		"confirmed": false,
	}
	# If this is a kill, mark the target as PROBABLE KILL instead of DESTROYED
	if is_kill and target_id in _world.units:
		_world.units[target_id]["kill_status"] = "probable"
		# Do NOT call destroy_unit yet -- wait for confirmation

func _process_kill_confirmations() -> void:
	var confirmed_weapons: Array = []
	for weapon_id in _pending_confirmations:
		var conf: Dictionary = _pending_confirmations[weapon_id]
		if conf["confirmed"]:
			confirmed_weapons.append(weapon_id)
			continue
		if _world.sim_time >= conf["confirm_time"]:
			conf["confirmed"] = true
			var target_id: String = conf["target_id"]
			if conf["is_kill"] and target_id in _world.units:
				# NOW confirm the kill
				_world.units[target_id]["kill_status"] = "confirmed"
				_world.destroy_unit(target_id)
				_safe_emit("kill_confirmed", [target_id])
			elif not conf["is_kill"]:
				# Damage confirmed but not a kill
				_safe_emit("kill_confirmed", [target_id])
			confirmed_weapons.append(weapon_id)

	for wid in confirmed_weapons:
		_pending_confirmations.erase(wid)

## Get kill status for a target: "none", "probable", "confirmed"
func get_kill_status(target_id: String) -> String:
	if target_id in _world.units:
		return _world.units[target_id].get("kill_status", "none")
	return "none"

# ---------------------------------------------------------------------------
# Countermeasure effectiveness computation
# ---------------------------------------------------------------------------

## Compute countermeasure factor for an incoming weapon against a target.
func _compute_countermeasure_factor(w: Dictionary, target_id: String, target: Dictionary) -> float:
	var factor: float = 1.0
	var wdata: Dictionary = w["data"]
	var weapon_type: String = wdata.get("type", "")
	var guidance: String = wdata.get("guidance", "")

	# NIXIE towed torpedo decoy (surface ships vs incoming torpedoes)
	if weapon_type == "torpedo" and is_nixie_deployed(target_id):
		# 30-50% chance torpedo acquires decoy instead
		var nixie_effectiveness: float = _rng.randf_range(0.30, 0.50)
		factor *= (1.0 - nixie_effectiveness)

	# Noisemaker (submarines vs incoming torpedoes)
	if weapon_type == "torpedo" and is_noisemaker_active(target_id):
		# Effective if target also changed course (simulated by random factor)
		var noisemaker_effectiveness: float = _rng.randf_range(0.20, 0.40)
		factor *= (1.0 - noisemaker_effectiveness)

	# Soviet countermeasures: slightly lower effectiveness (25-40%)
	var shooter_id: String = w.get("shooter_id", "")
	if target_id in _world.units and _world.units[target_id]["faction"] == "enemy":
		# AI auto-deploys countermeasures when torpedo detected
		if weapon_type == "torpedo":
			var soviet_cm_chance: float = _rng.randf_range(0.25, 0.40)
			# Only apply if target platform has decoy capability
			if target.get("platform", {}).get("has_decoy", false):
				factor *= (1.0 - soviet_cm_chance)

	return clampf(factor, 0.2, 1.0)

## Compute wake-homing torpedo countermeasure factor.
## Player can counter Type 65 wake-homer by slowing/turning.
func _compute_wake_homing_factor(w: Dictionary, target: Dictionary) -> float:
	var wdata: Dictionary = w["data"]
	if wdata.get("guidance", "") != "wake_homing":
		return 1.0  # Not a wake-homing torpedo, no effect

	# If target speed < 5 kts: wake-homer effectiveness drops 60%
	if target["speed_kts"] < 5.0:
		return 0.4

	# If target speed < 10 kts: partial reduction
	if target["speed_kts"] < 10.0:
		return 0.6

	# Full speed: wake-homer at full effectiveness
	return 1.0

# ---------------------------------------------------------------------------
# Weapon validity check (used by AI)
# ---------------------------------------------------------------------------
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

## Get best weapon range for a unit (used by AI for standoff distance).
func get_best_weapon_range(u: Dictionary) -> float:
	var best: float = 10.0
	for weapon_id in u["weapons_remaining"]:
		var wrec: Dictionary = u["weapons_remaining"][weapon_id]
		if wrec["count"] > 0:
			var r: float = wrec["data"].get("max_range_nm", 10.0)
			if r > best:
				best = r
	return best

# ---------------------------------------------------------------------------
# AI countermeasure auto-deployment
# ---------------------------------------------------------------------------

## Called by AI behavior when an incoming weapon is detected targeting this unit.
## AI automatically deploys countermeasures.
func ai_auto_deploy_countermeasures(unit_id: String) -> void:
	if unit_id not in _world.units:
		return
	var u: Dictionary = _world.units[unit_id]
	var cm: Dictionary = _ensure_countermeasures(unit_id)

	if u["platform"].get("type", "") == "SSN":
		# Submarine: launch noisemaker if available
		if cm["noisemakers_remaining"] > 0 and not is_noisemaker_active(unit_id):
			launch_noisemaker(unit_id)
	else:
		# Surface ship: deploy NIXIE if not already deployed
		if not cm["nixie_deployed"] and u["platform"].get("has_decoy", false):
			deploy_nixie(unit_id)

# ---------------------------------------------------------------------------
# State queries for HUD/RenderBridge
# ---------------------------------------------------------------------------

## Get all active wire connections (for HUD display).
func get_active_wires() -> Dictionary:
	var result: Dictionary = {}
	for wid in _active_wires:
		if not _active_wires[wid]["broken"]:
			result[wid] = _active_wires[wid].duplicate()
	return result

## Get countermeasure state for a unit (for HUD display).
func get_countermeasure_state(unit_id: String) -> Dictionary:
	if unit_id in _unit_countermeasures:
		return _unit_countermeasures[unit_id].duplicate()
	return {}

## Reset state on scenario load.
func reset() -> void:
	_pending_confirmations.clear()
	_active_wires.clear()
	_unit_countermeasures.clear()
