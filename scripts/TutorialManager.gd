extends Node
## TutorialManager -- Autoload singleton. 11-step guided tutorial state machine.
##
## Activated by Main.gd when loading a scenario with "tutorial": true.
## Connects to SimulationWorld and RenderBridge signals to detect player actions
## and advance through tutorial steps. Emits prompts via HUD.

# ---------------------------------------------------------------------------
# Step enum
# ---------------------------------------------------------------------------
enum Step {
	STEP_ORIENT,
	STEP_CAMERA,
	STEP_SELECT,
	STEP_WAYPOINT,
	STEP_TIMESCALE,
	STEP_DETECTION,
	STEP_SONAR,
	STEP_DESIGNATE,
	STEP_FIRE,
	STEP_RESOLUTION,
	STEP_COMPLETE,
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
var is_active: bool = false
var current_step: int = Step.STEP_ORIENT
var tutorial_completed: bool = false  # Flag checked by Main.gd after scene reload

var _hud: Control = null
var _render_bridge: Node2D = null
var _step_complete: bool = false  # Guard against double-advance
var _zoom_changed: bool = false  # Track zoom for STEP_CAMERA
var _pending_unpause_advance: bool = false  # Advance on next unpause
var _sonar_was_active: bool = false  # Track sonar state for STEP_SONAR

# ---------------------------------------------------------------------------
# Activation / Deactivation
# ---------------------------------------------------------------------------
func activate(hud_node: Control, render_bridge_node: Node2D) -> void:
	_hud = hud_node
	_render_bridge = render_bridge_node
	is_active = true
	current_step = Step.STEP_ORIENT
	_step_complete = false
	_zoom_changed = false
	_pending_unpause_advance = false
	_sonar_was_active = false

	# Hide help panel during tutorial -- we show our own prompts
	if _hud and _hud.has_method("set_help_visible"):
		_hud.set_help_visible(false)

	# Connect SimulationWorld signals
	SimulationWorld.unit_detected.connect(_on_unit_detected)
	SimulationWorld.unit_destroyed.connect(_on_unit_destroyed)
	SimulationWorld.weapon_fired.connect(_on_weapon_fired)
	SimulationWorld.weapon_resolved.connect(_on_weapon_resolved)
	SimulationWorld.contact_classified.connect(_on_contact_classified)
	SimulationWorld.time_scale_changed.connect(_on_time_scale_changed)
	SimulationWorld.unit_moved.connect(_on_unit_moved)

	# Connect RenderBridge signals
	if _render_bridge:
		_render_bridge.unit_selected.connect(_on_unit_selected)
		_render_bridge.fire_target_designated.connect(_on_fire_target_designated)
		_render_bridge.camera_recentered.connect(_on_camera_recentered)
		_render_bridge.camera_zoomed.connect(_on_camera_zoomed)

	# Show the first step
	_show_step(current_step)

func deactivate() -> void:
	is_active = false
	_step_complete = false
	_zoom_changed = false
	_pending_unpause_advance = false
	_sonar_was_active = false

	# Disconnect SimulationWorld signals
	if SimulationWorld.unit_detected.is_connected(_on_unit_detected):
		SimulationWorld.unit_detected.disconnect(_on_unit_detected)
	if SimulationWorld.unit_destroyed.is_connected(_on_unit_destroyed):
		SimulationWorld.unit_destroyed.disconnect(_on_unit_destroyed)
	if SimulationWorld.weapon_fired.is_connected(_on_weapon_fired):
		SimulationWorld.weapon_fired.disconnect(_on_weapon_fired)
	if SimulationWorld.weapon_resolved.is_connected(_on_weapon_resolved):
		SimulationWorld.weapon_resolved.disconnect(_on_weapon_resolved)
	if SimulationWorld.contact_classified.is_connected(_on_contact_classified):
		SimulationWorld.contact_classified.disconnect(_on_contact_classified)
	if SimulationWorld.time_scale_changed.is_connected(_on_time_scale_changed):
		SimulationWorld.time_scale_changed.disconnect(_on_time_scale_changed)
	if SimulationWorld.unit_moved.is_connected(_on_unit_moved):
		SimulationWorld.unit_moved.disconnect(_on_unit_moved)

