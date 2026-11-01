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
local function object(name, fields)
    local o = fields or {}
    o.IsValid = function() return true end
    o.GetFullName = function() return name end
    return o
end

local intake = object("AudioComponent Intake", { VolumeMultiplier = 0.75 })
local cue = object(cueName)
local channel = object("AudioComponent Engine", {
    VolumeMultiplier = 0.63, Sound = cue,
    SetVolumeMultiplier = function(self, gain) self.VolumeMultiplier = gain end,
})
local engine = object("EngineComponent", {
    AudioComponent = channel,
    IntakeAudioComponent = intake,
    EngineData = object(assetName),
})
local vehicle = object(vehicleName, { EngineComponent = engine })
local token = "A0B1C2"
local function lease(seq, key, car, asset)
    write(request, string.format("MTESM1 %s %d %s %s %s", session, seq,
        key or token, hex(car or vehicleName), hex(asset or assetName)))
end

lease(1)
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0 and intake.VolumeMultiplier == 0.75)
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
assert(channel.VolumeMultiplier == 0)

-- The exporter must restore the captured 0.63, not assume a default 1.0.
for _ = 1, 3 do __test_mute(vehicle) end
assert(channel.VolumeMultiplier == 0.63)
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
write(request, string.format("MTESM0 %s DAD0", session))
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63)

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
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0)
channel.Sound = object("SoundCue /Game/Other.Other")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0.63,
    "If the stock cue changes, restore immediately; prior ACK is no longer valid")
assert(read(ack) == "MTESA0")
channel.Sound = cue
lease(7, "EE33")
__test_mute(vehicle)
assert(channel.VolumeMultiplier == 0)
__test_mute(nil)
assert(channel.VolumeMultiplier == 0.63)
