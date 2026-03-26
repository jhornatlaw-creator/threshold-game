extends Node2D
## RenderBridge -- Subscribes to SimulationWorld signals and creates/updates
## visual Node2D representations. Pure listener. Never reads simulation state
## directly -- everything flows through signals.
##
## Phase 1: ModernRenderer (NATO symbols, bearing lines, range rings)
## Phase 2: RetroRenderer (pixel sprites, CRT shader) -- architecture supports it

# ---------------------------------------------------------------------------
# References
# ---------------------------------------------------------------------------
@onready var camera: Camera2D = $Camera2D
@onready var ocean: ColorRect = $Ocean
@onready var units_layer: Node2D = $UnitsLayer
@onready var weapons_layer: Node2D = $WeaponsLayer
@onready var effects_layer: Node2D = $EffectsLayer
@onready var ui_layer: CanvasLayer = $UILayer
@onready var hud: Control = $UILayer/HUD

var _unit_visuals: Dictionary = {}   # unit_id -> UnitVisual (Node2D)
var _weapon_visuals: Dictionary = {} # weapon_id -> WeaponVisual (Node2D)
var _selected_unit_id: String = ""
var _fire_target_id: String = ""  # Item 1: designated fire target (click enemy contact)
var _selected_weapon_id: String = ""  # Manually selected weapon type for firing
var _player_contacts: Dictionary = {}  # target_id -> latest detection dict (from player units)
var _bearing_lines: Dictionary = {}  # target_id -> Line2D (bearing line for passive contacts)
var _uncertainty_visuals: Dictionary = {}  # target_id -> Node2D (uncertainty zone visual)
var _player_unit_ids: Array = []  # M-6: ordered list of player unit IDs for Tab cycling
var _player_cycle_index: int = -1
var _result_shown: bool = false  # Item 10: track if result screen is visible
var _lost_contact_timers: Dictionary = {}  # target_id -> ticks remaining for last-known datum
var _route_line: Line2D = null  # Waypoint route line for selected player unit
var _sonobuoy_visuals: Dictionary = {}  # buoy_id -> Node2D (sonobuoy icon on map)
var _sonobuoy_bearing_lines: Dictionary = {}  # "buoy_id:target_id" -> Line2D

# Tutorial integration signals
signal unit_selected(unit_id: String)
signal fire_target_designated(target_id: String)
signal camera_recentered()
signal camera_zoomed()

# Conversion: simulation uses NM, rendering uses pixels
const NM_TO_PX: float = 10.0

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _exit_tree() -> void:
	# Disconnect signals from autoload singletons to prevent accumulation across scene reloads
	var sigs: Array = [
		[SimulationWorld.unit_spawned, _on_unit_spawned],
		[SimulationWorld.unit_moved, _on_unit_moved],
		[SimulationWorld.unit_heading_changed, _on_unit_heading_changed],
		[SimulationWorld.unit_destroyed, _on_unit_destroyed],
		[SimulationWorld.unit_detected, _on_unit_detected],
		[SimulationWorld.detection_lost, _on_detection_lost],
		[SimulationWorld.weapon_fired, _on_weapon_fired],
		[SimulationWorld.weapon_moved, _on_weapon_moved],
		[SimulationWorld.weapon_resolved, _on_weapon_resolved],
		[SimulationWorld.weapon_removed, _on_weapon_removed],
		[SimulationWorld.scenario_started, _on_scenario_started],
		[SimulationWorld.scenario_ended, _on_scenario_ended],
		[SimulationWorld.sim_tick, _on_sim_tick],
		[SimulationWorld.time_scale_changed, _on_time_scale_changed],
		[SimulationWorld.contact_classified, _on_contact_classified],
		[SimulationWorld.sosus_contact, _on_sosus_contact],
		[SimulationWorld.helicopter_launched, _on_helicopter_launched],
		[SimulationWorld.aircraft_bingo, _on_aircraft_bingo],
		[SimulationWorld.aircraft_landed, _on_aircraft_landed],
		[SimulationWorld.aircraft_crashed, _on_aircraft_crashed],
		[SimulationWorld.tma_solution_updated, _on_tma_solution_updated],
		[SimulationWorld.tma_contact_lost, _on_tma_contact_lost],
		[SimulationWorld.xbt_dropped, _on_xbt_dropped],
		[SimulationWorld.submarine_went_deep, _on_submarine_went_deep],
		[SimulationWorld.sonobuoy_deployed, _on_sonobuoy_deployed],
		[SimulationWorld.sonobuoy_contact, _on_sonobuoy_contact],
		[SimulationWorld.sonobuoy_expired, _on_sonobuoy_expired],
		[SimulationWorld.sonobuoy_dicass_contact, _on_sonobuoy_dicass_contact],
		[SimulationWorld.sonobuoy_dicass_alert, _on_sonobuoy_dicass_alert],
		[SimulationWorld.emcon_state_changed, _on_emcon_state_changed],
		[SimulationWorld.counter_detection_event, _on_counter_detection_event],
		[SimulationWorld.esm_contact_detected, _on_esm_contact_detected],
		[SimulationWorld.torpedo_launched, _on_torpedo_launched],
		[SimulationWorld.weapon_impact, _on_weapon_impact],
		[SimulationWorld.roe_changed, _on_roe_changed],
		[SimulationWorld.roe_blocked, _on_roe_blocked],
		[SimulationWorld.contact_classification_changed, _on_contact_classification_changed],
		[SimulationWorld.kill_confirmed, _on_kill_confirmed],
		[SimulationWorld.wire_cut, _on_wire_cut],
		[SimulationWorld.countermeasure_deployed, _on_countermeasure_deployed],
	]
	for pair in sigs:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])

func _ready() -> void:
	_connect_signals()
	_setup_camera()
	# Route line for selected player unit's waypoint path
	_route_line = Line2D.new()
	_route_line.width = 1.5
	_route_line.default_color = Color(0.3, 0.7, 1.0, 0.4)
	_route_line.name = "RouteLine"
	units_layer.add_child(_route_line)

func _connect_signals() -> void:
	SimulationWorld.unit_spawned.connect(_on_unit_spawned)
	SimulationWorld.unit_moved.connect(_on_unit_moved)
	SimulationWorld.unit_heading_changed.connect(_on_unit_heading_changed)
	SimulationWorld.unit_destroyed.connect(_on_unit_destroyed)
	SimulationWorld.unit_detected.connect(_on_unit_detected)
	SimulationWorld.detection_lost.connect(_on_detection_lost)
	SimulationWorld.weapon_fired.connect(_on_weapon_fired)
	SimulationWorld.weapon_moved.connect(_on_weapon_moved)
	SimulationWorld.weapon_resolved.connect(_on_weapon_resolved)
	SimulationWorld.weapon_removed.connect(_on_weapon_removed)
	SimulationWorld.scenario_started.connect(_on_scenario_started)
	SimulationWorld.scenario_ended.connect(_on_scenario_ended)
	SimulationWorld.sim_tick.connect(_on_sim_tick)
	SimulationWorld.time_scale_changed.connect(_on_time_scale_changed)
	SimulationWorld.contact_classified.connect(_on_contact_classified)
	SimulationWorld.sosus_contact.connect(_on_sosus_contact)
	SimulationWorld.helicopter_launched.connect(_on_helicopter_launched)
	SimulationWorld.aircraft_bingo.connect(_on_aircraft_bingo)
	SimulationWorld.aircraft_landed.connect(_on_aircraft_landed)
	SimulationWorld.aircraft_crashed.connect(_on_aircraft_crashed)
	SimulationWorld.tma_solution_updated.connect(_on_tma_solution_updated)
	SimulationWorld.tma_contact_lost.connect(_on_tma_contact_lost)
	SimulationWorld.xbt_dropped.connect(_on_xbt_dropped)
	SimulationWorld.submarine_went_deep.connect(_on_submarine_went_deep)
	SimulationWorld.sonobuoy_deployed.connect(_on_sonobuoy_deployed)
	SimulationWorld.sonobuoy_contact.connect(_on_sonobuoy_contact)
	SimulationWorld.sonobuoy_expired.connect(_on_sonobuoy_expired)
	SimulationWorld.sonobuoy_dicass_contact.connect(_on_sonobuoy_dicass_contact)
	SimulationWorld.sonobuoy_dicass_alert.connect(_on_sonobuoy_dicass_alert)
	SimulationWorld.emcon_state_changed.connect(_on_emcon_state_changed)
	SimulationWorld.counter_detection_event.connect(_on_counter_detection_event)
	SimulationWorld.esm_contact_detected.connect(_on_esm_contact_detected)
	SimulationWorld.torpedo_launched.connect(_on_torpedo_launched)
	SimulationWorld.weapon_impact.connect(_on_weapon_impact)
	SimulationWorld.roe_changed.connect(_on_roe_changed)
	SimulationWorld.roe_blocked.connect(_on_roe_blocked)
	SimulationWorld.contact_classification_changed.connect(_on_contact_classification_changed)
	SimulationWorld.kill_confirmed.connect(_on_kill_confirmed)
	SimulationWorld.wire_cut.connect(_on_wire_cut)
	SimulationWorld.countermeasure_deployed.connect(_on_countermeasure_deployed)
	# crisis_temperature_changed: intentionally unwired -- hidden from player

func _setup_camera() -> void:
	if camera:
		camera.zoom = Vector2(1.0, 1.0)
		camera.position = Vector2.ZERO

# ---------------------------------------------------------------------------
# Signal handlers -- unit lifecycle
# ---------------------------------------------------------------------------
func _on_unit_spawned(unit_id: String, unit_data: Dictionary) -> void:
	var visual := _create_unit_visual(unit_id, unit_data)
	var pos := Vector2(unit_data["position"].x, unit_data["position"].y) * NM_TO_PX
	visual.position = pos
	# Enemy units are hidden until detected (fog of war)
	# On-deck helicopters (visible=false) are hidden until launched
	if unit_data.get("faction", "") == "enemy" or not unit_data.get("visible", true):
		visual.visible = false
	else:
		# M-6: track player units for Tab cycling
		if unit_data.get("faction", "") == "player":
			_player_unit_ids.append(unit_id)
	units_layer.add_child(visual)
	_unit_visuals[unit_id] = visual

func _on_unit_moved(_unit_id: String, _old_pos: Vector2, new_pos: Vector2) -> void:
	if _unit_id in _unit_visuals:
		_unit_visuals[_unit_id].position = new_pos * NM_TO_PX
		# Update wake trail
		var visual: Node2D = _unit_visuals[_unit_id]
		if visual.has_method("update_wake"):
			visual.update_wake(new_pos * NM_TO_PX)

func _on_unit_heading_changed(unit_id: String, heading_deg: float) -> void:
	if unit_id in _unit_visuals:
		var symbol = _unit_visuals[unit_id].find_child("Symbol")
		if symbol and symbol.has_method("set_heading"):
			symbol.set_heading(heading_deg)

func _on_unit_destroyed(unit_id: String) -> void:
	if unit_id in _unit_visuals:
		var visual: Node2D = _unit_visuals[unit_id]
		_spawn_explosion(visual.position)
		visual.queue_free()
		_unit_visuals.erase(unit_id)
		if _selected_unit_id == unit_id:
			_selected_unit_id = ""
			# Fix 3: clear stale HUD panel when selected unit is destroyed
			if hud and hud.has_method("set_selected_unit"):
				hud.set_selected_unit("")
		if _fire_target_id == unit_id:
			_fire_target_id = ""
	# Clean up stale entries for destroyed unit
	_player_contacts.erase(unit_id)
	_remove_bearing_line(unit_id)
	_remove_uncertainty_zone(unit_id)
	_player_unit_ids.erase(unit_id)
	_player_cycle_index = -1  # Reset Tab cycling after force change

