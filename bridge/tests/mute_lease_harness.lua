-- Exercised against the production main.lua with test-only local exports.
local prefix = assert(os.getenv("MTES_TEST_PREFIX"))
local request = prefix .. "\\MotorTownEngineSim_native_mute_request.txt"
local ack = prefix .. "\\MotorTownEngineSim_native_mute_ack.txt"

local function write(path, text)
    local file = assert(io.open(path, "w"))
    file:write(text)
    file:close()
end

local function read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*l")
    file:close()
    return text
end

local function hex(text)
    return text:gsub(".", function(c) return string.format("%02X", c:byte()) end)
end

local session = assert(__test_session)
local vehicleName = "MTVehicle DoryWrecker_C_123"
local assetName = "MHEngineDataAsset Ford302"
local cueName = "SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine"
local intakeCueName = "SoundCue /Game/Sounds/Vehicle/Intake/SC_Intake01.SC_Intake01"
local function object(name, fields)
    local o = fields or {}
    o.IsValid = function() return true end
    o.GetFullName = function() return name end
    return o
end

local intakeCue = object(intakeCueName)
local intake = object("AudioComponent Intake", {
    VolumeMultiplier = 0.75, Sound = intakeCue,
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
local cue = object(cueName)
local channel = object("AudioComponent Engine", {
    VolumeMultiplier = 0.63, Sound = cue,
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
-- UE4SS returns a NEW Lua value for every object-property read, so two reads
-- of the same component are different Lua values. The previous harness
-- returned one shared table, which hid the in-game failure: the lease compared
-- component wrappers with ~= and restored stock audio on every following
-- tick (UE4SS.log 2026-11-01: lease/restore alternating, mute-ACK=39).
-- Model each read as a fresh forwarding wrapper (plain tables: ~= is true).
local function fresh_wrapper(target)
    return setmetatable({}, {
        __index = function(_, key)
            local value = target[key]
            if type(value) == "function" then
                return function(_, ...) return target[key](target, ...) end
            end
            return value
        end,
        __newindex = function(_, key, value) target[key] = value end,
    })
end
channel.GetAddress = function() return 0x1000 end
intake.GetAddress = function() return 0x2000 end
local engineFields = object("EngineComponent", {
    AudioComponent = channel,
    IntakeAudioComponent = intake,
    EngineData = object(assetName),
})
local engine = setmetatable({}, {
    __index = function(_, key)
        local value = engineFields[key]
        if (key == "AudioComponent" or key == "IntakeAudioComponent") and value then
            return fresh_wrapper(value)
        end
        return value
    end,
    __newindex = function(_, key, value) engineFields[key] = value end,
})
local vehicle = object(vehicleName, { EngineComponent = engine })
local token = "A0B1C2"
local function lease(seq, key, car, asset)
    write(request, string.format("MTESM1 %s %d %s %s %s", session, seq,
        key or token, hex(car or vehicleName), hex(asset or assetName)))
end

lease(1)
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0,
    "The verified engine and intake must both be muted before acknowledgment")
local expected = string.format("MTESA1 %s 1 %s %s %s", session,
    token, hex(vehicleName), hex(assetName))
assert(read(ack) == expected, "ACK: " .. tostring(read(ack)) .. " expected " .. expected)

-- Native may read an ACK on another game thread. An old positive ACK must
-- be revoked BEFORE the stock channel's gain is restored, or both sources
-- can become audible in the handoff window.
local originalSetGain = channel.SetVolumeMultiplier
channel.SetVolumeMultiplier = function(self, gain)
    if gain == 0.63 then
        assert(read(ack) == "MTESA0", "Invalidate ACK before stock gain restore")
    end
    originalSetGain(self, gain)
end

-- If the native reader misses a response on a slow frame, the same live
-- request may be re-ACKed while its bounded watchdog is still running.
-- A duplicate cannot extend the watchdog indefinitely after a DLL crash.
write(ack, "MTESA0")
__test_mute(vehicle)
assert(read(ack) == expected, "A repeated live lease must refresh its ACK")
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)

-- The exporter must restore the captured 0.63, not assume a default 1.0.
for _ = 1, 3 do __test_mute(vehicle) end
assert(channel.VolumeMultiplier == 0.63)
assert(intake.VolumeMultiplier == 0.75, "Watchdog restores original intake gain")
assert(read(ack) == "MTESA0", "Restoration must invalidate a once-live ACK")
for _ = 1, 8 do __test_mute(vehicle) end
assert(channel.VolumeMultiplier == 0.63,
    "A crashed native writer's unchanged request must never re-mute the car")
assert(read(ack) == "MTESA0", "A stale request must not issue a new ACK")

lease(2, "DAD0", vehicleName .. "_OTHER")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63)
lease(3, "DAD0", vehicleName, "DifferentEngineAsset")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63)

