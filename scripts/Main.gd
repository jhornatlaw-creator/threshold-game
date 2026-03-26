extends Node2D
## Main scene controller. Loads the default scenario and kicks off the sim.
## Handles campaign flow: when CampaignManager is active, loads campaign missions
## sequentially. Scene reloads (via RenderBridge SPACE) re-enter _ready() which
## picks up the next campaign mission automatically.
##
## Phase 3: Wires NarrativeDirector for mid-mission comms, interludes, crew registration.

@onready var render_bridge: Node2D = $RenderBridge

var hud: Control = null
var _campaign_complete_shown: bool = false
var _interlude_pending: bool = false  # True when an interlude screen needs to show before the next mission
var _pending_scenario_path: String = ""  # Scenario to load after interlude

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
	# Phase 3: disconnect narrative signals
	if SimulationWorld.unit_detected.is_connected(_on_unit_detected_narrative):
		SimulationWorld.unit_detected.disconnect(_on_unit_detected_narrative)
	if SimulationWorld.weapon_fired.is_connected(_on_weapon_fired_narrative):
		SimulationWorld.weapon_fired.disconnect(_on_weapon_fired_narrative)
	if SimulationWorld.sim_tick.is_connected(_on_sim_tick_narrative):
		SimulationWorld.sim_tick.disconnect(_on_sim_tick_narrative)
	if NarrativeDirector.interlude_finished.is_connected(_on_interlude_finished):
		NarrativeDirector.interlude_finished.disconnect(_on_interlude_finished)

func _ready() -> void:
	var scenario_path: String

	# Connect interlude dismissal handler
	if not NarrativeDirector.interlude_finished.is_connected(_on_interlude_finished):
		NarrativeDirector.interlude_finished.connect(_on_interlude_finished)

	if CampaignManager.campaign_active:
		if CampaignManager.is_campaign_complete():
			_campaign_complete_shown = true
			hud = render_bridge.find_child("HUD", true, false) if render_bridge else null
			if hud and hud.has_method("show_campaign_complete"):
				hud.show_campaign_complete(CampaignManager.mission_history)
			# Campaign reset deferred to SPACE press so player can view results
			return

		# Check for pending interlude between missions
		var prev_mission: int = CampaignManager.current_mission  # 0-based
		if prev_mission > 0 and not CampaignManager.was_interlude_shown(prev_mission):
			# Show interlude before loading the next mission
			scenario_path = CampaignManager.get_current_mission_path()
			if scenario_path != "" and NarrativeDirector.show_interlude(prev_mission):
				_interlude_pending = true
				_pending_scenario_path = scenario_path
				var interlude_key := "between_%d_%d" % [prev_mission, prev_mission + 1]
				CampaignManager.mark_interlude_shown(interlude_key)
				return  # Wait for player to dismiss the interlude

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
	# Interlude dismissal: SPACE during interlude
	if _interlude_pending and NarrativeDirector.is_interlude_active():
		if event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
			NarrativeDirector.dismiss_interlude()
			return

	if _campaign_complete_shown and event is InputEventKey and event.pressed and event.keycode == KEY_SPACE:
		_campaign_complete_shown = false
		CampaignManager.reset_campaign()
		get_tree().change_scene_to_file("res://scenes/mainmenu.tscn")

func _on_interlude_finished() -> void:
	_interlude_pending = false
	if _pending_scenario_path != "":
		var path: String = _pending_scenario_path
		_pending_scenario_path = ""
		_start_scenario_from_path(path)

func _start_scenario_from_path(scenario_path: String) -> void:
	var scenario_data: Dictionary = ScenarioLoader.load_scenario_file(scenario_path)
	if scenario_data.is_empty():
		push_error("Main: failed to load scenario: %s" % scenario_path)
		return
	_start_scenario(scenario_data)

