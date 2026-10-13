#!/usr/bin/env node
/**
 * 程序化生成简单语义动画（无需 Mixamo）——单关节/少关节动作直接用关键帧数学生成。
 *
 * 轴向语义实测自 nod.json / wave.json（VRM normalized humanoid 骨架）：
 *   head:      X+ 低头 / Y± 转头 / Z± 歪头
 *   spine/upperChest: X+ 前倾（鞠躬）/ X- 后仰
 *   upperArm:  X- 举臂（-90° 过头）/ Z± 外展（左右镜像）/ Y 内外旋
 *   lowerArm:  X- 弯曲
 *
 * 用法：node Tools/generate_animation.js [--out DIR]
 * 幂等覆盖同名文件；生成的都是增量帧（只写涉及的骨骼，未列出的骨骼默认恒等）。
 */
'use strict';
const fs = require('fs');
const path = require('path');

const OUT = process.argv.includes('--out')
  ? path.resolve(process.argv[process.argv.indexOf('--out') + 1])
  : path.join(__dirname, '..', 'AniCompanion', 'Resources', 'Animations');
const FPS = 30;

// ---- 数学工具 -------------------------------------------------------------

/** 绕单位轴旋转 deg 度 → 四元数分量 [x,y,z,w]（half-angle 形式）。 */
function rot(axis, deg) {
  const r = (deg * Math.PI) / 360;
  const s = Math.sin(r);
  return [axis[0] * s, axis[1] * s, axis[2] * s, Math.cos(r)];
}
const rx = d => rot([1, 0, 0], d);
const ry = d => rot([0, 1, 0], d);
const rz = d => rot([0, 0, 1], d);
/** Hamilton 积 a*b（先 a 后 b，b 在 a 的局部坐标系）。 */
function mul(a, b) {
  const [ax, ay, az, aw] = a, [bx, by, bz, bw] = b;
  return [
    aw * bx + ax * bw + ay * bz - az * by,
    aw * by - ax * bz + ay * bw + az * bx,
    aw * bz + ax * by - ay * bx + az * bw,
    aw * bw - ax * bx - ay * by - az * bz,
  ];
}
const IDENTITY = [0, 0, 0, 1];
const lerp = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

/**
 * 手臂骨骼的 rest 基准（对齐 vrm_scene.js applyRestPose 的 Z±65°/Z±10° 下垂姿势）。
 * 动画帧是绝对覆盖：手臂姿势必须写成 REST 与偏移的叠加（REST * delta），
 * 漏掉 Z 分量会把上臂打回 T-pose 平伸（"伸开双臂"bug 的根因）。
 */
const ARM_REST = {
  leftUpperArm: rz(65), rightUpperArm: rz(-65),
  leftLowerArm: rz(10), rightLowerArm: rz(-10),
};
/** 在 rest 基准上叠加偏移（局部系欧拉 x/y/z，单位度）。 */
const arm = (bone, { x = 0, y = 0, z = 0 }) =>
  mul(ARM_REST[bone], mul(mul(rx(x), ry(y)), rz(z)));

/** 关键帧 → 30fps 全帧 clip（每骨骼线性插值四元数分量；JS 端还会 slerp，够平滑）。 */
function clip(name, duration, loop, keys) {
  const frames = [];
  const bones = [...new Set(keys.flatMap(k => Object.keys(k.bones)))];
  for (let i = 0; i < Math.round(duration * FPS); i++) {
    const t = i / FPS;
    let a = keys[0], b = keys[keys.length - 1];
    for (let j = 0; j < keys.length - 1; j++) {
      if (t >= keys[j].t && t <= keys[j + 1].t) { a = keys[j]; b = keys[j + 1]; break; }
    }
    const span = b.t - a.t;
    const raw = span > 0 ? (t - a.t) / span : 0;
    const f = { time: +t.toFixed(4), bones: {} };
    for (const bone of bones) {
      f.bones[bone] = lerp(a.bones[bone] ?? IDENTITY, b.bones[bone] ?? IDENTITY, raw);
    }
    frames.push(f);
  }
  return { name, fps: FPS, duration, loop, frames };
}

