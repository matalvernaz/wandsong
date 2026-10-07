local t = dofile("native/tests/testlib.lua")
local events={}
RegisterCustomEvent=function(name,fn) events[name]=fn end
package.loaded.descriptions={{after="We must hurry, the carriage is waiting.",delay=0.2,text="Fig climbs into the carriage."},
    {id="Fig_7",after="Wait.",delay=0.2,text="Keyed description."},
    {id="Fig_20",after="Wait. We do not know what",items={{delay=2,text="A dragon swoops."},{delay=6,text="The carriage breaks apart."},{delay=12,text="You fall."}}},
    {id="Fig_30",after="Give me your hand!",items={{delay=1,text="Fig grabs your hand."}}},
    {id="PlayerFemale_500",after="What's that glow?",items={{delay=0.5,text="You point."}}},
    {after="Revelio.",prev="Revelio.",items={{delay=0.5,text="A white cat sits in a corridor."}}}}
local said={}
require("speech").say=function(s) said[#said+1]=s end
local keys=require("keys")
local skip_observer
local observe=keys.observe
keys.observe=function(fn) skip_observer=fn; observe(fn) end
local subs=require("subtitles")
local state=require("state")
local function line(text,dur,id)
    events.BPAddSubtitleEvent(nil,{get=function() return {
        lineID={ToString=function() return id or "L1" end},DurationSeconds=dur,
        VoiceName={ToString=function() return "Fig" end}}
    end},{get=function() return {ToString=function() return text end} end})
end
local text="We must hurry! The carriage is waiting."
line(text,0.5); line(text,0.5)
t.run(0.4); assert(#said==0,"waits for line end")
t.run(0.6); assert(#said==1,"duplicate hook delivery described only once")
t.run(0.3); line(text,0.5); t.run(1)
assert(#said==2,"replaying a line gets its description again")
line(text,5); t.run(0.2); line("Come on, then.",1,"L2"); t.run(6)
assert(#said==2,"new dialogue cancels obsolete description")
line(text,2); t.run(0.2); state.mark_loading(0.5); t.run(3)
assert(#said==2,"load cancels pending description")
line(text,0.5); t.run(0.2); state.set_cinematic(true); t.run(1)
assert(#said==3,"entering cutscene preserves opening description")
line(text,3); t.run(0.2); state.set_cinematic(false); t.run(4)
assert(#said==3,"cutscene exit cancels description")
-- Two scenes in a row leave cinematic mode for a moment between them (Gringotts cart, Oct 7).
state.set_cinematic(true); t.run(0.5)
line(text,1); t.run(0.2); state.set_cinematic(false); t.run(0.5); state.set_cinematic(true); t.run(1)
assert(#said==4,"a moment between two scenes keeps the description")
-- A long sound-only line ("(snoring)") neither holds descriptions back nor cancels them.
line(text,0.5); t.run(0.2); line("(snoring)",13,"Snore_1"); t.run(1)
assert(#said==5,"a sound-only line does not hold back a description")
state.set_cinematic(false); t.run(3)
line(text,1); t.run(0.2); state.paused=true; t.run(5)
assert(#said==5,"pause holds descriptions")
state.paused=false; t.run(1.3)
assert(#said==6,"resume preserves remaining delay")
line(text,1); t.run(0.2); skip_observer("delete","DEL"); t.run(2)
assert(#said==6,"skip cancels pending description before scene gate changes")
line(text,1); t.run(0.2); t.action("audio_description")(); local before=#said; t.run(2)
assert(#said==before,"turning descriptions off cancels pending speech")
assert(subs.similarity("Hello there, friend","hello there friend")==1)
assert(subs.similarity("It can't be.","Just give me whatever it is you've found here and we can let bygones be bygones.")<0.7,"a short line is not contained in a long one")
assert(subs.similarity("Take this. It's Wiggenweld Potion. That stuff'll right you in a second.","That stuff will write you in a second.")>0.7,"a transcript line inside the game's longer line still matches")
t.action("audio_description")(); t.run(5)
local n0=#said
line("Wait.",0.3,"Other_1"); t.run(1)
assert(#said==n0,"a keyed description ignores other lines with the same text")
line("Something the transcript misheard.",0.3,"Fig_7"); t.run(1)
assert(said[#said]=="Keyed description.","a keyed description fires on its line ID whatever the text")

-- Oct 6: an interjection in a silence ("Nor do I.", "Hang on!") cancelled every description
-- still waiting, so the whole dragon attack went undescribed. Now it only holds back the ones
-- it would talk over.
t.run(3); n0=#said
line("Wait. We do not know what -",1,"Fig_20")          -- items due 3, 7 and 13 s from now
t.run(2.5); line("Hang on!",1,"Fig_21")                -- spoken 2.5-3.5 s: the 3 s item waits
t.run(0.8); assert(#said==n0,"a description never talks over a line")
t.run(0.6); assert(said[#said]=="A dragon swoops.","the held description follows the interjection")
t.run(4); assert(said[#said]=="The carriage breaks apart.","later descriptions keep their moment")
-- A new trigger's descriptions replace older ones that would fall after its first.
line("Give me your hand!",1,"Fig_30"); t.run(2.5)
assert(said[#said]=="Fig grabs your hand.","the newer scene's description plays")
t.run(8); assert(said[#said]=="Fig grabs your hand.","the older line's later description is dropped, not spoken out of order")
-- A line that starts while the previous one should still be playing was skipped to.
t.run(2); n0=#said
line("Wait. We do not know what -",3,"Fig_20"); t.run(1); line("Next line.",1,"Fig_22"); t.run(15)
assert(#said==n0,"skipping a line drops its silence's descriptions")
-- Player lines are keyed without the voice: PlayerMale_500 is the same line as PlayerFemale_500.
line("What's that glow?",1,"PlayerMale_500"); t.run(2)
assert(said[#said]=="You point.","a player line fires for either voice")
-- A short "line before" must be that whole line: "Hmm. Revelio, perhaps." is not "Revelio."
-- (a much later scene's description fired in the Gringotts vault, Oct 7).
t.run(2); n0=#said
line("Let me think. Hmm. Revelio, perhaps.",1,"Fig_40"); t.run(1.5)
line("Revelio?",0.5,"Player_41"); t.run(3)
assert(#said==n0,"a word inside a longer line does not satisfy a short prev")
assert(not next(t.hooks),"custom subtitle event needs no repeated RegisterHook attempts")
print("subtitles test passed")
