# THRESHOLD — Board Review for Dev Team

**Date:** 2026-03-13
**From:** Board of Directors (Jerome, Martin, Naval Warfare Expert, X, Luna)
**To:** Alex (Dev Lead) + Engineering Team

---

## EXECUTIVE SUMMARY

Five-expert review of THRESHOLD's codebase, data, and design. Three game-breaking bugs found. The core ASW scenario is **mathematically unwinnable** due to compounding errors in the torpedo damage model and sonar calibration. Fix these three items first — everything else is tuning.

---

## P0 — SHIP-BLOCKING BUGS (fix before any playtesting)

### Bug 1: Torpedo Damage vs Submarines — UNWINNABLE SCENARIO

**The math:** Mk46 (44kg) vs Akula (8140t) = `(44/8140)*6.0 = 0.032` damage per hit. Takes **31 hits** to kill one Akula. Player has **22 total ASW weapons** across all ships. Need 62 hits for both Akulas. The scenario cannot be won.

**Root cause:** The damage formula `(warhead_kg / displacement_tons) * 6.0` treats submarines like surface ships. Submarines are pressure vessels — one torpedo hit causes hull breach and flooding that is near-lethal.

**Fix:** Add torpedo-vs-submarine damage override in `_compute_weapon_damage`:

```gdscript
# In SimulationWorld.gd, _compute_weapon_damage():
# Torpedoes vs submerged targets use fixed damage (pressure hull breach)
if wdata.get("type", "") == "torpedo" and target["depth_m"] < -5.0:
    var sub_base: float = wdata.get("sub_damage", 0.45)
    return clampf(sub_base * _rng.randf_range(0.7, 1.3), 0.05, 1.0)
```

**New field in weapons.json:**

| Weapon | `sub_damage` | Hits to Kill Sub |
|--------|-------------|-----------------|
| mk46_torpedo | 0.45 | 2-3 |
| asroc_rur5 | 0.45 | 2-3 |
| type65_torpedo | 0.65 | 1-2 |

---

### Bug 2: Sonar Absorption Coefficient — 15x Too High

**The math:** `alpha = 0.003 dB/m` = 3 dB/km. At 50nm (92.6km), absorption alone adds **278 dB** of loss. Real absorption at 3.5 kHz is **0.2 dB/km** (`alpha = 0.0002 dB/m`).

**Fix:** In `SimulationWorld.gd`, both `_sonar_detection_passive` and `_sonar_detection_active`:

```gdscript
# Change from:
var alpha: float = 0.003
# Change to:
var alpha: float = 0.0002
```

---

### Bug 3: Sonar Transmission Loss Exponent — Ranges Too Short

**The math:** Using `20*log10(range_m)` (spherical spreading) for all ranges. Real underwater propagation transitions to cylindrical spreading (~10*log10) beyond a few km. Mixed model should use ~15*log10.

**Current detection ranges (Burke passive vs Akula at 8kts, SS4, through thermal layer): 0.35nm.** That's inside minimum torpedo range. The player is dead before contact is established.

**Fix:** Change TL formula in both passive and active sonar functions:

```gdscript
# Change from:
var tl_db: float = 20.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0
# Change to:
var tl_db: float = 15.0 * log(maxf(range_m, 1.0)) / log(10.0) + alpha * range_m / 1000.0
```

**Expected result:** Detection ranges increase from 0.35nm to ~2-5nm through thermal layer.

---

## P1 — DATA FIXES (wrong weapon/sensor/platform values)

### Fix 4: LA-class SSN Carries Wrong Weapon

Los Angeles carries **Mk 48 ADCAP** heavyweight torpedo, not Mk 46 lightweight.

**Add to weapons.json:**
```json
{
    "id": "mk48_adcap",
    "name": "Mk 48 ADCAP",
    "type": "torpedo",
    "guidance": "wire_acoustic",
    "max_range_nm": 27,
    "speed_kts": 55,
    "warhead_kg": 295,
    "pk_base": 0.75,
    "loadout_default": 20,
    "min_range_nm": 0.5,
    "search_pattern": "snake",
    "max_depth_m": 800,
    "sub_damage": 0.70,
    "description": "Heavyweight wire-guided torpedo. Primary US submarine weapon. Active/passive acoustic homing with wire guidance for mid-course corrections."
}
```

**Update LA-class:** Change weapons to `["mk48_adcap", "harpoon_agm84"]`.

### Fix 5: LA-class Has Wrong Sensor

BQS-15 is the under-ice sonar. Primary suite is **BQQ-5**.

**Add to sensors.json:**
```json
{
    "id": "bqq5",
    "name": "AN/BQQ-5",
    "type": "sonar",
    "subtype": "submarine_suite",
    "source_level_db": 230,
    "sensitivity_db": 100,
    "array_gain_db": 32,
    "detection_threshold_db": 3,
    "max_range_nm_active": 25,
    "max_range_nm_passive": 80,
    "frequency_khz": 3.0,
    "description": "Integrated submarine sonar suite. BQS-13 spherical bow array with BQR-15 towed array."
}
```

**Update LA-class:** Change sensors to `["bqq5"]`.

### Fix 6: Perry RCS Too High

Perry (4100t) has RCS 2500m² — 2.5x larger than Burke (8315t). Change to **700m²**.

### Fix 7: ASROC Pk and Loadout

- base_pk 0.55 → **0.62** (delivers a Mk46, minus delivery dispersion)
- loadout_default 16 → **8** (Mk 16 launcher capacity)

### Fix 8: Perry Should NOT Have ASROC

Perry class did not carry ASROC. Remove `"asroc_rur5"` from Perry weapons.

### Fix 9: Soviet Ships Missing Primary Weapons