// ---- 动画定义 -------------------------------------------------------------

const clips = [
  // 摇头：来回两次渐弱
  clip('head_shake', 1.6, false, [
    { t: 0.0, bones: {} },
    { t: 0.35, bones: { head: ry(-18) } },
    { t: 0.75, bones: { head: ry(18) } },
    { t: 1.1, bones: { head: ry(-13) } },
    { t: 1.35, bones: { head: ry(10) } },
    { t: 1.6, bones: {} },
  ]),

  // 耸肩：双肩上提放下（手臂在 rest 基准上微收）
  clip('shrug', 1.3, false, [
    { t: 0.0, bones: {} },
    { t: 0.35, bones: {
      leftShoulder: rz(8), rightShoulder: rz(-8),
      leftUpperArm: arm('leftUpperArm', { z: 6 }), rightUpperArm: arm('rightUpperArm', { z: -6 }),
    } },
    { t: 0.75, bones: {
      leftShoulder: rz(8), rightShoulder: rz(-8),
      leftUpperArm: arm('leftUpperArm', { z: 6 }), rightUpperArm: arm('rightUpperArm', { z: -6 }),
    } },
    { t: 1.3, bones: {} },
  ]),

  // 鞠躬：躯干前倾到位停半秒再回
  clip('bow_thanks', 2.4, false, [
    { t: 0.0, bones: {} },
    { t: 0.8, bones: { spine: rx(28), upperChest: rx(15), head: rx(10) } },
    { t: 1.5, bones: { spine: rx(28), upperChest: rx(15), head: rx(10) } },
    { t: 2.4, bones: {} },
  ]),

  // 难过低头：持续姿势 + 呼吸微动（loop 首尾一致）
  clip('sad_down', 3.0, true, [
    { t: 0.0, bones: { head: rx(22), neck: rx(8), upperChest: rx(6) } },
    { t: 1.5, bones: { head: rx(23.5), neck: rx(8.5), upperChest: rx(7) } },
    { t: 3.0, bones: { head: rx(22), neck: rx(8), upperChest: rx(6) } },
  ]),

  // 好奇张望：头左右慢转，单次播完回正（闲时变体不再永续循环）
  clip('curious_look', 4.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.8, bones: { head: ry(-22) } },
    { t: 1.6, bones: { head: ry(-20) } },
    { t: 2.4, bones: { head: ry(22) } },
    { t: 3.2, bones: { head: ry(20) } },
    { t: 4.0, bones: {} },
  ]),

  // 大笑：上身后仰小幅高频晃
  clip('laugh_body', 2.4, true, [
    { t: 0.0, bones: { upperChest: rx(-6), head: rx(-8) } },
    { t: 0.4, bones: { upperChest: rx(-9), head: rx(-11) } },
    { t: 0.8, bones: { upperChest: rx(-5), head: rx(-6) } },
    { t: 1.2, bones: { upperChest: rx(-9), head: rx(-11) } },
    { t: 1.6, bones: { upperChest: rx(-5), head: rx(-6) } },
    { t: 2.0, bones: { upperChest: rx(-9), head: rx(-11) } },
    { t: 2.4, bones: { upperChest: rx(-6), head: rx(-8) } },
  ]),

  // 打哈欠：双臂自 rest 侧举过头 + 头后仰，保持一拍回落
  clip('sleepy_yawn', 3.4, false, [
    { t: 0.0, bones: {} },
    { t: 1.4, bones: {
      leftUpperArm: arm('leftUpperArm', { z: 110, x: -15 }), rightUpperArm: arm('rightUpperArm', { z: -110, x: -15 }),
      leftLowerArm: arm('leftLowerArm', { x: -12 }), rightLowerArm: arm('rightLowerArm', { x: -12 }),
      head: rx(-12), spine: rx(-4),
    } },
    { t: 2.2, bones: {
      leftUpperArm: arm('leftUpperArm', { z: 110, x: -15 }), rightUpperArm: arm('rightUpperArm', { z: -110, x: -15 }),
      leftLowerArm: arm('leftLowerArm', { x: -12 }), rightLowerArm: arm('rightLowerArm', { x: -12 }),
      head: rx(-12), spine: rx(-4),
    } },
    { t: 3.4, bones: {} },
  ]),

  // 叉腰自信：上臂略外展内旋 + 前臂弯向腰侧 + 头微歪
  clip('proud_pose', 3.0, true, [
    { t: 0.0, bones: {
      leftUpperArm: arm('leftUpperArm', { z: -25, y: -25 }), rightUpperArm: arm('rightUpperArm', { z: 25, y: 25 }),
      leftLowerArm: arm('leftLowerArm', { x: 55, y: 25 }), rightLowerArm: arm('rightLowerArm', { x: 55, y: -25 }),
      head: rz(6),
    } },
    { t: 1.5, bones: {
      leftUpperArm: arm('leftUpperArm', { z: -26, y: -25 }), rightUpperArm: arm('rightUpperArm', { z: 26, y: 25 }),
      leftLowerArm: arm('leftLowerArm', { x: 56, y: 25 }), rightLowerArm: arm('rightLowerArm', { x: 56, y: -25 }),
      head: rz(6.5),
    } },
    { t: 3.0, bones: {
      leftUpperArm: arm('leftUpperArm', { z: -25, y: -25 }), rightUpperArm: arm('rightUpperArm', { z: 25, y: 25 }),
      leftLowerArm: arm('leftLowerArm', { x: 55, y: 25 }), rightLowerArm: arm('rightLowerArm', { x: 55, y: -25 }),
      head: rz(6),
    } },
  ]),

  // 抱臂：上臂略外展 + 前臂前弯交叉在胸前，单次播完回落（不再永续卡姿势）
  clip('idle_arms_crossed', 4.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.5, bones: {
      leftUpperArm: arm('leftUpperArm', { z: -18, y: -35 }), rightUpperArm: arm('rightUpperArm', { z: 18, y: 35 }),
      leftLowerArm: arm('leftLowerArm', { x: 80, y: 30 }), rightLowerArm: arm('rightLowerArm', { x: 80, y: -30 }),
    } },
    { t: 3.5, bones: {
      leftUpperArm: arm('leftUpperArm', { z: -18, y: -35 }), rightUpperArm: arm('rightUpperArm', { z: 18, y: 35 }),
      leftLowerArm: arm('leftLowerArm', { x: 80, y: 30 }), rightLowerArm: arm('rightLowerArm', { x: 80, y: -30 }),
    } },
    { t: 4.0, bones: {} },
  ]),

  // 害羞捂脸：双手举到脸颊侧，头微低偏转（摸头反应首选动画）
  clip('shy_cover', 3.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.45, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -55, z: -18, y: -20 }), rightUpperArm: arm('rightUpperArm', { x: -55, z: 18, y: 20 }),
      leftLowerArm: arm('leftLowerArm', { x: 105, y: 25 }), rightLowerArm: arm('rightLowerArm', { x: 105, y: -25 }),
      head: rx(12),
    } },
    { t: 2.2, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -55, z: -18, y: -20 }), rightUpperArm: arm('rightUpperArm', { x: -55, z: 18, y: 20 }),
      leftLowerArm: arm('leftLowerArm', { x: 105, y: 25 }), rightLowerArm: arm('rightLowerArm', { x: 105, y: -25 }),
      head: rx(12),
    } },
    { t: 3.0, bones: {} },
  ]),

  // 伸懒腰（闲时变体）：双臂上举过头 + 上身后仰伸展
  clip('idle_stretch', 3.6, false, [
    { t: 0.0, bones: {} },
    { t: 1.3, bones: {
      leftUpperArm: arm('leftUpperArm', { z: 100, x: -30 }), rightUpperArm: arm('rightUpperArm', { z: -100, x: -30 }),
      leftLowerArm: arm('leftLowerArm', { x: -15 }), rightLowerArm: arm('rightLowerArm', { x: -15 }),
      upperChest: rx(-6), head: rx(-8),
    } },
    { t: 2.5, bones: {
      leftUpperArm: arm('leftUpperArm', { z: 100, x: -30 }), rightUpperArm: arm('rightUpperArm', { z: -100, x: -30 }),
      leftLowerArm: arm('leftLowerArm', { x: -15 }), rightLowerArm: arm('rightLowerArm', { x: -15 }),
      upperChest: rx(-6), head: rx(-8),
    } },
    { t: 3.6, bones: {} },
  ]),

  // 惊讶后缩：上身后仰 + 双臂张开 + 头后仰，快速到位保持回落
  clip('surprised_step_back', 1.8, false, [
    { t: 0.0, bones: {} },
    { t: 0.3, bones: {
      upperChest: rx(-10), head: rx(-8),
      leftUpperArm: arm('leftUpperArm', { z: -22, x: -30 }), rightUpperArm: arm('rightUpperArm', { z: 22, x: -30 }),
      leftLowerArm: arm('leftLowerArm', { x: 25 }), rightLowerArm: arm('rightLowerArm', { x: 25 }),
    } },
    { t: 1.1, bones: {
      upperChest: rx(-10), head: rx(-8),
      leftUpperArm: arm('leftUpperArm', { z: -22, x: -30 }), rightUpperArm: arm('rightUpperArm', { z: 22, x: -30 }),
      leftLowerArm: arm('leftLowerArm', { x: 25 }), rightLowerArm: arm('rightLowerArm', { x: 25 }),
    } },
    { t: 1.8, bones: {} },
  ]),

  // 挥拳庆祝：右臂高举过头 + 左臂收腰 + 头上扬
  clip('celebrate', 2.2, false, [
    { t: 0.0, bones: {} },
    { t: 0.35, bones: {
      rightUpperArm: arm('rightUpperArm', { z: -135, x: -15 }), rightLowerArm: arm('rightLowerArm', { x: 95 }),
      leftUpperArm: arm('leftUpperArm', { x: 10, y: 25, z: -10 }), leftLowerArm: arm('leftLowerArm', { x: 60 }),
      head: rx(-6),
    } },
    { t: 0.55, bones: {
      rightUpperArm: arm('rightUpperArm', { z: -120, x: -15 }), rightLowerArm: arm('rightLowerArm', { x: 80 }),
      leftUpperArm: arm('leftUpperArm', { x: 10, y: 25, z: -10 }), leftLowerArm: arm('leftLowerArm', { x: 60 }),
      head: rx(-6),
    } },
    { t: 0.8, bones: {
      rightUpperArm: arm('rightUpperArm', { z: -135, x: -15 }), rightLowerArm: arm('rightLowerArm', { x: 95 }),
      leftUpperArm: arm('leftUpperArm', { x: 10, y: 25, z: -10 }), leftLowerArm: arm('leftLowerArm', { x: 60 }),
      head: rx(-6),
    } },
    { t: 1.0, bones: {
      rightUpperArm: arm('rightUpperArm', { z: -120, x: -15 }), rightLowerArm: arm('rightLowerArm', { x: 80 }),
      leftUpperArm: arm('leftUpperArm', { x: 10, y: 25, z: -10 }), leftLowerArm: arm('leftLowerArm', { x: 60 }),
      head: rx(-6),
    } },
    { t: 1.3, bones: {
      rightUpperArm: arm('rightUpperArm', { z: -135, x: -15 }), rightLowerArm: arm('rightLowerArm', { x: 95 }),
      leftUpperArm: arm('leftUpperArm', { x: 10, y: 25, z: -10 }), leftLowerArm: arm('leftLowerArm', { x: 60 }),
      head: rx(-6),
    } },
    { t: 2.2, bones: {} },
  ]),

  // 加油鼓劲：双臂弯举胸前小幅快振
  clip('cheer', 2.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.3, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -35, z: -18 }), rightUpperArm: arm('rightUpperArm', { x: -35, z: 18 }),
      leftLowerArm: arm('leftLowerArm', { x: 100 }), rightLowerArm: arm('rightLowerArm', { x: 100 }),
    } },
    { t: 0.55, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -45, z: -18 }), rightUpperArm: arm('rightUpperArm', { x: -45, z: 18 }),
      leftLowerArm: arm('leftLowerArm', { x: 85 }), rightLowerArm: arm('rightLowerArm', { x: 85 }),
    } },
    { t: 0.8, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -35, z: -18 }), rightUpperArm: arm('rightUpperArm', { x: -35, z: 18 }),
      leftLowerArm: arm('leftLowerArm', { x: 100 }), rightLowerArm: arm('rightLowerArm', { x: 100 }),
    } },
    { t: 1.05, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -45, z: -18 }), rightUpperArm: arm('rightUpperArm', { x: -45, z: 18 }),
      leftLowerArm: arm('leftLowerArm', { x: 85 }), rightLowerArm: arm('rightLowerArm', { x: 85 }),
    } },
    { t: 1.3, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -35, z: -18 }), rightUpperArm: arm('rightUpperArm', { x: -35, z: 18 }),
      leftLowerArm: arm('leftLowerArm', { x: 100 }), rightLowerArm: arm('rightLowerArm', { x: 100 }),
    } },
    { t: 2.0, bones: {} },
  ]),

  // 大幅说话手势：双臂交替前摆（强情绪说话）
  clip('talk_expressive', 2.8, true, [
    { t: 0.0, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -45, y: -15 }), leftLowerArm: arm('leftLowerArm', { x: 55 }),
      rightUpperArm: arm('rightUpperArm', { x: -12 }), rightLowerArm: arm('rightLowerArm', { x: 40 }),
    } },
    { t: 0.7, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -12 }), leftLowerArm: arm('leftLowerArm', { x: 40 }),
      rightUpperArm: arm('rightUpperArm', { x: -45, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 55 }),
    } },
    { t: 1.4, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -45, y: -15 }), leftLowerArm: arm('leftLowerArm', { x: 55 }),
      rightUpperArm: arm('rightUpperArm', { x: -12 }), rightLowerArm: arm('rightLowerArm', { x: 40 }),
    } },
    { t: 2.1, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -12 }), leftLowerArm: arm('leftLowerArm', { x: 40 }),
      rightUpperArm: arm('rightUpperArm', { x: -45, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 55 }),
    } },
    { t: 2.8, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -45, y: -15 }), leftLowerArm: arm('leftLowerArm', { x: 55 }),
      rightUpperArm: arm('rightUpperArm', { x: -12 }), rightLowerArm: arm('rightLowerArm', { x: 40 }),
    } },
  ]),

  // 招手过来：右臂前举 + 前臂往回摆
  clip('come_here', 1.8, false, [
    { t: 0.0, bones: {} },
    { t: 0.4, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -75, z: 10 }), rightLowerArm: arm('rightLowerArm', { x: 45, y: 20 }),
    } },
    { t: 0.7, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -75, z: 10 }), rightLowerArm: arm('rightLowerArm', { x: 30, y: -15 }),
    } },
    { t: 1.0, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -75, z: 10 }), rightLowerArm: arm('rightLowerArm', { x: 45, y: 20 }),
    } },
    { t: 1.3, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -75, z: 10 }), rightLowerArm: arm('rightLowerArm', { x: 30, y: -15 }),
    } },
    { t: 1.8, bones: {} },
  ]),

  // 拍手：双臂前举 + 前臂交替靠拢分开
  clip('happy_clap', 2.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.3, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -50, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: -50, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 65, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 65, y: -15 }),
    } },
    { t: 0.55, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -50, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: -50, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 65, y: 30 }), rightLowerArm: arm('rightLowerArm', { x: 65, y: -30 }),
    } },
    { t: 0.8, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -50, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: -50, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 65, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 65, y: -15 }),
    } },
    { t: 1.05, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -50, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: -50, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 65, y: 30 }), rightLowerArm: arm('rightLowerArm', { x: 65, y: -30 }),
    } },
    { t: 1.3, bones: {
      leftUpperArm: arm('leftUpperArm', { x: -50, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: -50, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 65, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 65, y: -15 }),
    } },
    { t: 2.0, bones: {} },
  ]),

  // 生气跺脚（近似：双拳收腰 + 上身前倾小晃，替代腿部动作）
  clip('angry_stomp', 1.6, false, [
    { t: 0.0, bones: {} },
    { t: 0.3, bones: {
      leftUpperArm: arm('leftUpperArm', { x: 15, y: 25, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: 15, y: -25, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 85 }), rightLowerArm: arm('rightLowerArm', { x: 85 }),
      upperChest: rx(8), head: rx(8),
    } },
    { t: 0.55, bones: {
      leftUpperArm: arm('leftUpperArm', { x: 15, y: 25, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: 15, y: -25, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 85 }), rightLowerArm: arm('rightLowerArm', { x: 85 }),
      upperChest: rx(12), head: rx(10),
    } },
    { t: 0.8, bones: {
      leftUpperArm: arm('leftUpperArm', { x: 15, y: 25, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: 15, y: -25, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 85 }), rightLowerArm: arm('rightLowerArm', { x: 85 }),
      upperChest: rx(8), head: rx(8),
    } },
    { t: 1.05, bones: {
      leftUpperArm: arm('leftUpperArm', { x: 15, y: 25, z: -12 }), rightUpperArm: arm('rightUpperArm', { x: 15, y: -25, z: 12 }),
      leftLowerArm: arm('leftLowerArm', { x: 85 }), rightLowerArm: arm('rightLowerArm', { x: 85 }),
      upperChest: rx(12), head: rx(10),
    } },
    { t: 1.6, bones: {} },
  ]),

  // 飞吻（近似：右手到嘴边再前伸张开）
  clip('blow_kiss', 2.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.6, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -60, z: 8, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 110, y: -15 }),
      head: rz(-5),
    } },
    { t: 1.0, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -60, z: 8, y: 15 }), rightLowerArm: arm('rightLowerArm', { x: 110, y: -15 }),
      head: rz(-5),
    } },
    { t: 1.4, bones: {
      rightUpperArm: arm('rightUpperArm', { x: -80, z: 12, y: 25 }), rightLowerArm: arm('rightLowerArm', { x: 15 }),
      head: rz(-5),
    } },
    { t: 2.0, bones: {} },
  ]),

  // 手背后：上臂后旋微后摆 + 前臂后弯，单次播完回落
  clip('idle_hands_behind', 4.0, false, [
    { t: 0.0, bones: {} },
    { t: 0.5, bones: {
      leftUpperArm: arm('leftUpperArm', { x: 12, y: 25 }), rightUpperArm: arm('rightUpperArm', { x: 12, y: -25 }),
      leftLowerArm: arm('leftLowerArm', { x: 30 }), rightLowerArm: arm('rightLowerArm', { x: 30 }),
    } },
    { t: 3.5, bones: {
      leftUpperArm: arm('leftUpperArm', { x: 12, y: 25 }), rightUpperArm: arm('rightUpperArm', { x: 12, y: -25 }),
      leftLowerArm: arm('leftLowerArm', { x: 30 }), rightLowerArm: arm('rightLowerArm', { x: 30 }),
    } },
    { t: 4.0, bones: {} },
  ]),
];

// ---- 输出 -----------------------------------------------------------------

fs.mkdirSync(OUT, { recursive: true });
for (const c of clips) {
  const file = path.join(OUT, `${c.name}.json`);
  fs.writeFileSync(file, JSON.stringify(c) + '\n');
  console.log(`✓ ${c.name}.json  (${c.duration}s, loop=${c.loop}, ${c.frames.length} frames)`);
}
console.log(`\n${clips.length} 个动画已写入 ${OUT}`);
