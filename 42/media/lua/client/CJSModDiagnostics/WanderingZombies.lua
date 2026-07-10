require "CJSModDiagnostics/Core"

local Diagnostics = CJSModDiagnostics
local ADAPTER = "wandering_zombies"
local LONG_PATH_DISTANCE = 100
local BURST_WINDOW_MS = 1000
local BURST_THRESHOLD = 24
local WARNING_THROTTLE_MS = 1000

Diagnostics.WanderingZombies = Diagnostics.WanderingZombies or {}
local WanderingZombies = Diagnostics.WanderingZombies
local state = WanderingZombies._state or {
    installed = false,
    original = nil,
    wrapper = nil,
    windowStartMillis = 0,
    windowCount = 0,
    burstMax = 0,
}
WanderingZombies._state = state

local unpackValues = unpack or table.unpack

local function pack(...)
    return {n = select("#", ...), ...}
end

local function safeCall(fn, fallback)
    local ok, value = pcall(fn)
    if ok then return value end
    return fallback
end

local function reportDiagnosticsError(stage, errorValue)
    pcall(function()
        Diagnostics.log("ERROR", "adapter_failure", {
            adapter = ADAPTER,
            stage = stage,
            error = errorValue,
        })
    end)
end

local function nowMillis()
    if not getTimeInMillis then return 0 end
    return tonumber(safeCall(function() return getTimeInMillis() end, 0)) or 0
end

