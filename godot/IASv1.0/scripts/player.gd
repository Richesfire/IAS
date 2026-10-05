extends CharacterBody3D

# ============================================================
# 玩家控制器 —— 上半身(战斗) / 下半身(移动) 分层状态机
#   move_sm:  走路/待机的全身基底（下半身用它持续走路）
#   attack_sm: 攻击/格挡/受击/死亡（只覆盖上半身，通过混合权重控制）
# ============================================================

# ---------- 节点引用 ----------
@onready var animation_tree = $AnimationTree
@onready var move_sm = null
@onready var attack_sm = null

# 攻击时上半身混合权重（0=全身走路，1=上半身全部切换为攻击动作）
var combat_upper_blend: float = 0.0
# 攻击俯仰：平滑跟随镜头俯仰，避免蓄力/攻击/收招瞬间脊柱俯仰跳变
var aim_pitch: float = 0.0
# 举剑/收剑时的俯仰过渡（分别与举剑、收剑动画时长同步）
var raise_pitch_from: float = 0.0
var raise_pitch_t: float = 0.0
var raise_pitch_dur: float = 0.001
var recover_pitch_from: float = 0.0
var recover_pitch_t: float = 0.0
var recover_pitch_dur: float = 0.001
# body_blend(Blend2) 节点：用于动态开关上半身骨骼遮罩
var blend_node = null
# 当前是否有移动输入（决定下半身播移动动画还是举剑动画）
var is_moving: bool = false
@export var camera_pivot: Node3D
@export var camera_3d: Camera3D
@export var cam_default_marker: Marker3D
@export var cam_hold_marker: Marker3D
@export var cam_ride_marker: Marker3D   # 骑乘时的机位（在 3D 视图里拖它即可调整）
@onready var weapon_area: Area3D = $CharacterRig/character/Armature/Skeleton3D/WeaponSocket/Weapon/WeaponArea
@onready var weapon_hitbox: CollisionShape3D = $CharacterRig/character/Armature/Skeleton3D/WeaponSocket/Weapon/WeaponArea/WeaponHitbox
@onready var skeleton: Skeleton3D = $CharacterRig/character/Armature/Skeleton3D

# ---------- 移动参数 ----------
@export var walk_speed: float = 3.0
@export var run_speed: float = 6.0
@export var jump_velocity: float = 4.29  # 起跳初速度（匹配 jump 动画：1帧起跳→22帧落地，滞空约0.875s）
@export var jump_interval: float = 1.5  # 两次跳跃之间的间隔
@export var body_rotation_speed: float = 3
@export var head_bone_name: String = "Head"
@export var neck_bone_name: String = "Neck"
@export var spine_bone_name: String = "Spine"
@export var chest_bone_name: String = "Chest"
@export var upper_chest_bone_name: String = "UpperChest"

# ---------- 摄像机 ----------
@export var cam_transition_speed: float = 6.0
const CAM_PITCH_MIN: float = -1.6   # 镜头俯仰下限（低头）
const CAM_PITCH_MAX: float = 0.8     # 镜头俯仰上限（抬头）—— 攻击俯仰的限幅与之同步

# ---------- 战斗参数 ----------
@export var max_health: float = 100.0
@export var attack_damage: float = 25.0
@export var attack_cooldown: float = 0.1

# ---------- 运行时状态 ----------
var health: float
var can_attack: bool = true
var attack_gen: int = 0   # 挥砍代次：格挡打断挥砍时 +1，令旧挥砍协程彻底退出（只看 is_blocking 会漏掉「格挡已松开」的时机）
var is_charging: bool = false
var is_blocking: bool = false
var is_attacking: bool = false
var current_attack: String = ""
var block_dir: String = ""
var attack_buffered: bool = false   # 挥砍/冷却期间按左键 → 缓冲下一刀（举刀）
var lmb_held: bool = false          # 左键是否按住（缓冲刀要先举刀，松手再挥刀）
var is_recovering: bool = false     # 正在播放"收招"动画（保持上身权重=1，收招才显示）
var recover_gen: int = 0               # 收招「代次」：打断/接管收招时 +1，旧收招协程据此提前退出（避免 bool 残留）
var is_block_recovering: bool = false  # 正在播格挡收招（松开右键后）——此期间按左键可立刻打断接举剑
var mouse_move_delta: Vector2 = Vector2.ZERO
var last_mouse_relative: Vector2 = Vector2.ZERO  # 最近一次鼠标移动（原始值），用于格挡方向判定，避免用到攻击残留
var was_moving: bool = false                     # 上一帧是否在移动（用于捕获「停止瞬间」的朝向）
var was_in_combat: bool = false                  # 上一帧是否在攻击/格挡（用于捕获「攻击结束瞬间」的朝向）
var attack_started_moving: bool = false          # 本次攻击是「移动中起手」的 → 全程下半身走移动动画
var jump_vel: Vector3 = Vector3.ZERO             # 起跳那一刻的水平速度（空中保持惯性）
var jump_cool: float = 0.0                       # 跳跃冷却（两次跳跃间隔）
var idle_face_yaw: float = 0.0                   # 停止瞬间上身朝向；停止后下身朝它平滑回正
var aim_yaw: float = 0.0                         # 上身瞄准 yaw（平滑后的，起停不跳变）
var attack_dir: AttackDir = AttackDir.THRUST  # 保留的上次攻击方向（默认「下」/前刺）；鼠标不动就保持不变
var block_dir_keep: String = "down"           # 保留的上次格挡方向（默认「下」）；鼠标不动就保持不变

