//// Billiards physics: a pool table simulated in Gleam.
////
//// billiards_canvas.mjs owns the frame loop, the mouse and the drawing, and
//// calls into this module for everything that moves: friction, ball-to-ball
//// collisions, cushion bounces, pockets and the aiming prediction.
////
//// Units are canvas pixels and seconds. The canvas is 1000 x 600.

import gleam/float
import gleam/int
import gleam/list

// ── Table geometry ────────────────────────────────────────────────────────────

/// Edges of the playing surface (where the cushions are).
pub const left = 70.0

pub const right = 930.0

pub const top = 70.0

pub const bottom = 490.0

pub const radius = 11.0

// ── Physics tuning ────────────────────────────────────────────────────────────

/// Rolling friction: how quickly a ball loses speed (pixels/second²).
const friction = 160.0

/// Below this speed a ball is treated as stopped.
const stop_speed = 6.0

/// Fraction of speed kept when bouncing off a cushion.
const cushion_bounce = 0.75

/// Fraction of closing speed kept in a ball-to-ball collision (1.0 = perfect).
const ball_bounce = 0.96

/// Cue ball speed at full power.
const max_speed = 1600.0

/// Small steps per frame, so fast balls can't jump through each other.
const substeps = 8

/// Seconds a ball takes to shrink and vanish into a pocket.
const sink_time = 0.35

// ── Types ─────────────────────────────────────────────────────────────────────

pub type Pocket {
  Pocket(x: Float, y: Float, r: Float)
}

pub type BallState {
  OnTable
  /// Dropping into the pocket centred at (px, py); t seconds since it fell.
  Sinking(px: Float, py: Float, t: Float)
  Pocketed
}

/// num 0 is the cue ball, 1-7 solids, 8 the eight ball, 9-15 stripes.
pub type Ball {
  Ball(num: Int, x: Float, y: Float, vx: Float, vy: Float, state: BallState)
}

pub type Game {
  Game(balls: List(Ball))
}

/// What the canvas needs to draw one ball. scale shrinks from 1.0 to 0.0
/// while the ball sinks.
pub type BallView {
  BallView(num: Int, x: Float, y: Float, scale: Float)
}

/// The aiming prediction. ghost is where the cue ball will be when it
/// first touches something. If hit is True it touches the ball at target,
/// which then travels along obj_d, while the cue ball glances off along
/// cue_d. If hit is False it reaches a cushion and cue_d is the rebound.
pub type Aim {
  Aim(
    ghost_x: Float,
    ghost_y: Float,
    hit: Bool,
    target_x: Float,
    target_y: Float,
    obj_dx: Float,
    obj_dy: Float,
    cue_dx: Float,
    cue_dy: Float,
  )
}

pub fn pockets() -> List(Pocket) {
  let mid = { left +. right } /. 2.0
  [
    Pocket(left -. 4.0, top -. 4.0, 24.0),
    Pocket(mid, top -. 8.0, 21.0),
    Pocket(right +. 4.0, top -. 4.0, 24.0),
    Pocket(left -. 4.0, bottom +. 4.0, 24.0),
    Pocket(mid, bottom +. 8.0, 21.0),
    Pocket(right +. 4.0, bottom +. 4.0, 24.0),
  ]
}

// ── Setup ─────────────────────────────────────────────────────────────────────

fn mid_y() -> Float {
  { top +. bottom } /. 2.0
}

fn head_spot_x() -> Float {
  left +. { right -. left } *. 0.25
}

/// A fresh table: cue ball on the head spot, fifteen balls racked.
pub fn new_game() -> Game {
  Game([Ball(0, head_spot_x(), mid_y(), 0.0, 0.0, OnTable), ..rack()])
}

/// Standard 8-ball rack: 8 in the middle, a solid and a stripe in the back
/// corners.
const rack_order = [1, 9, 2, 10, 8, 3, 11, 7, 14, 4, 5, 13, 15, 6, 12]
/// The whole numbers from..to, inclusive.
fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

