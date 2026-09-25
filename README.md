# IAS

骑砍类（Mount & Blade 风格）近战原型。

## 目录结构
- `blender/`
  - `IAS人物模型.blend` —— 角色模型 / 骨骼 / 攻击·格挡·移动等动画（导出 `character.glb`）
  - `IAS马匹.blend` —— 马匹模型 / 骨架 / 动画槽
- `godot/IASv1.0/` —— Godot 4.7 工程（主角控制、上下半身分层动画、攻击/格挡、骑乘等）

## 流程
在 Blender 做好模型与动画 → 导出 glTF（`godot/IASv1.0/assets/models/character.glb`）→ Godot 里通过 AnimationTree 使用。

> Unity 相关素材属于其它项目，未纳入本仓库。