enum AttackDir { LEFT, RIGHT, UP, THRUST }

const ATTACK_DIR_NAMES = {
	AttackDir.LEFT: "left",
	AttackDir.RIGHT: "right",
	AttackDir.UP: "up",
	AttackDir.THRUST: "thrust",
}

# ---------- 摄像机平滑切换 ----------
var cam_target: Vector3 = Vector3.ZERO
var is_holding_cam: bool = false
var cam_lock: bool = false   # 按住 ~ 或松开后镜头回归期间：身体/上身不跟随镜头
var cam_returning: bool = false   # 松开 ~ 后镜头角度/位置正在回归按住前的状态
var saved_cam_yaw: float = 0.0    # 按下 ~ 时的镜头 yaw（松开后回到这里）
var saved_cam_pitch: float = 0.0  # 按下 ~ 时的镜头 pitch
var saved_body_pitch: float = 0.0 # 按下 ~ 时的身体俯仰（按住期间锁定）

var cam_yaw: float = 0.0
var cam_pitch: float = 0.0
var head_bone_idx: int = -1
var neck_bone_idx: int = -1
var spine_bone_idx: int = -1
var chest_bone_idx: int = -1
var upper_chest_bone_idx: int = -1
var body_target_yaw: float = 0.0
var frozen_move_yaw: float = 0.0
var head_world_yaw: float = 0.0
var is_walking: bool = false
var default_fov: float = 75.0
var last_anim_state: String = ""
var initialized: bool = false
var has_weapon: bool = true

# ---------- 骑乘 ----------
var riding: bool = false            # 是否正在骑乘
var mount_horse: Node3D = null      # 当前骑的马（group "horse"）
var is_mounting: bool = false       # 正播上马动画（全身）
var is_dismounting: bool = false    # 正播下马动画（倒放，此期间人物不受控）
var _saved_layer: int = 1           # 骑乘时保存玩家的碰撞层/掩码，下马还原
var _saved_mask: int = 1
@export var ride_offset: Vector3 = Vector3.ZERO   # 骑乘落点相对鞍座的偏移（X左右 / Y高低 / Z前后，随马朝向旋转）
@export var ride_follow_min: float = 0.1          # 末端跟随权重（离 Hips 最远骨骼只跟这么多）
@export var ride_falloff_dist: float = 1.5        # 从 Hips 到"只剩 ride_follow_min"的距离（线性）
@export var ride_hips_bone: String = "Hips"       # 跟随最快的根骨骼
@export var ride_damp_speed: float = 12.0         # 阻尼速度（越大跟得越紧）
var _ride_anchor: Transform3D = Transform3D()     # 当前鞍座（骨骼锚点）世界变换
var _ride_base: Transform3D = Transform3D()       # 上马瞬间人物根变换（骑乘时根保持不动）
var _ride_base_set: bool = false
var _ride_state: Array = []                       # 每根骨骼阻尼后的全局变换
var _ride_dbg: float = 0.0

# ============================================================
func _ready():
	health = max_health
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if animation_tree:
		move_sm = animation_tree.get("parameters/move_state/playback")
		attack_sm = animation_tree.get("parameters/attack_state/playback")
		# 用 tree_root 可靠获取 body_blend(Blend2) 节点（parameters/body_blend 方式可能返回 null）
		var tree = animation_tree.tree_root
		if tree is AnimationNodeBlendTree:
			blend_node = tree.get_node("body_blend")
			# 运行时给 move 状态机加上马/下马状态，并生成倒放的 mount_rev（不改 .tscn）
			_ensure_mount_states(tree.get_node("move_state"))
		print("[player] body_blend 节点 = ", blend_node)

	cam_target = cam_default_marker.position
	camera_3d.position = cam_target

	head_bone_idx = skeleton.find_bone(head_bone_name)
	neck_bone_idx = skeleton.find_bone(neck_bone_name)
	spine_bone_idx = skeleton.find_bone(spine_bone_name)
	chest_bone_idx = skeleton.find_bone(chest_bone_name)
	upper_chest_bone_idx = skeleton.find_bone(upper_chest_bone_name)

