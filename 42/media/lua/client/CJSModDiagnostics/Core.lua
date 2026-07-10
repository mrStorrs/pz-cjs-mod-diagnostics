CJSModDiagnostics = CJSModDiagnostics or {}

local Diagnostics = CJSModDiagnostics
local MOD_ID = "cjsModDiagnostics"
local VERSION = "0.1.1"
local HEARTBEAT_INTERVAL_MS = 5000
local MAX_RING_EVENTS = 16

local state = Diagnostics._state or {
    adapters = {},
    ring = {},
    lastHeartbeatMillis = 0,
    started = false,
    tickHooked = false,
}
Diagnostics._state = state
Diagnostics.VERSION = VERSION

local function safeCall(fn, fallback)
    local ok, value = pcall(fn)
    if ok then return value end
    return fallback
end

local function nowMillis()
    if getTimeInMillis then
        return tonumber(safeCall(function() return getTimeInMillis() end, 0)) or 0
    end
    if os and os.time then return os.time() * 1000 end
    return 0
end

local function scalar(value, key)
    local valueType = type(value)
    if valueType == "number" or valueType == "boolean" then return value end
    if valueType == "nil" then return nil end

    local text = valueType == "string" and value or "<" .. valueType .. ">"
    text = text:gsub("[%c]", " ")
    local limit = key == "error" and 1200 or 160
    if #text > limit then text = text:sub(1, limit - 3) .. "..." end
    return text
end

local function copyScalars(fields)
    local copy = {}
    for key, value in pairs(fields or {}) do
        local textKey = tostring(key)
        copy[textKey] = scalar(value, textKey)
    end
    return copy
end

local function fieldText(value)
    if type(value) == "number" then
        if value ~= value then return "nan" end
        if value == math.huge then return "inf" end
        if value == -math.huge then return "-inf" end
        if value == math.floor(value) then return tostring(value) end
        return string.format("%.2f", value)
    end
    return tostring(value)
end

function Diagnostics.log(level, event, fields)
    local keys = {}
    local clean = copyScalars(fields)
    for key in pairs(clean) do keys[#keys + 1] = key end
    table.sort(keys)

    local parts = {
        "[" .. MOD_ID .. "]",
        "level=" .. tostring(level),
        "event=" .. tostring(event),
    }
    for i = 1, #keys do
        local key = keys[i]
        if clean[key] ~= nil then
            parts[#parts + 1] = key .. "=" .. fieldText(clean[key])
        end
    end
    print(table.concat(parts, " "))
end

local function adapterState(name)
    local adapter = state.adapters[name]
    if adapter then return adapter end

    adapter = {
        counts = {},
        latest = {},
        lastSuspicious = {},
        throttles = {},
        summaryProvider = nil,
    }
    state.adapters[name] = adapter
    return adapter
end

function Diagnostics.increment(adapterName, key, amount)
    local adapter = adapterState(adapterName)
    adapter.counts[key] = (adapter.counts[key] or 0) + (amount or 1)
end

function Diagnostics.setLatest(adapterName, fields)
    adapterState(adapterName).latest = copyScalars(fields)
end

function Diagnostics.setSummaryProvider(adapterName, provider)
    adapterState(adapterName).summaryProvider = provider
end

local function pushRing(record)
    state.ring[#state.ring + 1] = record
    if #state.ring > MAX_RING_EVENTS then table.remove(state.ring, 1) end
end

function Diagnostics.flag(adapterName, event, fields, throttleKey, throttleMillis)
    local adapter = adapterState(adapterName)
    local clean = copyScalars(fields)
    local millis = nowMillis()
    clean.adapter = adapterName
    clean.event = event
    clean.millis = millis
    adapter.lastSuspicious = clean
    Diagnostics.increment(adapterName, "suspicious")
    pushRing({adapter = adapterName, event = event, fields = clean})

    local key = throttleKey or event
    local last = adapter.throttles[key]
    if last == nil or millis - last >= (throttleMillis or 1000) then
        adapter.throttles[key] = millis
        Diagnostics.log("WARN", event, clean)
    else
        Diagnostics.increment(adapterName, "warnings_suppressed")
    end
end

function Diagnostics.sample(adapterName, event, fields, throttleMillis)
    local adapter = adapterState(adapterName)
    local millis = nowMillis()
    local key = "sample:" .. event
    local last = adapter.throttles[key]
    if last ~= nil and millis - last < (throttleMillis or 30000) then return end
    adapter.throttles[key] = millis

    local clean = copyScalars(fields)
    clean.adapter = adapterName
    Diagnostics.log("DEBUG", event, clean)
end

function Diagnostics.isModActive(modId)
    if not getActivatedMods then return false end
    local mods = safeCall(function() return getActivatedMods() end, nil)
    if not mods then return false end
    return safeCall(function() return mods:contains(modId) end, false) == true
end

local function heartbeatFields(name, adapter)
    local fields = {adapter = name}
    for key, value in pairs(adapter.counts) do fields[key] = value end
    for key, value in pairs(adapter.latest) do fields["last_" .. key] = value end
    local riskKeys = {"event", "reason", "source", "from", "target", "distance", "millis"}
    for i = 1, #riskKeys do
        local key = riskKeys[i]
        if adapter.lastSuspicious[key] ~= nil then
            fields["risk_" .. key] = adapter.lastSuspicious[key]
        end
    end

    if adapter.summaryProvider then
        local extra = safeCall(adapter.summaryProvider, {summary_error = true})
        for key, value in pairs(extra or {}) do fields[key] = value end
    end
    return fields
end

local function onTick()
    -- high-freq: the time gate keeps diagnostics work to one pass every five seconds.
    local millis = nowMillis()
    if millis - state.lastHeartbeatMillis < HEARTBEAT_INTERVAL_MS then return end
    state.lastHeartbeatMillis = millis

    local names = {}
    for name in pairs(state.adapters) do names[#names + 1] = name end
    table.sort(names)
    for i = 1, #names do
        local name = names[i]
        Diagnostics.log("DEBUG", "heartbeat", heartbeatFields(name, state.adapters[name]))
    end
end

function Diagnostics.start()
    if not state.tickHooked then
        state.tickHooked = true
        Events.OnTick.Add(onTick)
    end
    if state.started then return end

    state.started = true
    state.lastHeartbeatMillis = nowMillis()
    Diagnostics.log("INFO", "started", {
        version = VERSION,
        wandering_zombies_active = Diagnostics.isModActive("WanderingZombiesWIP"),
        tempo_perfkit_active = Diagnostics.isModActive("Tempo_PerfKit"),
        heartbeat_ms = HEARTBEAT_INTERVAL_MS,
        ring_capacity = MAX_RING_EVENTS,
    })
end

return Diagnostics