fn rack() -> List(Ball) {
  let apex_x = left +. { right -. left } *. 0.72
  // A tiny gap so racked balls don't start overlapping.
  let dx = radius *. 2.0 *. 0.866 +. 0.5
  let dy = radius *. 2.0 +. 0.5
  let spots =
    list.flat_map(range(0, 4), fn(row) {
      list.map(range(0, row), fn(k) {
        let r = int.to_float(row)
        #(apex_x +. r *. dx, mid_y() +. { int.to_float(k) -. r /. 2.0 } *. dy)
      })
    })
  list.map2(rack_order, spots, fn(num, spot) {
    Ball(num, spot.0, spot.1, 0.0, 0.0, OnTable)
  })
}

// ── Queries used by the canvas ────────────────────────────────────────────────

pub fn ball_views(game: Game) -> List(BallView) {
  list.filter_map(game.balls, fn(b) {
    case b.state {
      OnTable -> Ok(BallView(b.num, b.x, b.y, 1.0))
      Sinking(_, _, t) ->
        Ok(BallView(b.num, b.x, b.y, float.max(0.0, 1.0 -. t /. sink_time)))
      Pocketed -> Error(Nil)
    }
  })
}

/// True when nothing is moving or sinking, so the player can shoot.
pub fn all_stopped(game: Game) -> Bool {
  list.all(game.balls, fn(b) {
    case b.state {
      OnTable -> b.vx == 0.0 && b.vy == 0.0
      Sinking(..) -> False
      Pocketed -> True
    }
  })
}

// ── Shooting ──────────────────────────────────────────────────────────────────

/// Strike the cue ball in direction (dx, dy) with power from 0.0 to 1.0.
/// Ignored while balls are still moving.
pub fn shoot(game: Game, dx: Float, dy: Float, power: Float) -> Game {
  let #(ux, uy) = normalize(dx, dy)
  case all_stopped(game) && { ux != 0.0 || uy != 0.0 } {
    False -> game
    True -> {
      let speed = float.clamp(power, 0.0, 1.0) *. max_speed
      Game(
        list.map(game.balls, fn(b) {
          case b.num == 0 && b.state == OnTable {
            True -> Ball(..b, vx: ux *. speed, vy: uy *. speed)
            False -> b
          }
        }),
      )
    }
  }
}

// ── Simulation ────────────────────────────────────────────────────────────────

/// Advance the table by dt seconds.
pub fn step(game: Game, dt: Float) -> Game {
  let h = dt /. int.to_float(substeps)
  game
  |> repeat_substep(h, substeps)
  |> respawn_cue
}

fn repeat_substep(game: Game, h: Float, n: Int) -> Game {
  case n {
    0 -> game
    _ -> repeat_substep(substep(game, h), h, n - 1)
  }
}

fn substep(game: Game, h: Float) -> Game {
  game.balls
  |> list.map(advance(_, h))
  |> collide_all
  // Pocketed balls leave the table, except the cue ball, which comes back.
  |> list.filter(fn(b) { b.state != Pocketed || b.num == 0 })
  |> Game
}

fn advance(b: Ball, h: Float) -> Ball {
  case b.state {
    Pocketed -> b
    Sinking(px, py, t) -> {
      let t = t +. h
      case t >=. sink_time {
        True -> Ball(..b, x: px, y: py, state: Pocketed)
        False -> {
          // Glide toward the pocket centre while shrinking.
          let k = float.min(1.0, h *. 10.0)
          Ball(
            ..b,
            x: b.x +. { px -. b.x } *. k,
            y: b.y +. { py -. b.y } *. k,
            state: Sinking(px, py, t),
          )
        }
      }
    }
    OnTable ->
      b
      |> apply_friction(h)
      |> move(h)
      |> cushions
      |> check_pockets
  }
}

fn apply_friction(b: Ball, h: Float) -> Ball {
  let speed = length(b.vx, b.vy)
  case speed <. stop_speed {
    True -> Ball(..b, vx: 0.0, vy: 0.0)
    False -> {
      let k = float.max(0.0, speed -. friction *. h) /. speed
      Ball(..b, vx: b.vx *. k, vy: b.vy *. k)
    }
  }
}

fn move(b: Ball, h: Float) -> Ball {
  Ball(..b, x: b.x +. b.vx *. h, y: b.y +. b.vy *. h)
}

