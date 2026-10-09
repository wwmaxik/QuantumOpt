//! QuantumCore: High-performance Rust native engine offloader for Balatro (LuaJIT FFI)
//! Offloads heavy physics, kinematics, BigNum/OmegaNum, and collision calculations.

use std::time::Instant;

// =========================================================================
// 1. High-precision Timer
// =========================================================================
static mut START_TIME: Option<Instant> = None;

#[no_mangle]
pub extern "C" fn quantum_init() -> i32 {
    unsafe {
        START_TIME = Some(Instant::now());
    }
    1
}

#[no_mangle]
pub extern "C" fn quantum_get_time() -> f64 {
    unsafe {
        match START_TIME {
            Some(t) => t.elapsed().as_secs_f64(),
            None => {
                START_TIME = Some(Instant::now());
                0.0
            }
        }
    }
}

// =========================================================================
// 2. Fast OmegaNum / Talisman BigNum Operations
// =========================================================================
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TalismanOmega {
    pub asize: f64,
    pub number: f64,
    pub sign: i8,
    pub _nan: bool,
    pub _inf: bool,
}

impl TalismanOmega {
    #[inline(always)]
    pub const fn zero() -> Self {
        Self {
            asize: 0.0,
            number: 0.0,
            sign: 1,
            _nan: false,
            _inf: false,
        }
    }

