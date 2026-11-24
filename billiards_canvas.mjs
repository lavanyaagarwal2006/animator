// Draws the billiards table and runs its frame loop.
// All the physics is in billiards.gleam; this file only handles the mouse,
// timing, and pictures.

import * as B from "./billiards.mjs";

const COLORS = {
  1: "#f2c00f", // yellow
  2: "#1d4ed8", // blue
  3: "#d62828", // red
  4: "#6b2d91", // purple
  5: "#f77f00", // orange
  6: "#127a3c", // green
  7: "#7f1d1d", // maroon
  8: "#111111", // black
};
const MAX_PULL = 140; // how far back (px) the stick goes at full power

let game = B.new_game();
let canvas = null;
let ctx = null;
let running = false;
let loopId = 0;
let last = 0;
let mouse = null; // last mouse position in canvas pixels
let aimDir = { x: 1, y: 0 };
let drag = null; // where the mouse was pressed while pulling back
let pull = 0; // 0..MAX_PULL

// ── Called from Gleam ──────────────────────────────────────────────────────────

export function start() {
  if (running) return;
  running = true;
  const id = ++loopId;
  const tryAttach = () => {
    if (id !== loopId) return;
    const el = document.getElementById("billiards-canvas");
    if (!el) {
      requestAnimationFrame(tryAttach);
      return;
    }
    if (el !== canvas) {
      canvas = el;
      ctx = el.getContext("2d");
      attach(el);
    }
    last = performance.now();
    requestAnimationFrame((now) => frame(now, id));
  };
  tryAttach();
}

export function stop() {
  running = false;
  loopId++;
}

export function reset() {
  game = B.new_game();
  drag = null;
  pull = 0;
}

// ── Loop ───────────────────────────────────────────────────────────────────────

function frame(now, id) {
  if (id !== loopId) return;
  const dt = Math.min((now - last) / 1000, 1 / 30);
  last = now;
  game = B.step(game, dt);
  draw();
  requestAnimationFrame((t) => frame(t, id));
}

// ── Mouse: move to aim, press and drag back to set power, release to shoot ───

function toCanvas(e) {
  const r = canvas.getBoundingClientRect();
  return {
    x: ((e.clientX - r.left) * canvas.width) / r.width,
    y: ((e.clientY - r.top) * canvas.height) / r.height,
  };
}

function cueBall() {
  return B.ball_views(game)
    .toArray()
    .find((b) => b.num === 0 && b.scale === 1);
}

function updateAim() {
  const cue = cueBall();
  if (!cue || !mouse) return;
  const dx = mouse.x - cue.x;
  const dy = mouse.y - cue.y;
  const len = Math.hypot(dx, dy);
  if (len > 1) aimDir = { x: dx / len, y: dy / len };
}

function updatePull() {
  // Distance the mouse has moved backwards along the aim line.
  const back = (drag.x - mouse.x) * aimDir.x + (drag.y - mouse.y) * aimDir.y;
  pull = Math.max(0, Math.min(MAX_PULL, back));
}

function attach(el) {
  window.addEventListener("mousemove", (e) => {
    if (!running) return;
    mouse = toCanvas(e);
    if (drag) updatePull();
    else updateAim();
  });
  el.addEventListener("mousedown", (e) => {
    if (!B.all_stopped(game) || !cueBall()) return;
    e.preventDefault();
    mouse = toCanvas(e);
    updateAim();
    drag = { x: mouse.x, y: mouse.y };
    pull = 0;
  });
  window.addEventListener("mouseup", () => {
    if (!drag) return;
    const power = pull / MAX_PULL;
    drag = null;
    pull = 0;
    if (power > 0.03) game = B.shoot(game, aimDir.x, aimDir.y, power);
  });
}

// ── Drawing ────────────────────────────────────────────────────────────────────

function draw() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  drawTable();
  const views = B.ball_views(game).toArray();
  const cue = views.find((v) => v.num === 0 && v.scale === 1);
  const aiming = B.all_stopped(game) && cue && (mouse || drag);
  if (aiming) drawAim(cue);
  for (const v of views) drawBall(v);
  if (aiming) {
    drawStick(cue);
    if (drag) drawPower();
  }
}

function fillRound(x, y, w, h, r, color) {
  ctx.beginPath();
  ctx.roundRect(x, y, w, h, r);
  ctx.fillStyle = color;
  ctx.fill();
}

function dot(x, y, r, color) {
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  ctx.fillStyle = color;
  ctx.fill();
}

function drawTable() {
  const L = B.left, R = B.right, T = B.top, Bo = B.bottom;
  // Wooden frame and cushions.
  fillRound(L - 48, T - 48, R - L + 96, Bo - T + 96, 18, "#5a3118");
  fillRound(L - 20, T - 20, R - L + 40, Bo - T + 40, 8, "#1b6a3f");
  // Felt, slightly lighter in the middle.
  const cx = (L + R) / 2, cy = (T + Bo) / 2;
  const felt = ctx.createRadialGradient(cx, cy, 40, cx, cy, (R - L) / 1.6);
  felt.addColorStop(0, "#2f9a5f");
  felt.addColorStop(1, "#1e7244");
  ctx.fillStyle = felt;
  ctx.fillRect(L, T, R - L, Bo - T);
  // Head string and foot spot.
  const headX = L + (R - L) * 0.25;
  ctx.strokeStyle = "rgba(255,255,255,0.12)";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(headX, T);
  ctx.lineTo(headX, Bo);
  ctx.stroke();
  dot(L + (R - L) * 0.72, cy, 2.5, "rgba(255,255,255,0.3)");
  // Diamonds on the rails.
  for (let i = 1; i < 8; i++) {
    if (i === 4) continue;
    const x = L + ((R - L) * i) / 8;
    dot(x, T - 34, 3, "#e8d9b0");
    dot(x, Bo + 34, 3, "#e8d9b0");
  }
  for (let i = 1; i < 4; i++) {
    const y = T + ((Bo - T) * i) / 4;
    dot(L - 34, y, 3, "#e8d9b0");
    dot(R + 34, y, 3, "#e8d9b0");
  }
  // Pockets.
  for (const p of B.pockets().toArray()) dot(p.x, p.y, p.r, "#0b0b0b");
}

