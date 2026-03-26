extends Node
## AudioManager -- Procedural audio system for THRESHOLD.
## All sounds are generated from PCM data at startup. No external audio files needed.
## Registered as an autoload singleton in project.godot.
##
## Phase 9: Sonar Soundscape + Audio Juice
## Seven audio layers:
##   1. Own-ship noise floor (hull creaks, machinery hum, flow noise, cavitation)
##   2. Ocean ambience (wind/wave, biologics, distant traffic)
##   3. Contact audio (screw beats, machinery tonals, transients) -- audio-first detection
##   4. Sonar system sounds (active ping, TMA crystallization, classification upgrade)
##   5. Weapon sounds (torpedo launch/run/impact, incoming warning)
##   6. Time compression pitch-shift
##   7. UI audio (click, confirm, splash, static burst, sonobuoy chirp)

# ---------------------------------------------------------------------------
# Signals -- other systems trigger audio through these
# ---------------------------------------------------------------------------
signal contact_audio_started(contact_id: String)  # Audio cue started (before display confirms)

# ---------------------------------------------------------------------------
# AudioStreamPlayer nodes -- original
# ---------------------------------------------------------------------------
var _player_sonar: AudioStreamPlayer
var _player_contact: AudioStreamPlayer
var _player_weapon: AudioStreamPlayer
var _player_explosion: AudioStreamPlayer
var _player_warning: AudioStreamPlayer  # looping torpedo warning
var _player_missile: AudioStreamPlayer
var _player_ocean: AudioStreamPlayer
var _player_sonar_return: AudioStreamPlayer
var _player_radio: AudioStreamPlayer

# Phase 9: additional audio players
var _player_hull_creak: AudioStreamPlayer
var _player_machinery: AudioStreamPlayer   # looping machinery hum
var _player_flow_noise: AudioStreamPlayer   # looping flow noise
var _player_cavitation: AudioStreamPlayer   # looping cavitation
var _player_biologics: AudioStreamPlayer    # whale calls / shrimp clicking
var _player_traffic: AudioStreamPlayer      # distant surface traffic
var _player_screw_beat: AudioStreamPlayer   # contact screw beats
var _player_tonal: AudioStreamPlayer        # contact machinery tonal
var _player_transient: AudioStreamPlayer    # contact transient
var _player_tma_tone: AudioStreamPlayer     # TMA solution crystallization
var _player_classify: AudioStreamPlayer     # classification upgrade tone
var _player_torp_run: AudioStreamPlayer     # torpedo run whine
var _player_torp_impact: AudioStreamPlayer  # distant impact boom
var _player_ui: AudioStreamPlayer           # UI clicks/confirms
var _player_splash: AudioStreamPlayer       # XBT/sonobuoy splash
var _player_emcon: AudioStreamPlayer        # EMCON change static burst
var _player_incoming: AudioStreamPlayer     # incoming torpedo rising pitch (replaces old warning)

# ---------------------------------------------------------------------------
# Pregenerated streams -- original
# ---------------------------------------------------------------------------
var _stream_sonar_ping: AudioStreamWAV
var _stream_contact_new: AudioStreamWAV
var _stream_weapon_launch: AudioStreamWAV
var _stream_explosion: AudioStreamWAV
var _stream_torpedo_warning: AudioStreamWAV
var _stream_missile_away: AudioStreamWAV
var _stream_ocean_loop: AudioStreamWAV
var _stream_sonar_return: AudioStreamWAV
var _stream_radio_chatter: AudioStreamWAV

# Phase 9: new streams
var _stream_hull_creak: AudioStreamWAV
var _stream_machinery_hum: AudioStreamWAV
var _stream_flow_noise: AudioStreamWAV
var _stream_cavitation: AudioStreamWAV
var _stream_whale_call: AudioStreamWAV
var _stream_shrimp_click: AudioStreamWAV
var _stream_distant_traffic: AudioStreamWAV
var _stream_tma_crystallize: AudioStreamWAV
var _stream_classify_upgrade: AudioStreamWAV
var _stream_tma_lock: AudioStreamWAV
var _stream_torp_launch_thunk: AudioStreamWAV   # mechanical clunk for torpedo tube
var _stream_torp_run_whine: AudioStreamWAV       # high-pitched wire-guided torpedo
var _stream_torp_impact: AudioStreamWAV          # deep rolling boom
var _stream_incoming_warning: AudioStreamWAV     # rising pitch urgency tone
var _stream_ui_click: AudioStreamWAV
var _stream_ui_confirm: AudioStreamWAV
var _stream_splash: AudioStreamWAV
var _stream_emcon_burst: AudioStreamWAV
var _stream_sonobuoy_chirp: AudioStreamWAV

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
# Torpedo warning state
var _warning_active: bool = false

# Radio chatter timer
var _radio_timer: float = 0.0
var _radio_interval: float = 60.0  # Will be randomized

# Phase 9 state
var _current_sea_state: int = 3
var _ownship_speed_kts: float = 0.0
var _ownship_heading: float = 0.0
var _time_compression: float = 1.0

# Biologics timer
var _biologics_timer: float = 0.0
var _biologics_interval: float = 45.0  # seconds between biologic sounds

# Hull creak timer
var _creak_timer: float = 0.0
var _creak_interval: float = 8.0

# Distant traffic timer
var _traffic_timer: float = 0.0
var _traffic_interval: float = 120.0
var _traffic_active: bool = false

# Contact audio tracking: contact_id -> {type, bearing, speed, active}
var _active_contact_audio: Dictionary = {}

# Audio-first detection delay queue: [{contact_id, type, bearing, display_time}]
var _pending_audio_cues: Array = []

# Cached PCM streams keyed by speed bucket (0.0, 0.25, 0.5, 0.75, 1.0)
var _cached_screw_beats: Dictionary = {}
# Cached machinery tonal streams keyed by class_hash
var _cached_machinery_tonals: Dictionary = {}

const SAMPLE_RATE: int = 22050
const CAVITATION_SPEED_KTS: float = 20.0  # Speed threshold for cavitation

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_generate_all_streams()
	_create_players()
	# Ocean ambience starts when scenario loads, not at boot