# ============================================================
func _process(delta: float):
	# 延迟到第一帧再初始化状态机（_ready 时动画树还没准备好）
	if not initialized:
		initialized = true
		animation_tree.set_active(true)
		if move_sm:
			move_sm.start(&"idle_weapon")
			last_anim_state = "idle_weapon"
		if attack_sm:
			attack_sm.start(&"idle_weapon")
	# 上马/下马动画：全身交给 move 层（关遮罩、上身混合归零），播完自动恢复
	if is_mounting or is_dismounting:
		combat_upper_blend = 0.0
		animation_tree.set("parameters/body_blend/blend_amount", 0.0)
		if blend_node is AnimationNodeBlend2:
			blend_node.filter_enabled = false
		skeleton.clear_bones_global_pose_override()   # 上马/下马期间不写上半身覆盖，避免和上马动画抢姿势
		return
	# 平滑切换上半身加权：战斗中（蓄力/攻击/格挡）上半身切到攻击动作，否则回走路（腾空不算战斗 → 上身继续用跳跃动画）
	var combat_active: bool = is_charging or is_attacking or is_blocking or is_recovering or health <= 0
	combat_upper_blend = move_toward(combat_upper_blend, 1.0 if combat_active else 0.0, 8.0 * delta)
	animation_tree.set("parameters/body_blend/blend_amount", combat_upper_blend)
	# 战斗中：移动时只让攻击覆盖上半身(下半身走移动动画)；站着不动时关闭遮罩，全身播攻击。
	# 「移动中起的攻击」全程保持遮罩（下半身一直用移动动画），避免攻击结束前停下导致脚跳。
	if not combat_active:
		attack_started_moving = false
	var mask_off: bool = combat_active and not is_moving and not attack_started_moving
	if blend_node is AnimationNodeBlend2:
		blend_node.filter_enabled = not mask_off
	# 俯仰过渡：收剑 = 与收剑动画同步归零；举剑 = 跟随镜头；挥砍跟随镜头；上劈(up)取消俯仰变化；其余归零
	var cancel_pitch: bool = is_blocking or (current_attack == "up" and (is_charging or is_attacking or is_recovering))
	var pitch_target: float = 0.0 if cancel_pitch else cam_pitch
	if is_recovering:
		recover_pitch_t += delta
		aim_pitch = lerpf(recover_pitch_from, 0.0, clampf(recover_pitch_t / recover_pitch_dur, 0.0, 1.0))
	elif is_charging:
		raise_pitch_t += delta
		aim_pitch = lerpf(raise_pitch_from, pitch_target, clampf(raise_pitch_t / raise_pitch_dur, 0.0, 1.0))
	else:
		aim_pitch = lerpf(aim_pitch, pitch_target if combat_active else 0.0, 12.0 * delta)
	# 按住 ~ 时锁定身体俯仰（镜头俯仰不受影响，仍可上下看）
	if is_holding_cam:
		aim_pitch = saved_body_pitch
	_update_head_rotation(delta)

# ============================================================
# 上下半身分层的骨骼遮罩已配在 player.tscn 的 body_blend(Blend2) 节点上（见编辑筛选轨道）
# ============================================================
func _input(event: InputEvent):
	# 下马动画期间人物不受控
	if is_dismounting:
		return
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# 上/下马：按交互键(F)
	if event.is_action_pressed("interact") and not event.echo:
		if is_mounting or is_dismounting:
			pass                       # 动画播放中不响应
		elif riding:
			_dismount()
		else:
			_try_mount()

	if event is InputEventKey and event.keycode == KEY_CAPSLOCK and event.pressed:
		is_walking = not is_walking
		print("移动模式: ", "走路" if is_walking else "跑步")

	if event is InputEventKey and event.keycode == KEY_QUOTELEFT:
		if event.pressed and not event.echo:
			is_holding_cam = true
			frozen_move_yaw = head_world_yaw
			saved_cam_yaw = cam_yaw       # 记住按 ~ 前的镜头角度，松开后回归
			saved_cam_pitch = cam_pitch
			saved_body_pitch = aim_pitch   # 锁定身体俯仰在当前值
			cam_returning = false
		elif not event.pressed:
			is_holding_cam = false
			cam_returning = true                              # 松开后开始回归
			camera_3d.position = cam_hold_marker.position     # ① 机位秒切到「悬停机位」
			# 视角也秒切回按住前，这样前进方向不变（往北走还是往北走）
			cam_yaw = saved_cam_yaw
			cam_pitch = saved_cam_pitch
			camera_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
		if is_holding_cam:
			cam_target = cam_hold_marker.position
		else:
			cam_target = cam_default_marker.position

	if event is InputEventMouseMotion:
		cam_yaw += -event.relative.x * 0.002
		cam_pitch += -event.relative.y * 0.002
		cam_pitch = clamp(cam_pitch, CAM_PITCH_MIN, CAM_PITCH_MAX)
		camera_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)

		# 攻击方向判定用的位移记录：对每帧鼠标位移做指数平滑（0.8 = 跟手程度，越大越跟手、越小越"重"）
		# 注意这是持续累积的平滑值（不限定时间窗），按下左键时读它来定方向
		mouse_move_delta = mouse_move_delta.lerp(event.relative, 0.8)
		last_mouse_relative = event.relative   # 原始单帧值：格挡方向用它，避免用到攻击方向的残留

	# 骑乘时鼠标只用来转镜头，不触发攻击/格挡
	if riding:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			lmb_held = true
			# 格挡优先：按住右键时左键完全无效（必须先松开右键才能攻击）
			if is_blocking:
				pass
			# 收剑/格挡收招期间按下左键 → 立刻打断收招、接举剑
			elif is_recovering:
				recover_gen += 1
				is_recovering = false
				is_block_recovering = false
				attack_buffered = false
				can_attack = true
				_begin_charge()
			# 挥砍中按左键 → 缓冲下一刀
			elif is_attacking:
				attack_buffered = true
			elif not is_charging:
				_begin_charge()
		else:
			lmb_held = false
			if is_charging:
				_release_attack()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_set_blocking(event.pressed)