func _on_unit_detected(detector_id: String, target_id: String, detection: Dictionary) -> void:
	# Only show contacts detected by player units
	var detector_data: Dictionary = SimulationWorld.units.get(detector_id, {})
	if detector_data.get("faction", "") != "player":
		return

	# Audio + visual feedback for NEW contact (not a refresh)
	var is_new_contact: bool = target_id not in _player_contacts
	if is_new_contact:
		AudioManager.play_contact_new()
		# Phase 9: audio-first detection -- screw beats before display confirmation
		AudioManager.queue_audio_first_detection(target_id, detection.get("bearing", 0.0), 2.5)
		if hud and hud.has_method("flash_new_contact"):
			hud.flash_new_contact()

	_player_contacts[target_id] = detection
	# Item 6: cancel any pending lost-contact timer on re-detection
	_lost_contact_timers.erase(target_id)

	var is_bearing_only: bool = detection.get("bearing_only", false)
	var det_pos: Vector2 = detector_data.get("position", Vector2.ZERO)
	var bearing_deg: float = detection.get("bearing", 0.0)
	var bearing_rad: float = deg_to_rad(bearing_deg)
	var bearing_dir: Vector2 = Vector2(sin(bearing_rad), -cos(bearing_rad))

	if is_bearing_only:
		# BEARING-ONLY CONTACT: draw a bearing line from detector to map edge
		_update_bearing_line(target_id, det_pos, bearing_dir, detection)
		# Hide positioned icon if it exists (was a ranged contact that lost range)
		if target_id in _unit_visuals:
			_unit_visuals[target_id].visible = false
	else:
		# RANGED CONTACT: positioned icon (radar, active sonar, or TMA solution)
		var range_est: float = detection.get("range_est", 10.0)
		var est_pos: Vector2 = det_pos + bearing_dir * range_est
		# Remove bearing line if contact upgraded from bearing-only to ranged
		_remove_bearing_line(target_id)

		if target_id in _unit_visuals:
			var visual: Node2D = _unit_visuals[target_id]
			visual.visible = true
			visual.position = est_pos * NM_TO_PX
			# Update label to show designator (Item 6: restore alpha from LK fade)
			var classification: Dictionary = detection.get("classification", {})
			var label = visual.find_child("Label")
			if label and classification.has("designator"):
				label.text = classification["designator"]
				label.modulate.a = 1.0
			var symbol = visual.find_child("Symbol")
			if symbol and symbol.has_method("set_detected"):
				symbol.set_detected(true, detection)
		else:
			# Create a contact marker for unknown entity
			var contact_visual := _create_contact_visual(target_id, detection)
			contact_visual.position = est_pos * NM_TO_PX
			units_layer.add_child(contact_visual)
			_unit_visuals[target_id] = contact_visual

func _on_detection_lost(_detector_id: String, target_id: String) -> void:
	# Check if ANY player unit still detects this target
	var still_detected := false
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if u.get("faction", "") == "player" and target_id in u.get("contacts", {}):
			still_detected = true
			break

	if not still_detected:
		_player_contacts.erase(target_id)
		# Phase 9: stop contact audio
		AudioManager.stop_contact_audio(target_id)
		# Clean up TMA visuals for this contact
		_remove_bearing_line(target_id)
		_remove_uncertainty_zone(target_id)
		if target_id in _unit_visuals:
			var visual: Node2D = _unit_visuals[target_id]
			var unit_data: Dictionary = SimulationWorld.units.get(target_id, {})
			if unit_data.get("faction", "") != "player":
				# Item 6: last-known datum -- fade to 30% alpha and mark "LK"
				var symbol = visual.find_child("Symbol")
				if symbol and symbol.has_method("set_detected"):
					symbol.set_detected(false, {})
				var label = visual.find_child("Label")
				if label:
					if not label.text.ends_with(" LK"):
						label.text = label.text + " LK"
					label.modulate.a = 0.3
				# Start 60-tick countdown before hiding
				_lost_contact_timers[target_id] = 60

func _on_contact_classified(_detector_id: String, target_id: String, detection: Dictionary) -> void:
	# Phase 9: classification upgrade audio
	AudioManager.play_classify_upgrade()
	if target_id in _unit_visuals:
		var symbol = _unit_visuals[target_id].find_child("Symbol")
		if symbol and symbol.has_method("update_classification"):
			symbol.update_classification(detection.get("classification", {}))

func _on_sosus_contact(barrier_id: String, bearing_deg: float, confidence: float) -> void:
	# Show SOSUS detection as HUD alert with bearing info
	if hud and hud.has_method("show_message"):
		hud.show_message("SOSUS %s: CONTACT BRG %03d (%.0f%%)" % [barrier_id, int(bearing_deg), confidence * 100.0], 4.0)
	AudioManager.play_contact_new()

func _on_helicopter_launched(parent_id: String, helo_id: String) -> void:
	# Make the launched helo's visual visible (it was hidden on deck)
	if helo_id in _unit_visuals:
		_unit_visuals[helo_id].visible = true
	# Add to player unit cycling if it's a player helo
	if helo_id in SimulationWorld.units and SimulationWorld.units[helo_id]["faction"] == "player":
		if helo_id not in _player_unit_ids:
			_player_unit_ids.append(helo_id)
	if parent_id in SimulationWorld.units and SimulationWorld.units[parent_id]["faction"] == "player":
		var parent_name: String = SimulationWorld.units[parent_id].get("name", parent_id)
		if hud and hud.has_method("show_message"):
			hud.show_message("%s: HELO AIRBORNE" % parent_name, 2.0)

func _on_aircraft_bingo(_aircraft_id: String, aircraft_name: String) -> void:
	if hud and hud.has_method("show_message"):
		hud.show_message("%s: BINGO FUEL — RETURNING TO BASE" % aircraft_name, 3.0)
	AudioManager.play_contact_new()

func _on_aircraft_landed(aircraft_id: String, aircraft_name: String) -> void:
	if aircraft_id in _unit_visuals:
		_unit_visuals[aircraft_id].visible = false
	if hud and hud.has_method("show_message"):
		hud.show_message("%s: RECOVERED ON DECK" % aircraft_name, 2.0)

func _on_aircraft_crashed(_aircraft_id: String, aircraft_name: String) -> void:
	if hud and hud.has_method("show_message"):
		hud.show_message("%s: LOST — FUEL EXHAUSTED" % aircraft_name, 4.0)
	AudioManager.play_explosion()

# ---------------------------------------------------------------------------
# Signal handlers -- weapons
# ---------------------------------------------------------------------------
func _on_weapon_fired(weapon_id: String, _shooter_id: String, _target_id: String, weapon_data: Dictionary) -> void:
	var visual := _create_weapon_visual(weapon_id, weapon_data)
	if _shooter_id in _unit_visuals:
		visual.position = _unit_visuals[_shooter_id].position
	weapons_layer.add_child(visual)
	_weapon_visuals[weapon_id] = visual

	# Audio: missile/weapon launch sounds
	var shooter_faction: String = SimulationWorld.units.get(_shooter_id, {}).get("faction", "")
	if shooter_faction == "player":
		# Phase 9: torpedo-specific launch sound
		if weapon_data.get("type", "") == "torpedo":
			AudioManager.play_torpedo_launch()
		else:
			AudioManager.play_weapon_launch()
		AudioManager.play_missile_away()

	# EN-1: "TORPEDO IN THE WATER" alert when enemy fires torpedo at player
	if _target_id in SimulationWorld.units:
		var target_unit: Dictionary = SimulationWorld.units[_target_id]
		if target_unit.get("faction", "") == "player" and weapon_data.get("type", "") == "torpedo":
			if hud and hud.has_method("show_alert"):
				hud.show_alert("TORPEDO IN THE WATER", 5.0)
			# Audio: torpedo warning loop starts for incoming enemy weapon
			AudioManager.play_torpedo_warning()

func _on_weapon_moved(weapon_id: String, _old_pos: Vector2, new_pos: Vector2) -> void:
	if weapon_id in _weapon_visuals:
		_weapon_visuals[weapon_id].position = new_pos * NM_TO_PX

func _on_weapon_resolved(weapon_id: String, target_id: String, hit: bool, _damage: float) -> void:
	if weapon_id not in _weapon_visuals:
		return  # B-1: guard against double-signal (already removed)
	var pos: Vector2 = _weapon_visuals[weapon_id].position
	if hit:
		_spawn_explosion(pos)
		AudioManager.play_explosion()
	_weapon_visuals[weapon_id].queue_free()
	_weapon_visuals.erase(weapon_id)
	# Stop torpedo warning if no more enemy weapons are in flight targeting player units
	_update_torpedo_warning()

func _on_weapon_removed(weapon_id: String) -> void:
	if weapon_id in _weapon_visuals:
		_weapon_visuals[weapon_id].queue_free()
		_weapon_visuals.erase(weapon_id)
	# Stop torpedo warning if no more enemy weapons are in flight targeting player units
	_update_torpedo_warning()

## Check if any enemy weapons are still in flight against player units.
## Starts or stops the torpedo warning tone accordingly.
func _update_torpedo_warning() -> void:
	var enemy_weapon_inbound: bool = false
	for wid in SimulationWorld.weapons_in_flight:
		var w: Dictionary = SimulationWorld.weapons_in_flight[wid]
		if w.get("resolved", false):
			continue
		var shooter_id: String = w.get("shooter_id", "")
		var target_id: String = w.get("target_id", "")
		var shooter_faction: String = SimulationWorld.units.get(shooter_id, {}).get("faction", "")
		var target_faction: String = SimulationWorld.units.get(target_id, {}).get("faction", "")
		if shooter_faction == "enemy" and target_faction == "player":
			enemy_weapon_inbound = true
			break
	if not enemy_weapon_inbound:
		AudioManager.stop_torpedo_warning()

# ---------------------------------------------------------------------------
# Signal handlers -- scenario / time
# ---------------------------------------------------------------------------
func _on_scenario_started(scenario_name: String) -> void:
	# Clear sonobuoy visuals from previous scenario
	for buoy_id in _sonobuoy_visuals:
		if is_instance_valid(_sonobuoy_visuals[buoy_id]):
			_sonobuoy_visuals[buoy_id].queue_free()
	_sonobuoy_visuals.clear()
	for line_key in _sonobuoy_bearing_lines:
		if is_instance_valid(_sonobuoy_bearing_lines[line_key]):
			_sonobuoy_bearing_lines[line_key].queue_free()
	_sonobuoy_bearing_lines.clear()
	if hud and hud.has_method("show_scenario_name"):
		hud.show_scenario_name(scenario_name)

func _on_scenario_ended(result: String) -> void:
	_result_shown = true
	if hud and hud.has_method("show_result"):
		hud.show_result(result)

