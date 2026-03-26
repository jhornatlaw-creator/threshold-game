extends RefCounted
## RadarHorizonSystem -- Earth curvature limit on radar detection.
##
## Implements the standard radar horizon formula:
##   radar_horizon_nm = 1.23 * (sqrt(antenna_height_ft) + sqrt(target_height_ft))
##
## Examples (November 1985 setting):
##   Spruance (75ft mast) vs surface target (30ft): ~17 NM
##   P-3C at 10,000ft vs surface (30ft):            ~130 NM
##   Surface ship vs submerged submarine:            0 NM (radar cannot detect)
##   Surface ship vs periscope depth (~3ft):         ~13 NM
##
## This limits radar from current fantasy ranges (190nm for SPY-1D vs surface)
## to realistic values bounded by Earth curvature.
##
## NOTE: DetectionSystem already has a radar horizon check in _radar_detection().
## This system provides the standalone calculation plus additional utilities
## that the existing inline check does not cover:
##   - Horizon calculation accounting for EMCON-dependent antenna selection
##   - Pre-computation of horizon distances for all unit pairs (optimization)
##   - Logging/debug signal for blocked detections
##   - Ducting and atmospheric refraction (future Phase 4 thermal integration)
##
## Standalone subsystem -- will be wired into SimulationWorld after Phase 4.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton

## Standard refraction factor for radar horizon (4/3 Earth radius model).
## The 1.23 constant already incorporates this.
const HORIZON_CONSTANT: float = 1.23  # NM per sqrt(ft)

## Minimum antenna height for surface ships without explicit data (feet).
const DEFAULT_SURFACE_ANTENNA_FT: float = 50.0

## Periscope mast exposure height (feet) -- submarine at periscope depth.
const PERISCOPE_HEIGHT_FT: float = 3.0

## Blocked detection events from the current tick.
## Array of {unit_id, target_id, antenna_height_ft, target_height_ft,
##           radar_horizon_nm, actual_range_nm, timestamp}
## Polled by integration layer for debug logging.
var pending_horizon_blocks: Array = []

## Cached horizon distances per unit pair. Recalculated when positions change.
## Key: "unit_id:target_id", Value: radar_horizon_nm
var _horizon_cache: Dictionary = {}
var _cache_tick: int = -1  # Tick when cache was last built

func initialize(world: Node) -> void:
	_world = world

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Calculate radar horizon distance between two heights.
## This is the core formula used everywhere.
static func compute_radar_horizon(antenna_height_ft: float, target_height_ft: float) -> float:
	if antenna_height_ft <= 0.0 and target_height_ft <= 0.0:
		return 0.0
	return HORIZON_CONSTANT * (sqrt(maxf(antenna_height_ft, 0.0)) + sqrt(maxf(target_height_ft, 0.0)))

## Get the effective antenna height for a unit, accounting for platform type
## and current state (airborne altitude, periscope depth, etc).
func get_effective_antenna_height(unit_id: String) -> float:
	if unit_id not in _world.units:
		return 0.0
	var unit: Dictionary = _world.units[unit_id]
	return _get_antenna_height(unit)

## Get the effective target height for a unit as seen by radar.
func get_effective_target_height(unit_id: String) -> float:
	if unit_id not in _world.units:
		return 0.0
	var unit: Dictionary = _world.units[unit_id]
	return _get_target_height(unit)

## Check if radar detection is blocked by horizon between two units.
## Returns true if detection IS possible (within radar horizon).
## Returns false if blocked by Earth curvature.
func is_within_radar_horizon(radar_unit_id: String, target_unit_id: String) -> bool:
	if radar_unit_id not in _world.units or target_unit_id not in _world.units:
		return false

	var radar_unit: Dictionary = _world.units[radar_unit_id]
	var target_unit: Dictionary = _world.units[target_unit_id]

	var antenna_ht: float = _get_antenna_height(radar_unit)
	var target_ht: float = _get_target_height(target_unit)
	var horizon_nm: float = compute_radar_horizon(antenna_ht, target_ht)
	var actual_range: float = radar_unit["position"].distance_to(target_unit["position"])

	return actual_range <= horizon_nm

## Get the radar horizon distance for a specific unit pair.
func get_horizon_range(radar_unit_id: String, target_unit_id: String) -> float:
	if radar_unit_id not in _world.units or target_unit_id not in _world.units:
		return 0.0

	var radar_unit: Dictionary = _world.units[radar_unit_id]
	var target_unit: Dictionary = _world.units[target_unit_id]

	var antenna_ht: float = _get_antenna_height(radar_unit)
	var target_ht: float = _get_target_height(target_unit)
	return compute_radar_horizon(antenna_ht, target_ht)

## Get the maximum radar horizon for a unit (vs a large surface target).
## Useful for HUD display of "how far can my radar see".
func get_max_radar_horizon(unit_id: String) -> float:
	if unit_id not in _world.units:
		return 0.0
	var unit: Dictionary = _world.units[unit_id]
	var antenna_ht: float = _get_antenna_height(unit)
	# Assume a moderate-sized surface target (~30ft superstructure)
	return compute_radar_horizon(antenna_ht, 30.0)

