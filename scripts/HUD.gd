extends Control
## HUD -- Tactical display overlay
##
## Shows simulation time, time scale, selected unit info, contact list,
## weapon inventory, scenario status. Pure UI -- reads nothing from SimulationWorld
## directly. Fed by RenderBridge.

@onready var time_label: Label = $TopBar/TimeLabel
@onready var speed_label: Label = $TopBar/SpeedLabel
@onready var pause_label: Label = $TopBar/PauseLabel
@onready var scenario_label: Label = $TopBar/ScenarioLabel
@onready var unit_panel: PanelContainer = $UnitPanel
@onready var unit_name_label: Label = $UnitPanel/VBox/UnitName
@onready var unit_class_label: Label = $UnitPanel/VBox/UnitClass
@onready var unit_speed_label: Label = $UnitPanel/VBox/SpeedInfo
@onready var unit_heading_label: Label = $UnitPanel/VBox/HeadingInfo
@onready var unit_depth_label: Label = $UnitPanel/VBox/DepthInfo
@onready var unit_damage_label: Label = $UnitPanel/VBox/DamageInfo
@onready var weapons_label: Label = $UnitPanel/VBox/WeaponsInfo
@onready var sensors_label: Label = $UnitPanel/VBox/SensorsInfo
@onready var contacts_panel: PanelContainer = $ContactsPanel
@onready var contacts_list: VBoxContainer = $ContactsPanel/VBox/ContactsList
@onready var result_panel: PanelContainer = $ResultPanel
@onready var result_label: Label = $ResultPanel/ResultLabel
@onready var help_label: Label = $HelpPanel/HelpLabel

var _current_time_scale: float = 1.0
var _selected_unit_id: String = ""
var _briefing_panel: PanelContainer = null  # X-1: briefing overlay
var _message_label: Label = null  # BL-2: transient message display
var _message_timer: float = 0.0
var _alert_label: Label = null  # EN-1: torpedo alert display
var _alert_timer: float = 0.0
var _time_limit: float = 0.0  # Item 4: mission time limit in seconds
var _weapons_hot_label: Label = null  # Item 12: weapons in-flight display
var _fire_target_label: Label = null  # Item 1: designated fire target display
var _armed_weapon_id: String = ""  # Currently armed weapon (shown with > marker)
var _tutorial_panel: PanelContainer = null  # Tutorial prompt overlay
var _tutorial_pause_gate: bool = false  # Whether current tutorial prompt requires SPACE
var _help_expanded: bool = false
var _pause_menu: PanelContainer = null  # Pause menu overlay
var _campaign_mission: int = 0  # Current campaign mission number (1-based), 0 = not in campaign
var _campaign_total: int = 0  # Total campaign missions
var _campaign_name: String = ""  # Current mission name for campaign header
var _tracking_target_seconds: float = 0.0  # Required contact time for maintain_contact

func _ready() -> void:
	unit_panel.visible = false
	result_panel.visible = false
	_update_help_text()
	SimulationWorld.sim_tick.connect(_on_sim_tick)
	# All HUD controls pass mouse events through to the tactical map
	_set_mouse_passthrough(self)

func _on_sim_tick(_tick: int, _time: float) -> void:
	_refresh_contacts()

func _process(delta: float) -> void:
	if pause_label:
		pause_label.visible = SimulationWorld.is_paused
		pause_label.text = "PAUSED" if SimulationWorld.is_paused else ""
	# X-8: always keep speed label visible even when paused
	if speed_label:
		speed_label.visible = true
	# BL-2: transient message countdown
	if _message_label and _message_timer > 0.0:
		_message_timer -= delta
		if _message_timer <= 0.0:
			_message_label.queue_free()
			_message_label = null
	# EN-1: torpedo alert countdown
	if _alert_label and _alert_timer > 0.0:
		_alert_timer -= delta
		# Flash effect for alerts
		if _alert_label:
			_alert_label.visible = fmod(_alert_timer, 0.6) > 0.3
		if _alert_timer <= 0.0:
			_alert_label.queue_free()
			_alert_label = null