# ============================================================
# 骑乘
# ============================================================
func _try_mount():
	var best: Node3D = null
	var best_d: float = 3.5
	for h in get_tree().get_nodes_in_group("horse"):
		var d: float = global_position.distance_to((h as Node3D).global_position)
		if d < best_d:
			best_d = d
			best = h as Node3D
	if best:
		_mount(best)

func _mount(h: Node3D):
	mount_horse = h
	riding = true                       # 上马动画期间即可控制马
	is_mounting = true
	h.set("has_rider", true)
	h.set("rider", self)
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if weapon_area:
		weapon_area.monitoring = false
	# 关掉玩家碰撞：否则玩家贴在马身上会互相顶，马的 CharacterBody 每帧被弹开 → 一上马就飘走
	_saved_layer = collision_layer
	_saved_mask = collision_mask
	collision_layer = 0
	collision_mask = 0
	_update_riding()
	if move_sm:
		move_sm.start(&"mount")          # 全身播放上马动画
	await get_tree().create_timer(_get_anim_length("mount", 1.0)).timeout
	is_mounting = false                  # 播完：下半身保持末帧，上半身恢复常规

func _dismount():
	if mount_horse == null:
		return
	is_dismounting = true
	if move_sm:
		move_sm.start(&"mount_rev")      # 倒放下马动画
	await get_tree().create_timer(_get_anim_length("mount", 1.0)).timeout
	mount_horse.set("has_rider", false)
	mount_horse.set("rider", null)
	# 下到马的左侧
	global_position = mount_horse.global_position + mount_horse.global_transform.basis.x * -1.4
	velocity = Vector3.ZERO
	mount_horse = null
	riding = false
	collision_layer = _saved_layer
	collision_mask = _saved_mask
	if weapon_area:
		weapon_area.monitoring = true
	if cam_default_marker:
		cam_target = cam_default_marker.position   # 下马回到默认机位
	_ride_base_set = false
	_ride_state.clear()
	if skeleton:
		skeleton.clear_bones_global_pose_override()
	is_dismounting = false

func _update_riding():
	if mount_horse == null:
		riding = false
		return
	var anchor: Transform3D = mount_horse.global_transform
	if mount_horse.has_method("rider_anchor"):
		anchor = mount_horse.rider_anchor()
	_ride_anchor = anchor * Transform3D(Basis(), ride_offset)
	if not _ride_base_set:
		_ride_base = global_transform       # 记住上马瞬间的人物根变换（供衰减混合用）
		_ride_base_set = true
	global_transform = _ride_anchor          # 刚性贴合骨骼（位置+朝向，含起伏/倾斜）
	if cam_ride_marker:
		cam_target = cam_ride_marker.position
	velocity = Vector3.ZERO

func _apply_ride_follow(delta: float) -> void:
	# 只阻尼旋转：每根骨骼的旋转朝「动画旋转 × 马的旋转增量」收敛；近 Hips 快、末端慢。
	# 位置不动（根节点已把马位移 100% 带上），所以不会分离。
	if skeleton == null:
		return
	skeleton.clear_bones_global_pose_override()   # 先清掉上一帧的覆盖，读到的才是干净动画姿态（否则旋转会累加自转）
	var n: int = skeleton.get_bone_count()
	if _ride_state.size() != n:
		_ride_state.resize(n)
		for i in n:
			_ride_state[i] = skeleton.get_bone_global_pose(i).basis.get_rotation_quaternion()
	var hips: int = skeleton.find_bone(ride_hips_bone)
	if hips < 0:
		hips = 0
	var hips_rest: Vector3 = skeleton.get_bone_global_rest(hips).origin
	var delta_q: Quaternion = _ride_anchor.basis.get_rotation_quaternion() * _ride_base.basis.get_rotation_quaternion().inverse()
	for i in n:
		var rest: Transform3D = skeleton.get_bone_global_rest(i)
		var d: float = rest.origin.distance_to(hips_rest)
		var rate: float = lerpf(1.0, ride_follow_min, clampf(d / maxf(ride_falloff_dist, 0.001), 0.0, 1.0))
		var cur: Transform3D = skeleton.get_bone_global_pose(i)
		var target_q: Quaternion = (delta_q * cur.basis.get_rotation_quaternion()).normalized()
		_ride_state[i] = (_ride_state[i] as Quaternion).slerp(target_q, clampf(rate * ride_damp_speed * delta, 0.0, 1.0))
		skeleton.set_bone_global_pose_override(i, Transform3D(Basis(_ride_state[i]), cur.origin), 1.0, true)

func _ensure_mount_states(machine) -> void:
	# 运行时给 move 状态机加上马/下马状态；并生成倒放的 mount_rev（不改 .tscn）
	var ap: AnimationPlayer = null
	if animation_tree.anim_player != NodePath(""):
		ap = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
	if ap and ap.has_animation("mount"):
		ap.get_animation("mount").loop_mode = Animation.LOOP_NONE
		if not ap.has_animation("mount_rev"):
			var libs := ap.get_animation_library_list()
			if libs.size() > 0:
				ap.get_animation_library(libs[0]).add_animation("mount_rev", _make_reversed(ap.get_animation("mount")))
	if machine == null:
		return
	for s in [["mount", "mount"], ["mount_rev", "mount_rev"]]:
		if not machine.has_node(s[0]):
			var n := AnimationNodeAnimation.new()
			n.animation = StringName(s[1])
			machine.add_node(s[0], n)

