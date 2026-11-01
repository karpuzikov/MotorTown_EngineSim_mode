-- Motor Town -> Engine Simulator (open-source version) telemetry exporter.
-- v0.2.16, single-player; UE4SS experimental with LoopInGameThreadWithDelay.
-- Changes only the verified local vehicle V8 engine cue's audio gain, and
-- only with a live native PCM mute lease. Never changes vehicle physics.

-- Optional: Set exact reflected paths after looking at the diagnostic log.
-- Examples of PATH SYNTAX only (not verified Motor Town field names):
--   RPM_PATH = "EngineComponent.CurrentRPM"
local RPM_PATH = nil
local THROTTLE_PATH = nil
local IGNITION_PATH = nil

local TEMP = os.getenv("TMP")
if not TEMP or TEMP == "" then TEMP = os.getenv("TEMP") end
if not TEMP then
    print("[MotorTownEngineSim] No TEMP directory. Export disabled.\n")
    return
end
local TELEMETRY = TEMP .. "\\MotorTownEngineSim_telemetry.txt"
local NATIVE_TELEMETRY = TEMP .. "\\MotorTownEngineSim_native_telemetry.txt"
local DEBUG_LOG = TEMP .. "\\MotorTownEngineSim_diagnostics.txt"
local DISCOVERY = TEMP .. "\\MotorTownEngineSim_discovery.txt"
local AUDIO_TARGETS = TEMP .. "\\MotorTownEngineSim_audio_targets.txt"
local MUTE_REQUEST = TEMP .. "\\MotorTownEngineSim_native_mute_request.txt"
local MUTE_ACK = TEMP .. "\\MotorTownEngineSim_native_mute_ack.txt"
local lastVehicle = nil
local mapping = nil
local lastValue = ""
local nextDiscovery = 0
local nextAudioProbe = 0
local hasRunningAudioSnapshot = false
local audioSnapshotVehicle = nil
local dumpInventory = true
local lastGear = nil
local nativeSequence = 0
local cachedUserSettings = nil
local nextSettingsProbe = 0
local lastReportedVolume = nil
-- A new token on Lua hot reload lets the persistent native DLL safely accept
-- a sequence restart without trusting decreasing counters in one session.
local nativeSession = string.format("%08X%08X",
    math.random(0, 0x7FFFFFFF), math.random(0, 0x7FFFFFFF))
local log, valid, member

-- This handshake is intentionally separate from telemetry. Only the native
-- synthesizer can request a lease; Lua validates the exact *local* vehicle,
-- engine asset and SoundCue on the Unreal game thread before acknowledging.
-- If the native module stops/crashes, four exporter ticks restore stock audio.
local leasedAudio = nil
local leaseToken = nil
local leaseSequence = 0
local leaseIdleTicks = 0
local lastAcceptedLeaseSequence = 0
local KNOWN_ENGINE_CUE =
    "SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine"

local function full_name(object)
    if not valid(object) then return nil end
    local ok, result = pcall(function() return object:GetFullName() end)
    if ok and type(result) == "string" then return result end
    return nil
end

local function hex_name(name)
    if type(name) ~= "string" or #name == 0 or #name > 512 then return nil end
    if name:find("[%c]") then return nil end
    return name:gsub(".", function(c) return string.format("%02X", c:byte()) end)
end

local function set_gain(channel, volume)
    if not valid(channel) then return false end
    local fn = member(channel, "SetVolumeMultiplier")
    if not fn then return false end
    local ok = pcall(fn, channel, volume)
    local actual = tonumber(member(channel, "VolumeMultiplier"))
    return ok and actual and math.abs(actual - volume) <= 0.001 or false
end

local function write_mute_ack(session, sequenceText, token, vehicleHex, assetHex)
    local ack = io.open(MUTE_ACK, "w")
    if not ack then return false end
    ack:write("MTESA1 ", session, " ", sequenceText, " ", token,
        " ", vehicleHex, " ", assetHex, "\n")
    ack:close()
    return true
