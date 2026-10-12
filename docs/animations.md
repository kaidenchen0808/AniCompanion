# 动画全集指南（26 个）

当前只导出了 5 个（`idle` / `nod` / `talk_gesture` / `think` / `wave`），编排层（`AnimationDirector`）已按
下面 26 个的完整清单实现触发逻辑——**动画文件放一个生效一个**，缺的静默跳过，随时可以先跑起来再补货。

## 导出管线（每个动作一次）

1. [mixamo.com](https://www.mixamo.com)（Adobe 免费账号）搜下表关键词，选最贴合的动画，Download → FBX
   Without Skin，30fps
2. Blender 打开 Perula 骨架工程，导入该 FBX，Auto-Rig Pro Remap 重定向
3. 选中 Perula armature 后跑导出：
   ```bash
   ANICOMPANION_ANIM_OUTPUT=/path/to/AniCompanion/Resources/Animations \
     blender file.blend --background --python Tools/export_animation.py
   ```
4. 产物改名成下表的 **文件名**（JSON 里 `name` 字段同步），重新构建即生效

许可证：Mixamo 动画可免费用于本项目形态（烘焙重定向的关键帧数据），`ATTRIBUTION.md` 已注明来源。

## 清单

### A. 基础状态（4）

| 文件名 | 语义 | 触发场景 | Mixamo 搜索词 |
|---|---|---|---|
| `idle` ✅ | 呼吸站立 | 默认待机 | Breathing / Idle |
| `idle_arms_crossed` | 抱臂站姿 | 闲时变体、bored 情绪 | Arms Crossed Idle |
| `idle_hands_behind` | 手背后 | 闲时变体 | Hands Behind Back Idle |
| `idle_stretch` | 伸懒腰 | 闲时变体、久坐提醒 | Stretching / Yawn Stretch |

### B. 说话与交流（5）

| 文件名 | 语义 | 触发场景 | Mixamo 搜索词 |
|---|---|---|---|
| `talk_gesture` ✅ | 常规说话手势 | 说话默认 | Talking Gesture |
| `talk_expressive` | 大幅手势 | excited/angry 等强情绪说话 | Talking Expressive |
| `nod` ✅ | 点头 | happy/认同情绪句、回应摸头 | Nodding Head |
| `head_shake` | 摇头 | 无奈、否定、bored | Shaking Head |
| `shrug` | 耸肩 | 好奇无解、neutral 点缀 | Shrugging |

### C. 情绪表达（8）

| 文件名 | 语义 | 触发场景 | Mixamo 搜索词 |
|---|---|---|---|
| `happy_clap` | 拍手 | happy/excited 峰值、庆祝 | Clapping |
| `happy_jump` | 开心跳 | excited 峰值、大好消息 | Jumping Joy |
| `laugh_body` | 大笑 | laugh 情绪句 | Laughing |
| `shy_cover` | 害羞低头 | shy 情绪、**被摸头** | Shy / Embarrassed |
| `sad_down` | 难过低头 | sad 情绪、失败安慰 | Sad Idle |
| `angry_stomp` | 跺脚生气 | angry 情绪、**连点戳她** | Angry Stomp / Stomp Foot |
| `surprised_step_back` | 惊讶后缩 | surprised 情绪、**被戳** | Surprised Reaction |
| `sleepy_yawn` | 打哈欠 | sleepy 情绪、**深夜劝睡** | Yawning |

### D. 互动反应（4）

| 文件名 | 语义 | 触发场景 | Mixamo 搜索词 |
|---|---|---|---|
| `wave` ✅ | 招手 | 连接成功打招呼、会话开始 | Waving |
| `bow_thanks` | 鞠躬感谢 | proud 情绪、被夸 | Bowing |
| `blow_kiss` | 飞吻 | love 情绪、close+ 阶段专属 | Blowing A Kiss |
| `come_here` | 招手过来 | 主动开口开场 | Beckoning / Come On |

### E. 功能场景（5）

| 文件名 | 语义 | 触发场景 | Mixamo 搜索词 |
|---|---|---|---|
| `think` ✅ | 思考 | 等大脑回复时 | Thinking Pose |
| `cheer` | 加油鼓劲 | **任务失败安慰**、鼓励 | Cheering / Pump Fist |
| `celebrate` | 挥拳庆祝 | **任务成功**、大活收工 | Victory Celebration |
| `curious_look` | 好奇张望 | curious 情绪、闲时点缀 | Looking Around |
| `proud_pose` | 骄傲叉腰 | proud 情绪、夸她时 | Hands On Hips Proud |

（被摸头的"享受眯眼"暂复用 `shy_cover`；想独立再做可选第 26 个：`pat_enjoy`。）

## 触发优先级与节流

显式指令（服务端推送）＞触摸反应＞情绪句＞说话手势＞闲时变体。同类动画 20s 冷却防连播；
说话期间情绪动画不打断唇同步（骨骼动画与表情 blendshape 互不冲突，但同一时间只播一个 clip）。