# ---------------------------------------------------------------------------
# Public methods called by RenderBridge
# ---------------------------------------------------------------------------
func show_scenario_name(scenario_name: String) -> void:
	if scenario_label:
		if _campaign_mission > 0:
			scenario_label.text = "MISSION %d OF %d -- %s" % [_campaign_mission, _campaign_total, scenario_name.to_upper()]
		else:
			scenario_label.text = scenario_name

## Set campaign info for mission header display. Called from Main.gd.
func set_campaign_info(mission_num: int, total: int, mission_name: String) -> void:
	_campaign_mission = mission_num
	_campaign_total = total
	_campaign_name = mission_name
	# Update scenario label immediately if it exists
	if scenario_label:
		scenario_label.text = "MISSION %d OF %d -- %s" % [mission_num, total, mission_name.to_upper()]

func show_result(result: String) -> void:
	if result_panel and result_label:
		result_panel.visible = true
		# Build performance summary
		var elapsed: float = SimulationWorld.sim_time
		var e_hours: int = int(elapsed) / 3600
		var e_minutes: int = (int(elapsed) % 3600) / 60
		var e_seconds: int = int(elapsed) % 60
		var elapsed_str: String = "%02d:%02d:%02d" % [e_hours, e_minutes, e_seconds]
		var player_total: int = 0
		var player_lost: int = 0
		var lost_names: Array = []
		for uid in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[uid]
			if u.get("faction", "") == "player":
				player_total += 1
				if not u["is_alive"]:
					player_lost += 1
					var ship_name: String = u.get("name", uid)
					var displacement: float = u.get("platform", {}).get("displacement_tons", 4000.0)
					var crew_est: int = int(displacement / 20.0)
					lost_names.append("%s (%d crew)" % [ship_name, crew_est])
		var stats: String = "\n\n%s elapsed. %d of %d assets lost." % [elapsed_str, player_lost, player_total]
		# Campaign: list lost ships with crew estimates
		if _campaign_mission > 0 and not lost_names.is_empty():
			stats += "\n"
			for ln in lost_names:
				stats += "\n  %s" % ln
		# Item 15: append score if ScoreManager is tracking
		var score_text: String = ""
		if ScoreManager.is_tracking:
			var time_limit: float = SimulationWorld.scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
			var score_data: Dictionary = ScoreManager.compute_score(SimulationWorld.sim_time, time_limit)
			score_text = "\n\nGRADE: %s    SCORE: %d\nKills: %d  Losses: %d  Weapons: %d" % [
				score_data["grade"], score_data["score"],
				score_data["kills"], score_data["losses"], score_data["weapons_fired"]]
			ScoreManager.stop_tracking()
		# Campaign vs standalone hint
		var restart_hint: String
		if _campaign_mission > 0:
			restart_hint = "\n\n[ SPACE to continue to next mission ]"
		else:
			restart_hint = "\n\n[ SPACE to restart ]"
		# Campaign mission header
		var campaign_header: String = ""
		if _campaign_mission > 0:
			campaign_header = "MISSION %d OF %d COMPLETE\n\n" % [_campaign_mission, _campaign_total]
		match result:
			"victory":
				result_label.text = campaign_header + "THREATS NEUTRALIZED" + stats + score_text + restart_hint
				result_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
			"defeat":
				result_label.text = campaign_header + "TASK FORCE LOST" + stats + score_text + restart_hint
				result_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			"draw":
				result_label.text = campaign_header + "CONTACTS ESCAPED" + stats + score_text + restart_hint
				result_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
			_:
				result_label.text = campaign_header + "MISSION ENDED\n" + result + stats + score_text + restart_hint

