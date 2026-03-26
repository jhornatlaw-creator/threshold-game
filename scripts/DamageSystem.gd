extends RefCounted
## DamageSystem -- Damage application, hit resolution (Pk model), sinking,
## unit destruction.
##
## Phase 8: effective_Pk = base_Pk * solution_quality * weapon_factors * cm_factor
## Solution quality linkage: TMA quality directly affects hit probability.
## Wire guidance bonus: +0.15 Pk while on wire.
## ASROC splash-down penalty. Wake-homing countermeasure factor.
##
## Extracted from SimulationWorld. Operates on world state dictionaries.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton
var _rng := RandomNumberGenerator.new()

func initialize(world: Node) -> void:
	_world = world
	_rng.randomize()

# ---------------------------------------------------------------------------
# Weapon Pk model -- LEGACY (kept for backward compatibility / non-Phase 8 paths)
# ---------------------------------------------------------------------------
func compute_weapon_hit(w: Dictionary, target: Dictionary) -> bool:
	# Delegate to Phase 8 model with neutral extra factors
	return compute_weapon_hit_phase8(w, target, 1.0, 1.0, 1.0)

# ---------------------------------------------------------------------------
# Phase 8 Pk model: effective_Pk = base_Pk * solution_quality * weapon_factors * cm
# ---------------------------------------------------------------------------
func compute_weapon_hit_phase8(w: Dictionary, target: Dictionary,
		asroc_factor: float, cm_factor: float, wake_factor: float) -> bool:
	var wdata: Dictionary = w["data"]
	var base_pk: float = wdata.get("pk_base", 0.7)
	var max_range: float = maxf(wdata.get("max_range_nm", 50.0), 0.01)

	# -- Solution quality (from TMA or sensor data, stored at fire time) --
	var solution_quality: float = w.get("solution_quality", 1.0)

	# -- Range factor: Pk degrades at long range (M-7: use launch position, not current) --
	var launch_pos: Vector2 = w.get("launch_position", w["position"])
	var launch_range: float = launch_pos.distance_to(target["position"])
	var range_ratio: float = launch_range / max_range
	var range_factor: float = clampf(1.0 - 0.5 * pow(range_ratio, 2.0), 0.3, 1.0)

	# -- Platform countermeasures factor (CIWS, chaff -- from platform data) --
	var cm_source: Dictionary = target.get("override_countermeasures", target["platform"])
	var platform_cm_factor: float = 1.0
	if cm_source.get("has_ciws", false):
		# Supersonic missiles (high_dive profile) reduce CIWS effectiveness
		var ciws_mult: float = wdata.get("ciws_effectiveness_mult", 1.0)
		platform_cm_factor *= 0.6 * ciws_mult if ciws_mult < 1.0 else 0.6
	if cm_source.get("has_chaff", false) and wdata.get("guidance", "") == "radar":
		platform_cm_factor *= 0.7  # Chaff vs radar-guided

	# -- Flight profile bonus (supersonic high-dive missiles are harder to defend) --
	var profile_bonus: float = wdata.get("pk_profile_bonus", 0.0)

	# -- Speed factor for torpedoes (faster targets harder to hit) --
	var speed_factor: float = 1.0
	if wdata.get("type", "") == "torpedo":
		var target_speed: float = target["speed_kts"]
		if target_speed > 20.0:
			speed_factor = clampf(1.0 - (target_speed - 20.0) / 40.0, 0.4, 1.0)

	# -- Sea state factor (rough seas degrade torpedo acquisition) --
	var sea_state_factor: float = 1.0
	var sea_state: int = _world.weather_sea_state
	if wdata.get("type", "") == "torpedo" and sea_state >= 5:
		# High sea state adds noise that degrades torpedo sonar
		sea_state_factor = clampf(1.0 - (sea_state - 4) * 0.08, 0.7, 1.0)

	# -- Wire guidance bonus (+0.15 if weapon is still on wire) --
	var wire_bonus: float = 0.0
	if w.get("on_wire", false):
		wire_bonus = 0.15

	# -- Depth factor: deep targets are harder for lightweight torpedoes --
	var depth_factor: float = 1.0
	if wdata.get("type", "") == "torpedo":
		var target_depth: float = absf(target["depth_m"])
		var max_depth: float = wdata.get("max_depth_m", 400.0)
		if target_depth > max_depth * 0.8:
			depth_factor = clampf(1.0 - (target_depth - max_depth * 0.8) / (max_depth * 0.2), 0.3, 1.0)

	# -- Combine all factors --
	# effective_Pk = (base_Pk + profile_bonus + wire_bonus) * solution_quality
	#                * range_factor * platform_cm_factor * speed_factor
	#                * sea_state_factor * depth_factor * asroc_factor
	#                * cm_factor (from WeaponSystem countermeasures)
	#                * wake_factor (wake-homing countermeasure)
	var adjusted_base: float = clampf(base_pk + profile_bonus + wire_bonus, 0.0, 0.95)
	var final_pk: float = adjusted_base * solution_quality * range_factor \
		* platform_cm_factor * speed_factor * sea_state_factor * depth_factor \
		* asroc_factor * cm_factor * wake_factor

	# Item 16: difficulty scaling -- player Pk multiplier
	var shooter_id: String = w.get("shooter_id", "")
	if shooter_id in _world.units and _world.units[shooter_id]["faction"] == "player":
		final_pk *= _world.difficulty.get("player_pk_mult", 1.0)
	final_pk = clampf(final_pk, 0.0, 0.95)

	var roll: float = _rng.randf()
	return roll <= final_pk

func compute_weapon_damage(w: Dictionary, target: Dictionary) -> float:
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