func _on_sim_tick(_tick_number: int, _sim_time: float) -> void:
	_update_hud()
	_update_selection_visuals()
	# Phase 9: own-ship speed/heading tracking for flow noise
	if _selected_unit_id in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[_selected_unit_id]
		AudioManager.update_ownship_speed(u.get("speed_kts", 0.0))
		AudioManager.update_ownship_heading(u.get("heading", 0.0))
	# Phase 9: sea state audio
	AudioManager.update_sea_state(SimulationWorld.weather_sea_state)
	_update_bearing_lines_tick()
	# Item 6: process last-known contact datum timers
	var expired := []
	for tid in _lost_contact_timers:
		_lost_contact_timers[tid] -= 1
		if _lost_contact_timers[tid] <= 0:
			expired.append(tid)
	for tid in expired:
		_lost_contact_timers.erase(tid)
		if tid in _unit_visuals:
			_unit_visuals[tid].visible = false

func _on_time_scale_changed(new_scale: float) -> void:
	if hud and hud.has_method("update_time_scale"):
		hud.update_time_scale(new_scale)
	# Phase 9: time compression audio
	AudioManager.set_time_compression(new_scale)

# ---------------------------------------------------------------------------
# Visual factory -- Modern Tactical Renderer (Phase 1)
# ---------------------------------------------------------------------------
func _create_unit_visual(unit_id: String, unit_data: Dictionary) -> Node2D:
	var node := Node2D.new()
	node.name = "Unit_" + unit_id

	var symbol := _NATOSymbol.new()
	symbol.unit_data = unit_data
	symbol.name = "Symbol"
	node.add_child(symbol)

	# Label
	var label := Label.new()
	label.text = unit_data.get("name", unit_id)
	label.position = Vector2(15, -8)
	label.add_theme_font_size_override("font_size", 11)
	if unit_data.get("faction", "") == "player":
		label.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	else:
		label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	label.name = "Label"
	node.add_child(label)

	# Heading line
	var heading_line := Line2D.new()
	heading_line.width = 1.5
	heading_line.default_color = Color(0.5, 0.5, 0.5, 0.6)
	heading_line.points = PackedVector2Array([Vector2.ZERO, Vector2(0, -20)])
	heading_line.name = "HeadingLine"
	node.add_child(heading_line)

	# Range rings for player units with radar
	if unit_data.get("faction", "") == "player":
		var ring := _RangeRing.new()
		ring.name = "RangeRing"
		# Find max radar range from sensors (sensors array contains full dicts from _init_sensors)
		for sdata in unit_data.get("sensors", []):
			if sdata.get("type", "") == "radar":
				ring.radar_range_px = sdata.get("max_range_nm", 100.0) * NM_TO_PX
		# Find max weapon range
		for weapon_id in unit_data.get("platform", {}).get("weapons", []):
			var wdata: Dictionary = PlatformLoader.get_weapon(weapon_id)
			if wdata.get("max_range_nm", 0.0) > ring.weapon_range_px / NM_TO_PX:
				ring.weapon_range_px = wdata.get("max_range_nm", 50.0) * NM_TO_PX
		node.add_child(ring)

	# N-2: Set heading line to initial heading at spawn
	var initial_heading: float = unit_data.get("heading", 0.0)
	var heading_rad: float = deg_to_rad(initial_heading)
	var tip := Vector2(sin(heading_rad), -cos(heading_rad)) * 20.0
	heading_line.points = PackedVector2Array([Vector2.ZERO, tip])

	# Store metadata
	node.set_meta("unit_id", unit_id)
	node.set_meta("faction", unit_data.get("faction", ""))
	node.set_meta("platform_type", unit_data.get("platform", {}).get("type", ""))
	node.set_meta("is_air", unit_data.get("platform", {}).get("type", "") in ["HELO", "MPA"])

	# Script-like methods via a helper script
	var helper := _UnitVisualHelper.new()
	helper.name = "Helper"
	node.add_child(helper)

	return node

func _create_contact_visual(target_id: String, detection: Dictionary) -> Node2D:
	var node := Node2D.new()
	node.name = "Contact_" + target_id

	var symbol := _NATOSymbol.new()
	symbol.is_contact = true
	symbol.detection_data = detection
	symbol.name = "Symbol"
	node.add_child(symbol)

	var classification: Dictionary = detection.get("classification", {})
	var label := Label.new()
	label.text = classification.get("designator", "UNKNOWN")
	label.position = Vector2(15, -8)
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
	label.name = "Label"
	node.add_child(label)

	node.set_meta("unit_id", target_id)
	node.set_meta("faction", "enemy")
	node.set_meta("is_contact", true)

	return node

func _create_weapon_visual(weapon_id: String, weapon_data: Dictionary) -> Node2D:
	var node := Node2D.new()
	node.name = "Weapon_" + weapon_id

	var marker := _WeaponMarker.new()
	marker.weapon_type = weapon_data.get("type", "ASM")
	marker.guidance = weapon_data.get("guidance", "")  # Item 8: pass guidance for ASROC distinction
	marker.name = "Marker"
	node.add_child(marker)

	# Trail
	var trail := Line2D.new()
	trail.width = 1.0
	trail.default_color = Color(1.0, 1.0, 0.0, 0.5)
	trail.name = "Trail"
	node.add_child(trail)

	node.set_meta("weapon_id", weapon_id)
	return node

func _spawn_explosion(pos: Vector2) -> void:
	var explosion := _ExplosionEffect.new()
	explosion.position = pos
	effects_layer.add_child(explosion)

# ---------------------------------------------------------------------------
# Bearing lines + uncertainty zones (TMA passive contacts)
# ---------------------------------------------------------------------------

## Draw or update a bearing line from detector to map edge for a passive contact.
func _update_bearing_line(target_id: String, detector_pos: Vector2, bearing_dir: Vector2,
		detection: Dictionary) -> void:
	var line: Line2D
	if target_id in _bearing_lines:
		line = _bearing_lines[target_id]
	else:
		line = Line2D.new()
		line.name = "BearingLine_" + target_id
		line.width = 1.5
		line.default_color = Color(1.0, 0.6, 0.2, 0.5)  # Amber, semi-transparent
		units_layer.add_child(line)
		_bearing_lines[target_id] = line

	# Draw from detector position along bearing to 200 NM (map edge)
	var start_px: Vector2 = detector_pos * NM_TO_PX
	var end_px: Vector2 = (detector_pos + bearing_dir * 200.0) * NM_TO_PX
	line.clear_points()
	line.add_point(start_px)
	line.add_point(end_px)
	line.visible = true

	# Add designator label at a point along the line (~40 NM out)
	var label_pos: Vector2 = (detector_pos + bearing_dir * 40.0) * NM_TO_PX
	var classification: Dictionary = detection.get("classification", {})
	var designator: String = classification.get("designator", "?")
	var label = line.find_child("BrgLabel")
	if not label:
		label = Label.new()
		label.name = "BrgLabel"
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2, 0.8))
		line.add_child(label)
	label.text = designator
	label.position = label_pos - start_px + Vector2(8, -12)

	# TMA quality indicator: color shifts from amber to green as quality improves
	var tma_quality: float = detection.get("tma_quality", 0.0)
	if tma_quality > 0.5:
		var t: float = clampf((tma_quality - 0.5) / 0.5, 0.0, 1.0)
		line.default_color = Color(
			lerpf(1.0, 0.3, t),   # R: amber -> green
			lerpf(0.6, 1.0, t),   # G: amber -> green
			lerpf(0.2, 0.3, t),   # B
			lerpf(0.5, 0.7, t)    # A: more opaque as quality improves
		)

func _remove_bearing_line(target_id: String) -> void:
	if target_id in _bearing_lines:
		_bearing_lines[target_id].queue_free()
		_bearing_lines.erase(target_id)

## Update all bearing lines each tick -- detector position moves, bearing lines follow.
func _update_bearing_lines_tick() -> void:
	for target_id in _bearing_lines.keys():
		if target_id not in _player_contacts:
			_remove_bearing_line(target_id)
			continue
		var detection: Dictionary = _player_contacts[target_id]
		if not detection.get("bearing_only", false):
			_remove_bearing_line(target_id)
			continue
		# Find the detecting player unit's current position
		var detector_pos: Vector2 = Vector2.ZERO
		for uid in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[uid]
			if u.get("faction", "") == "player" and target_id in u.get("contacts", {}):
				detector_pos = u["position"]
				break
		var bearing_rad: float = deg_to_rad(detection.get("bearing", 0.0))
		var bearing_dir: Vector2 = Vector2(sin(bearing_rad), -cos(bearing_rad))
		_update_bearing_line(target_id, detector_pos, bearing_dir, detection)

## Draw or update the uncertainty zone for a TMA contact.
## Starts as a wide arc along the bearing line, narrows to ellipse, then tight circle.
func _update_uncertainty_zone(target_id: String, estimated_pos: Vector2,
		uncertainty_radius: float, quality: float) -> void:
	if quality < 0.3:
		# Too low quality -- remove any existing uncertainty zone
		_remove_uncertainty_zone(target_id)
		return

	var zone: Node2D
	if target_id in _uncertainty_visuals:
		zone = _uncertainty_visuals[target_id]
	else:
		zone = Node2D.new()
		zone.name = "UncertaintyZone_" + target_id
		units_layer.add_child(zone)
		_uncertainty_visuals[target_id] = zone

	zone.position = estimated_pos * NM_TO_PX
	zone.visible = true

	# Remove old draw child and create new one
	for child in zone.get_children():
		child.queue_free()

	var draw_node := _UncertaintyDraw.new()
	draw_node.name = "Draw"
	draw_node.uncertainty_radius_px = uncertainty_radius * NM_TO_PX
	draw_node.quality = quality
	zone.add_child(draw_node)

func _remove_uncertainty_zone(target_id: String) -> void:
	if target_id in _uncertainty_visuals:
		_uncertainty_visuals[target_id].queue_free()
		_uncertainty_visuals.erase(target_id)

## TMA solution updated -- draw/update uncertainty zone and optionally show estimated position
func _on_tma_solution_updated(contact_id: String, quality: float,
		estimated_pos: Vector2, uncertainty_radius: float) -> void:
	# Phase 9: TMA solution audio feedback
	AudioManager.play_tma_tone(quality)
	if quality >= 0.3 and estimated_pos != Vector2.ZERO:
		_update_uncertainty_zone(contact_id, estimated_pos, uncertainty_radius, quality)
		# At quality > 0.7, show estimated position marker
		if quality >= 0.7 and contact_id in _player_contacts:
			var detection: Dictionary = _player_contacts[contact_id]
			if detection.get("bearing_only", false):
				# Still bearing-only in detection dict but TMA has a solution
				# Place a dim estimated position marker
				if contact_id in _unit_visuals:
					var visual: Node2D = _unit_visuals[contact_id]
					visual.visible = true
					visual.position = estimated_pos * NM_TO_PX
					visual.modulate.a = clampf(quality, 0.3, 0.8)
	elif quality < 0.3:
		_remove_uncertainty_zone(contact_id)

## TMA contact lost -- clean up bearing line and uncertainty zone
func _on_tma_contact_lost(contact_id: String) -> void:
	_remove_bearing_line(contact_id)
	_remove_uncertainty_zone(contact_id)

## XBT dropped -- show thermal profile result to player
func _on_xbt_dropped(unit_id: String, _position: Vector2, thermal_layer_depth_m: float) -> void:
	AudioManager.play_splash()
	if hud and hud.has_method("show_message"):
		hud.show_message("XBT: THERMAL LAYER AT %dm" % int(thermal_layer_depth_m), 5.0)
	if hud and hud.has_method("set_thermal_layer_known"):
		hud.set_thermal_layer_known(thermal_layer_depth_m)

