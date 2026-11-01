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

-- No engine cue at all: nothing verified to replace.
channel.Sound = nil
lease(13, "DE88")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63, "A component without a cue is not leased")
assert(read(ack) == "MTESA0")

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
StaticFindObject = function() return object("Class /Script/Engine.AudioComponent") end
vehicle.K2_GetComponentsByClass = function()
    return { channel, intake, exhaust, afterfire, horn }
end
lease(20, "EF99")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0)
assert(exhaust.VolumeMultiplier == 0, "Extra engine sound layer must be muted")
assert(afterfire.VolumeMultiplier == 0.5, "Afterfire pops stay stock")
assert(horn.VolumeMultiplier == 1.0, "Horn is never touched")
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
