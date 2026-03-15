extends Node2D
## Main scene controller. Loads the default scenario and kicks off the sim.
## Handles campaign flow: when CampaignManager is active, loads campaign missions
## sequentially. Scene reloads (via RenderBridge SPACE) re-enter _ready() which
## picks up the next campaign mission automatically.

@onready var render_bridge: Node2D = $RenderBridge

var hud: Control = null
var _campaign_complete_shown: bool = false

func _exit_tree() -> void:
	# Disconnect signal handlers from autoload singletons to prevent accumulation across scene reloads
	if SimulationWorld.unit_destroyed.is_connected(_on_unit_destroyed_score):
		SimulationWorld.unit_destroyed.disconnect(_on_unit_destroyed_score)
	if SimulationWorld.weapon_fired.is_connected(_on_weapon_fired_score):
		SimulationWorld.weapon_fired.disconnect(_on_weapon_fired_score)
	if SimulationWorld.sim_tick.is_connected(_on_sim_tick_tracking):
		SimulationWorld.sim_tick.disconnect(_on_sim_tick_tracking)
	if SimulationWorld.scenario_ended.is_connected(_on_scenario_ended_campaign):
		SimulationWorld.scenario_ended.disconnect(_on_scenario_ended_campaign)

func _ready() -> void:
	var scenario_path: String

	if CampaignManager.campaign_active:
		if CampaignManager.is_campaign_complete():
			_campaign_complete_shown = true
			hud = render_bridge.find_child("HUD", true, false) if render_bridge else null
			if hud and hud.has_method("show_campaign_complete"):
				hud.show_campaign_complete(CampaignManager.mission_history)
			CampaignManager.reset_campaign()
			return
		scenario_path = CampaignManager.get_current_mission_path()
		if scenario_path == "":
			push_error("Main: campaign active but no mission path!")
			return
	elif TutorialManager.tutorial_completed:
		scenario_path = "res://scenarios/north_atlantic_asw.json"
		TutorialManager.tutorial_completed = false
	elif ScenarioLoader.override_scenario != "":
		scenario_path = ScenarioLoader.override_scenario
		ScenarioLoader.override_scenario = ""
	else:
		# Fallback: if launched directly (not from menu), load default scenario
		scenario_path = "res://scenarios/north_atlantic_asw.json"

	_start_scenario_from_path(scenario_path)

func _unhandled_input(event: InputEvent) -> void:
	if _campaign_complete_shown and event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_campaign_complete_shown = false
		get_tree().change_scene_to_file("res://scenes/mainmenu.tscn")

func _start_scenario_from_path(scenario_path: String) -> void:
	var scenario_data: Dictionary = ScenarioLoader.load_scenario_file(scenario_path)
	if scenario_data.is_empty():
		push_error("Main: failed to load scenario: %s" % scenario_path)
		return
	_start_scenario(scenario_data)

