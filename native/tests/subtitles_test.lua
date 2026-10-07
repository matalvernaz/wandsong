local t = dofile("native/tests/testlib.lua")
local events={}
RegisterCustomEvent=function(name,fn) events[name]=fn end
package.loaded.descriptions={{after="We must hurry, the carriage is waiting.",delay=0.2,text="Fig climbs into the carriage."},
    {id="Fig_7",after="Wait.",delay=0.2,text="Keyed description."}}
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
line(text,1); t.run(0.2); state.paused=true; t.run(5)
assert(#said==3,"pause holds descriptions")
state.paused=false; t.run(1.3)
assert(#said==4,"resume preserves remaining delay")
line(text,1); t.run(0.2); skip_observer("delete","DEL"); t.run(2)
assert(#said==4,"skip cancels pending description before scene gate changes")
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
assert(not next(t.hooks),"custom subtitle event needs no repeated RegisterHook attempts")
print("subtitles test passed")
