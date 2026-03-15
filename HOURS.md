# THRESHOLD -- Hour Tracker

## Abandonment Signal
If no entry for 14 consecutive days, project is stalled. Review and either push or shelve.

## Phase 1 Target: 40-80 hours
- Gate 1 (hour 10-15): Ship moves. Radar ring renders. Contact appears.
- Gate 2 (hour 25-40): Enemy moves with doctrine. Fire weapon, get resolution. Core loop closed.
- Gate 3 (hour 50-80): Complete scenario playable start to finish with win/loss.

## Log

| Date       | Hours | Cumulative | Work Done                                              | Gate Progress |
|------------|-------|------------|--------------------------------------------------------|---------------|
| 2026-03-12 | 4     | 4          | Project scaffold, SimulationWorld, PlatformLoader, detection model, RenderBridge, HUD, scenario, data files | Pre-Gate 1 |
| 2026-03-15 | 6     | 10         | Difficulty selection, pause menu, export config, beta docs, settings | Gate 2 |
| 2026-03-15 | 4     | 14         | CRT shader, mission debrief screen, 4 skirmish scenarios, weather system, v0.3 build + release | Gate 2 |
| 2026-03-15 | 4     | 18         | Minimap, sonobuoys, helo fuel/RTB, ambient audio, weather HUD, waypoint routes, v0.4 release | Gate 2 |
| 2026-03-15 | 2     | 20         | QA round 1: 10 bugs fixed (radar crash, sea state sync, RTB tracking, helo recovery) | Gate 2 |
| 2026-03-15 | 2     | 22         | QA round 2: 8 more bugs fixed (PCK skirmish visibility, bearing display, difficulty scaling, audio lifecycle, pause guards, campaign flow), v0.5 release | Gate 2 |
| 2026-03-15 | 3     | 25         | v0.6: merchant vessel platform, P-700 Granit flight profile differentiation, score difficulty multipliers, Cold Passage maintain_contact rewrite, convoy escort platform swap | Gate 2 |
| 2026-03-15 | 3     | 28         | v0.7: Dialogic plugin integration, NarrativeDirector autoload, 6 mission briefing timelines (COMMS/INTEL/COMMAND voices), SPACE key conflict guard, safe fallback when plugin disabled | Gate 2 |
