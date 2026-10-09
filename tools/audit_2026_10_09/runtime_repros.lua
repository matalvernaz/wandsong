-- Audit probes. Fake game objects only, run in isolated temporary directories.
local t = dofile('native/tests/testlib.lua')
local case = assert(os.getenv('WANDSONG_AUDIT_CASE'))
local function result(s) print('AUDIT RESULT: ' .. s) end
local function up(fn, wanted)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error('missing upvalue ' .. wanted)
end

if case == 'menu_stall' then
    local hooks = {}
    RegisterCustomEvent = function(name, fn) hooks[name] = fn end
    local dispatch, state = require('dispatch'), require('state')
    dispatch.every(100, function() end, 'keep dispatcher active')
    hooks.Tick()
    state.ui_blocker = 'InPauseMode'
    t.run(2)
    local ran = false
    dispatch.run(function() ran = true end, 'menu key')
    t.run(5)
    assert(state.loading() and not ran)
    result('Menu falsely remains loading after 7 seconds; queued menu action never runs.')
elseif case == 'settings_override' then
    local s = { SubtitlesEnabled = false, AudioVisualizer = true, AccessibilityAudioCueOpacity = 1 }
    s.IsValid = function() return true end
    s.GetFullName = function() return 'PhoenixGameSettings /Game/Settings' end
    s.SetSubtitlesEnabled = function(self, value) self.SubtitlesEnabled = value end
    s.SaveSettings = function() end
    local cdo = { IsValid = function() return true end, GetPhoenixGameSettings = function() return s end }
    StaticFindObject = function() return cdo end
    FindAllOf = function() return {} end
    require('speech').say = function() end
    local gs = require('gamesettings')
    assert(gs.apply() and s.SubtitlesEnabled)
    gs.toggle('subtitles')
    assert(not s.SubtitlesEnabled)
    gs.enforce()
    assert(s.SubtitlesEnabled)
    result('Explicit subtitles OFF is overwritten to ON by the next enforcement tick.')
elseif case == 'wrong_handler' or case == 'menu_reorder' or case == 'virtual_enter' then
    for k, v in pairs({ OEM_FOUR=219, OEM_SIX=221, OEM_FIVE=220, OEM_ONE=186, OEM_SEVEN=222,
                        OEM_MINUS=189, OEM_PLUS=187, RETURN=13, F11=122, F12=123 }) do Key[k] = v end
    FindAllOf = function() return {} end
    StaticFindObject = function() return nil end
    FindFirstOf = function() return nil end
    RegisterLoadMapPostHook = function() end
    package.loaded.world = { gameplay=function() return case == 'virtual_enter' end,
        in_game=function() return case == 'virtual_enter' end, ui_busy=function() return false end }
    require('speech').say = function() end
    require('menus')
    if case == 'wrong_handler' then
        local fn = up(up(up(t.action('press'), 'click_current'), 'click_handler'), 'bound_event')
        local dangerous = 'BndEvt__DeleteSave_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature'
        local class = { IsValid=function() return true end, GetSuperStruct=function() return nil end,
            ForEachFunction=function(_, visit)
                visit({ GetFName=function() return { ToString=function() return dangerous end } end })
            end }
        local owner = { GetClass=function() return class end }
        local button = { GetFName=function() return { ToString=function() return 'ContinueButton' end } end }
        assert(fn(owner, button, 'OnButtonClickedEvent') == dangerous)
        result('ContinueButton resolves to the unrelated DeleteSave handler when no name matches.')
    else
        local pressed, reorder = nil, false
        local a = { text='First destination', button=true, on_press=function() pressed='first' end }
        local b = { text='Second destination', button=true, on_press=function() pressed='second' end }
        local provider = { title='Places', items=function() return reorder and {b,a} or {a,b} end }
        require('state').open_screen(provider, 'select')
        t.action('review_next')()
        if case == 'menu_reorder' then
            reorder = true
            t.action('press')()
            assert(pressed == 'second')
            result('Reordering an open list makes Press activate the unselected second destination.')
        else
            t.action('press_enter')()
            assert(pressed == nil)
            t.action('press')()
            assert(pressed == 'first')
            result('Enter does nothing on an open mod screen during gameplay; the Press key works.')
        end
    end
