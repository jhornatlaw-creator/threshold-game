extends Node
## NarrativeDirector -- Narrative pipeline: comms, interludes, and Dialogic briefings.
##
## Loads JSON comm scripts per campaign mission. Listens to SimulationWorld signals
## and triggers comms based on gameplay events. Renders comm text as a styled overlay
## on the HUD. Also handles between-mission interlude text screens.
##
## Keeps Dialogic briefing support for backward compatibility.
## Phase 3 of the THRESHOLD overhaul.

signal narrative_started
signal narrative_ended
signal interlude_finished  # Emitted when player dismisses an interlude screen
signal comm_displayed(comm_id: String)  # Emitted after a comm finishes displaying

# --- Character data ---
var _characters: Dictionary = {}  # role -> {color, name, rank, ...}

# --- Comm state ---
var _mission_comms: Array = []  # Array of comm dicts for current mission
var _fired_comm_ids: Dictionary = {}  # comm_id -> true (prevent re-fire)
var _comm_queue: Array = []  # Pending comm lines to display
var _comm_timer: float = 0.0  # Countdown for current line display
var _comm_delay_timer: float = 0.0  # Delay before next line
var _comm_overlay: Control = null  # The comm overlay UI node
var _comm_role_label: Label = null
var _comm_text_label: Label = null
var _current_comm_id: String = ""

# --- Interlude state ---
var _interlude_data: Dictionary = {}  # "between_N_M" -> interlude dict
var _interlude_panel: PanelContainer = null
var _interlude_active: bool = false

# --- Mission tracking ---
var _current_mission_number: int = 0
var _first_detection_fired: bool = false
var _first_weapon_fired: bool = false
var _mission_start_time: float = 0.0
var _time_limit: float = 0.0

# --- Dialogic (legacy) ---
var _sim_was_paused: bool = false
var _is_playing: bool = false
var _dialogic: Node = null
var _timeline_class: GDScript = null

# --- Constants ---
const COMM_DISPLAY_SECONDS: float = 4.0  # How long each comm line stays on screen
const COMM_FADE_SECONDS: float = 0.5
const ROLE_COLORS := {
	"COMMAND": Color(0.3, 0.58, 1.0),
	"INTEL": Color(0.4, 0.8, 0.67),
	"COMMS": Color(0.8, 0.8, 0.4),
}

func _ready() -> void:
	# Load character definitions
	_load_characters()
	# Load all interlude data
	_load_interludes()
	# Try Dialogic (may not be available)
	_dialogic = get_node_or_null("/root/Dialogic")
	if _dialogic:
		_timeline_class = load("res://addons/dialogic/Resources/timeline.gd") as GDScript

func _process(delta: float) -> void:
	# Handle comm display timing
	if _comm_timer > 0.0:
		_comm_timer -= delta
		if _comm_timer <= 0.0:
			_hide_comm_overlay()
			# Check for more lines in queue
			if not _comm_queue.is_empty():
				var next_line: Dictionary = _comm_queue.pop_front()
				var delay: float = next_line.get("delay_ms", 0) / 1000.0
				if delay > 0:
					_comm_delay_timer = delay
				else:
					_show_comm_line(next_line)
			else:
				_is_playing = false
				narrative_ended.emit()
				comm_displayed.emit(_current_comm_id)

	if _comm_delay_timer > 0.0:
		_comm_delay_timer -= delta
		if _comm_delay_timer <= 0.0 and not _comm_queue.is_empty():
			_show_comm_line(_comm_queue.pop_front())
		elif _comm_delay_timer <= 0.0 and _comm_queue.is_empty():
			_is_playing = false
			narrative_ended.emit()
			comm_displayed.emit(_current_comm_id)

# ---------------------------------------------------------------------------
# Character loading
# ---------------------------------------------------------------------------
func _load_characters() -> void:
	var char_dir := "res://narrative/characters/"
	for fname in ["command.json", "intel.json", "comms.json"]:
		var path: String = char_dir + fname
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			push_warning("NarrativeDirector: cannot load character: %s" % path)
			continue
		var json := JSON.new()
		if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			var role: String = json.data.get("role", "")
			if role != "":
				_characters[role] = json.data

