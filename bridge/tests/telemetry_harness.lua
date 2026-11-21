-- UE4SS/Motor Town boundary double. Runs the actual exporter with real Lua file I/O.
-- Modeled on UE4SS behavior (src/LuaType/LuaUStruct.cpp, LuaUScriptStruct.cpp):
--  * ForEachProperty exists on UStruct/UClass objects only. A struct VALUE read
--    from a property (e.g. vehicle.NetLC_EngineHotState) has no ForEachProperty;
--    unknown members of it read as nil.
--  * An iterator callback returning false loses the callback (reported failure).
--  * A StructProperty exposes its layout through GetStruct().
-- Field names follow published AMTVehicle dumps (MotorTownMods docs).
local exporter, scenario = arg[1], arg[2]

if scenario == 'iterator_contract' then
    assert(type(UE4SS_ForEach) == 'function', 'Native iteration boundary required')
    local count = 0
    local ok, err = pcall(function()
        UE4SS_ForEach(function() count = count + 1; return false end, {1, 2, 3})
    end)
    assert(not ok and count == 1 and tostring(err):find('nil value'), 'False must reproduce the reported binding failure')
    count = 0
    UE4SS_ForEach(function() count = count + 1 end, {1, 2, 3})
    assert(count == 3, 'Nil must continue through every member')
    count = 0
    UE4SS_ForEach(function() count = count + 1; return true end, {1, 2, 3})
    assert(count == 1, 'True must stop iteration')
    return
end

local native_open = io.open
io.open = function(path, mode) return native_open((path:gsub('\\', '/')), mode) end
local clock = 1790000000
os.time = function() return clock end

local writes, next_address = 0, 100

local function each(values, callback)
    if UE4SS_ForEach then return UE4SS_ForEach(callback, values) end
    for _, value in ipairs(values) do
        local result = callback(value)
        if result == true then break end
        if result == false then error('attempt to call a nil value (UE4SS iterator lost its callback)') end
    end
end

local function fname(name) return { ToString = function() return name end } end

-- UObject double: methods plus live reflected fields; writes are recorded.
local function uobject(methods, fields)
    next_address = next_address + 1
    local address = next_address
    methods.IsValid = methods.IsValid or function() return true end
    methods.GetAddress = function() return address end
    methods.GetFullName = methods.GetFullName or function() return 'Object test' end
    methods.type = function() return 'UObject' end
    return setmetatable({}, {
        __index = function(_, key)
            if methods[key] ~= nil then return methods[key] end
            if type(fields) == 'function' then return fields(key) end
            return fields and fields[key]
        end,
        __newindex = function() writes = writes + 1 end,
    })
end

-- Struct VALUE double (LuaUScriptStruct): no ForEachProperty, unknown keys are nil.
local function struct_value(fields)
    local methods = {
        IsValid = function() return true end,
        GetBaseAddress = function() return 1 end,
        GetStructAddress = function() return 2 end,
        IsMappedToObject = function() return true end,
        type = function() return 'UScriptStruct' end,
    }
    return setmetatable({}, {
        __index = function(_, key)
            if methods[key] ~= nil then return methods[key] end
            return fields[key]
        end,
        __newindex = function() writes = writes + 1 end,
    })
end

local function property(name, kind, layout)
    local p = {
        GetFName = function() return fname(name) end,
        GetClass = function() return { GetFName = function() return fname(kind) end } end,
    }
    if kind == 'StructProperty' then p.GetStruct = function() return layout end end
    return p
end

local function ustruct(name, props, super)
    return uobject({
        GetFName = function() return fname(name) end,
        ForEachProperty = function(_, callback) each(props, callback) end,
        GetSuperStruct = function() return super end,
    })
end

local actorClass = ustruct('Actor', { property('bHidden', 'BoolProperty') })
local pawnClass = ustruct('Pawn', { property('BaseEyeHeight', 'FloatProperty') }, actorClass)
local MTVehicle = ustruct('MTVehicle', {}, pawnClass)

-- Live game state the scenarios change between samples.
local state = { rpm = 2400, throttle = 0.65, ignition = true, starter = false }

local hotLayout = ustruct('MTVehicleEngineHotState', {
    property('bStarterOn', 'BoolProperty'), property('CurrentRPM', 'FloatProperty'),
    property('JakeBrake', 'ByteProperty'), property('bIgnitionOn', 'BoolProperty'),
    property('CoolantTemp', 'ByteProperty'), property('RegenBrake', 'ByteProperty'),
})

