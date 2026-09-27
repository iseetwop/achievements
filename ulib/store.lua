-- ulib/store.lua
-- Таблицы скриптов в JSON-файлах configs/ulib_<name>.json (история матчей, кэш и т.п.).
-- Для отдельных чисел и строк проще Config.Read*/Write* (он пишет в db.json).
-- Запись атомарная: временный файл и переименование, чтобы сбой не оставил файл обрезанным.
--
--   local Store = require("ulib.store")
--   local diary = Store.Load("diary", { matches = {} })
--   Store.Save("diary", diary)
--
-- JSON не различает массив и объект с числовыми ключами: у разреженных массивов ключи
-- после загрузки станут строками. Храним либо массивы подряд, либо объекты со строковыми ключами.

local JSON = require("assets.JSON")

local Store = {}

local function file_path(name)
    assert(type(name) == "string" and name:match("^[%w_]+$"), "store name: only letters, digits and _")
    local dir = Engine.GetCheatDirectory()
    if not dir:match("[\\/]$") then
        dir = dir .. "\\"
    end
    return dir .. "configs\\ulib_" .. name .. ".json"
end

local function write_file(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

-- Возвращает сохранённую таблицу или default, если файла нет или он повреждён.
function Store.Load(name, default)
    local f = io.open(file_path(name), "rb")
    if not f then
        return default
    end
    local text = f:read("a")
    f:close()
    local ok, data = pcall(JSON.decode, JSON, text)
    if ok and type(data) == "table" then
        return data
    end
    print(("[ulib.store] %s: damaged file, using default (%s)"):format(name, tostring(data)))
    return default
end

function Store.Save(name, data)
    local target = file_path(name)
    local text = JSON:encode(data)
    local tmp = target .. ".tmp"
    write_file(tmp, text)
    os.remove(target)
    if not os.rename(tmp, target) then
        write_file(target, text)
        os.remove(tmp)
    end
end

return Store
