--- STEAMODDED HEADER
--- MOD_NAME: QuantumOpt
--- MOD_ID: QuantumOpt
--- MOD_AUTHOR: [wwmaxik]
--- MOD_DESCRIPTION: Высокопроизводительная оптимизация для бесконечных забегов с 100+ джокерами и 100+ расходниками, Cryptid и Talisman.
--- BADGE_COLOUR: 00b4d8
--- PREFIX: qopt
--- VERSION: 1.3.0
--- PRIORITY: 1000

QuantumOpt = SMODS.current_mod or {}

-- Конфигурация по умолчанию
local default_config = {
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
-- 1. НЕЙТРАЛИЗАЦИЯ СМЕРТЕЛЬНОГО ЦИКЛА nuGC (ГЛАВНАЯ ПРИЧИНА 1 FPS)
-- =========================================================================
-- В vanilla Balatro (misc_functions.lua:658) есть код:
-- if collectgarbage("count") / 1024 > memory_ceiling (300MB) then collectgarbage("collect") end
-- В забегах с модами (Cryptid, 147 джокеров, 150 расходников, BigNum)
-- память ВСЕГДА больше 300MB. Движок вызывал полный collectgarbage("collect")
-- КАЖДЫЙ КАДР. Полный проход по 300MB памяти занимает 100-300 миллисекунд,
-- что превращало игру в 1-3 FPS слайдшоу!
if QuantumOpt.config.fix_nugc then
    function nuGC(time_budget, memory_ceiling, disable_otherwise)
        -- Делаем только мягкий безопасный шаг, НИКОГДА не делая стоп-кадр полного collect
        collectgarbage("step", 2)
    end
    collectgarbage("restart")
    pcall(collectgarbage, "setpause", 200)
    pcall(collectgarbage, "setstepmul", 200)
end

-- =========================================================================
-- 2. СРЕЗ ХОЛОСТЫХ ШЕЙДЕРОВ (Jokers & Consumeables)
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

-- =========================================================================
-- 3. THIN-DRAW & CULLING ДЛЯ СТЕКОВ КАРТ (> 16 карт в слоте)
-- =========================================================================
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
-- 4. ОПТИМИЗАЦИЯ CardArea:align_cards
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
-- 5. ОПТИМИЗАЦИЯ Card:update И MOVEABLES ДЛЯ 300+ КАРТ
-- =========================================================================
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
            if self._qopt_skip % 20 ~= 0 then
                if self.children and self.children.focused_ui and self.states and not self.states.focus.is then
                    self.children.focused_ui:remove()
                    self.children.focused_ui = nil
                end
                return
            end
        end
    end

    return orig_card_update(self, dt)
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

-- Оптимизация Moveable:update (Node:update) для стационарных карт
local orig_node_update = Node.update
function Node:update(dt)
    if QuantumOpt.config.optimize_cards and self.is and self:is(Card) then
        local area = self.area
        if area and (area == G.jokers or area == G.consumeables or area == G.deck) and area.cards and #area.cards > 16 then
            local is_active = (self.states and self.states.hover and self.states.hover.is)
                           or (self.states and self.states.drag and self.states.drag.is)
                           or (self.states and self.states.focus and self.states.focus.is)
                           or self.highlighted
            if not is_active then
                self._qopt_nskip = (self._qopt_nskip or 0) + 1
                if self._qopt_nskip % 10 ~= 0 then
                    return
                end
            end
        end
    end
    return orig_node_update(self, dt)
end

-- =========================================================================
-- 6. ОПТИМИЗАЦИЯ DYNATEXT (ТЕКСТА)
-- =========================================================================
-- Текстовые объекты (DynaText) в Balatro постоянно пересчитывают utf8.chars,
-- вызывают love.graphics.newText и тригонометрию (quiver/float/bump/pop_in).
-- При 300+ картах на столе это сжирает 50-80 мс процессора за кадр!
local orig_dynatext_update = DynaText.update
function DynaText:update(dt, real_dt)
    -- Неподвижный текст без анимаций не требует обновления каждый кадр
    if not self.config.pulse and not self.config.quiver and not self.config.marquee and not self.config.pop_in and not self.config.pop_out then
        self._qopt_skip = (self._qopt_skip or 0) + 1
        if self._qopt_skip % 10 ~= 0 then
            return
        end
    end
    return orig_dynatext_update(self, dt, real_dt)
end

-- =========================================================================
-- 7. ТУРБО-СКОРИНГ И EASING
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
-- 8. ЛИМИТЕР ЗВУКОВОГО БУФЕРА
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
-- 9. ОБНОВЛЕНИЕ ИГРЫ И ДИАГНОСТИЧЕСКИЙ ПРОФАЙЛЕР
-- =========================================================================
local cur_upd_ms = 0
local t_eman_ms = 0
local t_mov_ms = 0
local t_other_ms = 0

local orig_eman_update = nil

local orig_game_update = Game.update
function Game:update(dt)
    -- Защита от взрыва цикла Lightspeed
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
-- 10. УПРОЩЕННЫЙ ФОНОВЫЙ ШЕЙДЕР
-- =========================================================================
local orig_splash_draw = nil
if G and G.SPLASH_BACK then
    orig_splash_draw = G.SPLASH_BACK.draw
    G.SPLASH_BACK.draw = function(self)
        if QuantumOpt.config.simple_background then
            love.graphics.setColor(0.12, 0.14, 0.18, 1)
            love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
            return
        end
        if orig_splash_draw then
            return orig_splash_draw(self)
        end
    end
end

-- =========================================================================
-- 11. РАСШИРЕННЫЙ СЧЕТЧИК FPS (С ПАМЯТЬЮ И ВРЕМЕНЕМ КАДРА)
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

        love.graphics.setColor(0, 0, 0, 0.75)
        love.graphics.rectangle("fill", 12, 12, 280, 24, 6)

        love.graphics.setColor(r, g, b, 0.95)
        if G.LANG and G.LANG.font and G.LANG.font.FONT then
            love.graphics.setFont(G.LANG.font.FONT)
        end
        local info_str = string.format("%d FPS (Upd: %.1fms [Ev:%.1f] | Drw: %.1fms | %dMB)", cached_fps, cached_upd_ms, cached_eman_ms, cached_draw_ms, cached_ram_mb)
        love.graphics.print(info_str, 16, 16, 0, 0.30, 0.30)

        love.graphics.pop()
        if prev_font then
            love.graphics.setFont(prev_font)
        end
    end
end

-- =========================================================================
-- 11. ВКЛАДКА НАСТРОЕК В МЕНЮ МОДОВ SMODS
-- =========================================================================
QuantumOpt.config_tab = function()
    return {
        n = G.UIT.ROOT,
        config = { align = "cm", padding = 0.2, colour = G.C.BLACK, r = 0.1, minw = 8, minh = 6 },
        nodes = {
            { n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
                { n = G.UIT.T, config = { text = "QuantumOpt — Оптимизация Balatro v1.3.0", scale = 0.5, colour = G.C.GOLD } }
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
                create_toggle({ label = "Лимитер звукового спама", ref_table = QuantumOpt.config, ref_value = "audio_limiter" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Отображать счетчик FPS на экране", ref_table = QuantumOpt.config, ref_value = "show_fps" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Упрощенный фон (для слабых GPU)", ref_table = QuantumOpt.config, ref_value = "simple_background" })
            }},
            { n = G.UIT.R, config = { align = "cl", padding = 0.05 }, nodes = {
                create_toggle({ label = "Мгновенный подсчет Talisman (Disable Anims)", ref_table = QuantumOpt.config, ref_value = "talisman_instant" })
            }},
        }
    }
end

sendInfoMessage("QuantumOpt v1.3.0 successfully loaded!", "QuantumOpt")
