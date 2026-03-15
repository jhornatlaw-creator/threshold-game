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
var _debrief_panel: PanelContainer = null  # Mission debrief overlay
var _campaign_mission: int = 0  # Current campaign mission number (1-based), 0 = not in campaign
var _campaign_total: int = 0  # Total campaign missions
var _campaign_name: String = ""  # Current mission name for campaign header
var _tracking_target_seconds: float = 0.0  # Required contact time for maintain_contact
var _weather_label: Label = null  # Weather/sea state top-bar display

func _ready() -> void:
	unit_panel.visible = false
	result_panel.visible = false
	_update_help_text()
	SimulationWorld.sim_tick.connect(_on_sim_tick)
	SimulationWorld.weather_changed.connect(_on_weather_changed)
	# All HUD controls pass mouse events through to the tactical map
	_set_mouse_passthrough(self)
	# Weather label in top bar (right side)
	_weather_label = Label.new()
	_weather_label.name = "WeatherLabel"
	_weather_label.add_theme_font_size_override("font_size", 11)
	_weather_label.add_theme_color_override("font_color", Color(0.4, 0.5, 0.6))
	_weather_label.anchor_left = 1.0
	_weather_label.anchor_right = 1.0
	_weather_label.offset_left = -300
	_weather_label.offset_right = -10
	_weather_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_weather_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	$TopBar.add_child(_weather_label)
	_update_weather_display()

func _on_sim_tick(_tick: int, _time: float) -> void:
	_refresh_contacts()
	_update_weather_display()

func _update_weather_display() -> void:
	if not _weather_label:
		return
	var ss: int = SimulationWorld.weather_sea_state
	var weather: String = SimulationWorld.weather_type.to_upper()
	var vis: float = SimulationWorld.weather_visibility_nm
	_weather_label.text = "SS:%d  %s  VIS:%.0fnm" % [ss, weather, vis]
	if ss >= 5:
		_weather_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
	elif ss >= 4:
		_weather_label.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	else:
		_weather_label.add_theme_color_override("font_color", Color(0.3, 0.8, 0.5))

