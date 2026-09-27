-- achievements.lua - Достижения для Umbrella (Dota 2, Lua API v2.0). Нужна библиотека ulib (папка ulib в корне чита).
-- Достижения как в Steam, но за свои матчи в Dota: уведомление со звуком, очки за редкость, уровень,
-- страница со всеми достижениями и прогрессом до следующей ступени.
--
-- Всё считается по записям матчей: история OpenDota (при первом запуске - все матчи аккаунта, дальше раз
-- в 6 ч - последние 30 дней). Записи хранятся в configs\ulib_achievements_<аккаунт>.json, у каждого аккаунта
-- свой прогресс. Достижения получаются повтором истории по времени: дата получения - дата матча, а новые
-- достижения из следующих версий сразу применяются ко всем старым матчам.
-- Считаются обычные и рейтинговые матчи (лобби 0 и 7; режимы AP, CM, RD, SD, AR, CD, All Draft); Turbo -
-- отдельной категорией; боты, кастомки, Ability Draft и лобби - нет.
-- Достижение - семейство ступеней: бронза 10, серебро 25, золото 50, платина 100 очков. Уровень - по сумме очков.
-- У каждой ступени своё имя - отсылка к фильму, игре, книге или мему (таблица NAMES); цель - строкой под именем.
-- Загрузка истории и запись файла - только вне матча, чтобы не было фризов.
-- Страница - кнопка в меню или своя клавиша; окно двигается за шапку, колесо мыши - прокрутка.
-- v0.2: плюс события живого матча (регион Live match): мультикиллы, первая кровь, Aegis, Рошан, курьеры,
-- варды, стаки, ластхиты к 10:00, камбэк, выкуп. v0.3: убийства способностями героев (Sun Strike, хук,
-- Mana Void, дуэли, двойник Arc Warden, мины) - по OnEntityKilled.

local Icons = require("ulib.icons")
local Http = require("ulib.http")
local Store = require("ulib.store")
local Timer = require("ulib.timer")

local ach = {}

local VERSION <const> = "0.4.0"
local STORE_VERSION <const> = 1
local OPENDOTA <const> = "https://api.opendota.com/api/"
local STEAM64_BASE <const> = 76561197960265728
local MATCH_FIELDS <const> = { "hero_id", "kills", "deaths", "assists", "duration", "game_mode", "lobby_type",
    "start_time", "radiant_win", "player_slot", "last_hits", "denies", "gold_per_min", "xp_per_min",
    "hero_damage", "tower_damage", "hero_healing" }
local SYNC_EVERY <const> = 6 * 3600
local SYNC_RECENT_DAYS <const> = 30
local SYNC_FULL_AFTER <const> = 25 * 24 * 3600 -- давно не обновляли - берём всю историю
local SYNC_RETRY <const> = 120
local SYNC_TIMEOUT <const> = 60
local WR_MIN_GAMES <const> = 50
local BREAK_DAYS <const> = 30   -- «Возвращение джедая»: перерыв между матчами
local INVOKER_ID <const> = 74
-- живой матч
local EARLY_FIRST_BLOOD <const> = 90
local LIVE_POLL <const> = 0.5       -- опрос счёта игроков
local LIVE_SAVE_EVERY <const> = 5   -- запись незаконченного матча (маленький файл)
local LOG_EVENTS_PER_MATCH <const> = 60 -- сырые события чата и смертей в лог - проверить их смысл
-- Приёмы героев (v0.4). Константы - таблицами: у главного блока Lua предел в 200 локальных переменных,
-- скрипт к нему близко (не загрузится - «too many local variables»).
local FEAT <const> = {
    wk = "npc_dota_hero_skeleton_king", ls = "npc_dota_hero_life_stealer", pa = "npc_dota_hero_phantom_assassin",
    infest_modifier = "modifier_life_stealer_infest", omnislash_modifier = "modifier_juggernaut_omnislash",
    revived_window = 10, -- WK: убийство после воскрешения
    infest_window = 3,   -- Lifestealer: убийство после выхода из Infest
    haunt_window = 7,    -- Haunt длится 6 с (+1 на добивание)
    crit_log_from = 500, -- удары PA от стольки - в подробный лог (подобрать порог)
}
local MAX_SINGLE_TOASTS <const> = 4 -- больше новых за раз - одно общее уведомление
local SOUND_ACHIEVEMENT <const> = "sounds/ui/menu/trophy_new.vsnd_c"
local SOUND_LEVEL <const> = "sounds/ui/menu/trophy_levelup.vsnd_c"
local MAX_VOLUME <const> = 0.4 -- Engine.PlayVol: 0.5 - очень громко
local CFG <const> = "achievements" -- позиция страницы в db.json

-- матчи, которые считаются (OpenDota: lobby_type, game_mode)
local RANKED_LOBBY <const> = 7
local COUNTED_LOBBIES <const> = { [0] = true, [7] = true }
local NORMAL_MODES <const> = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [16] = true, [22] = true }
local TURBO_MODE <const> = 23

-- стадии матча (Enum.GameState): 1-5 - загрузка, драфт, игра; вне матча -1 (главное меню), 6 - итоги
local POST_GAME <const> = Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME or 6
local KEY <const> = {
    mouse1 = Enum.ButtonCode.KEY_MOUSE1, escape = Enum.ButtonCode.KEY_ESCAPE,
    wheel_up = Enum.ButtonCode.KEY_MWHEELUP, wheel_down = Enum.ButtonCode.KEY_MWHEELDOWN,
    -- события OnKeyEvent
    scroll_down = Enum.EKeyEvent.EKeyEvent_SCROLL_DOWN or 0, scroll_up = Enum.EKeyEvent.EKeyEvent_SCROLL_UP or 1,
    down = Enum.EKeyEvent.EKeyEvent_KEY_DOWN or 2, up = Enum.EKeyEvent.EKeyEvent_KEY_UP or 3,
}
local SHADOW_OUTSIDE <const> = Enum.DrawFlags.ShadowCutOutShapeBackground or 512
local WHITE <const> = Color(255, 255, 255, 255)
local UV0 <const> = Vec2(0, 0)
local UV1 <const> = Vec2(1, 1)

local floor, max, min = math.floor, math.max, math.min

--#region Helpers

local function log(fmt, ...)
    print("[achievements] " .. fmt:format(...))
end

-- результат вызова или nil, если функция упала
local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

-- целое из числа JSON (там все числа - float) или nil
local function int(v)
    v = tonumber(v)
    if not v then
        return nil
    end
    return math.tointeger(v) or floor(v + 0.5)
end

-- координата по целому пикселю: иначе текст и картинки размываются
local function px(v)
    return floor(v + 0.5)
end

-- 145830 -> "145 830"
local function fmt_num(n)
    local s = tostring(int(n) or 0)
    local sign, digits = s:match("^(-?)(%d+)$")
    if not digits then
        return s
    end
    digits = digits:reverse():gsub("(%d%d%d)", "%1 "):reverse()
    return sign .. (digits:gsub("^ ", ""))
end