/// Bounce off the four cushions, except in a pocket's mouth, where the ball
/// is allowed through so it can drop.
fn cushions(b: Ball) -> Ball {
  case near_pocket(b) {
    True -> b
    False -> {
      let b = case b.x <. left +. radius && b.vx <. 0.0 {
        True -> Ball(..b, x: left +. radius, vx: 0.0 -. b.vx *. cushion_bounce)
        False -> b
      }
      let b = case b.x >. right -. radius && b.vx >. 0.0 {
        True ->
          Ball(..b, x: right -. radius, vx: 0.0 -. b.vx *. cushion_bounce)
        False -> b
      }
      let b = case b.y <. top +. radius && b.vy <. 0.0 {
        True -> Ball(..b, y: top +. radius, vy: 0.0 -. b.vy *. cushion_bounce)
        False -> b
      }
      case b.y >. bottom -. radius && b.vy >. 0.0 {
        True ->
          Ball(..b, y: bottom -. radius, vy: 0.0 -. b.vy *. cushion_bounce)
        False -> b
      }
    }
  }
}

fn near_pocket(b: Ball) -> Bool {
  list.any(pockets(), fn(p) {
    distance(b.x, b.y, p.x, p.y) <. p.r +. radius +. 6.0
  })
}

/// Start sinking if the ball is over a pocket or has gone past the cushion
/// line (which can only happen through a pocket mouth).
fn check_pockets(b: Ball) -> Ball {
  let off_table =
    b.x <. left -. 2.0
    || b.x >. right +. 2.0
    || b.y <. top -. 2.0
    || b.y >. bottom +. 2.0
  let by_distance =
    list.sort(pockets(), fn(p, q) {
      float.compare(distance(b.x, b.y, p.x, p.y), distance(b.x, b.y, q.x, q.y))
    })
  case by_distance {
    [p, ..] ->
      case off_table || distance(b.x, b.y, p.x, p.y) <. p.r {
        True -> Ball(..b, vx: 0.0, vy: 0.0, state: Sinking(p.x, p.y, 0.0))
        False -> b
      }
    [] -> b
  }
}

/// Check every pair of balls once.
fn collide_all(balls: List(Ball)) -> List(Ball) {
  case balls {
    [] -> []
    [first, ..rest] -> {
      let #(first, rest) = list.map_fold(rest, first, collide)
      [first, ..collide_all(rest)]
    }
  }
}

/// Equal-mass collision: the balls swap the part of their velocity that
/// points along the line between their centres (minus a little energy).
fn collide(a: Ball, b: Ball) -> #(Ball, Ball) {
  case a.state, b.state {
    OnTable, OnTable -> {
      let dx = b.x -. a.x
      let dy = b.y -. a.y
      let d = length(dx, dy)
      let min_d = radius *. 2.0
      case d <. min_d && d >. 0.0 {
        False -> #(a, b)
        True -> {
          let nx = dx /. d
          let ny = dy /. d
          // Push them apart so they don't stay overlapped.
          let push = { min_d -. d } /. 2.0
          let a = Ball(..a, x: a.x -. nx *. push, y: a.y -. ny *. push)
          let b = Ball(..b, x: b.x +. nx *. push, y: b.y +. ny *. push)
          let closing = { a.vx -. b.vx } *. nx +. { a.vy -. b.vy } *. ny
          case closing >. 0.0 {
            False -> #(a, b)
            True -> {
              let j = closing *. { 1.0 +. ball_bounce } /. 2.0
              #(
                Ball(..a, vx: a.vx -. j *. nx, vy: a.vy -. j *. ny),
                Ball(..b, vx: b.vx +. j *. nx, vy: b.vy +. j *. ny),
              )
            }
          }
        }
      }
    }
    _, _ -> #(a, b)
  }
}

/// After a scratch, once everything stops, put the cue ball back on the
/// head spot (moved up if another ball is in the way).
fn respawn_cue(game: Game) -> Game {
  let cue_gone =
    list.any(game.balls, fn(b) { b.num == 0 && b.state == Pocketed })
  case cue_gone && all_stopped(game) {
    False -> game
    True -> {
      let #(x, y) = free_spot(game, head_spot_x(), mid_y(), 0)
      Game(
        list.map(game.balls, fn(b) {
          case b.num {
            0 -> Ball(0, x, y, 0.0, 0.0, OnTable)
            _ -> b
          }
        }),
      )
    }
  }
}