func _make_reversed(src: Animation) -> Animation:
	var rev := Animation.new()
	rev.length = src.length
	rev.loop_mode = Animation.LOOP_NONE
	for t in src.get_track_count():
		var idx: int = rev.add_track(src.track_get_type(t))
		rev.track_set_path(idx, src.track_get_path(t))
		var kc: int = src.track_get_key_count(t)
		for k in kc:
			var sk: int = kc - 1 - k                      # 倒序取源键 → 插入时间递增，避免乱序
			var nt: float = src.length - src.track_get_key_time(t, sk)
			rev.track_insert_key(idx, nt, src.track_get_key_value(t, sk))
	return rev

# ============================================================
func _physics_process(delta: float):
	if riding:
		_update_riding()
		_update_camera_follow()
		_update_camera(delta)
		return
	_update_movement(delta)
	_update_body_facing(delta)
	move_and_slide()
	# 跟随放在移动之后，避免镜头落后一帧（表现为朝移动反方向偏）
	_update_camera_follow()
	_update_camera(delta)

# ============================================================
func _update_movement(delta: float):
	var input: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	var move_yaw: float = frozen_move_yaw if cam_lock else head_world_yaw
	var cam_fwd: Vector3 = Vector3(sin(move_yaw), 0, cos(move_yaw))
	var cam_rgt: Vector3 = Vector3(cos(move_yaw), 0, -sin(move_yaw))
	var world_dir: Vector3 = (cam_fwd * input.y + cam_rgt * input.x).normalized()

	is_moving = input.length() > 0.1

	# 非走路模式（未开 CapsLock）下所有移动都跑，含后退（速度与动画都用跑）
	var is_running: bool = not is_walking
	var speed: float = run_speed if is_running else walk_speed

	velocity.x = world_dir.x * speed
	velocity.z = world_dir.z * speed

	jump_cool = maxf(jump_cool - delta, 0.0)
	if is_on_floor():
		if Input.is_action_just_pressed("jump") and jump_cool <= 0.0:
			velocity.y = jump_velocity
			jump_cool = jump_interval
			jump_vel = Vector3(velocity.x, 0.0, velocity.z)   # 记住起跳那一刻的水平速度（惯性）
		elif velocity.y <= 0.0:
			velocity.y = -0.2
	else:
		velocity.y -= 9.8 * delta
		# 空中：水平方向只按起跳那一刻，忽略腾空时的输入（有惯性、方向不随空中按键变）
		velocity.x = jump_vel.x
		velocity.z = jump_vel.z

	# 身体目标朝向：
	#   左右举剑的「后退」（右举剑按左 / 左举剑按右）→ 身体朝攻击方向，这样后退跑/走时腿才朝移动方向迈
	#   其余 → 根部照常朝向移动方向（腿跟着转）；不动时朝镜头
	var attack_facing: bool = (is_charging or is_attacking or is_recovering) and (current_attack == "left" or current_attack == "right")
	var ref_fwd: Vector3 = Vector3.ZERO
	var back_moving: bool = false
	if attack_facing:
		ref_fwd = cam_rgt if current_attack == "right" else -cam_rgt
		# 后退判定收窄：只认「正对攻击反方向」（正西）那一段，正北→正西（不含正西）都算前进
		back_moving = world_dir.length() > 0.1 and ref_fwd.dot(world_dir.normalized()) < -0.9

	# 停止瞬间：记住当时上身朝向，之后下身朝它平滑回正、上身保持不变
	if was_moving and not is_moving:
		idle_face_yaw = aim_yaw
	was_moving = is_moving

	var in_combat: bool = is_charging or is_attacking or is_recovering or is_blocking
	# 攻击/格挡结束瞬间：以当前实际朝向为准，之后不回正到攻击前
	if was_in_combat and not in_combat:
		idle_face_yaw = rotation.y
		print("[atk_end] rot=", rad_to_deg(rotation.y), " face=", rad_to_deg(idle_face_yaw), " aim=", rad_to_deg(aim_yaw), " move=", rad_to_deg(move_yaw), " tgt=", rad_to_deg(body_target_yaw), " moving=", is_moving)
	was_in_combat = in_combat

	if not is_on_floor():
		body_target_yaw = move_yaw   # 空中：下身朝镜头（移动键不控制转身）
	elif back_moving:
		body_target_yaw = atan2(-ref_fwd.x, -ref_fwd.z)
	elif world_dir.length() > 0.1:
		var body_dir: Vector3
		if input.y == 0:
			body_dir = -cam_rgt * input.x
		else:
			body_dir = world_dir if input.y >= 0 else -world_dir
		body_target_yaw = atan2(body_dir.x, body_dir.z)
	elif in_combat:
		# 攻击/格挡中不移动：下身转向瞄准方向（跟着攻击方向转过来）；转向平滑由 _update_body_facing 处理
		body_target_yaw = move_yaw
		idle_face_yaw = move_yaw   # 攻击结束后保持这个朝向，不回正到攻击前
	else:
		# 不移动：下身朝「停止瞬间的朝向」回正（平滑由 _update_body_facing 处理）
		body_target_yaw = idle_face_yaw

	# 基底状态机始终驱动走路（战斗时上半身被攻击层覆盖，下半身仍走路）
	if animation_tree and move_sm:
		var suffix: String = "weapon" if has_weapon else "empty"
		var move_state: String
		var back_state: String = ("run_back_" if not is_walking else "walk_back_") + suffix
		if not is_on_floor() or velocity.y > 0.0:
			move_state = "jump"   # 离地或在上升（起跳当帧）就播跳跃
		elif input.length() < 0.1:
			move_state = "idle_" + suffix
		elif back_moving:
			move_state = back_state
		elif attack_facing:
			move_state = ("run_forward_" if is_running else "walk_forward_") + suffix
		elif input.y > 0.1:
			# 后退：默认跑步后退（走路模式才用走路后退）
			move_state = back_state
		else:
			move_state = ("run_forward_" if is_running else "walk_forward_") + suffix
		if last_anim_state != move_state:
			move_sm.travel(StringName(move_state))
			last_anim_state = move_state

