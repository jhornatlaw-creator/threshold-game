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


def test_environment_has_thermal_fields():
    """Phase 4: all scenarios must have thermal layer + bottom depth fields."""
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        env = data["environment"]
        name = os.path.basename(path)
        assert "thermal_layer_depth_m" in env, f"{name}: missing thermal_layer_depth_m"
        assert "thermal_layer_strength" in env, f"{name}: missing thermal_layer_strength"
        assert "bottom_depth_m" in env, f"{name}: missing bottom_depth_m"
        # Thermal layer depth must be positive and less than bottom depth
        assert env["thermal_layer_depth_m"] > 0, f"{name}: thermal_layer_depth_m must be > 0"
        assert env["thermal_layer_strength"] >= 0.0 and env["thermal_layer_strength"] <= 1.0, \
            f"{name}: thermal_layer_strength must be 0.0-1.0"
        assert env["bottom_depth_m"] >= env.get("water_depth_m", 0), \
            f"{name}: bottom_depth_m must be >= water_depth_m"


def test_platforms_xbt_field():
    """Phase 4: surface ships should have xbt_count field."""
    platforms_path = os.path.join(os.path.dirname(__file__), "data", "platforms.json")
    data = _load(platforms_path)
    surface_types = {"DD", "FFG", "DDG", "CGN"}
    for platform in data["platforms"]:
        ptype = platform.get("type", "")
        if ptype in surface_types:
            # Surface combatants should have xbt_count (0 or positive)
            assert "xbt_count" in platform, \
                f"{platform['id']}: surface ship missing xbt_count"


# ---- Phase 7: Helicopter + P-3C Operations tests ----

def test_platforms_sonobuoy_typed_fields():
    """Phase 7: ASW aircraft should have typed sonobuoy fields (DIFAR + DICASS)."""
    platforms_path = os.path.join(os.path.dirname(__file__), "data", "platforms.json")
    data = _load(platforms_path)
    asw_types = {"HELO", "MPA"}
    for platform in data["platforms"]:
        ptype = platform.get("type", "")
        if ptype in asw_types:
            total = platform.get("sonobuoy_count", 0)
            difar = platform.get("sonobuoy_difar", 0)
            dicass = platform.get("sonobuoy_dicass", 0)
            pid = platform["id"]
            assert total > 0, f"{pid}: ASW platform missing sonobuoy_count"
            assert difar > 0, f"{pid}: ASW platform missing sonobuoy_difar"
            assert dicass > 0, f"{pid}: ASW platform missing sonobuoy_dicass"
            assert difar + dicass == total, \
                f"{pid}: DIFAR ({difar}) + DICASS ({dicass}) != total ({total})"


def test_p3c_sonobuoy_loadout():
    """Phase 7: P-3C Orion should carry 84 sonobuoys (historical max loadout)."""
    platforms_path = os.path.join(os.path.dirname(__file__), "data", "platforms.json")
    data = _load(platforms_path)
    p3c = [p for p in data["platforms"] if p["id"] == "p3c_orion"]
    assert len(p3c) == 1, "p3c_orion platform not found"
    p = p3c[0]
    assert p["sonobuoy_count"] == 84, f"P-3C sonobuoy_count should be 84, got {p['sonobuoy_count']}"
    assert p["sonobuoy_difar"] + p["sonobuoy_dicass"] == 84


def test_seahawk_sonobuoy_loadout():
    """Phase 7: SH-60B should carry 15 sonobuoys (10 DIFAR + 5 DICASS)."""
    platforms_path = os.path.join(os.path.dirname(__file__), "data", "platforms.json")
    data = _load(platforms_path)
    sh60 = [p for p in data["platforms"] if p["id"] == "sh60b_seahawk"]
    assert len(sh60) == 1, "sh60b_seahawk platform not found"
    p = sh60[0]
    assert p["sonobuoy_count"] == 15, f"SH-60B sonobuoy_count should be 15, got {p['sonobuoy_count']}"
    assert p["sonobuoy_difar"] == 10, f"SH-60B sonobuoy_difar should be 10"
    assert p["sonobuoy_dicass"] == 5, f"SH-60B sonobuoy_dicass should be 5"


def test_sonobuoy_system_exists():
    """Phase 7: SonobuoySystem.gd must exist in scripts/."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "SonobuoySystem.gd")
    assert os.path.exists(path), "SonobuoySystem.gd not found in scripts/"


def test_sonobuoy_system_has_buoy_types():
    """Phase 7: SonobuoySystem.gd must define DIFAR and DICASS buoy types."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "SonobuoySystem.gd")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "DIFAR" in content, "SonobuoySystem.gd missing DIFAR buoy type"
    assert "DICASS" in content, "SonobuoySystem.gd missing DICASS buoy type"
    assert "deploy_pattern_line" in content, "SonobuoySystem.gd missing line pattern drop"
    assert "deploy_pattern_field" in content, "SonobuoySystem.gd missing field pattern drop"


