-- Motor Town -> Engine Simulator telemetry exporter v0.3.0 (UE4SS, single player).
-- Reads the vehicle the local player is driving. Never writes game properties.
--
-- Field paths come from real AMTVehicle dumps published by MotorTownMods
-- (github.com/drpsyko101/MotorTownMods, docs/Webhooks.md and
-- docs/LuaHttpServer/VehicleManagement.md). The game replicates exactly these
-- values so other players hear each vehicle's engine:
--   NetLC_EngineHotState.CurrentRPM   float, engine RPM
--   NetLC_EngineHotState.bIgnitionOn  bool
--   Throttle                          float 0..1, vehicle control input
--
-- If a game update renames a field, set an exact path here. The discovery file
-- (%TEMP%\MotorTownEngineSim_discovery.txt) lists the vehicle's live fields.
local RPM_PATH = nil        -- e.g. "NetLC_EngineHotState.CurrentRPM"
local THROTTLE_PATH = nil   -- e.g. "Throttle"
local IGNITION_PATH = nil   -- e.g. "NetLC_EngineHotState.bIgnitionOn"

local VERSION = "0.3.0"
local DEFAULT_PATHS = {
    rpm = { "NetLC_EngineHotState.CurrentRPM" },
    throttle = { "Throttle" },
    ignition = { "NetLC_EngineHotState.bIgnitionOn" },
}
local OVERRIDES = { rpm = RPM_PATH, throttle = THROTTLE_PATH, ignition = IGNITION_PATH }
local SAMPLE_MS = 50                 -- 20 Hz
local STARTUP_DELAY_SECONDS = 30     -- Other Motor Town mods crashed the game when polling during boot.
local CONTROLLER_REFRESH_SECONDS = 2
local MAX_DUMP_LINES = 600

local TEMP = os.getenv("TMP") or os.getenv("TEMP")
if not TEMP then
    print("[MotorTownEngineSim] No TEMP directory. Export disabled.\n")
    return
end
local TELEMETRY = TEMP .. "\\MotorTownEngineSim_telemetry.txt"
local DEBUG_LOG = TEMP .. "\\MotorTownEngineSim_diagnostics.txt"
local DISCOVERY = TEMP .. "\\MotorTownEngineSim_discovery.txt"

local startAt = os.time() + STARTUP_DELAY_SECONDS
local lastPacket = ""
local lastStatus = nil
local lastMapping = nil
local controller, controllerCheckedAt = nil, -1
local vehicleClass = nil
local current = nil   -- { address, name, paths = {kind=path}, reported = bool }

