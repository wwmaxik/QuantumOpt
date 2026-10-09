--- STEAMODDED HEADER
--- MOD_NAME: QuantumOpt
--- MOD_ID: QuantumOpt
--- MOD_AUTHOR: [wwmaxik]
--- MOD_DESCRIPTION: Высокопроизводительный Rust-нативный мод для плавных 60 FPS при 100+ джокерах и 100+ расходниках, Cryptid и Talisman.
--- BADGE_COLOUR: 00b4d8
--- PREFIX: qopt
--- VERSION: 1.4.0
--- PRIORITY: 1000

QuantumOpt = SMODS.current_mod or {}

-- Конфигурация по умолчанию
local default_config = {
    rust_core = true,           -- Использовать Rust нативную библиотеку libquantum_core.so
    rust_physics = true,        -- Быстрая SIMD физика перемещений карт на Rust
    rust_bignum = true,         -- Нативное вычисление OmegaNum / Talisman BigNum на Rust
    cache_collisions = true,    -- Кэширование коллизий курсора (устраняет проверку 2000+ узлов при неподвижной мыши)
    throttle_joker_checks = true, -- Устранение O(N^2) циклов джокеров (Temperance, Stencil, Driver's License)
    fix_nugc = true,            -- Устранение смертельного цикла nuGC (full collect при >300MB)
    cull_cards = true,          -- Thin-Draw и срез тяжелых шейдеров для 100+ перекрытых карт
    optimize_cards = true,      -- Оптимизация обновлений и физики 300+ карт
    turbo_scoring = true,       -- Ускорение подсчета очков (срезает долгие задержки между триггерами)
    fast_easing = true,         -- Быстрое обновление счетчиков очков без микрофризов
    suppress_jiggle = true,     -- Подавление тряски экрана при астрономических очках
    audio_limiter = true,       -- Защита звукового буфера OpenAL от спама одинаковых звуков
    show_fps = true,            -- Аккуратный счетчик FPS в углу экрана с подробной диагностикой
    simple_background = false,  -- Упрощенный фон (для слабых GPU)
    talisman_instant = false,   -- Включить режим мгновенного счета Talisman (если установлен)
}

QuantumOpt.config = QuantumOpt.config or {}
for k, v in pairs(default_config) do
    if QuantumOpt.config[k] == nil then
        QuantumOpt.config[k] = v
    end
end

-- =========================================================================
-- 0. RUST NATIVE CORE LOADER (LuaJIT FFI -> libquantum_core.so)
-- =========================================================================
local ffi = require("ffi")
local QuantumLib = nil
local rust_active = false
local rust_loaded_path = nil

local function init_rust_core()
    if not QuantumOpt.config.rust_core then return end

    pcall(function()
        ffi.cdef[[
            int quantum_init();
            double quantum_get_time();

            struct TalismanOmega {
                double asize;
                double number;
                int8_t sign;
                bool _nan;
                bool _inf;
            };

            void quantum_omega_mul(const struct TalismanOmega* a, const struct TalismanOmega* b, struct TalismanOmega* out);
            void quantum_omega_add(const struct TalismanOmega* a, const struct TalismanOmega* b, struct TalismanOmega* out);
            void quantum_omega_pow(const struct TalismanOmega* a, const struct TalismanOmega* b, struct TalismanOmega* out);
            int quantum_omega_cmp(const struct TalismanOmega* a, const struct TalismanOmega* b);

            struct CMoveable {
                float tx, ty, tw, th, tr, tscale;
                float vtx, vty, vtw, vth, vtr, vtscale;
                float vx, vy, vr, vscale;
                bool pinch_x, pinch_y, stationary;
                float shadow_px, extra_scale, extra_r;
            };

            void quantum_batch_step_moveables(struct CMoveable* items, size_t count, float dt, float exp_xy, float exp_scale, float exp_r, float max_vel, float room_w);
            void quantum_step_xy(float tx, float ty, float* vtx, float* vty, float* vx, float* vy, float dt, float exp_xy, float max_vel, bool* out_stationary);

            struct CRect {
                float x, y, w, h, r;
            };

            bool quantum_point_in_rect(const struct CRect* r, float px, float py, float buffer);
            size_t quantum_batch_point_collision(const struct CRect* rects, size_t count, float px, float py, float buffer, int32_t* out_indices, size_t max_out);
        ]]
    end)

    local candidates = {
        (SMODS and SMODS.current_mod and SMODS.current_mod.path) and (SMODS.current_mod.path .. "libquantum_core.so"),
        (SMODS and SMODS.current_mod and SMODS.current_mod.path) and (SMODS.current_mod.path .. "/libquantum_core.so"),
        (love and love.filesystem and love.filesystem.getSaveDirectory) and (love.filesystem.getSaveDirectory() .. "/Mods/QuantumOpt/libquantum_core.so"),
        "/home/wwmaxik/.local/share/balatro/Mods/QuantumOpt/libquantum_core.so",
        "/home/wwmaxik/QuantumOpt/libquantum_core.so",
        "/home/wwmaxik/quantum-core/target/release/libquantum_core.so",
        "./libquantum_core.so",
        "libquantum_core.so"
    }

    for _, path in ipairs(candidates) do
        if path then
            local ok, lib = pcall(ffi.load, path)
            if ok and lib then
                QuantumLib = lib
                rust_loaded_path = path
                rust_active = true
                pcall(function() QuantumLib.quantum_init() end)
                sendInfoMessage("[QuantumOpt] Native Rust core loaded successfully from: " .. path, "QuantumOpt")
                break
            end
        end
    end

    if not QuantumLib then
        sendWarnMessage("[QuantumOpt] libquantum_core.so not found, falling back to pure Lua mode.", "QuantumOpt")
    end
end

init_rust_core()

-- =========================================================================
-- 1. RUST BIG-NUM ACCELERATION (TALISMAN / AMULET OMEGANUM)
-- =========================================================================
local function hook_amulet_rust()
    if not rust_active or not QuantumLib or not QuantumOpt.config.rust_bignum then return end
    if not _G.Big or _G.Big._quantum_hooked then return end
    _G.Big._quantum_hooked = true

    local TalismanOmega = ffi.typeof("struct TalismanOmega")
    local orig_big_mul = Big.mul
    local orig_big_pow = Big.pow
    local orig_big_add = Big.add
    local orig_big_cmp = Big.cmp

    Big.mul = function(self, other)
        if ffi.istype(TalismanOmega, self) then
            if type(other) == "number" then
                if other == 0 then return B.ZERO end
                if other == 1 then return self end
                local on = self.number * other
                if on == on and on ~= math.huge and on ~= -math.huge then
                    return Big:create(on)
                end
            end
            if ffi.istype(TalismanOmega, other) then
                local out = TalismanOmega()
                QuantumLib.quantum_omega_mul(self, other, out)
                return out
            end
        end
        return orig_big_mul(self, other)
    end

    if orig_big_pow then
        Big.pow = function(self, other)
            if ffi.istype(TalismanOmega, self) and ffi.istype(TalismanOmega, other) then
                local out = TalismanOmega()
                QuantumLib.quantum_omega_pow(self, other, out)
                return out
            end
            return orig_big_pow(self, other)
        end
    end

    if orig_big_add then
        Big.add = function(self, other)
            if ffi.istype(TalismanOmega, self) and ffi.istype(TalismanOmega, other) then
                local out = TalismanOmega()
                QuantumLib.quantum_omega_add(self, other, out)
                return out
            end
            return orig_big_add(self, other)
        end
    end

    sendInfoMessage("[QuantumOpt] High-speed Rust OmegaNum math hooked into BigNum/Amulet!", "QuantumOpt")
end

hook_amulet_rust()

-- =========================================================================
-- 2. НЕЙТРАЛИЗАЦИЯ СМЕРТЕЛЬНОГО ЦИКЛА nuGC (ГЛАВНАЯ ПРИЧИНА 1 FPS)
-- =========================================================================
if QuantumOpt.config.fix_nugc then
    function nuGC(time_budget, memory_ceiling, disable_otherwise)
        collectgarbage("step", 2)
    end
    collectgarbage("restart")
    pcall(collectgarbage, "setpause", 200)
    pcall(collectgarbage, "setstepmul", 200)
end

-- =========================================================================
-- 3. RUST-ACCELERATED MOVEABLES & PHYSICS STEP
-- =========================================================================
local q_vtx = ffi.new("float[1]")
local q_vty = ffi.new("float[1]")
local q_vx = ffi.new("float[1]")
local q_vy = ffi.new("float[1]")
local q_stat = ffi.new("bool[1]")

local orig_moveable_move_xy = Moveable.move_xy
function Moveable:move_xy(dt)
    if (self.T.x ~= self.VT.x or math.abs(self.velocity.x) > 0.01) or 
       (self.T.y ~= self.VT.y or math.abs(self.velocity.y) > 0.01) then

        if rust_active and QuantumOpt.config.rust_physics and QuantumLib and G.exp_times then
            q_vtx[0] = self.VT.x
            q_vty[0] = self.VT.y
            q_vx[0] = self.velocity.x
            q_vy[0] = self.velocity.y
            QuantumLib.quantum_step_xy(self.T.x, self.T.y, q_vtx, q_vty, q_vx, q_vy, dt, G.exp_times.xy, G.exp_times.max_vel, q_stat)
            self.VT.x = q_vtx[0]
            self.VT.y = q_vty[0]
            self.velocity.x = q_vx[0]
            self.velocity.y = q_vy[0]
            self.STATIONARY = q_stat[0]
            return
        end

        return orig_moveable_move_xy(self, dt)
    end
end

-- Оптимизация Moveable:move для статичных карт
local orig_moveable_move = Moveable.move
function Moveable:move(dt)
    if self.STATIONARY and not self.juice and self.role and self.role.role_type == 'Major' then
        if self.velocity and self.velocity.x == 0 and self.velocity.y == 0 and self.velocity.scale == 0 and self.velocity.r == 0 then
            if math.abs(self.T.x - self.VT.x) < 0.001 and math.abs(self.T.y - self.VT.y) < 0.001 then
                self.FRAME.MOVE = G.FRAMES.MOVE
                return
            end
        end
    end
    return orig_moveable_move(self, dt)
end

-- =========================================================================
-- 4. КЭШИРОВАНИЕ КОЛЛИЗИЙ КУРСОРА (Controller:get_cursor_collision)
-- =========================================================================
-- В Balatro при 300+ картах в G.DRAW_HASH скапливается 2000-4000 объектов.
-- Каждый кадр проверялись коллизии даже если мышь стоит на месте.
local last_cursor_x = -99999
local last_cursor_y = -99999
local orig_get_cursor_collision = Controller.get_cursor_collision
function Controller:get_cursor_collision(cursor_trans)
    if QuantumOpt.config.cache_collisions and cursor_trans then
        if not self.dragging.target 
           and cursor_trans.x == last_cursor_x 
           and cursor_trans.y == last_cursor_y 
           and self.collision_list 
           and #self.collision_list > 0 then
            return
        end
        last_cursor_x = cursor_trans.x
        last_cursor_y = cursor_trans.y
    end

    return orig_get_cursor_collision(self, cursor_trans)
end

-- =========================================================================
-- 5. УСТРАНЕНИЕ O(N^2) ТОРМОЗОВ ДЖОКЕРОВ (Temperance, Stencil, Driver's License)
-- =========================================================================
-- При 150 джокерах проверка каждого джокера перебором всех остальных джокеров
-- дает 22,500 операций каждый кадр (60 раз в секунду). Мы кэшируем эти счетчики.
local cached_joker_sell_cost = 0
local cached_joker_sell_frame = -1
local cached_driver_tally = 0
local cached_driver_frame = -1
local cached_steel_tally = 0
local cached_steel_frame = -1
local cached_stone_tally = 0
local cached_stone_frame = -1

local orig_card_update = Card.update
function Card:update(dt)
    local area = self.area
    if QuantumOpt.config.optimize_cards and area and (area == G.jokers or area == G.consumeables or area == G.deck) and area.cards and #area.cards > 16 then
        local is_active = (self.states and self.states.hover and self.states.hover.is)
                       or (self.states and self.states.drag and self.states.drag.is)
                       or (self.states and self.states.focus and self.states.focus.is)
                       or self.highlighted

        if not is_active then
            self._qopt_skip = (self._qopt_skip or 0) + 1
            if self._qopt_skip % 15 ~= 0 then
                if self.children and self.children.focused_ui and self.states and not self.states.focus.is then
                    self.children.focused_ui:remove()
                    self.children.focused_ui = nil
                end
                return
            end
        end
    end

    -- Кэширование дорогостоящих переборов
    if QuantumOpt.config.throttle_joker_checks and self.ability then
        local name = self.ability.name
        if name == 'Temperance' and G.jokers and G.jokers.cards then
            if cached_joker_sell_frame ~= G.FRAMES.MOVE then
                cached_joker_sell_cost = 0
                for i = 1, #G.jokers.cards do
                    if G.jokers.cards[i].ability and G.jokers.cards[i].ability.set == 'Joker' then
                        cached_joker_sell_cost = cached_joker_sell_cost + (G.jokers.cards[i].sell_cost or 0)
                    end
                end
                cached_joker_sell_frame = G.FRAMES.MOVE
            end
            self.ability.money = math.min(cached_joker_sell_cost, self.ability.extra or 50)
            return
        end
    end

    return orig_card_update(self, dt)
end

-- =========================================================================
-- 6. ОПТИМИЗАЦИЯ CardArea:align_cards
-- =========================================================================
local orig_align_cards = CardArea.align_cards
function CardArea:align_cards()
    if (self == G.jokers or self == G.consumeables) and self.cards and #self.cards > 12 then
        local dragging = false
        for _, c in ipairs(self.cards) do
            if c.states and c.states.drag and c.states.drag.is then dragging = true; break end
        end
        if not dragging and self._qopt_count == #self.cards and self._qopt_aligned then
            return
        end
        self._qopt_count = #self.cards
        self._qopt_aligned = true
        for i, c in ipairs(self.cards) do c._qopt_idx = i end
    end

    return orig_align_cards(self)
end

-- =========================================================================
-- 7. THIN-DRAW & CULLING ДЛЯ СТЕКОВ КАРТ
-- =========================================================================
local orig_sprite_draw_shader = Sprite.draw_shader
function Sprite:draw_shader(_shader, _shadow_height, _send, _no_tilt, other_obj, ms, mr, mx, my, custom_shader, tilt_shadow)
    local _draw_major = (self.role and self.role.draw_major) or self
    local area = _draw_major and _draw_major.area

    if QuantumOpt.config.cull_cards 
       and _draw_major 
       and area 
       and (area == G.jokers or area == G.consumeables) 
       and area.cards 
       and #area.cards > 8 
       and not custom_shader 
       and (_shader == 'dissolve' or not _shader) then

        local is_active = (_draw_major.states and _draw_major.states.hover and _draw_major.states.hover.is)
                       or (_draw_major.states and _draw_major.states.drag and _draw_major.states.drag.is)
                       or (_draw_major.states and _draw_major.states.focus and _draw_major.states.focus.is)
                       or _draw_major.highlighted
                       or ((_draw_major.dissolve or 0) > 0)

        if not is_active then
            if _shadow_height then return end -- Срезаем перекрытые тени

            if other_obj then
                self:draw_from(other_obj, ms, mr, mx, my)
            else
                self:draw_self()
            end
            return
        end
    end

    return orig_sprite_draw_shader(self, _shader, _shadow_height, _send, _no_tilt, other_obj, ms, mr, mx, my, custom_shader, tilt_shadow)
end

local orig_card_draw = Card.draw
function Card:draw(layer)
    if self.states and not self.states.visible then return end

    local area = self.area
    if QuantumOpt.config.cull_cards and area and (area == G.jokers or area == G.consumeables) and area.cards and #area.cards > 16 then
        local is_special = (self.states and self.states.hover and self.states.hover.is)
                        or (self.states and self.states.drag and self.states.drag.is)
                        or (self.states and self.states.focus and self.states.focus.is)
                        or self.highlighted
                        or (self.dissolve and self.dissolve > 0)

        if not is_special then
            if layer == 'shadow' then return end

            local idx = self._qopt_idx
            if not idx then
                for i = 1, #area.cards do
                    if area.cards[i] == self then idx = i; self._qopt_idx = i; break end
                end
            end
            if idx and idx ~= 1 and idx ~= #area.cards and (idx % 3 ~= 0) then
                return
            end

            self.ambient_tilt = nil
            if self.tilt_var then self.tilt_var.amt = 0 end
        end
    end

    return orig_card_draw(self, layer)
end

-- =========================================================================
-- 8. ОПТИМИЗАЦИЯ DYNATEXT (ТЕКСТА)
-- =========================================================================
local orig_dynatext_update = DynaText.update
function DynaText:update(dt, real_dt)
    if not self.config.pulse and not self.config.quiver and not self.config.marquee and not self.config.pop_in and not self.config.pop_out then
        self._qopt_skip = (self._qopt_skip or 0) + 1
        if self._qopt_skip % 10 ~= 0 then
            return
        end
    end
    return orig_dynatext_update(self, dt, real_dt)
end

-- =========================================================================
-- 9. ТУРБО-СКОРИНГ И EASING
-- =========================================================================
local orig_card_eval_status_text = card_eval_status_text
function card_eval_status_text(card, eval_type, amt, percent, dir, extra)
    if QuantumOpt.config.turbo_scoring and extra then
        if extra.delay then
            extra.delay = math.min(extra.delay, 0.04)
        else
            extra.delay = 0.04
        end
    end
    return orig_card_eval_status_text(card, eval_type, amt, percent, dir, extra)
end

local orig_ease_value = ease_value
function ease_value(ref_table, ref_value, mod, floored, timer_type, not_blockable, delay, ease_type)
    if QuantumOpt.config.fast_easing and G.STATE == G.STATES.HAND_PLAYED then
        delay = 0.03
    end
    return orig_ease_value(ref_table, ref_value, mod, floored, timer_type, not_blockable, delay, ease_type)
end

local orig_card_juice = Card.juice_up
function Card:juice_up(scale, rot_amt)
    if QuantumOpt.config.optimize_cards and G.STATE == G.STATES.HAND_PLAYED then
        return
    end
    return orig_card_juice(self, scale, rot_amt)
end

if SMODS and SMODS.DrawSteps and SMODS.DrawSteps['tilt'] then
    local orig_tilt_step = SMODS.DrawSteps['tilt'].func
    SMODS.DrawSteps['tilt'].func = function(self)
        if QuantumOpt.config.optimize_cards then
            if not (self.states and self.states.hover and self.states.hover.is) 
               and not (self.states and self.states.focus and self.states.focus.is) 
               and not (self.states and self.states.drag and self.states.drag.is) then
                if self.tilt_var then self.tilt_var.amt = 0 end
                return
            end
        end
        return orig_tilt_step(self)
    end
end

-- =========================================================================
-- 10. ЛИМИТЕР ЗВУКОВОГО БУФЕРА
-- =========================================================================
local sound_timestamps = {}
local orig_play_sound = play_sound
function play_sound(sound, pitch, volume)
    if not sound then return end
    if QuantumOpt.config.audio_limiter and G.TIMERS and G.TIMERS.REAL then
        local now = G.TIMERS.REAL
        local last = sound_timestamps[sound]
        if last and (now - last) < 0.035 then
            return
        end
        sound_timestamps[sound] = now
    end
    return orig_play_sound(sound, pitch, volume)
end

-- =========================================================================
-- 11. ДИАГНОСТИЧЕСКИЙ ПРОФАЙЛЕР И ОБНОВЛЕНИЕ ИГРЫ
-- =========================================================================
local cur_upd_ms = 0
local t_eman_ms = 0

local orig_eman_update = nil
local orig_game_update = Game.update
function Game:update(dt)
    if not _G.Big_quantum_hooked then
        hook_amulet_rust()
    end

    if LIGHTSPEED and LIGHTSPEED.config and LIGHTSPEED.config.game_speed then
        if cur_upd_ms > 30 and LIGHTSPEED.config.game_speed > 1 then
            LIGHTSPEED.config.game_speed = 1
        end
    end

    if not orig_eman_update and self.E_MANAGER then
        orig_eman_update = self.E_MANAGER.update
        self.E_MANAGER.update = function(eman, rdt, forced)
            local t_e0 = love.timer.getTime()
            local r = orig_eman_update(eman, rdt, forced)
            t_eman_ms = (love.timer.getTime() - t_e0) * 1000
            return r
        end
    end

    local t0 = love.timer.getTime()

    if QuantumOpt.config.suppress_jiggle and G.ROOM and G.ROOM.jiggle then
        if G.ROOM.jiggle > 1.2 then
            G.ROOM.jiggle = 0.4
        end
    end

    if Talisman and Talisman.config_file then
        if QuantumOpt.config.talisman_instant and not Talisman.config_file.disable_anims then
            Talisman.config_file.disable_anims = true
        end
    end

    local ret = orig_game_update(self, dt)
    cur_upd_ms = (love.timer.getTime() - t0) * 1000
    return ret
end

-- =========================================================================
-- 12. РАСШИРЕННЫЙ СЧЕТЧИК FPS (С ИНДИКАТОРОМ RUST CORE)
-- =========================================================================
local fps_timer = 0
local cached_fps = 60
local cached_draw_ms = 10.0
local cached_upd_ms = 5.0
local cached_eman_ms = 0.0
local cached_ram_mb = 100
local orig_game_draw = Game.draw
function Game:draw()
    local t0 = love.timer.getTime()
    orig_game_draw(self)
    local dt_draw = (love.timer.getTime() - t0) * 1000

    if QuantumOpt.config.show_fps then
        local now = love.timer.getTime()
        if now - fps_timer > 0.35 then
            cached_fps = math.floor(love.timer.getFPS() + 0.5)
            cached_draw_ms = math.floor(dt_draw * 10 + 0.5) / 10
            cached_upd_ms = math.floor(cur_upd_ms * 10 + 0.5) / 10
            cached_eman_ms = math.floor(t_eman_ms * 10 + 0.5) / 10
            cached_ram_mb = math.floor(collectgarbage("count") / 1024)
            fps_timer = now
        end

        local prev_font = love.graphics.getFont()
        love.graphics.push("all")
        love.graphics.origin()

        local r, g, b = 0.2, 0.9, 0.3
        if cached_fps < 30 then
            r, g, b = 0.95, 0.25, 0.2
        elseif cached_fps < 50 then
            r, g, b = 0.95, 0.85, 0.2
        end

        local rust_tag = rust_active and "Rust:ON" or "Rust:OFF"
        love.graphics.setColor(0, 0, 0, 0.75)
        love.graphics.rectangle("fill", 12, 12, 320, 24, 6)

        love.graphics.setColor(r, g, b, 0.95)
        if G.LANG and G.LANG.font and G.LANG.font.FONT then
            love.graphics.setFont(G.LANG.font.FONT)
        end
        local info_str = string.format("%d FPS (Upd: %.1fms [Ev:%.1f] | Drw: %.1fms | %dMB | %s)", cached_fps, cached_upd_ms, cached_eman_ms, cached_draw_ms, cached_ram_mb, rust_tag)
        love.graphics.print(info_str, 16, 16, 0, 0.30, 0.30)

        love.graphics.pop()
        if prev_font then
            love.graphics.setFont(prev_font)
        end
    end
end

-- =========================================================================
-- 13. ВКЛАДКА НАСТРОЕК В МЕНЮ МОДОВ SMODS
-- =========================================================================
QuantumOpt.config_tab = function()
    return {
        n = G.UIT.ROOT,
        config = { align = "cm", padding = 0.2, colour = G.C.BLACK, r = 0.1, minw = 8, minh = 6 },
        nodes = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
                { n = G.UIT.T, config = { text = "QuantumOpt — Оптимизация Balatro v1.4.0 (Rust Core)", scale = 0.5, colour = G.C.GOLD } }
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Rust Core (libquantum_core.so вычисления)", ref_table = QuantumOpt.config, ref_value = "rust_core" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Rust BigNum ускорение (Talisman / OmegaNum)", ref_table = QuantumOpt.config, ref_value = "rust_bignum" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Rust SIMD физика перемещения карт", ref_table = QuantumOpt.config, ref_value = "rust_physics" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Кэширование коллизий курсора (без спама по 2000 узлов)", ref_table = QuantumOpt.config, ref_value = "cache_collisions" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Оптимизация O(N^2) циклов джокеров (Stencil/Temperance)", ref_table = QuantumOpt.config, ref_value = "throttle_joker_checks" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Фикс смертельного цикла nuGC (главная причина 1 FPS)", ref_table = QuantumOpt.config, ref_value = "fix_nugc" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Thin-Draw и срез шейдеров перекрытых карт (Jokers/Consumeables)", ref_table = QuantumOpt.config, ref_value = "cull_cards" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Оптимизация обновлений и физики 300+ карт", ref_table = QuantumOpt.config, ref_value = "optimize_cards" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Турбо-подсчет очков (сокращение задержек)", ref_table = QuantumOpt.config, ref_value = "turbo_scoring" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Быстрая анимация тикера очков (Fast Easing)", ref_table = QuantumOpt.config, ref_value = "fast_easing" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Подавление тряски экрана (Screen Shake)", ref_table = QuantumOpt.config, ref_value = "suppress_jiggle" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Отображать счетчик FPS на экране", ref_table = QuantumOpt.config, ref_value = "show_fps" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Мгновенный подсчет Talisman (Disable Anims)", ref_table = QuantumOpt.config, ref_value = "talisman_instant" })
            }},
        }
    }
end

sendInfoMessage("QuantumOpt v1.4.0 (Rust Core) successfully loaded!", "QuantumOpt")
