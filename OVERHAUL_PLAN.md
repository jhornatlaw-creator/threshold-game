# THRESHOLD OVERHAUL -- Merged Build Plan
## Studio Jam + Kerrigan Review (2026-03-24)

### The Soul
**"Cold. Uncertain. Heavy."**
THRESHOLD is a game about listening in the dark and living with what you hear.

### The Four Questions
| Question | Answer |
|----------|--------|
| How to play | Hunt. DETECT, CLASSIFY, LOCALIZE, DECIDE, COMMIT, RESOLVE. Spend time/position/stealth to buy certainty. |
| How to win | Survive. Winning feels like exhaling, not fist-pumping. Victory is expensive. |
| How to lose | Pay. 200 names on a ship. An Akula past the barrier. An ROE violation. The deepest loss: you did everything right and it was not enough. |
| Why | Because you have never played anything that makes silence this heavy. Because 73 crew. |

---

## CRITICAL CORRECTIONS (Kerrigan)

### Anachronisms to Fix
- **Burke-class DDG did not exist in 1985.** Replace with Spruance-class DD (DD-963) or Kidd-class DDG (DDG-993).
- **Mk48 ADCAP did not exist until 1988.** Replace with Mk48 Mod 4.
- Update platforms.json and weapons.json accordingly.

### TMA Formula Correction
Revised weights (Kerrigan): geometry 0.35, bearing spread 0.30, time on track 0.20, leg bonus 0.15.
Geometry function: sin(angle_off_bow)^1.5 (craters near bow/stern).
Ownship speed penalty on TMA quality (flow noise degrades sonar).
Bold leg changes rewarded (60-90 degree turns), timid corrections penalized.

### Sprint-and-Drift Correction
Sprint: 12-18 kts for 8-15 min. Drift: 3-5 kts for 15-20 min with 90-120 degree baffle-clearing turn.
Baffle clear = most dangerous moment for trailing player.

### Weapon Corrections
- SET-65 (533mm, 16nm, acoustic) for destroyer attacks. Type 65 (650mm, wake-homing) for carrier scenarios.
- ASROC: 6nm standoff, rocket-thrown Mk46, 8 ready / 16 total. Resource management.
- Mk46: realistic Pk 30-40% per weapon with good datum.
- Wire guidance: tethered while guiding, cannot maneuver. Cut-the-wire decision is critical.
- No instant weapon feedback: 20-30 min uncertainty after firing. Debrief confirms.

---

## BUILD PHASES

### Phase 1: Foundation (4-5 days)
SimulationWorld decomposition into subsystems (Movement, Detection, Weapon, Damage).
SimulationWorld becomes orchestrator (~15KB). Signal architecture preserved.
Fix anachronisms: Spruance-class DD replaces Burke. Mk48 Mod 4 replaces ADCAP.
Gate: every scenario plays identically after refactor.

### Phase 2: TMA System (5-6 days)
Bearing-only passive sonar + Target Motion Analysis. THIS IS THE GAME.
TMASystem.gd as new subsystem. TMAContact resource class.
State machine: NO_CONTACT, DETECTING, TRACKING, SOLUTION (regresses on target maneuver).
Corrected formula (Kerrigan weights). Ownship speed penalty.
Towed array blind zone forward (~30-degree cone).
Uncertainty ellipse visualization (wide zone narrowing to point).
Remove range from passive sonar contacts completely.

### Phase 3: Narrative Pipeline (3 days, PARALLEL with Phase 2)
Character definitions: COMMAND (Hale), INTEL (Vasquez), COMMS (Ruiz).
Mid-mission comms: 2-3 per campaign mission, gameplay-triggered.
Interludes: 6 between-mission SIGINT fragments / flash traffic.
Debrief: real crew counts, enemy kills with hull number + crew, campaign-persistent grief.
Crew manifest: generate names pre-campaign, scroll on ship loss.

### Phase 4: Thermal Layers + Environment (3-4 days)
XBT drop mechanic. Hull sonar blocked by thermocline. Towed array goes deep.
CZ detection: binary on bathymetry. First CZ ~33nm, second ~66nm.
Sea state affects detection. Weather affects helicopter ops.
Submarine AI: detected = go deep below layer.

### Phase 5: Counter-Detection + EMCON (3 days)
Active sonar counter-detection (2-3x range). Two active modes (quiet/full-power).
EMCON states: Alpha (passive), Bravo (nav radar only), Charlie (most active), Delta (full).
ESM: detect radar at 2-3x range. Instant classification.
Radar horizon formula implemented.

### Phase 6: AI Doctrine (4 days)
Soviet submarine: corrected sprint-and-drift with baffle-clearing turn.
Evasion: sprint perpendicular, go deep below thermocline, deploy decoy.
Counterattack: fire torpedo when good solution, then evade.
Surface group: Udaloys screen Kirov, P-700 salvo response.
Difficulty = AI behavior, not physics.

### Phase 7: Helicopter + P-3C Operations (3-4 days)
Helicopter as deployable asset: player vectors, chooses sonobuoy patterns.
Fuel management (3 hours on station), weather constraints.
P-3C coordination: datum, patterns, contacts, attack.
Active sonobuoys alert submarine AI.

### Phase 8: Weapons Polish + Pk Linkage (2-3 days)
effective_Pk = base_Pk * solution_quality * weapon_factors.
No instant feedback: uncertainty for 20-30 min post-fire.
Wire guidance mechanic: stay on wire vs cut wire.
ASROC standoff. Countermeasures (NIXIE, noisemakers, chaff).
Wake-homing countermeasure: change wake pattern.

### Phase 9: Sonar Soundscape + Audio (3 days)
Own-ship noise, biologics, contact audio (screw beats, tonals, transients).
Audio-first detection (sound before display confirms).
Active ping: expanding ring, beautiful and terrifying.
Time compression pitch-shift. Contact crystallization tone.
Torpedo: quiet thunk, run audio, distant boom (maybe), silence.

### Phase 10: ROE + Crisis Temperature + Campaign (3-4 days)
Classification ladder: UNKNOWN, SUSPECT, PROBABLE HOSTILE, CERTAIN HOSTILE.
ROE gates: TIGHT (locked), HOLD (certain + threat), FREE (probable sufficient).
Crisis Temperature: hidden cross-campaign variable.
Crew fatigue: degrades sensors, reaction time, false positive rate.
Patrol Log: declassified after-action report at campaign end.

### Phase 11: Save + Final Polish (2-3 days)
Mid-mission save/load via subsystem state serialization.
Kill minimap: replace with tactical plot (bearing lines, probability areas, datum circles).
No precise enemy positions ever. Uncertainty ellipses and estimated tracks only.
Menu atmosphere. Debrief: no Continue button for 3 seconds.

---

## KILL LIST (Unanimous)
- Music (ever)
- Hero characters / named protagonists / voice acting
- Achievement popups, kill counters, victory fanfare
- Difficulty modes that change physics
- Explained motivation speeches
- Minimap (replace with tactical plot from sensor data)
- Instant weapon feedback
- Range on passive sonar contacts

## CONSULTANTS ON DECK
- **CDR Kerrigan** (naval-expert.md) -- on deck for all phases
- **Koji Tanaka** (/4x-designer) -- systems balance if needed
- **Dr. Elaine Marsh** (/literary-phd) -- narrative polish pass
- **Dr. Helen Voss** (/psychoacoustics) -- Phase 9 sonar soundscape

## TOTAL: ~35-40 days dev time across 11 phases