## Show campaign complete screen with full debrief.
func show_campaign_complete(history: Array) -> void:
	if not result_panel or not result_label:
		return
	result_panel.visible = true

	var text: String = "CAMPAIGN COMPLETE\nTHE AUTUMN WATCH\n"
	text += "\n" + "-".repeat(40) + "\n"

	# Grade values for averaging
	var grade_values := {"S": 6, "A": 5, "B": 4, "C": 3, "D": 2, "F": 1}
	var grade_sum: int = 0
	var total_losses: int = 0

	for entry in history:
		var mission_idx: int = entry.get("mission_index", 0)
		var mission_result: String = entry.get("result", "unknown")
		var grade: String = entry.get("grade", "?")
		var score: int = entry.get("score", 0)
		var losses: Array = entry.get("losses", [])

		var result_str: String = mission_result.to_upper()
		text += "\n  MISSION %d:  %s  GRADE: %s  SCORE: %d" % [mission_idx + 1, result_str, grade, score]
		if not losses.is_empty():
			text += "  (%d lost)" % losses.size()
			total_losses += losses.size()

		grade_sum += grade_values.get(grade, 1)

	text += "\n\n" + "-".repeat(40)

	# Overall campaign grade
	if history.size() > 0:
		var avg_grade_val: float = float(grade_sum) / float(history.size())
		var overall_grade: String = "F"
		if avg_grade_val >= 5.5:
			overall_grade = "S"
		elif avg_grade_val >= 4.5:
			overall_grade = "A"
		elif avg_grade_val >= 3.5:
			overall_grade = "B"
		elif avg_grade_val >= 2.5:
			overall_grade = "C"
		elif avg_grade_val >= 1.5:
			overall_grade = "D"
		text += "\n\nOVERALL GRADE: %s" % overall_grade
		text += "\nTOTAL SHIPS LOST: %d" % total_losses

	# Lost ships from CampaignManager
	var lost_ships: Array = CampaignManager.get_lost_ships()
	if not lost_ships.is_empty():
		text += "\n"
		for ship in lost_ships:
			var ship_name: String = ship.get("name", "Unknown")
			var lost_at: int = ship.get("lost_mission", 0) + 1
			text += "\n  %s -- lost mission %d" % [ship_name, lost_at]

	text += "\n\n[ SPACE to return to mission select ]"

	result_label.text = text
	result_label.add_theme_color_override("font_color", Color(0.6, 0.8, 1.0))

func update_time_scale(new_scale: float) -> void:
	_current_time_scale = new_scale
	if speed_label:
		if new_scale < 1.0:
			speed_label.text = "x%.1f" % new_scale
		else:
			speed_label.text = "x%d" % int(new_scale)

func update_sim_time(sim_time: float) -> void:
	if time_label:
		var hours: int = int(sim_time) / 3600
		var minutes: int = (int(sim_time) % 3600) / 60
		var seconds: int = int(sim_time) % 60
		var time_text: String = "%02d:%02d:%02d" % [hours, minutes, seconds]
		# Item 4: show remaining time if time limit is set
		if _time_limit > 0.0:
			var remaining: float = maxf(_time_limit - sim_time, 0.0)
			var r_hours: int = int(remaining) / 3600
			var r_minutes: int = (int(remaining) % 3600) / 60
			var r_seconds: int = int(remaining) % 60
			time_text += "  [%02d:%02d:%02d left]" % [r_hours, r_minutes, r_seconds]
			# Color coding: yellow below 900s (15min), red below 300s (5min)
			if remaining < 300.0:
				time_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			elif remaining < 900.0:
				time_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
			else:
				time_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
		time_label.text = time_text

## Item 4: set the mission time limit (called from Main.gd)
func set_time_limit(seconds: float) -> void:
	_time_limit = seconds

## Set the tracking target for maintain_contact missions (called from Main.gd)
func set_tracking_target(seconds: float) -> void:
	_tracking_target_seconds = seconds

## Update tracking progress display for maintain_contact missions
func update_tracking_progress(accumulated: float, all_tracked: bool) -> void:
	if _tracking_target_seconds <= 0.0:
		return
	# Show tracking status in the top bar area
	var pct: int = int((accumulated / _tracking_target_seconds) * 100.0)
	pct = clampi(pct, 0, 100)
	var status_text: String
	if all_tracked:
		status_text = "TRACKING: %d%% [ALL CONTACTS HELD]" % pct
	else:
		status_text = "TRACKING: %d%% [CONTACT LOST - DEGRADING]" % pct
	# Reuse the scenario_label or add text to it
	if scenario_label:
		var base_text: String = ""
		if _campaign_mission > 0:
			base_text = "MISSION %d OF %d -- %s" % [_campaign_mission, _campaign_total, _campaign_name.to_upper()]
		scenario_label.text = base_text + "    " + status_text if base_text != "" else status_text
		# Color: green when tracking, amber when degrading
		if all_tracked:
			scenario_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
		else:
			scenario_label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))

func set_selected_unit(unit_id: String) -> void:
	_selected_unit_id = unit_id
	unit_panel.visible = (unit_id != "")