func _process(delta: float) -> void:
	if not SimulationWorld.is_paused and SimulationWorld.tick_count > 0:
		# Original: radio chatter timer
		_radio_timer += delta
		if _radio_timer >= _radio_interval:
			_radio_timer = 0.0
			_radio_interval = randf_range(30.0, 90.0)
			play_radio_chatter()

		# Phase 9: own-ship noise modulation
		_update_ownship_audio(delta)

		# Phase 9: biologic sounds (whale calls, shrimp)
		_biologics_timer += delta
		if _biologics_timer >= _biologics_interval:
			_biologics_timer = 0.0
			_biologics_interval = randf_range(25.0, 90.0)
			_play_biologic()

		# Phase 9: hull creaks (intermittent)
		_creak_timer += delta
		if _creak_timer >= _creak_interval:
			_creak_timer = 0.0
			_creak_interval = randf_range(5.0, 15.0)
			_play_hull_creak()

		# Phase 9: distant surface traffic
		_traffic_timer += delta
		if _traffic_timer >= _traffic_interval:
			_traffic_timer = 0.0
			_traffic_interval = randf_range(60.0, 180.0)
			_toggle_distant_traffic()

		# Phase 9: process audio-first detection queue
		_process_pending_audio_cues(delta)

func _create_players() -> void:
	# Original players
	_player_sonar = _make_player("SonarPlayer", -6.0)
	_player_contact = _make_player("ContactPlayer", -4.0)
	_player_weapon = _make_player("WeaponPlayer", -8.0)
	_player_explosion = _make_player("ExplosionPlayer", -4.0)
	_player_warning = _make_player("WarningPlayer", -5.0)
	_player_missile = _make_player("MissilePlayer", -8.0)
	_player_ocean = _make_player("OceanPlayer", -20.0)  # Very quiet
	_player_sonar_return = _make_player("SonarReturnPlayer", -10.0)
	_player_radio = _make_player("RadioPlayer", -14.0)

	# Phase 9: own-ship noise floor
	_player_hull_creak = _make_player("HullCreakPlayer", -22.0)
	_player_machinery = _make_player("MachineryPlayer", -26.0)
	_player_flow_noise = _make_player("FlowNoisePlayer", -28.0)
	_player_cavitation = _make_player("CavitationPlayer", -18.0)

	# Phase 9: ocean biologics + traffic
	_player_biologics = _make_player("BiologicsPlayer", -24.0)
	_player_traffic = _make_player("TrafficPlayer", -30.0)

	# Phase 9: contact audio
	_player_screw_beat = _make_player("ScrewBeatPlayer", -16.0)
	_player_tonal = _make_player("TonalPlayer", -20.0)
	_player_transient = _make_player("TransientPlayer", -12.0)

	# Phase 9: sonar system
	_player_tma_tone = _make_player("TMATonePlayer", -18.0)
	_player_classify = _make_player("ClassifyPlayer", -14.0)

	# Phase 9: weapon sounds
	_player_torp_run = _make_player("TorpRunPlayer", -22.0)
	_player_torp_impact = _make_player("TorpImpactPlayer", -8.0)
	_player_incoming = _make_player("IncomingPlayer", -6.0)

	# Phase 9: UI sounds
	_player_ui = _make_player("UIPlayer", -16.0)
	_player_splash = _make_player("SplashPlayer", -14.0)
	_player_emcon = _make_player("EMCONPlayer", -12.0)

func _make_player(node_name: String, volume_db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.name = node_name
	p.volume_db = volume_db
	add_child(p)
	return p

# ---------------------------------------------------------------------------
# Stream generation
# ---------------------------------------------------------------------------
func _generate_all_streams() -> void:
	# Original streams
	_stream_sonar_ping = _generate_sonar_ping()
	_stream_contact_new = _generate_contact_new()
	_stream_weapon_launch = _generate_weapon_launch()
	_stream_explosion = _generate_explosion()
	_stream_torpedo_warning = _generate_torpedo_warning()
	_stream_missile_away = _generate_missile_away()
	_stream_ocean_loop = _generate_ocean_loop()
	_stream_sonar_return = _generate_sonar_return()
	_stream_radio_chatter = _generate_radio_chatter()

	# Phase 9: new streams
	_stream_hull_creak = _generate_hull_creak()
	_stream_machinery_hum = _generate_machinery_hum()
	_stream_flow_noise = _generate_flow_noise()
	_stream_cavitation = _generate_cavitation()
	_stream_whale_call = _generate_whale_call()
	_stream_shrimp_click = _generate_shrimp_click()
	_stream_distant_traffic = _generate_distant_traffic()
	_stream_tma_crystallize = _generate_tma_crystallize()
	_stream_classify_upgrade = _generate_classify_upgrade()
	_stream_tma_lock = _generate_tma_lock()
	_stream_torp_launch_thunk = _generate_torp_launch_thunk()
	_stream_torp_run_whine = _generate_torp_run_whine()
	_stream_torp_impact = _generate_torp_impact()
	_stream_incoming_warning = _generate_incoming_warning()
	_stream_ui_click = _generate_ui_click()
	_stream_ui_confirm = _generate_ui_confirm()
	_stream_splash = _generate_splash()
	_stream_emcon_burst = _generate_emcon_burst()
	_stream_sonobuoy_chirp = _generate_sonobuoy_chirp()

# ---------------------------------------------------------------------------
# Original stream generators (preserved exactly)
# ---------------------------------------------------------------------------

## Simple sine tone with optional fade-out envelope
func _generate_tone(freq: float, duration: float, volume: float = 0.4, fade_out: bool = true) -> AudioStreamWAV:
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)  # 16-bit = 2 bytes per sample
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var envelope: float = 1.0
		if fade_out:
			envelope = 1.0 - (float(i) / num_samples)
		var sample: float = sin(2.0 * PI * freq * t) * volume * envelope
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Classic sonar ping: 1500 Hz, 0.3s, exponential decay
func _generate_sonar_ping() -> AudioStreamWAV:
	var freq: float = 1500.0
	var duration: float = 0.3
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Exponential decay for natural ping tail
		var envelope: float = exp(-t * 12.0)
		var sample: float = sin(2.0 * PI * freq * t) * 0.45 * envelope
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Double-beep alert: 800 Hz, two 0.1s beeps with 0.05s gap
func _generate_contact_new() -> AudioStreamWAV:
	var freq: float = 800.0
	var beep_dur: float = 0.1
	var gap_dur: float = 0.05
	var total_dur: float = beep_dur + gap_dur + beep_dur
	var num_samples: int = int(SAMPLE_RATE * total_dur)
	var beep_samples: int = int(SAMPLE_RATE * beep_dur)
	var gap_samples: int = int(SAMPLE_RATE * gap_dur)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var sample: float = 0.0
		# First beep
		if i < beep_samples:
			var env: float = 1.0 - (float(i) / beep_samples)
			sample = sin(2.0 * PI * freq * t) * 0.4 * env
		# Gap: silence
		elif i < beep_samples + gap_samples:
			sample = 0.0
		# Second beep
		else:
			var local_i: int = i - beep_samples - gap_samples
			var local_t: float = float(local_i) / SAMPLE_RATE
			var env: float = 1.0 - (float(local_i) / beep_samples)
			sample = sin(2.0 * PI * freq * local_t) * 0.4 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Weapon launch thump: 200 Hz, 0.15s, fast decay