# ---------------------------------------------------------------------------
# Interlude loading
# ---------------------------------------------------------------------------
func _load_interludes() -> void:
	var interlude_dir := "res://narrative/interludes/"
	var files := [
		"between_1_2.json", "between_2_3.json", "between_3_4.json",
		"between_4_5.json", "between_5_6.json", "between_6_7.json"
	]
	for fname in files:
		var path: String = interlude_dir + fname
		var file := FileAccess.open(path, FileAccess.READ)
		if not file:
			continue
		var json := JSON.new()
		if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			var iid: String = json.data.get("interlude_id", fname.get_basename())
			_interlude_data[iid] = json.data

# ---------------------------------------------------------------------------
# Mission comm loading
# ---------------------------------------------------------------------------
func load_mission_comms(mission_number: int) -> void:
	_current_mission_number = mission_number
	_mission_comms = []
	_fired_comm_ids = {}
	_first_detection_fired = false
	_first_weapon_fired = false

	var comm_dir := "res://narrative/comms/"
	var mission_files := {
		1: "mission_1_threshold.json",
		2: "mission_2_cold_passage.json",
		3: "mission_3_sosus_ghost.json",
		4: "mission_4_northern_watch.json",
		5: "mission_5_crossing_the_line.json",
		6: "mission_6_reykjanes_ridge.json",
		7: "mission_7_silent_watch.json",
	}

	var fname: String = mission_files.get(mission_number, "")
	if fname == "":
		return

	var path := comm_dir + fname
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_warning("NarrativeDirector: cannot load comms for mission %d: %s" % [mission_number, path])
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) == OK and json.data is Dictionary:
		_mission_comms = json.data.get("comms", [])
		print("[NARRATIVE] Loaded %d comms for mission %d" % [_mission_comms.size(), mission_number])

func set_mission_timing(start_time: float, time_limit: float) -> void:
	_mission_start_time = start_time
	_time_limit = time_limit

# ---------------------------------------------------------------------------
# Trigger evaluation -- called by Main.gd signal handlers
# ---------------------------------------------------------------------------

## Called when a passive sonar detection occurs for the first time.
func on_first_passive_detection() -> void:
	if _first_detection_fired:
		return
	_first_detection_fired = true
	_try_trigger("first_passive_detection")

## Called when a contact is classified.
func on_contact_classified(classification: String) -> void:
	_try_trigger("contact_classified", {"classification_result": classification})

## Called when an enemy fires a weapon.
func on_enemy_weapon_fired(weapon_type: String) -> void:
	_try_trigger("enemy_weapon_fired", {"weapon_type": weapon_type})

## Called when the player activates sonar.
func on_player_active_sonar() -> void:
	_try_trigger("player_active_sonar")

## Called when the player fires their first weapon.
func on_first_player_weapon_fired() -> void:
	if _first_weapon_fired:
		return
	_first_weapon_fired = true
	_try_trigger("first_player_weapon_fired")

## Called when an enemy unit accelerates past a threshold.
func on_enemy_speed_increase(platform_type: String, speed_kts: float) -> void:
	_try_trigger("enemy_speed_increase", {"platform_type": platform_type, "speed_threshold_kts": speed_kts})

## Called when ESM detects a radar emission.
func on_esm_detection(radar_type: String) -> void:
	_try_trigger("esm_detection", {"radar_type": radar_type})