func update_selected_unit(u: Dictionary) -> void:
	if not unit_panel.visible:
		return

	if unit_name_label:
		unit_name_label.text = u.get("name", "Unknown")
	if unit_class_label:
		unit_class_label.text = u.get("platform", {}).get("class_name", "")
	if unit_speed_label:
		unit_speed_label.text = "SPD: %.0f kts" % u.get("speed_kts", 0.0)
	if unit_heading_label:
		unit_heading_label.text = "HDG: %03d" % int(u.get("heading", 0.0))
	if unit_depth_label:
		# Fix 12: hide depth label entirely for non-submarine units
		var platform_type: String = u.get("platform", {}).get("type", "")
		if platform_type != "SSN":
			unit_depth_label.visible = false
		else:
			var depth: float = u.get("depth_m", 0.0)
			if depth < -1.0:
				unit_depth_label.text = "DEPTH: %dm" % int(abs(depth))
			else:
				unit_depth_label.text = "SURFACE"
			unit_depth_label.visible = true
	if unit_damage_label:
		var dmg: float = u.get("damage", 0.0)
		if dmg > 0.0:
			unit_damage_label.text = "DMG: %d%%" % int(dmg * 100)
			unit_damage_label.add_theme_color_override("font_color",
				Color(1.0, 0.3, 0.3) if dmg > 0.5 else Color(1.0, 1.0, 0.3))
			unit_damage_label.visible = true
		else:
			unit_damage_label.visible = false

	# Weapons inventory with armed indicator
	if weapons_label:
		var weapon_text: String = "WEAPONS (C to switch):\n"
		var wrem: Dictionary = u.get("weapons_remaining", {})
		for wid in wrem:
			var marker: String = ">" if wid == _armed_weapon_id else " "
			weapon_text += " %s %s: %d\n" % [marker, wrem[wid]["data"].get("name", wid), wrem[wid]["count"]]
		weapons_label.text = weapon_text.strip_edges()

	# Sensor status
	if sensors_label:
		var sensor_text: String = "SENSORS:\n"
		if u.get("emitting_radar", false):
			sensor_text += "  RADAR: ON\n"
		else:
			sensor_text += "  RADAR: OFF\n"
		if u.get("emitting_sonar_active", false):
			sensor_text += "  SONAR: ACTIVE\n"
		else:
			sensor_text += "  SONAR: PASSIVE\n"
		sensors_label.text = sensor_text.strip_edges()

	# Helicopter status for ships that carry them
	var platform: Dictionary = u.get("platform", {})
	if platform.get("helicopter_type", "") != "":
		var helo_on_deck: int = 0
		var helo_airborne: int = 0
		for uid in SimulationWorld.units:
			var hu: Dictionary = SimulationWorld.units[uid]
			if hu.get("base_unit_id", "") == _selected_unit_id and hu["is_alive"]:
				if hu.get("is_airborne", false):
					helo_airborne += 1
				else:
					helo_on_deck += 1
		if sensors_label:
			sensors_label.text += "\n  HELO: %d deck / %d airborne (L to launch)" % [helo_on_deck, helo_airborne]