# ============================================================
func _update_camera(delta: float):
	if cam_returning:
		# ② 只回归机位：从悬停机位平滑回到默认机位（角度不锁，玩家全程可自由控制）
		camera_3d.position = camera_3d.position.lerp(cam_default_marker.position, cam_transition_speed * delta)
		if camera_3d.position.distance_to(cam_default_marker.position) < 0.005:
			camera_3d.position = cam_default_marker.position
			cam_returning = false
	else:
		camera_3d.position = camera_3d.position.lerp(cam_target, cam_transition_speed * delta)
	# ③ 回归那段不锁身体；只有按住 ~ 时才锁
	cam_lock = is_holding_cam
	var target_fov: float = 25.0 if Input.is_key_pressed(KEY_SHIFT) else default_fov
	camera_3d.fov = lerpf(camera_3d.fov, target_fov, 10.0 * delta)

func _update_camera_follow():
	var base: Vector3 = _ride_anchor.origin if riding else global_position
	camera_pivot.global_position = base + Vector3(0, 1.6, 0)

func _update_body_facing(delta: float):
	var angle_diff: float = abs(wrapf(cam_yaw - rotation.y, -PI, PI))
	var t: float = clampf(angle_diff / deg_to_rad(30.0), 0.0, 1.0)
	var speed: float = lerpf(body_rotation_speed, 30.0, t)
	rotation.y = lerp_angle(rotation.y, body_target_yaw, speed * delta)

func _update_head_rotation(delta: float):
	head_world_yaw = cam_yaw
	if spine_bone_idx < 0:
		return

	# 死亡：上半身完全交给动画（优先于瞄准，避免俯仰残留盖住死亡姿势）
	if health <= 0:
		if not riding:
			skeleton.clear_bones_global_pose_override()
		return

	var aiming: bool = is_charging or is_attacking or is_blocking or is_recovering
	# 瞄准 yaw 每帧都更新（战斗时也跟镜头），否则攻击结束瞬间 aim_yaw 还是旧值会把上身拽回去
	var aim_target: float = rotation.y if riding else (frozen_move_yaw if cam_lock else (cam_yaw if (is_moving or aiming) else idle_face_yaw))
	if is_moving or aiming or cam_lock or riding:
		aim_yaw = aim_target   # 骑乘：只跟马身朝向（镜头不影响人物转向）；其余同原
	else:
		aim_yaw = lerp_angle(aim_yaw, aim_target, 10.0 * delta)   # 停下回正：平滑

	# 蓄力/攻击/格挡/收招，或俯仰还没归零：上身左右转由代码控制（朝镜头瞄准）+ 平滑俯仰弯曲
	if aiming or absf(aim_pitch) > 0.001:
		_apply_aim_bend(aim_pitch)
		return

	# 非战斗：上身朝瞄准方向（移动时=镜头；停止后=停止瞬间的朝向）
	if not riding:
		skeleton.clear_bones_global_pose_override()   # 骑乘时保留骑乘覆盖，瞄准叠加在其上
	var upper_yaw: float = aim_yaw
	# 归一化到最短角，避免 cam_yaw 无界累加导致差值绕多圈、腰部扭成麻花
	var delta_yaw: float = wrapf(upper_yaw - rotation.y, -PI, PI)
	var chain: Array = [spine_bone_idx, chest_bone_idx]
	var poses: Array = []
	for bone in chain:
		poses.append(skeleton.get_bone_global_pose(bone) if bone >= 0 else Transform3D())
	var n: int = chain.size()
	for i in n:
		var bone: int = chain[i]
		if bone < 0:
			continue
		var cur: Transform3D = poses[i]
		var frac: float = float(i + 1) / float(n)
		var q: Quaternion = Quaternion(Vector3.UP, delta_yaw * frac)
		# 世界空间左乘：在当前动画朝向上叠加 yaw，动画姿势保留
		skeleton.set_bone_global_pose_override(bone, Transform3D(Basis(q) * cur.basis, cur.origin), 1.0, true)