## Called on sim tick -- checks time-based triggers.
func check_time_triggers(sim_time: float) -> void:
	for comm in _mission_comms:
		if comm.get("id", "") in _fired_comm_ids:
			continue
		var trigger: String = comm.get("trigger", "")

		if trigger == "time_elapsed":
			var required: float = comm.get("trigger_params", {}).get("elapsed_seconds", 0.0)
			if required > 0 and (sim_time - _mission_start_time) >= required:
				_fire_comm(comm)

		elif trigger == "time_remaining":
			var remaining: float = comm.get("trigger_params", {}).get("remaining_seconds", 0.0)
			if _time_limit > 0 and remaining > 0:
				var time_left: float = _time_limit - sim_time
				if time_left <= remaining:
					_fire_comm(comm)

		elif trigger == "mission_start":
			var delay: float = comm.get("trigger_params", {}).get("delay_seconds", 0.0)
			if (sim_time - _mission_start_time) >= delay:
				_fire_comm(comm)

## Called on scenario end or near-end for fallback triggers.
func on_mission_ending() -> void:
	for comm in _mission_comms:
		if comm.get("id", "") in _fired_comm_ids:
			continue
		if comm.get("fallback_trigger", "") == "time_remaining":
			_fire_comm(comm)

func _try_trigger(trigger_name: String, params: Dictionary = {}) -> void:
	for comm in _mission_comms:
		if comm.get("id", "") in _fired_comm_ids:
			continue
		if comm.get("trigger", "") != trigger_name:
			continue
		# Check trigger_params match if specified in the comm definition
		# (loose matching -- if comm defines params, event params must contain them)
		var comm_params: Dictionary = comm.get("trigger_params", {})
		var match_ok: bool = true
		for key in comm_params:
			if key in params:
				# String match or numeric threshold
				if params[key] is String and comm_params[key] is String:
					if params[key] != comm_params[key]:
						match_ok = false
						break
			# If event doesn't provide the key, allow (loose match)
		if match_ok:
			_fire_comm(comm)

func _fire_comm(comm: Dictionary) -> void:
	var comm_id: String = comm.get("id", "")
	if comm_id in _fired_comm_ids:
		return
	_fired_comm_ids[comm_id] = true

	# Check for silence flag (no radio traffic -- the absence IS the beat)
	if comm.get("silence", false):
		print("[NARRATIVE] Silence beat: %s" % comm_id)
		comm_displayed.emit(comm_id)
		return

	var lines: Array = comm.get("lines", [])
	if lines.is_empty():
		comm_displayed.emit(comm_id)
		return

	_current_comm_id = comm_id
	_is_playing = true
	narrative_started.emit()

	# Queue all lines: first plays immediately, rest go into queue
	var first: Dictionary = lines[0]
	for i in range(1, lines.size()):
		_comm_queue.append(lines[i])
	_show_comm_line(first)

# ---------------------------------------------------------------------------
# Comm overlay rendering
# ---------------------------------------------------------------------------
func _show_comm_line(line: Dictionary) -> void:
	var role: String = line.get("role", "COMMS")
	var text: String = line.get("text", "")
	var color: Color = ROLE_COLORS.get(role, Color(0.6, 0.7, 0.8))

	# Override color from character data if available
	if role in _characters:
		var hex: String = _characters[role].get("color", "")
		if hex != "":
			color = Color.from_string(hex, color)

	_ensure_comm_overlay()
	if _comm_role_label:
		_comm_role_label.text = role
		_comm_role_label.add_theme_color_override("font_color", color)
	if _comm_text_label:
		_comm_text_label.text = text
		_comm_text_label.add_theme_color_override("font_color", Color(0.75, 0.82, 0.9))

	if _comm_overlay:
		_comm_overlay.visible = true
		_comm_overlay.modulate.a = 1.0

	_comm_timer = COMM_DISPLAY_SECONDS
	print("[NARRATIVE] %s: %s" % [role, text])

func _hide_comm_overlay() -> void:
	if _comm_overlay:
		_comm_overlay.visible = false