func _generate_weapon_launch() -> AudioStreamWAV:
	return _generate_tone(200.0, 0.15, 0.45, true)

## Explosion: mix of 80 Hz + 160 Hz + 320 Hz + pseudo-noise, 0.4s fast decay
func _generate_explosion() -> AudioStreamWAV:
	var duration: float = 0.4
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	# Pseudo-random state for noise
	var noise_state: int = 12345
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var envelope: float = exp(-t * 10.0)
		# Mix of low harmonics for rumble
		var sig: float = sin(2.0 * PI * 80.0 * t) * 0.3
		sig += sin(2.0 * PI * 160.0 * t) * 0.2
		sig += sin(2.0 * PI * 320.0 * t) * 0.1
		# Add pseudo-noise via LCG
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		sig += noise * 0.25
		sig *= 0.4 * envelope
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Torpedo warning tone: 600 Hz, 0.2s on / 0.3s off, one cycle (0.5s) -- looped by player
func _generate_torpedo_warning() -> AudioStreamWAV:
	var freq: float = 600.0
	var on_dur: float = 0.2
	var off_dur: float = 0.3
	var total_dur: float = on_dur + off_dur
	var num_samples: int = int(SAMPLE_RATE * total_dur)
	var on_samples: int = int(SAMPLE_RATE * on_dur)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var sample: float = 0.0
		if i < on_samples:
			# Slight fade-in and fade-out on the beep to avoid click artifacts
			var local_t: float = float(i) / on_samples
			var env: float = sin(PI * local_t)  # smooth on/off ramp
			sample = sin(2.0 * PI * freq * t) * 0.4 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Missile away: rising tone sweep 400 Hz -> 1200 Hz over 0.2s
func _generate_missile_away() -> AudioStreamWAV:
	var duration: float = 0.2
	var freq_start: float = 400.0
	var freq_end: float = 1200.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var phase: float = 0.0
	for i in range(num_samples):
		var progress: float = float(i) / num_samples
		var freq: float = freq_start + (freq_end - freq_start) * progress
		# Envelope: fade in then out
		var env: float = sin(PI * progress)
		var sample: float = sin(phase) * 0.4 * env
		phase += 2.0 * PI * freq / SAMPLE_RATE
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Ocean ambience: low-frequency rumble + wave wash + subtle hiss, 2s looped
func _generate_ocean_loop() -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 54321
	var lp_state: float = 0.0  # Low-pass filter state
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# LCG noise
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		# Simple low-pass filter (cutoff ~200 Hz) for ocean rumble
		var alpha: float = 0.05  # Lower = more filtering
		lp_state = lp_state + alpha * (noise - lp_state)
		# Mix: heavy low-pass (rumble) + slight raw noise (spray)
		var sample: float = lp_state * 0.6 + noise * 0.05
		# Add very slow amplitude modulation for wave rhythm (~0.15 Hz)
		var wave_mod: float = 0.85 + 0.15 * sin(2.0 * PI * 0.15 * t)
		sample *= wave_mod * 0.25
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Sonar return echo: 1450 Hz (slight Doppler shift), 0.5s, slower decay than ping
func _generate_sonar_return() -> AudioStreamWAV:
	var freq: float = 1450.0  # Slightly lower due to Doppler
	var duration: float = 0.5
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var envelope: float = exp(-t * 8.0)  # Slower decay than ping
		var sample: float = sin(2.0 * PI * freq * t) * 0.15 * envelope
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Radio chatter blip: band-pass filtered noise burst (sounds like radio squelch), 0.3s
func _generate_radio_chatter() -> AudioStreamWAV:
	var duration: float = 0.3
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 98765
	var bp_state1: float = 0.0
	var bp_state2: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		# Band-pass around 2000 Hz (radio frequency range)
		var alpha_hp: float = 0.3  # High-pass
		var alpha_lp: float = 0.15  # Low-pass
		bp_state1 = bp_state1 + alpha_lp * (noise - bp_state1)
		bp_state2 = bp_state2 + alpha_hp * (bp_state1 - bp_state2)
		var sample: float = bp_state1 - bp_state2
		# Envelope: quick fade in, sustain, quick fade out
		var env: float = 1.0
		if t < 0.02:
			env = t / 0.02
		elif t > 0.25:
			env = (duration - t) / 0.05
		sample *= env * 0.2
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Phase 9: New stream generators -- Own-Ship Noise Floor
# ---------------------------------------------------------------------------

## Hull creaks: very low frequency rumble with random pitch variation, 0.4s
## Sounds like metal stress -- subtle but unmistakable in a quiet sonar room.
func _generate_hull_creak() -> AudioStreamWAV:
	var duration: float = 0.4
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 77777
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = float(i) / num_samples
		# Low frequency sweep 40-80 Hz (hull stress groan)
		var freq: float = 40.0 + 40.0 * sin(PI * progress * 0.5)
		var envelope: float = sin(PI * progress)  # fade in/out
		envelope *= envelope  # sharper envelope
		var sig: float = sin(2.0 * PI * freq * t) * 0.3
		# Add metallic overtone
		sig += sin(2.0 * PI * freq * 3.7 * t) * 0.08 * envelope
		# Tiny noise component for texture
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		sig += noise * 0.04
		sig *= envelope * 0.3
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Machinery hum: constant low drone at 60 Hz + harmonics, 2s looped.
## Pitch increases slightly when speed updates (handled in _update_ownship_audio).
func _generate_machinery_hum() -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Base 60 Hz hum with harmonics (like engine room transformer)
		var sig: float = sin(2.0 * PI * 60.0 * t) * 0.25
		sig += sin(2.0 * PI * 120.0 * t) * 0.12  # 2nd harmonic
		sig += sin(2.0 * PI * 180.0 * t) * 0.06  # 3rd harmonic
		# Subtle amplitude wobble for realism
		var wobble: float = 0.95 + 0.05 * sin(2.0 * PI * 0.3 * t)
		sig *= wobble * 0.2
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Flow noise: filtered noise that scales with speed, 2s looped.
## The rushing water sound outside the hull. Louder = faster = noisier for sonar.
func _generate_flow_noise() -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 33333
	var lp_state: float = 0.0
	var hp_state: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		# Band-pass: 100-800 Hz (water flow characteristic)
		lp_state = lp_state + 0.12 * (noise - lp_state)
		hp_state = hp_state + 0.02 * (lp_state - hp_state)
		var sample: float = lp_state - hp_state
		# Slow modulation (turbulence variation)
		var turb: float = 0.8 + 0.2 * sin(2.0 * PI * 0.5 * t)
		sample *= turb * 0.15
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Cavitation: churning propeller noise above ~20 kts, 2s looped.
## Distinct bubbling/churning sound. Speed = noise = bad for sonar.
func _generate_cavitation() -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 11111
	var lp1: float = 0.0
	var lp2: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		# Heavy low-pass for bubble rumble
		lp1 = lp1 + 0.08 * (noise - lp1)
		# Second layer: crackle (less filtered)
		lp2 = lp2 + 0.3 * (noise - lp2)
		# Mix: heavy rumble + crackle
		var sample: float = lp1 * 0.5 + lp2 * 0.15
		# Rhythmic pulsing at ~5 Hz (propeller blade rate)
		var pulse: float = 0.6 + 0.4 * sin(2.0 * PI * 5.0 * t)
		sample *= pulse * 0.25
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Phase 9: New stream generators -- Ocean Ambience
# ---------------------------------------------------------------------------

