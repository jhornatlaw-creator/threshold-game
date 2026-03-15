"""Validate scenario JSON files are well-formed and have required fields."""
import json
import glob
import os

REQUIRED_KEYS = {"name", "description", "environment", "victory_condition", "units"}
VALID_VICTORY_TYPES = {"destroy_all_enemies", "survive_time", "maintain_contact", "protect_convoy"}
SCENARIO_DIR = os.path.join(os.path.dirname(__file__), "scenarios")


def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def test_all_scenarios_parse():
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        missing = REQUIRED_KEYS - data.keys()
        assert not missing, f"{os.path.basename(path)} missing keys: {missing}"


def test_victory_conditions_valid():
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        vtype = data["victory_condition"]["type"]
        assert vtype in VALID_VICTORY_TYPES, f"{os.path.basename(path)}: unknown victory type '{vtype}'"


def test_all_scenarios_have_difficulty():
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        if data.get("tutorial"):
            assert "difficulty" in data, f"{os.path.basename(path)}: tutorial missing difficulty"
        # Non-tutorial scenarios should also have difficulty
        if not data.get("tutorial"):
            assert "difficulty" in data, f"{os.path.basename(path)}: missing difficulty block"


def test_units_have_required_fields():
    unit_keys = {"id", "platform_id", "name", "faction", "x", "y", "heading", "speed_kts"}
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        for unit in data["units"]:
            missing = unit_keys - unit.keys()
            assert not missing, f"{os.path.basename(path)} unit {unit.get('id','?')} missing: {missing}"