func _on_weather_changed(_sea_state: int, _weather: String, _visibility: float) -> void:
	_update_weather_display()

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
	# Keep result_panel visible so existing SPACE handler in RenderBridge still works.
	# result_label is hidden; custom debrief panel renders on top.
	if result_panel:
		result_panel.visible = true
	if result_label:
		result_label.visible = false

	# --- Collect time ---
	var elapsed: float = SimulationWorld.sim_time
	var e_hours: int = int(elapsed) / 3600
	var e_minutes: int = (int(elapsed) % 3600) / 60
	var e_seconds: int = int(elapsed) % 60
	var elapsed_str: String = "%02d:%02d:%02d" % [e_hours, e_minutes, e_seconds]

	# --- Collect player force status ---
	# Array of {name, ok} dicts for the forces section
	var force_rows: Array = []
	# Array of "Name (N crew)" strings for ships lost THIS mission
	var lost_this_mission: Array = []
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if u.get("faction", "") != "player":
			continue
		# Skip helicopters / aircraft
		var platform_type: String = u.get("platform", {}).get("type", "")
		if platform_type in ["SH60B", "MPA", "P3C", "HELO"]:
			continue
		var ship_name: String = u.get("name", uid)
		if u["is_alive"]:
			force_rows.append({"name": ship_name, "ok": true})
		else:
			var displacement: float = u.get("platform", {}).get("displacement_tons", 4000.0)
			var crew_est: int = int(displacement / 20.0)
			force_rows.append({"name": ship_name, "ok": false})
			lost_this_mission.append("%s (%d crew)" % [ship_name, crew_est])

	# --- Collect score ---
	var grade: String = "?"
	var score: int = 0
	var kills: int = 0
	var losses: int = 0
	var weapons_fired: int = 0
	var total_enemies: int = ScoreManager.total_enemies
	if ScoreManager.is_tracking:
		var time_limit: float = SimulationWorld.scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
		var score_data: Dictionary = ScoreManager.compute_score(SimulationWorld.sim_time, time_limit)
		grade = score_data["grade"]
		score = score_data["score"]
		kills = score_data["kills"]
		losses = score_data["losses"]
		weapons_fired = score_data["weapons_fired"]
		ScoreManager.stop_tracking()

	# Efficiency %: kills / total_enemies, or weapons efficiency
	var efficiency_pct: int = 100
	if weapons_fired > 0 and total_enemies > 0:
		var ideal: int = total_enemies * 2
		efficiency_pct = clampi(int(float(ideal) / float(weapons_fired) * 100), 0, 100)

	# --- Build the debrief panel ---
	close_debrief()
	_debrief_panel = PanelContainer.new()
	_debrief_panel.name = "DebriefPanel"

	# Center on screen, 600 wide x 500 tall
	_debrief_panel.anchor_left = 0.5
	_debrief_panel.anchor_top = 0.5
	_debrief_panel.anchor_right = 0.5
	_debrief_panel.anchor_bottom = 0.5
	_debrief_panel.offset_left = -300.0
	_debrief_panel.offset_top = -250.0
	_debrief_panel.offset_right = 300.0
	_debrief_panel.offset_bottom = 250.0
	_debrief_panel.mouse_filter = Control.MOUSE_FILTER_STOP

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
	style.content_margin_left = 24.0
	style.content_margin_top = 20.0
	style.content_margin_right = 24.0
	style.content_margin_bottom = 20.0
	_debrief_panel.add_theme_stylebox_override("panel", style)

	var scroll := ScrollContainer.new()
	scroll.layout_mode = 1
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_debrief_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# --- Header ---
	if _campaign_mission > 0:
		var mission_hdr := Label.new()
		mission_hdr.text = "MISSION %d OF %d — %s" % [_campaign_mission, _campaign_total, _campaign_name.to_upper()]
		mission_hdr.add_theme_font_size_override("font_size", 11)
		mission_hdr.add_theme_color_override("font_color", Color(0.4, 0.5, 0.65))
		mission_hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mission_hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(mission_hdr)

	var title_lbl := Label.new()
	title_lbl.text = "MISSION DEBRIEF"
	title_lbl.add_theme_font_size_override("font_size", 22)
	title_lbl.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title_lbl)

	# Outcome line
	var outcome_lbl := Label.new()
	var outcome_color: Color
	match result:
		"victory":
			outcome_lbl.text = "THREATS NEUTRALIZED"
			outcome_color = Color(0.3, 1.0, 0.3)
		"defeat":
			outcome_lbl.text = "TASK FORCE LOST"
			outcome_color = Color(1.0, 0.3, 0.3)
		"draw":
			outcome_lbl.text = "CONTACTS ESCAPED"
			outcome_color = Color(1.0, 1.0, 0.3)
		_:
			outcome_lbl.text = result.to_upper()
			outcome_color = Color(0.6, 0.7, 0.8)
	outcome_lbl.add_theme_font_size_override("font_size", 16)
	outcome_lbl.add_theme_color_override("font_color", outcome_color)
	outcome_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outcome_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(outcome_lbl)

	_debrief_add_spacer(vbox, 6)

	# --- SCORE section ---
	_debrief_add_divider(vbox, "SCORE")

	var grade_score_lbl := Label.new()
	grade_score_lbl.text = "Grade: %s        Score: %d" % [grade, score]
	grade_score_lbl.add_theme_font_size_override("font_size", 13)
	grade_score_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	grade_score_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(grade_score_lbl)

	var kills_lbl := Label.new()
	kills_lbl.text = "Kills: %d/%d        Weapons fired: %d" % [kills, total_enemies, weapons_fired]
	kills_lbl.add_theme_font_size_override("font_size", 13)
	kills_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	kills_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(kills_lbl)

	var time_eff_lbl := Label.new()
	time_eff_lbl.text = "Time: %s        Efficiency: %d%%" % [elapsed_str, efficiency_pct]
	time_eff_lbl.add_theme_font_size_override("font_size", 13)
	time_eff_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	time_eff_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(time_eff_lbl)

	_debrief_add_spacer(vbox, 4)

	# --- FORCES section ---
	_debrief_add_divider(vbox, "FORCES")

	for row in force_rows:
		var row_lbl := Label.new()
		var dots: String = " "
		# Pad ship name to ~36 chars with dots
		var name_str: String = row["name"]
		var pad_len: int = maxi(1, 38 - name_str.length())
		dots = " " + ".".repeat(pad_len) + " "
		var status_str: String = "OK" if row["ok"] else "LOST"
		row_lbl.text = "%s%s%s" % [name_str, dots, status_str]
		row_lbl.add_theme_font_size_override("font_size", 12)
		var row_color: Color = Color(0.3, 1.0, 0.3) if row["ok"] else Color(1.0, 0.3, 0.3)
		row_lbl.add_theme_color_override("font_color", row_color)
		row_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(row_lbl)

	# --- Prior campaign losses ---
	if _campaign_mission > 0 and CampaignManager.campaign_active:
		var prior_lost: Array = CampaignManager.get_lost_ships()
		# Filter to ships lost in missions BEFORE this one
		var prior_only: Array = []
		for ship in prior_lost:
			if ship.get("lost_mission", _campaign_mission) < _campaign_mission - 1:
				prior_only.append(ship)
		if not prior_only.is_empty():
			_debrief_add_spacer(vbox, 2)
			var prior_hdr := Label.new()
			prior_hdr.text = "Fleet losses to date:"
			prior_hdr.add_theme_font_size_override("font_size", 11)
			prior_hdr.add_theme_color_override("font_color", Color(0.5, 0.3, 0.3))
			prior_hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			vbox.add_child(prior_hdr)
			for ship in prior_only:
				var sl := Label.new()
				var sname: String = ship.get("name", "Unknown")
				var lost_at: int = ship.get("lost_mission", 0) + 1
				sl.text = "  %s — lost mission %d" % [sname, lost_at]
				sl.add_theme_font_size_override("font_size", 11)
				sl.add_theme_color_override("font_color", Color(0.55, 0.35, 0.35))
				sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
				vbox.add_child(sl)

	_debrief_add_spacer(vbox, 4)

	# --- SITUATION REPORT section ---
	_debrief_add_divider(vbox, "SITUATION REPORT")

	var narrative: String = _generate_debrief_narrative(result, grade, kills, losses, total_enemies, lost_this_mission)
	var narr_lbl := Label.new()
	narr_lbl.text = narrative
	narr_lbl.add_theme_font_size_override("font_size", 12)
	narr_lbl.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	narr_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	narr_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(narr_lbl)

	_debrief_add_spacer(vbox, 8)

	# --- Continue hint ---
	var hint_text: String = "[ SPACE to continue to next mission ]" if _campaign_mission > 0 else "[ SPACE to restart ]"
	var hint_lbl := Label.new()
	hint_lbl.text = hint_text
	hint_lbl.add_theme_font_size_override("font_size", 12)
	hint_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hint_lbl)

	add_child(_debrief_panel)


