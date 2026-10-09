-- Audit A19 (audio_bridge.dll, the real module): stop_all stops a one-shot that's already
-- playing, and the voice plays again afterwards. Silent (volume 0); skipped without an audio
-- device (CI) or off Windows.
local real_clock = os.clock
dofile("native/tests/testlib.lua")
if package.config:sub(1, 1) ~= "\\" then print("audio stop test skipped (Windows only)"); return end
local ok, audio = pcall(require, "audio_bridge")
assert(ok and type(audio) == "table", "audio_bridge builds and loads: " .. tostring(audio))
local ready, why = audio.init()
if not ready then print("audio stop test skipped: " .. tostring(why)); return end
-- Real time: the audio engine applies changes on its own thread, a few milliseconds later.
local function wait_for(cond, seconds)
    local stop = real_clock() + seconds
    while real_clock() < stop do if cond() then return true end end
    return cond()
end
-- Long enough for the engine to be well into a sound (it works in 10 ms passes): a sound
-- flushed before it starts is dropped either way, which isn't what's being tested.
local function under_way() wait_for(function() return false end, 0.2) end

-- "wall" loops for ever: played as a one-shot it only ends when stopped.
assert(audio.playing() == 0, "nothing playing at first")
assert(audio.play_ui("wall", 0.0), "a one-shot starts")
assert(audio.playing() == 1, "and holds its voice")
under_way()
assert(audio.playing() == 1, "still playing")
audio.stop_all()
assert(wait_for(function() return audio.playing() == 0 end, 1.0), "stop_all stops a sound already playing")
-- The voices still work: a one-second sound plays to its end on its own.
assert(audio.play_ui("wall_preview", 0.0), "a sound after stop_all")
assert(audio.playing() == 1, "holds a voice")
assert(wait_for(function() return audio.playing() == 0 end, 3.0), "and plays to its end, so the voice was started again")
-- Repeated mute and play, as scene changes do.
for _ = 1, 5 do
    audio.play_ui("wall", 0.0)
    audio.play("wall", 100, 0, 0, 0.0)
    under_way()
    audio.stop_all()
    assert(wait_for(function() return audio.playing() == 0 end, 1.0), "each round stops")
end
assert(audio.play_ui("tick", 0.0) and wait_for(function() return audio.playing() == 0 end, 1.0), "still playing afterwards")
print("audio stop test passed")