func _refresh_contacts() -> void:
	if not contacts_list:
		return

	# Build from player unit contacts -- track which unit reports best confidence
	var all_contacts: Dictionary = {}  # tid -> detection dict
	var reporting_unit: Dictionary = {}  # tid -> reporter unit name (abbreviated)
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if u.get("faction", "") != "player":
			continue
		for tid in u.get("contacts", {}):
			if tid not in all_contacts or u["contacts"][tid].get("confidence", 0.0) > all_contacts[tid].get("confidence", 0.0):
				all_contacts[tid] = u["contacts"][tid]
				# MA-4: track reporting unit name (first 4 chars)
				var rname: String = u.get("name", uid)
				reporting_unit[tid] = rname.substr(0, 4).to_upper()

	# Fix 14: build the desired text lines first, then update labels in-place
	var lines: Array[String] = []

	# MI-4: show "No contacts" placeholder when empty
	if all_contacts.is_empty():
		lines.append("AREA CLEAR — NO CONTACTS")
	else:
		for tid in all_contacts:
			var det: Dictionary = all_contacts[tid]
			var classification: Dictionary = det.get("classification", {})
			var designator: String = classification.get("designator", "UNKNOWN")
			var conf_pct: int = int(det.get("confidence", 0.0) * 100)
			var bearing: int = int(det.get("bearing", 0.0))
			var method: String = det.get("method", "?")
			# Item 11: abbreviate method to 3 chars
			var method_abbr: String
			match method:
				"sonar_passive":
					method_abbr = "PSV"
				"sonar_active":
					method_abbr = "ACT"
				"radar":
					method_abbr = "RAD"
				"esm":
					method_abbr = "ESM"
				"sonar_intercept":
					method_abbr = "INT"
				_:
					method_abbr = method.substr(0, 3).to_upper()
			# Item 11: cap reporter name to 4 chars
			var reporter: String = reporting_unit.get(tid, "????")
			# EN-3: include range estimate (or bearing-only if no range fix)
			var range_est: float = det.get("range_est", 0.0)
			var is_bearing_only: bool = det.get("bearing_only", false)
			var tma_progress: float = det.get("tma_progress", 0.0)
			if is_bearing_only:
				if tma_progress > 0.0:
					lines.append("%s %s %03d BRG ONLY %s %d%% TMA:%d%%" % [reporter, designator, bearing, method_abbr, conf_pct, int(tma_progress * 100)])
				else:
					lines.append("%s %s %03d BRG ONLY %s %d%%" % [reporter, designator, bearing, method_abbr, conf_pct])
			else:
				lines.append("%s %s %03d ~%dNM %s %d%%" % [reporter, designator, bearing, int(range_est), method_abbr, conf_pct])

	# Fix 14: update existing label nodes in-place; add/remove only as needed
	var existing: Array = contacts_list.get_children()
	for i in range(lines.size()):
		if i < existing.size():
			# Reuse existing label
			existing[i].text = lines[i]
			if all_contacts.is_empty():
				existing[i].add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			else:
				existing[i].add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
		else:
			# Need a new label
			var label := Label.new()
			label.text = lines[i]
			label.add_theme_font_size_override("font_size", 11)
			if all_contacts.is_empty():
				label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			else:
				label.add_theme_color_override("font_color", Color(1.0, 0.6, 0.2))
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			contacts_list.add_child(label)
	# Remove excess labels
	while contacts_list.get_child_count() > lines.size():
		var excess = contacts_list.get_child(contacts_list.get_child_count() - 1)
		contacts_list.remove_child(excess)
		excess.queue_free()

func _set_mouse_passthrough(node: Node) -> void:
	if node is Control:
		node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_set_mouse_passthrough(child)

func _update_help_text() -> void:
	if help_label:
		help_label.text = "F1 — Controls"

func toggle_help() -> void:
	_help_expanded = not _help_expanded
	if help_label:
		if _help_expanded:
			help_label.text = "LClick: Select / Designate | RClick: Waypoint\nF: Fire | C: Cycle Weapon | Tab: Cycle Units\nW/X: Speed +/- | [/]: Depth (subs)\nR: Radar | S: Sonar | L: Launch Helo\nH: Center Camera | +/-: Zoom | Arrows: Pan\nSPACE: Pause | 1-5: Time Scale | Esc: Menu"
		else:
			help_label.text = "F1 — Controls"

## X-1: Show briefing text in a centered panel. Press any key to dismiss.
func show_briefing(text: String) -> void:
	_briefing_panel = PanelContainer.new()
	_briefing_panel.name = "BriefingPanel"
	# Center on screen
	_briefing_panel.anchors_preset = Control.PRESET_CENTER
	_briefing_panel.anchor_left = 0.5
	_briefing_panel.anchor_top = 0.5
	_briefing_panel.anchor_right = 0.5
	_briefing_panel.anchor_bottom = 0.5
	_briefing_panel.offset_left = -300.0
	_briefing_panel.offset_top = -200.0
	_briefing_panel.offset_right = 300.0
	_briefing_panel.offset_bottom = 200.0
	_briefing_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.12, 0.95)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.25, 0.55, 0.85, 0.8)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 20.0
	style.content_margin_top = 20.0
	style.content_margin_right = 20.0
	style.content_margin_bottom = 20.0
	_briefing_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.layout_mode = 1
	_briefing_panel.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = "OPERATIONAL BRIEFING"
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_lbl.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title_lbl)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	vbox.add_child(spacer)

	var body_lbl := Label.new()
	body_lbl.text = text
	body_lbl.add_theme_font_size_override("font_size", 13)
	body_lbl.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	body_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(body_lbl)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 15)
	vbox.add_child(spacer2)

	var hint_lbl := Label.new()
	hint_lbl.text = "[ Press SPACE to begin ]"
	hint_lbl.add_theme_font_size_override("font_size", 12)
	hint_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(hint_lbl)

	add_child(_briefing_panel)

