# THRESHOLD v0.7-beta

Cold War naval warfare simulation — command US surface ships and submarines in the North Atlantic, hunting Soviet contacts before they slip through.

## How to Run

Double-click `THRESHOLD.exe`. No install required.

## Controls

| Input | Action |
|---|---|
| Left Click | Select unit / Designate target |
| Right Click | Set waypoint |
| F | Fire weapon |
| C | Cycle weapon |
| Tab | Cycle units |
| W / X | Speed increase / decrease |
| [ / ] | Depth up / down (submarines only) |
| R | Toggle radar |
| S | Active sonar |
| L | Launch helicopter |
| H | Center camera on selected unit |
| + / - | Zoom in / out |
| Arrow keys | Pan camera |
| Space | Pause / unpause |
| 1 - 5 | Time scale (1x through 5x) |
| F1 | Toggle controls reference |
| B | Drop sonobuoy (aircraft only) |
| V | Toggle CRT monitor effect |
| M | Toggle minimap |
| Esc | Menu |

## What to Test

- **Tutorial** — Complete the tutorial from start to finish. Confirm all prompts appear and advance correctly.
- **Campaign (The Autumn Watch)** — Play through all 7 missions in sequence. Check mission transitions, briefings, and win/loss screens.
- **Single missions** — Launch any scenario from the Single Mission menu. Confirm scenario loads and plays independently.
- **Sonar and radar detection** — Verify contacts appear on passive sonar (bearing-only), active sonar, and radar at expected ranges. Check that TMA resolves range after ~15 minutes of tracking.
- **Weapon engagement** — Fire torpedoes and missiles at designated targets. Confirm hit/miss resolution and scoring feedback.
- **Scoring** — Verify end-of-mission score is displayed and reflects hits, misses, and time.
- **Mission Debrief** — After each mission, check the debrief screen shows score breakdown, fleet status, and narrative situation report.
- **CRT Mode** — Press V to toggle the retro CRT monitor effect. Verify scanlines, vignette, and barrel distortion render correctly.
- **Weather** — In longer missions, sea state may shift. Check if sonar/radar performance changes with conditions.
- **New scenarios** — Try Torpedo Alley, Convoy Escort, Surface Action, and Lone Wolf from Single Mission menu.
- **Convoy Escort merchants** — In Convoy Escort, the two merchant ships (MV Atlantic Conveyor, MV Nordic Ferry) should be unarmed, slow, and loud. They cannot fire weapons or use countermeasures.
- **Cold Passage (Campaign Mission 2)** — This is now a maintain_contact mission. Shadow the Soviet group for 45 minutes without losing sensor contact. Watch the tracking progress bar.
- **P-700 Granit missiles** — Soviet Kirov fires supersonic missiles that are very hard for CIWS to stop. Expect higher hit rates vs your ships.
- **Score difficulty scaling** — Play the same scenario on Easy vs Hard. Hard should produce higher scores for the same performance.
- **Dialogic narrative briefings** — After enabling the Dialogic plugin, missions show transmission-style briefings with COMMS, INTEL, and COMMAND voices instead of static text. Press Enter to advance. Missions without Dialogic enabled fall back to the text overlay.
- **Minimap** — Press M to toggle the tactical minimap in the bottom-right corner. Shows all known contacts and own forces.
- **Sonobuoys** — Select a P-3C or helicopter and press B to drop a sonobuoy. Verify it detects nearby submarines and expires after ~40 minutes.
- **Helicopter fuel** — Launch a helicopter and watch fuel drain. At 10% it should auto-RTB. Verify it lands and can be relaunched.
- **Ambient audio** — Listen for ocean ambience, sonar return echoes, and occasional radio chatter blips.

## Known Limitations

- No mid-mission save. If you close the game, the mission restarts from the beginning.
- Difficulty selection (Easy/Normal/Hard/Elite) is on the main menu — changes detection ranges, weapon accuracy, and AI aggression.

## Bug Reports

If you find a bug, open an issue at:
https://github.com/jhornatlaw-creator/threshold-game/issues

Include: what you were doing, what happened, and what you expected to happen. Screenshots help.

## Version

v0.7-beta — 2026-03-15
