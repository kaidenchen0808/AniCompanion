# 动画全集指南（26 个）

## 总表：动作 × 情绪 × 触发

触发通道图例：**说话句** = 流式回复中带 `[情绪]` 标签的句子（本地 AnimationDirector，仅 12 种表达性情绪、情绪变化才触发、每 clip 20s 冷却）；**手势** = 回复 TTS 开始（本地）；**服务端** = companion-layer 推送（触摸/情绪反应，台词帧携带，先做后说）；**闲时** = 10s 无互动（本地，变体全冷却则回落 `idle`）；**生命周期/聊天** = 固定挂点（本地直调）。

| # | 动作 | 状态 | 关联情绪标签 | 触发场景 | 通道 | 节流 |
|---|---|---|---|---|---|---|
| 1 | `idle` | ✅ 已有 | — | 默认待机；闲时变体全冷却时的回落 | 闲时 | — |
| 2 | `idle_arms_crossed` | 待补 | `[bored]` | 闲时变体 | 闲时/说话句 | 20s |
| 3 | `idle_hands_behind` | 待补 | — | 闲时变体 | 闲时 | 20s |
| 4 | `idle_stretch` | 待补 | — | 闲时变体（伸懒腰） | 闲时 | 20s |
| 5 | `talk_gesture` | ✅ 已有 | 说话兜底 | 每轮回复开始（`talk_expressive` 缺失时回落） | 手势 | 每轮一次 |
| 6 | `talk_expressive` | 待补 | 强情绪说话 | 每轮回复开始（优先于 `talk_gesture`） | 手势 | 每轮一次 |
| 7 | `nod` | ✅ 已有 | — | **被摸头**（服务端随机候选） | 服务端 | 触摸 5s 冷却 |
| 8 | `head_shake` | 待补 | `[angry]`/`[smirk]` | 说话句；**被戳身体**（服务端候选） | 说话句/服务端 | 20s |
| 9 | `shrug` | 待补 | `[smirk]`/`[bored]` | 说话句（候选末位） | 说话句 | 20s |
| 10 | `happy_clap` | 待补 | `[excited]`/`[laugh]` | 说话句（候选次位） | 说话句 | 20s |
| 11 | `happy_jump` | 待补 | `[excited]` | 说话句（候选首位） | 说话句 | 20s |
| 12 | `laugh_body` | 待补 | `[laugh]` | 说话句（候选首位） | 说话句 | 20s |
| 13 | `shy_cover` | 待补 | `[shy]` | 说话句；**被摸头**（服务端候选首位） | 说话句/服务端 | 20s |
| 14 | `sad_down` | 待补 | `[sad]` | 说话句（难过低头） | 说话句 | 20s |
| 15 | `angry_stomp` | 待补 | `[angry]` | 说话句（候选首位）；被戳（候选末位） | 说话句/服务端 | 20s |
| 16 | `surprised_step_back` | 待补 | `[surprised]` | 说话句；**被戳身体**（候选首位） | 说话句/服务端 | 20s |
| 17 | `sleepy_yawn` | 待补 | `[sleepy]` | 说话句；**深夜劝睡反应** | 说话句/服务端 | 20s |
| 18 | `wave` | ✅ 已有 | — | **模型加载成功**（她出现打招呼） | 生命周期 | 每次启动一次 |
| 19 | `bow_thanks` | 待补 | `[proud]` | 说话句（候选次位，鞠躬感谢） | 说话句 | 20s |
| 20 | `blow_kiss` | 待补 | `[love]` | 说话句（飞吻） | 说话句 | 20s |
| 21 | `come_here` | 待补 | — | 规划：主动开口开场（**未接线**，clip 到位后补触发点） | —（规划） | — |
| 22 | `think` | ✅ 已有 | — | 发出聊天请求、等待大脑回复时 | 聊天 | 每轮一次 |
| 23 | `cheer` | 待补 | — | **任务失败安慰**反应 | 服务端 | 反应 15min 冷却 |
| 24 | `celebrate` | 待补 | — | **任务成功**反应（大活收工） | 服务端 | 收工 60s 冷却 |
| 25 | `curious_look` | 待补 | `[curious]` | 说话句；闲时变体（张望点缀） | 说话句/闲时 | 20s |
| 26 | `proud_pose` | 待补 | `[proud]` | 说话句（候选首位，叉腰） | 说话句 | 20s |

**无专属动作的 4 种情绪**（共 16 种情绪）：`[neutral]` `[happy]` `[pain]` `[disgusted]` —— 由面部表情（16 情绪 → VRM 表情 blendshape）+ 说话手势承载，不抢肢体。
**脸部**：所有 16 种情绪都会驱动面部表情（`setExpression`，与肢体动画并行、每句刷新），唇同步由音频振幅驱动——肢体、表情、口型三层独立叠加。

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