local function ago(t)
    local d = os.time() - (int(t) or 0)
    if d < 60 then
        return "только что"
    elseif d < 3600 then
        return ("%d мин назад"):format(d // 60)
    elseif d < 86400 then
        return ("%d ч назад"):format(d // 3600)
    end
    return ("%d д назад"):format(d // 86400)
end

local function date_of(t)
    return os.date("%d.%m.%Y", int(t) or 0)
end

-- идёт ли матч: загрузка, драфт, игра (экран итогов - уже нет)
local function match_running()
    local state = safe(GameRules.GetGameState)
    return state ~= nil and state >= 1 and state <= 5
end

--#endregion

--#region Achievements

-- Редкость ступени: очки и цвет.
local RANKS <const> = {
    B = { points = 10, name = "бронза", color = Color(214, 140, 80) },
    S = { points = 25, name = "серебро", color = Color(200, 212, 228) },
    G = { points = 50, name = "золото", color = Color(255, 205, 70) },
    P = { points = 100, name = "платина", color = Color(120, 225, 255) },
}

local TABS <const> = {
    { cat = nil, name = "Все" },
    { cat = "career", name = "Карьера" },
    { cat = "feat", name = "Подвиги" },
    { cat = "special", name = "Особые" },
    { cat = "turbo", name = "Турбо" },
    { cat = "shame", name = "Позор" },
}

-- Семейство достижений:
--   id, cat (вкладка), name - внутреннее имя (лог); имена ступеней - NAMES[id] (ниже, после всех семейств);
--   icon ("item:<имя>" / "spell:<имя>" / "hero:<npc_dota_hero_...>"), hero_icon - портрет героя, о котором речь;
--   desc - цель ступени, %s - её значение (tiers[i][3] - своё описание ступени);
--   match(r, g, c) -> значение за один матч (nil - матч не подходит; g - итоги категории уже с этим матчем,
--     c - контекст: c.date - os.date("*t") начала матча, c.gap - секунд с прошлого засчитанного матча,
--     c.loss_before - поражений подряд до этого матча) или total(g) -> значение по сумме матчей [, герой];
--   tiers - { { значение, редкость }, ... } по возрастанию сложности; lower - чем меньше, тем лучше (время);
--   show - как писать значение: "time", "pct", "kda" (по умолчанию целое); binary - без значения («сделал / нет»);
--   hidden - описание скрыто, пока нет ни одной ступени;
--   scope - по вкладке: "normal" (обычные и рейтинг), "turbo", "ap" (Особые: рейтинг и All Pick).
-- Запись матча r: h герой, w победа, k/d/a, du длительность (с), m режим, l лобби, t начало (unix),
-- lh ластхиты, dn денаи, gp GPM, xp XPM, hd урон героям, td урон постройкам, hh лечение.
local FAMILIES, FAMILY_BY_ID = {}, {}

local function F(f)
    -- Особые (даты, серии, приёмы героев) - только рейтинг и All Pick (решение пользователя 2026-09-26)
    f.scope = f.scope or (f.cat == "turbo" and "turbo" or (f.cat == "special" and "ap" or "normal"))
    FAMILIES[#FAMILIES + 1] = f
    FAMILY_BY_ID[f.id] = f
end

-- значение поля записи, если матч выигран
local function in_win(field)
    return function(r)
        if r.w then
            return r[field]
        end
    end
end

local function win_duration(r)
    if r.w and (r.du or 0) > 0 then
        return r.du
    end
end

-- лучший винрейт на герое, сыгранном от WR_MIN_GAMES раз (сейчас, а не за всё время)
local function best_hero_winrate(g)
    local best, hero = nil, nil
    for id, hs in pairs(g.heroes) do
        if hs.g >= WR_MIN_GAMES then
            local wr = hs.w / hs.g
            if not best or wr > best then
                best, hero = wr, id
            end
        end
    end
    return best, hero
end

-- Карьера (обычные и рейтинговые матчи)
F { id = "games", cat = "career", name = "Стаж", icon = "item:travel_boots", desc = "%s игр",
    total = function(g) return g.games end,
    tiers = { { 100, "B" }, { 500, "S" }, { 1000, "G" }, { 2000, "P" } } }
F { id = "wins", cat = "career", name = "Победитель", icon = "item:aegis", desc = "%s побед",
    total = function(g) return g.wins end,
    tiers = { { 50, "B" }, { 250, "S" }, { 500, "G" }, { 1000, "P" } } }
F { id = "streak", cat = "career", name = "Серия побед", icon = "item:moon_shard", desc = "%s побед подряд",
    total = function(g) return g.best_win_streak end,
    tiers = { { 5, "B" }, { 7, "S" }, { 10, "G" }, { 15, "P" } } }
F { id = "ranked", cat = "career", name = "Рейтинговый боец", icon = "item:ultimate_scepter", desc = "%s побед в рейтинге",
    total = function(g) return g.ranked_wins end,
    tiers = { { 100, "B" }, { 300, "S" }, { 600, "G" }, { 1000, "P" } } }
F { id = "heroes", cat = "career", name = "Универсал", icon = "spell:rubick_spell_steal", desc = "%s разных героев",
    total = function(g) return g.distinct end,
    tiers = { { 25, "B" }, { 50, "S" }, { 100, "G" }, { 127, "P", "Все герои (%s)" } } }
F { id = "hero_games", cat = "career", name = "Верность", icon = "item:bottle", hero_icon = true,
    desc = "%s игр на одном герое", total = function(g) return g.top_games, g.top_games_hero end,
    tiers = { { 25, "B" }, { 50, "S" }, { 100, "G" }, { 250, "P" } } }
F { id = "hero_wins", cat = "career", name = "Фирменный герой", icon = "item:bottle", hero_icon = true,
    desc = "%s побед на одном герое", total = function(g) return g.top_wins, g.top_wins_hero end,
    tiers = { { 25, "B" }, { 50, "S" }, { 100, "G" } } }
F { id = "hero_wr", cat = "career", name = "Коронный герой", icon = "item:bottle", hero_icon = true, show = "pct",
    desc = "%s побед на герое (от 50 игр)", total = best_hero_winrate,
    tiers = { { 0.6, "G" } } }
F { id = "arsenal", cat = "career", name = "Арсенал", icon = "spell:invoker_invoke", desc = "%s героев с 10+ победами",
    total = function(g) return g.heroes10 end,
    tiers = { { 5, "B" }, { 10, "S" }, { 20, "G" }, { 40, "P" } } }
F { id = "day", cat = "career", name = "Без остановки", icon = "item:enchanted_mango", desc = "%s игр за один день",
    total = function(g) return g.best_day end,
    tiers = { { 5, "B" }, { 8, "S" }, { 12, "G" } } }

-- Подвиги за матч
F { id = "kills", cat = "feat", name = "Истребитель", icon = "spell:axe_culling_blade", desc = "%s убийств за матч",
    match = function(r) return r.k end,
    tiers = { { 15, "B" }, { 25, "S" }, { 35, "G" }, { 45, "P" } } }
F { id = "assists", cat = "feat", name = "Душа команды", icon = "item:guardian_greaves", desc = "%s ассистов за матч",
    match = function(r) return r.a end,
    tiers = { { 20, "B" }, { 30, "S" }, { 40, "G" }, { 50, "P" } } }
F { id = "kda", cat = "feat", name = "Чистая работа", icon = "item:butterfly", show = "kda", desc = "KDA %s в победе",
    match = function(r)
        if r.w then
            return (r.k + r.a) / max(r.d, 1)
        end
    end,
    tiers = { { 10, "B" }, { 20, "S" }, { 40, "G" }, { 60, "P" } } }
F { id = "nodeath", cat = "feat", name = "Неприкасаемый", icon = "item:black_king_bar", binary = true,
    desc = "Победа без единой смерти",
    match = function(r)
        if r.w and r.d == 0 then
            return 1
        end
    end,
    tiers = { { 1, "G" } } }
F { id = "immortal", cat = "feat", name = "Бессмертный", icon = "spell:skeleton_king_reincarnation", binary = true,
    desc = "Победа без смертей и с 10+ убийствами",
    match = function(r)
        if r.w and r.d == 0 and r.k >= 10 then
            return 1
        end
    end,
    tiers = { { 1, "P" } } }
F { id = "lh", cat = "feat", name = "Фермер", icon = "item:bfury", desc = "%s ластхитов за матч",
    match = function(r) return r.lh end,
    tiers = { { 300, "B" }, { 500, "S" }, { 700, "G" }, { 900, "P" } } }
F { id = "denies", cat = "feat", name = "Жадина", icon = "item:quelling_blade", desc = "%s денаев за матч",
    match = function(r) return r.dn end,
    tiers = { { 15, "B" }, { 25, "S" }, { 40, "G" }, { 55, "P" } } }
F { id = "gpm", cat = "feat", name = "Золотая лихорадка", icon = "item:hand_of_midas", desc = "GPM %s",
    match = function(r) return r.gp end,
    tiers = { { 600, "B" }, { 750, "S" }, { 900, "G" }, { 1000, "P" } } }
F { id = "xpm", cat = "feat", name = "Быстрый рост", icon = "item:tome_of_knowledge", desc = "XPM %s",
    match = function(r) return r.xp end,
    tiers = { { 800, "B" }, { 1000, "S" }, { 1300, "G" }, { 1600, "P" } } }
F { id = "hero_damage", cat = "feat", name = "Молотилка", icon = "item:greater_crit", desc = "%s урона по героям",
    match = function(r) return r.hd end,
    tiers = { { 40000, "B" }, { 70000, "S" }, { 100000, "G" }, { 150000, "P" } } }
F { id = "tower_damage", cat = "feat", name = "Сносчик", icon = "item:desolator", desc = "%s урона по постройкам",
    match = function(r) return r.td end,
    tiers = { { 8000, "B" }, { 15000, "S" }, { 20000, "G" }, { 30000, "P" } } }
F { id = "healing", cat = "feat", name = "Лекарь", icon = "item:mekansm", desc = "%s лечения за матч",
    match = function(r) return r.hh end,
    tiers = { { 5000, "B" }, { 12000, "S" }, { 20000, "G" }, { 30000, "P" } } }
F { id = "fast", cat = "feat", name = "Блиц", icon = "item:blink", show = "time", lower = true,
    desc = "Победа быстрее %s", match = win_duration,
    tiers = { { 1500, "B" }, { 1200, "S" }, { 1020, "G" }, { 900, "P" } } }
F { id = "long", cat = "feat", name = "Марафонец", icon = "item:refresher", show = "time",
    desc = "Победа после %s", match = in_win("du"),
    tiers = { { 3600, "B" }, { 4200, "S" }, { 4800, "G" }, { 5400, "P" } } }

-- Turbo - отдельно: там всё быстрее и проще
F { id = "t_games", cat = "turbo", name = "Турбо: стаж", icon = "item:phase_boots", desc = "%s игр в Turbo",
    total = function(g) return g.games end,
    tiers = { { 50, "B" }, { 100, "S" }, { 250, "G" }, { 500, "P" } } }
F { id = "t_wins", cat = "turbo", name = "Турбо: победитель", icon = "item:cheese", desc = "%s побед в Turbo",
    total = function(g) return g.wins end,
    tiers = { { 25, "B" }, { 50, "S" }, { 150, "G" }, { 300, "P" } } }
F { id = "t_kills", cat = "turbo", name = "Турбо: истребитель", icon = "item:rapier", desc = "%s убийств за матч",
    match = function(r) return r.k end,
    tiers = { { 20, "B" }, { 30, "S" }, { 40, "G" } } }
F { id = "t_fast", cat = "turbo", name = "Турбо: блиц", icon = "item:travel_boots_2", show = "time", lower = true,
    desc = "Победа быстрее %s", match = win_duration,
    tiers = { { 1200, "B" }, { 900, "S" }, { 720, "G" } } }

-- Позор - скрытые, пока не получишь
F { id = "deaths", cat = "shame", hidden = true, name = "Мальчик для битья", icon = "item:tango",
    desc = "%s смертей за матч", match = function(r) return r.d end,
    tiers = { { 15, "B" }, { 20, "S" }, { 25, "G" } } }
F { id = "tourist", cat = "shame", hidden = true, name = "Турист", icon = "item:ward_observer", binary = true,
    desc = "Матч дольше 20 минут без убийств и ассистов",
    match = function(r)
        if r.k == 0 and r.a == 0 and (r.du or 0) >= 1200 then
            return 1
        end
    end,
    tiers = { { 1, "B" } } }
F { id = "lose_streak", cat = "shame", hidden = true, name = "Чёрная полоса", icon = "item:smoke_of_deceit",
    desc = "%s поражений подряд", total = function(g) return g.best_loss_streak end,
    tiers = { { 5, "B" }, { 8, "S" }, { 12, "G" } } }
F { id = "long_loss", cat = "shame", hidden = true, name = "Всё было зря", icon = "item:clarity", show = "time",
    desc = "Поражение после %s",
    match = function(r)
        if not r.w then
            return r.du
        end
    end,
    tiers = { { 4200, "B" }, { 5400, "S" } } }
F { id = "carried", cat = "shame", hidden = true, name = "Затащили", icon = "item:flask",
    desc = "Победа с %s смертями", match = in_win("d"),
    tiers = { { 15, "S" } } }
F { id = "samurai", cat = "shame", hidden = true, name = "Поражение с 20+ убийствами", binary = true,
    icon = "spell:juggernaut_omni_slash", desc = "Поражение с 20+ убийствами",
    match = function(r)
        if not r.w and r.k >= 20 then
            return 1
        end
    end,
    tiers = { { 1, "B" } } }

-- Особые: даты, перерывы, серии героев, необычные матчи
F { id = "night", cat = "special", name = "Ночная победа", icon = "spell:night_stalker_darkness", binary = true,
    desc = "Победа в матче, начатом с 2 до 5 ночи",
    match = function(r, g, c)
        if r.w and c.date.hour >= 2 and c.date.hour < 5 then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "new_year", cat = "special", name = "Новый год", icon = "spell:tusk_snowball", binary = true,
    desc = "Матч 31 декабря или 1 января",
    match = function(r, g, c)
        local d = c.date
        if (d.month == 12 and d.day == 31) or (d.month == 1 and d.day == 1) then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "birthday", cat = "special", name = "День рождения Dota 2", icon = "item:cheese", binary = true,
    desc = "Матч 9 июля — в день выхода Dota 2",
    match = function(r, g, c)
        if c.date.month == 7 and c.date.day == 9 then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "comeback", cat = "special", name = "Возвращение после перерыва", icon = "item:tpscroll",
    binary = true, desc = "Сыграть после перерыва больше 30 дней",
    match = function(r, g, c)
        if c.gap and c.gap >= BREAK_DAYS * 86400 then
            return 1
        end
    end,
    tiers = { { 1, "B" } } }
F { id = "phoenix", cat = "special", name = "Победа после чёрной полосы", icon = "spell:phoenix_supernova",
    binary = true, desc = "Победа сразу после 5+ поражений подряд",
    match = function(r, g, c)
        if r.w and c.loss_before >= 5 then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "variety", cat = "special", name = "Разные герои подряд", icon = "spell:chaos_knight_chaos_bolt",
    desc = "%s матчей подряд на разных героях", total = function(g) return g.best_distinct_run end,
    tiers = { { 10, "S" } } }
F { id = "same_hero", cat = "special", name = "Один герой подряд", icon = "spell:weaver_time_lapse", hero_icon = true,
    desc = "%s матчей подряд на одном герое", total = function(g) return g.best_same_run, g.best_same_run_hero end,
    tiers = { { 10, "G" } } }
F { id = "pacifist", cat = "special", name = "Победа без убийств", icon = "item:ghost", binary = true,
    desc = "Победа без единого убийства",
    match = function(r)
        if r.w and r.k == 0 then
            return 1
        end
    end,
    tiers = { { 1, "G" } } }
F { id = "cardinal", cat = "special", name = "Победа ассистами", icon = "item:glimmer_cape", binary = true,
    desc = "Победа: не больше 2 убийств и 25+ ассистов",
    match = function(r)
        if r.w and r.k <= 2 and r.a >= 25 then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "solo", cat = "special", name = "Всё сам", icon = "spell:legion_commander_duel", binary = true,
    desc = "25+ убийств и не больше 5 ассистов",
    match = function(r)
        if r.k >= 25 and r.a <= 5 then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "balance", cat = "special", name = "K = D = A", icon = "item:sange_and_yasha", binary = true,
    desc = "Убийств, смертей и ассистов поровну (от 5)",
    match = function(r)
        if r.k >= 5 and r.k == r.d and r.d == r.a then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "invoker", cat = "special", name = "Победы на Invoker", icon = "hero:npc_dota_hero_invoker",
    desc = "%s побед на Invoker",
    total = function(g)
        local hs = g.heroes[INVOKER_ID]
        return hs and hs.w or 0
    end,
    tiers = { { 50, "G" } } }

-- События живого матча (v0.2): только в записях, которые скрипт вёл сам (поле x), в истории OpenDota их нет.
-- live - считается по ходу матча (уведомление сразу), остальные с x - в конце (нужна победа).
local function x_value(field)
    return function(r)
        return r.x and r.x[field]
    end
end

F { id = "multikill", cat = "feat", live = true, name = "Мультикилл", icon = "spell:bloodseeker_bloodrage",
    desc = "%s убийств подряд", match = x_value("mk"),
    tiers = { { 3, "B", "Тройное убийство" }, { 4, "S", "Ультра-убийство" }, { 5, "P", "Рампага" } } }
F { id = "kill_streak", cat = "feat", live = true, name = "Серия убийств", icon = "spell:ursa_enrage",
    desc = "Серия из %s убийств без смерти", match = x_value("streak"),
    tiers = { { 5, "B" }, { 7, "S" }, { 10, "G" } } }
F { id = "first_blood", cat = "feat", live = true, name = "Ранняя первая кровь", icon = "spell:bloodseeker_rupture",
    binary = true, desc = "Первая кровь до 1:30",
    match = function(r)
        local x = r.x
        if x and x.fb == 1 and (x.fb_t or math.huge) <= EARLY_FIRST_BLOOD then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "aegis_steal", cat = "feat", live = true, name = "Украденный Aegis", icon = "item:aegis", binary = true,
    desc = "Украсть Aegis", match = x_value("aegis_steal"),
    tiers = { { 1, "G" } } }
F { id = "aegis", cat = "feat", live = true, name = "Поднял Aegis", icon = "item:aegis", binary = true,
    desc = "Поднять Aegis", match = x_value("aegis"),
    tiers = { { 1, "B" } } }
F { id = "roshan", cat = "feat", live = true, name = "Добил Рошана", icon = "item:refresher_shard", binary = true,
    desc = "Добить Рошана", match = x_value("roshan"),
    tiers = { { 1, "S" } } }
F { id = "tormentor", cat = "feat", live = true, name = "Добил торментора", icon = "item:aghanims_shard",
    binary = true, desc = "Добить торментора", match = x_value("tormentor"),
    tiers = { { 1, "S" } } }
F { id = "courier", cat = "feat", live = true, name = "Убил курьера", icon = "item:courier", binary = true,
    desc = "Убить вражеского курьера", match = x_value("courier"),
    tiers = { { 1, "B" } } }
F { id = "wards", cat = "feat", live = true, name = "Снёс варды", icon = "item:ward_sentry",
    desc = "%s вардов врага за матч", match = x_value("wards"),
    tiers = { { 10, "S" } } }
F { id = "stacks", cat = "feat", live = true, name = "Стаки", icon = "item:helm_of_the_dominator",
    desc = "%s стаков за матч", match = x_value("stacks"),
    tiers = { { 10, "S" } } }
F { id = "runes", cat = "feat", live = true, name = "Руны", icon = "item:bottle",
    desc = "%s рун за матч", match = x_value("runes"),
    tiers = { { 15, "S" } } }
F { id = "lh10", cat = "feat", live = true, name = "Ластхиты к 10:00", icon = "item:maelstrom",
    desc = "%s ластхитов к 10:00", match = x_value("lh10"),
    tiers = { { 70, "G" } } }
F { id = "kill_comeback", cat = "feat", name = "Камбэк", icon = "spell:abaddon_borrowed_time", binary = true,
    desc = "Победа после отставания на 10+ убийств",
    match = function(r)
        if r.w and r.x and (r.x.deficit or 0) >= 10 then
            return 1
        end
    end,
    tiers = { { 1, "G" } } }
F { id = "buyback_win", cat = "feat", name = "Выкуп и победа", icon = "item:bloodstone", binary = true,
    desc = "Выкупиться и победить",
    match = function(r)
        if r.w and r.x and r.x.bb then
            return 1
        end
    end,
    tiers = { { 1, "S" } } }
F { id = "neutral_death", cat = "shame", hidden = true, live = true, name = "Убит нейтралом", binary = true,
    icon = "spell:lycan_summon_wolves", desc = "Погибнуть от лесного крипа", match = x_value("neutral_death"),
    tiers = { { 1, "B" } } }
F { id = "fb_victim", cat = "shame", hidden = true, live = true, name = "Отдал первую кровь", binary = true,
    icon = "item:faerie_fire", desc = "Отдать первую кровь",
    match = function(r)
        if r.x and r.x.fb == -1 then
            return 1
        end
    end,
    tiers = { { 1, "B" } } }

-- 1, если событие матча x[field] набрало n (несколько убийств одним применением и т.п.)
local function x_reached(field, n)
    return function(r)
        if r.x and (r.x[field] or 0) >= n then
            return 1
        end
    end
end

-- Способности героев (v0.3, v0.4): кто и чем убил - OnEntityKilled, крит - OnEntityHurt (unsafe-режим);
-- воскрешение и Infest - опрос героя. Как все Особые - рейтинг и All Pick.
F { id = "sunstrike", cat = "special", live = true, name = "Убийство Sun Strike", binary = true,
    icon = "spell:invoker_sun_strike", desc = "Invoker: убить врага Sun Strike", match = x_value("sunstrike"),
    tiers = { { 1, "S" } } }
F { id = "sunstrike_blind", cat = "special", live = true, name = "Sun Strike вслепую", binary = true,
    icon = "spell:invoker_sun_strike", desc = "Invoker: убить Sun Strike врага, которого не видно",
    match = x_value("sunstrike_blind"),
    tiers = { { 1, "G" } } }
F { id = "hook", cat = "special", live = true, name = "Убийство хуком", binary = true,
    icon = "spell:pudge_meat_hook", desc = "Pudge: убить врага хуком", match = x_value("hook"),
    tiers = { { 1, "S" } } }
F { id = "mana_void", cat = "special", live = true, name = "Mana Void по двоим", binary = true,
    icon = "spell:antimage_mana_void", desc = "Anti-Mage: убить двоих одним Mana Void",
    match = x_reached("void_multi", 2),
    tiers = { { 1, "G" } } }
F { id = "duels", cat = "special", live = true, name = "Дуэли", icon = "spell:legion_commander_duel",
    desc = "Legion Commander: выиграть %s дуэли за матч", match = x_value("duels"),
    tiers = { { 3, "S" } } }
F { id = "tempest", cat = "special", live = true, name = "Убийство двойником", binary = true,
    icon = "spell:arc_warden_tempest_double", desc = "Arc Warden: убить врага двойником", match = x_value("tempest"),
    tiers = { { 1, "S" } } }
F { id = "mines", cat = "special", live = true, name = "Мины", icon = "spell:techies_land_mines",
    desc = "Techies: %s убийств минами за матч", match = x_value("mines"),
    tiers = { { 5, "G" } } }
F { id = "stolen_spell", cat = "special", live = true, name = "Его же оружием", binary = true,
    icon = "spell:rubick_spell_steal", desc = "Rubick: убить врага его же украденной способностью",
    match = x_value("stolen_spell"),
    tiers = { { 1, "G" } } }
F { id = "requiem", cat = "special", live = true, name = "Requiem по двоим", binary = true,
    icon = "spell:nevermore_requiem", desc = "Shadow Fiend: убить двоих одним Requiem of Souls",
    match = x_reached("requiem_multi", 2),
    tiers = { { 1, "G" } } }
F { id = "omnislash", cat = "special", live = true, name = "Omnislash по двоим", binary = true,
    icon = "spell:juggernaut_omni_slash", desc = "Juggernaut: убить двоих за один Omnislash",
    match = x_reached("omni_multi", 2),
    tiers = { { 1, "G" } } }
F { id = "crit", cat = "special", live = true, name = "Крит", icon = "spell:phantom_assassin_coup_de_grace",
    desc = "Phantom Assassin: крит по герою на %s урона", match = x_value("crit"),
    tiers = { { 1000, "S" } } }
F { id = "haunt", cat = "special", live = true, name = "Haunt", icon = "spell:spectre_haunt",
    desc = "Spectre: %s убийства за один Haunt", match = x_value("haunt"),
    tiers = { { 3, "G" } } }
F { id = "meepo", cat = "special", live = true, name = "Все Meepo", icon = "spell:meepo_divided_we_stand",
    desc = "Meepo: героев за матч убили %s разных Meepo", match = x_value("meepo"),
    tiers = { { 4, "G" } } }
F { id = "reincarnation", cat = "special", live = true, name = "Убийство после воскрешения", binary = true,
    icon = "spell:skeleton_king_reincarnation", desc = "Wraith King: убить героя в первые 10 с после воскрешения",
    match = x_value("reincarnation"),
    tiers = { { 1, "S" } } }
F { id = "infest", cat = "special", live = true, name = "Выход из Infest", binary = true,
    icon = "spell:life_stealer_infest", desc = "Lifestealer: убить героя в первые 3 с после выхода из Infest",
    match = x_value("infest"),
    tiers = { { 1, "S" } } }
F { id = "chaos_bolt", cat = "special", live = true, name = "Убийство Chaos Bolt", binary = true,
    icon = "spell:chaos_knight_chaos_bolt", desc = "Chaos Knight: добить героя Chaos Bolt",
    match = x_value("chaos_bolt"),
    tiers = { { 1, "S" } } }
F { id = "pl_illusions", cat = "special", live = true, name = "Убийства иллюзиями",
    icon = "spell:phantom_lancer_juxtapose", desc ="Phantom Lancer: иллюзии добили %s героев за матч", match = x_value("pl_illusions"),
    tiers = { { 3, "S" } } }

-- Эти значения за матч только растут - их можно проверять по ходу матча (уведомление сразу).
for _, id in ipairs({ "kills", "assists", "lh", "denies", "hero_damage", "healing", "t_kills", "deaths" }) do
    FAMILY_BY_ID[id].grows = true
end

-- Имена ступеней - отсылки к фильмам, играм, книгам и мемам; цель ступени - в desc.
local NAMES <const> = {
    games = { "Опасное это дело — выходить из дому", "Ещё один ход", "Тысяча и одна ночь", "Бесконечная история" },
    wins = { "Лок'тар огар!", "Пришёл, увидел, победил", "Игра престолов", "Один трон, чтобы править всеми" },
    streak = { "Я — скорость", "Семь самураев", "Неудержимые", "Я — легенда" },
    ranked = { "Маленький шаг для человека", "Это Спарта!", "Через тернии к звёздам", "Останется только один" },
    heroes = { "Кто я?", "Безликий", "Тысячеликий герой", "Поймать их всех" },
    hero_games = { "Начало прекрасной дружбы", "Моя прелесть", "Пока смерть не разлучит нас", "Всегда" },
    hero_wins = { "Секретного ингредиента нет", "Воин Дракона", "В сотне битв" },
    hero_wr = { "Избранный" },
    arsenal = { "Пятый элемент", "Джентльмены удачи", "Лига выдающихся джентльменов", "Али-Баба и сорок разбойников" },
    day = { "Неспящие в Сиэтле", "Восемь с половиной", "Двенадцать стульев" },
    kills = { "Ах, свежее мясо!", "Убить Билла", "Фростморн жаждет крови", "Я стал смертью, разрушителем миров" },
    assists = { "Один за всех", "Братство Кольца", "Не могу нести его, но могу нести тебя", "Мы — Грут" },
    kda = { "Элементарно, Ватсон", "Профессионал", "Агент 47", "Бог войны" },
    nodeath = { "Неуловимые мстители" },
    immortal = { "Кощей Бессмертный" },
    lh = { "Работа, работа", "Нужно больше золота", "Голодные игры", "Всё, чего касается свет" },
    denies = { "Так не доставайся же ты никому!", "Собака на сене", "Скупой рыцарь", "Очищение Стратхольма" },
    gpm = { "Остров сокровищ", "Золотая лихорадка", "Прикосновение Мидаса", "Волк с Уолл-стрит" },
    xpm = { "Ученик чародея", "Я знаю кунг-фу", "Сила в нём велика", "Больше девяти тысяч!" },
    hero_damage = { "Халк крушить!", "Выпустить Кракена!", "Армагеддон", "Судный день" },
    tower_damage = { "Иерихонские трубы", "Падение Лордерона", "Троя пала", "Карфаген должен быть разрушен" },
    healing = { "Айболит", "Доктор Хаус", "Живая вода", "Святой Грааль" },
    fast = { "Скорость", "Беги, Форрест, беги!", "88 миль в час", "Остановись, мгновенье!" },
    long = { "Режиссёрская версия", "Туда и обратно", "Вокруг света за 80 дней", "Война и мир" },
    t_games = { "Форсаж", "Час пик", "Безумный Макс", "Время — деньги" },
    t_wins = { "Молния Маккуин", "Такси", "Перевозчик", "Токийский дрифт" },
    t_kills = { "Ярость", "Хищник", "Коммандо" },
    t_fast = { "Угнать за 60 секунд", "Флэш", "Соник" },
    deaths = { "Пир во время чумы", "YOU DIED", "Мёртвые души" },
    tourist = { "Обломов" },
    lose_streak = { "33 несчастья", "Горе от ума", "Прощай, оружие!" },
    long_loss = { "Унесённые ветром", "Сизифов труд" },
    carried = { "Души мне не жаль… Я проживу и без неё" },
    samurai = { "Последний самурай" },
    night = { "Ночной дозор" },
    new_year = { "Какая гадость эта ваша заливная рыба" },
    birthday = { "С днём рождения, Dota" },
    comeback = { "Возвращение джедая" },
    phoenix = { "Возрождение легенды" },
    variety = { "Жизнь как коробка конфет" },
    same_hero = { "День сурка" },
    pacifist = { "Путь пацифиста" },
    cardinal = { "Серый кардинал" },
    solo = { "Один дома" },
    balance = { "Идеально сбалансировано" },
    invoker = { "Десять заклинаний, Карл!" },
    multikill = { "Бог любит троицу", "Четвёртый всадник", "И один в поле воин" },
    kill_streak = { "Бойня номер пять", "Семь", "И никого не стало" },
    aegis = { "Живёшь только дважды" },
    tormentor = { "Тессеракт" },
    runes = { "Старик Хоттабыч" },
    first_blood = { "Рэмбо: Первая кровь" },
    aegis_steal = { "Где Aegis, Лебовски?" },
    roshan = { "Убить дракона" },
    courier = { "Почтальон Печкин" },
    wards = { "Слепой Пью" },
    stacks = { "Плюшкин" },
    lh10 = { "Терминатор" },
    kill_comeback = { "Миссия невыполнима" },
    buyback_win = { "Жизнь взаймы" },
    neutral_death = { "Красная Шапочка" },
    fb_victim = { "Первый блин комом" },
    sunstrike = { "Солнечный удар" },
    sunstrike_blind = { "Восславь Солнце!" },
    hook = { "Get over here!" },
    mana_void = { "Экспеллиармус!" },
    duels = { "Ровно в полдень" },
    tempest = { "Двое из ларца, одинаковых с лица" },
    mines = { "Повелитель бури" },
    stolen_spell = { "Кто с мечом к нам придёт, от меча и погибнет" },
    requiem = { "Реквием по мечте" },
    omnislash = { "Затойчи" },
    crit = { "Finish him!" },
    haunt = { "Призрак бродит по Европе" },
    meepo = { "Агент Смит" },
    reincarnation = { "Король умер — да здравствует король!" },
    infest = { "Чужой" },
    chaos_bolt = { "Бог не играет в кости" },
    pl_illusions = { "Престиж" },
}
for id, names in pairs(NAMES) do
    local f = FAMILY_BY_ID[id]
    if f then
        f.names = names
    else
        log("NAMES: no achievement %s", id)
    end
end
for _, f in ipairs(FAMILIES) do
    if not f.names or #f.names ~= #f.tiers then
        log("NAMES: %s - %d names for %d tiers", f.id, f.names and #f.names or 0, #f.tiers)
    end
end

local TOTAL_TIERS = 0
for _, f in ipairs(FAMILIES) do
    TOTAL_TIERS = TOTAL_TIERS + #f.tiers
end

local function tier_key(f, i)
    return f.id .. ":" .. i
end

local function tier_points(key)
    local id, i = key:match("^(.+):(%d+)$")
    local f = id and FAMILY_BY_ID[id]
    local tier = f and f.tiers[tonumber(i)]
    return tier and RANKS[tier[2]].points or 0
end

local function show_value(f, v)
    if v == nil then
        return "—"
    elseif f.show == "time" then
        return Timer.Format(v)
    elseif f.show == "pct" then
        return ("%d%%"):format(floor(v * 100))
    elseif f.show == "kda" then
        return v < 10 and ("%.1f"):format(v) or fmt_num(v)
    end
    return fmt_num(v)
end

local function tier_desc(f, i)
    local tier = f.tiers[i]
    local text = tier[3] or f.desc
    if f.binary then
        return text
    end
    return text:format(show_value(f, tier[1]))
end

local function tier_name(f, i)
    local names = f.names
    return names and (names[i] or names[#names]) or f.name
end

local function meets(f, value, target)
    if f.lower then
        return value <= target
    end
    return value >= target
end

-- Уровень по сумме очков: на уровень L нужно 25·L·(L+1) (50, 150, 300, 500, 750...).
local function level_of(points)
    local level = 0
    while 25 * (level + 1) * (level + 2) <= points do
        level = level + 1
    end
    return level, 25 * level * (level + 1), 25 * (level + 1) * (level + 2)
end

--#endregion

--#region Heroes

local hero_units = {} -- id -> "npc_dota_hero_..." | false

local function hero_unit(id)
    id = int(id)
    if not id then
        return nil
    end
    local unit = hero_units[id]
    if unit == nil then
        local name = safe(Engine.GetHeroNameByID, id)
        if type(name) == "string" and name ~= "" then
            unit = name:find("^npc_dota_hero_") and name or "npc_dota_hero_" .. name
        else
            unit = false
        end
        hero_units[id] = unit
    end
    return unit or nil
end

local hero_titles = {}
local function hero_title(id)
    local unit = hero_unit(id)
    if not unit then
        return "#" .. tostring(int(id))
    end
    local title = hero_titles[unit]
    if not title then
        title = safe(Engine.GetDisplayNameByUnitName, unit)
        if type(title) ~= "string" or title == "" then
            title = unit:gsub("^npc_dota_hero_", ""):gsub("_", " ")
        end
        hero_titles[unit] = title
    end
    return title
end

-- Сколько всего героев в игре - для ступени «Все герои». ID идут с пропусками, берём с запасом.
local function count_heroes()
    local count = 0
    for id = 1, 200 do
        if hero_unit(id) then
            count = count + 1
        end
    end
    return count
end

--#endregion

--#region History

-- Какая категория у матча: "normal", "turbo" или nil (не считается).
local function scope_of(r)
    if not COUNTED_LOBBIES[r.l] then
        return nil
    elseif r.m == TURBO_MODE then
        return "turbo"
    elseif NORMAL_MODES[r.m] then
        return "normal"
    end
    return nil
end

-- Для Особых: рейтинг (лобби 7) или обычный All Pick (режимы 1 и 22 - сейчас All Pick это 22).
local AP_MODES <const> = { [1] = true, [22] = true }
local function is_ap(r)
    return scope_of(r) == "normal" and (r.l == RANKED_LOBBY or AP_MODES[r.m] == true)
end

local function id_key(v)
    local n = int(v)
    return n and tostring(n) or nil
end

-- Запись матча из ответа OpenDota /players/{id}/matches.
local function record_from_opendota(m)
    local slot = int(m.player_slot)
    if not (slot and int(m.hero_id) and int(m.start_time)) or m.radiant_win == nil then
        return nil
    end
    return {
        h = int(m.hero_id), w = (slot < 128) == (m.radiant_win == true),
        k = int(m.kills) or 0, d = int(m.deaths) or 0, a = int(m.assists) or 0,
        du = int(m.duration) or 0, m = int(m.game_mode), l = int(m.lobby_type), t = int(m.start_time),
        lh = int(m.last_hits), dn = int(m.denies), gp = int(m.gold_per_min), xp = int(m.xp_per_min),
        hd = int(m.hero_damage), td = int(m.tower_damage), hh = int(m.hero_healing),
    }
end

local function new_totals()
    return {
        games = 0, wins = 0, ranked_wins = 0,
        win_streak = 0, best_win_streak = 0, loss_streak = 0, best_loss_streak = 0,
        heroes = {}, distinct = 0, heroes10 = 0,
        top_games = 0, top_games_hero = nil, top_wins = 0, top_wins_hero = nil,
        day = nil, day_games = 0, best_day = 0,
        last_hero = nil, same_run = 0, best_same_run = 0, best_same_run_hero = nil,
        last_pos = {}, distinct_run = 0, best_distinct_run = 0,
    }
end

local function add_to_totals(g, r, c)
    g.games = g.games + 1
    local hs = g.heroes[r.h]
    if not hs then
        hs = { g = 0, w = 0 }
        g.heroes[r.h] = hs
        g.distinct = g.distinct + 1
    end
    hs.g = hs.g + 1
    if hs.g > g.top_games then
        g.top_games, g.top_games_hero = hs.g, r.h
    end
    if r.w then
        g.wins = g.wins + 1
        hs.w = hs.w + 1
        if hs.w > g.top_wins then
            g.top_wins, g.top_wins_hero = hs.w, r.h
        end
        if hs.w == 10 then
            g.heroes10 = g.heroes10 + 1
        end
        if r.l == RANKED_LOBBY then
            g.ranked_wins = g.ranked_wins + 1
        end
        g.win_streak, g.loss_streak = g.win_streak + 1, 0
        g.best_win_streak = max(g.best_win_streak, g.win_streak)
    else
        g.win_streak, g.loss_streak = 0, g.loss_streak + 1
        g.best_loss_streak = max(g.best_loss_streak, g.loss_streak)
    end
    local day = c.date.year * 1000 + c.date.yday
    if day == g.day then
        g.day_games = g.day_games + 1
    else
        g.day, g.day_games = day, 1
    end
    g.best_day = max(g.best_day, g.day_games)
    -- серии подряд: на одном герое и на разных героях (разные - пока не встретился герой из этой серии)
    g.same_run = r.h == g.last_hero and g.same_run + 1 or 1
    g.last_hero = r.h
    if g.same_run > g.best_same_run then
        g.best_same_run, g.best_same_run_hero = g.same_run, r.h
    end
    local last = g.last_pos[r.h]
    g.distinct_run = last and min(g.distinct_run + 1, g.games - last) or g.distinct_run + 1
    g.last_pos[r.h] = g.games
    g.best_distinct_run = max(g.best_distinct_run, g.distinct_run)
end

-- Повтор истории по времени. Возвращает:
--   got[ключ ступени] = { t = время матча, id = матч }, value[id семейства] - лучшее значение (у итоговых -
--   текущее), hero[id семейства] - герой этого значения, totals.normal / turbo / ap, points, count.
-- Матч рейтинга или All Pick идёт и в normal, и в ap (итоги для Особых считаются отдельно).
local function replay(records)
    local st = { got = {}, value = {}, hero = {},
        totals = { normal = new_totals(), turbo = new_totals(), ap = new_totals() },
        points = 0, count = 0, matches = { normal = 0, turbo = 0 } }
    local c = {}        -- контекст матча для match(r, g, c)
    local prev_t = nil  -- начало прошлого засчитанного матча (любой категории)
    local scopes = {}
    for _, r in ipairs(records) do
        -- r.w == nil - матч из живой записи без итога (вышел до конца): ждём итог от OpenDota
        local scope = r.w ~= nil and scope_of(r) or nil
        if scope then
            c.date = os.date("*t", r.t)
            c.gap = prev_t and r.t - prev_t or nil
            prev_t = r.t
            st.matches[scope] = st.matches[scope] + 1
            scopes[1], scopes[2] = scope, is_ap(r) and "ap" or nil
            for _, s in ipairs(scopes) do
                local g = st.totals[s]
                c.loss_before = g.loss_streak
                add_to_totals(g, r, c)
                for _, f in ipairs(FAMILIES) do
                    if f.scope == s then
                        local v, hero
                        if f.match then
                            v, hero = f.match(r, g, c), r.h
                        else
                            v, hero = f.total(g)
                        end
                        if v then
                            local prev = st.value[f.id]
                            if f.match and (prev == nil or (f.lower and v < prev) or (not f.lower and v > prev)) then
                                st.value[f.id], st.hero[f.id] = v, hero
                            end
                            for i, tier in ipairs(f.tiers) do
                                local key = tier_key(f, i)
                                if not st.got[key] and meets(f, v, tier[1]) then
                                    st.got[key] = { t = r.t, id = r.id }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- итоговые значения - на сейчас (винрейт мог упасть, а ступень остаётся)
    for _, f in ipairs(FAMILIES) do
        if f.total then
            st.value[f.id], st.hero[f.id] = f.total(st.totals[f.scope])
        end
    end
    for key in pairs(st.got) do
        st.points = st.points + tier_points(key)
        st.count = st.count + 1
    end
    return st
end

--#endregion

--#region State

local account = nil  -- account id (Steam32)
local data = nil     -- сохранённое: { v, account, matches = { [id] = запись }, seen = { [ступень] = true }, synced_at, imported }
local records = {}   -- записи по времени
local state = replay(records)
local dirty = false  -- файл надо записать (при первой возможности вне матча)
local live_merged = false -- живая запись перенесена в data: её файл очистить после записи основного
local sync = { busy = false, next_try = 0, status = nil, force = false }

local toasts = {} -- очередь уведомлений

local function save()
    if not (account and data) then
        return
    end
    if match_running() then
        dirty = true
        return
    end
    local started = os.clock()
    local ok, err = pcall(Store.Save, "achievements_" .. account, data)
    if ok then
        dirty = false
        log("saved %d matches in %.0f ms", #records, (os.clock() - started) * 1000)
        -- файл живого матча не нужен, только когда его данные уже на диске в основном файле
        if live_merged then
            live_merged = false
            pcall(Store.Save, "achievements_live_" .. account, { v = 1 })
        end
    else
        log("save failed: %s", tostring(err))
    end
end

local function build_records()
    local list = {}
    for id, r in pairs(data.matches) do
        r.id = id
        list[#list + 1] = r
    end
    table.sort(list, function(a, b)
        if a.t ~= b.t then
            return (a.t or 0) < (b.t or 0)
        end
        return a.id < b.id
    end)
    return list
end

local function points_of(keys)
    local points = 0
    for key in pairs(keys) do
        points = points + tier_points(key)
    end
    return points
end

local function push_toast(t)
    toasts[#toasts + 1] = t
end

local function tier_toast(key)
    local id, i = key:match("^(.+):(%d+)$")
    local f = FAMILY_BY_ID[id]
    i = tonumber(i)
    local tier = f and f.tiers[i]
    if not tier then
        return
    end
    local rank = RANKS[tier[2]]
    push_toast({
        kind = "tier", family = f, head = "Достижение получено", title = tier_name(f, i),
        text = rank.name .. " · " .. tier_desc(f, i), points = rank.points, color = rank.color,
    })
end

-- Пересчитать всё по записям; ступени, которых ещё не видели, - уведомления (announce) или молча в «видели».
local function refresh(announce)
    records = build_records()
    state = replay(records)
    -- ступени, которые больше не получены (поменялись правила), - из «видели»: получишь снова - будет уведомление.
    -- Во время матча не трогаем: полученное в нём уже показано, а в историю матч попадёт только после конца.
    if not match_running() then
        local dropped = 0
        for key in pairs(data.seen) do
            if not state.got[key] then
                data.seen[key] = nil
                dropped = dropped + 1
            end
        end
        if dropped > 0 then
            dirty = true
            log("%d tiers are no longer unlocked (rules changed)", dropped)
        end
    end
    local points_before = points_of(data.seen)
    local fresh = {}
    for key in pairs(state.got) do
        if not data.seen[key] then
            fresh[#fresh + 1] = key
            data.seen[key] = true
        end
    end
    if #fresh == 0 then
        return
    end
    dirty = true
    if not announce then
        return
    end
    table.sort(fresh, function(a, b) return state.got[a].t < state.got[b].t end)
    if #fresh <= MAX_SINGLE_TOASTS then
        for _, key in ipairs(fresh) do
            tier_toast(key)
        end
    else
        push_toast({
            kind = "summary", head = "Достижения", title = ("Новых достижений: %d"):format(#fresh),
            text = ("+%d очков"):format(points_of(data.seen) - points_before), color = RANKS.G.color,
        })
    end
    local level_before = level_of(points_before)
    local level_now = level_of(state.points)
    if level_now > level_before then
        push_toast({
            kind = "level", head = "Новый уровень", title = ("Уровень %d"):format(level_now),
            text = ("%s очков"):format(fmt_num(state.points)), color = RANKS.P.color, sound = SOUND_LEVEL,
        })
    end
end

-- Запись живого матча (скрипт ведёт её сам) - в маленьком файле, пока матч не перенесён в основной.
local function live_store_name()
    return "achievements_live_" .. account
end

local BASE_FIELDS <const> = { "h", "w", "k", "d", "a", "du", "m", "l", "t", "lh", "dn", "gp", "xp", "hd", "hh" }

-- Живая запись -> основной файл: события (x) - всегда; итог и счёт - только если OpenDota его ещё не прислал.
-- Без итога (вышел до конца) запись ждёт OpenDota и в достижениях пока не считается.
local function merge_live(rec)
    if type(rec) ~= "table" or not rec.id then
        return
    end
    local r = data.matches[rec.id]
    if not r then
        r = {}
        data.matches[rec.id] = r
    end
    r.x = r.x or {}
    for k, v in pairs(rec.x or {}) do
        r.x[k] = v
    end
    if r.w == nil then
        for _, field in ipairs(BASE_FIELDS) do
            if r[field] == nil then
                r[field] = rec[field]
            end
        end
    end
    dirty = true
end

-- Ступени, уже показанные в матче (из файла живой записи), - в «видели», чтобы после перезагрузки
-- скриптов или вылета не показать их снова. Возвращает их же.
local function restore_seen(saved)
    local keys = {}
    if type(saved.seen) == "table" then
        for key in pairs(saved.seen) do
            if type(key) == "string" then
                data.seen[key], keys[key] = true, true
            end
        end
    end
    return keys
end

local function local_account_id()
    local sid = tonumber(safe(GC.GetSteamID) or "")
    sid = sid and math.tointeger(sid)
    if sid and sid > STEAM64_BASE then
        return sid - STEAM64_BASE
    end
    return nil
end

local function load_account(acc)
    account = acc
    data = Store.Load("achievements_" .. acc, nil)
    if type(data) ~= "table" or data.v ~= STORE_VERSION then
        data = { v = STORE_VERSION, account = acc, matches = {}, seen = {}, synced_at = 0, imported = false }
    end
    data.matches = data.matches or {}
    data.seen = data.seen or {}
    data.synced_at = data.synced_at or 0
    -- живая запись прошлого матча, не перенесённая в основной файл (вышел из игры, перезагрузка скриптов)
    local saved = Store.Load(live_store_name(), nil)
    if type(saved) == "table" and type(saved.rec) == "table" then
        local running = match_running() and id_key(safe(GameRules.GetMatchID)) or nil
        if saved.rec.id ~= running then
            merge_live(saved.rec)
            restore_seen(saved)
            live_merged = true
            log("live record of match %s merged", tostring(saved.rec.id))
        end
    end
    -- новые достижения из обновления скрипта, полученные по старым матчам, - одним уведомлением
    refresh(data.imported)
    sync.next_try, sync.status = 0, nil
    log("account %d: %d matches, %d/%d tiers, %d points", acc, #records, state.count, TOTAL_TIERS, state.points)
end

-- Первая загрузка истории: всё, что открыто по старым матчам, - одним уведомлением, без россыпи.
local function finish_import()
    data.imported = true
    for key in pairs(state.got) do
        data.seen[key] = true
    end
    local level = level_of(state.points)
    push_toast({
        kind = "summary", head = "Достижения по истории матчей", sound = SOUND_LEVEL, color = RANKS.G.color,
        title = ("Открыто %d из %d"):format(state.count, TOTAL_TIERS),
        text = ("%s очков · уровень %d"):format(fmt_num(state.points), level),
    })
    dirty = true
end

local function merge_matches(list)
    local added = 0
    for _, m in ipairs(list) do
        local key = type(m) == "table" and id_key(m.match_id)
        local r = key and record_from_opendota(m)
        if r then
            local old = data.matches[key]
            if old then
                for k, v in pairs(r) do -- свои поля из живого матча (в следующих версиях) остаются
                    old[k] = v
                end
            else
                data.matches[key] = r
                added = added + 1
            end
        end
    end
    return added
end

local function project_query()
    local parts = {}
    for _, field in ipairs(MATCH_FIELDS) do
        parts[#parts + 1] = "project=" .. field
    end
    return table.concat(parts, "&")
end
local PROJECT <const> = project_query()

local function start_sync()
    if sync.busy or not account or match_running() then
        return
    end
    local acc = account
    local full = not data.imported or os.time() - data.synced_at > SYNC_FULL_AFTER
    local url = ("%splayers/%d/matches?significant=0&%s%s"):format(OPENDOTA, acc, PROJECT,
        full and "" or "&date=" .. SYNC_RECENT_DAYS)
    sync.busy, sync.force, sync.status = true, false, full and "загрузка истории…" or "обновление…"
    local started = os.clock()
    Http.GetJSON(url, {
        ttl = 0, timeout = SYNC_TIMEOUT,
        accept = function(d) return type(d) == "table" and d.error == nil end,
    }, function(list, err)
        sync.busy = false
        if acc ~= account then
            return -- аккаунт сменился, пока ждали
        end
        if type(list) ~= "table" or err then
            sync.status = "OpenDota: " .. tostring(err or "нет ответа")
            sync.next_try = os.clock() + SYNC_RETRY
            log("sync failed: %s", tostring(err))
            return
        end
        local decoded_at = os.clock()
        local added = merge_matches(list)
        data.synced_at = os.time()
        sync.status = nil
        if full and #list == 0 then
            sync.status = "OpenDota не вернул матчей: в настройках Dota включи «Открыть данные матчей»"
        end
        if data.imported then
            refresh(true)
        else
            records = build_records()
            state = replay(records)
            if #records > 0 then
                finish_import()
            end
        end
        save()
        log("sync %s: %d matches, %d new, request+decode %.2f s, replay %.0f ms; %d/%d tiers, %d points",
            full and "full" or "recent", #list, added, decoded_at - started, (os.clock() - decoded_at) * 1000,
            state.count, TOTAL_TIERS, state.points)
    end)
end

--#endregion

--#region Live match

-- Скрипт сам ведёт запись текущего матча: счёт, ластхиты к 10:00, мультикиллы, первая кровь, выкуп,
-- отставание по убийствам, стаки, воскрешение WK, Infest (опрос раз в 0,5 с); Aegis - из чата; Рошан,
-- курьеры, варды, смерть от нейтрала, приёмы героев - OnEntityKilled, крит PA - OnEntityHurt (только unsafe). Уведомление - сразу, как выполнено условие; итог
-- матча (победа, длительность) - на экране итогов, в основной файл - уже вне матча.
-- В лог пишутся сырые события чата и смертей (до LOG_EVENTS_PER_MATCH) - проверить, что поля значат.
local LOBBY_TYPES <const> = {
    CASUAL_MATCH = 0, PRACTICE = 1, COOP_BOT_MATCH = 4, COMPETITIVE_MATCH = 7, WEEKEND_TOURNEY = 9,
    LOCAL_BOT_MATCH = 10, SPECTATOR = 11, EVENT_MATCH = 12, NEW_PLAYER_POOL = 14, FEATURED_GAMEMODE = 15,
}
local TEAM_RADIANT <const> = Enum.TeamNum.TEAM_RADIANT or 2
local TEAM_DIRE <const> = Enum.TeamNum.TEAM_DIRE or 3
local TEAM_NEUTRAL <const> = Enum.TeamNum.TEAM_NEUTRAL or 4
local STATE_PRE_GAME <const> = Enum.GameState.DOTA_GAMERULES_STATE_PRE_GAME or 4
local STATE_IN_PROGRESS <const> = Enum.GameState.DOTA_GAMERULES_STATE_GAME_IN_PROGRESS or 5
local FORT_FLAG <const> = Enum.UnitTypeFlags.TYPE_FORT or 32 -- то же значение у TYPE_ANCIENT - фильтруем NPC.IsFort
local CHAT <const> = Enum.DotaChatMessage or {}
local CHAT_NAMES = {}
for name, value in pairs(CHAT) do
    CHAT_NAMES[value] = (name:gsub("^CHAT_MESSAGE_", ""))
end
-- какие события чата писать в лог (остальное - покупки, паузы - шум)
local CHAT_LOGGED = {}
for _, name in ipairs({ "HERO_KILL", "HERO_DENY", "STREAK_KILL", "FIRSTBLOOD", "BUYBACK", "AEGIS", "AEGIS_STOLEN",
    "DENIED_AEGIS", "ROSHAN_KILL", "MINIBOSS_KILL", "COURIER_LOST", "HERO_BANNED", "HERO_NOMINATED_BAN" }) do
    local value = CHAT["CHAT_MESSAGE_" .. name]
    if value then
        CHAT_LOGGED[value] = true
    end
end

local cur = nil      -- запись текущего матча (поля как у записи OpenDota + x = события); w - только в конце
local live = nil     -- служебное состояние слежки (не сохраняется)
local live_dirty = false
local live_skipped = nil -- матч, который не считаем (боты, демка, лобби), - чтобы не проверять каждый кадр
local live_wait = nil    -- { key, since }: ждём данные лобби, чтобы понять, считается ли матч
local live_next_try = 0  -- попытки начать слежку - не чаще раза в 2 с
local finished = nil     -- законченная запись, ждёт переноса в основной файл (вне матча)
local live_seen = {}     -- ступени, показанные в этом матче: основной файл пишется только вне матча
local tp_buf = {}        -- переиспользуемая таблица для Player.GetTeamPlayer

local function save_live()
    if not (account and cur) then
        return
    end
    local ok, err = pcall(Store.Save, live_store_name(), { v = 1, rec = cur, seen = live_seen })
    if not ok then
        log("live save failed: %s", tostring(err))
    end
    live_dirty = false
end

-- поле из GameRules.GetLobbyObjectJson(): число или имя из enum
local function lobby_field(field)
    local json = safe(GameRules.GetLobbyObjectJson)
    if type(json) ~= "string" or json == "" then
        return nil, false
    end
    return json:match('"' .. field .. '"%s*:%s*"?([%w_]+)"?'), true
end

-- Тип лобби: 0 - обычный (значение по умолчанию, в JSON его может не быть), 7 - рейтинг.
local function lobby_type()
    local raw, has_json = lobby_field("lobby_type")
    if not has_json then
        return nil, "no lobby json"
    elseif raw == nil then
        return 0, "absent"
    end
    return int(tonumber(raw)) or LOBBY_TYPES[raw], raw
end

-- Победитель: жив только один трон (разрушенного к пост-игре уже нет в списке) или исход из лобби.
local function winner_team()
    local alive = {}
    for _, npc in pairs(NPCs.GetAll(FORT_FLAG)) do
        if safe(NPC.IsFort, npc) and (safe(Entity.GetHealth, npc) or 0) > 0 then
            alive[safe(Entity.GetTeamNum, npc) or 0] = true
        end
    end
    if alive[TEAM_RADIANT] and not alive[TEAM_DIRE] then
        return TEAM_RADIANT, "throne"
    elseif alive[TEAM_DIRE] and not alive[TEAM_RADIANT] then
        return TEAM_DIRE, "throne"
    end
    local outcome = lobby_field("match_outcome")
    if outcome == "2" or (outcome and outcome:find("RadVictory")) then
        return TEAM_RADIANT, "lobby " .. outcome
    elseif outcome == "3" or (outcome and outcome:find("DireVictory")) then
        return TEAM_DIRE, "lobby " .. outcome
    end
    return nil, "unknown (" .. tostring(outcome) .. ")"
end

-- сырые события матча (чат, убийства) - только с включённым «Подробным логом» (пункт меню ниже)
local verbose_log = false

local function log_event(fmt, ...)
    if verbose_log and live and live.logged < LOG_EVENTS_PER_MATCH then
        live.logged = live.logged + 1
        log(fmt, ...)
    end
end

-- Убитые одним применением (Mana Void, Requiem, Omnislash) приходят подряд: пачка - пока между убийствами
-- не больше window секунд. В x[field] - самая большая пачка за матч.
local function burst(x, field, window)
    local now = GameRules.GetGameTime()
    local b = live.bursts[field]
    if b and now - b.t <= window then
        b.n = b.n + 1
    else
        b = { n = 1 }
        live.bursts[field] = b
    end
    b.t = now
    x[field] = max(x[field] or 0, b.n)
end

-- Spectre: когда был каст Haunt, если он ещё идёт (по откату способности), иначе nil
local function haunt_cast_time()
    local ab = safe(NPC.GetAbility, live.hero, "spectre_haunt")
    local left = ab and safe(Ability.GetCooldown, ab) or 0
    local length = ab and safe(Ability.GetCooldownLength, ab) or 0
    local since = length - left
    if left > 0 and length > 0 and since <= FEAT.haunt_window then
        return GameRules.GetGameTime() - since
    end
end

-- Новые ступени по текущей записи - сразу уведомление; полный повтор истории - после матча.
local function check_live()
    local scope = scope_of(cur)
    if not scope then
        return
    end
    local points_before = nil
    for _, f in ipairs(FAMILIES) do
        if (f.live or f.grows) and (f.scope == scope or (f.scope == "ap" and is_ap(cur))) then
            local v = f.match(cur)
            if v then
                for i, tier in ipairs(f.tiers) do
                    local key = tier_key(f, i)
                    if not data.seen[key] and meets(f, v, tier[1]) then
                        points_before = points_before or points_of(data.seen)
                        data.seen[key], live_seen[key] = true, true
                        dirty, live_dirty = true, true
                        tier_toast(key)
                        log("live: %s - %s", key, tier_name(f, i))
                    end
                end
            end
        end
    end
    -- уровень поднялся от полученного в матче - уведомление сейчас: после матча «до» уже будет с этими ступенями
    if points_before then
        local points_now = points_of(data.seen)
        local level_now = level_of(points_now)
        if level_now > level_of(points_before) then
            push_toast({
                kind = "level", head = "Новый уровень", title = ("Уровень %d"):format(level_now),
                text = ("%s очков"):format(fmt_num(points_now)), color = RANKS.P.color, sound = SOUND_LEVEL,
            })
        end
    end
end

local function start_live(match_id)
    local me, hero = Players.GetLocal(), Heroes.GetLocal()
    if not (me and hero) then
        return
    end
    local key = id_key(match_id)
    local lobby, lobby_raw = lobby_type()
    if lobby_raw == "no lobby json" then
        -- лобби ещё не пришло: попробуем позже, минуту спустя - считаем, что матч не наш (локальная игра)
        live_wait = live_wait or { key = key, since = os.clock() }
        if live_wait.key == key and os.clock() - live_wait.since > 60 then
            log("match %s: no lobby data for a minute - not tracked", key)
            live_skipped, live_wait = key, nil
        end
        return
    end
    live_wait = nil
    local mode = int(safe(GameRules.GetGameMode))
    local level = safe(Engine.GetLevelNameShort) or ""
    local clock = safe(GameRules.GetDOTATime, true, true) or 0
    local saved = Store.Load(live_store_name(), nil)
    local resumed = type(saved) == "table" and type(saved.rec) == "table" and saved.rec.id == key and not saved.rec.done
    if resumed then
        cur = saved.rec -- реконнект или перезагрузка скриптов: продолжаем ту же запись
        live_seen = restore_seen(saved)
    else
        if type(saved) == "table" and type(saved.rec) == "table" then
            merge_live(saved.rec) -- чужая незаконченная запись не должна потеряться
            restore_seen(saved)
        end
        live_seen = {}
        local known = data.matches[key]
        cur = {
            id = key, h = int(safe(Engine.GetHeroIDByName, NPC.GetUnitName(hero))), m = mode, l = lobby,
            t = os.time() - floor(max(clock, 0)), x = {},
        }
        if known and type(known.x) == "table" then -- вышел и вернулся: события уже были перенесены
            for k, v in pairs(known.x) do
                cur.x[k] = v
            end
        end
    end
    cur.x = cur.x or {}
    local scope = scope_of(cur)
    log("match %s: hero %s, lobby %s (%s), mode %s, map %s, clock %s, scope %s%s", key, tostring(cur.h),
        tostring(lobby), tostring(lobby_raw), tostring(mode), level, Timer.Format(clock), tostring(scope),
        resumed and ", resumed" or "")
    if not scope or level == "hero_demo_main" then
        live_skipped, cur = key, nil
        return
    end
    live = {
        player_id = Player.GetPlayerID(me), team = Entity.GetTeamNum(hero), hero = hero,
        hero_name = NPC.GetUnitName(hero) or "", from_clock = clock, bb_start = nil, logged = 0, killed_events = 0,
        chat_events = 0, next_poll = 0, next_save = 0,
        bursts = {},        -- убийства одним применением: { [поле] = { t, n } }
        down = nil,         -- герой лежит: { d = смертей до этого } - воскрешение без смерти (WK, Aegis)
        revived_at = nil,   -- время воскрешения без смерти
        infest_seen = nil,  -- когда последний раз видели Lifestealer внутри Infest
    }
    live_dirty = true
end

local function poll_live()
    local me = Players.GetLocal()
    local td = me and safe(Player.GetTeamData, me)
    local tp = me and safe(Player.GetTeamPlayer, me, tp_buf)
    if type(td) ~= "table" or type(tp) ~= "table" then
        return
    end
    local x = cur.x
    local clock = safe(GameRules.GetDOTATime, true, true) or 0
    local deaths_before = cur.d or 0
    cur.k, cur.d, cur.a = int(td.kills) or 0, int(td.deaths) or 0, int(td.assists) or 0
    cur.lh, cur.dn = int(tp.lasthit_count), int(tp.deny_count)
    cur.hd, cur.hh = int(tp.hero_damage), int(tp.healing)
    local changed = false

    -- ластхиты к 10:00 - только если следили с начала (не реконнект после 10:00)
    if x.lh10 == nil and clock >= 600 and live.from_clock < 600 then
        x.lh10, changed = cur.lh or 0, true
        log("last hits at 10:00: %d", x.lh10)
    end
    local stacks = int(tp.camps_stacked) or 0
    if stacks > (x.stacks or 0) then
        x.stacks, changed = stacks, true
    end
    local runes = int(tp.rune_pickups) or 0
    if runes > (x.runes or 0) then
        x.runes, changed = runes, true
    end

    -- счёт команд: отставание по убийствам
    local team_kills = { [TEAM_RADIANT] = 0, [TEAM_DIRE] = 0 }
    for _, p in pairs(Players.GetAll()) do
        local team = safe(Entity.GetTeamNum, p)
        if team == TEAM_RADIANT or team == TEAM_DIRE then
            local ptd = p == me and td or safe(Player.GetTeamData, p)
            if type(ptd) == "table" then
                team_kills[team] = team_kills[team] + (int(ptd.kills) or 0)
            end
        end
    end
    local enemy = live.team == TEAM_RADIANT and TEAM_DIRE or TEAM_RADIANT
    local deficit = team_kills[enemy] - team_kills[live.team]
    if deficit > (x.deficit or 0) then
        x.deficit, changed = deficit, true
    end

    -- выкуп: время последнего выкупа сменилось
    local bb = tonumber(td.last_buyback_time) or 0
    if live.bb_start == nil then
        live.bb_start = bb
    elseif bb > 0 and bb ~= live.bb_start and not x.bb then
        x.bb, changed = 1, true
        log("buyback at %s", Timer.Format(clock))
    end

    -- Wraith King: встал, а смертей не прибавилось - воскрешение (Reincarnation или Aegis)
    if live.hero_name == FEAT.wk then
        local alive = safe(Entity.IsAlive, live.hero)
        if alive == false and not live.down then
            live.down = { d = deaths_before }
        elseif alive and live.down then
            if cur.d == live.down.d then
                live.revived_at = GameRules.GetGameTime()
                log("revived at %s without a death", Timer.Format(clock))
            end
            live.down = nil
        end
    elseif live.hero_name == FEAT.ls and safe(NPC.HasModifier, live.hero, FEAT.infest_modifier) then
        live.infest_seen = GameRules.GetGameTime()
    end

    if changed then
        live_dirty = true
    end
    check_live()
end

local function x_summary(x)
    local parts = {}
    for k, v in pairs(x or {}) do
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- Экран итогов (или выход из игры): итог, длительность, GPM/XPM; запись ждёт переноса вне матча.
local function finish_live(reason)
    if not (cur and live) then
        return
    end
    local ok, err = pcall(poll_live)
    if not ok then
        log("final poll failed: %s", tostring(err))
    end
    local ended = safe(GameRules.GetGameState) == POST_GAME
    local winner, how = nil, "left before the end"
    if ended then
        winner, how = winner_team()
    end
    local clock = safe(GameRules.GetDOTATime) or 0
    local me = Players.GetLocal()
    local tp = me and safe(Player.GetTeamPlayer, me, tp_buf)
    if ended and clock > 60 then
        cur.du = int(clock)
        if type(tp) == "table" then
            cur.gp = int((tp.totalearned_gold or 0) / (clock / 60))
            cur.xp = int((tp.totalearned_xp or 0) / (clock / 60))
        end
    end
    if winner then
        cur.w = winner == live.team
    end
    cur.done = cur.w ~= nil
    save_live()
    log("match %s %s (%s): %s, %d/%d/%d, %s; chat events %d, kill events %d%s", cur.id,
        cur.w == nil and "result unknown" or (cur.w and "won" or "lost"), how, reason, cur.k or 0, cur.d or 0,
        cur.a or 0, x_summary(cur.x), live.chat_events, live.killed_events,
        live.killed_events == 0 and " (OnEntityKilled не приходил - нет unsafe-режима?)" or "")
    finished, cur, live = cur, nil, nil
end

--#endregion

--#region Menu

local tab = Menu.Create("General", "Main", "Achievements")
pcall(tab.Icon, tab, "\u{f091}")
local group = tab:Create("Main"):Create("Достижения")
local ui = {}
local page = {
    open = false, tab = 1, scroll = 0, max_scroll = 0, x = nil, y = nil,
    rect = nil, hits = {}, nhits = 0, dragging = false, held = false, drag_dx = 0, drag_dy = 0, click = nil,
}

local function toggle_page()
    page.open = not page.open
    page.dragging, page.held = false, false
end

ui.enabled = group:Switch("Включить", true)
ui.enabled:ToolTip("Достижения за матчи: история - с OpenDota, прогресс - у каждого аккаунта свой.\n"
    .. "Считаются обычные и рейтинговые матчи, Turbo - отдельной вкладкой, Особые - только рейтинг и All Pick.\n"
    .. "Рошан, курьеры, варды и приёмы героев - только с небезопасными функциями (Скрипты › Безопасность).")
ui.open = group:Button("Открыть достижения", function() toggle_page() end)
ui.key = group:Bind("Клавиша страницы", Enum.ButtonCode.KEY_NONE)
ui.key:ToolTip("Открыть или закрыть страницу достижений.")
ui.in_match = group:Combo("Уведомления в матче",
    { "Сразу, маленькое", "Когда мёртв или в конце матча", "Только после матча" }, 0)
ui.sound = group:Switch("Звук", true)
ui.volume = group:Slider("Громкость", 0, 100, 40, "%d%%")
ui.sync = group:Button("Обновить из OpenDota", function()
    sync.next_try, sync.force = 0, true
end)
ui.test = group:Button("Тестовое уведомление", function()
    local f = FAMILY_BY_ID.kills
    push_toast({
        kind = "tier", family = f, head = "Достижение получено (пример)", title = tier_name(f, 3),
        text = RANKS.G.name .. " · " .. tier_desc(f, 3), points = RANKS.G.points, color = RANKS.G.color,
    })
end)
ui.verbose = group:Switch("Подробный лог", false)
ui.verbose:ToolTip("Пишет в debug.log события матча: чат игры, убийства и чем убито.\n"
    .. "Нужно, чтобы разобраться с ошибкой: приложи строки [achievements] из лога.")
ui.verbose:SetCallback(function(widget) verbose_log = widget:Get() end, true)
ui.status = group:Label("Загрузка…")

local status_text = nil
local function update_status()
    local text
    if not account then
        text = "Жду аккаунт Steam…"
    elseif sync.status then
        text = sync.status
    elseif not data.imported then
        text = "История ещё не загружена"
    else
        local level = level_of(state.points)
        text = ("Уровень %d · %s очков · %d из %d · OpenDota %s"):format(level, fmt_num(state.points),
            state.count, TOTAL_TIERS, ago(data.synced_at))
    end
    if text ~= status_text then
        status_text = text
        pcall(ui.status.ForceLocalization, ui.status, text)
    end
end

--#endregion

--#region Drawing

local FONT = Render.LoadFont("MuseoSansEx", Enum.FontCreate.FONTFLAG_ANTIALIAS, 500)
local FONT_BOLD = Render.LoadFont("MuseoSansEx", Enum.FontCreate.FONTFLAG_ANTIALIAS, 700)

local theme = { next_refresh = 0, s = 1 }
local function refresh_theme()
    local now = os.clock()
    if now < theme.next_refresh then
        return
    end
    theme.next_refresh = now + 1
    local bg = Menu.Style("main_background")
    local card = Menu.Style("additional_background")
    theme.bg = Color(bg.r, bg.g, bg.b, 245)
    theme.card = Color(card.r, card.g, card.b, 200)
    theme.outline = Menu.Style("outline")
    theme.accent = Menu.Style("primary")
    theme.text = Menu.Style("active_widgets_text")
    theme.dim = Menu.Style("primary_widgets_text")
    theme.bar = Menu.Style("slider_background")
    theme.shadow = Color(0, 0, 0, 150)
    local accent = theme.accent
    theme.accent_bg = Color(accent.r, accent.g, accent.b, 55)
    -- неполученные достижения - тусклее; разделители; затухание краёв списка
    theme.card_dim = Color(card.r, card.g, card.b, 105)
    theme.card_hover = Color(min(card.r + 16, 255), min(card.g + 16, 255), min(card.b + 16, 255), 220)
    theme.line = Color(theme.dim.r, theme.dim.g, theme.dim.b, 45)
    theme.text_soft = Color(theme.text.r, theme.text.g, theme.text.b, 150)
    theme.image_dim = Color(255, 255, 255, 120)
    theme.fade_from = Color(bg.r, bg.g, bg.b, 245)
    theme.fade_to = Color(bg.r, bg.g, bg.b, 0)
    local scale = Menu.Scale()
    theme.s = (scale >= 50 and scale <= 300) and scale / 100 or 1
end

-- настоящая высота строки шрифта (больше размера шрифта) - для центрирования
local text_heights = {}
local function th(font, size)
    local key = font .. "@" .. size
    local h = text_heights[key]
    if not h then
        local measured = Render.TextSize(font, size, "Ay").y
        h = (measured and measured > 0) and measured or size
        text_heights[key] = h
    end
    return h
end

local function tw(font, size, text)
    return Render.TextSize(font, size, text).x
end

local function icon_of(f, hero)
    if f.hero_icon and hero then
        local unit = hero_unit(hero)
        local img = unit and Icons.HeroPortrait(unit)
        if img then
            return img, true
        end
    end
    local kind, name = f.icon:match("^(%a+):(.+)$")
    if kind == "item" then
        return Icons.Item(name), false
    elseif kind == "spell" then
        return Icons.Spell(name), false
    elseif kind == "hero" then
        return Icons.HeroPortrait(name), true
    end
    return nil, false
end

-- Текст в ширину width: сначала мельче (до min_size), потом обрезка с «…». Возвращает текст и размер.
-- Результат запоминается (строки страницы одни и те же каждый кадр); кэш сбрасывается при смене масштаба меню.
local fit_cache, fit_cache_scale = {}, nil

local function fit_text_uncached(font, size, min_size, text, width)
    while size > min_size and tw(font, size, text) > width do
        size = size - 1
    end
    if tw(font, size, text) <= width then
        return text, size
    end
    local chars = {}
    for _, code in utf8.codes(text) do
        chars[#chars + 1] = utf8.char(code)
    end
    for n = #chars - 1, 1, -1 do
        local cut = table.concat(chars, "", 1, n) .. "…"
        if tw(font, size, cut) <= width then
            return cut, size
        end
    end
    return text, size
end

local function fit_text(font, size, min_size, text, width)
    if fit_cache_scale ~= theme.s then
        fit_cache, fit_cache_scale = {}, theme.s
    end
    local key = ("%s|%s|%s|%d|%s"):format(font, size, min_size, floor(width), text)
    local hit = fit_cache[key]
    if not hit then
        hit = { fit_text_uncached(font, size, min_size, text, floor(width)) }
        fit_cache[key] = hit
    end
    return hit[1], hit[2]
end

-- Картинка в рамке w x h: предметы 88:64, портреты героев 128:72 - вписываем с сохранением пропорций.
-- gray - чёрно-белая и приглушённая. Возвращает прямоугольник картинки (x, y, w, h).
local function draw_icon(img, portrait, x, y, w, h, gray, rounding)
    if not img then
        Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), theme.bar, rounding)
        return x, y, w, h
    end
    local ratio = portrait and 128 / 72 or 88 / 64
    local iw, ih = w, px(w / ratio)
    if ih > h then
        ih, iw = h, px(h * ratio)
    end
    local ix, iy = px(x + (w - iw) / 2), px(y + (h - ih) / 2)
    Render.Image(img, Vec2(ix, iy), Vec2(iw, ih), gray and theme.image_dim or WHITE, rounding, 0, UV0, UV1,
        gray and 1 or 0)
    return ix, iy, iw, ih
end

local function add_hit(x0, y0, x1, y1, action, arg)
    local n = page.nhits + 1
    page.nhits = n
    local h = page.hits[n]
    if not h then
        h = {}
        page.hits[n] = h
    end
    h[1], h[2], h[3], h[4], h[5], h[6] = x0, y0, x1, y1, action, arg
end

local function inside(x, y, x0, y0, x1, y1)
    return x >= x0 and x <= x1 and y >= y0 and y <= y1
end

-- Прогресс к ступени: доля 0..1, текущее значение и цель; у «сделал / нет» - nil.
local function tier_progress(f, i)
    if f.binary then
        return nil
    end
    local value, target = state.value[f.id], f.tiers[i][1]
    if value == nil then
        return 0, nil, target
    end
    local fraction = f.lower and target / max(value, 1) or value / target
    return max(0, min(1, fraction)), value, target
end

-- Строки страницы: каждая ступень - отдельное достижение, как в Steam. По вкладкам: «Впереди» - ближайшие
-- к цели сверху, скрытые в конце; «Получено» - новые сверху. Пересобираются, когда меняется state.
local tab_rows = {}
local rows_state = nil -- для какого state собраны строки; счёт по редкости - в RANKS[..].got_n / total_n

local function rank_points(row)
    return RANKS[row.f.tiers[row.i][2]].points
end

local function build_rows()
    rows_state = state
    for _, r in pairs(RANKS) do
        r.got_n, r.total_n = 0, 0
    end
    for ti, t in ipairs(TABS) do
        local ahead, done = {}, {}
        for _, f in ipairs(FAMILIES) do
            if t.cat == nil or f.cat == t.cat then
                for i, tier in ipairs(f.tiers) do
                    local got = state.got[tier_key(f, i)]
                    local row = { f = f, i = i, got = got, key = tier_key(f, i) }
                    if ti == 1 then
                        local rank = RANKS[tier[2]]
                        rank.total_n = rank.total_n + 1
                        rank.got_n = rank.got_n + (got and 1 or 0)
                    end
                    if got then
                        done[#done + 1] = row
                    else
                        -- у скрытого семейства без единой ступени не видно ни цели, ни прогресса
                        row.secret = (f.hidden and not state.got[tier_key(f, 1)]) and true or false
                        row.fraction = tier_progress(f, i) or 0
                        ahead[#ahead + 1] = row
                    end
                end
            end
        end
        table.sort(ahead, function(a, b)
            if a.secret ~= b.secret then
                return b.secret
            elseif a.fraction ~= b.fraction then
                return a.fraction > b.fraction
            elseif rank_points(a) ~= rank_points(b) then
                return rank_points(a) < rank_points(b)
            end
            return a.key < b.key
        end)
        table.sort(done, function(a, b)
            if a.got.t ~= b.got.t then
                return a.got.t > b.got.t
            elseif rank_points(a) ~= rank_points(b) then
                return rank_points(a) > rank_points(b)
            end
            return a.key < b.key
        end)
        tab_rows[ti] = { ahead = ahead, done = done, got = #done, total = #ahead + #done }
    end
end

-- Заголовок раздела списка: «ВПЕРЕДИ · 36» и тонкая линия до правого края.
local function draw_section(label, count, left, right, top, h, s)
    local size = px(11 * s)
    local text = ("%s · %d"):format(label, count)
    local ty = px(top + (h - th(FONT_BOLD, size)) / 2)
    Render.Text(FONT_BOLD, size, text, Vec2(left + px(2 * s), ty), theme.dim)
    local lx = px(left + 2 * s + tw(FONT_BOLD, size, text) + 10 * s)
    local ly = floor(top + h / 2) + 0.5
    Render.Line(Vec2(lx, ly), Vec2(right, ly), theme.line)
end

-- Одно достижение (ступень). Получено: цветная иконка в рамке цвета редкости, очки этим цветом, дата.
-- Впереди: иконка серая, очки - какая будет награда, прогресс «5 / 10» и тонкая полоса.
local function draw_row(row, left, right, top, h, s, hover)
    local f, i = row.f, row.i
    local rank = RANKS[f.tiers[i][2]]
    local got = row.got ~= nil
    local background = hover and theme.card_hover or (got and theme.card or theme.card_dim)
    Render.FilledRect(Vec2(left, top), Vec2(right, top + h), background, 6 * s)

    -- иконка
    local box_w, box_h = px(50 * s), px(38 * s)
    local ix, iy = px(left + 10 * s), px(top + (h - box_h) / 2)
    if row.secret then
        Render.FilledRect(Vec2(ix, iy), Vec2(ix + box_w, iy + box_h), theme.bar, 4 * s)
        local qs = px(18 * s)
        Render.Text(FONT_BOLD, qs, "?", Vec2(px(ix + (box_w - tw(FONT_BOLD, qs, "?")) / 2),
            px(iy + (box_h - th(FONT_BOLD, qs)) / 2)), theme.dim)
    else
        local img, portrait = icon_of(f, state.hero[f.id])
        local x0, y0, w0, h0 = draw_icon(img, portrait, ix, iy, box_w, box_h, not got, 4 * s)
        if got then
            local b = px(2 * s)
            Render.Rect(Vec2(x0 - b, y0 - b), Vec2(x0 + w0 + b, y0 + h0 + b), rank.color, 5 * s, 0, 1.5 * s)
        end
    end

    local tx = px(ix + box_w + 14 * s)
    local inner_right = px(right - 12 * s)
    local size, small = px(14 * s), px(12 * s)
    local line_h = th(FONT_BOLD, size)
    local has_bar = not got and not row.secret and not f.binary
    -- две строки текста по центру карточки (с полосой - чуть выше)
    local block = line_h + 3 * s + th(FONT, small) + (has_bar and 9 * s or 0)
    local row1 = px(top + (h - block) / 2)
    local row2 = px(row1 + line_h + 3 * s)

    -- строка 1: имя и очки
    local pts = "+" .. rank.points
    local pts_w = tw(FONT_BOLD, small, pts)
    local title_room = inner_right - tx - pts_w - px(10 * s)
    local title, title_size = fit_text(FONT_BOLD, size, px(11 * s),
        row.secret and "Скрытое достижение" or tier_name(f, i), title_room)
    Render.Text(FONT_BOLD, title_size, title, Vec2(tx, px(row1 + (line_h - th(FONT_BOLD, title_size)) / 2)),
        got and theme.text or theme.text_soft)
    Render.Text(FONT_BOLD, small, pts, Vec2(px(inner_right - pts_w), px(row1 + (line_h - th(FONT_BOLD, small)) / 2)),
        got and rank.color or theme.dim)

    -- строка 2: цель и дата / прогресс
    local desc, right_text
    if row.secret then
        desc = "Откроется, когда получишь"
    else
        desc = tier_desc(f, i)
        if f.hero_icon and state.hero[f.id] and not f.binary then
            desc = desc .. " · " .. hero_title(state.hero[f.id])
        end
        if got then
            right_text = date_of(row.got.t)
        elseif has_bar then
            local _, value, target = tier_progress(f, i)
            right_text = show_value(f, value) .. " / " .. show_value(f, target)
        end
    end
    local desc_room = inner_right - tx - (right_text and tw(FONT, small, right_text) + px(12 * s) or 0)
    desc = fit_text(FONT, small, small, desc, desc_room)
    Render.Text(FONT, small, desc, Vec2(tx, row2), theme.dim)
    if right_text then
        Render.Text(FONT, small, right_text, Vec2(px(inner_right - tw(FONT, small, right_text)), row2),
            got and theme.dim or theme.text_soft)
    end

    -- полоса прогресса к этой ступени
    if has_bar then
        local bar_top = px(row2 + th(FONT, small) + 6 * s)
        local bar_bottom = bar_top + max(2, px(3 * s))
        Render.FilledRect(Vec2(tx, bar_top), Vec2(inner_right, bar_bottom), theme.bar, 2 * s)
        if row.fraction > 0 then
            Render.FilledRect(Vec2(tx, bar_top), Vec2(px(tx + (inner_right - tx) * row.fraction), bar_bottom),
                rank.color, 2 * s)
        end
    end
end

-- Курсор «сквозь окно»: клики и колесо забирает OnKeyEvent, а наведение мыши чит в скрипты не отдаёт -
-- кнопки Dota под страницей подсвечиваются. Поэтому под страницей - невидимая панель Panorama той же
-- площади: она ловит наведение, как любое окно игры. В меню - на панели дашборда, в матче - на HUD.
-- Прячется, когда страница закрыта; панель от прошлой загрузки скрипта ищется по id и переиспользуется.
local BLOCKER_ID <const> = "ulib_achievements_blocker"
local blocker = { panel = nil, root = nil, style = nil, visible = false, logged = {} }

local function panorama_root()
    local ids = Engine.IsInGame() and { "Hud", "DotaHud" } or { "DotaDashboard", "Dashboard" }
    for _, id in ipairs(ids) do
        local panel = safe(Panorama.GetPanelByName, id, false)
        if panel then
            return panel, id
        end
    end
    return nil, table.concat(ids, "/")
end

local function blocker_hide()
    if blocker.panel and blocker.visible then
        pcall(blocker.panel.SetVisible, blocker.panel, false)
    end
    blocker.visible = false
end

local function blocker_show(x, y, w, h)
    local root, root_id = panorama_root()
    if not blocker.logged[root_id] then
        blocker.logged[root_id] = true
        log("input blocker: panorama root %s %s", root_id, root and "found" or "not found")
    end
    if not root then
        return
    end
    if blocker.root ~= root or not (blocker.panel and safe(blocker.panel.IsValid, blocker.panel)) then
        blocker_hide()
        local panel = safe(root.FindChildTraverse, root, BLOCKER_ID)
            or safe(Panorama.CreatePanel, "Panel", BLOCKER_ID, root, "", "")
        if not panel then
            return
        end
        -- наведение и клики - этой панели, а не тому, что под ней
        pcall(Engine.RunScript, "$.GetContextPanel().hittest = true;", panel)
        blocker.panel, blocker.root, blocker.style = panel, root, nil
        blocker.fix_x, blocker.fix_y = nil, nil -- поправка своя у каждого корня
    end
    -- CSS-пиксели Panorama: высота экрана = 1080; fix - поправка, если панель встала не туда (раскладка корня)
    local k = 1080 / max(1, Render.ScreenSize().y)
    local fx, fy = blocker.fix_x or 0, blocker.fix_y or 0
    local style = ("position: %dpx %dpx 0px; width: %dpx; height: %dpx; horizontal-align: left; "
        .. "vertical-align: top; background-color: #00000001;"):format(floor((x + fx) * k), floor((y + fy) * k),
        floor(w * k + 1), floor(h * k + 1))
    if style ~= blocker.style then
        pcall(blocker.panel.SetStyle, blocker.panel, style)
        blocker.style = style
    end
    if not blocker.visible then
        pcall(blocker.panel.SetVisible, blocker.panel, true)
        blocker.visible = true
        if blocker.checked_root ~= blocker.root then
            blocker.check_at = os.clock() + 0.3
        end
    end
    -- один раз на корень (меню / HUD): где панель оказалась на самом деле
    if blocker.check_at and os.clock() >= blocker.check_at then
        blocker.check_at, blocker.checked_root = nil, blocker.root
        local pos = safe(blocker.panel.GetPositionWithinWindow, blocker.panel)
        if pos then
            local dx, dy = x - pos.x, y - pos.y
            log("input blocker at %d,%d, wanted %d,%d", floor(pos.x), floor(pos.y), floor(x), floor(y))
            if math.abs(dx) > 2 or math.abs(dy) > 2 then
                blocker.fix_x, blocker.fix_y = dx, dy
                blocker.style = nil
            end
        end
    end
end

-- После перезагрузки скрипта панель прошлой загрузки могла остаться видимой - спрятать.
local function blocker_cleanup()
    for _, id in ipairs({ "DotaDashboard", "Dashboard", "Hud", "DotaHud" }) do
        local root = safe(Panorama.GetPanelByName, id, false)
        local old = root and safe(root.FindChildTraverse, root, BLOCKER_ID)
        if old then
            pcall(old.SetVisible, old, false)
        end
    end
end

-- Подсказки к медалям редкости в шапке.
local RANK_TIPS <const> = {
    B = { title = "Бронза", text = "Первые ступени - то, что бывает почти в каждой игре" },
    S = { title = "Серебро", text = "Хороший матч или заметный стаж" },
    G = { title = "Золото", text = "Трудные достижения - лучшие матчи и долгие серии" },
    P = { title = "Платина", text = "Самые редкие - почти предел возможного" },
}

-- Окошко подсказки у курсора (поверх страницы, не выходит за экран).
local function draw_tip(tip, cx, cy, s)
    local screen = Render.ScreenSize()
    local size, small = px(13 * s), px(12 * s)
    local pad = px(10 * s)
    local w = tw(FONT_BOLD, size, tip.title)
    for _, line in ipairs(tip.lines) do
        w = max(w, tw(FONT, small, line))
    end
    local line_h = th(FONT, small) + px(3 * s)
    local h = th(FONT_BOLD, size) + px(5 * s) + #tip.lines * line_h - px(3 * s)
    w, h = px(w + pad * 2), px(h + pad * 2)
    local x = px(min(cx + 16 * s, screen.x - w - 4))
    local y = px(min(cy + 18 * s, screen.y - h - 4))
    Render.Shadow(Vec2(x, y), Vec2(x + w, y + h), theme.shadow, 16 * s, 5 * s, SHADOW_OUTSIDE, Vec2(0, 2 * s))
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), theme.bg, 5 * s)
    Render.Rect(Vec2(x, y), Vec2(x + w, y + h), tip.color or theme.outline, 5 * s)
    Render.Text(FONT_BOLD, size, tip.title, Vec2(x + pad, y + pad), tip.color or theme.text)
    local ty = y + pad + th(FONT_BOLD, size) + px(5 * s)
    for _, line in ipairs(tip.lines) do
        Render.Text(FONT, small, line, Vec2(x + pad, px(ty)), theme.dim)
        ty = ty + line_h
    end
end

local function draw_page()
    local s = theme.s
    page.tip = nil
    local screen = Render.ScreenSize()
    local w = px(min(640 * s, screen.x - 40))
    local h = px(min(680 * s, screen.y - 60))
    if not page.x then
        page.x = Config.ReadInt(CFG, "page_x", -1)
        page.y = Config.ReadInt(CFG, "page_y", -1)
        if page.x < 0 or page.y < 0 then
            page.x, page.y = (screen.x - w) / 2, (screen.y - h) / 2
        end
    end
    page.x = max(0, min(page.x, screen.x - w))
    page.y = max(0, min(page.y, screen.y - h))
    local x, y = px(page.x), px(page.y)
    page.rect = page.rect or {}
    page.rect[1], page.rect[2], page.rect[3], page.rect[4] = x, y, x + w, y + h
    page.nhits = 0

    local rounding = 8 * s
    Render.Shadow(Vec2(x, y), Vec2(x + w, y + h), theme.shadow, 26 * s, rounding, SHADOW_OUTSIDE, Vec2(0, 3 * s))
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), theme.bg, rounding)
    Render.Rect(Vec2(x, y), Vec2(x + w, y + h), theme.outline, rounding)

    local pad = px(18 * s)
    local left, right = x + pad, x + w - pad
    local cy = y + pad
    local cx, cur_y = Input.GetCursorPos()

    -- шапка: название, уровень, очки; шапку можно тащить
    local title_size = px(21 * s)
    Render.Text(FONT_BOLD, title_size, "Достижения", Vec2(left, cy), theme.text)
    local close = px(22 * s)
    local close_x0, close_y0 = right - close, cy
    local hover_close = inside(cx, cur_y, close_x0, close_y0, right, close_y0 + close)
    if hover_close then
        Render.FilledRect(Vec2(close_x0, close_y0), Vec2(right, close_y0 + close), theme.card, 4 * s)
    end
    local m = px(7 * s)
    local close_color = hover_close and theme.text or theme.dim
    Render.Line(Vec2(close_x0 + m, close_y0 + m), Vec2(right - m, close_y0 + close - m), close_color, 1.6 * s)
    Render.Line(Vec2(right - m, close_y0 + m), Vec2(close_x0 + m, close_y0 + close - m), close_color, 1.6 * s)
    cy = cy + th(FONT_BOLD, title_size) + 6 * s

    if rows_state ~= state then
        build_rows()
    end

    -- уровень: кольцо с прогрессом до следующего и номер внутри; справа - медали по редкости
    cy = cy + 8 * s
    local level, need_now, need_next = level_of(state.points)
    local ring_r = px(25 * s)
    local ring_cx, ring_cy = left + ring_r + px(2 * s), px(cy + ring_r + 2 * s)
    local fraction = (state.points - need_now) / max(1, need_next - need_now)
    Render.Circle(Vec2(ring_cx, ring_cy), ring_r, theme.bar, 4 * s)
    if fraction > 0 then
        Render.Circle(Vec2(ring_cx, ring_cy), ring_r, theme.accent, 4 * s, 270, max(0.02, fraction), true, 48)
    end
    local lvl_size = px(19 * s)
    local lvl = tostring(level)
    Render.Text(FONT_BOLD, lvl_size, lvl, Vec2(px(ring_cx - tw(FONT_BOLD, lvl_size, lvl) / 2),
        px(ring_cy - th(FONT_BOLD, lvl_size) / 2)), theme.text)
    local info_x = px(ring_cx + ring_r + 14 * s)
    local head_size, small = px(16 * s), px(12 * s)
    local info_h = th(FONT_BOLD, head_size) + 4 * s + th(FONT, small)
    local info_y = px(ring_cy - info_h / 2)
    Render.Text(FONT_BOLD, head_size, ("Уровень %d"):format(level), Vec2(info_x, info_y), theme.text)
    Render.Text(FONT, small, ("%s очков · до %d-го ещё %s"):format(fmt_num(state.points), level + 1,
        fmt_num(need_next - state.points)), Vec2(info_x, px(info_y + th(FONT_BOLD, head_size) + 4 * s)), theme.dim)

    -- медали: сколько ступеней каждой редкости получено из скольких (справа налево от платины)
    local medal_r = px(6 * s)
    local count_size = px(13 * s)
    local mx = right
    for _, key in ipairs({ "P", "G", "S", "B" }) do
        local rank = RANKS[key]
        local got_n, total_n = rank.got_n or 0, rank.total_n or 0
        local label = ("%d/%d"):format(got_n, total_n)
        local lx = mx - tw(FONT_BOLD, count_size, label)
        Render.Text(FONT_BOLD, count_size, label, Vec2(px(lx), px(ring_cy - th(FONT_BOLD, count_size) / 2)),
            theme.text)
        local mcx = px(lx - 7 * s - medal_r)
        Render.FilledCircle(Vec2(mcx, ring_cy), medal_r, rank.color)
        Render.Circle(Vec2(mcx, ring_cy), medal_r + px(2 * s), Color(rank.color.r, rank.color.g, rank.color.b, 90),
            1.2 * s)
        -- подсказка при наведении на медаль или её счёт
        if inside(cx, cur_y, mcx - medal_r - px(4 * s), ring_cy - px(12 * s), mx, ring_cy + px(12 * s)) then
            page.tip = {
                title = RANK_TIPS[key].title, color = rank.color,
                lines = {
                    RANK_TIPS[key].text,
                    ("%d очков за каждую ступень"):format(rank.points),
                    got_n >= total_n and ("Получены все %d"):format(total_n)
                        or ("Получено %d из %d, осталось %d"):format(got_n, total_n, total_n - got_n),
                },
            }
        end
        mx = mcx - medal_r - px(18 * s)
    end
    if inside(cx, cur_y, ring_cx - ring_r, ring_cy - ring_r, info_x + px(210 * s), ring_cy + ring_r) then
        page.tip = {
            title = ("Уровень %d"):format(level), color = theme.accent,
            lines = {
                "Уровень растёт от очков за достижения:",
                "бронза 10, серебро 25, золото 50, платина 100",
                ("Уровень %d - при %s очках, осталось %s"):format(level + 1, fmt_num(need_next),
                    fmt_num(need_next - state.points)),
            },
        }
    end
    cy = ring_cy + ring_r + px(14 * s)
    Render.Line(Vec2(left, floor(cy) + 0.5), Vec2(right, floor(cy) + 0.5), theme.line)
    cy = cy + px(12 * s)
    add_hit(x, y, x + w, px(cy), "drag")
    add_hit(close_x0, close_y0, right, close_y0 + close, "close")

    -- вкладки: получено ступеней из скольких
    local tab_size = px(13 * s)
    local tab_h = px(th(FONT, tab_size) + 10 * s)
    local tx = left
    for i, t in ipairs(TABS) do
        local label = ("%s %d/%d"):format(t.name, tab_rows[i].got, tab_rows[i].total)
        local tab_w = px(tw(FONT, tab_size, label) + 14 * s)
        local active = page.tab == i
        local hover = inside(cx, cur_y, tx, px(cy), tx + tab_w, px(cy) + tab_h)
        if active then
            Render.FilledRect(Vec2(tx, px(cy)), Vec2(tx + tab_w, px(cy) + tab_h), theme.accent_bg, 5 * s)
        elseif hover then
            Render.FilledRect(Vec2(tx, px(cy)), Vec2(tx + tab_w, px(cy) + tab_h), theme.card, 5 * s)
        end
        Render.Text(FONT, tab_size, label, Vec2(px(tx + 7 * s), px(cy + (tab_h - th(FONT, tab_size)) / 2)),
            active and theme.accent or (hover and theme.text or theme.dim))
        add_hit(tx, px(cy), tx + tab_w, px(cy) + tab_h, "tab", i)
        tx = tx + tab_w + px(4 * s)
    end
    cy = px(cy + tab_h + 8 * s)

    -- список с прокруткой: «Впереди», потом «Получено»
    local foot_size = px(12 * s)
    local list_top = cy
    local list_bottom = px(y + h - pad - th(FONT, foot_size) - 10 * s)
    local card_h, gap, section_h = px(58 * s), px(6 * s), px(28 * s)
    local rows = tab_rows[page.tab] or tab_rows[1]
    local sections = { { "ВПЕРЕДИ", rows.ahead }, { "ПОЛУЧЕНО", rows.done } }
    local content_h = 0
    for _, sec in ipairs(sections) do
        if #sec[2] > 0 then
            content_h = content_h + section_h + #sec[2] * (card_h + gap)
        end
    end
    page.max_scroll = max(0, content_h - (list_bottom - list_top))
    page.scroll = max(0, min(page.scroll, page.max_scroll))
    page.list = page.list or {}
    page.list[1], page.list[2], page.list[3], page.list[4] = x, list_top, x + w, list_bottom
    local scrollbar = page.max_scroll > 0
    local card_right = scrollbar and right - px(10 * s) or right
    local hover_ok = not page.dragging and inside(cx, cur_y, x, list_top, x + w, list_bottom)
    Render.PushClip(Vec2(x, list_top), Vec2(x + w, list_bottom), true)
    local top = list_top - page.scroll
    for _, sec in ipairs(sections) do
        local list = sec[2]
        if #list > 0 then
            if top + section_h >= list_top and top <= list_bottom then
                draw_section(sec[1], #list, left, card_right, px(top), section_h, s)
            end
            top = top + section_h
            for _, row in ipairs(list) do
                if top + card_h >= list_top and top <= list_bottom then
                    local ry = px(top)
                    draw_row(row, left, card_right, ry, card_h, s,
                        hover_ok and inside(cx, cur_y, left, ry, card_right, ry + card_h))
                end
                top = top + card_h + gap
            end
        end
    end
    Render.PopClip()
    -- края списка плавно гаснут, если за ними есть ещё
    local fade = px(18 * s)
    if page.scroll > 0 then
        Render.Gradient(Vec2(x + 1, list_top), Vec2(x + w - 1, list_top + fade),
            theme.fade_from, theme.fade_from, theme.fade_to, theme.fade_to)
    end
    if page.scroll < page.max_scroll then
        Render.Gradient(Vec2(x + 1, list_bottom - fade), Vec2(x + w - 1, list_bottom),
            theme.fade_to, theme.fade_to, theme.fade_from, theme.fade_from)
    end
    if scrollbar then
        -- ползунок: тащить мышью; клик по дорожке - перейти к этому месту
        local track_h = list_bottom - list_top
        local thumb_h = max(px(30 * s), px(track_h * track_h / content_h))
        local thumb_top = list_top + px((track_h - thumb_h) * page.scroll / page.max_scroll)
        page.track = page.track or {}
        page.track.top, page.track.h, page.track.thumb_h = list_top, track_h, thumb_h
        local grab_x0, grab_x1 = right - px(12 * s), right + px(4 * s)
        local hot = page.scroll_drag ~= nil or inside(cx, cur_y, grab_x0, list_top, grab_x1, list_bottom)
        local bx = right - px(hot and 6 * s or 4 * s)
        Render.FilledRect(Vec2(bx, list_top), Vec2(right, list_bottom), theme.card, 3 * s)
        Render.FilledRect(Vec2(bx, thumb_top), Vec2(right, thumb_top + thumb_h), hot and theme.text or theme.dim, 3 * s)
        add_hit(grab_x0, list_top, grab_x1, list_bottom, "track")
        add_hit(grab_x0, thumb_top, grab_x1, thumb_top + thumb_h, "thumb")
    else
        page.scroll_drag = nil
    end

    -- подвал: аккаунт и история
    local foot
    if not account then
        foot = "Жду аккаунт Steam…"
    elseif sync.status then
        foot = sync.status
    elseif not data.imported then
        foot = "История матчей ещё не загружена"
    else
        foot = ("Аккаунт %d · матчей: %d, Turbo: %d · OpenDota %s"):format(account, state.matches.normal,
            state.matches.turbo, ago(data.synced_at))
    end
    Render.Text(FONT, foot_size, foot, Vec2(left, px(list_bottom + 8 * s)), theme.dim)

    if page.tip then
        draw_tip(page.tip, cx, cur_y, s)
    end
end

-- Клик по странице (по прошлому кадру: области кнопок запоминаются при отрисовке).
local function page_click(cx, cy)
    for i = page.nhits, 1, -1 do
        local hit = page.hits[i]
        if inside(cx, cy, hit[1], hit[2], hit[3], hit[4]) then
            if hit[5] == "close" then
                page.open = false
            elseif hit[5] == "tab" then
                page.tab, page.scroll = hit[6], 0
            elseif hit[5] == "drag" then
                page.dragging, page.scroll_drag = true, nil
                page.drag_dx, page.drag_dy = cx - page.x, cy - page.y
            elseif hit[5] == "track" and page.track then
                -- центр ползунка - под курсор, дальше можно тащить (окно при этом стоит)
                local t = page.track
                local fraction = (cy - t.top - t.thumb_h / 2) / max(1, t.h - t.thumb_h)
                page.scroll = max(0, min(1, fraction)) * page.max_scroll
                page.scroll_drag, page.dragging = { y = cy, scroll = page.scroll }, false
            elseif hit[5] == "thumb" then
                page.scroll_drag, page.dragging = { y = cy, scroll = page.scroll }, false
            end
            return
        end
    end
end

local function stop_drag()
    if page.dragging then
        page.dragging = false
        Config.WriteInt(CFG, "page_x", floor(page.x))
        Config.WriteInt(CFG, "page_y", floor(page.y))
    end
end

local function cursor_over_page(cx, cy)
    local r = page.rect
    if not (page.open and r and inside(cx, cy, r[1], r[2], r[3], r[4])) then
        return false
    end
    -- открытое меню чита над страницей - клики его
    if Menu.Opened() then
        local pos, size = Menu.Pos(), Menu.Size()
        if inside(cx, cy, pos.x, pos.y, pos.x + size.x, pos.y + size.y) then
            return false
        end
    end
    return true
end

-- Уведомление: выезжает справа, держится несколько секунд, гаснет. В матче - маленькое.
local TOAST_IN <const> = 0.3
local TOAST_OUT <const> = 0.5

local function play(sound)
    if ui.sound:Get() then
        local volume = ui.volume:Get() / 100 * MAX_VOLUME
        if volume > 0 then
            pcall(Engine.PlayVol, sound, volume)
        end
    end
end

local function draw_toast(t, now)
    local s = theme.s
    if not t.start then
        t.start = now
        t.small = match_running()
        play(t.sound or SOUND_ACHIEVEMENT)
    end
    local hold = t.small and 3.5 or 5.5
    local elapsed = now - t.start
    if elapsed > TOAST_IN + hold + TOAST_OUT then
        return true
    end
    local screen = Render.ScreenSize()
    -- ширина - по тексту (названия бывают длинными цитатами), но не уже базовой и не шире 45% экрана
    local text_w
    if t.small then
        local line = t.points and ("+%d · %s"):format(t.points, t.text) or t.text
        text_w = max(tw(FONT_BOLD, px(13 * s), t.title), tw(FONT, px(11 * s), line))
    else
        local head_w = tw(FONT, px(12 * s), t.head) + (t.points and tw(FONT_BOLD, px(12 * s), "+" .. t.points) + 16 * s or 0)
        text_w = max(head_w, tw(FONT_BOLD, px(16 * s), t.title), tw(FONT, px(12 * s), t.text))
    end
    local base_w = (t.small and 280 or 370) * s
    local chrome_w = (t.small and 44 or 60) * s + 40 * s -- иконка и поля
    local w = px(min(max(base_w, text_w + chrome_w), screen.x * 0.45))
    local h = px((t.small and 50 or 78) * s)
    local margin = px(20 * s)
    local slide = 1
    if elapsed < TOAST_IN then
        slide = 1 - (1 - elapsed / TOAST_IN) ^ 3
    end
    local alpha = 1
    if elapsed > TOAST_IN + hold then
        alpha = max(0, 1 - (elapsed - TOAST_IN - hold) / TOAST_OUT)
    end
    local x = px(screen.x - w - margin + (1 - slide) * (w + margin))
    local y = px(screen.y * 0.62)

    Render.SetGlobalAlpha(alpha)
    Render.Shadow(Vec2(x, y), Vec2(x + w, y + h), theme.shadow, 20 * s, 7 * s, SHADOW_OUTSIDE, Vec2(0, 2 * s))
    Render.FilledRect(Vec2(x, y), Vec2(x + w, y + h), theme.bg, 7 * s)
    Render.Rect(Vec2(x, y), Vec2(x + w, y + h), t.color, 7 * s)
    Render.FilledRect(Vec2(x, y + px(8 * s)), Vec2(x + px(4 * s), y + h - px(8 * s)), t.color, 2 * s)

    local img, portrait = nil, false
    if t.family then
        img, portrait = icon_of(t.family, state.hero[t.family.id])
    else
        img = Icons.Item("aegis")
    end
    local box_w = px((t.small and 44 or 60) * s)
    local box_h = px((t.small and 32 or 44) * s)
    local ix, iy = x + px(14 * s), px(y + (h - box_h) / 2)
    draw_icon(img, portrait, ix, iy, box_w, box_h, false, 4 * s)
    local tx = ix + box_w + px(12 * s)
    local right = x + w - px(14 * s)

    if t.small then
        local size, small = px(13 * s), px(11 * s)
        local block = th(FONT_BOLD, size) + 2 * s + th(FONT, small)
        local ty = px(y + (h - block) / 2)
        Render.Text(FONT_BOLD, size, t.title, Vec2(tx, ty), theme.text)
        local line = t.points and ("+%d · %s"):format(t.points, t.text) or t.text
        Render.Text(FONT, small, line, Vec2(tx, px(ty + th(FONT_BOLD, size) + 2 * s)), t.color)
    else
        local head, size, small = px(12 * s), px(16 * s), px(12 * s)
        local block = th(FONT, head) + 2 * s + th(FONT_BOLD, size) + 3 * s + th(FONT, small)
        local ty = px(y + (h - block) / 2)
        Render.Text(FONT, head, t.head, Vec2(tx, ty), theme.dim)
        if t.points then
            local pts = "+" .. t.points
            Render.Text(FONT_BOLD, head, pts, Vec2(px(right - tw(FONT_BOLD, head, pts)), ty), t.color)
        end
        ty = px(ty + th(FONT, head) + 2 * s)
        Render.Text(FONT_BOLD, size, t.title, Vec2(tx, ty), theme.text)
        ty = px(ty + th(FONT_BOLD, size) + 3 * s)
        Render.Text(FONT, small, t.text, Vec2(tx, ty), t.color)
    end
    Render.ResetGlobalAlpha()
    return false
end

-- Показывать ли уведомления сейчас (настройка «Уведомления в матче»).
local function toasts_allowed()
    if not match_running() then
        return true
    end
    local mode = ui.in_match:Get()
    if mode == 0 then
        return true
    elseif mode == 1 then
        local hero = Heroes.GetLocal()
        return hero ~= nil and not Entity.IsAlive(hero)
    end
    return false
end

local function draw_toasts()
    local t = toasts[1]
    if not t then
        return
    end
    if not t.start and not toasts_allowed() then
        return
    end
    if draw_toast(t, os.clock()) then
        table.remove(toasts, 1)
    end
end

--#endregion

--#region Callbacks

local every_account_check = Timer.Every(2)
local every_status = Timer.Every(1)
local key_events_seen = false -- приходят ли клики мыши в OnKeyEvent (иначе - запасной опрос кнопки)
local mouse_was_down = false

local function handle_mouse()
    local cx, cy = Input.GetCursorPos()
    if not key_events_seen then
        local down = Input.IsKeyDown(KEY.mouse1, true)
        if down and not mouse_was_down and cursor_over_page(cx, cy) then
            page.click, page.held = { cx, cy }, true
        elseif not down and mouse_was_down then
            page.held = false
        end
        mouse_was_down = down
    elseif page.held and os.clock() - (page.last_down or 0) > 1.5 and not Input.IsKeyDown(KEY.mouse1, true) then
        page.held = false -- отпускание не дошло (например, отпустили за пределами игры)
    end
    if page.click then
        local click = page.click
        page.click = nil
        page_click(click[1], click[2])
    end
    if page.dragging then
        if page.held and not page.scroll_drag then
            page.x, page.y = cx - page.drag_dx, cy - page.drag_dy
        else
            stop_drag()
        end
    end
    if page.scroll_drag then
        local t = page.track
        if page.held and t then
            local per_px = page.max_scroll / max(1, t.h - t.thumb_h)
            page.scroll = page.scroll_drag.scroll + (cy - page.scroll_drag.y) * per_px -- границы - при отрисовке
        else
            page.scroll_drag = nil
        end
    end
end

local blocker_cleaned = false

function ach.OnFrame()
    if not blocker_cleaned then
        blocker_cleaned = true
        blocker_cleanup()
    end
    if not ui.enabled:Get() then
        page.open = false
        blocker_hide()
        return
    end
    refresh_theme()
    if every_account_check() then
        local acc = local_account_id()
        if acc and acc ~= account then
            load_account(acc)
        end
    end
    if account and not match_running() then
        -- вышел из матча до итогов (в главном меню, а слежка ещё идёт)
        if cur and safe(GameRules.GetGameState) ~= POST_GAME then
            finish_live("left")
        end
        -- законченный матч - в основной файл: повтор истории и уведомления о том, что зависело от итога
        if finished then
            merge_live(finished)
            finished = nil
            live_merged = true
            refresh(true)
        end
        local due = sync.force or os.time() - data.synced_at >= SYNC_EVERY
        if not sync.busy and os.clock() >= sync.next_try and due then
            start_sync()
        elseif dirty then
            save()
        end
    end
    if every_status() then
        update_status()
    end
    if ui.key:IsPressed() then
        toggle_page()
    end
    if page.open then
        handle_mouse()
        draw_page()
    end
    -- невидимая панель под страницей - чтобы курсор не «проходил сквозь» окно
    local r = page.rect
    if page.open and r then
        blocker_show(r[1], r[2], r[3] - r[1], r[4] - r[2])
    else
        blocker_hide()
    end
    draw_toasts()
end

-- Клики и колесо над страницей забираем себе, чтобы они не уходили в игру.
function ach.OnKeyEvent(e)
    if not page.open then
        return true
    end
    local key, event = e.key, e.event
    if key == KEY.escape and event == KEY.down and not safe(Input.IsInputCaptured) then
        page.open, page.dragging, page.held, page.scroll_drag = false, false, false, nil
        return false -- Esc закрывает страницу и не уходит в Dota (её меню не откроется)
    end
    local cx, cy = Input.GetCursorPos()
    if event == KEY.scroll_down or event == KEY.scroll_up or key == KEY.wheel_up or key == KEY.wheel_down then
        if not cursor_over_page(cx, cy) then
            return true
        end
        local r = page.list
        if r and inside(cx, cy, r[1], r[2], r[3], r[4]) then
            local down = event == KEY.scroll_down or key == KEY.wheel_down
            page.scroll = page.scroll + (down and 1 or -1) * px(71 * theme.s)
        end
        return false
    end
    if key == KEY.mouse1 then
        key_events_seen = true
        -- пока кнопка зажата, KEY_DOWN приходит каждый кадр: новый клик - только после отпускания
        if event == KEY.down and (page.held or cursor_over_page(cx, cy)) then
            if not page.held then
                page.click, page.held = { cx, cy }, true
            end
            page.last_down = os.clock()
            return false
        elseif event == KEY.up and page.held then
            page.held = false
            return false
        end
    end
    return true
end

-- Слежка за матчем: начало - с пре-гейма, опрос раз в LIVE_POLL, итог - на экране итогов.
function ach.OnUpdate()
    if not (account and data and ui.enabled:Get()) then
        return
    end
    local game_state = safe(GameRules.GetGameState)
    if not cur then
        if game_state == STATE_PRE_GAME or game_state == STATE_IN_PROGRESS then
            local key = id_key(safe(GameRules.GetMatchID))
            if key and key ~= "0" and key ~= live_skipped and not (finished and finished.id == key)
                and os.clock() >= live_next_try then
                live_next_try = os.clock() + 2
                start_live(key)
            end
        end
        return
    end
    if game_state == POST_GAME then
        finish_live("game over")
        return
    end
    local now = os.clock()
    if now >= live.next_poll then
        live.next_poll = now + LIVE_POLL
        poll_live()
    end
    if live_dirty and now >= live.next_save then
        live.next_save = now + LIVE_SAVE_EVERY
        save_live()
    end
end

function ach.OnGameRulesStateChange()
    if cur and safe(GameRules.GetGameState) == POST_GAME then
        finish_live("game over")
    end
end

function ach.OnGameEnd()
    if cur then
        finish_live("game end")
    end
end

-- События чата игры (поля проверены в матче 2026-09-26):
--   FIRSTBLOOD - playerid_1 убийца, playerid_2 жертва; HERO_KILL - playerid_1 жертва, playerid_2 убийца, value золото;
--   STREAK_KILL - playerid_1 убийца, playerid_2 серия убийств без смерти, playerid_3 мультикилл (2 - двойное,
--   3 - тройное...), playerid_4 жертва; AEGIS_STOLEN - playerid_1 укравший (проверено: пользователь украл).
--   BUYBACK - playerid_1 выкупившийся (проверено в рейтинге); AEGIS - playerid_1 поднявший.
-- Остальные нужные события пишутся в лог - для проверки полей.

function ach.OnChatEvent(e)
    if not (cur and live) then
        return
    end
    local kind = e.type
    live.chat_events = live.chat_events + 1
    if CHAT_LOGGED[kind] and kind ~= CHAT.CHAT_MESSAGE_STREAK_KILL and kind ~= CHAT.CHAT_MESSAGE_HERO_KILL then
        log_event("chat %s: value %s, players %s %s %s %s (me %s)", CHAT_NAMES[kind] or tostring(kind),
            tostring(e.value), tostring(e.playerid_1), tostring(e.playerid_2), tostring(e.playerid_3),
            tostring(e.playerid_4), tostring(live.player_id))
    end
    local x, me = cur.x, live.player_id
    local clock = safe(GameRules.GetDOTATime, true, true) or 0
    if kind == CHAT.CHAT_MESSAGE_STREAK_KILL and e.playerid_1 == me then
        local multikill = int(e.playerid_3) or 0
        if multikill >= 2 and multikill > (x.mk or 0) then
            x.mk = multikill
            log("multikill x%d at %s", multikill, Timer.Format(clock))
        end
        local streak = int(e.playerid_2) or 0
        if streak > (x.streak or 0) then
            x.streak = streak
        end
        live_dirty = true
        check_live()
    elseif kind == CHAT.CHAT_MESSAGE_FIRSTBLOOD and x.fb == nil then
        x.fb = e.playerid_1 == me and 1 or (e.playerid_2 == me and -1 or 0)
        x.fb_t = int(clock)
        log("first blood at %s: %s", Timer.Format(clock), x.fb == 1 and "mine" or (x.fb == -1 and "on me" or "other"))
        live_dirty = true
        check_live()
    elseif kind == CHAT.CHAT_MESSAGE_AEGIS_STOLEN and e.playerid_1 == me then
        x.aegis_steal = (x.aegis_steal or 0) + 1
        x.aegis = 1 -- украденный - тоже поднятый
        live_dirty = true
        check_live()
    elseif kind == CHAT.CHAT_MESSAGE_AEGIS and e.playerid_1 == me and not x.aegis then
        x.aegis = 1
        live_dirty = true
        check_live()
    elseif kind == CHAT.CHAT_MESSAGE_BUYBACK and e.playerid_1 == live.player_id and not x.bb then
        x.bb = 1
        live_dirty = true
    end
end

-- Кто кого убил (только unsafe-режим): Рошан, вражеские курьеры и варды - тобой или твоими юнитами;
-- твоя смерть от нейтрала.
function ach.OnEntityKilled(e)
    if not (cur and live) then
        return
    end
    live.killed_events = live.killed_events + 1
    local target, source = e.target, e.source
    if not (target and safe(Entity.IsNPC, target)) then
        return
    end
    local hero, x = live.hero, cur.x
    local source_npc = source and safe(Entity.IsNPC, source)
    if target == hero then
        -- Wraith King упал (воскрешение или смерть - решит опрос по счётчику смертей)
        if live.hero_name == FEAT.wk and not live.down then
            live.down = { d = cur.d or 0 }
            log_event("wraith king down (killer %s)", tostring(source_npc and safe(NPC.GetUnitName, source)))
        end
        if source_npc and safe(NPC.IsNeutral, source) and safe(Entity.GetTeamNum, source) == TEAM_NEUTRAL
            and not x.neutral_death then
            x.neutral_death = 1
            live_dirty = true
            log("killed by neutral %s", tostring(safe(NPC.GetUnitName, source)))
            check_live()
        end
        return
    end
    -- твоё: герой, его юниты (мины, медведь) или юниты игрока (двойник Arc Warden)
    local me = Players.GetLocal()
    if not source or not (source == hero or safe(Entity.RecursiveOwnedBy, source, hero) == true
        or (me and safe(Entity.RecursiveOwnedBy, source, me) == true)) then
        return
    end
    local enemy = safe(Entity.GetTeamNum, target) ~= live.team
    local field
    if safe(NPC.IsRoshan, target) then
        field = "roshan"
    elseif safe(NPC.GetUnitName, target) == "npc_dota_miniboss" then
        field = "tormentor"
    elseif enemy and safe(NPC.IsCourier, target) then
        field = "courier"
    elseif enemy and safe(NPC.IsWard, target) then
        field = "wards"
    end
    if field then
        x[field] = (x[field] or 0) + 1
        live_dirty = true
        log_event("kill: %s %s (by %s)", field, tostring(safe(NPC.GetUnitName, target)),
            tostring(source_npc and safe(NPC.GetUnitName, source)))
        check_live()
        return
    end
    if not (enemy and safe(NPC.IsHero, target) and not safe(NPC.IsIllusion, target)) then
        return
    end

    -- убит вражеский герой: какой способностью и кем
    local ability = e.ability and safe(Ability.GetName, e.ability) or nil
    local hero_name = live.hero_name
    local source_name = source_npc and safe(NPC.GetUnitName, source) or nil
    local by_hero = source == hero
    local by_illusion = not by_hero and source_npc and safe(NPC.IsIllusion, source) == true
    -- своя способность героя (у украденной Rubick'ом - чужое имя): приёмы засчитываются только своему герою
    local short = hero_name:gsub("^npc_dota_hero_", "")
    local own = ability ~= nil and ability:sub(1, #short + 1) == short .. "_"
    local now = GameRules.GetGameTime()
    local notes = {}
    local function add(name)
        x[name] = (x[name] or 0) + 1
    end

    if own and ability == "invoker_sun_strike" then
        add("sunstrike")
        if safe(Entity.IsDormant, target) or not safe(NPC.IsVisible, target) then
            add("sunstrike_blind")
            notes[#notes + 1] = "unseen"
        end
    elseif own and ability == "pudge_meat_hook" then
        add("hook")
    elseif own and ability == "antimage_mana_void" then
        burst(x, "void_multi", 1) -- убитые одним Mana Void приходят вместе
    elseif own and ability == "nevermore_requiem" then
        burst(x, "requiem_multi", 2) -- волны Requiem доходят за пару секунд
    elseif own and (ability == "techies_land_mines" or ability == "techies_remote_mines") then
        add("mines")
    elseif own and ability == "chaos_knight_chaos_bolt" then
        add("chaos_bolt")
    elseif hero_name == "npc_dota_hero_rubick" and by_hero and ability and not own and not ability:find("^item_")
        and safe(NPC.GetAbility, target, ability) ~= nil then
        add("stolen_spell") -- украденная у него же способность
    end

    if hero_name == "npc_dota_hero_juggernaut" and by_hero and (ability == "juggernaut_omni_slash"
        or ability == "juggernaut_swift_slash" or safe(NPC.HasModifier, hero, FEAT.omnislash_modifier) == true) then
        burst(x, "omni_multi", 3.5)
        notes[#notes + 1] = "omnislash"
    elseif hero_name == "npc_dota_hero_spectre" then
        local cast = haunt_cast_time()
        if cast then
            local h = live.haunt
            if not (h and math.abs(h.cast - cast) < 2) then
                h = { cast = cast, n = 0 }
                live.haunt = h
            end
            h.n = h.n + 1
            x.haunt = max(x.haunt or 0, h.n)
            notes[#notes + 1] = "haunt " .. h.n
        end
    elseif hero_name == "npc_dota_hero_meepo" and source_name == hero_name and not by_illusion then
        -- разные Meepo - разные сущности; номера - в записи, чтобы пережить перезагрузку скриптов
        local id = tostring(safe(Entity.GetIndex, source))
        local ids = x.meepo_ids or ""
        if not ("," .. ids .. ","):find("," .. id .. ",", 1, true) then
            x.meepo_ids = ids == "" and id or ids .. "," .. id
            x.meepo = (x.meepo or 0) + 1
        end
        notes[#notes + 1] = "meepo " .. id
    elseif hero_name == FEAT.wk and by_hero and live.revived_at and now - live.revived_at <= FEAT.revived_window then
        x.reincarnation = 1
        notes[#notes + 1] = "after revival"
    elseif hero_name == FEAT.ls and by_hero and (ability == "life_stealer_infest" or ability == "life_stealer_consume"
        or safe(NPC.HasModifier, hero, FEAT.infest_modifier) == true
        or (live.infest_seen and now - live.infest_seen <= FEAT.infest_window)) then
        x.infest = 1
        notes[#notes + 1] = "infest"
    elseif hero_name == "npc_dota_hero_phantom_lancer" and by_illusion then
        add("pl_illusions")
        notes[#notes + 1] = "illusion"
    elseif hero_name == "npc_dota_hero_arc_warden" and source_name == hero_name and not by_hero and not by_illusion then
        add("tempest") -- двойник: не иллюзия, тот же герой, но не ты
        notes[#notes + 1] = "clone"
    elseif hero_name == "npc_dota_hero_legion_commander" and by_hero
        and safe(NPC.HasModifier, hero, "modifier_legion_commander_duel") == true then
        add("duels")
        notes[#notes + 1] = "in duel"
    end
    log_event("hero kill: %s by %s, ability %s%s", tostring(safe(NPC.GetUnitName, target)), tostring(source_name),
        tostring(ability), #notes > 0 and ", " .. table.concat(notes, ", ") or "")
    live_dirty = true
    check_live()
end

-- Крит Phantom Assassin (только unsafe-режим): самый сильный удар атакой по вражескому герою за матч.
-- Колбэк на каждый урон в игре - сначала самые дешёвые проверки.
function ach.OnEntityHurt(e)
    if not (live and live.hero_name == FEAT.pa) or e.source ~= live.hero then
        return
    end
    local damage = tonumber(e.damage) or 0
    if damage < FEAT.crit_log_from then
        return
    end
    local ability = e.ability and safe(Ability.GetName, e.ability) or nil
    if ability and ability ~= "phantom_assassin_coup_de_grace" then
        return -- урон способностью (Stifling Dagger и т.п.), не атака
    end
    local target = e.target
    if not (target and safe(NPC.IsHero, target) and not safe(NPC.IsIllusion, target)
        and safe(Entity.GetTeamNum, target) ~= live.team) then
        return
    end
    log_event("hit: %d on %s, ability %s", int(damage), tostring(safe(NPC.GetUnitName, target)), tostring(ability))
    local x = cur.x
    if damage > (x.crit or 0) then
        x.crit = int(damage)
        live_dirty = true
        check_live()
    end
end

--#endregion

-- ступень «Все герои» - по числу героев в игре
do
    local count = count_heroes()
    local all = FAMILY_BY_ID.heroes.tiers[4]
    if count >= 100 and count <= 200 then
        all[1] = count
    end
    log("v%s loaded: %d achievements (%d tiers), heroes in game: %d, Notification(): %s",
        VERSION, #FAMILIES, TOTAL_TIERS, count, type(Notification))
end

return ach