lease(4, "DAD0")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0)
assert(intake.VolumeMultiplier == 0)
write(request, string.format("MTESM0 %s DAD0", session))
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75)

-- A failed Unreal mutation must not be acknowledged.
local oldAck = read(ack)
channel.SetVolumeMultiplier = function() error("UE property rejected") end
lease(5, "BB11")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63)
assert(read(ack) == oldAck)

-- Leaving the car always releases a successful lease immediately.
channel.SetVolumeMultiplier = function(self, volume) self.VolumeMultiplier = volume end
lease(6, "CC22")
intake.SetVolumeMultiplier = function() error("Intake rejected volume") end
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75,
    "A failed intake mute must restore the engine, too")
assert(read(ack) ~= string.format("MTESA1 %s 6 CC22 %s %s", session,
    hex(vehicleName), hex(assetName)), "Failed intake must not be acknowledged")
intake.SetVolumeMultiplier = function(self, volume) self.VolumeMultiplier = volume end
lease(7, "DD33")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)
intake.Sound = object("SoundCue /Game/Other.Other")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75,
    "A changed intake cue must revoke the shared mute lease")
assert(read(ack) == "MTESA0")
intake.Sound = intakeCue
lease(8, "EE33")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)
channel.Sound = object("SoundCue /Game/Other.Other")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75,
    "If the stock cue changes, restore immediately; prior ACK is no longer valid")
assert(read(ack) == "MTESA0")
channel.Sound = cue
lease(9, "FF44")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)
__test_mute(nil)
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75)

-- If ACK invalidation fails, stock must remain muted until it can be
-- revoked; otherwise a still-authorized native sink could overlay it.
lease(10, "AB55")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)
local realOpen = io.open
io.open = function(path, mode)
    if path == ack and mode == "w" then return nil end
    return realOpen(path, mode)
end
__test_mute(nil)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0,
    "An unwritable ACK must prevent both stock channels being restored")
io.open = realOpen
__test_mute(nil)
assert(read(ack) == "MTESA0")
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75)

-- Every car's own engine cue is leasable, not only the Dory's V8: a V6 car
-- with a different intake cue mutes both of its own components.
__test_mute(nil)
assert(read(ack) == "MTESA0")
local v6Cue = object("SoundCue /Game/Cars/Parts/Engine/Sound/V6Sport_02/SC_V6.SC_V6")
local v6Intake = object("SoundCue /Game/Sounds/Vehicle/Intake/SC_Intake03.SC_Intake03")
channel.Sound, intake.Sound = v6Cue, v6Intake
lease(11, "BC66")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0,
    "A non-V8 engine cue must be replaceable")
assert(read(ack) == string.format("MTESA1 %s 11 BC66 %s %s", session,
    hex(vehicleName), hex(assetName)))
-- Its cue swapping to another while leased still revokes at once.
intake.Sound = intakeCue
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63 and intake.VolumeMultiplier == 0.75,
    "A swapped intake cue must revoke the lease")
assert(read(ack) == "MTESA0")

-- A car without an intake component has no intake sound to leave audible:
-- its engine cue alone is leased.
engine.IntakeAudioComponent = nil
lease(12, "CD77")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0, "Engine-only cars must be replaceable")
assert(read(ack) == string.format("MTESA1 %s 12 CD77 %s %s", session,
    hex(vehicleName), hex(assetName)))
__test_mute(nil)
assert(channel.VolumeMultiplier == 0.63)