## Item 7: check if briefing panel is currently shown
func has_briefing() -> bool:
	return _briefing_panel != null

func dismiss_briefing() -> void:
	if _briefing_panel:
		_briefing_panel.queue_free()
		_briefing_panel = null

## Set the currently armed weapon ID for the > indicator in weapon list
func set_armed_weapon(weapon_id: String) -> void:
	_armed_weapon_id = weapon_id

## Item 12: show in-flight weapons for selected unit in unit panel
func update_weapons_hot(weapon_names: Array) -> void:
	if weapon_names.is_empty():
		if _weapons_hot_label:
			_weapons_hot_label.queue_free()
			_weapons_hot_label = null
		return
	if not _weapons_hot_label:
		_weapons_hot_label = Label.new()
		_weapons_hot_label.add_theme_font_size_override("font_size", 11)
		_weapons_hot_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.2))
		_weapons_hot_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Position below sensors label in unit panel
		var vbox = unit_panel.find_child("VBox", false, false)
		if vbox:
			vbox.add_child(_weapons_hot_label)
	_weapons_hot_label.text = "WEAPONS HOT: %s" % ", ".join(weapon_names)

## Item 1: show designated fire target in unit panel with range info
func update_fire_target(target_name: String, range_nm: float = -1.0, weapon_ranges: Array = []) -> void:
	if target_name == "":
		if _fire_target_label:
			_fire_target_label.queue_free()
			_fire_target_label = null
		return
	if not _fire_target_label:
		_fire_target_label = Label.new()
		_fire_target_label.add_theme_font_size_override("font_size", 12)
		_fire_target_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
		_fire_target_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var vbox = unit_panel.find_child("VBox", false, false)
		if vbox:
			vbox.add_child(_fire_target_label)
	var text: String = "TARGET: %s" % target_name
	if range_nm >= 0.0:
		text += "  ~%dNM" % int(range_nm)
		# Show weapon ranges with IN/OUT status
		for wr in weapon_ranges:
			var status: String = "OK" if range_nm <= wr["range"] else "OUT"
			text += "\n  %s: %dNM [%s]" % [wr["name"], int(wr["range"]), status]
	_fire_target_label.text = text

## BL-2: Show a transient message in the top bar area
## Item 3: duration of 0.0 means persist until dismissed (no auto-expire)
func show_message(text: String, duration: float = 3.0) -> void:
	if _message_label:
		_message_label.queue_free()
		_message_label = null
	_message_label = Label.new()
	_message_label.text = text
	_message_label.add_theme_font_size_override("font_size", 13)
	_message_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.5))
	_message_label.position = Vector2(10, 50)  # Fix 13: moved down to avoid TopBar overlap
	_message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_message_label)
	_message_timer = duration  # 0.0 = persist (never auto-expire)

## EN-1: Show a red flashing alert (e.g. torpedo warning)
func show_alert(text: String, duration: float = 5.0) -> void:
	if _alert_label:
		_alert_label.queue_free()
		_alert_label = null
	_alert_label = Label.new()
	_alert_label.text = text
	_alert_label.add_theme_font_size_override("font_size", 18)
	_alert_label.add_theme_color_override("font_color", Color(1.0, 0.2, 0.2))
	_alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_alert_label.position = Vector2(200, 45)
	_alert_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_alert_label)
	_alert_timer = duration

# ---------------------------------------------------------------------------
# Tutorial prompt system
# ---------------------------------------------------------------------------