function drawBall({ num, x, y, scale }) {
  const r = B.radius * scale;
  if (r < 0.3) return;
  ctx.save();
  dot(x + 2 * scale, y + 3 * scale, r, "rgba(0,0,0,0.35)"); // shadow
  // Base: white for the cue ball and stripes, the colour for solids.
  ctx.beginPath();
  ctx.arc(x, y, r, 0, 2 * Math.PI);
  ctx.fillStyle = num >= 1 && num <= 8 ? COLORS[num] : "#f8f6ee";
  ctx.fill();
  if (num >= 9) {
    // Coloured band across the middle of a stripe.
    ctx.save();
    ctx.clip();
    ctx.fillStyle = COLORS[num - 8];
    ctx.fillRect(x - r, y - r * 0.55, 2 * r, r * 1.1);
    ctx.restore();
  }
  if (num > 0) {
    dot(x, y, r * 0.5, "#ffffff");
    ctx.fillStyle = "#111";
    ctx.font = `bold ${Math.max(1, Math.round(r * 0.62))}px sans-serif`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(String(num), x, y + r * 0.04);
  }
  // Shine and shading so it looks round.
  const g = ctx.createRadialGradient(x - r * 0.4, y - r * 0.45, r * 0.05, x, y, r);
  g.addColorStop(0, "rgba(255,255,255,0.55)");
  g.addColorStop(0.35, "rgba(255,255,255,0)");
  g.addColorStop(1, "rgba(0,0,0,0.25)");
  dot(x, y, r, g);
  ctx.restore();
}

function line(x1, y1, x2, y2) {
  ctx.beginPath();
  ctx.moveTo(x1, y1);
  ctx.lineTo(x2, y2);
  ctx.stroke();
}

function drawAim(cue) {
  const a = B.aim(game, aimDir.x, aimDir.y);
  ctx.save();
  ctx.lineWidth = 2;
  ctx.strokeStyle = "rgba(255,255,255,0.85)";
  ctx.setLineDash([6, 6]);
  line(cue.x, cue.y, a.ghost_x, a.ghost_y);
  ctx.setLineDash([]);
  // Ghost ball: where the cue ball will be at contact.
  ctx.beginPath();
  ctx.arc(a.ghost_x, a.ghost_y, B.radius, 0, 2 * Math.PI);
  ctx.stroke();
  if (a.hit) {
    // Where the object ball goes...
    line(a.target_x, a.target_y, a.target_x + a.obj_dx * 90, a.target_y + a.obj_dy * 90);
    // ...and where the cue ball glances off to.
    ctx.strokeStyle = "rgba(255,255,255,0.45)";
    line(a.ghost_x, a.ghost_y, a.ghost_x + a.cue_dx * 55, a.ghost_y + a.cue_dy * 55);
  } else {
    ctx.strokeStyle = "rgba(255,255,255,0.45)";
    line(a.ghost_x, a.ghost_y, a.ghost_x + a.cue_dx * 60, a.ghost_y + a.cue_dy * 60);
  }
  ctx.restore();
}

function drawStick(cue) {
  const d = aimDir;
  const p = { x: -d.y, y: d.x };
  const start = B.radius + 5 + pull;
  const len = 320;
  const at = (dist, w) => [cue.x - d.x * dist + p.x * w, cue.y - d.y * dist + p.y * w];
  const width = (t) => 3 + 3.5 * t; // thin at the tip, thick at the butt
  const piece = (from, to, color) => {
    const w0 = width((from - start) / len), w1 = width((to - start) / len);
    ctx.beginPath();
    ctx.moveTo(...at(from, w0));
    ctx.lineTo(...at(to, w1));
    ctx.lineTo(...at(to, -w1));
    ctx.lineTo(...at(from, -w0));
    ctx.closePath();
    ctx.fillStyle = color;
    ctx.fill();
  };
  ctx.save();
  ctx.shadowColor = "rgba(0,0,0,0.4)";
  ctx.shadowBlur = 6;
  ctx.shadowOffsetY = 4;
  piece(start, start + len, "#d9a35f"); // shaft
  ctx.shadowColor = "transparent";
  piece(start + len * 0.65, start + len, "#3b1f0e"); // butt
  piece(start, start + 6, "#3f78c4"); // chalked tip
  piece(start + 6, start + 14, "#f3efe4"); // ferrule
  ctx.restore();
}

function drawPower() {
  const x = 350, y = 558, w = 300, h = 14;
  const frac = pull / MAX_PULL;
  fillRound(x, y, w, h, 7, "rgba(0,0,0,0.35)");
  const g = ctx.createLinearGradient(x, 0, x + w, 0);
  g.addColorStop(0, "#4ade80");
  g.addColorStop(0.6, "#facc15");
  g.addColorStop(1, "#ef4444");
  if (frac > 0) fillRound(x, y, w * frac, h, 7, g);
}
