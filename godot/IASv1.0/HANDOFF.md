# IAS 项目交接文档（会话迁移用）

> 生成时间：本会话结束时。下个会话先读本文件，再继续。

## 1. 项目与仓库

- **工作工程（开发用）**：`D:\NSS-huangrongji\Godot\IASv1.0`（Godot 4.7 项目，自带 git 仓库，**无远程**）
- **备份/发布仓库**：`D:\NSS-huangrongji\DeepSeek`
  - `origin` = `https://github.com/Hld298053408/IAS.git`
  - 结构：`godot/IASv1.0/`（工程副本，排除 `.godot`/`.git`）、`blender/*.blend`、`README.md`
  - 用**快照**方式维护：从工作工程同步 → 提交 → 推送
- **Blender 源文件**：`D:\NSS-huangrongji\Blender\铁与鳞之书项目\IAS人物模型.blend`、`IAS马匹.blend`

## 2. 环境 / 工具

- Godot：`D:\steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe`
- Blender：`D:\steam\steamapps\common\Blender\blender.exe`（5.2，**fps 24**）
- 校验命令（改完必跑，要求 `EXIT=0` 且无 `ERROR|Parse`）：
  ```powershell
  & "D:\steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe" --headless --path "D:\NSS-huangrongji\Godot\IASv1.0" --quit-after 30
  ```

## 3. 重要约束 / 坑（务必遵守）