## Show a styled tutorial prompt at bottom-center of screen.
## pause_gated: if true, shows "Press SPACE to continue" footer and blocks on SPACE.
func show_tutorial_prompt(text: String, pause_gated: bool = false) -> void:
	dismiss_tutorial_prompt()  # Clear any existing prompt

	_tutorial_pause_gate = pause_gated
	_tutorial_panel = PanelContainer.new()
	_tutorial_panel.name = "TutorialPanel"

	# Anchor bottom-center
	_tutorial_panel.anchors_preset = Control.PRESET_CENTER_BOTTOM
	_tutorial_panel.anchor_left = 0.5
	_tutorial_panel.anchor_top = 1.0
	_tutorial_panel.anchor_right = 0.5
	_tutorial_panel.anchor_bottom = 1.0
	_tutorial_panel.offset_left = -300.0
	_tutorial_panel.offset_top = -260.0
	_tutorial_panel.offset_right = 300.0
	_tutorial_panel.offset_bottom = -10.0
	_tutorial_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Dark navy background with green border
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.05, 0.1, 0.95)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.2, 0.8, 0.5, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 20.0
	style.content_margin_top = 15.0
	style.content_margin_right = 20.0
	style.content_margin_bottom = 15.0
	_tutorial_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tutorial_panel.add_child(vbox)

	# TRAINING header
	var header := Label.new()
	header.text = "TRAINING"
	header.add_theme_font_size_override("font_size", 16)
	header.add_theme_color_override("font_color", Color(0.2, 0.8, 0.5))
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(header)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 6)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)

	# Body text
	var body := Label.new()
	body.text = text
	body.add_theme_font_size_override("font_size", 12)
	body.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(body)

	# Footer hint for pause-gated prompts
	if pause_gated:
		var spacer2 := Control.new()
		spacer2.custom_minimum_size = Vector2(0, 8)
		spacer2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(spacer2)

		var footer := Label.new()
		footer.text = "[ Press SPACE to continue ]"
		footer.add_theme_font_size_override("font_size", 11)
		footer.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(footer)

	add_child(_tutorial_panel)

## Dismiss the current tutorial prompt.
func dismiss_tutorial_prompt() -> void:
	if _tutorial_panel:
		_tutorial_panel.queue_free()
		_tutorial_panel = null
	_tutorial_pause_gate = false

## Returns true if a pause-gated tutorial prompt is currently shown.
func has_tutorial_prompt() -> bool:
	return _tutorial_panel != null and _tutorial_pause_gate

## Show/hide the HelpPanel. Used by TutorialManager to hide controls during tutorial.
func set_help_visible(vis: bool) -> void:
	var help_panel = find_child("HelpPanel", false, false)
	if help_panel:
		help_panel.visible = vis

# ---------------------------------------------------------------------------
# Contact panel flash (new detection feedback)
# ---------------------------------------------------------------------------

## Flash the contacts panel border to bright amber for 1 second when a new
## contact is detected, then restore the default panel style.
func flash_new_contact() -> void:
	if not contacts_panel:
		return
	var flash_style := StyleBoxFlat.new()
	flash_style.bg_color = Color(0.06, 0.1, 0.2, 0.85)
	flash_style.border_width_left = 2
	flash_style.border_width_top = 2
	flash_style.border_width_right = 2
	flash_style.border_width_bottom = 2
	flash_style.border_color = Color(1.0, 0.6, 0.1, 1.0)  # Bright amber
	flash_style.corner_radius_top_left = 4
	flash_style.corner_radius_top_right = 4
	flash_style.corner_radius_bottom_right = 4
	flash_style.corner_radius_bottom_left = 4
	contacts_panel.add_theme_stylebox_override("panel", flash_style)
	# Reset after 1 second
	get_tree().create_timer(1.0).timeout.connect(_reset_contacts_style)

func _reset_contacts_style() -> void:
	if contacts_panel:
		contacts_panel.remove_theme_stylebox_override("panel")

# ---------------------------------------------------------------------------
# Pause menu
# ---------------------------------------------------------------------------

