-- Motor Town -> Engine Simulator (open-source version) telemetry exporter.
-- v0.2.20, single-player; UE4SS experimental with LoopInGameThreadWithDelay.
-- Changes only the local car's own engine/intake cue gains, and only with a
-- live native PCM mute lease. Never changes vehicle physics.

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
local ENGINE_CATALOG = TEMP .. "\\MotorTownEngineSim_engine_catalog.txt"
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

local function full_name(object)
    if not valid(object) then return nil end
    local ok, result = pcall(function() return object:GetFullName() end)
    if ok and type(result) == "string" then return result end
    return nil
end

-- Every car's own EngineComponent.AudioComponent / IntakeAudioComponent
-- carries its engine sound, whatever cue Motor Town picked (V8, V6, truck...).
-- The component identity proves it is engine sound; the cue name only
-- detects a swap while leased.
local function sound_name(component)
    if not valid(component) then return nil end
    return full_name(member(component, "Sound"))
end

local function hex_name(name)
    if type(name) ~= "string" or #name == 0 or #name > 512 then return nil end
    if name:find("[%c]") then return nil end
    return name:gsub(".", function(c) return string.format("%02X", c:byte()) end)
end

-- UE4SS hands Lua a new value on every object-property read; compare the
-- Unreal objects themselves, never the Lua wrappers.
local function address_of(object)
    if not valid(object) then return nil end
    local ok, result = pcall(function() return object:GetAddress() end)
    if ok and result and result ~= 0 then return result end
    return nil
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

-- Engine sound is not only EngineComponent.AudioComponent: depending on the
-- car's engine sound data, Motor Town plays further engine/exhaust/intake
-- layers on other AudioComponents of the same vehicle. All of them must be
-- leased, or stock engine sound overlaps the replacement. Jake brake and
-- afterfire pops stay stock: Engine Simulator does not synthesize them.
local audioComponentClass = nil
local function is_engine_sound(name)
    if type(name) ~= "string" then return false end
    local lower = name:lower()
    if lower:find("afterfire", 1, true) or lower:find("backfire", 1, true) or
        lower:find("jakebrake", 1, true) or lower:find("jake_brake", 1, true) then
        return false
    end
    return lower:find("/cars/parts/engine/", 1, true) ~= nil or
        lower:find("/vehicle/intake/", 1, true) ~= nil or
        lower:find("/vehicle/exhaust", 1, true) ~= nil or
        lower:find("/vehicle/engine", 1, true) ~= nil
end

local function vehicle_audio_components(vehicle)
    local found = {}
    pcall(function()
        if not audioComponentClass then
            audioComponentClass = StaticFindObject("/Script/Engine.AudioComponent")
        end
        if not valid(audioComponentClass) then audioComponentClass = nil; return end
        local list = vehicle:K2_GetComponentsByClass(audioComponentClass)
        local function add(component)
            if valid(component) and #found < 64 then found[#found + 1] = component end
        end
        if type(list) == "table" then
            for _, component in ipairs(list) do add(component) end
        else
            list:ForEach(function(_, element) add(element:get()) end)
        end
    end)
    return found
end

-- Extra engine-sound components besides the known engine/intake channels.
local function extra_engine_audio(vehicle, skip)
    local extras = {}
    for _, component in ipairs(vehicle_audio_components(vehicle)) do
        local address = address_of(component)
        if address and not skip[address] and is_engine_sound(sound_name(component)) then
            extras[#extras + 1] = { component = component, address = address,
                name = sound_name(component) }
        end
    end
    return extras
end

local loggedAudioVehicle = nil
local function log_vehicle_audio(vehicle)
    local address = address_of(vehicle)
    if not address or address == loggedAudioVehicle then return end
    loggedAudioVehicle = address
    for _, component in ipairs(vehicle_audio_components(vehicle)) do
        log("Vehicle audio: " .. tostring(full_name(component)) .. " sound=" ..
            tostring(sound_name(component)) .. " volume=" ..
            tostring(member(component, "VolumeMultiplier")) .. " engine=" ..
            tostring(is_engine_sound(sound_name(component))))
    end