## Enemy submarine went deep below thermal layer
func _on_submarine_went_deep(unit_id: String, _ordered_depth_m: float) -> void:
	# Only show if player had contact on this sub
	if unit_id in _player_contacts:
		if hud and hud.has_method("show_message"):
			var det: Dictionary = _player_contacts[unit_id]
			var designator: String = det.get("classification", {}).get("designator", "CONTACT")
			hud.show_message("%s: TARGET GOING DEEP" % designator, 3.0)

# ---------------------------------------------------------------------------
# Signal handlers -- sonobuoys (Phase 7)
# ---------------------------------------------------------------------------

func _on_sonobuoy_deployed(buoy_id: String, position: Vector2, _faction: String) -> void:
	AudioManager.play_sonobuoy_drop()
	# Create a visual marker for the sonobuoy on the map
	var visual := _SonobuoyVisual.new()
	visual.name = "Sonobuoy_" + buoy_id
	visual.buoy_id = buoy_id
	visual.position = position * NM_TO_PX
	units_layer.add_child(visual)
	_sonobuoy_visuals[buoy_id] = visual

func _on_sonobuoy_contact(buoy_id: String, target_id: String, bearing_deg: float, _snr: float) -> void:
	# Draw a bearing line from the sonobuoy position toward the contact
	if buoy_id not in _sonobuoy_visuals:
		return
	if buoy_id not in SimulationWorld.sonobuoys:
		return

	var buoy: Dictionary = SimulationWorld.sonobuoys[buoy_id]
	var buoy_pos: Vector2 = buoy["position"]
	var bearing_rad: float = deg_to_rad(bearing_deg)
	var bearing_dir: Vector2 = Vector2(sin(bearing_rad), cos(bearing_rad))

	var line_key: String = "%s:%s" % [buoy_id, target_id]
	var line: Line2D
	if line_key in _sonobuoy_bearing_lines:
		line = _sonobuoy_bearing_lines[line_key]
	else:
		line = Line2D.new()
		line.name = "BuoyBrg_" + line_key
		line.width = 1.0
		line.default_color = Color(0.2, 1.0, 0.4, 0.4)  # Green, semi-transparent
		units_layer.add_child(line)
		_sonobuoy_bearing_lines[line_key] = line

	var start_px: Vector2 = buoy_pos * NM_TO_PX
	var end_px: Vector2 = (buoy_pos + bearing_dir * 50.0) * NM_TO_PX
	line.clear_points()
	line.add_point(start_px)
	line.add_point(end_px)
	line.visible = true

	# Update sonobuoy visual to show contact state (yellow)
	var visual: Node2D = _sonobuoy_visuals.get(buoy_id)
	if visual and visual is _SonobuoyVisual:
		visual.has_contact = true
		visual.queue_redraw()

func _on_sonobuoy_dicass_contact(buoy_id: String, _target_id: String, bearing_deg: float, range_nm: float, _snr: float) -> void:
	# DICASS contact: show range ring on buoy and bearing+range line
	if buoy_id in _sonobuoy_visuals and _sonobuoy_visuals[buoy_id] is _SonobuoyVisual:
		var visual: _SonobuoyVisual = _sonobuoy_visuals[buoy_id]
		visual.has_contact = true
		visual.dicass_range_nm = range_nm
		visual.queue_redraw()

	if hud and hud.has_method("show_message"):
		hud.show_message("DICASS %s: CONTACT BRG %03d RNG %.1fNM" % [buoy_id, int(bearing_deg), range_nm], 3.0)

func _on_sonobuoy_dicass_alert(sub_id: String, buoy_id: String, bearing_to_buoy: float) -> void:
	# A submarine was alerted by a DICASS ping
	# If the player deployed the buoy, warn that the target may evade
	if buoy_id in SimulationWorld.sonobuoys:
		var buoy: Dictionary = SimulationWorld.sonobuoys[buoy_id]
		if buoy["faction"] == "player":
			if hud and hud.has_method("show_message"):
				hud.show_message("DICASS PING MAY HAVE ALERTED TARGET", 2.0)

func _on_sonobuoy_expired(buoy_id: String) -> void:
	# Remove the visual marker for the expired sonobuoy
	if buoy_id in _sonobuoy_visuals:
		_sonobuoy_visuals[buoy_id].queue_free()
		_sonobuoy_visuals.erase(buoy_id)
	# Remove any bearing lines from this buoy
	var keys_to_remove: Array = []
	for line_key in _sonobuoy_bearing_lines:
		if line_key.begins_with(buoy_id + ":"):
			keys_to_remove.append(line_key)
	for key in keys_to_remove:
		_sonobuoy_bearing_lines[key].queue_free()
		_sonobuoy_bearing_lines.erase(key)

# ---------------------------------------------------------------------------
# Signal handlers -- Phase 5 (EMCON, Counter-Detection, ESM)
# ---------------------------------------------------------------------------

func _on_emcon_state_changed(unit_id: String, _old_state: int, new_state: int) -> void:
	if unit_id in SimulationWorld.units and SimulationWorld.units[unit_id]["faction"] == "player":
		var state_names := {0: "ALPHA", 1: "BRAVO", 2: "CHARLIE", 3: "DELTA"}
		var name: String = state_names.get(new_state, "???")
		if hud and hud.has_method("show_message"):
			hud.show_message("EMCON %s" % name, 2.0)
		AudioManager.play_emcon_change()

func _on_counter_detection_event(detector_id: String, emitter_id: String, bearing: float) -> void:
	if emitter_id in SimulationWorld.units and SimulationWorld.units[emitter_id]["faction"] == "player":
		if hud and hud.has_method("show_alert"):
			hud.show_alert("COUNTER-DETECTION: ENEMY HOLDS BEARING ON US", 3.0)
	if detector_id in SimulationWorld.units and SimulationWorld.units[detector_id]["faction"] == "player":
		if hud and hud.has_method("show_message"):
			hud.show_message("ACTIVE SONAR INTERCEPT BRG %03d" % int(bearing), 2.0)

func _on_esm_contact_detected(detector_id: String, _emitter_id: String, bearing: float, radar_type: String) -> void:
	if detector_id in SimulationWorld.units and SimulationWorld.units[detector_id]["faction"] == "player":
		if hud and hud.has_method("show_message"):
			hud.show_message("ESM: %s RADAR BRG %03d" % [radar_type.to_upper(), int(bearing)], 2.0)

# ---------------------------------------------------------------------------
# Signal handlers -- Phase 8 (Weapons lifecycle)
# ---------------------------------------------------------------------------

func _on_torpedo_launched(weapon_id: String, shooter_id: String) -> void:
	var is_player: bool = SimulationWorld.units.get(shooter_id, {}).get("faction", "") == "player"
	AudioManager.play_torpedo_run("own" if is_player else "incoming")

func _on_weapon_impact(weapon_id: String, target_id: String, hit: bool) -> void:
	if hit:
		AudioManager.play_torpedo_impact()
		AudioManager.stop_torpedo_run()

# ---------------------------------------------------------------------------
# Signal handlers -- Phase 10 (ROE, classification, crisis temp)
# ---------------------------------------------------------------------------

func _on_roe_changed(new_state: int, _old_state: int) -> void:
	var roe_names := {0: "WEAPONS TIGHT", 1: "WEAPONS HOLD", 2: "WEAPONS FREE"}
	var name: String = roe_names.get(new_state, "???")
	if hud and hud.has_method("show_alert"):
		hud.show_alert("ROE: %s" % name, 4.0)

func _on_roe_blocked(shooter_id: String, target_id: String, reason: String) -> void:
	if shooter_id in SimulationWorld.units and SimulationWorld.units[shooter_id]["faction"] == "player":
		if hud and hud.has_method("show_alert"):
			hud.show_alert(reason, 3.0)

func _on_contact_classification_changed(target_id: String, new_level: int, _old_level: int) -> void:
	var level_names := {0: "UNKNOWN", 1: "SUSPECT", 2: "PROBABLE HOSTILE", 3: "CERTAIN HOSTILE"}
	if target_id in _player_contacts:
		var det: Dictionary = _player_contacts[target_id]
		var designator: String = det.get("classification", {}).get("designator", target_id)
		if hud and hud.has_method("show_message"):
			hud.show_message("%s: %s" % [designator, level_names.get(new_level, "???")], 2.0)

# ---------------------------------------------------------------------------
# Signal handlers -- Phase 8 (kill confirmation, wire guidance, countermeasures)
# ---------------------------------------------------------------------------

func _on_kill_confirmed(target_id: String) -> void:
	var kill_status: String = "DESTROYED"
	if target_id in SimulationWorld.units:
		var status: String = SimulationWorld.units[target_id].get("kill_status", "confirmed")
		if status == "probable":
			kill_status = "PROBABLE KILL"
	var target_name: String = target_id
	if target_id in _player_contacts:
		target_name = _player_contacts[target_id].get("classification", {}).get("designator", target_id)
	if hud and hud.has_method("show_alert"):
		hud.show_alert("%s: %s" % [target_name, kill_status], 5.0)

func _on_wire_cut(weapon_id: String) -> void:
	# Notify player that wire guidance has been lost
	if hud and hud.has_method("show_message"):
		hud.show_message("WIRE CUT: %s" % weapon_id, 3.0)

func _on_countermeasure_deployed(unit_id: String, cm_type: String) -> void:
	# Show countermeasure status for player units
	if unit_id in SimulationWorld.units and SimulationWorld.units[unit_id]["faction"] == "player":
		var cm_name: String = "NIXIE" if cm_type == "nixie" else "NOISEMAKER"
		if hud and hud.has_method("show_message"):
			hud.show_message("%s DEPLOYED" % cm_name, 2.0)

# ---------------------------------------------------------------------------
# Inner class: uncertainty zone draw node
# ---------------------------------------------------------------------------
class _UncertaintyDraw extends Node2D:
	var uncertainty_radius_px: float = 100.0
	var quality: float = 0.0

	func _draw() -> void:
		# Color: starts amber/transparent, becomes green/opaque as quality improves
		var t: float = clampf((quality - 0.3) / 0.7, 0.0, 1.0)
		var fill_color := Color(
			lerpf(1.0, 0.2, t),
			lerpf(0.5, 0.8, t),
			lerpf(0.1, 0.3, t),
			lerpf(0.08, 0.12, t)
		)
		var border_color := Color(
			lerpf(1.0, 0.3, t),
			lerpf(0.6, 1.0, t),
			lerpf(0.2, 0.4, t),
			lerpf(0.3, 0.6, t)
		)

		if quality < 0.6:
			# Low quality: draw wide arc (fan shape)
			var arc_points: int = 24
			var half_angle: float = lerpf(0.8, 0.3, clampf(quality / 0.6, 0.0, 1.0))  # radians
			var polygon: PackedVector2Array = PackedVector2Array()
			polygon.append(Vector2.ZERO)
			for i in range(arc_points + 1):
				var angle: float = -half_angle + (2.0 * half_angle * float(i) / float(arc_points))
				polygon.append(Vector2(sin(angle), -cos(angle)) * uncertainty_radius_px)
			polygon.append(Vector2.ZERO)
			draw_colored_polygon(polygon, fill_color)
			for i in range(1, polygon.size() - 1):
				draw_line(polygon[i - 1], polygon[i], border_color, 1.0)
		else:
			# Higher quality: draw ellipse/circle
			draw_circle(Vector2.ZERO, uncertainty_radius_px, fill_color)
			# Draw border as arc segments
			var segments: int = 32
			for i in range(segments):
				var a1: float = TAU * float(i) / float(segments)
				var a2: float = TAU * float(i + 1) / float(segments)
				draw_line(
					Vector2(cos(a1), sin(a1)) * uncertainty_radius_px,
					Vector2(cos(a2), sin(a2)) * uncertainty_radius_px,
					border_color, 1.0
				)

		# Center cross at quality > 0.7 (estimated position marker)
		if quality >= 0.7:
			var cross_size: float = 6.0
			var cross_color := Color(0.3, 1.0, 0.5, 0.8)
			draw_line(Vector2(-cross_size, 0), Vector2(cross_size, 0), cross_color, 1.5)
			draw_line(Vector2(0, -cross_size), Vector2(0, cross_size), cross_color, 1.5)

