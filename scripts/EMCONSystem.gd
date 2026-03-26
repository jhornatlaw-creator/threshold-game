extends RefCounted
## EMCONSystem -- Emissions Control state machine.
##
## Manages EMCON states per unit, determining which sensors are allowed
## to radiate. Changing EMCON state is a player/AI decision with tradeoffs:
##   ALPHA: fully passive, invisible to ESM, but blind beyond passive sonar
##   BRAVO: navigation radar only, minimal ESM footprint
##   CHARLIE: most systems active, normal operations
##   DELTA: full radiating, all sensors active including fire control radar
##
## Each state defines a set of allowed emission categories. When EMCON
## changes, this system enforces it by toggling unit emission flags.
##
## Standalone subsystem -- will be wired into SimulationWorld after Phase 4.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton

## EMCON state enum -- ordered from most restrictive to most permissive
enum EMCONState {
	ALPHA = 0,   # Everything off. Fully passive. Invisible to ESM.
	BRAVO = 1,   # Navigation radar only. Minimal emissions.
	CHARLIE = 2, # Most systems active. Normal operations.
	DELTA = 3,   # Full radiating. All sensors active. Maximum signature.
}

## Human-readable names for HUD display
const STATE_NAMES := {
	EMCONState.ALPHA: "ALPHA",
	EMCONState.BRAVO: "BRAVO",
	EMCONState.CHARLIE: "CHARLIE",
	EMCONState.DELTA: "DELTA",
}

## Per-state sensor permission table.
## Each entry defines which emission categories are ALLOWED in that state.
## Categories: "radar_navigation", "radar_search", "radar_fire_control",
##             "sonar_active", "data_link", "esm_receiver"
## Note: ESM receiver is passive but requires an antenna mast -- not available
## at deep depth regardless of EMCON. Passive sonar is ALWAYS available.
const STATE_PERMISSIONS := {
	EMCONState.ALPHA: {
		"radar_navigation": false,
		"radar_search": false,
		"radar_fire_control": false,
		"sonar_active": false,
		"data_link": false,
		"esm_receiver": false,  # Mast down in ALPHA
	},
	EMCONState.BRAVO: {
		"radar_navigation": true,
		"radar_search": false,
		"radar_fire_control": false,
		"sonar_active": false,
		"data_link": false,
		"esm_receiver": true,
	},
	EMCONState.CHARLIE: {
		"radar_navigation": true,
		"radar_search": true,
		"radar_fire_control": false,
		"sonar_active": true,
		"data_link": true,
		"esm_receiver": true,
	},
	EMCONState.DELTA: {
		"radar_navigation": true,
		"radar_search": true,
		"radar_fire_control": true,
		"sonar_active": true,
		"data_link": true,
		"esm_receiver": true,
	},
}

## Per-unit EMCON state tracking.  Key: unit_id, Value: EMCONState int
var _unit_emcon: Dictionary = {}

func initialize(world: Node) -> void:
	_world = world

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Set the EMCON state for a unit. Enforces sensor permissions immediately.
## Returns true if state changed, false if already in that state or unit unknown.
func set_emcon_state(unit_id: String, new_state: int) -> bool:
	if unit_id not in _world.units:
		return false

	var old_state: int = _unit_emcon.get(unit_id, EMCONState.CHARLIE)
	if old_state == new_state:
		return false

	_unit_emcon[unit_id] = new_state
	_enforce_emcon(unit_id, new_state)

	# Store event for the integration layer to poll.
	# Uses an array so multiple EMCON changes in the same tick are not lost.
	# Consumers must drain the array each tick.
	_last_emcon_events.append({
		"unit_id": unit_id,
		"old_state": old_state,
		"new_state": new_state,
		"timestamp": _world.sim_time if _world else 0.0,
	})

	return true

## Get the current EMCON state for a unit. Defaults to CHARLIE (normal ops).
func get_emcon_state(unit_id: String) -> int:
	return _unit_emcon.get(unit_id, EMCONState.CHARLIE)

## Get human-readable EMCON state name.
func get_emcon_name(unit_id: String) -> String:
	var state: int = get_emcon_state(unit_id)
	return STATE_NAMES.get(state, "UNKNOWN")

## Check if a specific emission category is allowed for a unit.
func is_emission_allowed(unit_id: String, category: String) -> bool:
	var state: int = get_emcon_state(unit_id)
	var perms: Dictionary = STATE_PERMISSIONS.get(state, STATE_PERMISSIONS[EMCONState.CHARLIE])
	return perms.get(category, false)

