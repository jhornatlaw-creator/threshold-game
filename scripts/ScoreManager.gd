extends Node
## ScoreManager -- Mission scoring autoload singleton.

var mission_score: int = 0
var kills: int = 0
var losses: int = 0
var weapons_fired: int = 0
var total_enemies: int = 0
var is_tracking: bool = false

func start_tracking(enemy_count: int) -> void:
	mission_score = 0
	kills = 0
	losses = 0
	weapons_fired = 0
	total_enemies = enemy_count
	is_tracking = true

func record_kill() -> void:
	if is_tracking:
		kills += 1

func record_loss() -> void:
	if is_tracking:
		losses += 1

func record_weapon_fired() -> void:
	if is_tracking:
		weapons_fired += 1

func compute_score(sim_time: float, time_limit: float, difficulty_mult: float = 1.0) -> Dictionary:
	var kill_bonus: int = kills * 300
	var speed_bonus: int = 0
	if time_limit > 0 and sim_time < time_limit:
		speed_bonus = int(200.0 * (1.0 - sim_time / time_limit))
	var efficiency_floor: int = total_enemies * 2
	var efficiency_penalty: int = maxi(0, (weapons_fired - efficiency_floor) * 20)
	var loss_penalty: int = losses * 400

	var raw_score: int = 1000 + kill_bonus + speed_bonus - efficiency_penalty - loss_penalty
	var score: int = maxi(int(raw_score * difficulty_mult), 0)

	var grade: String = "F"
	if score >= 1620:
		grade = "S"
	elif score >= 1350:
		grade = "A"
	elif score >= 1080:
		grade = "B"
	elif score >= 720:
		grade = "C"
	elif score >= 360:
		grade = "D"

	return {"score": score, "grade": grade, "kills": kills, "losses": losses, "weapons_fired": weapons_fired}

func stop_tracking() -> void:
	is_tracking = false