-- No engine cue on the engine component (in game: Kira Van, Brutus wrecker
-- stuck "waiting for Lua stock-mute ACK" in silence): still acknowledged.
channel.Sound = nil
lease(13, "DE88")
__test_mute(vehicle)
assert(read(ack) == string.format("MTESA1 %s 13 DE88 %s %s", session,
    hex(vehicleName), hex(assetName)), "A car without an engine cue must still play")
__test_mute(nil)
assert(channel.VolumeMultiplier == 0.63)

-- Engine sound layers on OTHER AudioComponents of the car (exhaust/engine
-- layers from the engine's sound data) must be leased too, or the stock
-- engine overlaps the replacement (in game 2026-11-02). Horn stays alone.
channel.Sound = cue
engine.IntakeAudioComponent = intake
local exhaust = object("AudioComponent ExhaustLayer", {
    VolumeMultiplier = 0.9,
    Sound = object("SoundCue /Game/Cars/Parts/Engine/Sound/V6Sport/V6Sport_02/SC_Exhaust.SC_Exhaust"),
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
exhaust.GetAddress = function() return 0x3000 end
local afterfire = object("AudioComponent Afterfire", {
    VolumeMultiplier = 0.5,
    Sound = object("SoundCue /Game/Cars/Parts/Engine/Sound/Afterfire/SC_Afterfire.SC_Afterfire"),
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
afterfire.GetAddress = function() return 0x4000 end
local horn = object("AudioComponent Horn", {
    VolumeMultiplier = 1.0, Sound = object("SoundWave /Game/Sounds/Vehicle/Horn.Horn"),
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
horn.GetAddress = function() return 0x5000 end
local electric = object("AudioComponent ElectricMotor", {
    VolumeMultiplier = 0.8,
    Sound = object("SoundCue /Game/Cars/Parts/Engine/Sound/Electric/SC_ElectricMotor.SC_ElectricMotor"),
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
electric.GetAddress = function() return 0x6000 end
StaticFindObject = function() return object("Class /Script/Engine.AudioComponent") end
vehicle.K2_GetComponentsByClass = function()
    return { channel, intake, exhaust, afterfire, horn, electric }
end
lease(20, "EF99")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)
assert(exhaust.VolumeMultiplier == 0, "Extra engine sound layer must be muted")
assert(afterfire.VolumeMultiplier == 0.5, "Afterfire pops stay stock")
assert(horn.VolumeMultiplier == 1.0, "Horn is never touched")
assert(electric.VolumeMultiplier == 0.8, "Electric motor sound stays stock")
__test_mute(nil)
assert(exhaust.VolumeMultiplier == 0.9, "Extra layer gain restored")
assert(channel.VolumeMultiplier == 0.63)

-- A gain the game refuses to take back must not block every later lease.
lease(21, "F0AA")
__test_mute(vehicle)
assert(exhaust.VolumeMultiplier == 0)
exhaust.SetVolumeMultiplier = function() error("component being destroyed") end
for _ = 1, 25 do __test_mute(nil) end
exhaust.SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end
lease(22, "F1BB")
__test_mute(vehicle)
assert(read(ack) == string.format("MTESA1 %s 22 F1BB %s %s", session,
    hex(vehicleName), hex(assetName)), "A stuck restore must give up eventually")

-- No stock engine sound from any car: the shared engine/intake assets are
-- silenced; electric motors, backfire, jake brake and unrelated sounds stay.
local counter = 0x9000
local function asset(name, field, value)
    counter = counter + 1
    local address = counter
    local o = object(name, { [field] = value })
    o.GetAddress = function() return address end
    return o
end
local v8 = asset("SoundCue /Game/Cars/Parts/Engine/Sound/V8/SC_V8Engine.SC_V8Engine", "VolumeMultiplier", 1.0)
local v6Wave = asset("SoundWave /Game/Cars/Parts/Engine/Sound/V6Sport/V6Sport_02/Exhaust_3000.Exhaust_3000", "Volume", 0.8)
local intakeWave = asset("SoundCue /Game/Sounds/Vehicle/Intake/SC_Intake01.SC_Intake01", "VolumeMultiplier", 0.7)
local electric = asset("SoundCue /Game/Cars/Parts/Engine/Sound/Electric/SC_ElectricMotor.SC_ElectricMotor", "VolumeMultiplier", 1.0)
local backfire = asset("SoundCue /Game/Cars/Parts/Engine/Sound/Backfire/SC_Backfire.SC_Backfire", "VolumeMultiplier", 1.0)
local jake = asset("SoundCue /Game/Sounds/Vehicle/Brake/JakeBrake/SC_JakeBrake_01.SC_JakeBrake_01", "VolumeMultiplier", 1.0)
local hornCue = asset("SoundCue /Game/Sounds/Vehicle/Horn/SC_Horn.SC_Horn", "VolumeMultiplier", 1.0)
local cdo = asset("SoundCue /Script/Engine.Default__SoundCue", "VolumeMultiplier", 1.0)
FindAllOf = function(class)
    if class == "SoundCue" then return { v8, intakeWave, electric, backfire, jake, hornCue, cdo } end
    if class == "SoundWave" then return { v6Wave } end
    return nil
end
__test_silence()
assert(v8.VolumeMultiplier == 0 and intakeWave.VolumeMultiplier == 0, "Stock engine/intake cues silenced")
assert(v6Wave.Volume == 0, "Stock engine sound-data waves silenced")
assert(electric.VolumeMultiplier == 1.0, "Electric motors keep their sound")
assert(backfire.VolumeMultiplier == 1.0 and jake.VolumeMultiplier == 1.0, "Pops and jake brake stay")
assert(hornCue.VolumeMultiplier == 1.0 and cdo.VolumeMultiplier == 1.0)

-- An electric vehicle's own sounds stay stock whatever they are called: the
-- sounds its audio components play are learned from the vehicle, together
-- with their folder. Here the assets have no "electric" in their path, and
-- were already muted before the first electric vehicle appeared.
local realTime = os.time
local clock = realTime() + 1000 -- past the scans the checks above started
os.time = function() return clock end
local truckCue = asset("SoundCue /Game/Cars/Parts/Engine/Sound/Truck/SC_Truck_05.SC_Truck_05", "VolumeMultiplier", 1.0)
local motorCue = asset("SoundCue /Game/Cars/Parts/Engine/Sound/Motor/SC_Whine.SC_Whine", "VolumeMultiplier", 1.0)
local motorWave = asset("SoundWave /Game/Cars/Parts/Engine/Sound/Motor/Whine_Loop.Whine_Loop", "Volume", 0.9)
local sharedRootCue = asset("SoundCue /Game/Sounds/Vehicle/Intake/SC_SharedWhine.SC_SharedWhine", "VolumeMultiplier", 0.6)
local electricVehicles = {}
FindAllOf = function(class)
    if class == "SoundCue" then return { truckCue, motorCue, sharedRootCue } end
    if class == "SoundWave" then return { motorWave } end
    if class == "MTVehicle" then return electricVehicles end
    return nil
end
__test_silence()
assert(motorCue.VolumeMultiplier == 0 and motorWave.Volume == 0 and truckCue.VolumeMultiplier == 0,
    "Before any electric vehicle is seen the shared engine assets are muted")
local electricComponent = object("AudioComponent Motor", { Sound = motorCue })
electricComponent.GetAddress = function() return 0xA001 end
local sharedRootComponent = object("AudioComponent Shared", { Sound = sharedRootCue })
sharedRootComponent.GetAddress = function() return 0xA002 end
local electricVehicle = object("MTVehicle EVan_C_1", {
    EngineComponent = object("EngineComponent", {
        EngineData = object("MHEngineDataAsset /Game/Cars/Parts/Engine/Electric_130HP.Electric_130HP") }),
})
electricVehicle.GetAddress = function() return 0xA000 end
electricVehicle.K2_GetComponentsByClass = function() return { electricComponent, sharedRootComponent } end
electricVehicles[1] = electricVehicle
clock = clock + 6
__test_silence()
assert(motorCue.VolumeMultiplier == 1.0, "The electric motor's cue gets its volume back")
assert(truckCue.VolumeMultiplier == 0, "A combustion cue stays silent")
clock = clock + 21
__test_silence()
assert(motorWave.Volume == 0.9, "Waves in the electric motor's folder get their volume back")
assert(sharedRootCue.VolumeMultiplier == 0.6, "A sound in the shared folder is kept by name")
assert(truckCue.VolumeMultiplier == 0 and v8.VolumeMultiplier == 0, "Combustion assets stay silent")
local laterMotorWave = asset("SoundWave /Game/Cars/Parts/Engine/Sound/Motor/Whine_Peak.Whine_Peak", "Volume", 1.0)
FindAllOf = function(class)
    if class == "SoundWave" then return { laterMotorWave } end
    if class == "MTVehicle" then return electricVehicles end
    return {}
end
clock = clock + 21
__test_silence()
assert(laterMotorWave.Volume == 1.0, "A wave found later in the electric motor's folder is never muted")
os.time = realTime

-- Distance makes engines quieter like in real life: -6 dB per doubling past
-- the 7.5 m their loudness is rated at, at most +8 dB at 3 m (in game the
-- stock attenuation kept a car 30 m away as loud as sitting in it).
channel.Sound = v8
local engineAt = 1500
channel.K2_GetComponentLocation = function() return { X = engineAt, Y = 0, Z = 0 } end
local camera = object("PlayerCameraManager Camera", {
    GetCameraLocation = function() return { X = 0, Y = 0, Z = 0 } end,
    GetCameraRotation = function() return { Yaw = 0 } end,
})
local pc = { PlayerCameraManager = camera }
local at15 = __test_mix(pc, vehicle)
engineAt = 3000
local at30 = __test_mix(pc, vehicle)
engineAt = 100
local inside = __test_mix(pc, vehicle)
assert(at15 and math.abs(at15 / at30 - 2) < 1e-6, "Spherical spreading: " .. tostring(at15) .. " " .. tostring(at30))
assert(math.abs(inside / at15 - 5) < 1e-6, "Capped at 3 m: " .. tostring(inside))

-- The chunk shares main.lua's 200-local limit: each part is scoped.
local trafficCar -- helper below
do
-- Traffic: the nearest running vehicles get the voices, standing ones too. The
-- game keeps no stock AudioComponent on traffic cars and its silenced sounds
-- say nothing about a car, so a car at a traffic light sounds like a passing
-- one; only an engine that is off, or too far away, stays out.
function trafficCar(name, address, x, state)
    local engineData = state.engineDataName and object(state.engineDataName) or nil
    local audio = not state.noAudioComponent and object("AudioComponent " .. name, {
        IsPlaying = function() return state.playing end,
        K2_GetComponentLocation = function() return { X = x, Y = 0, Z = 0 } end,
    }) or nil
    local engineComponent = object("EngineComponent", {
        AudioComponent = audio,
        EngineData = engineData,
        GetRPM = function() return state.rpm end,
        GetThrottle = function() return 0 end,
        IsIgnitionOn = function() return state.ignition ~= false end,
    })
    local car = object("MTVehicle " .. name, {
        EngineComponent = engineComponent,
        K2_GetActorLocation = function() return { X = state.x or x, Y = 0, Z = 0 } end,
        GetVelocity = function() return { X = state.speed or 0, Y = 0, Z = 0 } end,
    })
    car.GetAddress = function() return address end
    return car
end
local parkedBus = trafficCar("ParkedBus", 0xB001, 500, { rpm = 700, playing = false })
local idlingCar = trafficCar("IdlingCar", 0xB002, 800, { rpm = 700, playing = true })
local drivingCar = trafficCar("DrivingCar", 0xB003, 3000, { rpm = 2000, playing = false, speed = 1500 })
local fifthCar = trafficCar("FifthCar", 0xB008, 6000, { rpm = 900, playing = false })
local farCar = trafficCar("FarCar", 0xB004, 20000, { rpm = 1500, playing = true, speed = 1000 })
local stoppedCar = trafficCar("StoppedCar", 0xB005, 1000, { rpm = 800, playing = true, ignition = false })
FindAllOf = function(class)
    if class == "MTVehicle" then return { fifthCar, parkedBus, idlingCar, drivingCar, farCar, stoppedCar } end
    return nil
end
local chosen = __test_traffic_scan(pc, vehicle)
assert(#chosen == 4, "Four voices: " .. #chosen)
assert(chosen[1] == parkedBus and chosen[2] == idlingCar and chosen[3] == drivingCar and chosen[4] == fifthCar,
    "Standing cars, with or without a playing stock sound, and driving ones are listed nearest first")

end
do
-- Cars with no AudioComponent at all (the game has none on traffic) are
-- listed whether they stand or drive.
local parkedWithoutComponent = trafficCar("ParkedWithoutComponent", 0xB006, 400,
    { rpm = 700, noAudioComponent = true })
local passingWithoutComponent = trafficCar("PassingWithoutComponent", 0xB007, 2000,
    { rpm = 2000, noAudioComponent = true, speed = 1500 })
FindAllOf = function(class)
    if class == "MTVehicle" then return { parkedWithoutComponent, passingWithoutComponent } end
    return nil
end
local chosenWithoutComponents = __test_traffic_scan(pc, vehicle)
assert(#chosenWithoutComponents == 2 and chosenWithoutComponents[1] == parkedWithoutComponent and
    chosenWithoutComponents[2] == passingWithoutComponent,
    "Cars without a stock AudioComponent are listed, standing or passing: " .. #chosenWithoutComponents)

end
do
-- A car that has a voice keeps it unless another is clearly nearer: a new
-- voice costs a script compile and a second of silence. Five cars, four
-- voices; the fifth is a little nearer than the farthest voiced car.
local voicedFar = trafficCar("VoicedFar", 0xB101, 5000, { rpm = 900 })
local voicedA = trafficCar("VoicedA", 0xB102, 1000, { rpm = 900 })
local voicedB = trafficCar("VoicedB", 0xB103, 2000, { rpm = 900 })
local voicedC = trafficCar("VoicedC", 0xB104, 3000, { rpm = 900 })
local newcomer = trafficCar("Newcomer", 0xB105, 4500, { rpm = 900 })
local cars = { voicedFar, voicedA, voicedB, voicedC }
FindAllOf = function(class)
    if class == "MTVehicle" then return cars end
    return nil
end
__test_traffic_write(pc, vehicle) -- lists the four, so they hold voices
cars = { voicedFar, voicedA, voicedB, voicedC, newcomer }
local keptScan = __test_traffic_scan(pc, vehicle)
assert(#keptScan == 4 and keptScan[4] == voicedFar,
    "A slightly nearer newcomer does not take the voice of a car that has one")
local movedOn = trafficCar("MovedOn", 0xB105, 1200, { rpm = 900 })
cars = { voicedFar, voicedA, voicedB, voicedC, movedOn }
local replacedScan = __test_traffic_scan(pc, vehicle)
assert(#replacedScan == 4 and replacedScan[1] == voicedA and replacedScan[2] == movedOn and
    replacedScan[4] == voicedC, "A much nearer newcomer does take a voice from the farthest one")

end
do
-- What identifies a vehicle is found once, not by ~30 property reads on every
-- 50-ms tick of the game thread (it lagged the game with a few voices).
local identityReads = 0
local counted = trafficCar("Counted", 0xB201, 700, { rpm = 800 })
local data = object("MHEngineDataAsset /Game/Cars/Parts/Engine/I4_90HP.I4_90HP")
local dataName = data.GetFullName
data.GetFullName = function(self) identityReads = identityReads + 1; return dataName(self) end
counted.EngineComponent.EngineData = data
FindAllOf = function(class)
    if class == "MTVehicle" then return { counted } end
    return nil
end
local realNow = os.time
os.time = function() return realNow() + 100 end -- past the 2-s scan interval
__test_traffic_write(pc, vehicle)
local afterFirst = identityReads
for _ = 1, 20 do __test_traffic_write(pc, vehicle) end
os.time = realNow
assert(afterFirst >= 1 and identityReads == afterFirst,
    "Identity read once: " .. afterFirst .. " then " .. identityReads)
end
