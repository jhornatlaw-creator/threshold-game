extends Control
## MainMenu -- Programmatic main menu for THRESHOLD.

const CAMPAIGN_MISSIONS := [
	"res://scenarios/north_atlantic_asw.json",
	"res://scenarios/campaign_02_cold_passage.json",
	"res://scenarios/campaign_03_sosus_ghost.json",
	"res://scenarios/campaign_04_northern_watch.json",
	"res://scenarios/campaign_05_crossing_the_line.json",
	"res://scenarios/campaign_06_reykjanes_ridge.json",
	"res://scenarios/campaign_07_silent_watch.json",
]

const COLOR_BG         := Color(0.02, 0.04, 0.08)
const COLOR_TITLE      := Color(0.3, 0.7, 1.0)
const COLOR_SUBTITLE   := Color(0.4, 0.45, 0.5)
const COLOR_BUTTON     := Color(0.6, 0.7, 0.8)
const COLOR_HOVER      := Color(1.0, 1.0, 1.0)
const COLOR_VERSION    := Color(0.3, 0.32, 0.35)

const DIFFICULTY_TIERS := ["EASY", "NORMAL", "HARD", "ELITE"]

var _menu_container: VBoxContainer
var _button_container: VBoxContainer
var _difficulty_label: Label  # center label showing current tier name


func _ready() -> void:
	_build_layout()


func _build_layout() -> void:
	# Background
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# Outer centering container
	var outer := VBoxContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	outer.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(outer)

	# Inner fixed-width column
	_menu_container = VBoxContainer.new()
	_menu_container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_menu_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_menu_container.custom_minimum_size = Vector2(480, 0)
	_menu_container.add_theme_constant_override("separation", 0)
	outer.add_child(_menu_container)

	# Title
	var title := Label.new()
	title.text = "THRESHOLD"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	title.add_theme_color_override("font_color", COLOR_TITLE)
	_menu_container.add_child(title)

	# Subtitle
	var subtitle := Label.new()
	subtitle.text = "Cold War Naval Warfare Simulation"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 16)
	subtitle.add_theme_color_override("font_color", COLOR_SUBTITLE)
	_menu_container.add_child(subtitle)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 48)
	_menu_container.add_child(spacer)

	# Button list container
	_button_container = VBoxContainer.new()
	_button_container.add_theme_constant_override("separation", 4)
	_menu_container.add_child(_button_container)

	_build_main_buttons()

	# Bottom spacer + version
	var bottom_spacer := Control.new()
	bottom_spacer.custom_minimum_size = Vector2(0, 32)
	_menu_container.add_child(bottom_spacer)

	var version := Label.new()
	version.text = "v0.3-beta"
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	version.add_theme_font_size_override("font_size", 12)
	version.add_theme_color_override("font_color", COLOR_VERSION)
	_menu_container.add_child(version)


func _build_main_buttons() -> void:
	for child in _button_container.get_children():
		child.queue_free()

	# Check for saved campaign
	var has_saved := CampaignManager.load_campaign()
	if has_saved:
		_add_menu_button("CONTINUE CAMPAIGN", _on_continue_campaign)
		_add_menu_button("", null)  # visual gap

	_add_menu_button("THE AUTUMN WATCH", _on_autumn_watch)
	_add_menu_button("SINGLE MISSION", _on_single_mission)
	_build_difficulty_row()
	_add_menu_button("TUTORIAL", _on_tutorial)


func _build_difficulty_row() -> void:
	# Row: "DIFFICULTY:  <   NORMAL   >"
	# The row sits inside _button_container like any other entry.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 0)
	row.custom_minimum_size = Vector2(0, 36)

	# Static "DIFFICULTY:" prefix label
	var prefix := Label.new()
	prefix.text = "DIFFICULTY:"
	prefix.add_theme_font_size_override("font_size", 16)
	prefix.add_theme_color_override("font_color", COLOR_SUBTITLE)
	prefix.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(prefix)

	# Small spacer
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(12, 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap)

	# Left arrow "<"
	var arrow_l := Label.new()
	arrow_l.text = "<"
	arrow_l.add_theme_font_size_override("font_size", 20)
	arrow_l.add_theme_color_override("font_color", COLOR_BUTTON)
	arrow_l.mouse_filter = Control.MOUSE_FILTER_STOP
	arrow_l.mouse_entered.connect(_on_button_hover.bind(arrow_l, true))
	arrow_l.mouse_exited.connect(_on_button_hover.bind(arrow_l, false))
	arrow_l.gui_input.connect(_on_label_clicked.bind(_on_difficulty_prev))
	row.add_child(arrow_l)

	# Small spacer
	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(10, 0)
	gap2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap2)

	# Current difficulty name label
	_difficulty_label = Label.new()
	_difficulty_label.text = ScenarioLoader.selected_difficulty
	_difficulty_label.add_theme_font_size_override("font_size", 20)
	_difficulty_label.add_theme_color_override("font_color", COLOR_HOVER)
	_difficulty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_difficulty_label.custom_minimum_size = Vector2(80, 0)
	_difficulty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_difficulty_label)

	# Small spacer
	var gap3 := Control.new()
	gap3.custom_minimum_size = Vector2(10, 0)
	gap3.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gap3)

	# Right arrow ">"
	var arrow_r := Label.new()
	arrow_r.text = ">"
	arrow_r.add_theme_font_size_override("font_size", 20)
	arrow_r.add_theme_color_override("font_color", COLOR_BUTTON)
	arrow_r.mouse_filter = Control.MOUSE_FILTER_STOP
	arrow_r.mouse_entered.connect(_on_button_hover.bind(arrow_r, true))
	arrow_r.mouse_exited.connect(_on_button_hover.bind(arrow_r, false))
	arrow_r.gui_input.connect(_on_label_clicked.bind(_on_difficulty_next))
	row.add_child(arrow_r)

	_button_container.add_child(row)