func _ensure_comm_overlay() -> void:
	if _comm_overlay and is_instance_valid(_comm_overlay):
		return

	# Build a styled comm overlay at top-center of the screen.
	# This is a CanvasLayer child so it floats above the game world.
	var canvas := CanvasLayer.new()
	canvas.name = "CommOverlayCanvas"
	canvas.layer = 80
	add_child(canvas)

	_comm_overlay = PanelContainer.new()
	_comm_overlay.name = "CommOverlay"
	_comm_overlay.visible = false

	# Position: top center, 600px wide
	_comm_overlay.anchor_left = 0.5
	_comm_overlay.anchor_top = 0.0
	_comm_overlay.anchor_right = 0.5
	_comm_overlay.anchor_bottom = 0.0
	_comm_overlay.offset_left = -300.0
	_comm_overlay.offset_top = 60.0
	_comm_overlay.offset_right = 300.0
	_comm_overlay.offset_bottom = 140.0
	_comm_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.04, 0.08, 0.92)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.2, 0.45, 0.7, 0.6)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_right = 4
	style.corner_radius_bottom_left = 4
	style.content_margin_left = 16.0
	style.content_margin_top = 10.0
	style.content_margin_right = 16.0
	style.content_margin_bottom = 10.0
	_comm_overlay.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	_comm_overlay.add_child(vbox)

	_comm_role_label = Label.new()
	_comm_role_label.add_theme_font_size_override("font_size", 11)
	_comm_role_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_comm_role_label)

	_comm_text_label = Label.new()
	_comm_text_label.add_theme_font_size_override("font_size", 13)
	_comm_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_comm_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(_comm_text_label)

	canvas.add_child(_comm_overlay)

# ---------------------------------------------------------------------------
# Interlude display
# ---------------------------------------------------------------------------

## Show the interlude screen between two missions. Returns false if no interlude exists.
func show_interlude(after_mission: int) -> bool:
	var key := "between_%d_%d" % [after_mission, after_mission + 1]
	if key not in _interlude_data:
		return false

	var data: Dictionary = _interlude_data[key]
	var text: String = data.get("text", "")
	if text == "":
		return false

	# Substitute dynamic fields
	if data.has("dynamic_fields"):
		var fields: Dictionary = data.get("dynamic_fields", {})
		for placeholder in fields:
			var source: String = fields[placeholder]
			var replacement: String = ""
			if source == "campaign_lost_ships":
				replacement = _get_campaign_loss_text()
			text = text.replace("{%s}" % placeholder, replacement)

	_show_interlude_panel(text, data.get("classification", ""))
	return true

func _get_campaign_loss_text() -> String:
	if not CampaignManager.campaign_active:
		return ""
	var lost: Array = CampaignManager.get_lost_ships()
	if lost.is_empty():
		return ""
	var parts: Array = []
	for ship in lost:
		var sname: String = ship.get("name", "Unknown")
		parts.append("USS %s" % sname if not sname.begins_with("USS") else sname)
	return "USS " + ", ".join(parts) if parts.size() > 0 else ""

func _show_interlude_panel(text: String, classification: String) -> void:
	close_interlude()
	_interlude_active = true

	_interlude_panel = PanelContainer.new()
	_interlude_panel.name = "InterludePanel"

	# Full screen dark overlay
	_interlude_panel.anchor_left = 0.0
	_interlude_panel.anchor_top = 0.0
	_interlude_panel.anchor_right = 1.0
	_interlude_panel.anchor_bottom = 1.0
	_interlude_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.01, 0.02, 0.04, 0.98)
	style.content_margin_left = 100.0
	style.content_margin_top = 80.0
	style.content_margin_right = 100.0
	style.content_margin_bottom = 80.0
	_interlude_panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_interlude_panel.add_child(vbox)

	# Classification header
	if classification != "":
		var class_lbl := Label.new()
		class_lbl.text = "[%s]" % classification.to_upper()
		class_lbl.add_theme_font_size_override("font_size", 10)
		class_lbl.add_theme_color_override("font_color", Color(0.5, 0.3, 0.3))
		class_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		class_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vbox.add_child(class_lbl)

	# Main text -- monospaced feel, green-on-dark (teletype style)
	var text_lbl := Label.new()
	text_lbl.text = text
	text_lbl.add_theme_font_size_override("font_size", 14)
	text_lbl.add_theme_color_override("font_color", Color(0.15, 0.85, 0.15))
	text_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	text_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(text_lbl)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 40)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)

	# Continue hint
	var hint_lbl := Label.new()
	hint_lbl.text = "[ SPACE to continue ]"
	hint_lbl.add_theme_font_size_override("font_size", 12)
	hint_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(hint_lbl)

	# Add to scene tree via a CanvasLayer so it covers everything
	var canvas := CanvasLayer.new()
	canvas.name = "InterludeCanvas"
	canvas.layer = 90
	canvas.add_child(_interlude_panel)
	add_child(canvas)