# ============================================================
# 用镜头俯仰弯曲上身实现攻击俯仰（下半身不动），头/颈反向抵消保持平视
# ============================================================
func _apply_aim_bend(aim: float):
	if not riding:
		skeleton.clear_bones_global_pose_override()
	# 上身朝向瞄准方向：yaw 用「世界空间左乘」（不依赖骨骼局部轴），避免按 A/D 时上身左右晃动
	var upper_yaw: float = frozen_move_yaw if cam_lock else cam_yaw
	# 同样归一化到最短角，避免腰部扭成麻花
	var yaw_q: Quaternion = Quaternion(Vector3.UP, wrapf(upper_yaw - rotation.y, -PI, PI))
	if spine_bone_idx >= 0:
		var cur: Transform3D = skeleton.get_bone_global_pose(spine_bone_idx)
		var rest: Transform3D = skeleton.get_bone_global_rest(spine_bone_idx)
		# 俯仰轴取「举剑(转向瞄准)后的静止朝向」的侧轴并右转90°：各攻击方向一致，不随具体动画偏
		var aim_frame: Basis = Basis(yaw_q) * rest.basis
		var lateral: Vector3 = aim_frame.x.normalized().rotated(aim_frame.y.normalized(), -PI * 0.5)
		var pitch_q: Quaternion = Quaternion(lateral, clampf(-aim, -CAM_PITCH_MAX, -CAM_PITCH_MIN))
		# 实际姿态仍用当前动画姿势，再叠世界空间俯仰
		var aimed: Basis = Basis(yaw_q) * cur.basis
		skeleton.set_bone_global_pose_override(spine_bone_idx, Transform3D(Basis(pitch_q) * aimed, cur.origin), 1.0, true)

# ============================================================
# 战斗逻辑
# ============================================================
func _begin_charge():
	if is_attacking:
		return
	is_charging = true
	can_attack = true                   # 举剑了就能挥：清掉上一次的冷却/锁定（否则松手会卡在举剑）
	attack_started_moving = is_moving   # 记下起手时是否在移动（决定下半身是否用攻击动画）
	# 攻击方向：鼠标动过（平滑位移长度 > 2px）才更新方向；没动就保持上一次（初始默认「下」/前刺）
	if mouse_move_delta.length() > 2.0:
		attack_dir = _judge_mouse_dir(mouse_move_delta)
	current_attack = ATTACK_DIR_NAMES[attack_dir]
	# 举剑俯仰过渡：与举剑动画时长同步
	raise_pitch_from = aim_pitch
	raise_pitch_dur = maxf(_get_anim_length("attack_" + current_attack + "_raise", 0.3), 0.001)
	raise_pitch_t = 0.0
	if attack_sm:
		var target := StringName("attack_" + current_attack + "_raise")
		# 连击（从挥砍来）或从格挡起手 → 走交叉淡化；从待机起手 → 瞬切（淡入交给上身混合权重）
		var cur: String = String(attack_sm.get_current_node())
		if cur.begins_with("attack_") or cur.begins_with("block_"):
			attack_sm.travel(target)
		else:
			attack_sm.start(target)

func _release_attack():
	is_charging = false
	_do_attack_by_name(current_attack)

# 把鼠标位移判成 4 个攻击方向（以对角线 45° 为分界）：
#	|x| > |y| → 右 / 左（按 x 正负）
#	否则       → 下刺(motion.y > 0) / 上劈(motion.y < 0)
func _judge_mouse_dir(motion: Vector2) -> AttackDir:
	var ax: float = abs(motion.x)
	var ay: float = abs(motion.y)
	if ax > ay:
		return AttackDir.RIGHT if motion.x > 0 else AttackDir.LEFT
	else:
		return AttackDir.THRUST if motion.y > 0 else AttackDir.UP