## Whale call: eerie descending tone, 2s. Distant and haunting.
func _generate_whale_call() -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var phase: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = float(i) / num_samples
		# Descending sweep: 400 Hz -> 150 Hz (whale moan)
		var freq: float = 400.0 - 250.0 * progress
		# Envelope: slow fade in, sustain, slow fade out
		var env: float = 1.0
		if t < 0.3:
			env = t / 0.3
		elif t > 1.5:
			env = (duration - t) / 0.5
		# Vibrato for organic quality
		var vibrato: float = sin(2.0 * PI * 4.0 * t) * 3.0  # +/- 3 Hz wobble
		var sample: float = sin(phase) * 0.15 * env
		phase += 2.0 * PI * (freq + vibrato) / SAMPLE_RATE
		# Add a faint harmonic overtone
		sample += sin(phase * 2.03) * 0.03 * env  # slightly detuned harmonic
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Shrimp clicking: faint background crackle, very short bursts, 0.5s.
func _generate_shrimp_click() -> AudioStreamWAV:
	var duration: float = 0.5
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 55555
	for i in range(num_samples):
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		var sample: float = 0.0
		# Sparse random clicks (about 20% of samples have a click)
		if absf(noise) > 0.85:
			# Sharp transient click
			sample = noise * 0.12
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Distant surface traffic: very faint engine rumble, 3s.
func _generate_distant_traffic() -> AudioStreamWAV:
	var duration: float = 3.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 22222
	var lp_state: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = float(i) / num_samples
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		# Very heavy low-pass: distant diesel rumble
		lp_state = lp_state + 0.02 * (noise - lp_state)
		# Slow fade in and out (ship passing)
		var env: float = sin(PI * progress) * sin(PI * progress)
		var sample: float = lp_state * env * 0.1
		# Faint propeller beat
		sample += sin(2.0 * PI * 8.0 * t) * 0.015 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Phase 9: New stream generators -- Contact Audio
# ---------------------------------------------------------------------------

## Generate screw beats for a contact. Rate depends on target speed.
## speed_factor: 0.0 (slow) to 1.0 (fast). Controls beat frequency.
func _generate_screw_beats(speed_factor: float) -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	# Beat rate: 2 Hz (slow) to 8 Hz (fast)
	var beat_hz: float = 2.0 + speed_factor * 6.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Rhythmic thumping: sharp attack, exponential decay
		var beat_phase: float = fmod(t * beat_hz, 1.0)
		var beat_env: float = exp(-beat_phase * 8.0)  # sharp attack, fast decay
		# Low thump: 50-80 Hz depending on platform
		var freq: float = 50.0 + speed_factor * 30.0
		var sample: float = sin(2.0 * PI * freq * t) * beat_env * 0.2
		# Add broadband component (propeller wash)
		sample += sin(2.0 * PI * freq * 2.1 * t) * beat_env * 0.05
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Generate machinery tonal for a specific platform class.
## Each class_name produces a slightly different frequency, so they sound distinct.
func _generate_machinery_tonal(class_hash: int) -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	# Deterministic tonal frequency from class hash: 120-350 Hz range
	var base_freq: float = 120.0 + float(class_hash % 230)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Steady hum with slow vibrato
		var vibrato: float = sin(2.0 * PI * 0.5 * t) * 1.5
		var sig: float = sin(2.0 * PI * (base_freq + vibrato) * t) * 0.12
		# Add a harmonic for character
		sig += sin(2.0 * PI * (base_freq * 2.0 + vibrato * 0.5) * t) * 0.04
		# Subtle amplitude variation
		var amp_mod: float = 0.9 + 0.1 * sin(2.0 * PI * 0.2 * t)
		sig *= amp_mod
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Transient sound: brief mechanical sound (hatch slam, torpedo door, ballast).
## Rare but alarming. A single sharp clang.
func _generate_transient() -> AudioStreamWAV:
	var duration: float = 0.15
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Sharp metallic transient: high frequency burst with fast decay
		var env: float = exp(-t * 40.0)  # Very fast decay
		# Multiple harmonics for metallic character
		var sig: float = sin(2.0 * PI * 800.0 * t) * 0.3 * env
		sig += sin(2.0 * PI * 2400.0 * t) * 0.15 * env
		sig += sin(2.0 * PI * 4200.0 * t) * 0.08 * env
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Phase 9: New stream generators -- Sonar System Sounds
# ---------------------------------------------------------------------------

## TMA crystallization tone: subtle focusing sound that gets clearer as quality improves.
## Low-pass filtered tone that sharpens. 0.5s.
func _generate_tma_crystallize() -> AudioStreamWAV:
	var duration: float = 0.5
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var progress: float = float(i) / num_samples
		# Tone rises in clarity: cutoff increases over time
		var freq: float = 600.0
		var env: float = sin(PI * progress)
		# Start muffled, end clear
		var clarity: float = 0.3 + 0.7 * progress
		var sig: float = sin(2.0 * PI * freq * t) * 0.15 * env * clarity
		# Add harmonic that fades in
		sig += sin(2.0 * PI * freq * 2.0 * t) * 0.06 * env * clarity * clarity
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Classification upgrade tone: brief tone shift when contact moves up the ladder.
## Two ascending notes: 500 Hz -> 700 Hz, 0.2s total.
func _generate_classify_upgrade() -> AudioStreamWAV:
	var duration: float = 0.2
	var num_samples: int = int(SAMPLE_RATE * duration)
	var half: int = num_samples / 2
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = 500.0 if i < half else 700.0
		var local_progress: float = float(i % half) / half
		var env: float = sin(PI * local_progress)
		var sample: float = sin(2.0 * PI * freq * t) * 0.2 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## TMA lock tone: soft, satisfying confirmation at quality > 0.9.