## Initialize EMCON state for a newly spawned unit based on platform type.
## Submarines default to ALPHA (fully silent). Surface ships default to CHARLIE.
## Aircraft default to CHARLIE.
func init_unit_emcon(unit_id: String) -> void:
	if unit_id not in _world.units:
		return
	var unit: Dictionary = _world.units[unit_id]
	var platform_type: String = unit["platform"].get("type", "")

	# Submarines start in ALPHA (silent running) -- consistent with current
	# behavior where subs start with emitting_radar = false, emitting_sonar_active = false
	if platform_type == "SSN":
		_unit_emcon[unit_id] = EMCONState.ALPHA
	else:
		# Surface ships and aircraft default to CHARLIE (normal operations)
		_unit_emcon[unit_id] = EMCONState.CHARLIE

	_enforce_emcon(unit_id, _unit_emcon[unit_id])

## Restore a unit's EMCON state from saved data (used by load_game).
## Sets the state and enforces it without resetting to platform defaults.
func restore_unit_emcon(unit_id: String, state: int) -> void:
	if unit_id not in _world.units:
		return
	_unit_emcon[unit_id] = clampi(state, EMCONState.ALPHA, EMCONState.DELTA)
	_enforce_emcon(unit_id, _unit_emcon[unit_id])

## Remove a unit from EMCON tracking (call on unit destruction).
func remove_unit(unit_id: String) -> void:
	_unit_emcon.erase(unit_id)

## Get the ESM detectability range multiplier for a unit based on EMCON state.
## ALPHA: 0.0 (invisible to ESM)
## BRAVO: 0.3 (nav radar only -- very short ESM detection range)
## CHARLIE: 0.8 (most emissions -- detectable at moderate range)
## DELTA: 1.0 (full emissions -- detectable at maximum ESM range)
func get_esm_signature_multiplier(unit_id: String) -> float:
	var state: int = get_emcon_state(unit_id)
	match state:
		EMCONState.ALPHA:
			return 0.0
		EMCONState.BRAVO:
			return 0.3
		EMCONState.CHARLIE:
			return 0.8
		EMCONState.DELTA:
			return 1.0
		_:
			return 0.8

## Tick update -- called once per sim tick.
## Enforces EMCON state for all tracked units (handles edge cases where
## external code might toggle emissions directly).
func tick_update() -> void:
	for unit_id in _unit_emcon:
		if unit_id in _world.units and _world.units[unit_id]["is_alive"]:
			_enforce_emcon(unit_id, _unit_emcon[unit_id])

## Clear all tracking (call on scenario load).
func reset() -> void:
	_unit_emcon.clear()
	_last_emcon_events.clear()

# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

## EMCON change events -- array to avoid single-event overwrite within a tick.
## Consumers must drain the array each tick.
var _last_emcon_events: Array = []

## Apply EMCON permissions to unit emission flags.
func _enforce_emcon(unit_id: String, state: int) -> void:
	if unit_id not in _world.units:
		return

	var unit: Dictionary = _world.units[unit_id]
	var perms: Dictionary = STATE_PERMISSIONS.get(state, STATE_PERMISSIONS[EMCONState.CHARLIE])

	# Radar: emitting_radar controls all radar emissions.
	# In BRAVO, only nav radar is allowed -- but the current system has a single
	# emitting_radar flag. We set it true for BRAVO (nav radar only) and let
	# the detection system use the nav radar's limited range.
	# In ALPHA, radar is completely off.
	if perms["radar_search"] or perms["radar_navigation"]:
		unit["emitting_radar"] = true
	else:
		unit["emitting_radar"] = false

	# Active sonar
	if not perms["sonar_active"]:
		unit["emitting_sonar_active"] = false
	# Note: we do NOT force active sonar ON -- that requires explicit player action.
	# EMCON only RESTRICTS, never auto-enables.

	# Store EMCON state on unit dict for other systems to query
	unit["emcon_state"] = state

## Get a summary of what is allowed/denied for a given state (for HUD tooltip).
func get_state_summary(state: int) -> String:
	match state:
		EMCONState.ALPHA:
			return "EMCON ALPHA: All emissions OFF. Passive sonar only. Invisible to ESM."
		EMCONState.BRAVO:
			return "EMCON BRAVO: Nav radar only. ESM active. Minimal signature."
		EMCONState.CHARLIE:
			return "EMCON CHARLIE: Search radar + active sonar. Normal operations."
		EMCONState.DELTA:
			return "EMCON DELTA: All systems radiating. Fire control radar active. Maximum awareness."
		_:
			return "UNKNOWN EMCON STATE"

## Determine the radar subtype allowed in current EMCON state.
## Returns an array of allowed radar subtypes for DetectionSystem to filter.
func get_allowed_radar_subtypes(unit_id: String) -> Array:
	var state: int = get_emcon_state(unit_id)
	match state:
		EMCONState.ALPHA:
			return []
		EMCONState.BRAVO:
			return ["navigation"]  # Nav radar only
		EMCONState.CHARLIE:
			return ["navigation", "air_search", "air_surface_search", "air_search_3d", "maritime_search"]
		EMCONState.DELTA:
			return ["navigation", "air_search", "air_surface_search", "air_search_3d",
					"phased_array", "maritime_search", "fire_control"]
		_:
			return []