## Generate a 2-3 sentence narrative for the situation report section.
func _generate_debrief_narrative(result: String, grade: String, kills: int, losses: int, total_enemies: int, lost_ship_names: Array) -> String:
	var narrative: String = ""

	match result:
		"victory":
			match grade:
				"S":
					narrative = "Textbook prosecution. %d hostile contact%s destroyed with zero losses. COMNAVAIRLANT commends Task Force BRAVO's performance. Your crews will be recommended for unit citations." % [kills, "s" if kills != 1 else ""]
				"A":
					narrative = "Clean sweep. All hostile contacts neutralized. Minor tactical inefficiencies noted but overall outcome exceeds expectations. Well done, Commander."
				"B":
					narrative = "Mission accomplished. Hostile submarine threat eliminated. SACLANT acknowledges satisfactory prosecution of contacts in the operational area."
				"C":
					narrative = "Contacts destroyed but at cost. Review of engagement timeline indicates delayed prosecution. Operations staff will schedule debrief for lessons learned."
				"D":
					narrative = "Mission technically complete. Significant losses and resource expenditure raise concerns. Expect questions from the review board."
				_:
					narrative = "Pyrrhic outcome. While hostile contacts were eventually neutralized, the cost to the task force was unacceptable. A formal inquiry has been ordered."
		"defeat":
			narrative = "Task force combat effectiveness destroyed. Surviving crew are being recovered. SACLANT is redirecting assets from STANAVFORLANT to cover the gap. This will be remembered."
			if not lost_ship_names.is_empty():
				var first_loss: String = lost_ship_names[0]
				# Extract just the name part (before the parenthesis)
				var paren_idx: int = first_loss.find(" (")
				var ship_display: String = first_loss.substr(0, paren_idx) if paren_idx > 0 else first_loss
				narrative += "\n\n%s and her crew are gone. The families have been notified." % ship_display
		"draw":
			if grade in ["D", "F"]:
				narrative = "Unacceptable. They came, they passed, and we watched. SACLANT demands explanation."
			else:
				narrative = "The contacts slipped through. SOSUS reports transients heading south past the Faroes. COMSUBLANT is repositioning two boats to intercept, but the damage to the barrier is done."
		_:
			narrative = "Mission concluded. Full after-action review pending."

	return narrative