local function finite(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function coordinate(object, key)
    if not object then return nil end
    return tonumber(safeCall(function() return object[key] end, nil))
end

local function positionText(x, y, z)
    if not finite(x) or not finite(y) or not finite(z) then return "invalid" end
    return string.format("%.0f,%.0f,%.0f", math.floor(x), math.floor(y), math.floor(z))
end

local function distanceBetween(x1, y1, x2, y2)
    if not finite(x1) or not finite(y1) or not finite(x2) or not finite(y2) then return nil end
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt((dx * dx) + (dy * dy))
end

local function wzOption(key)
    if not WZSandboxVars or type(WZSandboxVars.get) ~= "function" then return nil end
    return safeCall(function() return WZSandboxVars:get(WZ_SHARED, key) end, nil)
end

local function wzCount(methodName)
    if not WZSandboxVars then return nil end
    local method = safeCall(function() return WZSandboxVars[methodName] end, nil)
    if type(method) ~= "function" then return nil end
    return tonumber(safeCall(function() return method(WZSandboxVars) end, nil))
end

local function candidateSummary(x, y, z)
    local summary = {
        cell_available = false,
        loaded_candidates = 0,
        unloaded_candidates = 0,
        solid_floor_candidates = 0,
    }
    if not finite(x) or not finite(y) or not finite(z) then return summary end

    local cell = getCell and safeCall(function() return getCell() end, nil) or nil
    if not cell then
        summary.unloaded_candidates = 3
        return summary
    end

    summary.cell_available = true
    local targetX = math.floor(x)
    local targetY = math.floor(y)
    local targetZ = math.floor(z)
    for offset = -1, 1 do
        local square = safeCall(function()
            return cell:getGridSquare(targetX, targetY, targetZ + offset)
        end, nil)
        if square == nil then
            summary.unloaded_candidates = summary.unloaded_candidates + 1
        else
            summary.loaded_candidates = summary.loaded_candidates + 1
            if safeCall(function() return square:isSolidFloor() end, false) then
                summary.solid_floor_candidates = summary.solid_floor_candidates + 1
            end
        end
    end
    return summary
end

local function inObservedPhysicsRegion(x, y)
    if not finite(x) or not finite(y) then return false end
    -- Covers the repeated IsoChunk physics-overflow coordinates in the July 7-9 logs, with margin.
    return x >= 5024 and x <= 5387 and y >= 15439 and y <= 15677
end

local function updateBurst(millis)
    if millis - state.windowStartMillis >= BURST_WINDOW_MS then
        state.windowStartMillis = millis
        state.windowCount = 0
    end
    state.windowCount = state.windowCount + 1
    state.burstMax = math.max(state.burstMax, state.windowCount)
    return state.windowCount
end

local function sourceName(moveType, forceOOCP, forcePathfind, skipDestruction)
    if moveType == "Wander" and forcePathfind == true and skipDestruction == true then
        return "director_pull"
    end
    if forceOOCP == true then return "forced_out_of_cell" end
    return tostring(moveType or "unknown")
end

local function analyze(self, pos, moveType, inHorde, noZScan, forceOOCP, forcePathfind, skipDestruction)
    local x = coordinate(pos, "x")
    local y = coordinate(pos, "y")
    local z = coordinate(pos, "z")
    local ref = self and safeCall(function() return self._ref end, nil) or nil
    local fromX = ref and tonumber(safeCall(function() return ref:getX() end, nil)) or nil
    local fromY = ref and tonumber(safeCall(function() return ref:getY() end, nil)) or nil
    local fromZ = ref and tonumber(safeCall(function() return ref:getZ() end, nil)) or nil
    local distance = distanceBetween(fromX, fromY, x, y)
    local candidates = candidateSummary(x, y, z)
    local zombieCount = wzCount("getZombieCount")
    local outOfCellEnabled = wzOption("OutOfCellPaths") == true
    local outOfCellThreshold = tonumber(wzOption("OutOfCellThreshold"))
    local forcePathfindMode = tonumber(wzOption("ForcePathfind"))
    local isOutside = self and safeCall(function() return self:isOutside() end, nil) or nil
    local effectivePathfind = forcePathfind == true
        or forcePathfindMode == 3
        or (forcePathfindMode == 2 and isOutside == false)
    local outOfCellEligible = forceOOCP == true
        or (outOfCellEnabled and zombieCount and outOfCellThreshold
            and zombieCount > outOfCellThreshold)
    local burst = updateBurst(nowMillis())
    local reasons = {}

    if not finite(x) or not finite(y) or not finite(z) then reasons[#reasons + 1] = "invalid_target" end
    if not candidates.cell_available then reasons[#reasons + 1] = "cell_unavailable" end
    if outOfCellEligible and candidates.unloaded_candidates > 0 then
        reasons[#reasons + 1] = "unloaded_candidate"
    end
    if forceOOCP == true then reasons[#reasons + 1] = "forced_out_of_cell" end
    if effectivePathfind then reasons[#reasons + 1] = "forced_pathfind" end
    if distance and distance >= LONG_PATH_DISTANCE then reasons[#reasons + 1] = "long_path" end
    if inObservedPhysicsRegion(fromX, fromY) or inObservedPhysicsRegion(x, y) then
        reasons[#reasons + 1] = "observed_physics_region"
    end
    if burst >= BURST_THRESHOLD then reasons[#reasons + 1] = "path_burst" end

    return {
        source = sourceName(moveType, forceOOCP, forcePathfind, skipDestruction),
        move_type = moveType,
        from = positionText(fromX, fromY, fromZ),
        target = positionText(x, y, z),
        distance = distance,
        in_horde = inHorde == true,
        no_z_scan = noZScan == true,
        force_ooc = forceOOCP == true,
        force_pathfind = forcePathfind == true,
        force_pathfind_mode = forcePathfindMode,
        effective_pathfind = effectivePathfind,
        skip_destruction = skipDestruction == true,
        cell_available = candidates.cell_available,
        loaded_candidates = candidates.loaded_candidates,
        unloaded_candidates = candidates.unloaded_candidates,
        solid_floor_candidates = candidates.solid_floor_candidates,
        ooc_enabled = outOfCellEnabled,
        ooc_threshold = outOfCellThreshold,
        ooc_eligible = outOfCellEligible == true,
        wz_zombies = zombieCount,
        burst = burst,
        reason = #reasons > 0 and table.concat(reasons, "+") or nil,
    }, #reasons > 0
end

local function setLatest(fields)
    Diagnostics.setLatest(ADAPTER, {
        source = fields.source,
        from = fields.from,
        target = fields.target,
        actual_target = fields.actual_target,
        distance = fields.distance,
        reason = fields.reason,
        ooc_eligible = fields.ooc_eligible,
        unloaded_candidates = fields.unloaded_candidates,
        force_pathfind = fields.force_pathfind,
        effective_pathfind = fields.effective_pathfind,
        burst = fields.burst,
        result = fields.result,
    })
end

local function pathTarget(ref)
    return positionText(
        ref and tonumber(safeCall(function() return ref:getPathTargetX() end, nil)) or nil,
        ref and tonumber(safeCall(function() return ref:getPathTargetY() end, nil)) or nil,
        ref and tonumber(safeCall(function() return ref:getPathTargetZ() end, nil)) or nil
    )
end

local function playerPosition()
    if not getPlayer then return "unavailable" end
    local player = safeCall(function() return getPlayer() end, nil)
    if not player then return "unavailable" end
    return positionText(
        tonumber(safeCall(function() return player:getX() end, nil)),
        tonumber(safeCall(function() return player:getY() end, nil)),
        tonumber(safeCall(function() return player:getZ() end, nil))
    )
end

local function summary()
    local wrapperCurrent = WZZombieBase and WZZombieBase.pathTo == state.wrapper
    return {
        wrapper_current = wrapperCurrent == true,
        window_paths = state.windowCount,
        burst_max = state.burstMax,
        player = playerPosition(),
        wz_zombies = wzCount("getZombieCount"),
        wz_hordes = wzCount("getHordeCount"),
        ooc_enabled = wzOption("OutOfCellPaths") == true,
        ooc_threshold = tonumber(wzOption("OutOfCellThreshold")),
        force_pathfind_mode = tonumber(wzOption("ForcePathfind")),
        pathfinding_backend = Diagnostics.pathfindingBackend(),
    }
end

function WanderingZombies.install()
    if not WZZombieBase or type(WZZombieBase.pathTo) ~= "function" then return false end
    if WZZombieBase.pathTo == state.wrapper then return true end

    if state.installed then
        Diagnostics.flag(ADAPTER, "wrapper_displaced", {
            target = "WZZombieBase.pathTo",
        }, "wrapper_displaced", 30000)
        return false
    end

    local original = WZZombieBase.pathTo
    local function wrappedPathTo(self, pos, moveType, inHorde, noZScan, forceOOCP, forcePathfind, skipDestruction)
        -- high-freq: this observes each WIP path request and only emits sampled or throttled lines.
        local fields
        local observed, observationError = pcall(function()
            Diagnostics.increment(ADAPTER, "requests")
            local suspicious
            fields, suspicious = analyze(
                self, pos, moveType, inHorde, noZScan, forceOOCP, forcePathfind, skipDestruction
            )
            setLatest(fields)
            if suspicious then
                Diagnostics.flag(ADAPTER, "path_request", fields, "path_request", WARNING_THROTTLE_MS)
            else
                Diagnostics.sample(ADAPTER, "path_sample", fields, 30000)
            end
        end)
        if not observed then
            reportDiagnosticsError("before_path", observationError)
        end

        local results = pack(original(
            self, pos, moveType, inHorde, noZScan, forceOOCP, forcePathfind, skipDestruction
        ))
        local completed, completionError = pcall(function()
            Diagnostics.increment(ADAPTER, "completed")
            if results[1] == false then Diagnostics.increment(ADAPTER, "rejected") end

            if fields then
                local ref = self and safeCall(function() return self._ref end, nil) or nil
                fields.actual_target = pathTarget(ref)
                fields.result = results[1]
                setLatest(fields)
            end
        end)
        if not completed then
            reportDiagnosticsError("after_path", completionError)
        end
        return unpackValues(results, 1, results.n)
    end

    state.original = original
    state.wrapper = wrappedPathTo
    state.installed = true
    WZZombieBase.pathTo = wrappedPathTo
    Diagnostics.setSummaryProvider(ADAPTER, summary)
    Diagnostics.log("INFO", "adapter_installed", {
        adapter = ADAPTER,
        target = "WZZombieBase.pathTo",
        long_path_distance = LONG_PATH_DISTANCE,
        burst_threshold = BURST_THRESHOLD,
    })
    return true
end

return WanderingZombies