end

local function restore_leased_engine()
    if leaseToken then
        -- Revoke playback permission BEFORE touching the original gain.
        -- Native audio may inspect the ACK concurrently with this tick.
        local ack = io.open(MUTE_ACK, "w")
        if ack then
            ack:write("MTESA0\n")
            ack:close()
        else
            log("WARNING: Could not invalidate native mute ACK")
        end
    end
    if leasedAudio then
        if valid(leasedAudio.channel) then
            if not set_gain(leasedAudio.channel, leasedAudio.gain) then
                log("WARNING: Could not restore original engine gain; retrying")
                return false
            end
        end
        leasedAudio = nil
        log("Restored stock V8 engine audio")
    end
    leaseToken = nil
    leaseSequence = 0
    leaseIdleTicks = 0
    return true
end

local function mute_lease_tick(vehicle)
    local f = io.open(MUTE_REQUEST, "r")
    local line = f and f:read("*l") or nil
    if f then f:close() end

    if not valid(vehicle) then
        restore_leased_engine()
        return
    end

    -- STOP belongs only to the session that produced our telemetry. A STOP
    -- from an older lease must not unmute a new active replacement.
    local stopSession, stopToken
    if line then
        stopSession, stopToken = line:match("^MTESM0 ([0-9A-F]+) ([0-9A-F]+)$")
    end
    if stopSession == nativeSession and stopToken == leaseToken then
        restore_leased_engine()
        return
    end

    local session, sequenceText, token, vehicleHex, assetHex
    if line then
        session, sequenceText, token, vehicleHex, assetHex = line:match(
            "^MTESM1 ([0-9A-F]+) (%d+) ([0-9A-F]+) ([0-9A-F]+) ([0-9A-F]+)$")
    end
    local sequence = tonumber(sequenceText)
    local engine = member(vehicle, "EngineComponent")
    local data = valid(engine) and member(engine, "EngineData") or nil
    local channel = valid(engine) and member(engine, "AudioComponent") or nil
    local cue = valid(channel) and member(channel, "Sound") or nil
    if leasedAudio and (leasedAudio.channel ~= channel or
        hex_name(full_name(vehicle)) ~= leasedAudio.vehicleHex or
        hex_name(full_name(data)) ~= leasedAudio.assetHex or
        full_name(cue) ~= KNOWN_ENGINE_CUE) then
        -- The verified owner/cue disappeared or changed. Revoke its ACK
        -- immediately, not after four watchdog ticks of overlapping audio.
        restore_leased_engine()
        return
    end
    local matching = session == nativeSession and sequence and sequence > 0 and
        hex_name(full_name(vehicle)) == vehicleHex and
        hex_name(full_name(data)) == assetHex and
        full_name(cue) == KNOWN_ENGINE_CUE and valid(channel)

    -- Remember the highest *accepted* sequence even after restoring stock.
    -- Otherwise a crashed DLL leaves MTESM1 on disk and its static request
    -- re-mutes the engine every fifth Lua tick forever.
    if matching and sequence > lastAcceptedLeaseSequence and
        (token ~= leaseToken or sequence > leaseSequence) then
        if leasedAudio and (leasedAudio.channel ~= channel or leaseToken ~= token) then
            if not restore_leased_engine() then return end
        end
        if not leasedAudio then
            local original = tonumber(member(channel, "VolumeMultiplier"))
            if not original or original < 0 or original > 4 then return end
            leasedAudio = { channel = channel, gain = original,
                vehicleHex = vehicleHex, assetHex = assetHex }
            log("Native PCM lease requested; muting verified V8 engine cue only")
        end
        if not set_gain(channel, 0.0) then
            restore_leased_engine()
            return
        end
        if not write_mute_ack(session, sequenceText, token, vehicleHex, assetHex) then
            restore_leased_engine()
            return
        end
        leaseToken, leaseSequence, leaseIdleTicks = token, sequence, 0
        lastAcceptedLeaseSequence = sequence
        return
    end

    if matching and token == leaseToken and sequence == leaseSequence and
        leasedAudio and leasedAudio.channel == channel then
        -- A duplicate is allowed to refresh an ACK lost to scheduling or
        -- file timing, but it does NOT reset the independent 4-tick
        -- watchdog. A stopped DLL can never hold the stock cue muted.
        leaseIdleTicks = leaseIdleTicks + 1
        if leaseIdleTicks >= 4 then restore_leased_engine(); return end
        if not set_gain(channel, 0.0) or
            not write_mute_ack(session, sequenceText, token, vehicleHex, assetHex) then
            restore_leased_engine()
        end
        return
    end

    -- Duplicate requests are not fresh heartbeats. No reliable wall-clock
    -- monotonic millisecond timer is needed on this UE4SS Lua game thread.
    leaseIdleTicks = leaseIdleTicks + 1
    if leaseIdleTicks >= 4 then restore_leased_engine() end
