extends Node
## ScenarioLoader -- Reads scenario JSON files and feeds them to SimulationWorld.

var override_scenario: String = ""
var selected_difficulty: String = "NORMAL"

## Difficulty parameter table.  Enemies and time_limit are scenario-specific
## and are NOT injected here -- only the three simulation scaling params.
const DIFFICULTY_PARAMS := {
	"EASY":   { "detection_mult": 1.5, "player_pk_mult": 1.3, "ai_attack_threshold": 0.50 },
	"NORMAL": { "detection_mult": 1.0, "player_pk_mult": 1.0, "ai_attack_threshold": 0.30 },
	"HARD":   { "detection_mult": 0.7, "player_pk_mult": 0.8, "ai_attack_threshold": 0.20 },
	"ELITE":  { "detection_mult": 0.5, "player_pk_mult": 0.7, "ai_attack_threshold": 0.15 },
}

const SCORE_MULTIPLIERS := {
	"EASY":   0.70,
	"NORMAL": 1.00,
	"HARD":   1.30,
	"ELITE":  1.60,
}

func get_score_multiplier() -> float:
	return SCORE_MULTIPLIERS.get(selected_difficulty, 1.0)


## Injects the selected difficulty params into scenario_data["difficulty"].
## Scenario-level overrides take precedence — menu selection only fills gaps.
func apply_difficulty(data: Dictionary) -> Dictionary:
	var params: Dictionary = DIFFICULTY_PARAMS.get(selected_difficulty, DIFFICULTY_PARAMS["NORMAL"])
	if not data.has("difficulty"):
		data["difficulty"] = {}
	for key in params:
		if not data["difficulty"].has(key):
			data["difficulty"][key] = params[key]
	return data

func load_scenario_file(path: String) -> Dictionary:
	path = path.simplify_path()
	if not path.to_lower().begins_with("res://scenarios/") or not path.to_lower().ends_with(".json"):
		push_error("ScenarioLoader: path outside allowed directory: %s" % path)
		return {}

	if not FileAccess.file_exists(path):
		push_error("ScenarioLoader: file not found: %s" % path)
		return {}

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("ScenarioLoader: cannot open: %s" % path)
		return {}

	var text: String = file.get_as_text()
	file.close()

	var json := JSON.new()
	var err: Error = json.parse(text)
	if err != OK:
		push_error("ScenarioLoader: parse error in %s: %s" % [path, json.get_error_message()])
		return {}

	var data = json.data
	if not data is Dictionary:
		push_error("ScenarioLoader: root is not a Dictionary in %s" % path)
		return {}

	# Validate required fields
	if not data.has("name"):
		push_error("ScenarioLoader: missing 'name' in %s" % path)
		return {}
	if not data.has("units"):
		push_error("ScenarioLoader: missing 'units' in %s" % path)
		return {}

	return apply_difficulty(data)