    #[inline(always)]
    pub fn from_f64(v: f64) -> Self {
        if v.is_nan() {
            return Self { asize: 0.0, number: 0.0, sign: 0, _nan: true, _inf: false };
        }
        if v.is_infinite() {
            return Self { asize: 0.0, number: 0.0, sign: if v > 0.0 { 1 } else { -1 }, _nan: false, _inf: true };
        }
        let sign = if v < 0.0 { -1 } else { 1 };
        let abs_v = v.abs();
        if abs_v == 0.0 {
            Self::zero()
        } else if abs_v < 1e15 {
            Self { asize: 1.0, number: abs_v, sign, _nan: false, _inf: false }
        } else {
            Self { asize: 2.0, number: abs_v.log10(), sign, _nan: false, _inf: false }
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn quantum_omega_mul(
    a: *const TalismanOmega,
    b: *const TalismanOmega,
    out: *mut TalismanOmega,
) {
    if a.is_null() || b.is_null() || out.is_null() { return; }
    let a = *a;
    let b = *b;

    if a._nan || b._nan {
        *out = TalismanOmega { asize: 0.0, number: 0.0, sign: 0, _nan: true, _inf: false };
        return;
    }
    if a.asize == 0.0 || b.asize == 0.0 {
        *out = TalismanOmega::zero();
        return;
    }

    let sign = (a.sign * b.sign) as i8;

    // Both normal numbers (< 1e15)
    if a.asize == 1.0 && b.asize == 1.0 {
        let val = a.number * b.number;
        if val < 1e15 {
            *out = TalismanOmega { asize: 1.0, number: val, sign, _nan: false, _inf: false };
        } else {
            *out = TalismanOmega { asize: 2.0, number: val.log10(), sign, _nan: false, _inf: false };
        }
        return;
    }

    // Level 2 (10^x)
    let log_a = if a.asize == 1.0 { a.number.log10() } else if a.asize == 2.0 { a.number } else { a.number };
    let log_b = if b.asize == 1.0 { b.number.log10() } else if b.asize == 2.0 { b.number } else { b.number };

    if a.asize <= 2.0 && b.asize <= 2.0 {
        let new_log = log_a + log_b;
        if new_log < 1e15 {
            *out = TalismanOmega { asize: 2.0, number: new_log, sign, _nan: false, _inf: false };
        } else {
            *out = TalismanOmega { asize: 3.0, number: new_log.log10(), sign, _nan: false, _inf: false };
        }
        return;
    }

    // High towers: dominant wins
    if a.asize > b.asize {
        *out = TalismanOmega { asize: a.asize, number: a.number, sign, _nan: false, _inf: false };
    } else if b.asize > a.asize {
        *out = TalismanOmega { asize: b.asize, number: b.number, sign, _nan: false, _inf: false };
    } else {
        *out = TalismanOmega { asize: a.asize, number: a.number.max(b.number), sign, _nan: false, _inf: false };
    }
}

#[no_mangle]
pub unsafe extern "C" fn quantum_omega_add(
    a: *const TalismanOmega,
    b: *const TalismanOmega,
    out: *mut TalismanOmega,
) {
    if a.is_null() || b.is_null() || out.is_null() { return; }
    let a = *a;
    let b = *b;

    if a.asize == 0.0 { *out = b; return; }
    if b.asize == 0.0 { *out = a; return; }

    // Same sign level 1
    if a.asize == 1.0 && b.asize == 1.0 && a.sign == b.sign {
        let val = a.number + b.number;
        if val < 1e15 {
            *out = TalismanOmega { asize: 1.0, number: val, sign: a.sign, _nan: false, _inf: false };
        } else {
            *out = TalismanOmega { asize: 2.0, number: val.log10(), sign: a.sign, _nan: false, _inf: false };
        }
        return;
    }

    // Level 2 / large magnitude: larger dominates if difference > 15 in exponent
    let _max_asize = a.asize.max(b.asize);
    if a.asize != b.asize {
        *out = if a.asize > b.asize { a } else { b };
        return;
    }

    // Equal asize == 2: log10(10^a + 10^b) = max + log10(1 + 10^(-|a-b|))
    let diff = (a.number - b.number).abs();
    if diff > 15.0 {
        *out = if a.number >= b.number { a } else { b };
    } else {
        let max_val = a.number.max(b.number);
        let adjustment = (1.0 + 10.0_f64.powf(-diff)).log10();
        *out = TalismanOmega { asize: 2.0, number: max_val + adjustment, sign: a.sign, _nan: false, _inf: false };
    }
}

#[no_mangle]
pub unsafe extern "C" fn quantum_omega_pow(
    a: *const TalismanOmega,
    b: *const TalismanOmega,
    out: *mut TalismanOmega,
) {
    if a.is_null() || b.is_null() || out.is_null() { return; }
    let a = *a;
    let b = *b;

    if b.asize == 0.0 {
        *out = TalismanOmega { asize: 1.0, number: 1.0, sign: 1, _nan: false, _inf: false };
        return;
    }
    if a.asize == 0.0 {
        *out = TalismanOmega::zero();
        return;
    }

    // Normal pow: a^b = 10^(b * log10(a))
    let log_a = if a.asize == 1.0 { a.number.log10() } else { a.number };
    let mult = if b.asize == 1.0 { b.number } else { 10.0_f64.powf(b.number.min(300.0)) };
    let new_log = log_a * mult;

    if new_log < 15.0 && a.asize == 1.0 && b.asize == 1.0 {
        let res = a.number.powf(b.number);
        *out = TalismanOmega { asize: 1.0, number: res, sign: 1, _nan: false, _inf: false };
    } else if new_log < 1e15 {
        *out = TalismanOmega { asize: 2.0, number: new_log, sign: 1, _nan: false, _inf: false };
    } else {
        *out = TalismanOmega { asize: 3.0, number: new_log.log10(), sign: 1, _nan: false, _inf: false };
    }
}

#[no_mangle]
pub unsafe extern "C" fn quantum_omega_cmp(
    a: *const TalismanOmega,
    b: *const TalismanOmega,
) -> i32 {
    if a.is_null() || b.is_null() { return 0; }
    let a = *a;
    let b = *b;

    if a.sign != b.sign {
        return if a.sign > b.sign { 1 } else { -1 };
    }
    let sign = a.sign as i32;
    if a.asize != b.asize {
        return if a.asize > b.asize { sign } else { -sign };
    }
    if (a.number - b.number).abs() < 1e-12 {
        0
    } else if a.number > b.number {
        sign
    } else {
        -sign
    }
}

// =========================================================================
// 3. Ultra-Fast Moveables Batch Physics / Kinematics (SIMD-Friendly)
// =========================================================================
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CMoveable {
    pub tx: f32,
    pub ty: f32,
    pub tw: f32,
    pub th: f32,
    pub tr: f32,
    pub tscale: f32,

    pub vtx: f32,
    pub vty: f32,
    pub vtw: f32,
    pub vth: f32,
    pub vtr: f32,
    pub vtscale: f32,

    pub vx: f32,
    pub vy: f32,
    pub vr: f32,
    pub vscale: f32,

    pub pinch_x: bool,
    pub pinch_y: bool,
    pub stationary: bool,

    pub shadow_px: f32,
    pub extra_scale: f32,
    pub extra_r: f32,
}

#[no_mangle]
pub unsafe extern "C" fn quantum_batch_step_moveables(
    items: *mut CMoveable,
    count: usize,
    dt: f32,
    exp_xy: f32,
    exp_scale: f32,
    exp_r: f32,
    max_vel: f32,
    room_w: f32,
) {
    if items.is_null() || count == 0 { return; }
    let slice = std::slice::from_raw_parts_mut(items, count);

    let max_vel_sq = max_vel * max_vel;
    let inv_room_half = if room_w > 0.0 { 1.5 / (room_w * 0.5) } else { 0.0 };
    let room_half = room_w * 0.5;

    for m in slice.iter_mut() {
        m.stationary = true;

        // --- 1. move_xy ---
        let dx = m.tx - m.vtx;
        let dy = m.ty - m.vty;
        let moving_xy = dx.abs() > 0.001 || dy.abs() > 0.001 || m.vx.abs() > 0.001 || m.vy.abs() > 0.001;

        if moving_xy {
            m.vx = exp_xy * m.vx + (1.0 - exp_xy) * dx * (35.0 * dt);
            m.vy = exp_xy * m.vy + (1.0 - exp_xy) * dy * (35.0 * dt);

            let vel_sq = m.vx * m.vx + m.vy * m.vy;
            if vel_sq > max_vel_sq {
                let inv_len = max_vel / vel_sq.sqrt();
                m.vx *= inv_len;
                m.vy *= inv_len;
            }

            m.vtx += m.vx;
            m.vty += m.vy;

            if (m.vtx - m.tx).abs() < 0.01 && m.vx.abs() < 0.01 {
                m.vtx = m.tx;
                m.vx = 0.0;
            }
            if (m.vty - m.ty).abs() < 0.01 && m.vy.abs() < 0.01 {
                m.vty = m.ty;
                m.vy = 0.0;
            }
            m.stationary = false;
        }

        // --- 2. move_scale ---
        let des_scale = m.tscale + m.extra_scale;
        let dscale = des_scale - m.vtscale;
        if dscale.abs() > 0.0005 || m.vscale.abs() > 0.0005 {
            m.vscale = exp_scale * m.vscale + (1.0 - exp_scale) * dscale;
            m.vtscale += m.vscale;
            m.stationary = false;
        }

        // --- 3. move_wh (pinch / flip) ---
        let wh_changing = (m.tw != m.vtw && !m.pinch_x)
            || (m.th != m.vth && !m.pinch_y)
            || (m.vtw > 0.0 && m.pinch_x)
            || (m.vth > 0.0 && m.pinch_y);

        if wh_changing {
            let step = 8.0 * dt;
            let dir_x = if m.pinch_x { -1.0 } else { 1.0 };
            let dir_y = if m.pinch_y { -1.0 } else { 1.0 };

            m.vtw = (m.vtw + step * dir_x * m.tw).clamp(0.0, m.tw);
            m.vth = (m.vth + step * dir_y * m.th).clamp(0.0, m.th);
            m.stationary = false;
        }

        // --- 4. move_r ---
        let des_r = m.tr + (0.015 * m.vx / dt.max(0.0001)) + m.extra_r;
        let dr = des_r - m.vtr;
        if dr.abs() > 0.0005 || m.vr.abs() > 0.0005 {
            m.vr = exp_r * m.vr + (1.0 - exp_r) * dr;
            m.vtr += m.vr;
            if (m.vtr - m.tr).abs() < 0.001 && m.vr.abs() < 0.001 {
                m.vtr = m.tr;
                m.vr = 0.0;
            }
            m.stationary = false;
        }

        // --- 5. parallax ---
        if inv_room_half > 0.0 {
            m.shadow_px = (m.tx + m.tw * 0.5 - room_half) * inv_room_half;
        }
    }
}

// Single-item fast physics step for inline Lua call
#[no_mangle]
pub unsafe extern "C" fn quantum_step_xy(
    tx: f32, ty: f32,
    vtx: *mut f32, vty: *mut f32,
    vx: *mut f32, vy: *mut f32,
    dt: f32,
    exp_xy: f32,
    max_vel: f32,
    out_stationary: *mut bool,
) {
    if vtx.is_null() || vty.is_null() || vx.is_null() || vy.is_null() { return; }
    let cur_vtx = *vtx;
    let cur_vty = *vty;
    let mut cur_vx = *vx;
    let mut cur_vy = *vy;

    let dx = tx - cur_vtx;
    let dy = ty - cur_vty;

    if dx.abs() > 0.001 || dy.abs() > 0.001 || cur_vx.abs() > 0.001 || cur_vy.abs() > 0.001 {
        cur_vx = exp_xy * cur_vx + (1.0 - exp_xy) * dx * (35.0 * dt);
        cur_vy = exp_xy * cur_vy + (1.0 - exp_xy) * dy * (35.0 * dt);

        let vel_sq = cur_vx * cur_vx + cur_vy * cur_vy;
        let max_vel_sq = max_vel * max_vel;
        if vel_sq > max_vel_sq {
            let inv_len = max_vel / vel_sq.sqrt();
            cur_vx *= inv_len;
            cur_vy *= inv_len;
        }

        let mut next_x = cur_vtx + cur_vx;
        let mut next_y = cur_vty + cur_vy;

        if (next_x - tx).abs() < 0.01 && cur_vx.abs() < 0.01 {
            next_x = tx;
            cur_vx = 0.0;
        }
        if (next_y - ty).abs() < 0.01 && cur_vy.abs() < 0.01 {
            next_y = ty;
            cur_vy = 0.0;
        }

        *vtx = next_x;
        *vty = next_y;
        *vx = cur_vx;
        *vy = cur_vy;
        if !out_stationary.is_null() { *out_stationary = false; }
    } else {
        if !out_stationary.is_null() { *out_stationary = true; }
    }
}

// =========================================================================
// 4. Batch Collision Detection for Cursor & Cards
// =========================================================================
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct CRect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub r: f32,
}

#[no_mangle]
pub unsafe extern "C" fn quantum_point_in_rect(
    r: *const CRect,
    px: f32,
    py: f32,
    buffer: f32,
) -> bool {
    if r.is_null() { return false; }
    let rect = *r;

    if rect.r.abs() < 0.01 {
        px >= rect.x - buffer
            && px <= rect.x + rect.w + buffer
            && py >= rect.y - buffer
            && py <= rect.y + rect.h + buffer
    } else {
        // Rotated point test
        let angle = -(rect.r + std::f32::consts::FRAC_PI_2);
        let cos = angle.cos();
        let sin = angle.sin();

        let cx = rect.x + 0.5 * rect.w;
        let cy = rect.y + 0.5 * rect.h;

        let dx = px - cx;
        let dy = py - cy;

        let local_x = dx * cos - dy * sin;
        let local_y = dx * sin + dy * cos;

        let hw = 0.5 * rect.w + buffer;
        let hh = 0.5 * rect.h + buffer;

        local_x.abs() <= hw && local_y.abs() <= hh
    }
}

#[no_mangle]
pub unsafe extern "C" fn quantum_batch_point_collision(
    rects: *const CRect,
    count: usize,
    px: f32,
    py: f32,
    buffer: f32,
    out_indices: *mut i32,
    max_out: usize,
) -> usize {
    if rects.is_null() || out_indices.is_null() || count == 0 || max_out == 0 {
        return 0;
    }
    let rect_slice = std::slice::from_raw_parts(rects, count);
    let mut hit_count = 0;

    for (idx, r) in rect_slice.iter().enumerate() {
        if quantum_point_in_rect(r, px, py, buffer) {
            *out_indices.add(hit_count) = idx as i32;
            hit_count += 1;
            if hit_count >= max_out {
                break;
            }
        }
    }
    hit_count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_omega_mul() {
        let a = TalismanOmega::from_f64(100.0);
        let b = TalismanOmega::from_f64(20.0);
        let mut out = TalismanOmega::zero();
        unsafe {
            quantum_omega_mul(&a, &b, &mut out);
        }
        assert_eq!(out.number, 2000.0);
        assert_eq!(out.asize, 1.0);
    }

    #[test]
    fn test_point_collision() {
        let rect = CRect { x: 10.0, y: 10.0, w: 50.0, h: 50.0, r: 0.0 };
        unsafe {
            assert!(quantum_point_in_rect(&rect, 25.0, 25.0, 0.0));
            assert!(!quantum_point_in_rect(&rect, 100.0, 100.0, 0.0));
        }
    }
}