end

local restoreFailures = 0
local mute_extra_engine_audio
local function restore_leased_engine(reason)
    if leaseToken then
        -- Revoke playback permission BEFORE touching the original gain.
        -- Native audio may inspect the ACK concurrently with this tick.
        local ack = io.open(MUTE_ACK, "w")
        if ack then
            ack:write("MTESA0\n")
            ack:close()
        else
            log("WARNING: Could not invalidate native mute ACK")
            return false
        end
    end
    if leasedAudio then
        local restored = true
        if valid(leasedAudio.channel) then
            if not set_gain(leasedAudio.channel, leasedAudio.gain) then
                restored = false
            end
        end
        if leasedAudio.intake and valid(leasedAudio.intake) then
            if not set_gain(leasedAudio.intake, leasedAudio.intakeGain) then
                restored = false
            end
        end
        for _, extra in ipairs(leasedAudio.extras or {}) do
            if valid(extra.component) and not set_gain(extra.component, extra.gain) then
                restored = false
            end
        end
        if not restored then
            -- The ACK is already revoked, so native audio is silent. A car
            -- the game itself is fading/rebuilding may refuse the old gain;
            -- never let that block every later lease (in game: 4 minutes).
            restoreFailures = restoreFailures + 1
            if restoreFailures < 20 then
                if restoreFailures == 1 then
                    log("WARNING: Could not restore original engine/intake gains; retrying (" ..
                        tostring(reason or "unknown") .. ")")
                end
                return false
            end
            log("WARNING: Gave up restoring stock gains after 20 attempts (" ..
                tostring(reason or "unknown") .. ")")
        end
        restoreFailures = 0
        leasedAudio = nil
        log("Restored stock engine/intake audio (" ..
            tostring(reason or "unknown") .. ")")
    end
    leaseToken = nil
    leaseSequence = 0
    leaseIdleTicks = 0
    return true
end

