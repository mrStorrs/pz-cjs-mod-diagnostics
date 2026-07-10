local root = arg[1]
assert(root, "usage: lua test_wandering_zombies.lua <client-lua-root>")

package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local logs = {}
local clock = 1000
local callbacks = {gameStart = {}, tick = {}}

_G.print = function(message) logs[#logs + 1] = tostring(message) end
isServer = function() return false end
getTimeInMillis = function() return clock end
getActivatedMods = function()
    return {
        contains = function(_, id)
            return id == "WanderingZombiesWIP" or id == "Tempo_PerfKit"
        end,
    }
end

local function event(list)
    return {
        Add = function(fn) list[#list + 1] = fn end,
        Remove = function(fn)
            for i = #list, 1, -1 do
                if list[i] == fn then table.remove(list, i) end
            end
        end,
    }
end

Events = {
    OnGameStart = event(callbacks.gameStart),
    OnTick = event(callbacks.tick),
}

getCell = function()
    return {
        getGridSquare = function() return nil end,
    }
end
getPlayer = function()
    return {
        getX = function() return 5100 end,
        getY = function() return 15500 end,
        getZ = function() return 0 end,
    }
end

WZ_SHARED = "shared"
WZSandboxVars = {
    get = function(_, _, key)
        local values = {
            OutOfCellPaths = true,
            OutOfCellThreshold = 150,
            ForcePathfind = 1,
        }
        return values[key]
    end,
    getZombieCount = function() return 180 end,
    getHordeCount = function() return 3 end,
}

local originalCalls = {}
local original = function(self, pos, moveType, inHorde, noZScan, forceOOCP, forcePathfind, skipDestruction)
    originalCalls[#originalCalls + 1] = {
        self, pos, moveType, inHorde, noZScan, forceOOCP, forcePathfind, skipDestruction,
    }
    if moveType == "Explode" then error("sentinel path error") end
    return true, nil, 7
end

WZZombieBase = nil

dofile(root .. "/CJS_ModDiagnostics.lua")
assert(#callbacks.gameStart == 1, "expected an OnGameStart hook")
callbacks.gameStart[1]()
assert(#callbacks.tick == 2, "missing adapter should install one bounded retry hook")

WZZombieBase = {pathTo = original}
local pendingTicks = {}
for i = 1, #callbacks.tick do pendingTicks[i] = callbacks.tick[i] end
for i = 1, #pendingTicks do pendingTicks[i]() end
assert(WZZombieBase.pathTo ~= original, "pathTo was not wrapped")
assert(#callbacks.tick == 1, "adapter retry hook was not removed after installation")

local ref = {
    getX = function() return 5100 end,
    getY = function() return 15500 end,
    getZ = function() return 0 end,
    getPathTargetX = function() return 6000 end,
    getPathTargetY = function() return 16000 end,
    getPathTargetZ = function() return 0 end,
}
local zombie = {_ref = ref}
local pos = {x = 6000.4, y = 16000.8, z = 0}

local returned = {n = 0}
local function capture(...)
    returned = {n = select("#", ...), ...}
end
capture(WZZombieBase.pathTo(zombie, pos, "Wander", false, false, false, true, true))
assert(returned.n == 3, "wrapper changed the return count")
assert(returned[1] == true and returned[2] == nil and returned[3] == 7, "wrapper changed return values")
assert(#originalCalls == 1, "original pathTo was not called exactly once")
assert(originalCalls[1][1] == zombie and originalCalls[1][2] == pos, "wrapper changed receiver or target")
assert(originalCalls[1][7] == true and originalCalls[1][8] == true, "wrapper changed path flags")

local setLatest = CJSModDiagnostics.setLatest
CJSModDiagnostics.setLatest = function() error("diagnostics failed") end
capture(WZZombieBase.pathTo(zombie, pos, "Wander", false, false, false, true, true))
CJSModDiagnostics.setLatest = setLatest
assert(returned.n == 3 and returned[1] == true and returned[3] == 7, "diagnostic failure changed returns")
assert(#originalCalls == 2, "diagnostic failure blocked the original pathTo")

local warningFound = false
for i = 1, #logs do
    if logs[i]:find("level=WARN", 1, true)
        and logs[i]:find("source=director_pull", 1, true)
        and logs[i]:find("unloaded_candidate", 1, true)
    then
        warningFound = true
    end
end
assert(warningFound, "expected a warning with director-pull and unloaded-candidate context")

local ok, err = pcall(function()
    WZZombieBase.pathTo(zombie, pos, "Explode", false, false, false, false, false)
end)
assert(not ok and tostring(err):find("sentinel path error", 1, true), "wrapper swallowed the original error")

for _ = 1, 40 do
    clock = clock + 10
    WZZombieBase.pathTo(zombie, pos, "Wander", false, false, false, true, true)
end
assert(#CJSModDiagnostics._state.ring == 16, "diagnostic ring is not bounded")

clock = clock + 5000
for i = 1, #callbacks.tick do callbacks.tick[i]() end

local heartbeatFound = false
for i = 1, #logs do
    if logs[i]:find("event=heartbeat", 1, true)
        and logs[i]:find("wrapper_current=true", 1, true)
    then
        heartbeatFound = true
    end
end
assert(heartbeatFound, "expected a heartbeat with wrapper state")

io.stdout:write("ok - wandering zombies diagnostics preserve behavior and bound logging\n")