## Pure 880 Hz (concert A5) with gentle decay, 0.3s.
func _generate_tma_lock() -> AudioStreamWAV:
	var duration: float = 0.3
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var env: float = exp(-t * 5.0)  # Gentle decay
		# Clean A5 with soft harmonic
		var sig: float = sin(2.0 * PI * 880.0 * t) * 0.2 * env
		sig += sin(2.0 * PI * 1760.0 * t) * 0.05 * env  # Octave overtone
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Phase 9: New stream generators -- Weapon Sounds
# ---------------------------------------------------------------------------

## Torpedo launch: mechanical thunk/clunk. NOT explosive. Quiet. Professional.
## Tube door opening, water slug ejection. 0.2s.
func _generate_torp_launch_thunk() -> AudioStreamWAV:
	var duration: float = 0.2
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 44444
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Two-phase: clunk (0-0.05s) then water rush (0.05-0.2s)
		var sample: float = 0.0
		if t < 0.05:
			# Metallic clunk: sharp transient
			var env: float = exp(-t * 60.0)
			sample = sin(2.0 * PI * 150.0 * t) * 0.4 * env
			sample += sin(2.0 * PI * 450.0 * t) * 0.15 * env
		else:
			# Water slug rush: filtered noise fading out
			var local_t: float = t - 0.05
			noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
			var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
			var env: float = exp(-local_t * 12.0)
			sample = noise * 0.12 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Torpedo run: faint high-pitched whine (wire-guided), 2s looped.
## Own torpedo: faint. Enemy torpedo: gets louder as it approaches (volume modulated externally).
func _generate_torp_run_whine() -> AudioStreamWAV:
	var duration: float = 2.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# High-pitched screw whine: 2000 Hz base + harmonics
		var sig: float = sin(2.0 * PI * 2000.0 * t) * 0.08
		sig += sin(2.0 * PI * 4000.0 * t) * 0.03
		# Propeller modulation at 12 Hz
		var prop_mod: float = 0.7 + 0.3 * sin(2.0 * PI * 12.0 * t)
		sig *= prop_mod
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

