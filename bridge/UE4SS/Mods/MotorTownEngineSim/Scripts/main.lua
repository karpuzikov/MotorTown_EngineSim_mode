-- Motor Town -> Engine Simulator (open-source version) telemetry exporter.
-- v0.2.9, single-player; UE4SS experimental with LoopInGameThreadWithDelay.
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
local DISCOVERY = TEMP .. "\\MotorTownEngineSim_discovery.txt"
local lastVehicle = nil
local mapping = nil
local lastValue = ""
local nextDiscovery = 0
local dumpInventory = true

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

local function path_value(root, path, diagnostic)
    if not path or not root then return nil end
    local current = root
    for name in path:gmatch("[^%.]+") do
        if current == nil then return nil end
        if name:sub(-2) == "()" then
            local context = current
            local fn = member(context, name:sub(1, -3))
            local ok, result = pcall(function() return fn(context) end)
            if not ok and diagnostic then diagnostic("Getter failed: " .. name .. ": " .. tostring(result)) end
            current = ok and result or nil
            -- Preserve a getter's boolean false (Lua's and/or idiom loses it).
            if ok and result == false then current = false end
        else
            current = member(current, name)
        end
    end
    return current
end

local function reflected_type(obj)
    local ok, result = pcall(function() return obj:type() end)
    return ok and result or type(obj)
end

local function relevant(name)
    local n = name:lower()
    if n:find("class") or n:find("config") or n:find("setting") or
       n:find("curve") or n:find("tuning") then return false end
    return n:find("engine") or n:find("motor") or n:find("drive") or
        n:find("movement") or n:find("vehicle") or n:find("power") or
        n:find("sim") or n:find("physics") or n:find("state") or n:find("data")
end