- **不要用 PowerShell `Get-Content -Raw` + `Set-Content` 改 `.gd/.tscn`**（ANSI 回写会毁中文注释）。一律用 edit/write 工具。
- `git log` 在控制台**会显示乱码但内容正常**；提交信息用 `-F <UTF-8文件>`，勿用控制台字符串。
- Blender 5.2：Action 用**新 layers API**（`action.layers→strips→channelbags→cb.fcurves`），**没有 `action.fcurves`**；建槽 `act.slots.new(id_type='OBJECT', name='Armature')`。
- `Skeleton3D.set_bone_global_pose_override(idx, tf, amount, persistent)` 是**骨架空间**；`amount=0` 清除该骨覆盖；`get_bone_global_pose` **包含覆盖** → 先清再读，否则累积自转。
- `BoneAttachment3D` 必须 `use_external_skeleton=true` + `external_skeleton=NodePath(...)`。
- `AnimationNodeBlendTree.connect_node(in_node, in_index, out_node)` 只 3 参；重连 `"output"` 会报 `Condition "output == p_output_node"`。
- 骨架改名已完成：人物 `Armature→ren`、马 `metarig→ma`（相关节点路径已同步）。
- 同步到备份仓库：`robocopy "D:\NSS-huangrongji\Godot\IASv1.0" "D:\NSS-huangrongji\DeepSeek\godot\IASv1.0" /E /XD ".godot" ".git" /XF "*.tmp" "*.bak*"`；再拷两个 `.blend` 到 `DeepSeek\blender\`。
- 强制重导资源：删 `.godot/imported/<file>-*` 再 `--headless --import`。

## 4. 已完成功能

### 骑乘系统（player.gd / horse.gd / horse.tscn）
- **上/下马**：按 `F`（输入动作 `interact`）。`_mount()` 全身播 `mount` 动画并刚性贴鞍座锚点；`_dismount()` 倒放 `mount_rev`（`_make_reversed` 运行时生成），下到马左侧。
- **跟随**：`_update_riding()` 每帧 `global_transform = 鞍座锚点`（`horse.rider_anchor()` → `RideBone(BoneAttachment3D)/Seat`，骨骼 `spine.005`）；关闭人物碰撞避免顶马。
- **步态**：按马 `speed` 切 `ride_walk/trot/canter/gallop`（move 状态机运行时 `_ensure_mount_states` 添加，转场 xfade 0.3）。
- **转向扭转**：`_apply_ride_twist()`，非攻击时 A/D → 躯干扭转（Spine 0.15、Chest 0.2，世界空间左乘）。
- **弹簧骨骼**：`_setup_spring_bones()` 建 `SpringBoneSimulator3D`，5 条链：`Chest→Head`、`左右Shoulder→Hand`、`左右UpperLeg→Foot`；默认关，骑乘（非上/下马）时开。
- **骑乘攻击**：允许（已去掉 `_input` 里骑乘拦截鼠标）；攻击时**始终保留上半身遮罩**（下半身骑马、不站起）。`_process` 的 `mask_off` 加了 `and not riding`。
- **骑乘攻击方向限制**：`_clamp_ride_aim()` 夹上身瞄准角（相对马正前）：
  - 右区 `[+right_min, +right_max]`、左区 `[-left_max, -left_min]`（默认均 15°/120°）；
  - **Godot `+yaw=左`、`-yaw=右`**；
  - 换侧判定：镜头进入**另一侧有效区**才切（越过对侧 ±min 边界），不是中线；
  - 换侧用 `move_toward` **限速**扫向实时目标（两端异号 → **必经 0°=马头正前**，不会从后面绕）；时长 = 需转角度 / `ride_aim_turn_speed`；
  - 同侧有效范围内**即时跟随、无延迟**。

### 其它
- 攻击方向判定仍是 `_judge_mouse_dir`（鼠标位移 4 向），未改。
- **上劈（up）现在也跟随镜头俯仰**：`cancel_pitch` 已改为**只剩 `is_blocking`**（之前 up 会取消俯仰）。
- **`~` 键**：按住 = 悬停机位 `CamHold` + 锁身体俯仰，松开回默认/骑乘机位；`_update_riding` 里 `cam_target` 覆盖加了 `and not is_holding_cam`（否则按下无效）。**站定(未移动/未战斗)时上身不朝镜头**（`_update_head_rotation` aim_target 已改）。

## 5. 关键参数（默认值）

player.gd：
- `ride_offset=(0,0,0)`、`ride_twist_speed=6.0`、`ride_combat_blend=3.0`（骑乘上下身混合，越小越慢）
- `ride_aim_right_min_deg=15` / `right_max=120`、`left_min=15` / `left_max=120`
- `ride_aim_turn_speed=1.5`（换侧角速度 弧度/秒，越小越慢）
- `spring_stiffness=0.1` / `spring_drag=0.3` / `spring_gravity=1.0`
- `CAM_PITCH_MIN=-1.6` / `CAM_PITCH_MAX=0.8`
- `walk_speed=3.0` / `run_speed=6.0` / `jump_velocity=4.29` / `jump_interval=1.5` / `body_rotation_speed=3`
- `max_health=100` / `attack_damage=25` / `attack_cooldown=0.1`

horse.gd：
- `walk_speed=1.8` / `trot_speed=3.6` / `canter_speed=6.0` / `gallop_speed=9.0` / `back_speed=1.5` / `accel=5` / `brake=8`
- `turn_speed=2.2` / `turn_speed_fast=1.1` / `jump_velocity=5.5` / `gravity=12` / `gait_fade=0.25`
- `ride_bone_name="spine.005"` / `turn_out_time=0.35` / `TURN_KEEP_BONES=["spine.004","spine.006","neck.002","neck.004"]`

相机 marker（CameraPivot 本地坐标，main.tscn）：
- `CamDefault=(0,0.354,1.794)`、`CamHold=(0,-0.511,1.518)`、`RideCam=(0,1.0,3.6)`；pivot 世界点 = base + `(0,1.6,0)`。

输入：`jump`=空格、`interact`=F、`move_*`；`~`=`KEY_QUOTELEFT`；CapsLock 切换走/跑。

## 6. 关键文件 / 函数索引

- `scripts/player.gd`（~916 行）：`_mount`/`_dismount`、`_update_riding(_delta)`、`_apply_ride_twist(delta)`、`_clamp_ride_aim(dy,side)`、`_apply_aim_bend(aim,delta)`、`_update_head_rotation(delta)`、`_update_camera(delta)`、`_update_camera_follow()`、`_cam_base_marker_pos()`、`_setup_spring_bones()`、`_ensure_mount_states()`/`_make_reversed()`、`_process`（combat blend / `mask_off` / pitch）、`_physics_process`（骑乘时只跑 `_update_riding`+相机）。
- `scripts/horse.gd`：速度步态、A/D 转向、空格跳；空中只播 `jump` 且不转向；`rider_anchor()`；`_strip_turn_tracks`。
- `scenes/horse.tscn`：`Model`(glb 转 180°，`ma/Skeleton3D`)、`TurnPlayer`、`Collision`、`RideBone(BoneAttachment3D)+Seat`。
- `scenes/player.tscn`：动画树 `body_blend(Blend2)` / `move_state` / `attack_state`；上半身遮罩配在 `body_blend` 过滤器（`ren/Skeleton3D:...`）。
- `scenes/main.tscn`：`Horse` 实例 (2,0,2)、`RideCam`、Player 节点引用。
- `assets/models/character.glb`（含 `ride_walk/trot/canter/gallop`、`mount`、jump 等）、`horse.glb`（11 个动画）。
- `scripts/enemy.gd`（勿删 AI 绕圈）、`weapon.gd`（Area3D 伤害）。

## 7. 待办 / 未决

- 骑乘攻击目前仍用**地面挥砍动画**（只作用上半身）。若要"骑在马上"的专用攻击动画，需在 Blender 另做再接入。
- `~` 在**骑乘且未攻击**时对"身体俯仰"不生效（骑乘只在攻击/格挡时跑 `_apply_aim_bend`）——待确认是否要补上。
- 弹簧骨骼参数（stiffness/drag/gravity）待实机微调。
- 备份仓库是**快照制**，不含工作工程自身的完整 git 历史。

## 8. 提交/推送流程

```powershell
$r="D:\NSS-huangrongji\DeepSeek"
git -C $r add -A
git -C $r -c user.name="IAS" -c user.email="ias@local" commit -F "<UTF-8信息文件>"
$env:GIT_TERMINAL_PROMPT=0; git -C $r push origin main
```
（推送前先跑一次上面的 headless 校验。）