## Add a styled section divider label to a VBoxContainer.
func _debrief_add_divider(parent: VBoxContainer, section_title: String) -> void:
	var lbl := Label.new()
	lbl.text = "— %s " % section_title + "—".repeat(maxi(1, 30 - section_title.length()))
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color(0.25, 0.55, 0.85, 0.8))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(lbl)


## Add a blank spacer of the given pixel height.
func _debrief_add_spacer(parent: VBoxContainer, height: int) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, height)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(spacer)


## Close and free the debrief panel.
func close_debrief() -> void:
	if _debrief_panel:
		_debrief_panel.queue_free()
		_debrief_panel = null


## Returns true if the debrief panel is currently shown.
func is_debrief_visible() -> bool:
	return _debrief_panel != null

## Show campaign complete screen with full debrief.
func show_campaign_complete(history: Array) -> void:
	# Campaign complete is handled by Main.gd's _unhandled_input (SPACE -> main menu).
	# We build a styled panel here; no result_panel wiring needed.
	close_debrief()

	# Compute overall grade
	var grade_values := {"S": 6, "A": 5, "B": 4, "C": 3, "D": 2, "F": 1}
	var grade_sum: int = 0
	var total_score: int = 0
	var total_losses: int = 0
	for entry in history:
		var g: String = entry.get("grade", "F")
		grade_sum += grade_values.get(g, 1)
		total_score += entry.get("score", 0)
		total_losses += entry.get("losses", []).size()

	var overall_grade: String = "F"
	if history.size() > 0:
		var avg: float = float(grade_sum) / float(history.size())
		if avg >= 5.5:
			overall_grade = "S"
		elif avg >= 4.5:
			overall_grade = "A"
		elif avg >= 3.5:
			overall_grade = "B"
		elif avg >= 2.5:
			overall_grade = "C"
		elif avg >= 1.5:
			overall_grade = "D"

	# Build panel
	_debrief_panel = PanelContainer.new()
	_debrief_panel.name = "DebriefPanel"
	_debrief_panel.anchor_left = 0.5
	_debrief_panel.anchor_top = 0.5
	_debrief_panel.anchor_right = 0.5
	_debrief_panel.anchor_bottom = 0.5
	_debrief_panel.offset_left = -310.0
	_debrief_panel.offset_top = -270.0
	_debrief_panel.offset_right = 310.0
	_debrief_panel.offset_bottom = 270.0
	_debrief_panel.mouse_filter = Control.MOUSE_FILTER_STOP

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
	style.content_margin_left = 24.0
	style.content_margin_top = 20.0
	style.content_margin_right = 24.0
	style.content_margin_bottom = 20.0
	_debrief_panel.add_theme_stylebox_override("panel", style)

	var scroll := ScrollContainer.new()
	scroll.layout_mode = 1
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_debrief_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# Title block
	var campaign_lbl := Label.new()
	campaign_lbl.text = "THE AUTUMN WATCH"
	campaign_lbl.add_theme_font_size_override("font_size", 13)
	campaign_lbl.add_theme_color_override("font_color", Color(0.4, 0.5, 0.65))
	campaign_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	campaign_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(campaign_lbl)

	var title_lbl := Label.new()
	title_lbl.text = "CAMPAIGN COMPLETE"
	title_lbl.add_theme_font_size_override("font_size", 22)
	title_lbl.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(title_lbl)

	_debrief_add_spacer(vbox, 4)

	# Overall stats
	var overall_lbl := Label.new()
	overall_lbl.text = "Overall Grade: %s        Total Score: %d        Ships Lost: %d" % [overall_grade, total_score, total_losses]
	overall_lbl.add_theme_font_size_override("font_size", 13)
	overall_lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.8))
	overall_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overall_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(overall_lbl)

	_debrief_add_spacer(vbox, 4)

	# --- Mission results table ---
	_debrief_add_divider(vbox, "MISSION RESULTS")

	for entry in history:
		var m_idx: int = entry.get("mission_index", 0)
		var m_result: String = entry.get("result", "unknown")
		var m_grade: String = entry.get("grade", "?")
		var m_score: int = entry.get("score", 0)
		var m_losses: Array = entry.get("losses", [])

		var result_abbr: String
		var row_color: Color
		match m_result:
			"victory":
				result_abbr = "VICTORY"
				row_color = Color(0.3, 1.0, 0.3)
			"defeat":
				result_abbr = "DEFEAT "
				row_color = Color(1.0, 0.3, 0.3)
			"draw":
				result_abbr = "ESCAPE "
				row_color = Color(1.0, 1.0, 0.3)
			_:
				result_abbr = m_result.substr(0, 7).to_upper()
				row_color = Color(0.6, 0.7, 0.8)

		var loss_str: String = "  (%d lost)" % m_losses.size() if not m_losses.is_empty() else ""
		var row_lbl := Label.new()
		row_lbl.text = "  Mission %d:  %s   Grade: %s   Score: %d%s" % [m_idx + 1, result_abbr, m_grade, m_score, loss_str]
		row_lbl.add_theme_font_size_override("font_size", 12)
		row_lbl.add_theme_color_override("font_color", row_color)
		row_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(row_lbl)

	_debrief_add_spacer(vbox, 4)

	# --- Fleet casualties ---
	var lost_ships: Array = CampaignManager.get_lost_ships()
	if not lost_ships.is_empty():
		_debrief_add_divider(vbox, "FLEET CASUALTIES")
		for ship in lost_ships:
			var sname: String = ship.get("name", "Unknown")
			var lost_at: int = ship.get("lost_mission", 0) + 1
			var cas_lbl := Label.new()
			cas_lbl.text = "  %s — lost mission %d" % [sname, lost_at]
			cas_lbl.add_theme_font_size_override("font_size", 12)
			cas_lbl.add_theme_color_override("font_color", Color(0.7, 0.35, 0.35))
			cas_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			vbox.add_child(cas_lbl)
		_debrief_add_spacer(vbox, 4)

	# --- Campaign narrative ---
	_debrief_add_divider(vbox, "ASSESSMENT")

	var campaign_narrative: String = _generate_campaign_narrative(overall_grade, total_losses, history.size())
	var narr_lbl := Label.new()
	narr_lbl.text = campaign_narrative
	narr_lbl.add_theme_font_size_override("font_size", 12)
	narr_lbl.add_theme_color_override("font_color", Color(0.5, 0.6, 0.7))
	narr_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	narr_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(narr_lbl)

	_debrief_add_spacer(vbox, 8)

	var hint_lbl := Label.new()
	hint_lbl.text = "[ SPACE to return to mission select ]"
	hint_lbl.add_theme_font_size_override("font_size", 12)
	hint_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hint_lbl)

	add_child(_debrief_panel)