-- Mutes every engine-sound component of the leased car (re-scanned every
-- 20 ticks: the game can start layers late). Keeps each original gain.
local extraScanTick = 0
mute_extra_engine_audio = function(vehicle)
    if not leasedAudio or not leasedAudio.extras then return true end
    extraScanTick = extraScanTick + 1
    if not leasedAudio.scanned or extraScanTick % 20 == 0 then
        leasedAudio.scanned = true
        for _, extra in ipairs(extra_engine_audio(vehicle, leasedAudio.extraAddresses)) do
            local original = tonumber(member(extra.component, "VolumeMultiplier"))
            if original and original >= 0 and original <= 4 then
                extra.gain = original
                leasedAudio.extras[#leasedAudio.extras + 1] = extra
                leasedAudio.extraAddresses[extra.address] = true
                log("Also muting engine sound layer " .. tostring(extra.name))
            end
        end
    end
    for _, extra in ipairs(leasedAudio.extras) do
        if valid(extra.component) and not set_gain(extra.component, 0.0) then return false end
    end
    return true
end

local function mute_lease_tick(vehicle)
    local f = io.open(MUTE_REQUEST, "r")
    local line = f and f:read("*l") or nil
    if f then f:close() end

    if not valid(vehicle) then
        restore_leased_engine("vehicle unavailable")
        return
    end

    -- STOP belongs only to the session that produced our telemetry. A STOP
    -- from an older lease must not unmute a new active replacement.
    local stopSession, stopToken
    if line then
        stopSession, stopToken = line:match("^MTESM0 ([0-9A-F]+) ([0-9A-F]+)$")
    end
    if stopSession == nativeSession and stopToken == leaseToken then
        restore_leased_engine("native STOP request")
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
    local cueName = sound_name(channel)
    local intake = valid(engine) and member(engine, "IntakeAudioComponent") or nil
    if not valid(intake) then intake = nil end -- a car without intake sound
    local intakeCueName = sound_name(intake)
    local channelAddress, intakeAddress = address_of(channel), address_of(intake)
    if leasedAudio then
        local changed = nil
        if not channelAddress or channelAddress ~= leasedAudio.channelAddress then
            changed = "engine audio component"
        elseif intakeAddress ~= leasedAudio.intakeAddress then
            changed = "intake audio component"
        elseif intakeCueName ~= leasedAudio.intakeCueName then
            changed = "intake cue " .. tostring(intakeCueName)
        elseif hex_name(full_name(vehicle)) ~= leasedAudio.vehicleHex then
            changed = "vehicle"
        elseif hex_name(full_name(data)) ~= leasedAudio.assetHex then
            changed = "engine asset"
        elseif cueName ~= leasedAudio.cueName then
            changed = "engine cue " .. tostring(cueName)
        end
        if changed then
            -- The verified owner/cue disappeared or changed. Revoke its ACK
            -- immediately, not after four watchdog ticks of overlapping audio.
            restore_leased_engine("audio target or identity changed: " .. changed)
            return
        end
    end
    local matching = session == nativeSession and sequence and sequence > 0 and
        hex_name(full_name(vehicle)) == vehicleHex and
        hex_name(full_name(data)) == assetHex and
        cueName ~= nil and valid(channel)

    -- Remember the highest *accepted* sequence even after restoring stock.
    -- Otherwise a crashed DLL leaves MTESM1 on disk and its static request
    -- re-mutes the engine every fifth Lua tick forever.
    if matching and sequence > lastAcceptedLeaseSequence and
        (token ~= leaseToken or sequence > leaseSequence) then
        if leasedAudio and (leasedAudio.channelAddress ~= channelAddress or leaseToken ~= token) then
            if not restore_leased_engine("new lease token") then return end
        end
        if not leasedAudio then
            local original = tonumber(member(channel, "VolumeMultiplier"))
            if not original or original < 0 or original > 4 then return end
            local intakeOriginal = intake and tonumber(member(intake, "VolumeMultiplier"))
            if intake and (not intakeOriginal or intakeOriginal < 0 or
                intakeOriginal > 4) then return end
            leasedAudio = { channel = channel, gain = original,
                intake = intake, intakeGain = intakeOriginal,
                channelAddress = channelAddress, intakeAddress = intakeAddress,
                cueName = cueName, intakeCueName = intakeCueName,
                vehicleHex = vehicleHex, assetHex = assetHex }
            log_vehicle_audio(vehicle)
            log("Native PCM lease requested; muting engine cue " .. tostring(cueName) ..
                " and intake cue " .. tostring(intakeCueName))
        end
        if not set_gain(channel, 0.0) or
            (intake and not set_gain(intake, 0.0)) then
            restore_leased_engine("mute gain validation failed")
            return
        end
        if not leasedAudio.extras then
            leasedAudio.extras = {}
            leasedAudio.extraAddresses = { [channelAddress] = true }
            if intakeAddress then leasedAudio.extraAddresses[intakeAddress] = true end
        end
        if not mute_extra_engine_audio(vehicle) then
            restore_leased_engine("extra engine sound mute failed")
            return
        end
        if not write_mute_ack(session, sequenceText, token, vehicleHex, assetHex) then
            restore_leased_engine("ACK write failed")
            return
        end
        leaseToken, leaseSequence, leaseIdleTicks = token, sequence, 0
        lastAcceptedLeaseSequence = sequence
        return
    end

    if matching and token == leaseToken and sequence == leaseSequence and
        leasedAudio and leasedAudio.channelAddress == channelAddress then
        -- A duplicate is allowed to refresh an ACK lost to scheduling or
        -- file timing, but it does NOT reset the independent 4-tick
        -- watchdog. A stopped DLL can never hold the stock cue muted.
        leaseIdleTicks = leaseIdleTicks + 1
        if leaseIdleTicks >= 4 then
            restore_leased_engine("duplicate watchdog expired"); return
        end
        if not set_gain(channel, 0.0) or
            (intake and not set_gain(intake, 0.0)) or
            not mute_extra_engine_audio(vehicle) or
            not write_mute_ack(session, sequenceText, token, vehicleHex, assetHex) then
            restore_leased_engine("renewal gain or ACK failed")
        end
        return
    end

    -- Duplicate requests are not fresh heartbeats. No reliable wall-clock
    -- monotonic millisecond timer is needed on this UE4SS Lua game thread.
    leaseIdleTicks = leaseIdleTicks + 1
    if leaseIdleTicks >= 4 then restore_leased_engine("lease watchdog expired") end
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
        snapshot:write("Exporter v0.2.20 ", os.date("%Y-%m-%d %H:%M:%S"), "\n",
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

-- Master Volume, found by its EMTUserSettingType name (never by a guessed
-- number). Native XAudio2 output bypasses Unreal's mixer, so the game's
-- master slider must be applied explicitly. nil when not verifiable.
local masterVolumeKey = nil
local nextMasterKeyProbe = 0
local soundSettingNames = nil
local function setting_keys()
    if masterVolumeKey or os.time() < nextMasterKeyProbe then return masterVolumeKey end
    nextMasterKeyProbe = os.time() + 10
    local names = {}
    pcall(function()
        local enum = StaticFindObject("/Script/MotorTown.EMTUserSettingType")
        if not valid(enum) then return end
        enum:ForEachName(function(name, value)
            local text = type(name) == "string" and name or name:ToString()
            if text:find("Sound_", 1, true) then names[value] = text end
            if text:find("Sound_MasterVolume", 1, true) then masterVolumeKey = value end
        end)
    end)
    if next(names) then soundSettingNames = names end
    return masterVolumeKey
end

local function setting_value(key)
    if not key or not valid(cachedUserSettings) then return nil end
    local settingsMap = member(cachedUserSettings, "Values")
    local selected
    pcall(function()
        settingsMap:ForEach(function(entryKey, value)
            if entryKey:get() == key then
                local setting = value:get()
                if member(setting, "ValueType") == 0 then
                    selected = member(setting, "FloatValue")
                end
                return true
            end
        end)
    end)
    if type(selected) ~= "number" or selected ~= selected or
        selected < 0 or selected > 1 then return nil end
    return selected
end

local function vector_of(value)
    local x, y, z = tonumber(member(value, "X")), tonumber(member(value, "Y")),
        tonumber(member(value, "Z"))
    if not (x and y and z) or x ~= x or y ~= y or z ~= z then return nil end
    return x, y, z
end

-- FSoundAttenuationSettings Unreal uses for this component, in its own
-- priority order. nil: the stock sound is not attenuated at all.
local function attenuation_of(channel, cue)
    if member(channel, "bOverrideAttenuation") == true then
        return member(channel, "AttenuationOverrides")
    end
    local asset = member(channel, "AttenuationSettings")
    if valid(asset) then return member(asset, "Attenuation") end
    if valid(cue) then
        if member(cue, "bOverrideAttenuation") == true then
            return member(cue, "AttenuationOverrides")
        end
        asset = member(cue, "AttenuationSettings")
        if valid(asset) then return member(asset, "Attenuation") end
    end
    return nil
end

-- FBaseAttenuationSettings::AttenuationEval (UE 5.5), sphere extents.
local function distance_gain(settings, distance)
    if member(settings, "bAttenuate") == false then return 1 end
    local extents = member(settings, "AttenuationShapeExtents")
    local radius = extents and tonumber(member(extents, "X")) or 0
    local falloff = tonumber(member(settings, "FalloffDistance")) or 0
    local d = math.max(0, distance - math.max(0, radius))
    if falloff <= 0 then return d > 0 and 0 or 1 end
    local alpha = math.min(1, d / falloff)
    local algorithm = tonumber(member(settings, "DistanceAlgorithm")) or 0
    local result
    if algorithm == 1 then -- Logarithmic
        result = alpha <= 0 and 1 or 0.5 * -math.log(alpha)
    elseif algorithm == 2 then -- Inverse
        result = alpha <= 0 and 1 or 0.02 / alpha
    elseif algorithm == 3 then -- LogReverse
        result = alpha >= 1 and 0 or 1 + 0.5 * math.log(1 - alpha)
    elseif algorithm == 4 then -- NaturalSound
        local atMax = tonumber(member(settings, "dBAttenuationAtMax")) or -60
        result = 10 ^ (alpha * math.min(0, atMax) / 20)
    else -- Linear, or Custom curve approximated linearly
        result = 1 - alpha
    end
    return math.max(0, math.min(1, result))
end

local function lowpass_of(settings, distance)
    if member(settings, "bAttenuateWithLPF") ~= true then return 0 end
    local r0 = tonumber(member(settings, "LPFRadiusMin")) or 0
    local r1 = tonumber(member(settings, "LPFRadiusMax")) or 0
    local f0 = tonumber(member(settings, "LPFFrequencyAtMin")) or 20000
    local f1 = tonumber(member(settings, "LPFFrequencyAtMax")) or 20000
    local t = r1 > r0 and math.max(0, math.min(1, (distance - r0) / (r1 - r0))) or
        (distance >= r1 and 1 or 0)
    local hz = f0 + (f1 - f0) * t
    if hz ~= hz or hz <= 0 then return 0 end
    return math.max(10, math.min(30000, hz))
end

-- Where/how loud Unreal plays the car's stock engine cue for this camera:
-- stock volume multipliers x distance attenuation x master volume, pan from
-- the camera's right vector, distance low-pass. nil when unknown.
local function stock_mix(pc, vehicle)
    local engine = member(vehicle, "EngineComponent")
    local channel = valid(engine) and member(engine, "AudioComponent") or nil
    if not valid(channel) then return nil end
    local cue = member(channel, "Sound")
    local componentGain = leasedAudio and leasedAudio.channelAddress == address_of(channel)
        and leasedAudio.gain or tonumber(member(channel, "VolumeMultiplier"))
    if not componentGain or componentGain < 0 then return nil end
    local cueGain = valid(cue) and tonumber(member(cue, "VolumeMultiplier")) or 1
    local master = setting_value(setting_keys()) or 1
    local gain = componentGain * (cueGain or 1) * master
    local settings = attenuation_of(channel, cue)
    if not settings then return math.min(8, gain), 0, 0 end
    local okEmitter, emitter = pcall(function() return channel:K2_GetComponentLocation() end)
    local camera = member(pc, "PlayerCameraManager")
    if not okEmitter or not valid(camera) then return nil end
    local okLocation, listener = pcall(function() return camera:GetCameraLocation() end)
    local okRotation, rotation = pcall(function() return camera:GetCameraRotation() end)
    if not okLocation or not okRotation then return nil end
    local ex, ey, ez = vector_of(emitter)
    local lx, ly, lz = vector_of(listener)
    local yaw = tonumber(member(rotation, "Yaw"))
    if not (ex and lx and yaw) then return nil end
    local dx, dy, dz = ex - lx, ey - ly, ez - lz
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    gain = gain * distance_gain(settings, distance)
    local pan = 0
    if member(settings, "bSpatialize") ~= false and distance > 1 then
        local rad = math.rad(yaw)
        pan = (dx * -math.sin(rad) + dy * math.cos(rad)) / distance
        -- Unreal blends to unspatialized audio inside the non-spatialized radius.
        local inner = tonumber(member(settings, "NonSpatializedRadiusEnd")) or
            tonumber(member(settings, "OmniRadius")) or 0
        if inner > 0 and distance < inner then pan = pan * distance / inner end
        pan = math.max(-1, math.min(1, pan))
    end
    return math.min(8, gain), pan, lowpass_of(settings, distance)
end

-- One-time inventory of every Motor Town engine and the stock sound data the
-- game uses, so each can be given an exact Engine Simulator profile.
local catalogCount, nextCatalog = -1, 0
local function write_engine_catalog(vehicle)
    if os.time() < nextCatalog then return end
    nextCatalog = os.time() + 30
    local ok, assets = pcall(function() return FindAllOf("MHEngineDataAsset") end)
    if not ok or type(assets) ~= "table" or #assets == catalogCount then return end
    catalogCount = #assets
    local lines = { "# Motor Town engines seen by MotorTownEngineSim v0.2.20" }
    local engine = member(vehicle, "EngineComponent")
    local channel = valid(engine) and member(engine, "AudioComponent") or nil
    local intake = valid(engine) and member(engine, "IntakeAudioComponent") or nil
    lines[#lines + 1] = "current\t" .. tostring(full_name(vehicle)) .. "\t" ..
        tostring(full_name(valid(engine) and member(engine, "EngineData") or nil)) ..
        "\t" .. tostring(sound_name(channel)) .. "\t" .. tostring(sound_name(intake))
    setting_keys()
    for value, name in pairs(soundSettingNames or {}) do
        lines[#lines + 1] = "setting\t" .. name .. "\t" .. tostring(value) .. "\t" ..
            tostring(setting_value(value))
    end
    for i, asset in ipairs(assets) do
        if i > 400 then break end
        local name = full_name(asset)
        if name and not name:find("Default__", 1, true) then
            local property = member(asset, "EngineProperty")
            local fields = {}
            for _, field in ipairs({ "EngineType", "MaxRPM", "MaxTorque", "IdleRPM",
                "StarterRPM", "FuelType" }) do
                local v = property and member(property, field)
                if type(v) == "number" or type(v) == "boolean" then
                    fields[#fields + 1] = field .. "=" .. tostring(v)
                end
            end
            pcall(function()
                local count = 0
                asset:GetClass():ForEachProperty(function(prop)
                    count = count + 1
                    if count > 60 then return true end
                    local pname = prop:GetFName():ToString()
                    local v = member(asset, pname)
                    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                        fields[#fields + 1] = pname .. "=" .. tostring(v)
                    elseif valid(v) then
                        fields[#fields + 1] = pname .. "=" .. tostring(full_name(v))
                    end
                end)
            end)
            lines[#lines + 1] = "engine\t" .. name .. "\t" .. table.concat(fields, " ")
        end
    end
    local file = io.open(ENGINE_CATALOG, "w")
    if file then
        file:write(table.concat(lines, "\n"), "\n")
        file:close()
        log("Engine catalog: " .. tostring(#lines - 1) .. " lines -> " .. ENGINE_CATALOG)
    end
end

-- Same-game-process native DLL feed. The companion's MTES1 packet is kept
-- unchanged. A missing gear is -99, never a guessed neutral (0).
-- MTES3 adds the full EngineData UObject name for exact per-engine matching.
-- MTES4 adds the read-only engine-volume setting. -1 means unknown.
-- MTES5 adds the stock engine cue name and where/how loud Unreal would play
-- it (gain, pan, low-pass Hz); gain -1 means unknown.
local function write_native_telemetry(vehicle, rpm, throttle, running, gear, pc)
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
    local cueHex, mixField = "-", "-1 0.0000 0"
    if valid(vehicle) then
        local engine = member(vehicle, "EngineComponent")
        cueHex = hex_name(sound_name(valid(engine) and member(engine, "AudioComponent") or nil)) or "-"
        if pc then
            local ok, gain, pan, lowpass = pcall(stock_mix, pc, vehicle)
            if ok and gain then
                mixField = string.format("%.4f %.4f %.0f", gain, pan, lowpass)
            end
        end
    end
    local packet = string.format("MTES5 %s %d %.3f %.4f %d %d %s %d %.3f %s %s %s %s\n",
        nativeSession, nativeSequence, rpm, throttle, running and 1 or 0, gear or -99,
        encoded, engineType, maxRpm, encodedAsset, volumeField, cueHex, mixField)
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
    write_native_telemetry(vehicle, rpm, throttle, running, gear, pc)
    pcall(write_engine_catalog, vehicle)
end

if type(LoopInGameThreadWithDelay) ~= "function" then
    log("Requires a recent UE4SS experimental build with game-thread timers")
else
    log("Exporter v0.2.20 active. Telemetry: " .. TELEMETRY)
    LoopInGameThreadWithDelay(50, function()
        local ok, err = pcall(tick)
        if not ok then
            restore_leased_engine()
            log("Sample failed: " .. tostring(err))
        end
    end)
end