local function log(line)
    local f = io.open(DEBUG_LOG, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S "), line, "\n")
        f:close()
    end
    print("[MotorTownEngineSim] " .. line .. "\n")
end

local function status(line)
    if line ~= lastStatus then
        lastStatus = line
        log(line)
    end
end

local function valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function get(obj, name)
    local ok, value = pcall(function() return obj[name] end)
    if ok then return value end
    return nil
end

local function read_path(root, path)
    local value = root
    for name in path:gmatch("[^%.]+") do
        if value == nil then return nil end
        value = get(value, name)
    end
    return value
end

local function name_of(obj)
    local ok, result = pcall(function() return obj:GetFullName() end)
    return ok and tostring(result) or "?"
end

local function address_of(obj)
    local ok, result = pcall(function() return obj:GetAddress() end)
    return ok and result or nil
end

-- Plain checks that each value has the meaning the simulator expects.
local ACCEPT = {
    rpm = function(v) return type(v) == "number" and v == v and v >= 0 and v <= 25000 end,
    throttle = function(v) return type(v) == "number" and v == v and v >= 0 and v <= 100 end,
    ignition = function(v) return type(v) == "boolean" end,
}

---------------------------------------------------------------------------
-- Player vehicle

local function find_vehicle_class()
    if valid(vehicleClass) then return vehicleClass end
    vehicleClass = nil
    local ok, cls = pcall(StaticFindObject, "/Script/MotorTown.MTVehicle")
    if ok and valid(cls) then vehicleClass = cls end
    return vehicleClass
end

local function is_vehicle(obj)
    if not valid(obj) then return false end
    local cls = find_vehicle_class()
    if not cls then return false end
    local ok, result = pcall(function() return obj:IsA(cls) end)
    return ok and result == true
end

local function local_controller()
    local now = os.time()
    if valid(controller) and now - controllerCheckedAt < CONTROLLER_REFRESH_SECONDS then
        return controller
    end
    controller, controllerCheckedAt = nil, now
    local ok, controllers = pcall(FindAllOf, "MotorTownPlayerController")
    if ok and type(controllers) == "table" then
        for _, pc in ipairs(controllers) do
            local isLocal = false
            pcall(function() isLocal = valid(pc) and pc:IsLocalController() == true end)
            if isLocal then controller = pc break end
        end
    end
    if not controller then
        local okHelper, pc = pcall(function() return require("UEHelpers").GetPlayerController() end)
        if okHelper and valid(pc) then controller = pc end
    end
    return controller
end

local function player_vehicle(pc)
    local pawn = get(pc, "Pawn")
    if is_vehicle(pawn) then return pawn end
    -- Sitting in a vehicle without possessing it: use the controller's last vehicle.
    if valid(pawn) and valid(get(pawn, "Net_Seat")) then
        local last = get(pc, "LastVehicle")
        if is_vehicle(last) then return last end
    end
    return nil
end

---------------------------------------------------------------------------
-- Fallback discovery and diagnostic dump.
-- UE4SS struct values (e.g. NetLC_EngineHotState) have no ForEachProperty;
-- their layout comes from the StructProperty's GetStruct(). Iterator callbacks
-- return nothing to continue: UE4SS mishandles a returned false.

local function each_property(struct, visit)
    local count = 0
    local level = struct
    while valid(level) and count < 12 do
        count = count + 1
        local levelName = ""
        pcall(function() levelName = level:GetFName():ToString() end)
        if levelName == "Actor" or levelName == "Object" then break end
        pcall(function()
            level:ForEachProperty(function(prop)
                local ok, stop = pcall(visit, prop)
                if ok and stop then return true end
            end)
        end)
        local okSuper, super = pcall(function() return level:GetSuperStruct() end)
        level = okSuper and super or nil
    end
end

local function property_info(prop)
    local name, kind = nil, nil
    pcall(function() name = prop:GetFName():ToString() end)
    pcall(function() kind = prop:GetClass():GetFName():ToString() end)
    return name, kind or "?"
end

local function normalized(name) return (name:lower():gsub("[^a-z0-9]", "")) end

local function score(kind, path)
    local leaf = normalized(path:match("([^%.]+)$") or path)
    local full = normalized(path)
    if kind == "rpm" then
        if full:find("max") or full:find("min") or full:find("idle") or full:find("limit") or
           full:find("redline") or full:find("target") or full:find("stall") then return -1 end
        if leaf == "currentrpm" or leaf == "enginerpm" or leaf == "rpm" then
            return full:find("engine") and 130 or 110
        end
        if leaf:find("rpm", 1, true) then return 80 end
    elseif kind == "throttle" then
        if full:find("pto") or full:find("max") or full:find("min") or full:find("limit") or
           full:find("target") then return -1 end
        if leaf == "throttle" then return path:find("%.") and 90 or 120 end
        if leaf:find("throttle", 1, true) then return 60 end
    elseif kind == "ignition" then
        if leaf == "bignitionon" or leaf == "ignitionon" then return 120 end
        if leaf == "bisengineon" or leaf == "bengineon" or leaf == "engineon" then return 100 end
    end
    return -1
end

local NUMERIC = { FloatProperty = true, DoubleProperty = true, IntProperty = true,
                  ByteProperty = true, BoolProperty = true, EnumProperty = true }

-- Lists numeric/bool fields of the vehicle and of its struct fields, and
-- ranks candidates for each signal. Bounded; reads values only.
local function discover(vehicle)
    local lines, best = {}, {}
    local function add(line) if #lines < MAX_DUMP_LINES then lines[#lines + 1] = line end end
    local function consider(path, value)
        for kind, accept in pairs(ACCEPT) do
            local rank = score(kind, path)
            if rank > 0 and accept(value) and (not best[kind] or rank > best[kind].rank) then
                best[kind] = { path = path, rank = rank }
            end
        end
    end
    local okClass, cls = pcall(function() return vehicle:GetClass() end)
    if not okClass or not valid(cls) then
        add("Vehicle class unavailable")
        return best, lines
    end
    each_property(cls, function(prop)
        local name, kind = property_info(prop)
        if not name then return end
        if NUMERIC[kind] then
            local value = get(vehicle, name)
            add(string.format("%s (%s) = %s", name, kind, tostring(value)))
            consider(name, value)
        elseif kind == "StructProperty" then
            local okStruct, layout = pcall(function() return prop:GetStruct() end)
            local value = get(vehicle, name)
            if okStruct and valid(layout) and value ~= nil then
                each_property(layout, function(member)
                    local memberName, memberKind = property_info(member)
                    if memberName and NUMERIC[memberKind] then
                        local memberValue = get(value, memberName)
                        local path = name .. "." .. memberName
                        add(string.format("%s (%s) = %s", path, memberKind, tostring(memberValue)))
                        consider(path, memberValue)
                    end
                end)
            end
        end
        if #lines >= MAX_DUMP_LINES then return true end
    end)
    return best, lines
end

local function write_discovery(vehicle, paths, values, lines)
    local f = io.open(DISCOVERY, "w")
    if not f then return end
    f:write("Exporter v", VERSION, " ", os.date("%Y-%m-%d %H:%M:%S"), "\n")
    f:write("Player vehicle: ", name_of(vehicle), "\n")
    for _, kind in ipairs({ "rpm", "throttle", "ignition" }) do
        f:write(string.format("Mapping %s = %s (value %s)\n", kind, tostring(paths[kind]),
            tostring(values[kind])))
    end
    if lines and #lines > 0 then
        f:write("Vehicle fields (numeric/bool, first ", MAX_DUMP_LINES, "):\n")
        f:write(table.concat(lines, "\n"), "\n")
    end
    f:close()
end

---------------------------------------------------------------------------
-- Mapping and sampling

local function resolve(vehicle)
    local paths, values, missing = {}, {}, false
    for kind, accept in pairs(ACCEPT) do
        local candidates = OVERRIDES[kind] and { OVERRIDES[kind] } or DEFAULT_PATHS[kind]
        for _, path in ipairs(candidates) do
            local value = read_path(vehicle, path)
            if accept(value) then
                paths[kind], values[kind] = path, value
                break
            end
        end
        if not paths[kind] and not OVERRIDES[kind] then missing = true end
    end
    local lines = nil
    if missing then
        local best
        best, lines = discover(vehicle)
        for kind in pairs(ACCEPT) do
            if not paths[kind] and not OVERRIDES[kind] and best[kind] then
                paths[kind] = best[kind].path
                values[kind] = read_path(vehicle, paths[kind])
            end
        end
    end
    write_discovery(vehicle, paths, values, lines)
    local mapping = string.format("Vehicle %s: RPM=%s throttle=%s ignition=%s", name_of(vehicle),
        tostring(paths.rpm), tostring(paths.throttle), tostring(paths.ignition))
    if mapping ~= lastMapping then
        lastMapping = mapping
        log(mapping)
    end
    return paths
end

local function write_packet(rpm, throttle, running)
    local packet = string.format("MTES1 %.3f %.4f %d %d\n", rpm, throttle, running and 1 or 0, os.time())
    if packet == lastPacket then return end
    local f = io.open(TELEMETRY, "w")
    if not f then return end
    f:write(packet)
    f:close()
    lastPacket = packet
end

local function idle(reason)
    current = nil
    status(reason)
    write_packet(0, 0, false)
end

local function sample()
    if os.time() < startAt then return end
    local pc = local_controller()
    if not valid(pc) then return idle("Waiting for the local player controller") end
    local vehicle = player_vehicle(pc)
    if not vehicle then return idle("Player is not driving a vehicle") end

    local address = address_of(vehicle)
    if not current or current.address ~= address then
        current = { address = address, paths = resolve(vehicle), retryAt = os.time() + 5 }
    end
    local paths = current.paths
    if not paths.rpm then
        -- Components can appear after the vehicle spawns; retry the mapping.
        if os.time() >= current.retryAt then current = nil end
        status("No RPM field found on this vehicle; see " .. DISCOVERY)
        write_packet(0, 0, false)
        return
    end

    local rpm = read_path(vehicle, paths.rpm)
    if not ACCEPT.rpm(rpm) then
        current = nil
        status("RPM read failed at " .. paths.rpm .. " (value " .. tostring(rpm) .. "); remapping")
        write_packet(0, 0, false)
        return
    end
    local throttle = nil
    if paths.throttle then throttle = read_path(vehicle, paths.throttle) end
    if not ACCEPT.throttle(throttle) then throttle = 0 end
    if throttle > 1 then throttle = throttle / 100 end
    throttle = math.max(0, math.min(1, throttle))
    -- Keep a boolean false: Lua's "a and b or c" idiom would turn it into nil.
    local ignition = nil
    if paths.ignition then ignition = read_path(vehicle, paths.ignition) end
    local running
    if type(ignition) == "boolean" then running = ignition else running = rpm >= 100 end

    status("Live: reading " .. paths.rpm)
    write_packet(rpm, throttle, running)
end

local function tick()
    local ok, err = pcall(sample)
    if not ok then status("Sample failed: " .. tostring(err)) end
end

log("Exporter v" .. VERSION .. " loaded. Telemetry: " .. TELEMETRY ..
    " (sampling starts in " .. STARTUP_DELAY_SECONDS .. " s)")
local scheduled = false
if type(LoopInGameThreadWithDelay) == "function" then
    scheduled = pcall(LoopInGameThreadWithDelay, SAMPLE_MS, tick)
    if not scheduled then log("LoopInGameThreadWithDelay unavailable; using LoopAsync") end
end
if not scheduled and type(LoopAsync) == "function" and type(ExecuteInGameThread) == "function" then
    local busy = false
    scheduled = pcall(LoopAsync, SAMPLE_MS, function()
        if not busy then
            busy = true
            ExecuteInGameThread(function()
                tick()
                busy = false
            end)
        end
        return false
    end)
end
if not scheduled then log("No UE4SS game-thread timer available. Export disabled.") end
