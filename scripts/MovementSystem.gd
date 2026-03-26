extends RefCounted
## MovementSystem -- Unit kinematics, waypoints, depth changes, aircraft fuel/RTB.
##
## Extracted from SimulationWorld. Operates on world state dictionaries.
## All signals emit THROUGH the world reference (SimulationWorld stays the signal owner).

var _world: Node  # Reference to SimulationWorld singleton

func initialize(world: Node) -> void:
	_world = world

# ---------------------------------------------------------------------------
# Main movement tick -- called once per sim tick
# ---------------------------------------------------------------------------
func move_units() -> void:
	for uid in _world.units:
		var u: Dictionary = _world.units[uid]
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
					_world.unit_heading_changed.emit(uid, u["heading"])
					# Phase 8: wire break check -- turns > 30 degrees break the wire
					if _world._weapon_system.is_unit_on_wire(uid):
						var heading_change: float = absf(_bearing_delta(old_heading, u["heading"]))
						if heading_change > 30.0:
							for wid in _world._weapon_system._active_wires:
								var wire: Dictionary = _world._weapon_system._active_wires[wid]
								if wire["shooter_id"] == uid and not wire["broken"]:
									wire["broken"] = true
									_world.wire_cut.emit(wid)
									if wid in _world.weapons_in_flight:
										_world.weapons_in_flight[wid]["on_wire"] = false

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
			var distance_nm: float = u["speed_kts"] * _world.KNOTS_TO_NM_PER_SEC * (1.0 / _world.BASE_TICK_HZ)
			var movement := Vector2(sin(heading_rad), cos(heading_rad)) * distance_nm
			u["position"] += movement
			_world.unit_moved.emit(uid, old_pos, u["position"])

		# Sea state constraint for helicopters: Sea State 6+ means no flight ops
		# Airborne helos in SS6+ must RTB immediately (can't hover, can't search)
		if u.get("is_airborne", false) and _world.weather_sea_state >= 6:
			var platform_type: String = u["platform"].get("type", "")
			if platform_type == "HELO" and u.get("behavior", "") != "rtb":
				_air_rtb(uid, u)
				_world.aircraft_bingo.emit(uid, u.get("name", uid))
				# Message handled by RenderBridge via aircraft_bingo signal

		# Fuel consumption for airborne units
		if u.get("is_airborne", false) and u.get("max_endurance_hours", 0.0) > 0.0:
			var fuel_per_tick: float = (1.0 / _world.BASE_TICK_HZ) / (u["max_endurance_hours"] * 3600.0)
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
					if base_id != "" and base_id in _world.units:
						var dist_to_base: float = u["position"].distance_to(_world.units[base_id]["position"])
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
			if base_id != "" and base_id in _world.units and _world.units[base_id]["is_alive"]:
				# Update waypoint to track moving base ship
				u["waypoints"] = [_world.units[base_id]["position"]]
				var dist_to_base: float = u["position"].distance_to(_world.units[base_id]["position"])
				if dist_to_base < 1.0:
					_land_aircraft(uid, u)

# ---------------------------------------------------------------------------
# Aircraft operations
# ---------------------------------------------------------------------------

## Initiate return-to-base for an airborne unit.
func _air_rtb(uid: String, u: Dictionary) -> void:
	var base_id: String = u.get("base_unit_id", "")
	if base_id != "" and base_id in _world.units and _world.units[base_id]["is_alive"]:
		u["waypoints"] = [_world.units[base_id]["position"]]
		u["speed_kts"] = u["max_speed_kts"] * 0.8
		u["behavior"] = "rtb"
		_world.aircraft_bingo.emit(uid, u.get("name", uid))
	elif base_id != "" and (base_id not in _world.units or not _world.units[base_id]["is_alive"]):
		# Base ship destroyed -- divert or crash when fuel runs out
		u["behavior"] = "rtb"
		_world.aircraft_bingo.emit(uid, u.get("name", uid))

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
	if base_id != "" and base_id in _world.units:
		u["position"] = _world.units[base_id]["position"]
	_world.aircraft_landed.emit(uid, u.get("name", uid))

## Aircraft ran out of fuel in flight -- lost.
func _crash_aircraft(uid: String, u: Dictionary) -> void:
	_world.aircraft_crashed.emit(uid, u.get("name", uid))
	_world.destroy_unit(uid)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
func _turn_toward(current_deg: float, target_deg: float, max_turn: float) -> float:
	var diff: float = fmod(target_deg - current_deg + 540.0, 360.0) - 180.0
	var turn: float = clampf(diff, -max_turn, max_turn)
	return fmod(current_deg + turn + 360.0, 360.0)

## Phase 8: compute shortest angular difference between two bearings.
func _bearing_delta(from_deg: float, to_deg: float) -> float:
	var delta: float = fmod(to_deg - from_deg + 540.0, 360.0) - 180.0
	return delta