elseif case == 'hotspot_remap' then
    local f = assert(io.open(require('files').input(), 'w'))
    f:write('ActionMappings=(ActionName="AM_Interact",Key=Delete,GroupName="OnFoot")\n')
    f:close()
    local calls, observer, reader = 0
    local actor = { allowInteract=true, WantsToBeInteractable=false, IsActivated=true, bHotSpotActive=true,
        GetFullName=function() return 'BP_AncientMagicHotSpot_C /Game/Hotspot' end,
        InteractionInitiated=function() calls=calls+1 end }
    local entry = { path='/Game/Hotspot', kind='magic', x=90, y=0, z=0, extra={} }
    package.loaded.world = { in_game=function() return true end, position=function() return 0,0,0,0 end,
        pawn=function() return {} end, on_scan=function(_,fn) reader=fn end,
        entries=function() reader(actor,entry); return {entry} end }
    package.loaded.feedback = { prompt_active=function() return false end }
    FindAllOf = function() return {actor} end
    local keys = require('keys')
    keys.observe = function(fn) observer=fn end
    require('speech').say = function() end
    require('hotspots')
    t.run(3)
    observer('delete','DEL')
    t.run(0.4)
    assert(calls == 0)
    result('Interact remapped to Delete is announced but the hotspot does not recognize DEL.')
elseif case == 'scanner_marker' then
    local walked, faced
    package.loaded.world = { in_game=function() return true end, position=function() return 0,0,0,0 end,
        entries=function() return {} end, locate=function() return nil end }
    package.loaded.markers = { list=function() return {{x=1000,y=0,z=0},{x=0,y=2000,z=0}} end,
        marked=function() return false end }
    package.loaded.path = { objective=function() return {x=1000,y=0,z=0,name='Nearest objective'} end,
        walk_objective=function() walked='nearest objective' end,
        face_point=function(x,y) faced={x,y} end }
    require('speech').say = function() end
    require('scanner')
    t.action('scan_cat_next')()
    t.action('scan_next')()
    t.action('scan_repeat')()
    assert(faced[1] == 0 and faced[2] == 2000)
    t.action('scan_walk')()
    assert(walked == 'nearest objective')
    result('Second marker is selected and faced, but Walk requests the nearest general objective.')
elseif case == 'disabled_world_loading' then
    local flag = assert(io.open(require('files').runtime('world_active.flag',true),'w'))
    flag:write('previous crash'); flag:close()
    local reads = 0
    FindFirstOf=function() reads=reads+1; return nil end
    FindAllOf=function() reads=reads+1; return {} end
    StaticFindObject=function() reads=reads+1; return nil end
    require('state').mark_loading(10)
    require('world')
    t.run(1)
    assert(reads > 0 and require('state').loading())
    result('Crash-paused world still performs ' .. reads .. ' object searches during a marked load.')
elseif case == 'pending_bindings' then
    local input = require('files').input()
    local function write(key)
        local f = assert(io.open(input, 'w'))
        f:write('ActionMappings=(ActionName="AM_Map",Key=' .. key .. ',GroupName="OnFoot")\n')
        f:close()
    end
    write('M')
    local bindings = require('bindings')
    assert(bindings.key('AM_Map') == 'M' and bindings.conflict('M') == 'AM_Map')
    write('J')
    assert(bindings.key('AM_Map') == 'M' and bindings.conflict('M') == nil)
    result('A pending Map rebind frees M for mod controls even though the active game still uses M.')
elseif case == 'reused_address' then
    local objects = {}
    local function obj(cls, path, props)
        props.IsValid=function() return true end
        props.GetFullName=function() return cls .. ' ' .. path end
        props.GetAddress=function() return path end
        props.GetClass=function() return {GetFName=function() return {ToString=function() return cls end} end} end
        props.IsA=function() return false end
        objects[path]=props
        return props
    end
    local ui=obj('UIManager','/Game/UI',{IsInPreGameplayState=function() return false end,
        IsAsyncScreenLoadInProgress=function() return false end,GetInMenuTransition=function() return false end,
        InPauseMode=function() return false end})
    local pawn=obj('Biped_Player','/Game/Player',{InCinematic=false,
        RootComponent={RelativeLocation={X=0,Y=0,Z=0}},Controller={ControlRotation={Yaw=0}}})
    local current=obj('BP_Student_C','/Game/OldPerson',{RootComponent={RelativeLocation={X=100,Y=0,Z=0}}})
    current.GetAddress=function() return 1234 end
    FindFirstOf=function(cls) if cls=='UIManager' then return ui elseif cls=='Biped_Player' then return pawn end end
    FindAllOf=function(cls) return cls=='NPC_Character' and {current} or {} end
    StaticFindObject=function(path) return objects[path] end
    package.loaded.tips={once=function() end}
    package.loaded.guide={welcome=function() return 'Welcome' end}
    require('speech').say=function() end
    local world=require('world')
    t.run(8)
    assert(world.locate('/Game/OldPerson')[1]==100)
    objects['/Game/OldPerson']=nil
    current=obj('BP_Student_C','/Game/NewPerson',{RootComponent={RelativeLocation={X=900,Y=0,Z=0}}})
    current.GetAddress=function() return 1234 end
    t.run(2)
    assert(world.locate('/Game/OldPerson')[1]==900 and world.locate('/Game/NewPerson')==nil)
    result('A new actor reusing an address keeps the old actor identity and receives its new position.')
