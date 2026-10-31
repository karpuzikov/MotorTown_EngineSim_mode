-- Motor Town -> Engine Simulator (open-source version) telemetry exporter.
-- v0.1, single-player; UE4SS experimental with LoopInGameThreadWithDelay.
-- Does not change vehicle physics or write any game properties.

-- Optional: Set exact reflected paths after looking at the diagnostic log.
-- Examples of PATH SYNTAX only (not verified Motor Town field names):
--   RPM_PATH = "EngineComponent.CurrentRPM"
local RPM_PATH = nil
local THROTTLE_PATH = nil
local IGNITION_PATH = nil

local TEMP = os.getenv("TMP") or os.getenv("TEMP")
if not TEMP then
    print("[MotorTownEngineSim] No TEMP directory. Export disabled.\n")
    return
end
local TELEMETRY = TEMP .. "\\MotorTownEngineSim_telemetry.txt"
local DEBUG_LOG = TEMP .. "\\MotorTownEngineSim_diagnostics.txt"
local lastVehicle = nil
local mapping = nil
local lastValue = ""

local function log(line)
    local f = io.open(DEBUG_LOG, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
        f:close()
    end
    print("[MotorTownEngineSim] " .. line .. "\n")
end

local function valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function member(obj, name)
    local ok, result = pcall(function() return obj[name] end)
    if ok then return result end
    return nil
end

local function path_value(root, path)
    if not path or not root then return nil end
    local current = root
    for name in path:gmatch("[^%.]+") do
        if current == nil then return nil end
        current = member(current, name)
    end
    return current
end

local function field_names(obj)
    local names = {}
    local ok = pcall(function()
        local klass = obj:GetClass()
        for _ = 1, 12 do
            if not valid(klass) then break end
            klass:ForEachProperty(function(prop)
                local success, name = pcall(function()
                    return prop:GetFName():ToString()
                end)
                if success and type(name) == "string" then
                    names[#names + 1] = name
                end
                return false
            end)
            klass = klass:GetSuperStruct()
        end
    end)
    if not ok then return names end
    return names
end

local function score(name, kind)
    local n = name:lower():gsub("[^a-z0-9]", "")
    local scoreValue = -1
    if kind == "rpm" then
        if n == "rpm" or n == "enginerpm" or n == "currentrpm" then
            scoreValue = 120
        elseif n:find("rpm", 1, true) then
            scoreValue = 90
        elseif n:find("engine", 1, true) and n:find("speed", 1, true) then
            scoreValue = 45
        end
        if n:find("max") or n:find("min") or n:find("limit") or
           n:find("idle") or n:find("target") or n:find("redline") then
            scoreValue = -1
        end
    elseif kind == "throttle" then
        if n == "throttle" or n == "throttleinput" or n == "currentthrottle" then
            scoreValue = 120
        elseif n:find("throttle") then
            scoreValue = 75
        elseif n == "acceleratorinput" then
            scoreValue = 60
        end
        if n:find("max") or n:find("min") or n:find("limit") or n:find("target") then
            scoreValue = -1
        end
    elseif kind == "ignition" then
        if n == "bisengineon" or n == "engineon" or n == "bengineon" then
            scoreValue = 120
        elseif n:find("engine") and (n:find("running") or n:find("started")) then
            scoreValue = 65
        end
    end
    return scoreValue
end

local function discover(vehicle)
    local candidates = { rpm = {}, throttle = {}, ignition = {} }
    local diagnostic = {}
    local seen = {}
    local function scan(obj, prefix, depth)
        if not valid(obj) or seen[tostring(obj:GetAddress())] then return end
        seen[tostring(obj:GetAddress())] = true
        local names = field_names(obj)
        table.sort(names)
        for _, name in ipairs(names) do
            local path = prefix .. name
            local value = member(obj, name)
            if type(value) == "number" or type(value) == "boolean" then
                for _, kind in ipairs({"rpm", "throttle", "ignition"}) do
                    local rank = score(name, kind) - depth * 2
                    if rank > 0 then
                        if kind == "rpm" and type(value) == "number" and
                           (value < 0 or value > 25000) then rank = -1 end
                        if kind == "throttle" and type(value) == "number" and
                           (value < -1 or value > 100) then rank = -1 end
                        if kind == "ignition" and type(value) ~= "boolean" then rank = -1 end
                        if rank > 0 then
                            candidates[kind][#candidates[kind] + 1] = {
                                path = path, rank = rank, value = value
                            }
                            diagnostic[#diagnostic + 1] =
                                string.format("%s: %s = %s", kind, path, tostring(value))
                        end
                    end
                end
            elseif depth == 0 and type(value) == "userdata" and valid(value) then
                -- Only follow relevant UE components, avoiding expensive whole-object traversal.
                local lower = name:lower()
                if lower:find("engine") or lower:find("motor") or
                   lower:find("drive") or lower:find("movement") or
                   lower:find("vehicle") or lower:find("power") then
                    scan(value, path .. ".", 1)
                end
            end
        end
    end
    scan(vehicle, "", 0)
    local chosen = {}
    for _, kind in ipairs({"rpm", "throttle", "ignition"}) do
        table.sort(candidates[kind], function(a,b)
            if a.rank ~= b.rank then return a.rank > b.rank end
            return a.path < b.path
        end)
        chosen[kind] = candidates[kind][1] and candidates[kind][1].path or nil
    end
    chosen.rpm = RPM_PATH or chosen.rpm
    chosen.throttle = THROTTLE_PATH or chosen.throttle
    chosen.ignition = IGNITION_PATH or chosen.ignition
    log("Player vehicle: " .. tostring(vehicle:GetFullName()))
    log("Auto/override mapping: RPM=" .. tostring(chosen.rpm) ..
        " throttle=" .. tostring(chosen.throttle) ..
        " ignition=" .. tostring(chosen.ignition))
    for _, entry in ipairs(diagnostic) do log("Candidate " .. entry) end
    return chosen
end

local function write_telemetry(rpm, throttle, running)
    local data = string.format("MTES1 %.3f %.4f %d %d\n",
        rpm, throttle, running and 1 or 0, os.time())
    if data == lastValue then return end
    local file = io.open(TELEMETRY, "w")
    if not file then return end
    file:write(data)
    file:close()
    lastValue = data
end

local function tick()
    local pc = nil
    local success, result = pcall(function()
        local helpers = require("UEHelpers")
        return helpers.GetPlayerController()
    end)
    if success and valid(result) then pc = result end
    if not pc then pc = FindFirstOf("MotorTownPlayerController") end
    if not valid(pc) then
        write_telemetry(0, 0, false)
        lastVehicle, mapping = nil, nil
        return
    end
    local ok, vehicle = pcall(function() return pc:K2_GetPawn() end)
    if not ok or not valid(vehicle) then
        write_telemetry(0, 0, false)
        lastVehicle, mapping = nil, nil
        return
    end
    local isVehicle = pcall(function()
        if not vehicle:IsA("/Script/MotorTown.MTVehicle") then error("Not vehicle") end
    end)
    if not isVehicle then
        write_telemetry(0, 0, false)
        lastVehicle, mapping = nil, nil
        return
    end
    local addr = vehicle:GetAddress()
    if addr ~= lastVehicle then
        lastVehicle = addr
        mapping = discover(vehicle)
    end
    if not mapping or not mapping.rpm then
        write_telemetry(0, 0, false)
        return
    end
    local rpm = tonumber(path_value(vehicle, mapping.rpm)) or 0
    if rpm ~= rpm or rpm < 0 or rpm > 25000 then rpm = 0 end
    local throttle = tonumber(path_value(vehicle, mapping.throttle)) or 0.3
    if throttle > 1 then throttle = throttle / 100 end
    throttle = math.max(0, math.min(1, throttle))
    local ignition = path_value(vehicle, mapping.ignition)
    -- If no usable ignition property, infer it from the live RPM.
    local running = (type(ignition) == "boolean") and ignition or rpm >= 100
    write_telemetry(rpm, throttle, running)
end

if type(LoopInGameThreadWithDelay) ~= "function" then
    log("Requires a recent UE4SS experimental build with game-thread timers")
else
    log("Exporter active. Telemetry: " .. TELEMETRY)
    LoopInGameThreadWithDelay(50, function()
        local ok, err = pcall(tick)
        if not ok then log("Sample failed: " .. tostring(err)) end
    end)
end