# ---------------------------------------------------------------------------
# HUD update
# ---------------------------------------------------------------------------
func _update_hud() -> void:
	if not hud:
		return
	# Update via HUD script methods if available
	if hud.has_method("update_sim_time"):
		hud.update_sim_time(SimulationWorld.sim_time)
	if hud.has_method("update_selected_unit") and _selected_unit_id != "":
		var u: Dictionary = SimulationWorld.units.get(_selected_unit_id, {})
		if not u.is_empty():
			# Push armed weapon to HUD for the > indicator
			if hud.has_method("set_armed_weapon"):
				hud.set_armed_weapon(_selected_weapon_id)
			hud.update_selected_unit(u)
			# Item 12: show weapons HOT for selected unit
			if hud.has_method("update_weapons_hot"):
				var hot_names: Array = []
				for wid in SimulationWorld.weapons_in_flight:
					var w: Dictionary = SimulationWorld.weapons_in_flight[wid]
					if w["shooter_id"] == _selected_unit_id and not w["resolved"]:
						hot_names.append(w["data"].get("name", wid))
				hud.update_weapons_hot(hot_names)
			# Item 1: show target designation in unit panel with range/weapon info
			if hud.has_method("update_fire_target"):
				var tgt_name: String = ""
				var tgt_range: float = -1.0
				var wpn_ranges: Array = []
				if _fire_target_id != "" and _fire_target_id in _player_contacts:
					tgt_name = _player_contacts[_fire_target_id].get("classification", {}).get("designator", _fire_target_id)
					if _fire_target_id in SimulationWorld.units:
						tgt_range = u["position"].distance_to(SimulationWorld.units[_fire_target_id]["position"])
						var target: Dictionary = SimulationWorld.units[_fire_target_id]
						for wid in u["weapons_remaining"]:
							var wrec: Dictionary = u["weapons_remaining"][wid]
							var wdata: Dictionary = wrec["data"]
							if wrec["count"] <= 0:
								continue
							if not SimulationWorld.is_weapon_valid_for_target(wdata, target):
								continue
							wpn_ranges.append({"name": wdata.get("name", wid).substr(0, 10), "range": wdata.get("max_range_nm", 50.0)})
				hud.update_fire_target(tgt_name, tgt_range, wpn_ranges)
	_update_route_line()

func _update_route_line() -> void:
	if not _route_line:
		return
	if _selected_unit_id == "" or _selected_unit_id not in SimulationWorld.units:
		_route_line.clear_points()
		return
	var u: Dictionary = SimulationWorld.units[_selected_unit_id]
	if u["faction"] != "player" or not u["is_alive"]:
		_route_line.clear_points()
		return
	var waypoints: Array = u.get("waypoints", [])
	if waypoints.is_empty():
		_route_line.clear_points()
		return
	_route_line.clear_points()
	# Start from current position
	_route_line.add_point(u["position"] * NM_TO_PX)
	for wp in waypoints:
		if wp is Vector2:
			_route_line.add_point(wp * NM_TO_PX)
		elif wp is Array and wp.size() >= 2:
			_route_line.add_point(Vector2(wp[0], wp[1]) * NM_TO_PX)

func _update_selection_visuals() -> void:
	for uid in _unit_visuals:
		var visual: Node2D = _unit_visuals[uid]
		var ring: Node2D = visual.find_child("RangeRing")
		if ring:
			ring.visible = (uid == _selected_unit_id)
		# Fix 11: add/remove pulsing selection indicator on selected unit
		var sel_indicator = visual.find_child("SelectionIndicator")
		if uid == _selected_unit_id:
			if not sel_indicator:
				sel_indicator = _SelectionIndicator.new()
				sel_indicator.name = "SelectionIndicator"
				visual.add_child(sel_indicator)
			sel_indicator.visible = true
		else:
			if sel_indicator:
				sel_indicator.visible = false

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.pressed:
			if event.button_index == MOUSE_BUTTON_LEFT:
				_handle_select(event.global_position)
			elif event.button_index == MOUSE_BUTTON_RIGHT:
				_handle_waypoint(event.global_position, event.shift_pressed)
			elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_zoom_camera(1.1)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_zoom_camera(0.9)

	elif event is InputEventKey and event.pressed:
		# Block gameplay commands during pause/debrief/briefing (UI keys still work below)
		var _gameplay_blocked: bool = SimulationWorld.is_paused or _result_shown
		match event.keycode:
			KEY_F:
				if not _gameplay_blocked:
					_handle_fire_weapon()
			KEY_SPACE:
				# Narrative guard: SPACE does nothing during Dialogic sequences
				if NarrativeDirector.is_playing():
					return
				# Tutorial prompt gate: dismiss tutorial panel on SPACE
				if hud and hud.has_method("has_tutorial_prompt") and hud.has_tutorial_prompt():
					hud.dismiss_tutorial_prompt()
					SimulationWorld.unpause()
					return
				# Item 10: if scenario ended, SPACE restarts
				if SimulationWorld.is_paused and SimulationWorld.tick_count > 0 and _result_shown:
					SimulationWorld.pause()
					get_tree().call_deferred("reload_current_scene")
					return
				# Item 7: if briefing panel exists, dismiss and start the mission
				if hud and hud.has_method("has_briefing") and hud.has_briefing():
					hud.dismiss_briefing()
					SimulationWorld.is_paused = false
					return
				SimulationWorld.toggle_pause()
			KEY_KP_ADD:
				SimulationWorld.set_time_scale(SimulationWorld.time_scale * 2.0)
			KEY_KP_SUBTRACT:
				SimulationWorld.set_time_scale(SimulationWorld.time_scale / 2.0)
			KEY_1:
				SimulationWorld.set_time_scale(1.0)
			KEY_2:
				SimulationWorld.set_time_scale(5.0)
			KEY_3:
				SimulationWorld.set_time_scale(15.0)
			KEY_4:
				SimulationWorld.set_time_scale(30.0)
			KEY_5:
				SimulationWorld.set_time_scale(60.0)
			KEY_R:
				if not _gameplay_blocked and _selected_unit_id != "":
					var u: Dictionary = SimulationWorld.units.get(_selected_unit_id, {})
					var new_radar: bool = not u.get("emitting_radar", false)
					SimulationWorld.set_unit_radar(_selected_unit_id, new_radar)
					# Item 9: radar toggle feedback
					if hud and hud.has_method("show_message"):
						hud.show_message("RADAR: %s" % ("ON" if new_radar else "OFF"), 1.5)
			KEY_S:
				if not _gameplay_blocked and _selected_unit_id != "":
					# Phase 5: cycle active sonar modes: OFF -> QUIET -> FULL_POWER -> OFF
					var current_mode: int = SimulationWorld.get_active_sonar_mode(_selected_unit_id)
					var next_mode: int = (current_mode + 1) % 3
					SimulationWorld.set_active_sonar_mode(_selected_unit_id, next_mode)
					var mode_names := {0: "PASSIVE", 1: "QUIET PING", 2: "FULL POWER"}
					if hud and hud.has_method("show_message"):
						hud.show_message("SONAR: %s" % mode_names.get(next_mode, "???"), 1.5)
					SimulationWorld.set_unit_sonar_active(_selected_unit_id, next_mode > 0)
					if next_mode > 0:
						AudioManager.play_sonar_ping()
			KEY_L:
				# Launch helicopter from selected ship
				if not _gameplay_blocked and _selected_unit_id != "" and _selected_unit_id in SimulationWorld.units:
					var u: Dictionary = SimulationWorld.units[_selected_unit_id]
					var platform: Dictionary = u.get("platform", {})
					if platform.get("helicopter_type", "") != "":
						# Sea state 6+ blocks helicopter operations
						if SimulationWorld.weather_sea_state >= 6:
							if hud and hud.has_method("show_message"):
								hud.show_message("FLIGHT OPS SUSPENDED — SEA STATE %d" % SimulationWorld.weather_sea_state, 3.0)
						else:
							var helo_id: String = SimulationWorld.launch_aircraft(_selected_unit_id)
							if helo_id != "":
								if hud and hud.has_method("show_message"):
									hud.show_message("HELICOPTER LAUNCHED", 2.0)
								AudioManager.play_missile_away()  # Reuse the rising tone for launch
							else:
								if hud and hud.has_method("show_message"):
									hud.show_message("NO HELICOPTER AVAILABLE", 2.0)
					else:
						if hud and hud.has_method("show_message"):
							hud.show_message("NO HELICOPTER ON THIS SHIP", 2.0)
			KEY_V:
				# Phase 2: toggle CRT post-processing overlay
				if not event.echo:
					CRTEffect.enabled = not CRTEffect.enabled
					if hud and hud.has_method("show_message"):
						hud.show_message("CRT MODE: %s" % ("ON" if CRTEffect.enabled else "OFF"), 2.0)
			KEY_M:
				# Toggle tactical plot visibility
				if not event.echo:
					Minimap.enabled = not Minimap.enabled
					if hud and hud.has_method("show_message"):
						hud.show_message("TACTICAL PLOT: %s" % ("ON" if Minimap.enabled else "OFF"), 2.0)
			KEY_E:
				# Phase 5: cycle EMCON state: ALPHA -> BRAVO -> CHARLIE -> DELTA -> ALPHA
				if not _gameplay_blocked and _selected_unit_id != "":
					var current: int = SimulationWorld.get_unit_emcon(_selected_unit_id)
					var next_state: int = (current + 1) % 4
					SimulationWorld.set_unit_emcon(_selected_unit_id, next_state)
			KEY_B:
				# Drop DIFAR (passive) sonobuoy from selected aircraft
				if not _gameplay_blocked and _selected_unit_id != "" and _selected_unit_id in SimulationWorld.units:
					var u: Dictionary = SimulationWorld.units[_selected_unit_id]
					if u.get("is_airborne", false):
						var buoy_id: String = SimulationWorld.deploy_sonobuoy(_selected_unit_id, 0)
						if buoy_id != "":
							var difar_rem: int = u.get("sonobuoys_difar", 0)
							var dicass_rem: int = u.get("sonobuoys_dicass", 0)
							if hud and hud.has_method("show_message"):
								hud.show_message("DIFAR DEPLOYED (P:%d A:%d)" % [difar_rem, dicass_rem], 2.0)
							AudioManager.play_weapon_launch()
						else:
							if hud and hud.has_method("show_message"):
								hud.show_message("NO DIFAR SONOBUOYS AVAILABLE", 2.0)
					else:
						if hud and hud.has_method("show_message"):
							hud.show_message("MUST BE AIRBORNE TO DROP SONOBUOYS", 2.0)
			KEY_N:
				# Drop DICASS (active) sonobuoy from selected aircraft
				if not _gameplay_blocked and _selected_unit_id != "" and _selected_unit_id in SimulationWorld.units:
					var u: Dictionary = SimulationWorld.units[_selected_unit_id]
					if u.get("is_airborne", false):
						var buoy_id: String = SimulationWorld.deploy_sonobuoy(_selected_unit_id, 1)
						if buoy_id != "":
							var difar_rem: int = u.get("sonobuoys_difar", 0)
							var dicass_rem: int = u.get("sonobuoys_dicass", 0)
							if hud and hud.has_method("show_message"):
								hud.show_message("DICASS DEPLOYED (P:%d A:%d)" % [difar_rem, dicass_rem], 2.0)
							AudioManager.play_weapon_launch()
						else:
							if hud and hud.has_method("show_message"):
								hud.show_message("NO DICASS SONOBUOYS AVAILABLE", 2.0)
					else:
						if hud and hud.has_method("show_message"):
							hud.show_message("MUST BE AIRBORNE TO DROP SONOBUOYS", 2.0)
			KEY_T:
				# Drop XBT from selected surface ship
				if not _gameplay_blocked and _selected_unit_id != "" and _selected_unit_id in SimulationWorld.units:
					var u: Dictionary = SimulationWorld.units[_selected_unit_id]
					if u.get("is_airborne", false):
						if hud and hud.has_method("show_message"):
							hud.show_message("AIRCRAFT CANNOT DROP XBT", 2.0)
					elif u["depth_m"] < -5.0:
						if hud and hud.has_method("show_message"):
							hud.show_message("SUBMARINES CANNOT DROP XBT", 2.0)
					else:
						var xbt_remaining: int = u.get("xbt_remaining", 0)
						if xbt_remaining <= 0:
							if hud and hud.has_method("show_message"):
								hud.show_message("NO XBTs REMAINING", 2.0)
						else:
							var success: bool = SimulationWorld.drop_xbt(_selected_unit_id)
							if success:
								AudioManager.play_weapon_launch()
							else:
								if hud and hud.has_method("show_message"):
									hud.show_message("XBT DROP FAILED", 2.0)
			KEY_TAB:
				if not _gameplay_blocked:
					_cycle_player_unit()  # M-6: Tab cycles through player units
			KEY_ESCAPE:
				_handle_escape()  # N-7: Escape to restart/quit
			KEY_W:
				if not _gameplay_blocked:
					_adjust_unit_speed(5.0)
			KEY_X:
				if not _gameplay_blocked:
					_adjust_unit_speed(-5.0)
			KEY_BRACKETLEFT:
				if not _gameplay_blocked:
					_adjust_unit_depth(25.0)
			KEY_BRACKETRIGHT:
				if not _gameplay_blocked:
					_adjust_unit_depth(-25.0)
			KEY_C:
				if not _gameplay_blocked:
					_cycle_weapon()
			KEY_H:
				# Fix 8: recenter camera on centroid of alive player units
				_recenter_camera()
			KEY_F1:
				if hud and hud.has_method("toggle_help"):
					hud.toggle_help()
			KEY_F5:
				# Mid-mission save
				if SimulationWorld.save_game():
					if hud and hud.has_method("show_message"):
						hud.show_message("GAME SAVED", 2.0)
				else:
					if hud and hud.has_method("show_message"):
						hud.show_message("SAVE FAILED", 2.0)
			KEY_F9:
				# Mid-mission load
				if SimulationWorld.load_game():
					if hud and hud.has_method("show_message"):
						hud.show_message("GAME LOADED", 2.0)
				else:
					if hud and hud.has_method("show_message"):
						hud.show_message("NO SAVE FILE FOUND", 2.0)
			KEY_EQUAL:
				_zoom_camera(1.15)
			KEY_MINUS:
				_zoom_camera(0.87)
			KEY_UP:
				_pan_camera(Vector2(0, -40))
			KEY_DOWN:
				_pan_camera(Vector2(0, 40))
			KEY_LEFT:
				_pan_camera(Vector2(-40, 0))
			KEY_RIGHT:
				_pan_camera(Vector2(40, 0))

	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			camera.position -= event.relative / camera.zoom

