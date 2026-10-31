-- Unreal boundary double; executes the actual exporter with real Lua/file I/O.
local exporter, scenario = arg[1], arg[2]
local native_open, native_time = io.open, os.time
io.open = function(path, mode) return native_open(path:gsub('\\', '/'), mode) end
local clock = 1790000000
os.time = function() return clock end
local next_address = 1
local state = { rpm = 2400, throttle = 0.65, running = true, unsafe_calls = 0 }

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
local function schema(properties, functions)
    local result = object({
        ForEachProperty = function(self, callback)
            for _, name in ipairs(properties or {}) do if callback(prop(name)) then break end end
        end,
        ForEachFunction = function(self, callback)
            for _, fn in ipairs(functions or {}) do if callback(fn) then break end end
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
            for _, input in ipairs(inputs or {}) do if visit(prop(input)) then return end end
            visit(prop('ReturnValue'))
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
    for _, name in ipairs({'CurrentRPM','ActualThrottle','bEngineOn'}) do visit(prop(name)) end
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
end
assert(state.unsafe_calls == 0, 'A getter with input parameters was called')
assert(reflected_count <= 2000, 'Metadata enumeration exceeded budget: ' .. reflected_count)
