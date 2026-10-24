extends CharacterBody3D

# ============================================================
# 敌人 AI —— 同样纯动画驱动
# 行为: 发现玩家 -> 接近 -> 随机选择攻击/格挡
# ============================================================

# ---------- 节点引用 ----------
@onready var animation_tree = $AnimationTree
@onready var state_machine = null
@onready var model_ap: AnimationPlayer = get_node_or_null("Model/AnimationPlayer") as AnimationPlayer
@onready var weapon_area: Area3D = $WeaponArea
@onready var weapon_hitbox: CollisionShape3D = $WeaponArea/WeaponHitbox

# ---------- AI 参数 ----------
@export var move_speed: float = 2.5
@export var max_health: float = 80.0
@export var attack_damage: float = 20.0
@export var detect_range: float = 15.0          # 发现玩家的距离
@export var attack_range: float = 2.5           # 能打到玩家的距离
@export var attack_cooldown: float = 1.2        # AI 攻击间隔比玩家慢
@export var block_chance: float = 0.3           # 格挡概率
@export var strafe_speed: float = 1.5           # 横向移动速度

# ---------- 状态 ----------
var health: float
var target: CharacterBody3D = null
var can_attack: bool = true
var is_blocking: bool = false
var is_attacking: bool = false
var current_action_timer: float = 0.0           # 当前行为计时器
var think_interval: float = 0.8                 # 多久做一次决策
var facing_target: bool = false

enum AIState { IDLE, CHASE, ATTACK, BLOCK, STRAFE }
var state: AIState = AIState.IDLE

# ============================================================
func _ready():
	health = max_health
	weapon_hitbox.disabled = true
	if animation_tree:
		state_machine = animation_tree.get("parameters/playback")
	if model_ap and model_ap.has_animation("idle_empty"):
		model_ap.play("idle_empty")
	# 寻找玩家
	target = get_tree().get_first_node_in_group("player")

# ============================================================
func _physics_process(delta: float):
	if is_dead():
		return
	if not target:
		return

	var dist: float = global_position.distance_to(target.global_position)

	# --- AI 决策 ---
	current_action_timer -= delta
	if current_action_timer <= 0:
		current_action_timer = think_interval
		_make_decision(dist)

	# --- 面向目标 ---
	_look_at_target(delta)

	# --- 执行当前状态 ---
	match state:
		AIState.IDLE:
			velocity = Vector3.ZERO
		AIState.CHASE:
			_chase_target(delta)
		AIState.STRAFE:
			_strafe_around(delta)
		AIState.ATTACK:
			_passive_move(delta)
		AIState.BLOCK:
			velocity.x = move_toward(velocity.x, 0, move_speed)
			velocity.z = move_toward(velocity.z, 0, move_speed)

	# 重力
	if not is_on_floor():
		velocity.y -= 9.8 * delta
	else:
		velocity.y = -0.2

	move_and_slide()

# ============================================================
# AI 决策
# ============================================================
func _make_decision(dist_to_target: float):
	if dist_to_target > detect_range:
		state = AIState.IDLE
		return

	if dist_to_target <= attack_range:
		# 在攻击范围内: 攻击或格挡
		if can_attack and randf() > 0.3:
			state = AIState.ATTACK
			_do_ai_attack()
		elif randf() < block_chance:
			state = AIState.BLOCK
			_set_blocking(true)
		else:
			state = AIState.STRAFE
			_set_blocking(false)
	else:
		# 在视野内但离得远: 追击
		state = AIState.CHASE
		_set_blocking(false)

# ============================================================
# 面向目标
# ============================================================
func _look_at_target(_delta: float):
	if not target:
		return
	var dir: Vector3 = target.global_position - global_position
	dir.y = 0
	if dir.length() > 0.01:
		var target_rotation: float = Vector3.FORWARD.signed_angle_to(dir, Vector3.UP)
		rotation.y = lerp_angle(rotation.y, target_rotation, 0.1)

# ============================================================
# 各状态下移动
# ============================================================
func _chase_target(_delta: float):
	var dir: Vector3 = (target.global_position - global_position).normalized()
	dir.y = 0
	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed

func _strafe_around(_delta: float):
	# 绕圈移动
	var to_target: Vector3 = (target.global_position - global_position).normalized()
	to_target.y = 0
	var strafe_dir: Vector3 = to_target.rotated(Vector3.UP, PI * 0.25 * (1 if randi() % 2 == 0 else -1))
	velocity.x = strafe_dir.x * strafe_speed
	velocity.z = strafe_dir.z * strafe_speed

func _passive_move(_delta: float):
	# 攻击时缓慢靠近
	var dir: Vector3 = (target.global_position - global_position).normalized()
	dir.y = 0
	velocity.x = dir.x * move_speed * 0.3
	velocity.z = dir.z * move_speed * 0.3

# ============================================================
# AI 攻击
# ============================================================
func _do_ai_attack():
	if not can_attack:
		return
	can_attack = false
	is_attacking = true

	var dirs: Array = ["left", "right", "up", "thrust"]
	var choice: String = dirs[randi() % dirs.size()]

	if animation_tree:
		animation_tree.set("parameters/conditions/attack_" + choice, true)

	# 冷却
	await get_tree().create_timer(attack_cooldown).timeout
	can_attack = true

# ============================================================
# 格挡
# ============================================================
func _set_blocking(active: bool):
	is_blocking = active
	if animation_tree:
		animation_tree.set("parameters/conditions/is_blocking", active)

# ============================================================
# 动画回调
# ============================================================
func _enable_weapon():
	weapon_hitbox.disabled = false

func _disable_weapon():
	weapon_hitbox.disabled = true

func _attack_finished():
	is_attacking = false
	if animation_tree:
		for d in ["left", "right", "up", "thrust"]:
			animation_tree.set("parameters/conditions/attack_" + d, false)

# ============================================================
# 伤害
# ============================================================
func take_damage(amount: float, attack_dir: String = ""):
	if is_blocking:
		health -= amount * 0.2
		print("敌人格挡了 ", amount * 0.2)
		return
	health -= amount
	if animation_tree and state_machine:
		state_machine.travel("hit")
	if health <= 0:
		_die()

func _die():
	if animation_tree and state_machine:
		state_machine.travel("death")
	set_physics_process(false)

func is_dead() -> bool:
	return health <= 0