local function reflected_members(obj, diagnostic, budget)
    local members, seen = {}, {}
    local function take()
        if budget.remaining <= 0 then return false end
        budget.remaining = budget.remaining - 1
        return true
    end
    local function add(name, getter)
        if type(name) == "string" and not seen[name] then
            seen[name] = true
            members[#members + 1] = { name = name, getter = getter }
        end
    end
    local ok, err = pcall(function()
        -- UScriptStruct exposes its own UStruct methods. GetClass() gives the
        -- metaclass, which does not enumerate the value's data members.
        local klass = reflected_type(obj) == "UScriptStruct" and obj or obj:GetClass()
        for _ = 1, 12 do
            if not valid(klass) or budget.remaining <= 0 then break end
            klass:ForEachProperty(function(prop)
                if not take() then return true end
                add(prop:GetFName():ToString(), false)
                return budget.remaining <= 0
            end)
            if budget.remaining <= 0 then break end
            klass:ForEachFunction(function(fn)
                if not take() then return true end
                local name = fn:GetFName():ToString()
                if name:match("^Get") or name:match("^Is") or name:match("^Has") then
                    -- Invoke only reflected Const/BlueprintPure getters with
                    -- exactly a return property and no input/out parameters.
                    local flags = fn:GetFunctionFlags()
                    if (flags & 0x50000000) ~= 0 then
                        local returns, inputs = 0, 0
                        if budget.remaining > 0 then
                            fn:ForEachProperty(function(prop)
                                if not take() then return true end
                                if prop:GetFName():ToString() == "ReturnValue" then returns = returns + 1
                                else inputs = inputs + 1 end
                                return budget.remaining <= 0
                            end)
                        end
                        -- A truncated parameter list cannot establish that a
                        -- getter has no inputs. Never invoke it in that case.
                        if budget.remaining <= 0 then
                            diagnostic("Skipped getter " .. name .. ": metadata budget exhausted")
                        elseif returns == 1 and inputs == 0 then add(name, true)
                        elseif relevant(name) or name:lower():find("rpm") or name:lower():find("throttle") then
                            diagnostic("Skipped getter " .. name .. ": returns=" .. returns .. " inputs/out=" .. inputs)
                        end
                    elseif relevant(name) or name:lower():find("rpm") or name:lower():find("throttle") then
                        diagnostic("Skipped getter " .. name .. ": not reflected Const/BlueprintPure")
                    end
                end
                return budget.remaining <= 0
            end)
            klass = klass:GetSuperStruct()
        end
    end)
    if not ok then diagnostic("Reflection failed: " .. tostring(err)) end
    table.sort(members, function(a,b)
        local ar, br = not not relevant(a.name), not not relevant(b.name)
        if ar ~= br then return ar end
        return a.name < b.name
    end)
    return members
end

local function score(name, kind)
    local n = name:lower():gsub("[^a-z0-9]", "")
    local scoreValue = -1
    if kind == "rpm" then
        if n == "rpm" or n == "enginerpm" or n == "currentrpm" then
            scoreValue = 120
        elseif n:find("rpm", 1, true) then
            scoreValue = 90
        end
        if n:find("max") or n:find("min") or n:find("limit") or
           n:find("idle") or n:find("target") or n:find("redline") then
            scoreValue = -1
        end
    elseif kind == "throttle" then
        if n == "actualthrottle" or n == "enginethrottle" then
            scoreValue = 150
        elseif n == "currentthrottle" then
            scoreValue = 140
        elseif n == "throttle" then
            scoreValue = 120
        elseif n == "throttleinput" then
            scoreValue = 90
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

local function discover(vehicle, detailed)
    local candidates = { rpm = {}, throttle = {}, ignition = {} }
    local seen, objectCount, memberCount, inventory = {}, 0, 0, {}
    local budget = { remaining = 2000 }
    local function diagnostic(line)
        if #inventory < 300 then inventory[#inventory + 1] = line end
    end
    local function scan(obj, prefix, depth)
        if not valid(obj) or objectCount >= 32 or budget.remaining <= 0 then return end
        local isStruct = reflected_type(obj) == "UScriptStruct"
        local ok, address = pcall(function()
            local metadata = obj:GetAddress()
            if not metadata or metadata == 0 then return nil end
            if isStruct then
                local data = obj:GetStructAddress()
                if not data or data == 0 then return nil end
                -- A struct's first member may share its data address while
                -- having a different reflected layout.
                return "struct:" .. tostring(metadata) .. ":" .. tostring(data)
            end
            return "object:" .. tostring(metadata)
        end)
        if not ok or not address then return end
        local key = address
        if seen[key] then return end
        seen[key] = true
        objectCount = objectCount + 1
        local members = reflected_members(obj, diagnostic, budget)
        diagnostic("Scan " .. (prefix == "" and "vehicle" or prefix) ..
            " type=" .. reflected_type(obj) .. " members=" .. #members)
        for _, entry in ipairs(members) do
            if memberCount >= 2000 then break end
            memberCount = memberCount + 1
            local name = entry.name
            local signal = entry.getter and name:gsub("^Get", ""):gsub("^Is", ""):gsub("^Has", "") or name
            local path = prefix .. name .. (entry.getter and "()" or "")
            -- Do not execute unrelated getters (UObject's GetWorld, etc.).
            local wanted = relevant(name) or score(signal, "rpm") > 0 or
                score(signal, "throttle") > 0 or score(signal, "ignition") > 0
            local value = nil
            if not entry.getter or wanted then value = path_value(obj, name .. (entry.getter and "()" or ""), diagnostic) end
            local description = type(value)
            if description == "number" or description == "boolean" then description = tostring(value)
            elseif value ~= nil then description = reflected_type(value) end
            if entry.getter and not wanted then description = "unrelated getter (not queried)" end
            diagnostic("Member " .. path .. " = " .. description)
            if type(value) == "number" or type(value) == "boolean" then
                for _, kind in ipairs({"rpm", "throttle", "ignition"}) do
                    local confidence = score(signal, kind)
                    local rank = confidence - depth * 2
                    if rank > 0 then
                        if kind == "rpm" and (type(value) ~= "number" or
                           value ~= value or value < 0 or value > 25000) then rank = -1 end
                        if kind == "throttle" and (type(value) ~= "number" or
                           value ~= value or value < 0 or value > 100) then rank = -1 end
                        if kind == "ignition" and type(value) ~= "boolean" then rank = -1 end
                        if rank > 0 then
                            candidates[kind][#candidates[kind] + 1] = {
                                path = path, rank = rank, value = value, confidence = confidence
                            }
                            diagnostic(string.format("Candidate %s: %s = %s", kind, path, tostring(value)))
                        end
                    end
                end
            elseif depth < 3 and value ~= nil and relevant(name) and valid(value) then
                local classOk, isClass = pcall(function() return value:IsClass() end)
                if not (classOk and isClass) then
                    scan(value, path .. ".", depth + 1)
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
    local throttleCandidate = candidates.throttle[1]
    chosen.refresh = not THROTTLE_PATH and throttleCandidate and throttleCandidate.confidence < 140
    local vehicleLine = "Player vehicle: " .. tostring(vehicle:GetFullName())
    local mappingLine = "Auto/override mapping: RPM=" .. tostring(chosen.rpm) ..
        " throttle=" .. tostring(chosen.throttle) ..
        " ignition=" .. tostring(chosen.ignition)
    local totalsLine = "Discovery totals: objects=" .. objectCount .. " members=" .. memberCount ..
        " metadata=" .. (2000 - budget.remaining)
    -- Keep the latest bounded inventory separate from the growing history log.
    -- Refresh it on retries too, so late-loading components are captured.
    local snapshot = io.open(DISCOVERY, "w")
    if snapshot then
        snapshot:write("Exporter v0.2.9 ", os.date("%Y-%m-%d %H:%M:%S"), "\n",
            vehicleLine, "\n", mappingLine, "\n", totalsLine, "\n",
            table.concat(inventory, "\n"), "\n")
        snapshot:close()
    end
    log(vehicleLine)
    if detailed and #inventory > 0 then log("Discovery inventory:\n" .. table.concat(inventory, "\n")) end
    log(mappingLine)
    log(totalsLine)
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
        mapping, nextDiscovery, dumpInventory = nil, 0, true
    end
    if (not mapping or not mapping.rpm or not mapping.throttle or mapping.refresh) and os.time() >= nextDiscovery then
        mapping = discover(vehicle, dumpInventory)
        nextDiscovery, dumpInventory = os.time() + 1, false
    end
    if not mapping or not mapping.rpm then
        write_telemetry(0, 0, false)
        return
    end
    local rpm = tonumber(path_value(vehicle, mapping.rpm))
    if not rpm or rpm ~= rpm or rpm < 0 or rpm > 25000 then
        mapping = nil
        write_telemetry(0, 0, false)
        return
    end
    local throttle = tonumber(path_value(vehicle, mapping.throttle))
    if not throttle or throttle ~= throttle or throttle < 0 or throttle > 100 then
        mapping.throttle = nil
        throttle = 0
    end
    if throttle > 1 then throttle = throttle / 100 end
    throttle = math.max(0, math.min(1, throttle))
    local ignition = path_value(vehicle, mapping.ignition)
    -- If no usable ignition property, infer it from the live RPM.
    local running
    if type(ignition) == "boolean" then running = ignition else running = rpm >= 100 end
    write_telemetry(rpm, throttle, running)
end

if type(LoopInGameThreadWithDelay) ~= "function" then
    log("Requires a recent UE4SS experimental build with game-thread timers")
else
    log("Exporter v0.2.9 active. Telemetry: " .. TELEMETRY)
    LoopInGameThreadWithDelay(50, function()
        local ok, err = pcall(tick)
        if not ok then log("Sample failed: " .. tostring(err)) end
    end)
end