	# Disconnect RenderBridge signals
	if _render_bridge:
		if _render_bridge.unit_selected.is_connected(_on_unit_selected):
			_render_bridge.unit_selected.disconnect(_on_unit_selected)
		if _render_bridge.fire_target_designated.is_connected(_on_fire_target_designated):
			_render_bridge.fire_target_designated.disconnect(_on_fire_target_designated)
		if _render_bridge.camera_recentered.is_connected(_on_camera_recentered):
			_render_bridge.camera_recentered.disconnect(_on_camera_recentered)
		if _render_bridge.camera_zoomed.is_connected(_on_camera_zoomed):
			_render_bridge.camera_zoomed.disconnect(_on_camera_zoomed)

	# Restore help panel
	if _hud and _hud.has_method("set_help_visible"):
		_hud.set_help_visible(true)

	_hud = null
	_render_bridge = null

# ---------------------------------------------------------------------------
# Step display
# ---------------------------------------------------------------------------
func _show_step(idx: int) -> void:
	_step_complete = false
	_zoom_changed = false
	_pending_unpause_advance = false
	var step_name: String = Step.keys()[idx]
	var text: String = _get_prompt_text(step_name)
	var pause_gated: bool = false

	# Certain steps pause the sim and require SPACE to dismiss
	match idx:
		Step.STEP_ORIENT:
			pause_gated = true
			# Sim is already paused from Main.gd
		Step.STEP_DETECTION:
			pause_gated = true
			SimulationWorld.pause()
			# After SPACE dismisses prompt and unpauses, advance via _process
			_pending_unpause_advance = true
		Step.STEP_SONAR:
			pause_gated = true
			SimulationWorld.pause()
			# Record current sonar state so we can detect the toggle
			if "TUT_PLAYER" in SimulationWorld.units:
				_sonar_was_active = SimulationWorld.units["TUT_PLAYER"].get("emitting_sonar_active", false)
		Step.STEP_FIRE:
			pause_gated = true
			SimulationWorld.pause()
			# Don't set _pending_unpause_advance here -- STEP_FIRE waits for
			# weapon_fired signal AFTER unpause, not just the unpause itself
		Step.STEP_COMPLETE:
			pause_gated = true
			SimulationWorld.pause()
			# When SPACE dismisses the prompt and unpauses, _process handles reload
			_pending_unpause_advance = true

	# STEP_WAYPOINT: set time scale to 5 so the ship moves visibly
	if idx == Step.STEP_WAYPOINT:
		SimulationWorld.set_time_scale(5.0)

	# Ensure TUT_PLAYER stays selected for steps that need it (prevents soft-lock)
	if idx >= Step.STEP_WAYPOINT and _render_bridge and _render_bridge._selected_unit_id == "":
		_render_bridge.force_select_unit("TUT_PLAYER")

	if _hud and _hud.has_method("show_tutorial_prompt"):
		_hud.show_tutorial_prompt(text, pause_gated)

# ---------------------------------------------------------------------------
# Step advancement
# ---------------------------------------------------------------------------
func _advance_step() -> void:
	if _step_complete:
		return
	_step_complete = true

	# Dismiss current prompt if still showing
	if _hud and _hud.has_method("dismiss_tutorial_prompt"):
		_hud.dismiss_tutorial_prompt()

	current_step += 1
	if current_step >= Step.size():
		current_step = Step.STEP_COMPLETE

	_show_step(current_step)

# ---------------------------------------------------------------------------
# Process -- checks for unpause-triggered advances and sonar toggle
# ---------------------------------------------------------------------------
func _process(_delta: float) -> void:
	if not is_active:
		return

	# STEP_ORIENT: advance when sim unpauses (player pressed SPACE to dismiss)
	if current_step == Step.STEP_ORIENT and not _step_complete:
		if not SimulationWorld.is_paused:
			_advance_step()
			return

	# STEP_SONAR: after SPACE dismisses prompt and unpauses, poll for sonar toggle
	if current_step == Step.STEP_SONAR and not _step_complete:
		if not SimulationWorld.is_paused:
			# Guard: re-select TUT_PLAYER if selection was lost (prevents soft-lock)
			if _render_bridge and _render_bridge._selected_unit_id == "":
				_render_bridge.force_select_unit("TUT_PLAYER")
			if "TUT_PLAYER" in SimulationWorld.units:
				var current_sonar: bool = SimulationWorld.units["TUT_PLAYER"].get("emitting_sonar_active", false)
				if current_sonar != _sonar_was_active:
					_advance_step()
					return