fn free_spot(game: Game, x: Float, y: Float, tries: Int) -> #(Float, Float) {
  let blocked =
    list.any(game.balls, fn(b) {
      b.num != 0
      && b.state == OnTable
      && distance(b.x, b.y, x, y) <. radius *. 2.2
    })
  case blocked && tries < 10 {
    True -> free_spot(game, x, y -. radius *. 2.5, tries + 1)
    False -> #(x, y)
  }
}

// ── Aiming prediction ─────────────────────────────────────────────────────────

/// Where a shot in direction (dx, dy) would go.
pub fn aim(game: Game, dx: Float, dy: Float) -> Aim {
  let nothing = Aim(0.0, 0.0, False, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
  let #(ux, uy) = normalize(dx, dy)
  let cue = list.find(game.balls, fn(b) { b.num == 0 && b.state == OnTable })
  case cue, ux != 0.0 || uy != 0.0 {
    Ok(cue), True -> {
      // The cue ball touches another ball when their centres are 2r apart,
      // so treat each target as a circle of radius 2r and cast a ray at it.
      let reach2 = 4.0 *. radius *. radius
      let hits =
        list.filter_map(game.balls, fn(b) {
          case b.num != 0 && b.state == OnTable {
            False -> Error(Nil)
            True -> {
              let mx = b.x -. cue.x
              let my = b.y -. cue.y
              let along = mx *. ux +. my *. uy
              let side2 = mx *. mx +. my *. my -. along *. along
              case along >. 0.0 && side2 <. reach2 {
                False -> Error(Nil)
                True -> Ok(#(along -. sqrt(reach2 -. side2), b))
              }
            }
          }
        })
      case list.sort(hits, fn(p, q) { float.compare(p.0, q.0) }) {
        [#(t, target), ..] -> {
          let gx = cue.x +. ux *. t
          let gy = cue.y +. uy *. t
          // Object ball leaves along the line of centres; the cue ball
          // glances off at 90 degrees to it.
          let #(nx, ny) = normalize(target.x -. gx, target.y -. gy)
          let dot = ux *. nx +. uy *. ny
          let #(cx, cy) = normalize(ux -. dot *. nx, uy -. dot *. ny)
          Aim(gx, gy, True, target.x, target.y, nx, ny, cx, cy)
        }
        [] -> wall_aim(cue, ux, uy)
      }
    }
    _, _ -> nothing
  }
}

fn wall_aim(cue: Ball, ux: Float, uy: Float) -> Aim {
  let far = 1.0e9
  let tx = case ux >. 0.0, ux <. 0.0 {
    True, _ -> { right -. radius -. cue.x } /. ux
    _, True -> { left +. radius -. cue.x } /. ux
    _, _ -> far
  }
  let ty = case uy >. 0.0, uy <. 0.0 {
    True, _ -> { bottom -. radius -. cue.y } /. uy
    _, True -> { top +. radius -. cue.y } /. uy
    _, _ -> far
  }
  let t = float.min(tx, ty)
  let #(rx, ry) = case tx <. ty {
    True -> #(0.0 -. ux, uy)
    False -> #(ux, 0.0 -. uy)
  }
  Aim(cue.x +. ux *. t, cue.y +. uy *. t, False, 0.0, 0.0, 0.0, 0.0, rx, ry)
}

// ── Vector helpers ────────────────────────────────────────────────────────────

fn sqrt(x: Float) -> Float {
  case float.square_root(x) {
    Ok(r) -> r
    Error(_) -> 0.0
  }
}

fn length(x: Float, y: Float) -> Float {
  sqrt(x *. x +. y *. y)
}

fn distance(x1: Float, y1: Float, x2: Float, y2: Float) -> Float {
  length(x2 -. x1, y2 -. y1)
}

fn normalize(x: Float, y: Float) -> #(Float, Float) {
  let l = length(x, y)
  case l >. 0.0 {
    True -> #(x /. l, y /. l)
    False -> #(0.0, 0.0)
  }
}