## Generate a campaign-end assessment narrative based on overall grade and losses.
func _generate_campaign_narrative(overall_grade: String, total_losses: int, mission_count: int) -> String:
	match overall_grade:
		"S":
			return "Flawless execution across all %d missions. The GIUK barrier held without a single loss. SACLANT has forwarded commendations for all task force commanders. This is what it means to own the Atlantic." % mission_count
		"A":
			return "The campaign is concluded with distinction. Hostile submarine activity in the operational area has been suppressed. Minor friction noted in a handful of engagements, but the outcome was never in doubt. Well executed."
		"B":
			return "The Autumn Watch is over. The task force performed adequately across the campaign. Barrier integrity was maintained at acceptable cost. Lessons will be incorporated into the next rotation's training syllabus."
		"C":
			return "A qualified success. The barrier held, but %d ships and their crews did not come home. SACLANT will review the engagements where prosecution was delayed. The margin for error in the real North Atlantic is thinner than this." % total_losses
		"D":
			return "The campaign achieved its minimum objectives at significant cost. %d ships lost. The task force's operational effectiveness was compromised. A comprehensive review has been ordered. SACLANT expects a full accounting." % total_losses
		_:
			return "The campaign is over, but at unacceptable cost. %d ships lost. STANAVFORLANT is repositioning to compensate for the gap this task force has left behind. The families of %d lost crews have been notified. This result will not be forgotten." % [total_losses, total_losses]

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
		var platform_type: String = u.get("platform", {}).get("type", "")
		if u.get("is_airborne", false):
			# Airborne units: show altitude and fuel instead of depth
			var alt: float = u.get("altitude_ft", 0.0)
			var fuel: float = u.get("fuel_remaining", 1.0)
			var fuel_pct: int = int(fuel * 100.0)
			unit_depth_label.text = "ALT: %dft  FUEL: %d%%" % [int(alt), fuel_pct]
			if fuel <= 0.1:
				unit_depth_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3))
			elif fuel <= 0.3:
				unit_depth_label.add_theme_color_override("font_color", Color(1.0, 1.0, 0.3))
			else:
				unit_depth_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
			unit_depth_label.visible = true
		elif platform_type != "SSN":
			unit_depth_label.visible = false
		else:
			var depth: float = u.get("depth_m", 0.0)
			if depth < -1.0:
				unit_depth_label.text = "DEPTH: %dm" % int(abs(depth))
			else:
				unit_depth_label.text = "SURFACE"
			unit_depth_label.remove_theme_color_override("font_color")
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
			help_label.text = "LClick: Select / Designate | RClick: Waypoint\nF: Fire | C: Cycle Weapon | Tab: Cycle Units\nW/X: Speed +/- | [/]: Depth (subs)\nR: Radar | S: Sonar | L: Launch Helo\nH: Center Camera | +/-: Zoom | Arrows: Pan\nSPACE: Pause | 1-5: Time Scale | Esc: Menu\nV: Toggle CRT Mode | M: Toggle Minimap"
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