func _handle_select(screen_pos: Vector2) -> void:
	# Convert screen position to world position
	var world_pos: Vector2 = _screen_to_world(screen_pos)
	var closest_id: String = ""
	var closest_dist: float = 25.0 / camera.zoom.x  # 25px selection radius

	for uid in _unit_visuals:
		var visual: Node2D = _unit_visuals[uid]
		var faction: String = visual.get_meta("faction", "")
		# Can only select player units
		if faction != "player":
			continue
		var dist: float = visual.position.distance_to(world_pos)
		if dist < closest_dist:
			closest_dist = dist
			closest_id = uid

	# Item 1: Target designation -- if click is near a visible enemy contact, designate it
	if closest_id == "":
		# No player unit clicked -- check enemy contacts
		var enemy_closest_id: String = ""
		var enemy_closest_dist: float = 30.0 / camera.zoom.x  # slightly larger radius for contacts
		for uid in _unit_visuals:
			var visual: Node2D = _unit_visuals[uid]
			if not visual.visible:
				continue
			var faction: String = visual.get_meta("faction", "")
			if faction != "enemy":
				continue
			var dist: float = visual.position.distance_to(world_pos)
			if dist < enemy_closest_dist:
				enemy_closest_dist = dist
				enemy_closest_id = uid
		if enemy_closest_id != "":
			_fire_target_id = enemy_closest_id
			fire_target_designated.emit(enemy_closest_id)
			var det: Dictionary = _player_contacts.get(enemy_closest_id, {})
			var designator: String = det.get("classification", {}).get("designator", enemy_closest_id)
			if hud and hud.has_method("show_message"):
				hud.show_message("TARGET: %s" % designator, 2.0)
		else:
			# Clicked empty space -- clear fire target
			_fire_target_id = ""
	else:
		# Selected a player unit -- clear fire target
		_fire_target_id = ""

	if closest_id != "" and closest_id != _selected_unit_id:
		_selected_weapon_id = ""  # Reset weapon selection when switching units
	_selected_unit_id = closest_id if closest_id != "" else _selected_unit_id
	_update_selection_visuals()
	if closest_id != "":
		if hud and hud.has_method("set_selected_unit"):
			hud.set_selected_unit(closest_id)
		unit_selected.emit(closest_id)

func _handle_waypoint(screen_pos: Vector2, shift_held: bool = false) -> void:
	if _selected_unit_id == "":
		return
	if _selected_unit_id not in SimulationWorld.units:
		return  # N-6: guard against destroyed unit
	var world_pos: Vector2 = _screen_to_world(screen_pos)
	var sim_pos: Vector2 = world_pos / NM_TO_PX
	if shift_held:
		# M-5: Shift+RClick adds waypoint to chain
		SimulationWorld.add_unit_waypoint(_selected_unit_id, sim_pos)
	else:
		SimulationWorld.set_unit_waypoint(_selected_unit_id, sim_pos)
	# Item 5: only set speed if unit is stopped; don't override player's carefully set speed
	var current_speed: float = SimulationWorld.units[_selected_unit_id]["speed_kts"]
	if current_speed < 1.0:
		SimulationWorld.set_unit_speed(_selected_unit_id,
			SimulationWorld.units[_selected_unit_id]["max_speed_kts"] * 0.5)

	# Show waypoint marker
	_show_waypoint_marker(world_pos)

func _handle_fire_weapon() -> void:
	if _selected_unit_id == "":
		if hud and hud.has_method("show_message"):
			hud.show_message("No unit selected")
		return

	var shooter: Dictionary = SimulationWorld.units.get(_selected_unit_id, {})
	if shooter.is_empty():
		return

	# Find target: use designated fire target if valid, else nearest enemy
	var best_target: String = _find_fire_target(shooter)
	if best_target == "":
		if hud and hud.has_method("show_message"):
			hud.show_message("No contacts detected")
		return

	var target: Dictionary = SimulationWorld.units[best_target]
	var best_dist: float = shooter["position"].distance_to(target["position"])

	# If a weapon is manually selected, try that weapon first
	if _selected_weapon_id != "" and _selected_weapon_id in shooter["weapons_remaining"]:
		var wrec: Dictionary = shooter["weapons_remaining"][_selected_weapon_id]
		var wdata: Dictionary = wrec["data"]
		if wrec["count"] <= 0:
			# Auto-advance to next weapon when current is depleted
			_cycle_weapon()
			if hud and hud.has_method("show_message"):
				hud.show_message("WINCHESTER %s — switched weapon" % wdata.get("name", _selected_weapon_id))
			return
		if not SimulationWorld.is_weapon_valid_for_target(wdata, target):
			if hud and hud.has_method("show_message"):
				hud.show_message("%s: invalid vs target (C to switch)" % wdata.get("name", _selected_weapon_id))
			return
		if best_dist > wdata.get("max_range_nm", 50.0):
			if hud and hud.has_method("show_message"):
				hud.show_message("%s: target at %dNM, max %dNM" % [
					wdata.get("name", _selected_weapon_id), int(best_dist), int(wdata.get("max_range_nm", 50.0))])
			return
		var wid: String = SimulationWorld.fire_weapon(_selected_unit_id, best_target, _selected_weapon_id)
		if wid != "" and hud and hud.has_method("show_message"):
			hud.show_message("FIRED: %s (%d left)" % [wdata.get("name", _selected_weapon_id), wrec["count"]])
		# ROE violation check: maintain_contact scenario defeats on any weapon fire
		if SimulationWorld._game_over:
			if hud and hud.has_method("show_alert"):
				hud.show_alert("WEAPONS HOLD VIOLATED — MISSION FAILED", 5.0)
		return

	# No weapon selected — auto-select best valid weapon
	var had_valid_weapon: bool = false
	var all_out_of_range: bool = true
	var all_weapons_empty: bool = true
	for weapon_id in shooter["weapons_remaining"]:
		var wrec: Dictionary = shooter["weapons_remaining"][weapon_id]
		var wdata: Dictionary = wrec["data"]
		if not SimulationWorld.is_weapon_valid_for_target(wdata, target):
			continue
		if wrec["count"] <= 0:
			continue
		all_weapons_empty = false
		had_valid_weapon = true
		if best_dist <= wdata.get("max_range_nm", 50.0):
			all_out_of_range = false
			# Auto-select this weapon for future fires
			_selected_weapon_id = weapon_id
			var wid: String = SimulationWorld.fire_weapon(_selected_unit_id, best_target, weapon_id)
			if wid != "" and hud and hud.has_method("show_message"):
				hud.show_message("FIRED: %s (%d left)" % [wdata.get("name", weapon_id), wrec["count"]])
			# ROE violation check: maintain_contact scenario defeats on any weapon fire
			if SimulationWorld._game_over:
				if hud and hud.has_method("show_alert"):
					hud.show_alert("WEAPONS HOLD VIOLATED — MISSION FAILED", 5.0)
			return

	if hud and hud.has_method("show_message"):
		if all_weapons_empty:
			hud.show_message("WEAPONS DEPLETED")
		elif not had_valid_weapon:
			hud.show_message("No valid weapon for target")
		elif all_out_of_range:
			hud.show_message("Target out of range (C to switch weapon)")