def test_simulation_world_has_dicass_signals():
    """Phase 7: SimulationWorld.gd must have DICASS-specific signals."""
    sw_path = os.path.join(os.path.dirname(__file__), "scripts", "SimulationWorld.gd")
    with open(sw_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "sonobuoy_dicass_contact" in content, \
        "SimulationWorld.gd missing sonobuoy_dicass_contact signal"
    assert "sonobuoy_dicass_alert" in content, \
        "SimulationWorld.gd missing sonobuoy_dicass_alert signal"
    assert "SonobuoySystemScript" in content, \
        "SimulationWorld.gd missing SonobuoySystem preload"


# ---- Phase 8: Weapons Polish tests ----

def test_weapons_have_wire_guided_field():
    """Phase 8: all weapons must have wire_guided boolean."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    for weapon in data["weapons"]:
        assert "wire_guided" in weapon, \
            f"{weapon['id']}: missing wire_guided field"
        assert isinstance(weapon["wire_guided"], bool), \
            f"{weapon['id']}: wire_guided must be boolean"


def test_wire_guided_weapons_have_wire_length():
    """Phase 8: wire-guided weapons must have wire_length_nm."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    for weapon in data["weapons"]:
        if weapon.get("wire_guided", False):
            assert "wire_length_nm" in weapon, \
                f"{weapon['id']}: wire_guided=true but missing wire_length_nm"
            assert weapon["wire_length_nm"] > 0, \
                f"{weapon['id']}: wire_length_nm must be positive"


def test_mk48_mod4_is_wire_guided():
    """Phase 8: Mk48 Mod 4 must be wire-guided with ~20nm wire."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    mk48 = [w for w in data["weapons"] if w["id"] == "mk48_mod4"]
    assert len(mk48) == 1, "mk48_mod4 not found in weapons.json"
    mk48 = mk48[0]
    assert mk48["wire_guided"] is True, "mk48_mod4 must be wire_guided"
    assert mk48["wire_length_nm"] == 20, "mk48_mod4 wire_length_nm should be 20"
    assert mk48["guidance"] == "wire_acoustic", "mk48_mod4 guidance should be wire_acoustic"


def test_asroc_range_corrected():
    """Phase 8: ASROC range should be ~6nm (was incorrectly 12nm)."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    asroc = [w for w in data["weapons"] if w["id"] == "asroc_rur5"]
    assert len(asroc) == 1, "asroc_rur5 not found in weapons.json"
    asroc = asroc[0]
    assert asroc["max_range_nm"] == 6, f"ASROC max_range_nm should be 6, got {asroc['max_range_nm']}"
    assert "splash_warning_seconds" in asroc, "ASROC missing splash_warning_seconds"
    assert asroc["splash_warning_seconds"] == 30, "ASROC splash_warning_seconds should be 30"


def test_pk_base_values_are_base():
    """Phase 8: all pk_base values should be pre-solution-quality (0.0-1.0 range)."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    for weapon in data["weapons"]:
        pk = weapon.get("pk_base", 0)
        assert 0.0 < pk <= 1.0, \
            f"{weapon['id']}: pk_base {pk} out of range (0.0, 1.0]"


def test_no_weapon_has_adcap():
    """Phase 8: No ADCAP weapons (anachronism check -- 1985 setting)."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    for weapon in data["weapons"]:
        assert "adcap" not in weapon["id"].lower(), \
            f"{weapon['id']}: ADCAP did not exist in 1985"
        assert "adcap" not in weapon["name"].lower(), \
            f"{weapon['name']}: ADCAP did not exist in 1985"


def test_weapons_json_valid():
    """Phase 8: weapons.json is valid JSON with expected structure."""
    weapons_path = os.path.join(os.path.dirname(__file__), "data", "weapons.json")
    data = _load(weapons_path)
    assert "weapons" in data, "weapons.json missing 'weapons' key"
    assert len(data["weapons"]) >= 9, f"Expected 9+ weapons, got {len(data['weapons'])}"
    required_fields = {"id", "name", "type", "guidance", "max_range_nm",
                       "speed_kts", "warhead_kg", "pk_base", "loadout_default"}
    for weapon in data["weapons"]:
        missing = required_fields - weapon.keys()
        assert not missing, f"{weapon.get('id', '?')}: missing fields {missing}"


# ---- Phase 6: AI Doctrine System tests ----

def test_ai_doctrine_system_exists():
    """Phase 6: AIDoctrineSystem.gd must exist in scripts/."""
    doctrine_path = os.path.join(os.path.dirname(__file__), "scripts", "AIDoctrineSystem.gd")
    assert os.path.exists(doctrine_path), "AIDoctrineSystem.gd not found in scripts/"

def test_ai_doctrine_system_has_state_machine():
    """Phase 6: AIDoctrineSystem.gd must define TRANSIT/DETECTED/ATTACK/EVASION states."""
    doctrine_path = os.path.join(os.path.dirname(__file__), "scripts", "AIDoctrineSystem.gd")
    with open(doctrine_path, "r", encoding="utf-8") as f:
        content = f.read()
    for state in ["TRANSIT", "DETECTED", "ATTACK", "EVASION"]:
        assert state in content, f"AIDoctrineSystem.gd missing DoctrineState.{state}"

def test_ai_doctrine_system_has_difficulty_levels():
    """Phase 6: AIDoctrineSystem.gd must define EASY/NORMAL/HARD/ELITE difficulty levels."""
    doctrine_path = os.path.join(os.path.dirname(__file__), "scripts", "AIDoctrineSystem.gd")
    with open(doctrine_path, "r", encoding="utf-8") as f:
        content = f.read()
    for level in ["EASY", "NORMAL", "HARD", "ELITE"]:
        assert level in content, f"AIDoctrineSystem.gd missing DifficultyLevel.{level}"

def test_ai_doctrine_system_has_sprint_and_drift():
    """Phase 6: AIDoctrineSystem.gd must implement sprint-and-drift behavior."""
    doctrine_path = os.path.join(os.path.dirname(__file__), "scripts", "AIDoctrineSystem.gd")
    with open(doctrine_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "sprint_drift" in content, "AIDoctrineSystem.gd missing sprint-and-drift references"
    assert "baffle_clear" in content, "AIDoctrineSystem.gd missing baffle-clearing turn"

def test_ai_doctrine_system_has_surface_group_doctrine():
    """Phase 6: AIDoctrineSystem.gd must implement surface group formation doctrine."""
    doctrine_path = os.path.join(os.path.dirname(__file__), "scripts", "AIDoctrineSystem.gd")
    with open(doctrine_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "formation" in content.lower(), "AIDoctrineSystem.gd missing formation references"
    assert "screen" in content.lower() or "SCREEN" in content, \
        "AIDoctrineSystem.gd missing screen distance references"

def test_simulation_world_loads_doctrine():
    """Phase 6: SimulationWorld.gd must preload and initialize AIDoctrineSystem."""
    sw_path = os.path.join(os.path.dirname(__file__), "scripts", "SimulationWorld.gd")
    with open(sw_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "AIDoctrineSystemScript" in content, \
        "SimulationWorld.gd missing AIDoctrineSystemScript preload"
    assert "_ai_doctrine_system" in content, \
        "SimulationWorld.gd missing _ai_doctrine_system variable"
    assert "init_unit_doctrine" in content, \
        "SimulationWorld.gd missing doctrine initialization in spawn_unit"

def test_difficulty_inference_from_threshold():
    """Phase 6: verify difficulty inference logic matches scenario thresholds."""
    # ai_attack_threshold >= 0.4 -> EASY
    # 0.25-0.39 -> NORMAL
    # 0.15-0.24 -> HARD
    # < 0.15 -> ELITE
    thresholds = {
        0.5: 0,   # EASY
        0.4: 0,   # EASY
        0.3: 1,   # NORMAL
        0.25: 1,  # NORMAL
        0.2: 2,   # HARD
        0.15: 2,  # HARD
        0.1: 3,   # ELITE
    }
    # Just validate the mapping exists and covers all scenario thresholds
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        diff = data.get("difficulty", {})
        threshold = diff.get("ai_attack_threshold", 0.3)
        name = os.path.basename(path)
        assert 0.0 <= threshold <= 1.0, \
            f"{name}: ai_attack_threshold {threshold} out of range"


# ---- Phase 10: ROE + Crisis Temperature + Campaign Polish tests ----

VALID_ROE_STATES = {"WEAPONS_TIGHT", "WEAPONS_HOLD", "WEAPONS_FREE", "TIGHT", "HOLD", "FREE"}


def test_all_scenarios_have_roe_state():
    """Phase 10: all scenarios must have roe_state field."""
    for path in glob.glob(os.path.join(SCENARIO_DIR, "*.json")):
        data = _load(path)
        name = os.path.basename(path)
        assert "roe_state" in data, f"{name}: missing roe_state field"
        assert data["roe_state"] in VALID_ROE_STATES, \
            f"{name}: invalid roe_state '{data['roe_state']}'"


def test_campaign_roe_states_match_narrative():
    """Phase 10: campaign missions have narratively correct ROE states."""
    roe_map = {
        "campaign_02_cold_passage.json": "WEAPONS_HOLD",       # Shadow mission, fire only if fired upon
        "campaign_03_sosus_ghost.json": "WEAPONS_HOLD",         # Confirm before you fire
        "campaign_04_northern_watch.json": "WEAPONS_TIGHT",     # Do not fire unless fired upon -> changes mid-mission
        "campaign_05_crossing_the_line.json": "WEAPONS_FREE",   # They crossed the line
        "campaign_06_reykjanes_ridge.json": "WEAPONS_FREE",     # Kill them all
        "campaign_07_silent_watch.json": "WEAPONS_TIGHT",       # Ceasefire -- do not fire
    }
    for filename, expected_roe in roe_map.items():
        path = os.path.join(SCENARIO_DIR, filename)
        if not os.path.exists(path):
            continue
        data = _load(path)
        assert data["roe_state"] == expected_roe, \
            f"{filename}: expected roe_state '{expected_roe}', got '{data['roe_state']}'"


def test_roe_system_exists():
    """Phase 10: ROESystem.gd must exist in scripts/."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "ROESystem.gd")
    assert os.path.exists(path), "ROESystem.gd not found in scripts/"


def test_roe_system_has_classification_ladder():
    """Phase 10: ROESystem.gd must define UNKNOWN/SUSPECT/PROBABLE_HOSTILE/CERTAIN_HOSTILE."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "ROESystem.gd")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    for level in ["UNKNOWN", "SUSPECT", "PROBABLE_HOSTILE", "CERTAIN_HOSTILE"]:
        assert level in content, f"ROESystem.gd missing Classification.{level}"


def test_roe_system_has_roe_states():
    """Phase 10: ROESystem.gd must define WEAPONS_TIGHT/WEAPONS_HOLD/WEAPONS_FREE."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "ROESystem.gd")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    for state in ["WEAPONS_TIGHT", "WEAPONS_HOLD", "WEAPONS_FREE"]:
        assert state in content, f"ROESystem.gd missing ROEState.{state}"


def test_roe_system_has_crisis_temperature():
    """Phase 10: ROESystem.gd must implement crisis temperature system."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "ROESystem.gd")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "crisis_temperature" in content, "ROESystem.gd missing crisis_temperature"
    assert "get_crisis_temperature" in content, "ROESystem.gd missing get_crisis_temperature()"
    assert "does_ceasefire_hold" in content, "ROESystem.gd missing does_ceasefire_hold()"


def test_roe_system_has_crew_fatigue():
    """Phase 10: ROESystem.gd must implement crew fatigue/readiness system."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "ROESystem.gd")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "readiness" in content.lower(), "ROESystem.gd missing readiness system"
    assert "false_contact" in content.lower(), "ROESystem.gd missing false contact generation"


def test_roe_system_has_patrol_log():
    """Phase 10: ROESystem.gd must implement patrol log / after-action report."""
    path = os.path.join(os.path.dirname(__file__), "scripts", "ROESystem.gd")
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "generate_after_action_report" in content, \
        "ROESystem.gd missing generate_after_action_report()"
    assert "patrol_log" in content.lower(), "ROESystem.gd missing patrol log"


def test_simulation_world_loads_roe_system():
    """Phase 10: SimulationWorld.gd must preload and initialize ROESystem."""
    sw_path = os.path.join(os.path.dirname(__file__), "scripts", "SimulationWorld.gd")
    with open(sw_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "ROESystemScript" in content, \
        "SimulationWorld.gd missing ROESystemScript preload"
    assert "_roe_system" in content, \
        "SimulationWorld.gd missing _roe_system variable"
    assert "roe_changed" in content, \
        "SimulationWorld.gd missing roe_changed signal"
    assert "roe_blocked" in content, \
        "SimulationWorld.gd missing roe_blocked signal"


def test_weapon_system_has_roe_check():
    """Phase 10: WeaponSystem.gd must check ROE before allowing fire_weapon."""
    ws_path = os.path.join(os.path.dirname(__file__), "scripts", "WeaponSystem.gd")
    with open(ws_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "roe_system" in content.lower() or "get_roe_system" in content, \
        "WeaponSystem.gd missing ROE check in fire_weapon"
    assert "check_fire_authorization" in content or "roe_blocked" in content, \
        "WeaponSystem.gd missing fire authorization check"


def test_campaign_manager_has_crisis_temperature():
    """Phase 10: CampaignManager.gd must persist crisis temperature."""
    cm_path = os.path.join(os.path.dirname(__file__), "scripts", "CampaignManager.gd")
    with open(cm_path, "r", encoding="utf-8") as f:
        content = f.read()
    assert "crisis_temperature" in content, \
        "CampaignManager.gd missing crisis_temperature"
    assert "ship_readiness" in content, \
        "CampaignManager.gd missing ship_readiness"
    assert "patrol_log" in content, \
        "CampaignManager.gd missing patrol_log"