## Torpedo impact: deep, rolling boom. Distant. Felt more than heard.
## Low-frequency rumble with slow decay, 1.5s.
func _generate_torp_impact() -> AudioStreamWAV:
	var duration: float = 1.5
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 66666
	var lp_state: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		# Very slow decay: this rolls through the ocean
		var env: float = exp(-t * 2.5)
		# Deep harmonics: 30 Hz + 60 Hz + 90 Hz (hull breaking apart)
		var sig: float = sin(2.0 * PI * 30.0 * t) * 0.35 * env
		sig += sin(2.0 * PI * 60.0 * t) * 0.2 * env
		sig += sin(2.0 * PI * 90.0 * t) * 0.1 * env
		# Noise component: hull fragmentation
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		lp_state = lp_state + 0.03 * (noise - lp_state)
		sig += lp_state * 0.15 * env
		sig *= 0.4
		var sample_int: int = int(clampf(sig, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Incoming torpedo warning: rising pitch that creates urgency without klaxon.
## NOT an alarm -- a rising tone. 1s looped.
func _generate_incoming_warning() -> AudioStreamWAV:
	var duration: float = 1.0
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var phase: float = 0.0
	for i in range(num_samples):
		var progress: float = float(i) / num_samples
		# Rising sweep: 300 Hz -> 900 Hz over 1 second, then resets (loop)
		var freq: float = 300.0 + 600.0 * progress * progress  # Accelerating rise
		var env: float = 0.6 + 0.4 * progress  # Gets louder as it rises
		var sample: float = sin(phase) * 0.35 * env
		phase += 2.0 * PI * freq / SAMPLE_RATE
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = num_samples
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Phase 9: New stream generators -- UI Audio
# ---------------------------------------------------------------------------

## UI click: soft click for unit selection. 0.02s.
func _generate_ui_click() -> AudioStreamWAV:
	var duration: float = 0.02
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var env: float = exp(-t * 200.0)
		var sample: float = sin(2.0 * PI * 3000.0 * t) * 0.15 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## UI confirm: subtle confirmation tone for waypoint set. Two quick tones. 0.1s.
func _generate_ui_confirm() -> AudioStreamWAV:
	var duration: float = 0.1
	var num_samples: int = int(SAMPLE_RATE * duration)
	var half: int = num_samples / 2
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		var freq: float = 1000.0 if i < half else 1200.0
		var local_i: int = i % half
		var env: float = exp(-float(local_i) / half * 3.0)
		var sample: float = sin(2.0 * PI * freq * t) * 0.12 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Splash sound: XBT drop or sonobuoy deployment. 0.15s.
func _generate_splash() -> AudioStreamWAV:
	var duration: float = 0.15
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 88888
	var lp_state: float = 0.0
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		# Low-pass filtered noise burst (water impact)
		lp_state = lp_state + 0.15 * (noise - lp_state)
		var env: float = exp(-t * 25.0)
		var sample: float = lp_state * 0.3 * env
		# Add a brief bubble pop
		sample += sin(2.0 * PI * 250.0 * t) * 0.1 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## EMCON state change: brief static burst (radio squelch). 0.08s.
func _generate_emcon_burst() -> AudioStreamWAV:
	var duration: float = 0.08
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var noise_state: int = 99999
	for i in range(num_samples):
		var t: float = float(i) / SAMPLE_RATE
		noise_state = (noise_state * 1664525 + 1013904223) & 0x7FFFFFFF
		var noise: float = (float(noise_state) / float(0x7FFFFFFF)) * 2.0 - 1.0
		var env: float = sin(PI * float(i) / num_samples)
		var sample: float = noise * 0.2 * env
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

## Sonobuoy initialization chirp: brief sonar chirp after splash. 0.1s.
func _generate_sonobuoy_chirp() -> AudioStreamWAV:
	var duration: float = 0.1
	var num_samples: int = int(SAMPLE_RATE * duration)
	var data := PackedByteArray()
	data.resize(num_samples * 2)
	var phase: float = 0.0
	for i in range(num_samples):
		var progress: float = float(i) / num_samples
		# Ascending chirp: 800 -> 2400 Hz
		var freq: float = 800.0 + 1600.0 * progress
		var env: float = sin(PI * progress) * 0.15
		var sample: float = sin(phase) * env
		phase += 2.0 * PI * freq / SAMPLE_RATE
		var sample_int: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, sample_int)
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

# ---------------------------------------------------------------------------
# Original public play methods (preserved)
# ---------------------------------------------------------------------------
func play_sonar_ping() -> void:
	if _player_sonar and _stream_sonar_ping:
		_player_sonar.stream = _stream_sonar_ping
		_player_sonar.play()
		# Schedule echo return after 1.5-3 seconds
		var delay: float = randf_range(1.5, 3.0)
		get_tree().create_timer(delay).timeout.connect(play_sonar_return)

func play_contact_new() -> void:
	if _player_contact and _stream_contact_new:
		_player_contact.stream = _stream_contact_new
		_player_contact.play()

func play_weapon_launch() -> void:
	if _player_weapon and _stream_weapon_launch:
		_player_weapon.stream = _stream_weapon_launch
		_player_weapon.play()

func play_explosion() -> void:
	if _player_explosion and _stream_explosion:
		_player_explosion.stream = _stream_explosion
		_player_explosion.play()

func play_torpedo_warning() -> void:
	if _player_warning and _stream_torpedo_warning and not _warning_active:
		_player_warning.stream = _stream_torpedo_warning
		_player_warning.play()
		_warning_active = true

func stop_torpedo_warning() -> void:
	if _player_warning and _warning_active:
		_player_warning.stop()
		_warning_active = false

func play_missile_away() -> void:
	if _player_missile and _stream_missile_away:
		_player_missile.stream = _stream_missile_away
		_player_missile.play()

## Reset all audio state between missions. Call on scenario load/exit.
func reset() -> void:
	stop_ocean_ambience()
	stop_torpedo_warning()
	if _player_sonar: _player_sonar.stop()
	if _player_contact: _player_contact.stop()
	if _player_weapon: _player_weapon.stop()
	if _player_explosion: _player_explosion.stop()
	if _player_missile: _player_missile.stop()
	if _player_radio: _player_radio.stop()
	if _player_sonar_return: _player_sonar_return.stop()
	_radio_timer = 0.0
	_radio_interval = 60.0

	# Phase 9: reset new audio layers
	if _player_hull_creak: _player_hull_creak.stop()
	if _player_machinery: _player_machinery.stop()
	if _player_flow_noise: _player_flow_noise.stop()
	if _player_cavitation: _player_cavitation.stop()
	if _player_biologics: _player_biologics.stop()
	if _player_traffic: _player_traffic.stop()
	if _player_screw_beat: _player_screw_beat.stop()
	if _player_tonal: _player_tonal.stop()
	if _player_transient: _player_transient.stop()
	if _player_tma_tone: _player_tma_tone.stop()
	if _player_classify: _player_classify.stop()
	if _player_torp_run: _player_torp_run.stop()
	if _player_torp_impact: _player_torp_impact.stop()
	if _player_incoming: _player_incoming.stop()
	if _player_ui: _player_ui.stop()
	if _player_splash: _player_splash.stop()
	if _player_emcon: _player_emcon.stop()
	_biologics_timer = 0.0
	_creak_timer = 0.0
	_traffic_timer = 0.0
	_traffic_active = false
	_active_contact_audio.clear()
	_pending_audio_cues.clear()
	_ownship_speed_kts = 0.0
	_time_compression = 1.0
	_current_sea_state = 3
	_warning_active = false

func start_ocean_ambience() -> void:
	if _player_ocean and _stream_ocean_loop:
		_player_ocean.stream = _stream_ocean_loop
		_player_ocean.play()
	# Phase 9: start machinery hum (always running when at sea)
	_start_machinery_hum()

## Stop the ambient ocean loop.
func stop_ocean_ambience() -> void:
	if _player_ocean:
		_player_ocean.stop()
	# Phase 9: stop own-ship layers
	if _player_machinery: _player_machinery.stop()
	if _player_flow_noise: _player_flow_noise.stop()
	if _player_cavitation: _player_cavitation.stop()

## Play the sonar return echo (delayed ping return).
func play_sonar_return() -> void:
	if _player_sonar_return and _stream_sonar_return:
		_player_sonar_return.stream = _stream_sonar_return
		_player_sonar_return.play()

## Play a radio chatter blip.
func play_radio_chatter() -> void:
	if _player_radio and _stream_radio_chatter:
		_player_radio.stream = _stream_radio_chatter
		_player_radio.play()

# ---------------------------------------------------------------------------
# Phase 9: Public API -- Contact Audio (audio-first detection)
# ---------------------------------------------------------------------------

## Play a contact's audio cue. Called BEFORE the display confirms the contact.
## contact_id: the target unit ID
## type: "screw_beats" | "tonal" | "transient"
## bearing: relative bearing from player's heading (for future stereo panning)
func play_contact_audio(contact_id: String, type: String, bearing: float) -> void:
	match type:
		"screw_beats":
			# Determine speed from target data if available
			var speed_factor: float = 0.5  # default medium
			if contact_id in SimulationWorld.units:
				var u: Dictionary = SimulationWorld.units[contact_id]
				var max_spd: float = u.get("max_speed_kts", 30.0)
				speed_factor = clampf(u.get("speed_kts", 10.0) / max_spd, 0.0, 1.0)
			# Bucket to 5 levels (0.0, 0.25, 0.5, 0.75, 1.0) for caching
			var bucket: float = roundf(speed_factor * 4.0) / 4.0
			var stream: AudioStreamWAV
			if bucket in _cached_screw_beats:
				stream = _cached_screw_beats[bucket]
			else:
				stream = _generate_screw_beats(bucket)
				_cached_screw_beats[bucket] = stream
			if _player_screw_beat:
				_player_screw_beat.stream = stream
				_player_screw_beat.play()
		"tonal":
			# Generate class-specific tonal
			var class_hash: int = contact_id.hash() % 1000
			if contact_id in SimulationWorld.units:
				var class_name_str: String = SimulationWorld.units[contact_id].get("platform", {}).get("class_name", "")
				if class_name_str != "":
					class_hash = class_name_str.hash() % 1000
			var stream: AudioStreamWAV
			if class_hash in _cached_machinery_tonals:
				stream = _cached_machinery_tonals[class_hash]
			else:
				stream = _generate_machinery_tonal(class_hash)
				_cached_machinery_tonals[class_hash] = stream
			if _player_tonal:
				_player_tonal.stream = stream
				_player_tonal.play()
		"transient":
			var stream: AudioStreamWAV = _generate_transient()
			if _player_transient:
				_player_transient.stream = stream
				_player_transient.play()
	_active_contact_audio[contact_id] = {"type": type, "bearing": bearing}
	contact_audio_started.emit(contact_id)

## Stop audio for a specific contact (lost contact or destroyed).
func stop_contact_audio(contact_id: String) -> void:
	if contact_id in _active_contact_audio:
		_active_contact_audio.erase(contact_id)
	# Players are shared, so just let current stream finish naturally

## Queue an audio-first detection cue: plays audio now, display confirms later.
## The display_delay_sec is how long BEFORE the bearing line appears on screen.
func queue_audio_first_detection(contact_id: String, bearing: float, display_delay_sec: float = 2.5) -> void:
	# Play screw beats immediately as the faint audio cue
	play_contact_audio(contact_id, "screw_beats", bearing)
	# Queue the pending display confirmation
	_pending_audio_cues.append({
		"contact_id": contact_id,
		"bearing": bearing,
		"remaining": display_delay_sec,
	})

# ---------------------------------------------------------------------------
# Phase 9: Public API -- Sonar System Sounds
# ---------------------------------------------------------------------------

## Play active sonar ping with optional mode.
## mode: "active" (standard) or "sprint_and_drift" (rapid pings)
func play_sonar_ping_ex(unit_id: String, mode: String = "active") -> void:
	# Use the existing sonar ping for now; mode can differentiate later
	play_sonar_ping()

## Play TMA crystallization tone. Quality drives the character.
## quality: 0.0-1.0. Below 0.3: nothing. 0.3-0.9: crystallizing. >0.9: lock.
func play_tma_tone(quality: float) -> void:
	if quality >= 0.9:
		# Solution locked -- satisfying lock tone
		if _player_tma_tone and _stream_tma_lock:
			_player_tma_tone.stream = _stream_tma_lock
			_player_tma_tone.play()
	elif quality >= 0.3:
		# Solution developing -- crystallization tone
		if _player_tma_tone and _stream_tma_crystallize:
			_player_tma_tone.stream = _stream_tma_crystallize
			# Scale volume with quality: louder as it gets closer to lock
			_player_tma_tone.volume_db = -24.0 + (quality - 0.3) * 10.0  # -24 to -18 dB
			_player_tma_tone.play()

## Play classification upgrade tone.
func play_classify_upgrade() -> void:
	if _player_classify and _stream_classify_upgrade:
		_player_classify.stream = _stream_classify_upgrade
		_player_classify.play()

# ---------------------------------------------------------------------------
# Phase 9: Public API -- Weapon Sounds
# ---------------------------------------------------------------------------

## Torpedo launch: mechanical thunk, not explosion. Quiet. Professional.
func play_torpedo_launch() -> void:
	if _player_weapon and _stream_torp_launch_thunk:
		_player_weapon.stream = _stream_torp_launch_thunk
		_player_weapon.play()

## Start torpedo run audio (faint whine for own torpedo, louder for incoming).
## type: "own" | "incoming"
func play_torpedo_run(type: String = "own") -> void:
	if _player_torp_run and _stream_torp_run_whine:
		_player_torp_run.stream = _stream_torp_run_whine
		if type == "incoming":
			_player_torp_run.volume_db = -14.0  # Louder for incoming
		else:
			_player_torp_run.volume_db = -26.0  # Faint for own
		_player_torp_run.play()

## Stop torpedo run audio.
func stop_torpedo_run() -> void:
	if _player_torp_run:
		_player_torp_run.stop()

## Torpedo impact: deep, rolling boom. Distant. Felt through the hull.
func play_torpedo_impact() -> void:
	if _player_torp_impact and _stream_torp_impact:
		_player_torp_impact.stream = _stream_torp_impact
		_player_torp_impact.play()

## Start incoming torpedo warning: escalating rising pitch.
func play_incoming_warning() -> void:
	if _player_incoming and _stream_incoming_warning:
		_player_incoming.stream = _stream_incoming_warning
		_player_incoming.play()

## Stop incoming torpedo warning.
func stop_incoming_warning() -> void:
	if _player_incoming:
		_player_incoming.stop()

# ---------------------------------------------------------------------------
# Phase 9: Public API -- Weapon Sounds (signal-compatible wrappers)
# ---------------------------------------------------------------------------

## Unified weapon sound dispatcher. Called by RenderBridge or SimulationWorld signal handlers.
## type: "torpedo_launch" | "torpedo_run_own" | "torpedo_run_incoming" | "torpedo_impact" |
##       "missile_away" | "incoming_warning"
## bearing: relative bearing (for future stereo panning)
func play_weapon_sound(type: String, bearing: float = 0.0) -> void:
	match type:
		"torpedo_launch":
			play_torpedo_launch()
		"torpedo_run_own":
			play_torpedo_run("own")
		"torpedo_run_incoming":
			play_torpedo_run("incoming")
		"torpedo_impact":
			play_torpedo_impact()
		"missile_away":
			play_missile_away()
		"incoming_warning":
			play_incoming_warning()

# ---------------------------------------------------------------------------
# Phase 9: Public API -- Time Compression Audio
# ---------------------------------------------------------------------------

## Set time compression factor. Adjusts pitch of ambient audio.
## factor: 1.0 = real time, 2.0-60.0 = compressed
func set_time_compression(factor: float) -> void:
	var old_compression: float = _time_compression
	_time_compression = factor

	# Modulate ocean ambience pitch based on compression
	# At 2x-5x: subtle upward shift. Above 5x: noticeable.
	if _player_ocean and _player_ocean.playing:
		# Godot AudioStreamPlayer pitch_scale affects playback speed/pitch
		var pitch: float = 1.0
		if factor > 1.0:
			# Subtle: 1.0 at 1x, up to ~1.15 at 60x
			pitch = 1.0 + log(factor) / log(60.0) * 0.15
		_player_ocean.pitch_scale = pitch

	# Machinery hum pitch shifts too
	if _player_machinery and _player_machinery.playing:
		var pitch: float = 1.0
		if factor > 1.0:
			pitch = 1.0 + log(factor) / log(60.0) * 0.1
		_player_machinery.pitch_scale = pitch

	# When snapping back to 1x from compressed: "surfacing" feeling
	# The pitch correction itself creates this naturally when pitch_scale resets to 1.0

# ---------------------------------------------------------------------------
# Phase 9: Public API -- UI Audio
# ---------------------------------------------------------------------------

## Soft click for unit selection.
func play_ui_click() -> void:
	if _player_ui and _stream_ui_click:
		_player_ui.stream = _stream_ui_click
		_player_ui.play()

## Subtle confirmation tone for waypoint set.
func play_ui_confirm() -> void:
	if _player_ui and _stream_ui_confirm:
		_player_ui.stream = _stream_ui_confirm
		_player_ui.play()

## Splash sound for XBT drop or sonobuoy deployment.
func play_splash() -> void:
	if _player_splash and _stream_splash:
		_player_splash.stream = _stream_splash
		_player_splash.play()

## Sonobuoy splash + initialization chirp.
func play_sonobuoy_drop() -> void:
	play_splash()
	# Chirp after brief delay (sonar initializing)
	if _stream_sonobuoy_chirp:
		get_tree().create_timer(0.3).timeout.connect(_play_sonobuoy_chirp)

func _play_sonobuoy_chirp() -> void:
	if _player_splash and _stream_sonobuoy_chirp:
		_player_splash.stream = _stream_sonobuoy_chirp
		_player_splash.play()

## EMCON state change: brief static burst.
func play_emcon_change() -> void:
	if _player_emcon and _stream_emcon_burst:
		_player_emcon.stream = _stream_emcon_burst
		_player_emcon.play()

# ---------------------------------------------------------------------------
# Phase 9: Public API -- Sea State + Own-Ship State Updates
# ---------------------------------------------------------------------------

## Update sea state for ambient audio scaling.
## Higher sea state = louder ocean noise, more wave modulation.
func update_sea_state(sea_state: int) -> void:
	_current_sea_state = clampi(sea_state, 0, 8)
	# Scale ocean volume: SS0 = very quiet, SS8 = loud
	if _player_ocean:
		# -28 dB at SS0, -12 dB at SS8
		_player_ocean.volume_db = -28.0 + float(_current_sea_state) * 2.0

## Update own-ship speed for flow noise / cavitation.
## Called externally when player's selected unit speed changes.
func update_ownship_speed(speed_kts: float) -> void:
	_ownship_speed_kts = speed_kts

## Update own-ship heading for stereo panning reference.
func update_ownship_heading(heading: float) -> void:
	_ownship_heading = heading

# ---------------------------------------------------------------------------
# Phase 9: Internal -- Own-Ship Audio Modulation
# ---------------------------------------------------------------------------

## Called every frame to adjust own-ship noise layers based on current speed.
func _update_ownship_audio(_delta: float) -> void:
	# Flow noise: scales with speed. Silent at 0 kts, loud at max speed.
	if _player_flow_noise and _stream_flow_noise:
		if _ownship_speed_kts > 0.5:
			if not _player_flow_noise.playing:
				_player_flow_noise.stream = _stream_flow_noise
				_player_flow_noise.play()
			# Volume: -36 dB at 1 kt, -16 dB at 30 kts
			var speed_factor: float = clampf(_ownship_speed_kts / 30.0, 0.0, 1.0)
			_player_flow_noise.volume_db = -36.0 + speed_factor * 20.0
			# Pitch increases slightly with speed
			_player_flow_noise.pitch_scale = 0.8 + speed_factor * 0.4
		else:
			if _player_flow_noise.playing:
				_player_flow_noise.stop()

	# Cavitation: only above CAVITATION_SPEED_KTS (~20 kts)
	if _player_cavitation and _stream_cavitation:
		if _ownship_speed_kts > CAVITATION_SPEED_KTS:
			if not _player_cavitation.playing:
				_player_cavitation.stream = _stream_cavitation
				_player_cavitation.play()
			# Volume ramps up above threshold
			var cav_factor: float = clampf(
				(_ownship_speed_kts - CAVITATION_SPEED_KTS) / 15.0, 0.0, 1.0)
			_player_cavitation.volume_db = -24.0 + cav_factor * 12.0
		else:
			if _player_cavitation.playing:
				_player_cavitation.stop()

	# Machinery hum: pitch increases slightly with speed
	if _player_machinery and _player_machinery.playing:
		var speed_factor: float = clampf(_ownship_speed_kts / 30.0, 0.0, 1.0)
		# Base pitch 1.0, up to 1.08 at max speed
		var base_pitch: float = 1.0 + speed_factor * 0.08
		# Apply time compression on top
		if _time_compression > 1.0:
			base_pitch *= 1.0 + log(_time_compression) / log(60.0) * 0.1
		_player_machinery.pitch_scale = base_pitch

## Start the constant machinery hum layer.
func _start_machinery_hum() -> void:
	if _player_machinery and _stream_machinery_hum:
		_player_machinery.stream = _stream_machinery_hum
		_player_machinery.play()

# ---------------------------------------------------------------------------
# Phase 9: Internal -- Biologic Sounds
# ---------------------------------------------------------------------------

## Play a random biologic sound (whale call or shrimp clicking).
func _play_biologic() -> void:
	if not _player_biologics:
		return
	var roll: float = randf()
	if roll < 0.3:
		# Whale call (30% chance) -- distant and eerie
		if _stream_whale_call:
			_player_biologics.stream = _stream_whale_call
			_player_biologics.volume_db = -28.0 + float(_current_sea_state) * 0.5
			_player_biologics.play()
	else:
		# Shrimp clicking (70% chance) -- faint background crackle
		if _stream_shrimp_click:
			_player_biologics.stream = _stream_shrimp_click
			_player_biologics.volume_db = -30.0
			_player_biologics.play()

# ---------------------------------------------------------------------------
# Phase 9: Internal -- Hull Creaks
# ---------------------------------------------------------------------------

## Play a subtle hull creak. Intermittent, adds submarine atmosphere.
func _play_hull_creak() -> void:
	if _player_hull_creak and _stream_hull_creak:
		_player_hull_creak.stream = _stream_hull_creak
		# Vary volume slightly for each creak
		_player_hull_creak.volume_db = randf_range(-26.0, -18.0)
		# Vary pitch for different creak character
		_player_hull_creak.pitch_scale = randf_range(0.7, 1.3)
		_player_hull_creak.play()

# ---------------------------------------------------------------------------
# Phase 9: Internal -- Distant Traffic
# ---------------------------------------------------------------------------

## Toggle distant surface traffic on/off.
func _toggle_distant_traffic() -> void:
	if _traffic_active:
		if _player_traffic:
			_player_traffic.stop()
		_traffic_active = false
	else:
		if _player_traffic and _stream_distant_traffic:
			_player_traffic.stream = _stream_distant_traffic
			_player_traffic.volume_db = randf_range(-34.0, -28.0)
			_player_traffic.play()
			_traffic_active = true

# ---------------------------------------------------------------------------
# Phase 9: Internal -- Audio-First Detection Processing
# ---------------------------------------------------------------------------

## Process the pending audio cue queue. Counts down timers.
## When a cue expires, the contact should already be on screen (handled by DetectionSystem).
func _process_pending_audio_cues(delta: float) -> void:
	var i: int = _pending_audio_cues.size() - 1
	while i >= 0:
		_pending_audio_cues[i]["remaining"] -= delta
		if _pending_audio_cues[i]["remaining"] <= 0.0:
			_pending_audio_cues.remove_at(i)
		i -= 1
