-- Audio demo for audio_bridge, outside the game. The listener stands at the origin facing
-- forward (+X). Run: luahost.exe tests\audio_demo.lua from the build output folder.
package.cpath = package.cpath .. ";.\\?.dll"
local audio = require("audio_bridge")
print(audio.init())

local function sleep(s)
    local t = os.clock() + s
    while os.clock() < t do end
end
local say = function(s) print(s) end

audio.listener(0, 0, 0, 1, 0, 0)

local spots = {
    { "ahead",  400,    0 }, { "right",  0,  400 }, { "behind", -400, 0 }, { "left", 0, -400 },
}
for _, p in ipairs(spots) do
    say("ping " .. p[1])
    for _ = 1, 3 do audio.play("ping", p[2], p[3], 0); sleep(0.35) end
    sleep(0.6)
end

say("distance: a door knocking from 2 m out to 40 m, ahead-right")
for _, d in ipairs({ 200, 600, 1500, 4000 }) do
    audio.play("door", d * 0.7, d * 0.7, 0); sleep(0.7)
end
sleep(0.5)

say("a wall sound circling you once")
for i = 0, 72 do
    local a = i / 72 * 2 * math.pi
    audio.loop("wall", "wall", math.cos(a) * 200, math.sin(a) * 200, 0, 0.8)
    sleep(0.06)
end
audio.stop("wall")
sleep(0.4)

say("beacon getting closer: ticks speed up, then arrive")
for d = 3000, 200, -150 do
    audio.play("tick", d, 300, 0)
    sleep(0.1 + 0.75 * (d / 3000))
end
audio.play_ui("arrive"); sleep(0.6)

say("the other sounds: chime, person, item, enemy, warn, step_blocked")
for _, n in ipairs({ "chime", "person", "item", "enemy", "warn", "step_blocked" }) do
    audio.play(n, 300, 0, 0); sleep(0.6)
end
audio.stop_all()
say("done")
