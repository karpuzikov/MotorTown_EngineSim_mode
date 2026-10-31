-- Unreal boundary double; executes the actual exporter with real Lua/file I/O.
local exporter, scenario = arg[1], arg[2]
if scenario == 'iterator_contract' then
    assert(type(UE4SS_ForEach) == 'function', 'Native iteration boundary required')
    local count = 0
    local ok, err = pcall(function()
        UE4SS_ForEach(function() count = count + 1; return false end, {1,2,3})
    end)
    assert(not ok and count == 1 and tostring(err):find('nil value'), 'False must reproduce the reported binding failure')
    count = 0
    UE4SS_ForEach(function() count = count + 1 end, {1,2,3})
    assert(count == 3, 'Nil must continue through every member')
    count = 0
    UE4SS_ForEach(function() count = count + 1; return true end, {1,2,3})
    assert(count == 1, 'True must stop iteration')
    return
end
local native_open, native_time = io.open, os.time
io.open = function(path, mode) return native_open(path:gsub('\\', '/'), mode) end
local clock = 1790000000
os.time = function() return clock end
local next_address = 1
local state = { rpm = 2400, throttle = 0.65, running = true, gear = 3, unsafe_calls = 0 }

local function object(fields, kind)
    local value = io.tmpfile()
    value:close() -- the closed userdata is only an Unreal boundary double
    next_address = next_address + 1
    local address = next_address
    fields.type = function() return kind or 'UObject' end
    fields.IsValid = function() return fields.ready ~= false end
    fields.GetAddress = function() return address end
    fields.GetStructAddress = function() return address end
    fields.GetFullName = fields.GetFullName or function() return 'DoryWrecker_C test object' end
    debug.setmetatable(value, {
        __index = fields,
        __newindex = function() error('Exporter must not write Unreal properties') end,
        __call = fields.call,
    })
    return value, fields
end

local function fname(name) return { ToString = function() return name end } end
local function prop(name) return { GetFName = function() return fname(name) end } end
local function each(values, callback)
    if UE4SS_ForEach then return UE4SS_ForEach(callback, values) end
    for _, value in ipairs(values) do if callback(value) then break end end