func _start_scenario(scenario_data: Dictionary) -> void:
	AudioManager.reset()
	SimulationWorld.load_scenario(scenario_data)
	AudioManager.start_ocean_ambience()

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

	SimulationWorld.is_paused = true
	SimulationWorld.time_scale = 1.0

	# Center camera on player task force
	if render_bridge and render_bridge.camera:
		render_bridge.camera.position = Vector2.ZERO
		render_bridge.camera.zoom = Vector2(0.8, 0.8)

	hud = render_bridge.find_child("HUD", true, false) if render_bridge else null
	var is_tutorial: bool = scenario_data.get("tutorial", false)

	# --- Phase 3: Register ships with CampaignManager for real crew counts ---
	if CampaignManager.campaign_active:
		for uid in SimulationWorld.units:
			var u: Dictionary = SimulationWorld.units[uid]
			if u.get("faction", "") != "player":
				continue
			var platform_type: String = u.get("platform", {}).get("type", "")
			if platform_type in ["SH60B", "MPA", "P3C", "HELO"]:
				continue
			var ship_name: String = u.get("name", uid)
			var class_name_str: String = u.get("platform", {}).get("class_name", "")
			var crew_count: int = u.get("platform", {}).get("crew", 0)
			CampaignManager.register_ship(uid, ship_name, class_name_str, crew_count)

	if is_tutorial:
		# Tutorial mode: activate TutorialManager, skip briefing/time-limit/auto-select
		if hud:
			TutorialManager.activate(hud, render_bridge)
	else:
		# Normal mode: show briefing, set time limit, auto-select first player unit
		# Dialogic briefings disabled until style/input issues resolved
		# var used_dialogic: bool = NarrativeDirector.play_briefing(scenario_data)

		# Phase 3: Prepend "struck from roster" message to briefing if ships were lost
		var briefing_text: String = scenario_data.get("briefing", "")
		if CampaignManager.campaign_active:
			var roster_msg: String = CampaignManager.get_roster_reduction_message()
			if roster_msg != "" and briefing_text != "":
				briefing_text = roster_msg + "\n\n" + briefing_text

		if hud and hud.has_method("show_briefing"):
			if briefing_text != "":
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

	# Phase 10: Load crisis temperature and readiness from CampaignManager into ROESystem
	if CampaignManager.campaign_active and SimulationWorld.get("_roe_system"):
		var roe := SimulationWorld._roe_system
		var temp: float = CampaignManager.crisis_temperature
		if temp > 0.0:
			roe.crisis_temperature = temp
		var readiness_dict: Dictionary = CampaignManager.ship_readiness
		if not readiness_dict.is_empty():
			roe._ship_readiness = readiness_dict.duplicate(true)

	# Phase 10: Mission 7 ceasefire temperature gate
	if CampaignManager.campaign_active and CampaignManager.get_current_mission_number() == 7:
		if SimulationWorld.get("_roe_system"):
			if not SimulationWorld._roe_system.does_ceasefire_hold():
				# Crisis too high -- ceasefire fails, enemies attack
				for uid in SimulationWorld.units:
					var u: Dictionary = SimulationWorld.units[uid]
					if u.get("faction", "") == "enemy" and u["is_alive"]:
						SimulationWorld.set_unit_behavior(uid, "attack", {"target_id": ""})
				if hud and hud.has_method("show_alert"):
					hud.show_alert("CEASEFIRE HAS COLLAPSED -- ENEMY FORCES HOSTILE", 5.0)

	# --- Phase 3: Wire NarrativeDirector for mid-mission comms ---
	if CampaignManager.campaign_active and not is_tutorial:
		var mission_num: int = CampaignManager.get_current_mission_number()
		NarrativeDirector.load_mission_comms(mission_num)
		var time_limit: float = scenario_data.get("victory_condition", {}).get("time_limit_seconds", 0.0)
		NarrativeDirector.set_mission_timing(0.0, time_limit)

		# Connect narrative trigger signals
		if not SimulationWorld.unit_detected.is_connected(_on_unit_detected_narrative):
			SimulationWorld.unit_detected.connect(_on_unit_detected_narrative)
		if not SimulationWorld.weapon_fired.is_connected(_on_weapon_fired_narrative):
			SimulationWorld.weapon_fired.connect(_on_weapon_fired_narrative)
		if not SimulationWorld.sim_tick.is_connected(_on_sim_tick_narrative):
			SimulationWorld.sim_tick.connect(_on_sim_tick_narrative)

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

	# Phase 3: fire any end-of-mission narrative triggers
	NarrativeDirector.on_mission_ending()

	# Compute score before ScoreManager.stop_tracking is called by HUD.show_result
	var time_limit: float = SimulationWorld.scenario.get("victory_condition", {}).get("time_limit_seconds", 0.0)
	var score_data: Dictionary = ScoreManager.compute_score(SimulationWorld.sim_time, time_limit, ScenarioLoader.get_score_multiplier())

	# Collect lost and surviving player units
	var lost := []
	var surviving := []
	var weapons_fired_count: int = 0
	for uid in SimulationWorld.units:
		var u: Dictionary = SimulationWorld.units[uid]
		if u["faction"] == "player":
			if u["is_alive"]:
				surviving.append(uid)
			else:
				lost.append(uid)

	# Phase 10: ROE system mission-end hooks
	if SimulationWorld.get("_roe_system"):
		var roe := SimulationWorld._roe_system
		# Check if player fired no weapons (de-escalation)
		if ScoreManager.is_tracking:
			weapons_fired_count = ScoreManager.weapons_fired
		if weapons_fired_count == 0:
			roe.on_mission_complete_no_fire(0)
		# Check if player maintained contact without engaging
		if SimulationWorld._contact_accumulator > 600.0 and weapons_fired_count == 0:
			roe.on_maintained_contact_no_engagement()
		# Persist crisis temperature and patrol log to CampaignManager
		CampaignManager.update_crisis_temperature(roe.get_crisis_temperature())
		CampaignManager.append_patrol_log(roe.get_patrol_log())
		# Degrade readiness based on losses
		CampaignManager.degrade_readiness_post_mission(surviving, lost)

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

# ---------------------------------------------------------------------------
# Phase 3: NarrativeDirector signal handlers for mid-mission comms
# ---------------------------------------------------------------------------

## Called when a unit is detected -- triggers first_passive_detection comms.
func _on_unit_detected_narrative(detector_id: String, target_id: String, _detection: Dictionary) -> void:
	# Only trigger on player detecting enemy
	if detector_id not in SimulationWorld.units or target_id not in SimulationWorld.units:
		return
	var detector: Dictionary = SimulationWorld.units[detector_id]
	var target: Dictionary = SimulationWorld.units[target_id]
	if detector.get("faction", "") == "player" and target.get("faction", "") == "enemy":
		NarrativeDirector.on_first_passive_detection()

## Called when any weapon is fired -- triggers narrative comms.
func _on_weapon_fired_narrative(_weapon_id: String, shooter_id: String, _target_id: String, weapon_data: Dictionary) -> void:
	if shooter_id not in SimulationWorld.units:
		return
	var shooter: Dictionary = SimulationWorld.units[shooter_id]
	if shooter.get("faction", "") == "player":
		NarrativeDirector.on_first_player_weapon_fired()
	elif shooter.get("faction", "") == "enemy":
		var weapon_type: String = weapon_data.get("type", "torpedo")
		NarrativeDirector.on_enemy_weapon_fired(weapon_type)

## Called on sim tick -- check time-based narrative triggers.
func _on_sim_tick_narrative(_tick: int, sim_time: float) -> void:
	NarrativeDirector.check_time_triggers(sim_time)