func _find_fire_target(shooter: Dictionary) -> String:
	var best_target: String = ""
	var best_dist: float = 99999.0
	# Prefer designated fire target
	if _fire_target_id != "" and _fire_target_id in SimulationWorld.units:
		var ft: Dictionary = SimulationWorld.units[_fire_target_id]
		if ft["is_alive"] and ft.get("faction", "") == "enemy" and _fire_target_id in _player_contacts:
			return _fire_target_id
	# Fall back to nearest enemy contact
	for target_id in _player_contacts:
		if target_id in SimulationWorld.units and SimulationWorld.units[target_id]["is_alive"]:
			if SimulationWorld.units[target_id].get("faction", "") != "enemy":
				continue
			var dist: float = shooter["position"].distance_to(SimulationWorld.units[target_id]["position"])
			if dist < best_dist:
				best_dist = dist
				best_target = target_id
	return best_target

func _cycle_weapon() -> void:
	## C key: cycle through available weapons on selected unit
	if _selected_unit_id == "" or _selected_unit_id not in SimulationWorld.units:
		return
	var shooter: Dictionary = SimulationWorld.units[_selected_unit_id]
	var weapon_ids: Array = []
	for wid in shooter["weapons_remaining"]:
		var wrec: Dictionary = shooter["weapons_remaining"][wid]
		if wrec["count"] > 0:
			weapon_ids.append(wid)
	if weapon_ids.is_empty():
		if hud and hud.has_method("show_message"):
			hud.show_message("WEAPONS DEPLETED")
		return
	# Find current index and advance
	var current_idx: int = weapon_ids.find(_selected_weapon_id)
	var next_idx: int = (current_idx + 1) % weapon_ids.size()
	_selected_weapon_id = weapon_ids[next_idx]
	var wdata: Dictionary = shooter["weapons_remaining"][_selected_weapon_id]["data"]
	var count: int = shooter["weapons_remaining"][_selected_weapon_id]["count"]
	if hud and hud.has_method("show_message"):
		hud.show_message("ARMED: %s (%d) — %dNM max" % [
			wdata.get("name", _selected_weapon_id), count, int(wdata.get("max_range_nm", 50.0))], 2.5)

func _cycle_player_unit() -> void:
	## M-6: Tab key cycles through alive player units and centers camera
	var alive_ids: Array = []
	for uid in _player_unit_ids:
		if uid in SimulationWorld.units and SimulationWorld.units[uid]["is_alive"]:
			alive_ids.append(uid)
	if alive_ids.is_empty():
		return
	_player_cycle_index = (_player_cycle_index + 1) % alive_ids.size()
	var uid: String = alive_ids[_player_cycle_index]
	_selected_unit_id = uid
	_selected_weapon_id = ""  # Reset weapon selection when switching units
	_update_selection_visuals()
	if hud and hud.has_method("set_selected_unit"):
		hud.set_selected_unit(uid)
	# Center camera on selected unit
	if uid in _unit_visuals and camera:
		camera.position = _unit_visuals[uid].position

func _handle_escape() -> void:
	## ESC key: if pause menu visible -> close it; if briefing/tutorial active -> ignore;
	## if unit/target selected -> clear; otherwise -> open pause menu.
	if hud and hud.has_method("is_pause_menu_visible") and hud.is_pause_menu_visible():
		# Pause menu open -- close it and resume
		hud.close_pause_menu()
		SimulationWorld.unpause()
		return
	# Block ESC while briefing or tutorial prompt is active (prevent panel stacking)
	if hud and hud.has_method("has_briefing") and hud.has_briefing():
		return
	if hud and hud.has_method("has_tutorial_prompt") and hud.has_tutorial_prompt():
		return
	if _selected_unit_id != "" or _fire_target_id != "":
		# Something selected -- clear selection/target first
		_selected_unit_id = ""
		_fire_target_id = ""
		_update_selection_visuals()
		if hud and hud.has_method("set_selected_unit"):
			hud.set_selected_unit("")
		if hud and hud.has_method("update_fire_target"):
			hud.update_fire_target("")
		return
	# Nothing selected -- open pause menu
	SimulationWorld.pause()
	if hud and hud.has_method("show_pause_menu"):
		hud.show_pause_menu()

func _adjust_unit_speed(delta_kts: float) -> void:
	## MA-2: W/X speed control for selected unit
	if _selected_unit_id == "" or _selected_unit_id not in SimulationWorld.units:
		return
	var u: Dictionary = SimulationWorld.units[_selected_unit_id]
	if u.get("faction", "") != "player":
		return
	var new_speed: float = clampf(u["speed_kts"] + delta_kts, 0.0, u["max_speed_kts"])
	SimulationWorld.set_unit_speed(_selected_unit_id, new_speed)
	u["ordered_speed_kts"] = new_speed  # EN-2: store ordered speed
	if hud and hud.has_method("show_message"):
		hud.show_message("Speed: %d kts" % int(new_speed), 1.5)

func _adjust_unit_depth(delta_m: float) -> void:
	## MA-3: [/] depth control for submarines only
	if _selected_unit_id == "" or _selected_unit_id not in SimulationWorld.units:
		return
	var u: Dictionary = SimulationWorld.units[_selected_unit_id]
	if u.get("faction", "") != "player":
		return
	# Only works on submarines
	var ptype: String = u["platform"].get("type", "")
	if ptype != "SSN":
		if hud and hud.has_method("show_message"):
			hud.show_message("Depth control: submarines only", 1.5)
		return
	var new_depth: float = clampf(u["ordered_depth_m"] + delta_m, -500.0, 0.0)
	SimulationWorld.set_unit_depth(_selected_unit_id, new_depth)
	if hud and hud.has_method("show_message"):
		if new_depth >= -1.0:
			hud.show_message("Ordered: SURFACE", 1.5)
		else:
			hud.show_message("Ordered depth: %dm" % int(absf(new_depth)), 1.5)

func _recenter_camera() -> void:
	## Fix 8: compute centroid of all alive player units and move camera there
	var centroid := Vector2.ZERO
	var count: int = 0
	for uid in _player_unit_ids:
		if uid in SimulationWorld.units and SimulationWorld.units[uid]["is_alive"]:
			centroid += SimulationWorld.units[uid]["position"] * NM_TO_PX
			count += 1
	if count > 0 and camera:
		centroid /= float(count)
		camera.position = centroid
		camera_recentered.emit()
		if hud and hud.has_method("show_message"):
			hud.show_message("CENTERED", 1.5)

func force_select_unit(unit_id: String) -> void:
	_selected_unit_id = unit_id
	_update_selection_visuals()
	if hud and hud.has_method("set_selected_unit"):
		hud.set_selected_unit(unit_id)
	unit_selected.emit(unit_id)

func _show_waypoint_marker(world_pos: Vector2) -> void:
	# N-5: Show persistent waypoint line from ship to waypoint (replaces fading X)
	# Remove any old waypoint display for this unit
	if _selected_unit_id != "":
		var old_wp = effects_layer.find_child("WP_" + _selected_unit_id, false, false)
		if old_wp:
			old_wp.queue_free()
		var wp_node := _WaypointLine.new()
		wp_node.name = "WP_" + _selected_unit_id
		wp_node.unit_id = _selected_unit_id
		wp_node.nm_to_px = NM_TO_PX
		effects_layer.add_child(wp_node)
		# Fix 10: instantiate click-feedback marker at waypoint position
		var marker := _WaypointMarker.new()
		marker.position = world_pos
		effects_layer.add_child(marker)

func _pan_camera(offset: Vector2) -> void:
	if camera:
		camera.position += offset / camera.zoom

func _zoom_camera(factor: float) -> void:
	camera_zoomed.emit()
	if camera:
		camera.zoom *= factor
		camera.zoom = camera.zoom.clamp(Vector2(0.3, 0.3), Vector2(10.0, 10.0))  # Fix 9: min zoom 0.3

func _screen_to_world(screen_pos: Vector2) -> Vector2:
	# N-10: proper camera transform inverse for correct screen-to-world after pan/zoom
	if camera:
		var canvas_xform: Transform2D = camera.get_canvas_transform()
		return canvas_xform.affine_inverse() * screen_pos
	return screen_pos

# ===========================================================================
# Inner classes -- Modern Tactical Renderer drawing primitives
# ===========================================================================

## NATO symbol drawer
class _NATOSymbol extends Node2D:
	var unit_data: Dictionary = {}
	var is_contact: bool = false
	var detection_data: Dictionary = {}
	var _alpha: float = 1.0

	func _draw() -> void:
		var platform_type: String = unit_data.get("platform", {}).get("type", unit_data.get("type", ""))
		var faction: String = unit_data.get("faction", "")
		var color: Color

		if is_contact:
			color = Color(1.0, 0.6, 0.2, _alpha)  # Orange for unconfirmed contacts
			_draw_contact_symbol(color)
			return

		if faction == "player":
			color = Color(0.3, 0.8, 1.0, _alpha)  # Friendly blue
		elif faction == "enemy":
			color = Color(1.0, 0.3, 0.3, _alpha)  # Hostile red
		else:
			color = Color(0.6, 0.6, 0.6, _alpha)  # Neutral grey

		match platform_type:
			"DD", "DDG", "FFG", "CGN":
				_draw_surface_symbol(color)
			"SSN":
				_draw_sub_symbol(color)
			"HELO", "MPA":
				_draw_air_symbol(color)
			_:
				_draw_surface_symbol(color)

	func _draw_surface_symbol(color: Color) -> void:
		# NATO surface ship: semicircle (flat bottom)
		var points := PackedVector2Array()
		for i in range(0, 181, 10):
			var angle: float = deg_to_rad(float(i) - 90.0)
			points.append(Vector2(cos(angle) * 10.0, sin(angle) * -10.0))
		# Close the bottom
		points.append(Vector2(-10.0, 0.0))
		draw_polyline(points, color, 2.0)
		# Hull line
		draw_line(Vector2(-10.0, 0.0), Vector2(10.0, 0.0), color, 2.0)

	func _draw_sub_symbol(color: Color) -> void:
		# NATO submarine: full circle with bottom line
		draw_arc(Vector2.ZERO, 10.0, 0, TAU, 32, color, 2.0)
		draw_line(Vector2(-12.0, 10.0), Vector2(12.0, 10.0), color, 1.5)

	func _draw_air_symbol(color: Color) -> void:
		# NATO air unit: semicircle (flat top, dome below) + wing lines
		var points := PackedVector2Array()
		for i in range(0, 181, 10):
			var angle: float = deg_to_rad(float(i) + 90.0)
			points.append(Vector2(cos(angle) * 10.0, sin(angle) * 10.0))
		points.append(Vector2(-10.0, 0.0))
		draw_polyline(points, color, 2.0)
		# Top line (flat top of NATO air symbol)
		draw_line(Vector2(-10.0, 0.0), Vector2(10.0, 0.0), color, 2.0)
		# Wing indicators: short diagonal lines extending from body
		draw_line(Vector2(-10.0, 0.0), Vector2(-17.0, -4.0), color, 1.5)
		draw_line(Vector2(10.0, 0.0), Vector2(17.0, -4.0), color, 1.5)

	func _draw_contact_symbol(color: Color) -> void:
		# Unknown contact: diamond shape
		var points := PackedVector2Array([
			Vector2(0, -10), Vector2(10, 0), Vector2(0, 10), Vector2(-10, 0), Vector2(0, -10)
		])
		draw_polyline(points, color, 2.0)
		# Uncertainty indicator: dashed outer diamond
		var confidence: float = detection_data.get("confidence", 0.5)
		if confidence < 0.7:
			var outer := PackedVector2Array([
				Vector2(0, -14), Vector2(14, 0), Vector2(0, 14), Vector2(-14, 0), Vector2(0, -14)
			])
			draw_polyline(outer, Color(color, 0.3), 1.0)

	func set_detected(detected: bool, data: Dictionary) -> void:
		detection_data = data
		_alpha = 1.0 if detected else 0.3
		queue_redraw()

	func update_classification(classification: Dictionary) -> void:
		detection_data["classification"] = classification
		queue_redraw()

	func set_heading(heading_deg: float) -> void:
		# Rotate parent heading line
		var parent: Node2D = get_parent()
		if parent:
			var line: Line2D = parent.find_child("HeadingLine")
			if line:
				var heading_rad: float = deg_to_rad(heading_deg)
				var tip := Vector2(sin(heading_rad), -cos(heading_rad)) * 20.0
				line.points = PackedVector2Array([Vector2.ZERO, tip])

