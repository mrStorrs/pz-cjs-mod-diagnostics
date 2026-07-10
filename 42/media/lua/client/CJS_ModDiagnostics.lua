if isServer() then return end

require "CJSModDiagnostics/Core"
require "CJSModDiagnostics/WanderingZombies"

local Diagnostics = CJSModDiagnostics
local WanderingZombies = Diagnostics.WanderingZombies
local RETRY_INTERVAL_MS = 1000
local MAX_RETRY_ATTEMPTS = 60

local retryHooked = false
local unavailableLogged = false
local retryAttempts = 0
local nextRetryMillis = 0
local installAdapters

local function stopRetry()
    if not retryHooked then return end
    Events.OnTick.Remove(installAdapters)
    retryHooked = false
end

installAdapters = function()
    -- high-freq: missing adapters are retried at most once per second for one minute.
    if retryHooked then
        local millis = getTimeInMillis and getTimeInMillis() or 0
        if millis < nextRetryMillis then return end
        nextRetryMillis = millis + RETRY_INTERVAL_MS
        retryAttempts = retryAttempts + 1
    end

    Diagnostics.start()

    if WanderingZombies.install() then
        stopRetry()
        return
    end

    if not unavailableLogged then
        unavailableLogged = true
        Diagnostics.log("INFO", "adapter_waiting", {
            adapter = "wandering_zombies",
            target = "WZZombieBase.pathTo",
        })
    end

    if retryAttempts >= MAX_RETRY_ATTEMPTS then
        Diagnostics.log("WARN", "adapter_unavailable", {
            adapter = "wandering_zombies",
            target = "WZZombieBase.pathTo",
            retry_attempts = retryAttempts,
        })
        stopRetry()
        return
    end

    if not retryHooked then
        retryHooked = true
        Events.OnTick.Add(installAdapters)
    end
end

Events.OnGameStart.Add(installAdapters)