func _start_scenario(scenario_data: Dictionary) -> void:
	SimulationWorld.load_scenario(scenario_data)

	# Campaign: filter out ships lost in prior missions
	if CampaignManager.campaign_active:
		var lost_ids: Array = []
		for ship_id in CampaignManager.fleet_status:
			if not CampaignManager.fleet_status[ship_id].get("alive", true):
				lost_ids.append(ship_id)
		for lost_id in lost_ids:
			if lost_id in SimulationWorld.units:
				SimulationWorld.units[lost_id]["is_alive"] = false
				SimulationWorld.units[lost_id]["visible"] = false
				SimulationWorld.unit_destroyed.emit(lost_id)
				print("[THRESHOLD] %s was lost in a prior mission -- not available." % lost_id)

	# Start paused -- player presses SPACE to begin
	SimulationWorld.is_paused = true
	SimulationWorld.time_scale = 1.0

	# Center camera on player task force
	if render_bridge and render_bridge.camera:
		render_bridge.camera.position = Vector2.ZERO
		render_bridge.camera.zoom = Vector2(0.8, 0.8)

	hud = render_bridge.find_child("HUD", true, false) if render_bridge else null
	var is_tutorial: bool = scenario_data.get("tutorial", false)

	if is_tutorial:
		# Tutorial mode: activate TutorialManager, skip briefing/time-limit/auto-select
		if hud:
			TutorialManager.activate(hud, render_bridge)
	else:
		# Normal mode: show briefing, set time limit, auto-select first player unit
		if hud and hud.has_method("show_briefing"):
			var briefing_text: String = scenario_data.get("briefing", "")
			if briefing_text != "":
				briefing_text += "\n\nTIP: Press 2-5 to increase time compression."
				hud.show_briefing(briefing_text)

		# Campaign mission header
		if CampaignManager.campaign_active and hud and hud.has_method("set_campaign_info"):
			hud.set_campaign_info(
				CampaignManager.get_current_mission_number(),
				CampaignManager.get_total_missions(),
				scenario_data.get("name", "")
			)

		# Item 4: Set time limit from scenario's victory condition
		if hud and hud.has_method("set_time_limit"):
			var time_limit: float = scenario_data.get("victory_condition", {}).get("time_limit_seconds", 0.0)
			if time_limit > 0.0:
				hud.set_time_limit(time_limit)

		# Auto-select the first player unit so the unit panel isn't blank on start
		if render_bridge:
			for uid in SimulationWorld.units:
				if SimulationWorld.units[uid].get("faction", "") == "player":
					render_bridge.force_select_unit(uid)
					break

	# Item 15: Wire ScoreManager for non-tutorial scenarios
	if not is_tutorial:
		var enemy_count: int = 0
		for uid in SimulationWorld.units:
			if SimulationWorld.units[uid].get("faction", "") == "enemy":
				enemy_count += 1
		ScoreManager.start_tracking(enemy_count)

		# Connect signals for score tracking
		if not SimulationWorld.unit_destroyed.is_connected(_on_unit_destroyed_score):
			SimulationWorld.unit_destroyed.connect(_on_unit_destroyed_score)
		if not SimulationWorld.weapon_fired.is_connected(_on_weapon_fired_score):
			SimulationWorld.weapon_fired.connect(_on_weapon_fired_score)

		# Wire maintain_contact tracking progress
		var victory_type: String = scenario_data.get("victory_condition", {}).get("type", "")
		if victory_type == "maintain_contact":
			var required_secs: float = scenario_data.get("victory_condition", {}).get("contact_duration_seconds", 1800.0)
			if hud and hud.has_method("set_tracking_target"):
				hud.set_tracking_target(required_secs)
			# Connect sim_tick for progress updates
			if not SimulationWorld.sim_tick.is_connected(_on_sim_tick_tracking):
				SimulationWorld.sim_tick.connect(_on_sim_tick_tracking)

	# Connect scenario_ended for campaign recording (before scene reload)
	if not SimulationWorld.scenario_ended.is_connected(_on_scenario_ended_campaign):
		SimulationWorld.scenario_ended.connect(_on_scenario_ended_campaign)

	print("[THRESHOLD] Scenario loaded: %s" % scenario_data.get("name", ""))
	if CampaignManager.campaign_active:
		print("[THRESHOLD] Campaign mission %d of %d" % [CampaignManager.get_current_mission_number(), CampaignManager.get_total_missions()])
	if is_tutorial:
		print("[THRESHOLD] Tutorial mode. Follow the on-screen prompts.")
	else:
		print("[THRESHOLD] Press SPACE to begin. F to fire. Right-click to set waypoints.")

# ---------------------------------------------------------------------------
# Campaign
# ---------------------------------------------------------------------------
func _on_scenario_ended_campaign(result: String) -> void:
	if not CampaignManager.campaign_active:
		return

	# Compute score before ScoreManager.stop_tracking is called by HUD.show_result
	var time_limit: float = SimulationWorld.scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
	var score_data: Dictionary = ScoreManager.compute_score(SimulationWorld.sim_time, time_limit)

	# Collect lost and surviving player units
	var lost := []
	var surviving := []
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if u["faction"] == "player":
			if u["is_alive"]:
				surviving.append(uid)
			else:
				lost.append(uid)

	CampaignManager.record_mission_result(result, score_data["score"], score_data["grade"], lost, surviving)
	# Scene will reload via RenderBridge SPACE handler -> _ready() picks up next mission

# ---------------------------------------------------------------------------
# Item 15: ScoreManager signal handlers
# ---------------------------------------------------------------------------
func _on_unit_destroyed_score(unit_id: String) -> void:
	if unit_id in SimulationWorld.units:
		var faction: String = SimulationWorld.units[unit_id].get("faction", "")
		if faction == "enemy":
			ScoreManager.record_kill()
		elif faction == "player":
			ScoreManager.record_loss()

func _on_weapon_fired_score(_weapon_id: String, shooter_id: String, _target_id: String, _weapon_data: Dictionary) -> void:
	# Only count player weapon firings
	if shooter_id in SimulationWorld.units and SimulationWorld.units[shooter_id].get("faction", "") == "player":
		ScoreManager.record_weapon_fired()

func _on_sim_tick_tracking(_tick: int, _time: float) -> void:
	if not hud or not hud.has_method("update_tracking_progress"):
		return
	# Read accumulator and tracking state from SimulationWorld
	var accumulated: float = SimulationWorld._contact_accumulator
	# Check if all enemies are currently tracked
	var all_tracked: bool = true
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if not u["is_alive"] or u["faction"] != "enemy":
			continue
		var tracked: bool = false
		for puid in SimulationWorld.units:
			var pu: Dictionary = SimulationWorld.units[puid]
			if pu["is_alive"] and pu["faction"] == "player":
				if uid in pu.get("contacts", {}):
					tracked = true
					break
		if not tracked:
			all_tracked = false
			break
	hud.update_tracking_progress(accumulated, all_tracked)