	# Pending unpause advance (STEP_DETECTION uses this; STEP_COMPLETE uses it for reload)
	if _pending_unpause_advance and not _step_complete:
		if not SimulationWorld.is_paused:
			_pending_unpause_advance = false
			if current_step == Step.STEP_COMPLETE:
				# Tutorial finished -- load the real mission
				tutorial_completed = true
				deactivate()
				SimulationWorld.pause()
				get_tree().call_deferred("reload_current_scene")
				return
			else:
				_advance_step()
				return

# ---------------------------------------------------------------------------
# Signal handlers -- SimulationWorld
# ---------------------------------------------------------------------------
func _on_unit_detected(_detector_id: String, _target_id: String, _detection: Dictionary) -> void:
	if not is_active:
		return
	# Detection fires continuously; STEP_DETECTION is shown after STEP_TIMESCALE
	# advances. The detection prompt is shown via the normal step flow. The
	# _pending_unpause_advance flag handles the SPACE->advance transition.

func _on_unit_destroyed(unit_id: String) -> void:
	if not is_active or _step_complete:
		return
	# STEP_RESOLUTION: enemy surface destroyed = tutorial almost done
	if current_step == Step.STEP_RESOLUTION and unit_id == "TUT_ENEMY_SURFACE":
		_advance_step()

func _on_weapon_fired(_weapon_id: String, shooter_id: String, target_id: String, _weapon_data: Dictionary) -> void:
	if not is_active or _step_complete:
		return
	# STEP_FIRE: player fires at the designated target -> advance to RESOLUTION
	if current_step == Step.STEP_FIRE and shooter_id == "TUT_PLAYER" and target_id == "TUT_ENEMY_SURFACE":
		_advance_step()

func _on_weapon_resolved(_weapon_id: String, target_id: String, hit: bool, _damage: float) -> void:
	if not is_active or _step_complete:
		return
	# STEP_RESOLUTION: if the weapon misses, show full tutorial panel prompt
	if current_step == Step.STEP_RESOLUTION and target_id == "TUT_ENEMY_SURFACE" and not hit:
		if _hud and _hud.has_method("show_tutorial_prompt"):
			_hud.show_tutorial_prompt("MISS! The target's defenses intercepted your missile.\n\nPress F to fire another Harpoon. Persistence wins at sea.", false)

func _on_contact_classified(_detector_id: String, _target_id: String, _classification: Dictionary) -> void:
	pass  # Connected for completeness; not used for step triggers

func _on_time_scale_changed(new_scale: float) -> void:
	if not is_active or _step_complete:
		return
	# STEP_TIMESCALE: player sets time to 15x -> advance to STEP_DETECTION
	if current_step == Step.STEP_TIMESCALE and is_equal_approx(new_scale, 15.0):
		_advance_step()

func _on_unit_moved(unit_id: String, _old_pos: Vector2, _new_pos: Vector2) -> void:
	if not is_active or _step_complete:
		return
	# STEP_WAYPOINT: player's unit is moving toward a waypoint
	if current_step == Step.STEP_WAYPOINT and unit_id == "TUT_PLAYER":
		if unit_id in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[unit_id]
			if u["waypoints"].size() > 0:
				_advance_step()

# ---------------------------------------------------------------------------
# Signal handlers -- RenderBridge
# ---------------------------------------------------------------------------
func _on_unit_selected(unit_id: String) -> void:
	if not is_active or _step_complete:
		return
	if current_step == Step.STEP_SELECT and unit_id == "TUT_PLAYER":
		_advance_step()

func _on_fire_target_designated(target_id: String) -> void:
	if not is_active or _step_complete:
		return
	if current_step == Step.STEP_DESIGNATE and target_id == "TUT_ENEMY_SURFACE":
		_advance_step()

func _on_camera_recentered() -> void:
	if not is_active or _step_complete:
		return
	if current_step == Step.STEP_CAMERA and _zoom_changed:
		_advance_step()

func _on_camera_zoomed() -> void:
	if not is_active:
		return
	if current_step == Step.STEP_CAMERA:
		_zoom_changed = true

# ---------------------------------------------------------------------------
# Prompt text for each step
# ---------------------------------------------------------------------------
func _get_prompt_text(step_name: String) -> String:
	match step_name:
		"STEP_ORIENT":
			return "WELCOME TO THRESHOLD\n\nYou command USS Connor (DDG-54), the blue diamond at center screen.\nBlue = friendly forces. Red = confirmed enemy. Orange = unidentified contact.\n\nThe line extending from your ship shows its heading.\n\nPress SPACE to begin."
		"STEP_CAMERA":
			return "CAMERA CONTROLS\n\n+/- keys: zoom in/out (or scroll wheel).\nArrow keys: pan the map (or middle-drag).\nH key: snap camera back to your fleet.\n\nTry zooming in with +, then press H to re-center."
		"STEP_SELECT":
			return "SELECTING A UNIT\n\nLeft-click on USS Connor (the blue symbol) to select it.\n\nWhen selected, the unit panel (bottom-left) shows speed, heading, weapons, and sensors.\nA pulsing bracket appears around the selected unit."
		"STEP_WAYPOINT":
			return "MOVEMENT ORDERS\n\nRight-click anywhere on the map to send USS Connor to that position.\nA green line shows the ordered waypoint.\n\nGive your ship a heading. Watch it turn and begin moving."
		"STEP_TIMESCALE":
			return "TIME COMPRESSION\n\nNaval operations take hours. Keys 1-5 compress time:\n  1 = real-time  2 = 5x  3 = 15x  4 = 30x  5 = 60x\n\nPress 3 to run at 15x speed."
		"STEP_DETECTION":
			return "RADAR CONTACT\n\nYou should see an orange diamond on the map -- that is a radar contact.\nYour AN/SPY-1D radar detected a surface vessel.\n\nThe contacts panel (right side) shows:\n  [reporter] [designator] [bearing] [range] [method] [confidence]\n\nSIERRA-01 = NATO designator for this surface contact.\nRAD = detected by radar.\n\nPress SPACE to continue."
		"STEP_SONAR":
			return "SONAR\n\nPassive sonar runs automatically -- your ship is always listening.\nPress S to activate sonar (pinging) -- reveals more but exposes your position.\n\nSubmarines are invisible to radar. Sonar is the only way to find them.\n\nPress SPACE to resume, then press S to toggle active sonar."
		"STEP_DESIGNATE":
			return "TARGET DESIGNATION\n\nLeft-click on the orange contact marker to designate it.\n\nThe unit panel will show TARGET: SIERRA-01 with range and weapon status.\nDesignating a target locks your weapons onto that contact."
		"STEP_FIRE":
			return "ENGAGING THE TARGET\n\nPress F to fire your selected weapon at the designated target.\nC cycles through available weapons.\n\nYou have:\n  Harpoon (AGM-84): anti-ship missile, 67 NM\n  SM-2 (RIM-66): air defense only -- cannot target surface ships\n  ASROC (RUR-5): rocket-torpedo, 12 NM\n  Mk 46 Torpedo: short-range, 4 NM\n\nPress SPACE to resume, then press F to fire."
		"STEP_RESOLUTION":
			return "WEAPON IN FLIGHT\n\nThe missile is in flight. Watch the map.\n\nHit = contact destroyed. MISSION COMPLETE.\nMiss = press F to fire again. You have multiple Harpoons remaining."
		"STEP_COMPLETE":
			return "TUTORIAL COMPLETE\n\nYou have learned:\n  Camera (scroll, pan, H)\n  Unit selection (left-click)\n  Movement (right-click waypoints)\n  Time compression (1-5)\n  Contact detection (contacts panel)\n  Radar toggle (R) and Sonar toggle (S)\n  Target designation (left-click enemy)\n  Weapons (F to fire, C to cycle)\n  Helicopter launch (L key)\n\nPassive sonar gives bearing only -- hold contact to build a range solution (TMA).\nSubs don't show on radar. Helicopters with dipping sonar extend your reach.\n\nPress SPACE to begin your first patrol."
		_:
			return ""