end

log = function(line)
    local f = io.open(DEBUG_LOG, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
        f:close()
    end
    print("[MotorTownEngineSim] " .. line .. "\n")
end

valid = function(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

member = function(obj, name)
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
        n:find("gear") or n:find("transmission") or n:find("sound") or
        n:find("audio") or n:find("exhaust") or
        n:find("movement") or n:find("vehicle") or n:find("power") or
        n:find("sim") or n:find("physics") or n:find("state") or n:find("data")
end

-- Engine data must be discovered before enormous generic actor/seat hierarchies
-- consume the reflection budget. Priority affects order only, not candidate scores.
local function member_priority(name)
    local n = name:lower()
    if n:find("engine") or n:find("motor") or n:find("vehiclesimulation") then return 0 end
    if n:find("gear") or n:find("transmission") then return 1 end
    if n:find("throttle") or n:find("ignition") then return 2 end
    if n:find("sound") or n:find("audio") or n:find("exhaust") then return 3 end
    if n:find("driver") or n:find("seat") or n:find("physicsvolume") then return 20 end
    if relevant(name) then return 8 end
    return 30
end

local function diagnostic_field(name)
    local n = name:lower()
    return n:find("rpm") or n:find("engine") or n:find("motor") or
        n:find("gear") or n:find("transmission") or n:find("cylinder") or
        n:find("displacement") or n:find("stroke") or n:find("firing") or
        n:find("exhaust") or n:find("sound") or n:find("audio") or
        n:find("volume") or n:find("boost") or n:find("turbo")
end

-- Explore the engine's actual configuration and the gearbox before diving into
-- large, unrelated vehicle sounds (horns, door effects, SoundCue internals).
-- Sorting *members* is insufficient: a breadth-first object queue can still
-- fill the budget before the EngineData branch is reached.
local function object_priority(prefix)
    local path = prefix:lower():gsub("%.$", "")
    if path == "enginecomponent" then return 0 end
    if path == "transmissioncomponent" or path == "transmission" or
       path == "netlc_transmissioncoldstate" then return 1 end
    if path == "netlc_enginehotstate" or path == "enginecomponent.netlc_enginehotstate" then return 2 end
    if path == "enginecomponent.enginedata" then return 3 end
    if path == "enginecomponent.enginedata.engineproperty" then return 4 end
    if path == "enginecomponent.enginesoundcomponent" then return 5 end
    if path == "enginecomponent.enginedata.enginesounddata" then return 6 end
    if path == "enginecomponent.enginedata.enginessound" then return 7 end
    if path:find("sound") or path:find("audio") then return 50 end
    if path:find("engine") or path:find("motor") then return 10 end
    if path:find("transmission") or path:find("gear") then return 11 end
    return 25
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
            -- UE4SS f885e8d2 consumes a returned false twice and loses the
            -- iterator callback. Return nil to continue; true only to stop.
            klass:ForEachProperty(function(prop)
                if not take() then return true end
                add(prop:GetFName():ToString(), false)
                if budget.remaining <= 0 then return true end
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
                                if budget.remaining <= 0 then return true end
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
                if budget.remaining <= 0 then return true end
            end)
            klass = klass:GetSuperStruct()
        end
    end)
    if not ok then diagnostic("Reflection failed: " .. tostring(err)) end
    table.sort(members, function(a,b)
        local ar, br = member_priority(a.name), member_priority(b.name)
        if ar ~= br then return ar < br end
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
        if n == "bignitionon" or n == "ignitionon" then
            scoreValue = 150
        elseif n == "bisengineon" or n == "engineon" or n == "bengineon" then
            scoreValue = 120
        elseif n:find("engine") and (n:find("running") or n:find("started")) then
            scoreValue = 65
        end
    elseif kind == "gear" then
        if n == "currentgear" or n == "actualgear" then scoreValue = 150
        elseif n == "gear" or n == "selectedgear" then scoreValue = 120
        elseif n:find("gear") and not (n:find("ratio") or n:find("count") or
            n:find("max") or n:find("min") or n:find("target")) then scoreValue = 70 end
    end
    return scoreValue
end

-- Explicit SDK-backed, read-only probe. The generic reflection budget can be
-- exhausted before the audio arrays are visited. Only inspect EngineComponent's
-- own engine/exhaust channels; never enumerate horns or other vehicle audio.
local function sdk_audio_targets(vehicle)
    local lines = {}
    local engine = path_value(vehicle, "EngineComponent")
    local owner = valid(engine) and member(engine, "EngineSoundComponent") or nil
    local function identity(obj)
        if not valid(obj) then return "unavailable" end
        local ok, name = pcall(function() return obj:GetFullName() end)
        if not ok or type(name) ~= "string" or name == "" then return "unavailable" end
        return name:sub(1, 220):gsub("[%c]", " ")
    end
    local function channel_line(prefix, channel)
        if not valid(channel) then return prefix .. ": unavailable" end
        local sound = identity(member(channel, "Sound"))
        local gain = member(channel, "VolumeMultiplier")
        if type(gain) ~= "number" or gain ~= gain then gain = "unavailable" end
        return prefix .. ": " .. identity(channel) .. " Sound=" .. sound ..
            " VolumeMultiplier=" .. tostring(gain)
    end
    local function inspect_array(array, field)
        local ok, count = pcall(function() return array:GetArrayNum() end)
        if not ok or type(count) ~= "number" or count < 0 or count > 4096 then
            lines[#lines + 1] = field .. ": unavailable"
        else
            lines[#lines + 1] = field .. ": count=" .. tostring(count)
            local observed = 0
            local iterated = pcall(function()
                array:ForEach(function(index, element)
                    if observed >= 16 then return true end
                    observed = observed + 1
                    local got, channel = pcall(function() return element:get() end)
                    if not got or not valid(channel) then
                        lines[#lines + 1] = field .. "[" .. tostring(index) .. "]: unavailable"
                    else
                        lines[#lines + 1] = channel_line(field .. "[" .. tostring(index) .. "]", channel)
                    end
                end)
            end)
            if not iterated then lines[#lines + 1] = field .. ": iteration unavailable" end
            if count > 16 then lines[#lines + 1] = field .. ": truncated to 16" end
        end
    end
    if valid(owner) then
        for _, field in ipairs({"EngineAudioComponents", "ExhaustAudioComponents"}) do
            inspect_array(member(owner, field), field)
        end
    else
        lines[#lines + 1] = "EngineSoundComponent: unavailable"
    end
    for _, field in ipairs({"AudioComponent", "IntakeAudioComponent", "JakeBrakeAudioComponent"}) do
        lines[#lines + 1] = channel_line("EngineComponent." .. field,
            valid(engine) and member(engine, field) or nil)
    end
    inspect_array(valid(engine) and member(engine, "AfterfireAudioComponents") or nil,
        "EngineComponent.AfterfireAudioComponents")
    return lines
end

local function write_audio_targets(vehicle)
    if not valid(vehicle) then return end
    local rpm = path_value(vehicle, "EngineComponent.GetRPM()")
    local ignition = path_value(vehicle, "EngineComponent.IsIgnitionOn()")
    -- Other engine implementations may expose the equivalent pure getters.
    if type(rpm) ~= "number" then rpm = path_value(vehicle, "EngineComponent.GetEngineRPM()") end
    if type(ignition) ~= "boolean" then
        ignition = path_value(vehicle, "EngineComponent.IsEngineRunning()")
    end
    local running = ignition == true and type(rpm) == "number" and
        rpm > 0 and rpm <= 25000 and rpm == rpm
    -- Game exit/engine shutdown can otherwise erase the only usable snapshot.
    if hasRunningAudioSnapshot and not running then return end
    local ok, name = pcall(function() return vehicle:GetFullName() end)
    if not ok or type(name) ~= "string" then name = "unavailable" end
    local report = io.open(AUDIO_TARGETS, "w")
    if report then
        report:write("Player vehicle: ", name:sub(1, 220), "\n",
            "Engine state: ignition=", tostring(ignition),
            " RPM=", tostring(rpm), "\n",
            "SDK engine audio targets:\n", table.concat(sdk_audio_targets(vehicle), "\n"), "\n")
        report:close()
        if running then hasRunningAudioSnapshot = true end
    end
end

local function discover(vehicle, detailed)
    local audioTargets = sdk_audio_targets(vehicle)
    local candidates = { rpm = {}, throttle = {}, ignition = {}, gear = {} }
    local seen, objectCount, memberCount, inventory = {}, 0, 0, {}
    local priorityInventory = {}
    local budget = { remaining = 2000 }
    local pending = {{ object = vehicle, prefix = "", depth = 0 }}
    local function diagnostic(line, priority)
        if #inventory < 300 then inventory[#inventory + 1] = line end
        if priority and #priorityInventory < 180 then
            priorityInventory[#priorityInventory + 1] = line
        end
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
            " type=" .. reflected_type(obj) .. " members=" .. #members,
            prefix:lower():find("transmission") or prefix:lower():find("gear") or
            prefix:lower():find("engine"))
        for _, entry in ipairs(members) do
            if memberCount >= 2000 then break end
            memberCount = memberCount + 1
            local name = entry.name
            local signal = entry.getter and name:gsub("^Get", ""):gsub("^Is", ""):gsub("^Has", "") or name
            local path = prefix .. name .. (entry.getter and "()" or "")
            -- Do not execute unrelated getters (UObject's GetWorld, etc.).
            local wanted = relevant(name) or score(signal, "rpm") > 0 or
                score(signal, "throttle") > 0 or score(signal, "ignition") > 0 or
                score(signal, "gear") > 0
            local value = nil
            if not entry.getter or wanted then value = path_value(obj, name .. (entry.getter and "()" or ""), diagnostic) end
            local description = type(value)
            if description == "number" or description == "boolean" then description = tostring(value)
            elseif value ~= nil then
                description = reflected_type(value)
                if diagnostic_field(name) and valid(value) then
                    local identityOk, identity = pcall(function() return value:GetFullName() end)
                    if identityOk and type(identity) == "string" and identity ~= "" then
                        description = description .. " [" .. identity:sub(1, 220) .. "]"
                    end
                end
            end
            if entry.getter and not wanted then description = "unrelated getter (not queried)" end
            diagnostic("Member " .. path .. " = " .. description, diagnostic_field(name))
            if type(value) == "number" or type(value) == "boolean" then
                for _, kind in ipairs({"rpm", "throttle", "ignition", "gear"}) do
                    local confidence = score(signal, kind)
                    local rank = confidence - depth * 2
                    -- The driver's Throttle can be zero under autopilot.
                    -- EngineComponent's live throttle is the sound input.
                    if kind == "throttle" and path:match("^EngineComponent%.") then
                        rank = rank + 15
                    end
                    if rank > 0 then
                        if kind == "rpm" and (type(value) ~= "number" or
                           value ~= value or value < 0 or value > 25000) then rank = -1 end
                        if kind == "throttle" and (type(value) ~= "number" or
                           value ~= value or value < 0 or value > 100) then rank = -1 end
                        if kind == "ignition" and type(value) ~= "boolean" then rank = -1 end
                        if kind == "gear" and (type(value) ~= "number" or
                           value % 1 ~= 0 or value < -2 or value > 32) then rank = -1 end
                        if rank > 0 then
                            candidates[kind][#candidates[kind] + 1] = {
                                path = path, rank = rank, value = value, confidence = confidence
                            }
                            diagnostic(string.format("Candidate %s: %s = %s", kind, path, tostring(value)), true)
                        end
                    end
                end
            elseif depth < 3 and value ~= nil and relevant(name) and
                name ~= "GetPhysicsVolume" and valid(value) then
                local classOk, isClass = pcall(function() return value:IsClass() end)
                if not (classOk and isClass) then
                    pending[#pending + 1] = {
                        object = value, prefix = path .. ".", depth = depth + 1
                    }
                end
            end
        end
    end
    -- A bounded priority queue keeps engine data/gearbox ahead of sound assets.
    -- It preserves breadth-first order for objects of equal priority.
    local head = 1
    while pending[head] and objectCount < 32 and budget.remaining > 0 do
        local best = head
        for index = head + 1, #pending do
            if object_priority(pending[index].prefix) < object_priority(pending[best].prefix) then
                best = index
            end
        end
        pending[head], pending[best] = pending[best], pending[head]
        local nextObject = pending[head]
        scan(nextObject.object, nextObject.prefix, nextObject.depth)
        head = head + 1
    end
    if budget.remaining <= 0 then
        diagnostic("Reflection metadata budget exhausted; some branches were not examined", true)
    end
    local chosen = {}
    for _, kind in ipairs({"rpm", "throttle", "ignition", "gear"}) do
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
    -- EngineComponent.GetThrottle() is a real engine signal even though its
    -- generic name scores below GetActualThrottle(). Don't rescan every second.
    local authoritativeThrottle = throttleCandidate and
        (throttleCandidate.path:match("^EngineComponent%.") or
         throttleCandidate.path:match("^VehicleSimulation%."))
    chosen.refresh = not THROTTLE_PATH and throttleCandidate and
        throttleCandidate.confidence < 140 and not authoritativeThrottle
    local vehicleLine = "Player vehicle: " .. tostring(vehicle:GetFullName())
    local mappingLine = "Auto/override mapping: RPM=" .. tostring(chosen.rpm) ..
        " throttle=" .. tostring(chosen.throttle) ..
        " ignition=" .. tostring(chosen.ignition) ..
        " gear=" .. tostring(chosen.gear)
    local totalsLine = "Discovery totals: objects=" .. objectCount .. " members=" .. memberCount ..
        " metadata=" .. (2000 - budget.remaining)
    -- Keep the latest bounded inventory separate from the growing history log.
    -- Refresh it on retries too, so late-loading components are captured.
    local snapshot = io.open(DISCOVERY, "w")
    if snapshot then
        snapshot:write("Exporter v0.2.16 ", os.date("%Y-%m-%d %H:%M:%S"), "\n",
            vehicleLine, "\n", mappingLine, "\n", totalsLine, "\n",
            "Priority engine/gear/audio fields:\n", table.concat(priorityInventory, "\n"), "\n",
            "SDK engine audio targets:\n", table.concat(audioTargets, "\n"), "\n",
            "First 300 inventory lines:\n",
            table.concat(inventory, "\n"), "\n")
        snapshot:close()
    end
    log(vehicleLine)
    if detailed and #inventory > 0 then log("Discovery inventory:\n" .. table.concat(inventory, "\n")) end
    log(mappingLine)
    log(totalsLine)
    if budget.remaining <= 0 then
        log("Reflection metadata budget exhausted; some branches were not examined")
    end
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

-- SDK: UMotorTownUserSettings.Values maps EMTUserSettingType ->
-- FMTUserSettingValue. Sound_EngineVolume = 28; ValueType::Float = 0.
-- Return no gain unless the *live* engine-volume entry is usable. Never
-- substitute master/effects volume or a class-default setting.
local function engine_volume()
    if not valid(cachedUserSettings) then
        cachedUserSettings = nil
        if os.time() < nextSettingsProbe then return nil end
        nextSettingsProbe = os.time() + 1
        local ok, found = pcall(function() return FindFirstOf("MotorTownUserSettings") end)
        if not ok or not valid(found) then return nil end
        local named, identity = pcall(function() return found:GetFullName() end)
        if not named or type(identity) ~= "string" or
            identity:find("Default__", 1, true) then return nil end
        cachedUserSettings = found
    end
    local settingsMap = member(cachedUserSettings, "Values")
    local selected
    local ok = pcall(function()
        settingsMap:ForEach(function(key, value)
            if key:get() == 28 then
                local setting = value:get()
                if member(setting, "ValueType") == 0 then
                    selected = member(setting, "FloatValue")
                end
                return true
            end
        end)
    end)
    if not ok or type(selected) ~= "number" or selected ~= selected or
        selected < 0 or selected > 1 then return nil end
    return selected
end

-- Same-game-process native DLL feed. The companion's MTES1 packet is kept
-- unchanged. A missing gear is -99, never a guessed neutral (0).
-- MTES3 adds the full EngineData UObject name for exact per-engine matching.
-- MTES4 adds the read-only engine-volume setting. -1 means unknown.
local function write_native_telemetry(vehicle, rpm, throttle, running, gear)
    nativeSequence = nativeSequence + 1
    local name = ""
    if valid(vehicle) then
        local ok, value = pcall(function() return vehicle:GetFullName() end)
        if ok and type(value) == "string" then name = value end
    end
    local encoded = name:gsub(".", function(c) return string.format("%02X", c:byte()) end)
    if encoded == "" then encoded = "-" end
    local engineType, maxRpm = -1, 0
    local engineAsset = ""
    if valid(vehicle) then
        local kind = path_value(vehicle, "EngineComponent.EngineData.EngineProperty.EngineType")
        local limit = path_value(vehicle, "EngineComponent.EngineData.EngineProperty.MaxRPM")
        local data = path_value(vehicle, "EngineComponent.EngineData")
        if valid(data) then
            local ok, name = pcall(function() return data:GetFullName() end)
            if ok and type(name) == "string" and #name <= 512 and
               not name:find("[%c]") then engineAsset = name end
        end
        if type(kind) == "number" and kind % 1 == 0 and kind >= 0 and kind <= 1000 then
            engineType = kind
        end
        if type(limit) == "number" and limit > 0 and limit <= 25000 then maxRpm = limit end
    end
    local encodedAsset = engineAsset:gsub(".", function(c)
        return string.format("%02X", c:byte())
    end)
    if encodedAsset == "" then encodedAsset = "-" end
    local volume = engine_volume()
    local volumeField = volume and string.format("%.4f", volume) or "-1"
    -- Lua considers 0 truthy, preserving an intentional engine mute.
    if volumeField ~= lastReportedVolume then
        log("Engine Volume: " .. volumeField)
        lastReportedVolume = volumeField
    end
    local packet = string.format("MTES4 %s %d %.3f %.4f %d %d %s %d %.3f %s %s\n",
        nativeSession, nativeSequence, rpm, throttle, running and 1 or 0, gear or -99,
        encoded, engineType, maxRpm, encodedAsset, volumeField)
    local file = io.open(NATIVE_TELEMETRY, "w")
    if file then file:write(packet); file:close() end
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
        restore_leased_engine()
        write_telemetry(0, 0, false)
        write_native_telemetry(nil, 0, 0, false, nil)
        lastVehicle, mapping, lastGear = nil, nil, nil
        return
    end
    local ok, vehicle = pcall(function() return pc:K2_GetPawn() end)
    if not ok or not valid(vehicle) then
        restore_leased_engine()
        write_telemetry(0, 0, false)
        write_native_telemetry(nil, 0, 0, false, nil)
        lastVehicle, mapping, lastGear = nil, nil, nil
        return
    end
    local isVehicle = pcall(function()
        if not vehicle:IsA("/Script/MotorTown.MTVehicle") then error("Not vehicle") end
    end)
    if not isVehicle then
        restore_leased_engine()
        write_telemetry(0, 0, false)
        write_native_telemetry(nil, 0, 0, false, nil)
        lastVehicle, mapping, lastGear = nil, nil, nil
        return
    end
    mute_lease_tick(vehicle)
    local addr = vehicle:GetAddress()
    if addr ~= lastVehicle then
        lastVehicle = addr
        mapping, nextDiscovery, dumpInventory, lastGear = nil, 0, true, nil
        nextAudioProbe = 0
        -- Briefly leaving/re-entering the same car must not discard its live
        -- report. A different car must never inherit another one's snapshot.
        if addr ~= audioSnapshotVehicle then
            audioSnapshotVehicle = addr
            hasRunningAudioSnapshot = false
        end
    end
    -- Sound arrays can be populated after RPM/gear discovery has stabilized.
    -- Refresh these two exact fields without re-scanning thousands of properties.
    if os.time() >= nextAudioProbe then
        write_audio_targets(vehicle)
        nextAudioProbe = os.time() + 5
    end
    local retryMissingGear = mapping and mapping.rpm and mapping.throttle and not mapping.gear
    if (not mapping or not mapping.rpm or not mapping.throttle or
        mapping.refresh or retryMissingGear) and os.time() >= nextDiscovery then
        -- A late transmission can appear after the engine is already mapped.
        -- Once RPM/throttle are stable, cap expensive gear rediscovery to 5s.
        local interval = retryMissingGear and 5 or 1
        mapping = discover(vehicle, dumpInventory)
        nextDiscovery, dumpInventory = os.time() + interval, false
    end
    if not mapping or not mapping.rpm then
        write_telemetry(0, 0, false)
        write_native_telemetry(vehicle, 0, 0, false, nil)
        return
    end
    local gear = mapping.gear and tonumber(path_value(vehicle, mapping.gear)) or nil
    if gear and gear % 1 == 0 and gear >= -2 and gear <= 32 then
        if gear ~= lastGear then
            lastGear = gear
            log("Live gear: " .. tostring(gear))
        end
    else
        gear = nil
        mapping.gear = nil
    end
    local rpm = tonumber(path_value(vehicle, mapping.rpm))
    if not rpm or rpm ~= rpm or rpm < 0 or rpm > 25000 then
        mapping = nil
        write_telemetry(0, 0, false)
        write_native_telemetry(vehicle, 0, 0, false, nil)
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
    write_native_telemetry(vehicle, rpm, throttle, running, gear)
end

if type(LoopInGameThreadWithDelay) ~= "function" then
    log("Requires a recent UE4SS experimental build with game-thread timers")
else
    log("Exporter v0.2.16 active. Telemetry: " .. TELEMETRY)
    LoopInGameThreadWithDelay(50, function()
        local ok, err = pcall(tick)
        if not ok then
            restore_leased_engine()
            log("Sample failed: " .. tostring(err))
        end
    end)
end
