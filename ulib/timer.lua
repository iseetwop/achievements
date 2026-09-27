-- ulib/timer.lua
-- Ограничение частоты и форматирование времени.
--
--   local Timer = require("ulib.timer")
--   local every_second = Timer.Every(1)                        -- по os.clock
--   local every_tick = Timer.Every(0.5, GameRules.GetGameTime) -- по игровому времени
--   if every_second() then ... end
--   Timer.Format(754) --> "12:34"

local Timer = {}

-- Возвращает функцию, которая даёт true не чаще раза в interval секунд.
-- clock - источник времени, по умолчанию os.clock.
function Timer.Every(interval, clock)
    clock = clock or os.clock
    local next_time = -math.huge
    return function()
        local now = clock()
        -- время ушло назад (новый матч для игровых часов) - не ждём до старой отметки
        if now >= next_time or next_time - now > interval then
            next_time = now + interval
            return true
        end
        return false
    end
end

-- Секунды в "м:сс": 754.3 -> "12:34", -35 -> "-0:35".
function Timer.Format(seconds)
    local sign = seconds < 0 and "-" or ""
    seconds = math.floor(math.abs(seconds))
    return ("%s%d:%02d"):format(sign, seconds // 60, seconds % 60)
end

return Timer