func _on_difficulty_prev() -> void:
	var idx: int = DIFFICULTY_TIERS.find(ScenarioLoader.selected_difficulty)
	if idx < 0:
		idx = 1  # default to NORMAL index
	idx = (idx - 1 + DIFFICULTY_TIERS.size()) % DIFFICULTY_TIERS.size()
	ScenarioLoader.selected_difficulty = DIFFICULTY_TIERS[idx]
	if is_instance_valid(_difficulty_label):
		_difficulty_label.text = ScenarioLoader.selected_difficulty


func _on_difficulty_next() -> void:
	var idx: int = DIFFICULTY_TIERS.find(ScenarioLoader.selected_difficulty)
	if idx < 0:
		idx = 1  # default to NORMAL index
	idx = (idx + 1) % DIFFICULTY_TIERS.size()
	ScenarioLoader.selected_difficulty = DIFFICULTY_TIERS[idx]
	if is_instance_valid(_difficulty_label):
		_difficulty_label.text = ScenarioLoader.selected_difficulty


func _build_single_mission_buttons() -> void:
	for child in _button_container.get_children():
		child.queue_free()

	var scenarios := _list_scenarios()
	for path in scenarios:
		var name_text := _scenario_display_name(path)
		# Capture path for closure via a bound callable
		var btn := _add_menu_button(name_text, null)
		btn.set_meta("scenario_path", path)
		btn.gui_input.connect(_on_scenario_selected.bind(btn))

	_add_menu_button("", null)  # gap
	_add_menu_button("BACK", _on_back)


func _add_menu_button(text: String, callback) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", COLOR_BUTTON)
	lbl.custom_minimum_size = Vector2(0, 36)

	if text == "":
		# Silent spacer row — no interaction
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		lbl.mouse_filter = Control.MOUSE_FILTER_STOP
		lbl.mouse_entered.connect(_on_button_hover.bind(lbl, true))
		lbl.mouse_exited.connect(_on_button_hover.bind(lbl, false))
		if callback != null:
			lbl.gui_input.connect(_on_label_clicked.bind(callback))

	_button_container.add_child(lbl)
	return lbl


func _on_button_hover(lbl: Label, hovered: bool) -> void:
	lbl.add_theme_color_override("font_color", COLOR_HOVER if hovered else COLOR_BUTTON)


func _on_label_clicked(event: InputEvent, callback: Callable) -> void:
	if event is InputEventMouseButton and event.button_index == 1 and event.pressed:
		callback.call()


func _on_scenario_selected(event: InputEvent, lbl: Label) -> void:
	if event is InputEventMouseButton and event.button_index == 1 and event.pressed:
		var path: String = lbl.get_meta("scenario_path")
		ScenarioLoader.override_scenario = path
		get_tree().change_scene_to_file("res://scenes/main.tscn")


# --- Navigation callbacks ---

func _on_continue_campaign() -> void:
	# load_campaign() already called in _build_main_buttons — campaign state is restored.
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_autumn_watch() -> void:
	CampaignManager.start_campaign(CAMPAIGN_MISSIONS)
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_single_mission() -> void:
	_build_single_mission_buttons()


func _on_tutorial() -> void:
	ScenarioLoader.override_scenario = "res://scenarios/tutorial.json"
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_back() -> void:
	_build_main_buttons()


# --- Scenario discovery ---

func _list_scenarios() -> Array:
	var results: Array = []
	var dir := DirAccess.open("res://scenarios/")
	if dir != null:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() and fname.ends_with(".json") and fname != "tutorial.json":
				results.append("res://scenarios/" + fname)
			fname = dir.get_next()
		dir.list_dir_end()
	# Fallback: DirAccess cannot enumerate files inside a packed PCK in release exports.
	# Use the known campaign missions list to ensure scenarios are always available.
	if results.is_empty():
		for path in CAMPAIGN_MISSIONS:
			if FileAccess.file_exists(path):
				results.append(path)
	results.sort()
	return results


func _scenario_display_name(path: String) -> String:
	# Strip directory + extension, replace underscores with spaces, uppercase
	var base := path.get_file().get_basename()
	return base.replace("_", " ").to_upper()