local function make_vehicle(name, renamed, rpmOffset)
    local props, fields = {}, {}
    rpmOffset = rpmOffset or 0
    local function hot()
        return struct_value(setmetatable({}, { __index = function(_, key)
            if key == 'CurrentRPM' then return state.rpm + rpmOffset end
            if key == 'bIgnitionOn' then return state.ignition end
            if key == 'bStarterOn' then return state.starter end
            if key == 'CoolantTemp' then return 80 end
            if key == 'JakeBrake' then return 0 end
            if key == 'RegenBrake' then return 1 end
        end }))
    end
    if renamed then
        local layout = ustruct('EngineStateRenamed', {
            property('MaxRPM', 'FloatProperty'), property('EngineRPM', 'FloatProperty'),
            property('bIgnitionOn', 'BoolProperty'),
        })
        props = {
            property('Net_PTOThrottle', 'FloatProperty'), property('Clutch', 'FloatProperty'),
            property('EngineState', 'StructProperty', layout), property('ThrottleInput', 'FloatProperty'),
            property('Wheels', 'ArrayProperty'),
        }
        fields = function(key)
            if key == 'Net_PTOThrottle' then return 0.2 end
            if key == 'Clutch' then return 0 end
            if key == 'ThrottleInput' then return state.throttle end
            if key == 'EngineState' then
                return struct_value(setmetatable({}, { __index = function(_, k)
                    if k == 'MaxRPM' then return 7000 end
                    if k == 'EngineRPM' then return state.rpm end
                    if k == 'bIgnitionOn' then return state.ignition end
                end }))
            end
        end
    else
        props = {
            property('Net_PTOThrottle', 'FloatProperty'), property('Clutch', 'FloatProperty'),
            property('NetLC_EngineHotState', 'StructProperty', hotLayout),
            property('Throttle', 'FloatProperty'), property('Brake', 'FloatProperty'),
        }
        fields = function(key)
            if key == 'Throttle' then return state.throttle end
            if key == 'NetLC_EngineHotState' then return hot() end
            if key == 'Net_PTOThrottle' then return 0.2 end
            if key == 'Clutch' or key == 'Brake' then return 0 end
        end
    end
    local cls = ustruct(name .. '_C', props, MTVehicle)
    return uobject({
        GetFullName = function() return name .. '_C /Game/Test.' .. name end,
        GetClass = function() return cls end,
        IsA = function(_, target) return target == MTVehicle end,
    }, fields)
end

local vehicle = make_vehicle('DoryWrecker', scenario == 'renamed_fields')
local otherVehicle = make_vehicle('Jemusi', false, 600)
local seat = uobject({})
local character = uobject({
    GetFullName = function() return 'MTCharacter_C test' end,
    IsA = function() return false end,
}, function(key) if key == 'Net_Seat' and scenario == 'seated' then return seat end end)

local pawn = (scenario == 'on_foot' or scenario == 'seated') and character or vehicle
local controller = uobject({
    IsLocalController = function() return true end,
}, function(key)
    if key == 'Pawn' then return pawn end
    if key == 'LastVehicle' then return vehicle end
end)

function StaticFindObject(path)
    if path == '/Script/MotorTown.MTVehicle' then return MTVehicle end
    return nil
end
function FindAllOf(className)
    if className == 'MotorTownPlayerController' then return { controller } end
    return nil
end

local loop, asyncLoop
function LoopInGameThreadWithDelay(ms, callback)
    if scenario == 'timer_fallback' then error('Neither EngineTick nor ProcessEvent hooks are available') end
    assert(ms <= 100, 'Telemetry must be sampled at 10 Hz or faster')
    loop = callback
    return 1
end
function LoopAsync(ms, callback) asyncLoop = callback return 2 end
function ExecuteInGameThread(callback) callback() end

dofile(exporter)

local function tick()
    if loop then loop() else assert(asyncLoop, 'Exporter scheduled no loop')() end
end

tick()
if scenario == 'startup_delay' then return end   -- Nothing may be sampled during boot.
clock = clock + 31
tick()

if scenario == 'autopilot' then
    -- AI drives the player's vehicle: control input and engine state come from the game.
    state.rpm, state.throttle = 4100, 0.8
    tick()
elseif scenario == 'ignition_off' then
    state.rpm, state.throttle, state.ignition = 0, 0, false
    tick()
elseif scenario == 'engine_stopping' then
    state.ignition = false   -- residual RPM while spinning down
    tick()
elseif scenario == 'rpm_follows' then
    for _, rpm in ipairs({ 900, 1800, 3100 }) do
        state.rpm = rpm
        clock = clock + 1
        tick()
    end
elseif scenario == 'vehicle_switch' then
    pawn = otherVehicle
    tick()
elseif scenario == 'leave_vehicle' then
    pawn = character
    tick()
end

assert(writes == 0, 'Exporter must never write game properties')
