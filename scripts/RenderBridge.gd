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
var _player_unit_ids: Array = []  # M-6: ordered list of player unit IDs for Tab cycling
var _player_cycle_index: int = -1
var _result_shown: bool = false  # Item 10: track if result screen is visible
var _lost_contact_timers: Dictionary = {}  # target_id -> ticks remaining for last-known datum

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
func _ready() -> void:
	_connect_signals()
	_setup_camera()

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
		if hud and hud.has_method("flash_new_contact"):
			hud.flash_new_contact()

	_player_contacts[target_id] = detection
	# Item 6: cancel any pending lost-contact timer on re-detection
	_lost_contact_timers.erase(target_id)

	# Show contact marker -- make hidden enemy visuals visible or create contact marker
	if target_id in _unit_visuals:
		var visual: Node2D = _unit_visuals[target_id]
		visual.visible = true
		# Update position from detection estimate (not exact -- fog of war)
		var det_pos: Vector2 = detector_data.get("position", Vector2.ZERO)
		var bearing_rad: float = deg_to_rad(detection.get("bearing", 0.0))
		var range_est: float = detection.get("range_est", 10.0)
		var est_pos: Vector2 = det_pos + Vector2(sin(bearing_rad), cos(bearing_rad)) * range_est
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
		var det_pos: Vector2 = detector_data.get("position", Vector2.ZERO)
		var bearing_rad: float = deg_to_rad(detection.get("bearing", 0.0))
		var range_est: float = detection.get("range_est", 10.0)
		var pos: Vector2 = det_pos + Vector2(sin(bearing_rad), cos(bearing_rad)) * range_est
		contact_visual.position = pos * NM_TO_PX
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
	if hud and hud.has_method("show_scenario_name"):
		hud.show_scenario_name(scenario_name)

func _on_scenario_ended(result: String) -> void:
	_result_shown = true
	if hud and hud.has_method("show_result"):
		hud.show_result(result)

func _on_sim_tick(_tick_number: int, _sim_time: float) -> void:
	_update_hud()
	_update_selection_visuals()
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
		match event.keycode:
			KEY_F:
				_handle_fire_weapon()
			KEY_SPACE:
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
				# Item 7: if briefing panel exists, ONLY dismiss briefing (don't unpause)
				if hud and hud.has_method("has_briefing") and hud.has_briefing():
					hud.dismiss_briefing()
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
				if _selected_unit_id != "":
					var u: Dictionary = SimulationWorld.units.get(_selected_unit_id, {})
					var new_radar: bool = not u.get("emitting_radar", false)
					SimulationWorld.set_unit_radar(_selected_unit_id, new_radar)
					# Item 9: radar toggle feedback
					if hud and hud.has_method("show_message"):
						hud.show_message("RADAR: %s" % ("ON" if new_radar else "OFF"), 1.5)
			KEY_S:
				if _selected_unit_id != "":
					var u: Dictionary = SimulationWorld.units.get(_selected_unit_id, {})
					var new_sonar: bool = not u.get("emitting_sonar_active", false)
					SimulationWorld.set_unit_sonar_active(_selected_unit_id, new_sonar)
					# Item 9: sonar toggle feedback
					if hud and hud.has_method("show_message"):
						hud.show_message("SONAR: %s" % ("ACTIVE" if new_sonar else "PASSIVE"), 1.5)
					# Audio: play sonar ping when switching to active mode
					if new_sonar:
						AudioManager.play_sonar_ping()
			KEY_L:
				# Launch helicopter from selected ship
				if _selected_unit_id != "" and _selected_unit_id in SimulationWorld.units:
					var u: Dictionary = SimulationWorld.units[_selected_unit_id]
					var platform: Dictionary = u.get("platform", {})
					if platform.get("helicopter_type", "") != "":
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
			KEY_TAB:
				_cycle_player_unit()  # M-6: Tab cycles through player units
			KEY_ESCAPE:
				_handle_escape()  # N-7: Escape to restart/quit
			KEY_W:
				# MA-2: increase speed by 5 kts
				_adjust_unit_speed(5.0)
			KEY_X:
				# MA-2: decrease speed by 5 kts
				_adjust_unit_speed(-5.0)
			KEY_BRACKETLEFT:
				# MA-3: go shallower by 25m (only subs)
				_adjust_unit_depth(25.0)
			KEY_BRACKETRIGHT:
				# MA-3: go deeper by 25m (only subs)
				_adjust_unit_depth(-25.0)
			KEY_C:
				# Cycle weapon selection
				_cycle_weapon()
			KEY_H:
				# Fix 8: recenter camera on centroid of alive player units
				_recenter_camera()
			KEY_F1:
				if hud and hud.has_method("toggle_help"):
					hud.toggle_help()
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
	## ESC key: if pause menu visible -> close it; if unit/target selected -> clear;
	## otherwise -> open pause menu.
	if hud and hud.has_method("is_pause_menu_visible") and hud.is_pause_menu_visible():
		# Pause menu open -- close it and resume
		hud.close_pause_menu()
		SimulationWorld.unpause()
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
			"DDG", "FFG", "CGN":
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
