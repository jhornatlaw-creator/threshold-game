extends Node
## NarrativeDirector -- Single entry point from game systems into Dialogic.
## Owns pause state coordination during narrative sequences.
## All other systems call NarrativeDirector. NarrativeDirector calls Dialogic.
## Safe to load even when Dialogic plugin is not yet enabled.

signal narrative_started
signal narrative_ended

var _sim_was_paused: bool = false
var _is_playing: bool = false
var _dialogic: Node = null

func _ready() -> void:
	# Dialogic is added as an autoload when the plugin is enabled.
	# Use get_node to safely check at runtime.
	_dialogic = get_node_or_null("/root/Dialogic")
	if not _dialogic:
		push_warning("NarrativeDirector: Dialogic not found. Enable the Dialogic plugin in Project Settings > Plugins.")

func _has_dialogic() -> bool:
	if not _dialogic:
		_dialogic = get_node_or_null("/root/Dialogic")
	return _dialogic != null

func play_briefing(scenario_data: Dictionary) -> void:
	var timeline_id: String = scenario_data.get("timeline", "")
	if timeline_id == "":
		return  # caller falls through to HUD.show_briefing()
	if not _has_dialogic():
		return
	var path := "res://narrative/briefings/%s.dtl" % timeline_id
	if not ResourceLoader.exists(path):
		push_warning("NarrativeDirector: briefing timeline not found: %s" % path)
		return
	_sim_was_paused = SimulationWorld.is_paused
	_begin_narrative(path)

func play_comm(event_name: String) -> void:
	if not _has_dialogic():
		return
	var path := "res://narrative/comms/%s.dtl" % event_name
	if not ResourceLoader.exists(path):
		return
	_sim_was_paused = SimulationWorld.is_paused
	SimulationWorld.is_paused = true
	_begin_narrative(path)

func play_interlude(timeline_name: String) -> void:
	if not _has_dialogic():
		return
	var path := "res://narrative/interludes/%s.dtl" % timeline_name
	if not ResourceLoader.exists(path):
		push_warning("NarrativeDirector: interlude not found: %s" % path)
		return
	_sim_was_paused = SimulationWorld.is_paused
	SimulationWorld.is_paused = true
	_begin_narrative(path)

func _begin_narrative(path: String) -> void:
	if _is_playing:
		push_warning("NarrativeDirector: already playing, ignoring %s" % path)
		return
	_is_playing = true
	narrative_started.emit()
	_dialogic.timeline_ended.connect(_on_timeline_ended, CONNECT_ONE_SHOT)
	_dialogic.start(path)

func _on_timeline_ended() -> void:
	_is_playing = false
	narrative_ended.emit()
	# Restore pause state: briefings keep sim paused, mid-mission comms resume
	if not _sim_was_paused:
		SimulationWorld.is_paused = false

func is_playing() -> bool:
	return _is_playing