**Kirov** — Currently has only Type 65. Should have:
- P-700 Granit (SS-N-19): ASM, Mach 2.5, 300nm, 750kg warhead, 20 rounds
- RPK-6 Vodopad (SS-N-16): ASW missile, 27nm, delivers torpedo

**Udaloy** — Should have:
- RPK-6 Vodopad (SS-N-16): 8 rounds
- Change Type 65 to SET-65 (533mm surface ship torpedo)

### Fix 10: Add Towed Array Sonar

**Add AN/SQR-19 TACTAS to sensors.json:**
```json
{
    "id": "sqr19",
    "name": "AN/SQR-19 TACTAS",
    "type": "sonar",
    "subtype": "towed_array",
    "source_level_db": 0,
    "sensitivity_db": 105,
    "array_gain_db": 35,
    "detection_threshold_db": 3,
    "max_range_nm_active": 0,
    "max_range_nm_passive": 100,
    "frequency_khz": 1.0,
    "description": "Tactical Towed Array. Passive only. Most effective below 14 knots."
}
```

Add to Burke and Perry sensor loadouts.

---

## P2 — MISSING MECHANICS

### 11. Radar Horizon

Surface radar cannot detect surface targets beyond ~20nm (Earth curvature). Currently SPY-1D detects at 190nm (physically impossible for surface targets).

```gdscript
var antenna_height_ft: float = detector["platform"].get("antenna_height_ft", 80.0)
var target_height_ft: float = 50.0 if not target_submerged else 0.0
var radar_horizon_nm: float = 1.23 * (sqrt(antenna_height_ft) + sqrt(target_height_ft))
if range_nm > radar_horizon_nm:
    return {"p_detect": 0.0}
```

### 12. ESM (Electronic Support Measures)

Passively detect radar emitters at 2x their radar range. Bearing-only. Every surface combatant has ESM.

### 13. Active Sonar Counter-Detection

Going active should alert every enemy within 2-3x detection range with instant bearing.

### 14. Passive Sonar Bearing-Only

Real passive sonar = bearing only, no range. Range requires TMA (~15-30 min of tracking).

### 15. Scoring System

```
Score = 1000 + KillBonus(300/kill) + SpeedBonus(0-200) - EfficiencyPenalty - LossPenalty(400/ship)
```

| Grade | Score |
|-------|-------|
| S | 1620+ |
| A | 1350-1619 |
| B | 1080-1349 |
| C | 720-1079 |
| D | 360-719 |
| F | <360 |

### 16. Difficulty Scaling

| Parameter | Easy | Normal | Hard | Elite |
|-----------|------|--------|------|-------|
| Sonar det mult | 1.5x | 1.0x | 0.7x | 0.5x |
| Player Pk mult | 1.3x | 1.0x | 0.8x | 0.7x |
| AI attack threshold | 0.50 | 0.30 | 0.20 | 0.15 |
| Enemies | 1 | 2 | 2 | 3 |
| Time limit | 150m | 120m | 90m | 60m |

---

## P3 — NEW PLATFORMS & SYSTEMS

### 17. ASW Helicopters (SH-60B LAMPS III, Ka-27 Helix)

Without helicopters, surface ships must close to suicidal range to prosecute subs. Helicopters extend prosecution to 50+ nm.

### 18. P-3C Orion + Sonobuoys

Primary GIUK Gap ASW asset. 12+ hour endurance, 84 sonobuoys, Mk 46 torpedoes. Requires fuel/endurance, sonobuoy entities, patrol patterns, Keflavik airfield.

### 19. SOSUS Barrier

Fixed seabed hydrophone array. Bearing-only initial cueing. Low complexity, high authenticity.

### 20. Convergence Zone Propagation

Sound refocuses at 30-35nm intervals in deep water. Critical for realistic passive sonar ranges.

---

## CREATIVE DIRECTION (Luna)

### Identity: Cold. Precise. Heavy.

### Campaign: "The Autumn Watch" — 7 Missions

| # | Name | Hook |
|---|------|------|
| 1 | THRESHOLD | First GIUK patrol. Two Akulas. Tutorial graduation. |
| 2 | COLD PASSAGE | Soviet surface group. One Udaloy breaks toward you. |
| 3 | SOSUS GHOST | Unknown signature. Pure detection. Firing has consequences. |
| 4 | NORTHERN WATCH | Restrictive ROE. Fire control radar paints you. Twice. |
| 5 | CROSSING THE LINE | First shots — not by you. ROE unrestricted. |
| 6 | REYKJANES RIDGE | Full engagement. Sub group closes on your carrier. |
| 7 | SILENT WATCH | Shooting stopped. Maintain contact without reigniting. |

### Persistent losses. Ships don't come back.

### Audio: No music during gameplay. Ambient bridge sounds. Sonar echo on detection. Torpedo warning escalation. Radio chatter fragments.

### Debrief: Consequence summary, not score screen. Ship names, crew count, intel note.

---

## IMPLEMENTATION ORDER

```
Phase A — Playable
  Bug 1: Torpedo sub_damage override
  Bug 2: Sonar alpha 0.003 → 0.0002
  Bug 3: Sonar TL exponent 20 → 15
  Fix 4: Add Mk 48, fix LA-class
  Fix 6: Perry RCS 2500 → 700

Phase B — Correct Data
  Fix 5: BQS-15 → BQQ-5
  Fix 7: ASROC Pk/loadout
  Fix 8: Remove ASROC from Perry
  Fix 9: Soviet weapons
  Fix 10: Towed array

Phase C — Mechanics
  Radar horizon
  Scoring system
  Difficulty scaling
  ESM + active sonar counter-detection

Phase D — Air Layer + Campaign
  ASW helicopters
  P-3C + sonobuoys
  SOSUS barrier
  7-mission campaign
```
