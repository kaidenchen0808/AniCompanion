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
const IDENTITY = [0, 0, 0, 1];
const lerp = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
const easeInOut = t => (t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2);

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

  // 耸肩：双肩上提放下
  clip('shrug', 1.3, false, [
    { t: 0.0, bones: {} },
    { t: 0.35, bones: { leftShoulder: rz(8), rightShoulder: rz(-8), leftUpperArm: rz(15), rightUpperArm: rz(-15) } },
    { t: 0.75, bones: { leftShoulder: rz(8), rightShoulder: rz(-8), leftUpperArm: rz(15), rightUpperArm: rz(-15) } },
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

  // 好奇张望：头左右慢转带一点歪
  clip('curious_look', 4.0, true, [
    { t: 0.0, bones: {} },
    { t: 0.8, bones: { head: ry(-22) } },
    { t: 1.6, bones: { head: ry(-20), }, },
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

  // 打哈欠：双臂缓举过头 + 头后仰，保持一拍回落
  clip('sleepy_yawn', 3.4, false, [
    { t: 0.0, bones: {} },
    { t: 1.4, bones: {
      leftUpperArm: rx(-150), rightUpperArm: rx(-150),
      leftLowerArm: rx(-12), rightLowerArm: rx(-12),
      head: rx(-12), spine: rx(-4),
    } },
    { t: 2.2, bones: {
      leftUpperArm: rx(-150), rightUpperArm: rx(-150),
      leftLowerArm: rx(-12), rightLowerArm: rx(-12),
      head: rx(-12), spine: rx(-4),
    } },
    { t: 3.4, bones: {} },
  ]),

  // 叉腰自信：双臂外展 + 头微歪（静态呼吸）
  clip('proud_pose', 3.0, true, [
    { t: 0.0, bones: { leftUpperArm: rz(32), rightUpperArm: rz(-32), leftLowerArm: rx(0), head: rz(6) } },
    { t: 1.5, bones: { leftUpperArm: rz(33), rightUpperArm: rz(-33), head: rz(6.5) } },
    { t: 3.0, bones: { leftUpperArm: rz(32), rightUpperArm: rz(-32), head: rz(6) } },
  ]),

  // 抱臂：双臂前收交叉（保守幅度防穿模）
  clip('idle_arms_crossed', 3.0, true, [
    { t: 0.0, bones: {
      leftUpperArm: rx(22), leftLowerArm: rx(75),
      rightUpperArm: rx(22), rightLowerArm: rx(75),
    } },
    { t: 1.5, bones: {
      leftUpperArm: rx(23), leftLowerArm: rx(76),
      rightUpperArm: rx(23), rightLowerArm: rx(76),
    } },
    { t: 3.0, bones: {
      leftUpperArm: rx(22), leftLowerArm: rx(75),
      rightUpperArm: rx(22), rightLowerArm: rx(75),
    } },
  ]),

  // 手背后：上臂后收
  clip('idle_hands_behind', 3.0, true, [
    { t: 0.0, bones: { leftUpperArm: rx(-10), rightUpperArm: rx(-10), leftLowerArm: rx(25), rightLowerArm: rx(25) } },
    { t: 1.5, bones: { leftUpperArm: rx(-11), rightUpperArm: rx(-11), leftLowerArm: rx(26), rightLowerArm: rx(26) } },
    { t: 3.0, bones: { leftUpperArm: rx(-10), rightUpperArm: rx(-10), leftLowerArm: rx(25), rightLowerArm: rx(25) } },
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
