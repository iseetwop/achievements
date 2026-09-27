-- ulib/http.lua
-- GET-запросы с JSON-ответом: кэш в памяти и на диске, склейка одинаковых запросов.
--
--   local Http = require("ulib.http")
--   Http.GetJSON("https://api.opendota.com/api/heroes", { ttl = 24 * 3600 }, function(data, err, cached)
--       if data then ... end
--   end)
--   Http.UrlEncode(sql) -- для параметров запроса (например, OpenDota explorer?sql=)
--
-- ttl - сколько секунд ответ считается свежим (0 - без кэша, ответ не хранится и в памяти). Если сеть не ответила, callback
-- получает устаревший кэш вместе с ошибкой. При попадании в кэш callback вызывается сразу,
-- ещё внутри GetJSON. Кэш на диске - configs/ulib_http_<хэш url>.json.
-- accept(data) -> bool (необязательно): ответ, который не прошёл проверку (например, {"err": ...}
-- с кодом 200), считается ошибкой и в кэш не попадает.
-- Запрос, на который нет ответа дольше timeout + 15 с, считается потерянным: ожидающие получают
-- ошибку, следующий такой же запрос уходит заново.

local JSON = require("assets.JSON")
local Store = require("ulib.store")

local Http = {}

local HEADERS <const> = { ["User-Agent"] = "Umbrella/ulib", ["Accept"] = "application/json" }

-- модуль общий для всех скриптов, поэтому кэш и ожидающие запросы тоже общие
local memory = {}  -- ключ -> { url, time, data }
local pending = {} -- ключ -> { at, limit, callbacks, done }
local LOST_AFTER <const> = 15 -- сверх timeout запроса

-- FNV-1a, 32 бита: короткое имя файла кэша по url
local function hash(s)
    local h = 2166136261
    for i = 1, #s do
        h = ((h ~ s:byte(i)) * 16777619) & 0xFFFFFFFF
    end
    return ("%08x"):format(h)
end

local function cached_entry(key, url, use_disk)
    local entry = memory[key]
    if not entry and use_disk then
        entry = Store.Load("http_" .. key, nil)
        if entry and entry.url ~= url then
            entry = nil -- совпал хэш другого url
        end
        memory[key] = entry
    end
    return entry
end

-- ошибка в callback одного скрипта не должна ломать остальных ожидающих
local function notify(callbacks, ...)
    for _, cb in ipairs(callbacks) do
        local ok, err = pcall(cb, ...)
        if not ok then
            print("[ulib.http] callback error: " .. tostring(err))
        end
    end
end

-- Кодирование для query-строки: Http.UrlEncode("a b") --> "a%20b".
function Http.UrlEncode(s)
    return (s:gsub("[^%w%-_%.~]", function(c)
        return ("%%%02X"):format(c:byte())
    end))
end

-- callback(data, err, cached): data - разобранный JSON или nil; cached - данные из кэша.
function Http.GetJSON(url, opts, callback)
    opts = opts or {}
    local ttl = opts.ttl or 0
    local key = hash(url)
    local entry = cached_entry(key, url, ttl > 0)
    if entry and ttl > 0 and os.time() - entry.time < ttl then
        notify({ callback }, entry.data, nil, true)
        return
    end

    local timeout = opts.timeout or 15
    local waiting = pending[key]
    if waiting then
        if os.clock() - waiting.at < waiting.limit then
            waiting.callbacks[#waiting.callbacks + 1] = callback
            return
        end
        -- ответа так и нет: ожидающим - ошибка, запрос отправляем заново
        waiting.done = true
        notify(waiting.callbacks, entry and entry.data, "no response", entry ~= nil)
    end
    waiting = { at = os.clock(), limit = timeout + LOST_AFTER, callbacks = { callback } }
    pending[key] = waiting

    local function on_response(res)
        if pending[key] == waiting then
            pending[key] = nil
        end
        local data, err
        if tostring(res.code) == "200" then
            local ok, decoded = pcall(JSON.decode, JSON, res.response)
            if ok then
                data = decoded
            else
                err = "bad json: " .. tostring(decoded)
            end
        else
            err = ("http %s %s"):format(tostring(res.code), tostring(res.error_message or ""))
        end
        if data ~= nil and opts.accept then
            local ok, accepted = pcall(opts.accept, data)
            if not (ok and accepted) then
                err, data = "response rejected", nil
            end
        end

        if data == nil then
            if not waiting.done then
                notify(waiting.callbacks, entry and entry.data, err, entry ~= nil)
            end
            return
        end
        if ttl > 0 then
            memory[key] = { url = url, time = os.time(), data = data }
            local ok, save_err = pcall(Store.Save, "http_" .. key, memory[key])
            if not ok then
                print("[ulib.http] cache not saved: " .. tostring(save_err))
            end
        else
            memory[key] = nil -- без кэша: большой ответ (история матчей) не держим в памяти всю сессию
        end
        -- опоздавший ответ всё равно попадает в кэш, но ожидающие уже получили ошибку
        if not waiting.done then
            notify(waiting.callbacks, data, nil, false)
        end
    end

    local sent = HTTP.Request("GET", url, { headers = HEADERS, timeout = timeout }, on_response, key)
    if not sent then
        if pending[key] == waiting then
            pending[key] = nil
        end
        notify(waiting.callbacks, entry and entry.data, "request was not sent", entry ~= nil)
    end
end

return Http