## Range ring drawer
class _RangeRing extends Node2D:
	var radar_range_px: float = 1000.0
	var weapon_range_px: float = 500.0

	func _draw() -> void:
		# Radar range ring (blue, dashed feel via low alpha)
		draw_arc(Vector2.ZERO, radar_range_px, 0, TAU, 64,
			Color(0.3, 0.6, 1.0, 0.15), 1.0)
		# Weapon range ring (yellow)
		draw_arc(Vector2.ZERO, weapon_range_px, 0, TAU, 48,
			Color(1.0, 1.0, 0.3, 0.2), 1.0)

## Weapon in-flight marker
class _WeaponMarker extends Node2D:
	var weapon_type: String = "ASM"
	var guidance: String = ""  # Item 8: guidance type for visual distinction

	func _draw() -> void:
		var color: Color
		# Item 8: ASROC (rocket_acoustic guidance) rendered as white/yellow triangle
		if guidance == "rocket_acoustic":
			color = Color(1.0, 1.0, 0.7)  # White-yellow for ASROC
		else:
			match weapon_type:
				"ASM":
					color = Color(1.0, 0.5, 0.0)
				"torpedo":
					color = Color(0.0, 1.0, 0.5)
				_:
					color = Color(1.0, 1.0, 0.0)
		# Small filled triangle
		var points := PackedVector2Array([
			Vector2(0, -5), Vector2(4, 3), Vector2(-4, 3)
		])
		draw_colored_polygon(points, color)

## Explosion effect (fades out over 2 seconds)
class _ExplosionEffect extends Node2D:
	var _life: float = 0.0
	var _max_life: float = 2.0

	func _process(delta: float) -> void:
		_life += delta
		if _life >= _max_life:
			queue_free()
		else:
			queue_redraw()

	func _draw() -> void:
		var t: float = _life / _max_life
		var radius: float = 10.0 + 30.0 * t
		var alpha: float = 1.0 - t
		draw_circle(Vector2.ZERO, radius, Color(1.0, 0.5, 0.0, alpha * 0.6))
		draw_arc(Vector2.ZERO, radius, 0, TAU, 32, Color(1.0, 0.8, 0.0, alpha), 2.0)

## Waypoint marker (fades out)
class _WaypointMarker extends Node2D:
	var _life: float = 0.0

	func _process(delta: float) -> void:
		_life += delta
		if _life >= 3.0:
			queue_free()
		else:
			queue_redraw()

	func _draw() -> void:
		var alpha: float = clampf(1.0 - _life / 3.0, 0.0, 1.0)
		var color := Color(0.3, 1.0, 0.3, alpha)
		draw_line(Vector2(-6, -6), Vector2(6, 6), color, 1.5)
		draw_line(Vector2(6, -6), Vector2(-6, 6), color, 1.5)
		draw_arc(Vector2.ZERO, 8.0, 0, TAU, 16, color, 1.0)

## N-5: Persistent waypoint line from ship to its waypoint(s)
class _WaypointLine extends Node2D:
	var unit_id: String = ""
	var nm_to_px: float = 10.0

	func _process(_delta: float) -> void:
		if unit_id == "" or unit_id not in SimulationWorld.units:
			queue_free()
			return
		var u: Dictionary = SimulationWorld.units[unit_id]
		if not u["is_alive"] or u["waypoints"].size() == 0:
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		if unit_id == "" or unit_id not in SimulationWorld.units:
			return
		var u: Dictionary = SimulationWorld.units[unit_id]
		if u["waypoints"].size() == 0:
			return
		var ship_pos: Vector2 = u["position"] * nm_to_px
		var color := Color(0.3, 1.0, 0.3, 0.5)
		var prev_pos: Vector2 = ship_pos
		for wp in u["waypoints"]:
			var wp_pos: Vector2 = wp * nm_to_px
			draw_line(prev_pos, wp_pos, color, 1.0)
			# Draw small X at waypoint
			draw_line(wp_pos + Vector2(-4, -4), wp_pos + Vector2(4, 4), color, 1.5)
			draw_line(wp_pos + Vector2(4, -4), wp_pos + Vector2(-4, 4), color, 1.5)
			prev_pos = wp_pos

## Helper attached to unit visuals for method calls
class _UnitVisualHelper extends Node:
	func update_wake(new_pos: Vector2) -> void:
		pass  # Wake trail placeholder for Phase 2

	func set_heading(heading_deg: float) -> void:
		var symbol = get_parent().find_child("Symbol")
		if symbol and symbol.has_method("set_heading"):
			symbol.set_heading(heading_deg)

	func set_detected(detected: bool, data: Dictionary) -> void:
		var symbol = get_parent().find_child("Symbol")
		if symbol and symbol.has_method("set_detected"):
			symbol.set_detected(detected, data)

	func update_classification(classification: Dictionary) -> void:
		var symbol = get_parent().find_child("Symbol")
		if symbol and symbol.has_method("update_classification"):
			symbol.update_classification(classification)

## Phase 7: sonobuoy visual marker on the tactical map
class _SonobuoyVisual extends Node2D:
	var buoy_id: String = ""
	var has_contact: bool = false
	var dicass_range_nm: float = -1.0  # Positive when DICASS has a range fix
	var _pulse_time: float = 0.0
	var _last_has_contact: bool = false
	var _last_battery_bucket: int = -1  # floor(battery_pct * 20), 0-20

	func _process(delta: float) -> void:
		_pulse_time += delta
		# Check if buoy still exists
		if buoy_id != "" and buoy_id not in SimulationWorld.sonobuoys:
			queue_free()
			return
		# Only redraw when visual state actually changes
		var _needs_redraw: bool = false
		if has_contact != _last_has_contact:
			_last_has_contact = has_contact
			_needs_redraw = true
		if buoy_id in SimulationWorld.sonobuoys:
			var buoy: Dictionary = SimulationWorld.sonobuoys[buoy_id]
			var age: float = SimulationWorld.sim_time - buoy["deploy_time"]
			var battery_pct: float = clampf(1.0 - age / buoy["battery_life"], 0.0, 1.0)
			var bucket: int = int(battery_pct * 20.0)
			if bucket != _last_battery_bucket:
				_last_battery_bucket = bucket
				_needs_redraw = true
		if _needs_redraw:
			queue_redraw()

	func _draw() -> void:
		if buoy_id == "" or buoy_id not in SimulationWorld.sonobuoys:
			return
		var buoy: Dictionary = SimulationWorld.sonobuoys[buoy_id]
		var age: float = SimulationWorld.sim_time - buoy["deploy_time"]
		var battery_pct: float = clampf(1.0 - age / buoy["battery_life"], 0.0, 1.0)
		var buoy_type: int = buoy.get("buoy_type", 0)

		# Color: green = active/listening, yellow = contact, dims as battery depletes
		var base_color: Color
		if has_contact:
			base_color = Color(1.0, 1.0, 0.2)  # Yellow: contact
		elif buoy_type == 1:  # DICASS
			base_color = Color(0.3, 0.6, 1.0)  # Blue for active buoys
		else:
			base_color = Color(0.2, 1.0, 0.4)  # Green for passive buoys

		var alpha: float = clampf(battery_pct * 0.8 + 0.2, 0.2, 1.0)
		var color := Color(base_color.r, base_color.g, base_color.b, alpha)

		# Draw sonobuoy icon: small circle with center dot
		draw_circle(Vector2.ZERO, 4.0, Color(color, alpha * 0.3))
		draw_arc(Vector2.ZERO, 4.0, 0, TAU, 16, color, 1.0)
		draw_circle(Vector2.ZERO, 1.5, color)

		# DICASS: draw active ping ring (pulsing)
		if buoy_type == 1:
			var ping_alpha: float = alpha * 0.15 * (0.5 + 0.5 * sin(_pulse_time * 3.0))
			var ring_radius: float = 8.0 * 10.0  # DICASS_BASE_DETECTION_RADIUS * NM_TO_PX
			draw_arc(Vector2.ZERO, ring_radius, 0, TAU, 32, Color(0.3, 0.6, 1.0, ping_alpha), 1.0)

		# Detection radius ring (faint)
		var det_radius: float = 5.0 * 10.0 if buoy_type == 0 else 8.0 * 10.0  # nm * NM_TO_PX
		draw_arc(Vector2.ZERO, det_radius, 0, TAU, 24, Color(color, alpha * 0.1), 0.5)

		# Battery indicator: small arc segment below the buoy
		if battery_pct < 0.9:
			var arc_length: float = TAU * battery_pct
			var arc_color: Color
			if battery_pct > 0.5:
				arc_color = Color(0.2, 1.0, 0.4, alpha * 0.6)
			elif battery_pct > 0.2:
				arc_color = Color(1.0, 1.0, 0.2, alpha * 0.6)
			else:
				arc_color = Color(1.0, 0.3, 0.3, alpha * 0.8)
			draw_arc(Vector2(0, 8), 3.0, -PI / 2.0, -PI / 2.0 + arc_length, 12, arc_color, 1.5)

		# Buoy type label
		var type_str: String = "P" if buoy_type == 0 else "A"
		# Draw type indicator as positioned text would require a Label child,
		# so draw a small distinguishing mark instead
		if buoy_type == 1:
			# Active: small cross inside the circle
			draw_line(Vector2(-2, 0), Vector2(2, 0), color, 1.0)
			draw_line(Vector2(0, -2), Vector2(0, 2), color, 1.0)

## Fix 11: pulsing selection bracket drawn around the selected unit
class _SelectionIndicator extends Node2D:
	var _pulse_time: float = 0.0

	func _process(delta: float) -> void:
		_pulse_time += delta
		queue_redraw()

	func _draw() -> void:
		var alpha: float = 0.5 + 0.4 * sin(_pulse_time * 4.0)
		var color := Color(0.3, 1.0, 0.3, alpha)
		var s: float = 14.0
		var b: float = 6.0  # bracket arm length
		# Top-left bracket
		draw_line(Vector2(-s, -s), Vector2(-s + b, -s), color, 1.5)
		draw_line(Vector2(-s, -s), Vector2(-s, -s + b), color, 1.5)
		# Top-right bracket
		draw_line(Vector2(s, -s), Vector2(s - b, -s), color, 1.5)
		draw_line(Vector2(s, -s), Vector2(s, -s + b), color, 1.5)
		# Bottom-left bracket
		draw_line(Vector2(-s, s), Vector2(-s + b, s), color, 1.5)
		draw_line(Vector2(-s, s), Vector2(-s, s - b), color, 1.5)
		# Bottom-right bracket
		draw_line(Vector2(s, s), Vector2(s - b, s), color, 1.5)
		draw_line(Vector2(s, s), Vector2(s, s - b), color, 1.5)