func close_interlude() -> void:
	if _interlude_panel and is_instance_valid(_interlude_panel):
		var canvas: Node = _interlude_panel.get_parent()
		_interlude_panel.queue_free()
		if canvas:
			canvas.queue_free()
	_interlude_panel = null
	_interlude_active = false

func dismiss_interlude() -> void:
	close_interlude()
	interlude_finished.emit()

func is_interlude_active() -> bool:
	return _interlude_active

# ---------------------------------------------------------------------------
# Dialogic briefing support (legacy -- kept for backward compatibility)
# ---------------------------------------------------------------------------
func _has_dialogic() -> bool:
	if not _dialogic:
		_dialogic = get_node_or_null("/root/Dialogic")
		if _dialogic and not _timeline_class:
			_timeline_class = load("res://addons/dialogic/Resources/timeline.gd") as GDScript
	return _dialogic != null

func _load_timeline(path: String) -> Resource:
	if not _timeline_class:
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_warning("NarrativeDirector: cannot open %s: error %d" % [path, FileAccess.get_open_error()])
		return null
	var tml = _timeline_class.new()
	tml.from_text(file.get_as_text())
	return tml

func play_briefing(scenario_data: Dictionary) -> bool:
	var timeline_id: String = scenario_data.get("timeline", "")
	if timeline_id == "":
		return false
	if not _has_dialogic():
		return false
	var path := "res://narrative/briefings/%s.dtl" % timeline_id
	if not FileAccess.file_exists(path):
		push_warning("NarrativeDirector: briefing timeline not found: %s" % path)
		return false
	_sim_was_paused = SimulationWorld.is_paused
	return _begin_narrative(path)

func play_comm(event_name: String) -> void:
	if not _has_dialogic():
		return
	var path := "res://narrative/comms/%s.dtl" % event_name
	if not FileAccess.file_exists(path):
		return
	_sim_was_paused = SimulationWorld.is_paused
	SimulationWorld.is_paused = true
	_begin_narrative(path)

func play_interlude(timeline_name: String) -> void:
	if not _has_dialogic():
		return
	var path := "res://narrative/interludes/%s.dtl" % timeline_name
	if not FileAccess.file_exists(path):
		push_warning("NarrativeDirector: interlude not found: %s" % path)
		return
	_sim_was_paused = SimulationWorld.is_paused
	SimulationWorld.is_paused = true
	_begin_narrative(path)

func _begin_narrative(path: String) -> bool:
	if _is_playing:
		push_warning("NarrativeDirector: already playing, ignoring %s" % path)
		return false
	var tml: Resource = _load_timeline(path)
	if tml == null:
		push_warning("NarrativeDirector: failed to parse timeline: %s" % path)
		return false
	_is_playing = true
	narrative_started.emit()
	_dialogic.timeline_ended.connect(_on_timeline_ended, CONNECT_ONE_SHOT)
	_dialogic.start(tml)
	return true

func _on_timeline_ended() -> void:
	_is_playing = false
	narrative_ended.emit()
	if not _sim_was_paused:
		SimulationWorld.is_paused = false

func is_playing() -> bool:
	if _is_playing and _dialogic:
		if _dialogic.current_timeline == null and _dialogic.current_state == 0:
			_is_playing = false
			narrative_ended.emit()
	return _is_playing
