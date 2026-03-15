extends Node
## AudioManager -- Procedural audio system for THRESHOLD.
## All sounds are generated from PCM data at startup. No external audio files needed.
## Registered as an autoload singleton in project.godot.

# ---------------------------------------------------------------------------
# AudioStreamPlayer nodes
# ---------------------------------------------------------------------------
var _player_sonar: AudioStreamPlayer
var _player_contact: AudioStreamPlayer
var _player_weapon: AudioStreamPlayer
var _player_explosion: AudioStreamPlayer
var _player_warning: AudioStreamPlayer  # looping torpedo warning
var _player_missile: AudioStreamPlayer

# Pregenerated streams
var _stream_sonar_ping: AudioStreamWAV
var _stream_contact_new: AudioStreamWAV
var _stream_weapon_launch: AudioStreamWAV
var _stream_explosion: AudioStreamWAV
var _stream_torpedo_warning: AudioStreamWAV
var _stream_missile_away: AudioStreamWAV

# Torpedo warning state
var _warning_active: bool = false

const SAMPLE_RATE: int = 22050

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
func _ready() -> void:
	_generate_all_streams()
	_create_players()

func _create_players() -> void:
	_player_sonar = _make_player("SonarPlayer", -6.0)
	_player_contact = _make_player("ContactPlayer", -4.0)
	_player_weapon = _make_player("WeaponPlayer", -8.0)
	_player_explosion = _make_player("ExplosionPlayer", -4.0)
	_player_warning = _make_player("WarningPlayer", -5.0)
	_player_missile = _make_player("MissilePlayer", -8.0)

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
	_stream_sonar_ping = _generate_sonar_ping()
	_stream_contact_new = _generate_contact_new()
	_stream_weapon_launch = _generate_weapon_launch()
	_stream_explosion = _generate_explosion()
	_stream_torpedo_warning = _generate_torpedo_warning()
	_stream_missile_away = _generate_missile_away()

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

## Torpedo warning tone: 600 Hz, 0.2s on / 0.3s off, one cycle (0.5s) — looped by player
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

# ---------------------------------------------------------------------------
# Public play methods
# ---------------------------------------------------------------------------
func play_sonar_ping() -> void:
	if _player_sonar and _stream_sonar_ping:
		_player_sonar.stream = _stream_sonar_ping
		_player_sonar.play()

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