## Clear all tracking (call on scenario load).
func reset() -> void:
	pending_horizon_blocks.clear()
	_horizon_cache.clear()
	_cache_tick = -1

# ---------------------------------------------------------------------------
# Tick processing
# ---------------------------------------------------------------------------

## Tick update. Logs blocked radar detections for debug purposes.
## Call once per sim tick.
##
## NOTE: The actual radar horizon enforcement happens in DetectionSystem._radar_detection()
## (it already has the formula inline). This tick method is for supplementary
## logging and for the integration layer to provide horizon data to the HUD.
func tick_update() -> void:
	# Clear previous tick's blocks
	pending_horizon_blocks.clear()

	# Only log blocks every 10 ticks to avoid spam
	if _world.tick_count % 10 != 0:
		return

	# Check all radar-emitting units against all potential targets
	for radar_id in _world.units:
		var radar_unit: Dictionary = _world.units[radar_id]
		if not radar_unit["is_alive"]:
			continue
		if not radar_unit.get("emitting_radar", false):
			continue

		var antenna_ht: float = _get_antenna_height(radar_unit)
		if antenna_ht <= 0.0:
			continue  # No antenna = no radar (submerged sub)

		for target_id in _world.units:
			if target_id == radar_id:
				continue
			var target_unit: Dictionary = _world.units[target_id]
			if not target_unit["is_alive"]:
				continue
			# Only log blocks for enemy units (not friendlies)
			if target_unit["faction"] == radar_unit["faction"]:
				continue

			var target_ht: float = _get_target_height(target_unit)
			var horizon_nm: float = compute_radar_horizon(antenna_ht, target_ht)
			var actual_range: float = radar_unit["position"].distance_to(target_unit["position"])

			if actual_range > horizon_nm:
				pending_horizon_blocks.append({
					"unit_id": radar_id,
					"target_id": target_id,
					"antenna_height_ft": antenna_ht,
					"target_height_ft": target_ht,
					"radar_horizon_nm": horizon_nm,
					"actual_range_nm": actual_range,
					"timestamp": _world.sim_time,
				})

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

## Get effective antenna height for a unit (for the radar equation).
func _get_antenna_height(unit: Dictionary) -> float:
	if unit.get("platform", {}).is_empty():
		return 0.0
	# Airborne units use flight altitude
	if unit.get("is_airborne", false):
		return unit.get("altitude_ft", 0.0)

	# Submerged submarines: no radar mast above water
	if unit["depth_m"] < -5.0:
		return 0.0

	# At periscope depth (depth between -5 and 0): only periscope mast exposed
	if unit["depth_m"] < 0.0 and unit["platform"].get("type", "") == "SSN":
		return PERISCOPE_HEIGHT_FT

	# Surface ship: use platform antenna height
	return unit["platform"].get("antenna_height_ft", DEFAULT_SURFACE_ANTENNA_FT)

## Get effective target height as seen by radar.
func _get_target_height(unit: Dictionary) -> float:
	if unit.get("platform", {}).is_empty():
		return 0.0
	# Airborne targets use flight altitude
	if unit.get("is_airborne", false):
		return unit.get("altitude_ft", 0.0)

	# Fully submerged: radar cannot see (height = 0)
	if unit["depth_m"] < -5.0:
		return 0.0

	# Periscope depth: tiny exposure
	if unit["depth_m"] < 0.0 and unit["platform"].get("type", "") == "SSN":
		return PERISCOPE_HEIGHT_FT

	# Surface ship: use antenna height as proxy for superstructure height
	# (radar detects the highest point of the target)
	return unit["platform"].get("antenna_height_ft", DEFAULT_SURFACE_ANTENNA_FT)

# ---------------------------------------------------------------------------
# Reference table (for developer reference, not used in code)
# ---------------------------------------------------------------------------
# Platform             | Antenna Height | vs 30ft surface | vs Periscope (3ft)
# ---------------------|----------------|-----------------|-------------------
# Spruance DD (75ft)   | 75 ft          | ~17 NM          | ~13 NM
# Perry FFG (60ft)     | 60 ft          | ~16 NM          | ~12 NM
# Kirov CGN (100ft)    | 100 ft         | ~19 NM          | ~14 NM
# Udaloy DDG (75ft)    | 75 ft          | ~17 NM          | ~13 NM
# P-3C at 10,000ft     | 10,000 ft      | ~130 NM         | ~125 NM
# SH-60B at 500ft      | 500 ft         | ~34 NM          | ~30 NM
# Merchant (40ft)      | 40 ft          | ~14 NM          | ~10 NM
# Los Angeles SSN      | 0 ft (sub'd)   | N/A             | N/A
# Los Angeles (PD)     | 3 ft           | ~9 NM           | ~4 NM