## Show the pause menu. Pauses simulation and blocks game input.
func show_pause_menu() -> void:
	if _pause_menu:
		return  # Already visible

	_pause_menu = PanelContainer.new()
	_pause_menu.name = "PauseMenu"

	# Center on screen
	_pause_menu.anchor_left = 0.5
	_pause_menu.anchor_top = 0.5
	_pause_menu.anchor_right = 0.5
	_pause_menu.anchor_bottom = 0.5
	_pause_menu.offset_left = -200.0
	_pause_menu.offset_top = -220.0
	_pause_menu.offset_right = 200.0
	_pause_menu.offset_bottom = 220.0
	# Block mouse events from passing through to game
	_pause_menu.mouse_filter = Control.MOUSE_FILTER_STOP

	# Style: dark navy bg, blue border (matches briefing panel)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.12, 0.97)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.25, 0.55, 0.85, 0.8)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_right = 6
	style.corner_radius_bottom_left = 6
	style.content_margin_left = 30.0
	style.content_margin_top = 30.0
	style.content_margin_right = 30.0
	style.content_margin_bottom = 30.0
	_pause_menu.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_pause_menu.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	vbox.add_child(title)

	var divider := Control.new()
	divider.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(divider)

	# Menu buttons
	_pause_add_button(vbox, "RESUME", _on_pause_resume)

	var gap1 := Control.new()
	gap1.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(gap1)

	_pause_add_button(vbox, "RESTART MISSION", _on_pause_restart)
	_pause_add_button(vbox, "MAIN MENU", _on_pause_main_menu)
	_pause_add_button(vbox, "QUIT", _on_pause_quit)

	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 16)
	vbox.add_child(gap2)

	# Audio toggle
	var audio_muted: bool = AudioServer.is_bus_mute(0)
	var audio_lbl := Label.new()
	audio_lbl.name = "AudioToggleLabel"
	audio_lbl.text = "AUDIO: OFF" if audio_muted else "AUDIO: ON"
	audio_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	audio_lbl.add_theme_font_size_override("font_size", 18)
	audio_lbl.add_theme_color_override("font_color", Color(0.5, 0.55, 0.65))
	audio_lbl.custom_minimum_size = Vector2(0, 32)
	audio_lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	audio_lbl.mouse_entered.connect(_on_pause_btn_hover.bind(audio_lbl, true))
	audio_lbl.mouse_exited.connect(_on_pause_btn_hover.bind(audio_lbl, false))
	audio_lbl.gui_input.connect(_on_pause_audio_toggle.bind(audio_lbl))
	vbox.add_child(audio_lbl)

	add_child(_pause_menu)


func _pause_add_button(parent: VBoxContainer, text: String, callback: Callable) -> void:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	lbl.custom_minimum_size = Vector2(0, 32)
	lbl.mouse_filter = Control.MOUSE_FILTER_STOP
	lbl.mouse_entered.connect(_on_pause_btn_hover.bind(lbl, true))
	lbl.mouse_exited.connect(_on_pause_btn_hover.bind(lbl, false))
	lbl.gui_input.connect(_on_pause_label_clicked.bind(callback))
	parent.add_child(lbl)


func _on_pause_btn_hover(lbl: Label, hovered: bool) -> void:
	lbl.add_theme_color_override("font_color",
		Color(1.0, 1.0, 1.0) if hovered else Color(0.6, 0.7, 0.8))


func _on_pause_label_clicked(event: InputEvent, callback: Callable) -> void:
	if event is InputEventMouseButton and event.button_index == 1 and event.pressed:
		callback.call()


func _on_pause_audio_toggle(event: InputEvent, lbl: Label) -> void:
	if event is InputEventMouseButton and event.button_index == 1 and event.pressed:
		var currently_muted: bool = AudioServer.is_bus_mute(0)
		AudioServer.set_bus_mute(0, not currently_muted)
		lbl.text = "AUDIO: ON" if currently_muted else "AUDIO: OFF"


func _on_pause_resume() -> void:
	close_pause_menu()
	SimulationWorld.unpause()


func _on_pause_restart() -> void:
	close_pause_menu()
	SimulationWorld.unpause()
	get_tree().call_deferred("reload_current_scene")


func _on_pause_main_menu() -> void:
	close_pause_menu()
	SimulationWorld.unpause()
	get_tree().call_deferred("change_scene_to_file", "res://scenes/mainmenu.tscn")


func _on_pause_quit() -> void:
	get_tree().quit()


## Close the pause menu without any scene transition.
func close_pause_menu() -> void:
	if _pause_menu:
		_pause_menu.queue_free()
		_pause_menu = null


## Returns true if the pause menu is currently shown.
func is_pause_menu_visible() -> bool:
	return _pause_menu != null
