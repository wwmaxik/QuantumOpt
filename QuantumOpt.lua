--- STEAMODDED HEADER
--- MOD_NAME: QuantumOpt
--- MOD_ID: QuantumOpt
--- MOD_AUTHOR: [wwmaxik]
--- MOD_DESCRIPTION: [BETA] Мгновенный подсчет очков и Rust-нативная оптимизация 60 FPS для Balatro при 150+ джокерах, Cryptid и Talisman.
--- BADGE_COLOUR: 00b4d8
--- PREFIX: qopt
--- VERSION: 1.4.0-beta
--- PRIORITY: 1000

QuantumOpt = SMODS.current_mod or {}

-- Конфигурация по умолчанию
local default_config = {
    instant_scoring = true,     -- Мгновенный подсчет очков (срезает задержки очереди событий до 0.001с)
    filter_other_jokers = true, -- Устранение O(N^2) цикла other_joker (пропуск 22,500 лишних вызовов eval_card)
    talisman_instant = true,    -- Мгновенный счет Talisman/Amulet (framecalc = 100000, disable_anims = true)
    turbo_scoring = true,       -- Турбо-дрейн очереди EventManager (до 25 событий за кадр во время счета)
    rust_core = true,           -- Использовать Rust нативную библиотеку libquantum_core.so
    rust_physics = true,        -- Быстрая SIMD физика перемещений карт на Rust
    cache_collisions = true,    -- Кэширование коллизий курсора (устраняет проверку 2000+ узлов при неподвижной мыши)
    throttle_joker_checks = true, -- Кэширование пассивных джокеров (Temperance, Stencil, Driver's License)
    fix_nugc = true,            -- Устранение смертельного цикла nuGC (full collect при >300MB)
    cull_cards = true,          -- Thin-Draw и срез тяжелых шейдеров для 100+ перекрытых карт
    optimize_cards = true,      -- Оптимизация обновлений и физики 300+ карт
    fast_easing = true,         -- Мгновенное обновление счетчиков очков без микрофризов
    suppress_jiggle = true,     -- Подавление тряски экрана при астрономических очках
    audio_limiter = true,       -- Защита звукового буфера OpenAL от спама одинаковых звуков
    show_fps = true,            -- Аккуратный счетчик FPS в углу экрана с подробной диагностикой
    simple_background = false,  -- Упрощенный фон (для слабых GPU)
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

    pcall(ffi.cdef, [[
        int quantum_init();
        double quantum_get_time();
    ]])

    pcall(ffi.cdef, [[
        void quantum_step_xy(float tx, float ty, float* vtx, float* vty, float* vx, float* vy, float dt, float exp_xy, float max_vel, bool* out_stationary);
    ]])

    pcall(ffi.cdef, [[
        struct CRect {
            float x, y, w, h, r;
        };
        bool quantum_point_in_rect(const struct CRect* r, float px, float py, float buffer);
        size_t quantum_batch_point_collision(const struct CRect* rects, size_t count, float px, float py, float buffer, int32_t* out_indices, size_t max_out);
    ]])

    local candidates = {
        (SMODS and SMODS.current_mod and SMODS.current_mod.path) and (SMODS.current_mod.path .. "libquantum_core.so"),
        (SMODS and SMODS.current_mod and SMODS.current_mod.path) and (SMODS.current_mod.path .. "/libquantum_core.so"),
        (love and love.filesystem and love.filesystem.getSaveDirectory) and (love.filesystem.getSaveDirectory() .. "/Mods/QuantumOpt/libquantum_core.so"),
        "/home/wwmaxik/.local/share/balatro/Mods/QuantumOpt/libquantum_core.so",
        "/home/wwmaxik/QuantumOpt/libquantum_core.so",
        "./libquantum_core.so",
        "libquantum_core.so"
    }

    for _, path in ipairs(candidates) do
        if path then
            local ok, lib = pcall(ffi.load, path)
            if ok and lib then
                local sym_ok = pcall(function() return lib.quantum_step_xy ~= nil end)
                if sym_ok then
                    QuantumLib = lib
                    rust_loaded_path = path
                    rust_active = true
                    pcall(function() QuantumLib.quantum_init() end)
                    sendInfoMessage("[QuantumOpt] Native Rust core loaded successfully from: " .. path, "QuantumOpt")
                    break
                end
            end
        end
    end

    if not QuantumLib then
        sendWarnMessage("[QuantumOpt] libquantum_core.so not found, falling back to pure Lua mode.", "QuantumOpt")
    end
end

init_rust_core()

-- =========================================================================
-- 1. НЕЙТРАЛИЗАЦИЯ СМЕРТЕЛЬНОГО ЦИКЛА nuGC (ГЛАВНАЯ ПРИЧИНА 1 FPS)
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
-- 2. УСКОРЕНИЕ ВЫЧИСЛЕНИЙ ПОДСЧЕТА И УСТРАНЕНИЕ O(N^2) OTHER_JOKER
-- =========================================================================
-- При 150+ джокерах vanilla и SMODS вызывают eval_card для каждого джокера против
-- каждого другого джокера (150 * 150 = 22,500 вызовов на каждый триггер карты!).
-- 99% джокеров никогда не используют context.other_joker. Мы кэшируем и отсекаем их.
local cares_about_other_cache = {}
local function card_cares_about_other(card)
    if not card then return true end
    if card.debuff then return false end
    if card.edition and (card.edition.cry_astral or card.edition.key == 'e_cry_astral') then return true end

    local name = card.ability and card.ability.name
    if name == 'Baseball Card' or name == 'Blueprint' or name == 'Brainstorm' then return true end

    local center = card.config and card.config.center
    if not center then return true end
    local key = center.key or name
    if not key then return true end

    local cached = cares_about_other_cache[key]
    if cached ~= nil then return cached end

    if type(center.calculate) == 'function' then
        local ok, dump = pcall(string.dump, center.calculate)
        if ok and dump then
            if string.find(dump, "other_joker") or string.find(dump, "other_main") 
               or string.find(dump, "other_card") or string.find(dump, "other_consumeable") 
               or string.find(dump, "other_voucher") then
                cares_about_other_cache[key] = true
                return true
            end
        end
    end

    cares_about_other_cache[key] = false
    return false
end

local orig_eval_card = eval_card
function eval_card(card, context)
    if QuantumOpt.config.filter_other_jokers and context and (context.other_joker or context.other_main or context.other_consumeable or context.other_voucher) then
        if card and card.ability and card.ability.set == 'Joker' then
            if not card_cares_about_other(card) then
                return {}, {}
            end
        end
    end
    return orig_eval_card(card, context)
end

-- Сжатие искусственных пауз delay(...) до 0.001с во время розыгрыша руки
local orig_delay = delay
function delay(time, queue)
    if (QuantumOpt.config.instant_scoring or QuantumOpt.config.turbo_scoring) and G.STATE == G.STATES.HAND_PLAYED then
        time = 0.001
    end
    return orig_delay(time, queue)
end

-- Сжатие задержек событий очереди EventManager
local orig_event_init = Event.init
function Event:init(config)
    if (QuantumOpt.config.instant_scoring or QuantumOpt.config.turbo_scoring) and G.STATE == G.STATES.HAND_PLAYED then
        if config.delay and config.delay > 0.005 then
            config.delay = 0.002
        end
    end
    return orig_event_init(self, config)
end

-- Турбо-дрейн очереди событий EventManager: мгновенный сброс триггеров без просадки FPS
local orig_eman_update = EventManager.update
function EventManager:update(dt, forced)
    if (QuantumOpt.config.instant_scoring or QuantumOpt.config.turbo_scoring) and G.STATE == G.STATES.HAND_PLAYED then
        for _ = 1, 20 do
            orig_eman_update(self, dt, true)
            local q = self.queues['base']
            if not q or #q == 0 then break end
            if q[1] and q[1].delay and q[1].delay > 0.05 then break end
        end
        return
    end
    return orig_eman_update(self, dt, forced)
end

-- Мгновенный вывод статуса очков (card_eval_status_text)
local orig_card_eval_status_text = card_eval_status_text
function card_eval_status_text(card, eval_type, amt, percent, dir, extra)
    if (QuantumOpt.config.instant_scoring or QuantumOpt.config.turbo_scoring) and G.STATE == G.STATES.HAND_PLAYED then
        if extra then
            extra.delay = 0.002
            extra.instant = true
        else
            extra = { delay = 0.002, instant = true }
        end
    end
    return orig_card_eval_status_text(card, eval_type, amt, percent, dir, extra)
end

-- Мгновенная интерполяция чисел (Fast Easing)
local orig_ease_value = ease_value
function ease_value(ref_table, ref_value, mod, floored, timer_type, not_blockable, delay, ease_type)
    if QuantumOpt.config.fast_easing and G.STATE == G.STATES.HAND_PLAYED then
        delay = 0.01
    end
    return orig_ease_value(ref_table, ref_value, mod, floored, timer_type, not_blockable, delay, ease_type)
end

-- Отключение анимаций вздрагивания карт во время расчета очков
local orig_card_juice = Card.juice_up
function Card:juice_up(scale, rot_amt)
    if QuantumOpt.config.optimize_cards and G.STATE == G.STATES.HAND_PLAYED then
        return
    end
    return orig_card_juice(self, scale, rot_amt)
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
            local ok = pcall(function()
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
            end)
            if ok then return end
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
local cached_joker_sell_cost = 0
local cached_joker_sell_frame = -1

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
-- 9. ЛИМИТЕР ЗВУКОВОГО БУФЕРА
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
-- 10. ДИАГНОСТИЧЕСКИЙ ПРОФАЙЛЕР И ОБНОВЛЕНИЕ ИГРЫ
-- =========================================================================
local cur_upd_ms = 0
local t_eman_ms = 0

local orig_eman_measure = nil
local orig_game_update = Game.update
function Game:update(dt)
    if LIGHTSPEED and LIGHTSPEED.config and LIGHTSPEED.config.game_speed then
        if cur_upd_ms > 30 and LIGHTSPEED.config.game_speed > 1 then
            LIGHTSPEED.config.game_speed = 1
        end
    end

    if not orig_eman_measure and self.E_MANAGER then
        orig_eman_measure = self.E_MANAGER.update
        self.E_MANAGER.update = function(eman, rdt, forced)
            local t_e0 = love.timer.getTime()
            local r = orig_eman_measure(eman, rdt, forced)
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

    -- Автоускорение Talisman / Amulet: мгновенный подсчет без ожидания 400 кадров
    if Talisman then
        if QuantumOpt.config.talisman_instant then
            if Talisman.config_file and not Talisman.config_file.disable_anims then
                Talisman.config_file.disable_anims = true
            end
            if Talisman.coroutine then
                if Talisman.coroutine.framecalc and Talisman.coroutine.framecalc < 50000 then
                    Talisman.coroutine.framecalc = 100000
                end
                if Talisman.coroutine.frametime and Talisman.coroutine.frametime < 1.0 then
                    Talisman.coroutine.frametime = 5.0
                end
            end
        end
    end

    local ret = orig_game_update(self, dt)
    cur_upd_ms = (love.timer.getTime() - t0) * 1000
    return ret
end

-- =========================================================================
-- 11. РАСШИРЕННЫЙ СЧЕТЧИК FPS (С ИНДИКАТОРОМ RUST CORE)
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
        love.graphics.rectangle("fill", 12, 12, 330, 24, 6)

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
-- 12. ВКЛАДКА НАСТРОЕК В МЕНЮ МОДОВ SMODS
-- =========================================================================
QuantumOpt.config_tab = function()
    return {
        n = G.UIT.ROOT,
        config = { align = "cm", padding = 0.2, colour = G.C.BLACK, r = 0.1, minw = 8, minh = 6 },
        nodes = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
                { n = G.UIT.T, config = { text = "QuantumOpt — Мгновенный подсчет очков & 60 FPS v1.4.0-beta", scale = 0.5, colour = G.C.GOLD } }
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Мгновенный подсчет очков (срезает искусственные паузы)", ref_table = QuantumOpt.config, ref_value = "instant_scoring" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Устранение O(N^2) цикла other_joker (пропуск 22,500 вызовов)", ref_table = QuantumOpt.config, ref_value = "filter_other_jokers" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Мгновенный расчет Talisman (framecalc 100k, disable anims)", ref_table = QuantumOpt.config, ref_value = "talisman_instant" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Турбо-дрейн очереди EventManager (до 20 событий за кадр)", ref_table = QuantumOpt.config, ref_value = "turbo_scoring" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Rust Core (libquantum_core.so вычисления)", ref_table = QuantumOpt.config, ref_value = "rust_core" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Rust SIMD физика перемещения карт", ref_table = QuantumOpt.config, ref_value = "rust_physics" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Кэширование коллизий курсора (без спама по 2000 узлов)", ref_table = QuantumOpt.config, ref_value = "cache_collisions" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Оптимизация O(N^2) пассивных джокеров (Stencil/Temperance)", ref_table = QuantumOpt.config, ref_value = "throttle_joker_checks" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Фикс смертельного цикла nuGC (главная причина 1 FPS)", ref_table = QuantumOpt.config, ref_value = "fix_nugc" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Thin-Draw и срез шейдеров перекрытых карт", ref_table = QuantumOpt.config, ref_value = "cull_cards" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Оптимизация обновлений и физики 300+ карт", ref_table = QuantumOpt.config, ref_value = "optimize_cards" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Быстрая анимация счетчиков очков (Fast Easing)", ref_table = QuantumOpt.config, ref_value = "fast_easing" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Подавление тряски экрана (Screen Shake)", ref_table = QuantumOpt.config, ref_value = "suppress_jiggle" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Отображать счетчик FPS на экране", ref_table = QuantumOpt.config, ref_value = "show_fps" })
            }},
        }
    }
end

sendInfoMessage("QuantumOpt v1.4.0-beta (Instant Scoring & Rust Core) successfully loaded!", "QuantumOpt")