elseif case == 'ai_ui_load' then
    local objects={}
    local function obj(cls,path,props)
        props=props or {}
        props.IsValid=function() return true end
        props.GetFullName=function() return cls .. ' ' .. path end
        objects[path]=props
        return props
    end
    local pc=obj('BP_PhoenixPlayerController_C','/Game/PC')
    local pawn=obj('BP_Biped_Player_C','/Game/Player',{Controller=pc,
        CharacterMovement={MaxWalkSpeed=600,StopMovementImmediately=function() end},
        RootComponent={CapsuleRadius=30,CapsuleHalfHeight=90,SetCapsuleSize=function() end}})
    pc.Possess=function(_,p) p.Controller=pc end
    local ai=obj('AIController','/Game/AI',{Possess=function(self,p) p.Controller=self end,
        MoveToLocation=function() return 2 end,GetMoveStatus=function() return 3 end,
        StopMovement=function() end,UnPossess=function() end,K2_DestroyActor=function() end})
    obj('GameplayStatics','/Script/Engine.Default__GameplayStatics',{
        BeginDeferredActorSpawnFromClass=function() return ai end,FinishSpawningActor=function(_,a) return a end})
    obj('Class','/Script/AIModule.AIController')
    StaticFindObject=function(p) return objects[p] end
    package.loaded.world={in_game=function() return true end,position=function() return 0,0,0,0 end,
        pawn=function() return pawn end}
    require('speech').say=function() end
    local flag=assert(io.open(require('files').runtime('ai_walk_enabled.txt'),'w')); flag:write('on'); flag:close()
    local walk=require('ai_walk')
    assert(walk.start({1000,0,0},'Door') and pawn.Controller==ai)
    -- world.lua marks asynchronous UI screen loads the same way, without changing the world.
    require('state').mark_loading(0.5)
    t.run(1)
    walk.stop('menu closed')
    assert(not walk.active() and pawn.Controller==ai)
    result('A UI load forgets the experimental AI walk, leaving the same player pawn AI-possessed.')
elseif case == 'description_save_load' then
    local events,said={},{}
    RegisterCustomEvent=function(name,fn) events[name]=fn end
    package.loaded.descriptions={{id='Old_1',after='Old scene line.',delay=8,text='Description of the old save.'}}
    require('speech').say=function(s) said[#said+1]=s end
    require('subtitles')
    local state=require('state')
    state.set_cinematic(true); t.run(0.5)
    events.BPAddSubtitleEvent(nil,{get=function() return {
        lineID={ToString=function() return 'Old_1' end},DurationSeconds=1,
        VoiceName={ToString=function() return 'Speaker' end}} end},
        {get=function() return {ToString=function() return 'Old scene line.' end} end})
    t.run(0.5)
    state.mark_loading(2); t.run(0.2); state.set_cinematic(false)
    t.run(2)
    -- An unrelated save starts in a silent scene, with no matching old dialogue.
    state.generation=state.generation+1
    state.set_cinematic(true); t.run(3)
    assert(said[#said]=='Description of the old save.')
    result('Loading an unrelated save into a scene replays the prior save\'s pending description.')
elseif case == 'spell_checkpoint_fallback' then
    local f=assert(io.open(require('files').input(),'w'))
    f:write('ActionMappings=(ActionName="UMGSpellMinigameOption1",Key=LeftMouseButton,GroupName="MinigamesGlobal")\n')
    f:close()
    Key.OEM_FIVE=220
    local keys=require('keys')
    keys.action{id='press',name='Press',default='\\',run=function() end}
    local events,actions={},{}
    RegisterCustomEvent=function(name,fn) events[name]=fn end
    package.loaded.input_bridge={focused=function() return true end}
    require('speech').say=function() end
    local path='/Game/UI_SpellMiniGame_C_1'
    local widget={Visibility=0,IsValid=function() return true end,
        GetFullName=function() return 'SpellMiniGameBase ' .. path end,
        GetMiniGameName=function() return {ToString=function() return 'Revelio' end} end,
        GetIsWaitingForStart=function() return false end}
    StaticFindObject=function(p) return p==path and widget or nil end
    FindFirstOf=function() return {IsValid=function() return true end,
        OnInputAction=function(_,code) actions[#actions+1]=code end} end
    local spells=require('spells')
    events.OnMinigameFullyLoaded({get=function() return widget end})
    t.run(0.2)
    local lesson=up(spells.press,'lesson')
    assert(lesson)
    local option_key=up(up(spells.items,'details'),'option_key')
    local label,fallback=option_key(77)
    assert(fallback and label==keys.describe_combo(keys.combo_of('press')))
    lesson.mode,lesson.window_code='adapted',77
    spells.press()
    assert(lesson.assisted and #actions==0)
    result('Checkpoint 77 announces the Press fallback, but Press starts full assistance instead of answering it.')
else error('unknown case ' .. case) end
