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
var _timeline_class: GDScript = null

func _ready() -> void:
	_dialogic = get_node_or_null("/root/Dialogic")
	if not _dialogic:
		push_warning("NarrativeDirector: Dialogic not found. Enable the Dialogic plugin in Project Settings > Plugins.")
		return
	# Cache the timeline class for manual .dtl loading
	_timeline_class = load("res://addons/dialogic/Resources/timeline.gd") as GDScript

func _has_dialogic() -> bool:
	if not _dialogic:
		_dialogic = get_node_or_null("/root/Dialogic")
		if _dialogic and not _timeline_class:
			_timeline_class = load("res://addons/dialogic/Resources/timeline.gd") as GDScript
	return _dialogic != null

## Manually load a .dtl file into a DialogicTimeline resource.
## Bypasses ResourceFormatLoader which can fail at runtime.
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

## Returns true if Dialogic briefing actually started. False = caller should fall back to text.
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

## Returns true if timeline resource was valid and handed to Dialogic.
func _begin_narrative(path: String) -> bool:
	if _is_playing:
		push_warning("NarrativeDirector: already playing, ignoring %s" % path)
		return false

	# Pre-load the .dtl manually — passing a Resource to Dialogic.start()
	# skips the load() call inside start_timeline() that can fail at runtime.
	var tml: Resource = _load_timeline(path)
	if tml == null:
		push_warning("NarrativeDirector: failed to parse timeline: %s" % path)
		return false

	_is_playing = true
	narrative_started.emit()
	_dialogic.timeline_ended.connect(_on_timeline_ended, CONNECT_ONE_SHOT)
	_dialogic.start(tml)
	# Note: start() may defer start_timeline() until the style scene is ready.
	# We trust Dialogic to fire timeline_ended when it finishes (or errors).
	return true

func _on_timeline_ended() -> void:
	_is_playing = false
	narrative_ended.emit()
	# Restore pause state: briefings keep sim paused, mid-mission comms resume
	if not _sim_was_paused:
		SimulationWorld.is_paused = false

func is_playing() -> bool:
	# Safety valve: if Dialogic returned to idle with no active timeline,
	# our signal handler was missed — clear the stale flag.
	if _is_playing and _dialogic:
		if _dialogic.current_timeline == null and _dialogic.current_state == 0:
			_is_playing = false
			narrative_ended.emit()
	return _is_playing