end
local function schema(properties, functions)
    local result = object({
        ForEachProperty = function(self, callback)
            local values = {}
            for _, name in ipairs(properties or {}) do values[#values + 1] = prop(name) end
            each(values, callback)
        end,
        ForEachFunction = function(self, callback)
            each(functions or {}, callback)
        end,
        GetSuperStruct = function() return nil end,
    }, 'UClass')
    return result
end
local function getter(name, callback, inputs)
    return object({
        GetFName = function() return fname(name) end,
        GetFunctionFlags = function() return 0x50000000 end, -- BlueprintPure + Const
        ForEachProperty = function(self, visit)
            local values = {}
            for _, input in ipairs(inputs or {}) do values[#values + 1] = prop(input) end
            values[#values + 1] = prop('ReturnValue')
            each(values, visit)
        end,
        call = callback,
    }, 'UFunction')
end

local rpm = getter('GetEngineRPM', function()
    if scenario == 'getter_error' then error('Synthetic RPM getter failure') end
    return state.rpm
end)
local throttle = getter('GetEngineThrottle', function() return state.throttle end)
local ignition = getter('IsEngineRunning', function() return state.running end)
local unsafe = getter('GetEngineRPMWithOffset', function() state.unsafe_calls = state.unsafe_calls + 1; return 9999 end, {'Offset'})
local engine, engine_fields = object({
    GetEngineRPM = rpm, GetEngineThrottle = throttle, IsEngineRunning = ignition,
    GetEngineRPMWithOffset = unsafe,
    ThrottleInput = 0, -- autopilot is driving; no keyboard input
    GetClass = function() return schema({'ThrottleInput'}, {rpm, throttle, ignition, unsafe}) end,
})
local struct_fields = { CurrentRPM = state.rpm, ActualThrottle = state.throttle, bEngineOn = true }
local struct, struct_members = object(struct_fields, 'UScriptStruct')
struct_members.ForEachProperty = function(self, visit)
    each({prop('CurrentRPM'),prop('ActualThrottle'),prop('bEngineOn')}, visit)
end
struct_members.ForEachFunction = function() end
struct_members.GetSuperStruct = function() return nil end
-- A struct's GetClass is its metaclass, not its reflected data layout.
struct_members.GetClass = function() return schema({}, {}) end
local component = object({ RuntimeState = struct, GetClass = function() return schema({'RuntimeState'}, {}) end })
local vehicle, vehicle_fields = object({
    VehicleSimulation = engine, ThrottleInput = 0,
    IsA = function(self, name) return name == '/Script/MotorTown.MTVehicle' end,
    GetClass = function() return schema({'VehicleSimulation','ThrottleInput'}, {}) end,
})
if scenario == 'deep_vehicle' then
    local junk = {}
    for i = 1, 2200 do junk[#junk + 1] = 'Junk' .. i end
    local seat = object({ GetClass = function() return schema(junk, {}) end })
    vehicle_fields.DriverSeat = seat
    vehicle_fields.EngineComponent = engine
    vehicle_fields.VehicleSimulation = nil
    vehicle_fields.GetClass = function() return schema({'DriverSeat','EngineComponent','ThrottleInput'}, {}) end
end
if scenario == 'gear_probe' then
    local transmission, transmission_fields = object({
        CurrentGear = state.gear,
        GetClass = function() return schema({'CurrentGear'}, {}) end,
    })
    vehicle_fields.Transmission = transmission
    vehicle_fields.GetClass = function() return schema({'VehicleSimulation','Transmission','ThrottleInput'}, {}) end
    state.transmission_fields = transmission_fields
end
if scenario == 'audio_inventory' then
    local props = {'VehicleSimulation','EngineSoundComponent'}
    for i = 1, 350 do props[#props + 1] = 'Aaa' .. i end
    vehicle_fields.EngineSoundComponent = object({
        VolumeMultiplier = 0.75,
        GetClass = function() return schema({'VolumeMultiplier'}, {}) end,
    })
    vehicle_fields.GetClass = function() return schema(props, {}) end
end
if scenario == 'deep_sound_and_gear' or scenario == 'engine_hot_state_off' then
    local rpmGetter = getter('GetRPM', function() return state.rpm end)
    local throttleGetter = getter('GetThrottle', function() return state.throttle end)
    local hotState, hotStateFields = object({ bIgnitionOn = state.running }, 'UScriptStruct')
    hotStateFields.ForEachProperty = function(self, visit) each({prop('bIgnitionOn')}, visit) end
    hotStateFields.ForEachFunction = function() end
    hotStateFields.GetSuperStruct = function() return nil end
    local engineProps = {'NetLC_EngineHotState'}
    local audioAsset = object({ GetClass = function()
        local huge = {}
        for i = 1, 2100 do huge[#huge + 1] = 'AssetField' .. i end
        return schema(huge, {})
    end })
    local engineData = object({ EnginesSound = audioAsset,
        GetClass = function() return schema({'EnginesSound'}, {}) end,
    })
    if scenario == 'deep_sound_and_gear' then engineProps[#engineProps + 1] = 'EngineData' end
    engine_fields.GetRPM = rpmGetter
    engine_fields.GetThrottle = throttleGetter
    engine_fields.NetLC_EngineHotState = hotState
    engine_fields.EngineData = engineData
    engine_fields.GetClass = function() return schema(engineProps, {rpmGetter, throttleGetter}) end
    local transmission = object({ CurrentGear = 3,
        GetClass = function() return schema({'CurrentGear'}, {}) end,
    })
    vehicle_fields.VehicleSimulation = nil
    vehicle_fields.EngineComponent = engine
    vehicle_fields.TransmissionComponent = transmission
    vehicle_fields.Throttle = 0 -- driver input can be zero under autopilot
    vehicle_fields.GetClass = function()
        return schema({'EngineComponent','TransmissionComponent','Throttle'}, {})
    end
    if scenario == 'deep_sound_and_gear' then state.throttle = 0.8 end
    if scenario == 'engine_hot_state_off' then
        state.running = false
        hotStateFields.bIgnitionOn = false
    end
end
if scenario == 'struct' then vehicle_fields.VehicleSimulation = component end
if scenario == 'struct_alias' then
    struct_members.GetStructAddress = function() return 4242 end
    local outer, outer_fields = object({ EngineState = struct }, 'UScriptStruct')
    outer_fields.GetStructAddress = function() return 4242 end
    outer_fields.ForEachProperty = function(self, visit) visit(prop('EngineState')) end
    outer_fields.ForEachFunction = function() end
    outer_fields.GetSuperStruct = function() return nil end
    vehicle_fields.VehicleSimulation = outer
end
if scenario == 'late_component' then engine_fields.ready = false end
if scenario == 'late_actual_throttle' then
    engine_fields.ready = false
    vehicle_fields.EngineRPM = state.rpm
    vehicle_fields.GetClass = function() return schema({'EngineRPM','VehicleSimulation','ThrottleInput'}, {}) end
end
if scenario == 'ignition_initially_off' then state.running = false end
local reflected_count = 0
if scenario == 'metadata_budget' then
    vehicle_fields.GetClass = function()
        return object({
            ForEachProperty = function(self, visit)
                for i = 1, 5000 do
                    reflected_count = reflected_count + 1
                    if visit(prop('Unused' .. i)) then break end
                end
            end,
            ForEachFunction = function() end,
            GetSuperStruct = function() return nil end,
        }, 'UClass')
    end
end
if scenario == 'truncated_getter' then
    local properties = {'VehicleSimulation'}
    for i = 1, 1997 do properties[#properties + 1] = 'Unused' .. i end
    vehicle_fields.GetClass = function() return schema(properties, {}) end
    local partial = getter('GetEngineRPM', function()
        state.unsafe_calls = state.unsafe_calls + 1
        return 9999
    end)
    -- A return-first signature must not hide its later input at the budget edge.
    getmetatable(partial).__index.ForEachProperty = function(self, visit)
        if visit(prop('ReturnValue')) then return end
        visit(prop('Offset'))
    end
    engine_fields.GetEngineRPM = partial
    engine_fields.GetClass = function() return schema({}, {partial}) end
end
if scenario == 'reflection_error' then
    vehicle_fields.GetClass = function() error('Synthetic reflection failure') end
end
local controller = object({ K2_GetPawn = function() return vehicle end })
package.preload['UEHelpers'] = function() return { GetPlayerController = function() return controller end } end
FindFirstOf = function() error('Must use the local player controller') end
local tick = nil
LoopInGameThreadWithDelay = function(delay, callback) assert(delay == 50); tick = callback end
dofile(exporter)
assert(tick, 'Exporter did not start its game-thread loop')
tick()
if scenario == 'late_component' or scenario == 'late_actual_throttle' then
    engine_fields.ready = true
    clock = clock + 2
    tick()
elseif scenario == 'autopilot' then
    state.rpm, state.throttle = 4100, 0.8
    clock = clock + 1
    tick()
elseif scenario == 'ignition_off' then
    state.running = false -- residual RPM must not override explicit ignition off
    clock = clock + 1
    tick()
elseif scenario == 'changed_throttle_getter' then
    local replacement = getter('GetActualThrottle', function() return 0.75 end)
    vehicle_fields.VehicleSimulation = object({
        GetEngineRPM = rpm, GetActualThrottle = replacement,
        IsEngineRunning = ignition,
        GetClass = function() return schema({}, {rpm, replacement, ignition}) end,
    })
    clock = clock + 2
    tick() -- old throttle getter is unavailable
    clock = clock + 1
    tick() -- discover the replacement getter
elseif scenario == 'gear_probe' then
    state.transmission_fields.CurrentGear = 4
    clock = clock + 1
    tick()
end
assert(state.unsafe_calls == 0, 'A getter with input parameters was called')
assert(reflected_count <= 2000, 'Metadata enumeration exceeded budget: ' .. reflected_count)