func _do_attack_by_name(attack_name: String):
	if not can_attack:
		return
	can_attack = false
	is_attacking = true
	attack_gen += 1
	var my_gen: int = attack_gen
	# 从「开始挥击」这一刻起重新累积鼠标移动，用于判定下一刀方向（输入缓冲）
	mouse_move_delta = Vector2.ZERO
	current_attack = attack_name
	weapon_area.attack_dir = current_attack
	var swing_name: String = "attack_" + current_attack + "_swing"
	if attack_sm:
		attack_sm.travel(StringName(swing_name))
	# 读取挥砍动画实际时长，把打击判定窗口对齐到挥砍中段
	var swing_len: float = _get_anim_length(swing_name, 0.42)
	await get_tree().create_timer(swing_len * 0.25).timeout
	if my_gen != attack_gen:
		return   # 挥砍已被格挡打断，别再开打击判定
	weapon_hitbox.disabled = false
	await get_tree().create_timer(swing_len * 0.45).timeout
	weapon_hitbox.disabled = true
	# 让挥砍的收招段播完再回 idle，避免动作被生硬切断
	await get_tree().create_timer(swing_len * 0.30).timeout
	# 格挡优先：格挡已接管，挥砍协程直接退出，别再改状态/顶动画
	if my_gen != attack_gen or is_blocking:
		weapon_hitbox.disabled = true
		return
	is_attacking = false
	# 注意：这里不要清 last_anim_state —— 否则下一帧会对 move 层重新 travel，把移动动画从 0 帧重启（闪一下）
	# 缓冲连击：挥砍期间按住左键 → 挥砍结束直接过渡到下一次举刀（跳过收刀）；其间松手则作废
	if attack_buffered:
		attack_buffered = false
		can_attack = true
		if lmb_held and not is_blocking:
			_begin_charge()
			return
	# 收招 → 待机（收招期间 is_recovering=true，让上身权重保持 1，收招动作才显示）
	if attack_sm and not is_blocking:
		var recover_name: String = "attack_" + current_attack + "_recover"
		var recover_len: float = _get_anim_length(recover_name, 0.4)
		# 收剑俯仰过渡：与收剑动画时长同步归零
		recover_pitch_from = aim_pitch
		recover_pitch_dur = maxf(recover_len, 0.001)
		recover_pitch_t = 0.0
		is_recovering = true
		var recover_my_gen: int = recover_gen
		attack_sm.travel(StringName(recover_name))
		await get_tree().create_timer(recover_len).timeout
		if recover_my_gen != recover_gen:
			return   # 收招已被打断/被新的收招接管，交给接管者处理，勿回待机
		is_recovering = false
		attack_buffered = false
		attack_sm.travel(&"idle_weapon")
	await get_tree().create_timer(attack_cooldown).timeout
	can_attack = true

func _get_anim_length(clip: String, fallback: float) -> float:
	if animation_tree.anim_player != NodePath(""):
		var ap: AnimationPlayer = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
		if ap:
			if ap.has_animation(clip):
				return ap.get_animation(clip).get_length()
			# 持剑动画带 s_ 前缀
			var sname: String = "s_" + clip
			if ap.has_animation(sname):
				return ap.get_animation(sname).get_length()
	return fallback

func _set_blocking(active: bool):
	is_blocking = active
	if active:
		# 格挡优先：重置全部攻击状态（蓄力/挥砍/收剑/缓冲），并让挂起的收剑协程提前退出，
		# 避免残留的攻击动画在格挡之后乱播。
		is_charging = false
		is_attacking = false
		is_recovering = false
		recover_gen += 1   # 令挂起的收招协程提前退出（无条件 +1，不会像 bool 那样残留）
		attack_gen += 1    # 令挂起的挥砍协程彻底退出（否则挥砍协程醒来时格挡可能已松开，会顶掉格挡/后续攻击）
		can_attack = true  # 清除挥砍锁定，否则打断后「格挡完再攻击」会被 _do_attack_by_name 的 can_attack 挡掉
		weapon_hitbox.disabled = true
		attack_buffered = false
		# 鼠标动过才更新格挡方向；没动就保持上一次（初始默认「下」）
		if last_mouse_relative.length() > 1.0:
			var dir_name: String = ATTACK_DIR_NAMES[_judge_mouse_dir(last_mouse_relative)]
			block_dir_keep = "down" if dir_name == "thrust" else dir_name
		block_dir = block_dir_keep
		if attack_sm:
			# 用 travel 走 attack_* -> block_* 的短交叉淡化，避免 start() 硬切造成的跳变
			attack_sm.travel(StringName("block_" + block_dir))
	else:
		# 松开格挡时左键还按着 → 立刻淡入举剑攻击（不播格挡收招）
		if lmb_held:
			is_block_recovering = false
			is_recovering = false
			attack_buffered = false
			can_attack = true
			block_dir = ""
			last_anim_state = ""
			_begin_charge()
			return
		# 格挡松开：先播收招，再回待机（收招期间 is_recovering 保持上身权重=1）
		if block_dir != "" and attack_sm:
			var recover_name: String = "block_" + block_dir + "_recover"
			var recover_len: float = _get_anim_length(recover_name, 0.4)
			# 收剑俯仰过渡：与收剑动画时长同步归零
			recover_pitch_from = aim_pitch
			recover_pitch_dur = maxf(recover_len, 0.001)
			recover_pitch_t = 0.0
			is_block_recovering = true
			is_recovering = true
			var my_gen: int = recover_gen
			attack_sm.travel(StringName(recover_name))
			await get_tree().create_timer(recover_len).timeout
			is_block_recovering = false
			if my_gen != recover_gen:
				return   # 收招已被打断/接管，交给接管者处理，勿回待机
			is_recovering = false
			if attack_buffered and lmb_held:
				attack_buffered = false
				_begin_charge()
			elif not is_blocking:
				attack_sm.travel(&"idle_weapon")
		block_dir = ""
		last_anim_state = ""

# ============================================================
func take_damage(amount: float, _attack_dir: String = ""):
	if is_blocking:
		var reduced: float = amount * 0.2
		health -= reduced
		return
	health -= amount
	if attack_sm:
		attack_sm.travel(&"hit_weapon")
	if health <= 0:
		_die()

func _die():
	if attack_sm:
		attack_sm.travel(&"death")
	set_physics_process(false)

func is_dead() -> bool:
	return health <= 0
