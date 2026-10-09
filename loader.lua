--[[
    BITE BY DAYLIGHT -- single script
    PlaceId 129117145449630.  RightControl hides the menu.
    Replaces every earlier bbd_* script. Run this alone.

    Hard-won details baked in:
      * generator list cached, rebuilt only on a debounced map change.
        MAPS:GetDescendants() is 6138 instances / ~1.6ms and the old
        scripts called it ~18x a second -- that was the stutter.
      * a generator only accepts a completion from an Event the server
        HANDED you, so each is engaged via its ProximityPrompt first.
      * ESP name anchors to the model bounding box. Springtrap has no
        Head part and killer rigs are 9+ studs tall.
      * parry fires over the Warp wire by replaying a captured Ability
        packet. Measured: Springtrap's swing is 1.10s and damage lands at
        0.153s -- 13.9% in, NOT mid-animation. Firing at 55% is 452ms late.
      * optimizer records every original value and restores on toggle-off.
]]

LPH_ATTRIBUTES(ERROR_HANDLING(false))


local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local VIM        = game:GetService("VirtualInputManager")
local RS         = game:GetService("ReplicatedStorage")
local Lighting   = game:GetService("Lighting")
local Stats      = game:GetService("Stats")
local CS         = game:GetService("CollectionService")
local HttpSvc    = game:GetService("HttpService")
local LP         = Players.LocalPlayer
local CAM        = workspace.CurrentCamera
local req        = request or http_request

local G = (getgenv and getgenv()) or _G
for _, old in ipairs({"BBD","BBDHub","BBDParry","BBDGens","BBDVerify","BBDTheme",
                      "BBDWire","BBDSet","BBDTiming","BBDVerify2","BBDWatch"}) do
    if G[old] and G[old].stop then pcall(G[old].stop) end
    G[old] = nil
end

local A = { conns={}, drawings={}, saved={}, stopped=false, repaint={},
            aimPts={},
            themeStatus="idle", fps=0, scale=1,
            captured={}, lastPacket="none yet", fires=0, lastMode="-", lastDelay=0 }
G.BBD = A

local C = {
    sprint={on=false,forceRun=false},
    speed ={on=false,walk=22,run=34},
    noStun={on=false}, dodges={on=false},
    parry ={on=false, slot=2, range=16, hitFrac=0.139, offset=-0.06, cooldown=0.35,
            -- autoPing/autoTune/baseLead are self-managing, no UI
            autoPing=true, baseLead=0.06, autoTune=true},
    gens  ={on=false,delay=0,range=30,tp=false,tpHeight=2},
    behind={on=false, dist=4.5, rate=0.4, maxDist=200, faceThem=true},
    killer={silent=false, fov=180, maxDist=400, los=true, mode="crosshair",
            lockTo="",   -- "" = pick automatically; otherwise a player name
            autoThrow=false, throwCd=1.6, sticky=1.5, never=false},
    esp   ={on=false,highlight=true,boxes=false,tracers=false,skeleton=false,
            names=true,class=true,distance=true,health=false,gens=true,traps=true,
            maxDist=400,fillAlpha=0.62,
            -- redraws per second; the eye gains nothing past ~40 and the
            -- cost is linear in this number
            rate=40},
    opt   ={fpsCap=0, particles=false, postfx=false, shadows=false,
            textures=false, terrain=false, lowq=false, float=false,
            -- re-run after a server hop; without it the hub is gone on
            -- arrival and has to be executed by hand
            -- the published loadstring target, so a server hop can
            -- re-run the hub on arrival without the user doing anything
            loader="https://raw.githubusercontent.com/krazy2dope/Crusader-Hub/main/loader.lua"},
    hop   ={target=80, maxTries=6},
    theme ={accent=Color3.fromRGB(120,255,160), survivor=Color3.fromRGB(90,210,255),
            killer=Color3.fromRGB(255,70,70),  gen=Color3.fromRGB(120,255,140), trap=Color3.fromRGB(255,170,60),
            wall=0.15, glass=true, panel=0.45, vol=0.5, loop=true,
            -- the wallpaper and audio links themselves, so a re-execute
            -- brings the theme back instead of starting blank
            url="", audio=""},
    cross = {on=false, style="star", size=22, spin=true, spinSpeed=70,
             fovCircle=false, useAccent=false,
             color=Color3.fromRGB(0,56,184)},   -- flag blue
    wm    = {on=true, scale=1.17},
    key   = Enum.KeyCode.RightControl,
}
A.C = C

-- ---- settings persistence -------------------------------------------
-- Everything the user toggles is written to disk and restored next launch,
-- so the hub comes back exactly as they left it.
local CFG_FILE="crusader_hub_cfg.json"

local function serialiseCfg()
    local t={}
    for k,v in pairs(C) do
        if typeof(v)=="Color3" then
            t[k]="#"..v:ToHex()
        elseif typeof(v)=="EnumItem" then
            t[k]="Enum:"..v.Name
        elseif type(v)=="table" then
            local sub={}
            for k2,v2 in pairs(v) do
                if typeof(v2)=="Color3" then sub[k2]="#"..v2:ToHex()
                elseif type(v2)=="number" or type(v2)=="boolean" or type(v2)=="string" then
                    sub[k2]=v2 end
            end
            t[k]=sub
        elseif type(v)=="number" or type(v)=="boolean" or type(v)=="string" then
            t[k]=v
        end
    end
    local ok,j=pcall(function() return HttpSvc:JSONEncode(t) end)
    return ok and j or nil
end

local function loadCfg()
    if not (isfile and readfile) then return false end
    local ok,has=pcall(isfile,CFG_FILE)
    if not ok or not has then return false end
    local okR,raw=pcall(readfile,CFG_FILE)
    if not okR or not raw then return false end
    local okJ,t=pcall(function() return HttpSvc:JSONDecode(raw) end)
    if not okJ or type(t)~="table" then return false end
    for k,v in pairs(t) do
        if type(v)=="table" and type(C[k])=="table" then
            for k2,v2 in pairs(v) do
                if type(v2)=="string" and v2:sub(1,1)=="#" then
                    local okC,c=pcall(Color3.fromHex,v2)
                    if okC then C[k][k2]=c end
                elseif C[k][k2]~=nil or k=="cross" then
                    C[k][k2]=v2
                end
            end
        elseif type(v)=="string" and v:sub(1,7)=="Enum:" then
            local nm=v:sub(6)
            if Enum.KeyCode[nm] then C[k]=Enum.KeyCode[nm] end
        elseif type(v)=="string" and v:sub(1,1)=="#" then
            local okC,c=pcall(Color3.fromHex,v) if okC then C[k]=c end
        elseif C[k]~=nil and type(C[k])~="table" then
            C[k]=v
        end
    end
    return true
end
A.cfgLoaded = loadCfg()

local lastSaved=nil
function A.saveCfg()
    if not writefile then return end
    local j=serialiseCfg()
    if not j or j==lastSaved then return end   -- only write on a real change
    if pcall(writefile,CFG_FILE,j) then lastSaved=j end
end


local ST = { gensFixed=0, gensTries=0, genStatus="idle" }
A.S = ST

local function char() return LP.Character end
local function root() local c=char() return c and c:FindFirstChild("HumanoidRootPart") end

----------------------------------------------------------------------
local genCache, genCacheAt, genDirty = {}, 0, true
local function rebuildGenCache()
    genCache = {}
    local maps = workspace:FindFirstChild("MAPS") if not maps then return end
    for _, d in ipairs(maps:GetDescendants()) do
        if d:IsA("RemoteEvent") and d.Name=="Event" and d.Parent and d.Parent.Name=="GeneratorMain" then
            local m=d for _=1,4 do m=m and m.Parent end
            if m then genCache[#genCache+1]={ev=d, model=m,
                root=m:FindFirstChild("RootPart") or m:FindFirstChild("HumanoidRootPart")} end
        end end
    genCacheAt=os.clock() genDirty=false end
local function generators()
    if genDirty or os.clock()-genCacheAt>5 then rebuildGenCache() end
    return genCache end
local pendingDirty=false
local function markDirty()
    if pendingDirty then return end
    pendingDirty=true task.delay(1,function() genDirty=true pendingDirty=false end) end
table.insert(A.conns, workspace.DescendantAdded:Connect(function(d)
    if d.Name=="Event" or d.Name=="GeneratorMain" then markDirty() end end))
table.insert(A.conns, workspace.DescendantRemoving:Connect(function(d)
    if d.Name=="Event" or d.Name=="GeneratorMain" then markDirty() end end))
local function genDone(e)
    return (e.model:GetAttribute("Progress") or 0)>=100 or e.model:GetAttribute("Fixed")==true end

----------------------------------------------------------------------
local function applySprint()
    local c=char() if not c then return end
    local mx=c:GetAttribute("MaxStamina") or 0 if mx<=0 then mx=100 end
    c:SetAttribute("MaxStamina",mx) c:SetAttribute("Stamina",mx)
    c:SetAttribute("Regen",math.max(c:GetAttribute("Regen") or 0,100))
    if c:GetAttribute("CanRun")~=true then c:SetAttribute("CanRun",true) end
    if C.sprint.forceRun then
        local h=c:FindFirstChildOfClass("Humanoid")
        if h and h.MoveDirection.Magnitude>0 and c:GetAttribute("Running")~=true then
            c:SetAttribute("Running",true) end end end
-- Base speeds are per ROLE and per CLASS, not a constant: measured live,
-- Springtrap runs 14/22.5 while a survivor runs 12/24 and the lobby 12/0.
-- The old restore wrote a hardcoded WalkSpeed=12 and never touched RunSpeed
-- at all, so turning the boost off left sprint permanently fast and walking
-- wrong for the killer. Snapshot whatever the character actually spawned
-- with, before the first overwrite, and put exactly that back.
--
-- The snapshot lives in SH because it has to survive a script reload. Kept
-- in A it would be lost on reload and the next capture would record the
-- BOOSTED values as the baseline, making the boost impossible to undo.
-- Reached through G, not the SH upvalue: SH is declared further down the
-- file, so naming it here would read a nil GLOBAL and error on the first
-- call. G is in scope from the top and the table is in place long before
-- anything calls this.
local function speedShared()
    local sh=G.BBD_SHARED
    if not sh then sh={} G.BBD_SHARED=sh end
    return sh
end
local function speedSnapshot(c)
    local sh=speedShared()
    if sh.speedBaseFor~=c then
        sh.speedBaseFor=c
        sh.speedBase={walk=c:GetAttribute("WalkSpeed"),
                      run =c:GetAttribute("RunSpeed")}
    end
    return sh.speedBase
end
local function applySpeed()
    local c=char() if not c then return end
    speedSnapshot(c)
    if c:GetAttribute("WalkSpeed")~=C.speed.walk then c:SetAttribute("WalkSpeed",C.speed.walk) end
    if c:GetAttribute("RunSpeed")~=C.speed.run then c:SetAttribute("RunSpeed",C.speed.run) end end
function A.restoreSpeed()
    local c=char() if not c then return false end
    local sh=speedShared()
    local b=sh.speedBase
    -- no snapshot means we never boosted this character; leave it alone
    -- rather than guessing a number and breaking a role we did not touch
    if not b or sh.speedBaseFor~=c then return false end
    if b.walk~=nil then c:SetAttribute("WalkSpeed",b.walk) end
    if b.run ~=nil then c:SetAttribute("RunSpeed", b.run)  end
    sh.speedBase=nil sh.speedBaseFor=nil
    return true
end
local function applyNoStun()
    local c=char() if not c then return end
    if c:GetAttribute("Stun") then c:SetAttribute("Stun",false) end
    if c:GetAttribute("Ragdoll") then c:SetAttribute("Ragdoll",false) end
    for _,t in ipairs({"CantMove","Ragdoll","Confusion","Stun"}) do
        if c:HasTag(t) then pcall(function() c:RemoveTag(t) end) end end end
local function applyDodges()
    local c=char() if not c then return end
    if (c:GetAttribute("Dodges") or 0)<99 then c:SetAttribute("Dodges",99) end end

----------------------------------------------------------------------
-- parry: capture the real Ability packet, replay it with the slot patched
----------------------------------------------------------------------
-- Shared, reload-surviving state.
--
-- hookmetamethod CANNOT be uninstalled. Every execution used to install a
-- fresh __namecall layer on top of the previous one, and the old layers kept
-- running their old code forever -- so a bug shipped once stayed resident for
-- the rest of the game session and no amount of reloading could remove it.
-- That is what broke swinging and throwing twice now.
--
-- So the hook is installed exactly ONCE per game session and reads its
-- configuration out of this table. Reloads replace the table's contents,
-- never the hook. Only a rejoin clears the hook, and it no longer needs to.
local G = (getgenv and getgenv()) or _G
local SH = G.BBD_SHARED
if not SH then
    SH = {captured={}, lastPacket="none", captureOff=false, stopped=false,
          silent=false, aimPos=nil, aimSwaps=0,
          rawTriple=nil, rawT=0, rawCount=0}
    G.BBD_SHARED = SH
end
-- a reload inherits the captured packets but starts disarmed
SH.silent=false SH.aimPos=nil SH.stopped=false

local Reliable = RS:FindFirstChild("Modules")
Reliable = Reliable and Reliable:FindFirstChild("Warp")
Reliable = Reliable and Reliable:FindFirstChild("Index")
Reliable = Reliable and Reliable:FindFirstChild("Event")
Reliable = Reliable and Reliable:FindFirstChild("Reliable")

local function toBytes(b)
    if typeof(b)~="buffer" then return nil end
    local n=buffer.len(b) local t=table.create(n)
    for i=0,n-1 do t[i+1]=buffer.readu8(b,i) end return t end
local function fromBytes(t)
    local b=buffer.create(#t)
    for i=1,#t do buffer.writeu8(b,i-1,t[i]) end return b end
local function findAbilitySlot(t)
    local w="Ability"
    for i=1,#t-#w do
        local ok=true
        -- string.byte, NOT w:byte(j): a colon call emits a NAMECALL and
        -- would overwrite the engine's pending namecall method.
        for j=1,#w do if t[i+j-1]~=string.byte(w,j) then ok=false break end end
        if ok then local si=i+#w+1 if si<=#t then return si end return nil end end
    return nil end

-- The Request remote carries the Side-channel reply: when you throw, the
-- server asks the client where it is aiming and the client answers with
-- {Hit.Position, UnitRay.Direction, UnitRay.Origin}. The request id is
-- session-random, so this matches on SHAPE: exactly three Vector3s.
local Request = RS:FindFirstChild("Modules")
Request = Request and Request:FindFirstChild("Warp")
Request = Request and Request:FindFirstChild("Index")
Request = Request and Request:FindFirstChild("Event")
Request = Request and Request:FindFirstChild("Request")

-- ---- silent aim, applied where the ray is PRODUCED -------------------
--
-- The Warp Request channel is server-initiated: the server asks the client to
-- resolve its aim, the game's own handler computes it, and the result is
-- queued and flushed next frame. Rewriting the outgoing packet is therefore
-- the wrong layer and never worked. This wraps the handler itself.
--
-- Identified live: channel 1, PlayerScripts.Client line 280, called with
-- "Mouse", returning {hitPosition, unitDirection, rayOrigin}. Rather than
-- hardcode a handler id (they are randomised every session) or a line number,
-- every registered handler gets a thin wrapper that simply notices when a
-- return value IS that shape. Self-identifying, so it survives game updates.
local function isAimTriple(v)
    return type(v)=="table" and #v==3
       and typeof(v[1])=="Vector3" and typeof(v[2])=="Vector3"
       and typeof(v[3])=="Vector3"
end

SH.aimSeen = SH.aimSeen or 0
local function installAimWrap()
    if not (getgc and islclosure) then return 0 end
    SH.aimWrapped = SH.aimWrapped or setmetatable({}, {__mode="k"})
    local count = 0
    for _,tb in ipairs(getgc(true)) do
        if type(tb)=="table" and not SH.aimWrapped[tb] then
            local chans,n = 0,0
            local ok = pcall(function()
                for k,sub in pairs(tb) do
                    if type(k)=="string" and #k==1 and type(sub)=="table" then
                        chans = chans + 1
                        for _,fn in pairs(sub) do
                            if type(fn)=="function" then n = n + 1 end end
                    end
                end
            end)
            if ok and chans>=3 and n>0 then
                SH.aimWrapped[tb] = true
                for k,sub in pairs(tb) do
                    if type(k)=="string" and #k==1 and type(sub)=="table" then
                        for id,fn in pairs(sub) do
                            if type(fn)=="function" then
                                local orig = fn
                                sub[id] = function(...)
                                    local res = table.pack(orig(...))
                                    local t = res[1]
                                    if isAimTriple(t) then
                                        SH.lastOrigin = t[3]
                                        SH.lastOriginT = os.clock()
                                        -- Store it relative to the camera.
                                        -- The absolute point goes stale the
                                        -- moment you move: measured 27.9
                                        -- studs behind the player after a
                                        -- short run, which casts the
                                        -- line-of-sight ray through geometry
                                        -- already passed and drops the lock.
                                        local cp = CAM.CFrame.Position
                                        SH.originVsCam = t[3] - cp
                                        SH.aimSeen = SH.aimSeen + 1
                                        if SH.silent and SH.aimPos then
                                            local o = t[3]
                                            local want = SH.aimPos
                                            t[1] = want
                                            local d = want - o
                                            if d.Magnitude > 0 then t[2] = d.Unit end
                                            SH.aimSwaps = (SH.aimSwaps or 0) + 1
                                            -- captured here, not read back later:
                                            -- the lock can drop between the swap
                                            -- and anything that inspects it
                                            SH.sentAim = want
                                            SH.sentOrigin = o
                                            SH.sentName = SH.aimName
                                            SH.sentDist = d.Magnitude
                                            SH.sentT = os.clock()
                                        else
                                            SH.missedAim = (SH.missedAim or 0) + 1
                                            SH.missedT = os.clock()
                                        end
                                    end
                                    return table.unpack(res, 1, res.n)
                                end
                                count = count + 1
                            end
                        end
                    end
                end
            end
        end
    end
    return count
end
SH.aimWrapCount = (SH.aimWrapCount or 0) + installAimWrap()

local Unreliable = RS:FindFirstChild("Modules")
Unreliable = Unreliable and Unreliable:FindFirstChild("Warp")
Unreliable = Unreliable and Unreliable:FindFirstChild("Index")
Unreliable = Unreliable and Unreliable:FindFirstChild("Event")
Unreliable = Unreliable and Unreliable:FindFirstChild("Unreliable")

local function findAimTriple(v, depth)
    depth = depth or 0
    if depth > 6 or type(v) ~= "table" then return nil end
    if #v == 3 and typeof(v[1])=="Vector3" and typeof(v[2])=="Vector3"
       and typeof(v[3])=="Vector3" then return v end
    for _, inner in pairs(v) do
        local r = findAimTriple(inner, depth+1)
        if r then return r end
    end
    return nil
end

-- Installed once per game session, and deliberately almost empty.
--
-- hookmetamethod cannot be uninstalled, so whatever body is installed here is
-- stuck for the rest of the session: a bug shipped once stays resident and no
-- reload can remove it (only a rejoin can). So the body holds no logic of its
-- own. It calls two swappable callbacks that live in the shared table, which
-- every reload replaces. That way behaviour can be changed freely from here on
-- without reinstalling anything and without ever stacking a second layer.
--
--   SH.onSwap(self, ...)     runs BEFORE the forward, so it MUST be
--                            namecall-free (a colon call, even on a string,
--                            overwrites the pending namecall method). It
--                            returns a packed table of replacement args, or
--                            nil to forward unchanged.
--   SH.onObserve(self, ...)  runs AFTER the forward via task.defer, so it is
--                            free to do anything at all, including namecalls.
if hookmetamethod and newcclosure
   and not (G.BBD_HOOK_INSTALLED and rawequal(G.BBD_HOOK_GAME, game)) then
    G.BBD_HOOK_INSTALLED = true
    G.BBD_HOOK_GAME = game
    local oldNC
    oldNC = hookmetamethod(game,"__namecall",newcclosure(function(self,...) LPH_ATTRIBUTES(VM(NONE))
        if SH.stopped then return oldNC(self,...) end
        local nm = getnamecallmethod()
        if nm == "FireServer" and not checkcaller() then
            local swap = SH.onSwap
            if swap then
                local ok,rep = pcall(swap, self, ...)
                if ok and rep then
                    local obs = SH.onObserve
                    if obs then task.defer(obs, self, ...) end
                    return oldNC(self, table.unpack(rep, 1, rep.n))
                end
            end
            local obs = SH.onObserve
            if obs then task.defer(obs, self, ...) end
        end
        return oldNC(self,...)
    end))
end

-- ---- the swappable logic, replaced wholesale on every reload ----------

-- Namecall-free by construction: only rawequal, table indexing, Vector3
-- arithmetic and property reads. Nothing here may use a colon call.
SH.onSwap = function(self, ...)
    -- Ability packet capture. Runs here rather than in onObserve because the
    -- outgoing buffer is only reliably readable before Warp recycles it.
    if Reliable and rawequal(self, Reliable) and not SH.captureOff then
        local args = table.pack(...)
        for i = 1, args.n do
            local bt = toBytes(args[i])
            if bt then
                local si = findAbilitySlot(bt)
                if si then
                    SH.captured[bt[si]] = {chan = toBytes(args[1]) or {10},
                                           arg = bt, slotIdx = si}
                    SH.lastPacket = "slot " .. tostring(bt[si]) ..
                                    ", " .. tostring(#bt) .. " bytes"
                    break
                end
            end
        end
        return nil
    end
    -- The aim rewrite deliberately does NOT happen here any more.
    -- Matching "a table of three Vector3s" inside an outgoing Request payload
    -- also matched unrelated packets: swaps had already fired 3 times before a
    -- single aim ray existed, i.e. it was corrupting other traffic. The rewrite
    -- now happens in installAimWrap, on the handler that actually produces the
    -- aim ray, where there is nothing to misidentify.
    return nil
end

-- Runs after the forward, so it may use anything.
SH.log = SH.log or {}
local function describe(v, depth, seen)
    depth = depth or 0
    seen = seen or {}
    local t = typeof(v)
    if t == "Vector3" then
        return ("V3(%.1f, %.1f, %.1f)|len %.2f"):format(v.X, v.Y, v.Z, v.Magnitude)
    elseif t == "CFrame" then return "CFrame(" .. tostring(v.Position) .. ")"
    elseif t == "Instance" then return "Instance<" .. v.ClassName .. ":" .. v.Name .. ">"
    elseif t == "buffer" then
        local n = buffer.len(v)
        local parts = {}
        for i = 0, math.min(n, 24) - 1 do parts[#parts+1] = buffer.readu8(v, i) end
        return ("buffer[%d]{%s%s}"):format(n, table.concat(parts, ","), n > 24 and ",..." or "")
    elseif t == "table" then
        if depth > 5 then return "{...}" end
        if seen[v] then return "{cycle}" end
        seen[v] = true
        local parts = {}
        local n = 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 12 then parts[#parts+1] = "..." break end
            parts[#parts+1] = tostring(k) .. "=" .. describe(val, depth + 1, seen)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

SH.onObserve = function(self, ...)
    if not SH.spy then return end
    local which
    if rawequal(self, Request) then which = "Request"
    elseif Unreliable and rawequal(self, Unreliable) then which = "Unreliable"
    else return end
    local args = table.pack(...)
    local parts = {}
    for i = 1, args.n do parts[#parts+1] = ("  arg%d: %s"):format(i, describe(args[i])) end
    local entry = ("[%s] t=%.2f\n%s"):format(which, os.clock(),
                   table.concat(parts, "\n"))
    SH.log[#SH.log+1] = entry
    if #SH.log > 40 then table.remove(SH.log, 1) end
end

local KEY={[1]=Enum.KeyCode.Q,[2]=Enum.KeyCode.E}
local function fireWire(slot)
    if not Reliable then return false end
    local cap=SH.captured[slot]
    if not cap then
        for _,c2 in pairs(SH.captured) do
            cap={chan=c2.chan, arg=table.clone(c2.arg), slotIdx=c2.slotIdx}
            cap.arg[cap.slotIdx]=slot break end end
    if not cap then return false end
    return (pcall(function()
        Reliable:FireServer(fromBytes(cap.chan), fromBytes(cap.arg), nil) end)) end
local function fireKey(slot)
    local k=KEY[slot]
    task.spawn(function()
        pcall(function() VIM:SendKeyEvent(true,k,false,game) end)
        task.wait(0.12)
        pcall(function() VIM:SendKeyEvent(false,k,false,game) end) end) end

local function pingSec()
    local ok,v=pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
    return (ok and v or 70)/1000 end
A.lastPing=0
A.captureOff=false
A.aimPos=nil A.aimName="-" A.aimCount=0
A.lastThrow=0 A.throws=0

-- Closed loop. Ping compensation is only a guess; this checks the result.
-- Every swing aimed at us becomes a trial: if we took damage we were late
-- (and the damage timing also tells us exactly where the hit lands, which
-- recalibrates hitFrac). A clean run lets the lead creep back down so it
-- converges on the smallest lead that still works on this server.
-- 0.139 was measured deliberately from a killer-side probe, so it is treated
-- as PRIOR_W pseudo-samples rather than as just another data point. Without
-- that weight two noisy observations dragged it to 0.362 and the parry started
-- firing 241ms after the swing -- worse than never tuning at all. Different
-- killers do swing differently, so the band is wide enough to follow a real
-- difference, but it now takes consistent evidence to get there.
local HIT_PRIOR, PRIOR_W = 0.139, 6
A.recentAnims = {}
A.tune = { pending=nil, hits=0, clean=0, streak=0,
           fracN=PRIOR_W, fracSum=HIT_PRIOR*PRIOR_W, real=0,
           last="idle", adjusted=0 }

local function tuneRecordSwing(len, firedDelay)
    if not C.parry.autoTune then return end
    A.tune.pending = { t=os.clock(), len=len, fired=firedDelay,
                       firesBefore=A.fires }
end

local function tuneOnDamage()
    local pn = A.tune.pending
    -- Count the hit even with no pending swing. Previously this returned
    -- early, so "got hit" read 0 while the player was being beaten to death:
    -- the counter only ever saw damage from swings it had already detected,
    -- which hid the detection failure completely.
    A.tune.hits = A.tune.hits + 1
    A.tune.streak = 0
    if not pn then
        A.tune.undetected = (A.tune.undetected or 0) + 1
        -- Blame the most recent killer animation: whatever the killer played
        -- just before the damage landed is almost certainly the attack. Two
        -- sightings promote it to a real attack animation permanently.
        local now, best, bestT = os.clock(), nil, nil
        for _,r in ipairs(A.recentAnims) do
            local age = now - r.t
            if age >= 0 and age <= 1.0 and (not bestT or r.t > bestT) then
                best, bestT = r.id, r.t
            end
        end
        if best then
            local sc = (SH.learnedAnims[best] or 0) + 1
            SH.learnedAnims[best] = sc
            A.tune.last = (sc >= 2)
                and "LEARNED a new attack animation"
                or  "hit undetected - candidate animation noted"
        else
            A.tune.last = "hit with NO swing detected"
        end
        return
    end
    if not C.parry.autoTune then A.tune.pending=nil return end
    A.tune.pending = nil

    -- when the damage actually landed, less the ping it took to reach us
    local dt = (os.clock() - pn.t) - (A.lastPing * 0.5)
    if pn.len > 0 and dt > 0 and dt < pn.len then
        local f = dt / pn.len
        -- reject implausible samples outright instead of averaging them in
        if f > 0.05 and f < 0.60 then
            A.tune.fracN = A.tune.fracN + 1
            A.tune.fracSum = A.tune.fracSum + f
            A.tune.real = A.tune.real + 1
            C.parry.hitFrac = math.clamp(A.tune.fracSum / A.tune.fracN, 0.08, 0.45)
        end
    end
    if A.fires > pn.firesBefore then
        -- we did fire and still got hit: lead was too short
        C.parry.baseLead = math.clamp(C.parry.baseLead + 0.02, 0, 0.35)
        A.tune.adjusted = A.tune.adjusted + 1
        A.tune.last = ("hit -> lead +20ms (now %.0fms)"):format(C.parry.baseLead*1000)
    else
        A.tune.last = "hit but no parry fired (out of range?)"
    end
end

local function tuneResolve()
    local pn = A.tune.pending
    if not pn then return end
    if os.clock() - pn.t < (pn.len + 0.6) then return end
    A.tune.pending = nil
    if A.fires > pn.firesBefore then
        A.tune.clean = A.tune.clean + 1
        A.tune.streak = A.tune.streak + 1
        -- several clean parries in a row: inch the lead back down
        if A.tune.streak >= 5 and C.parry.baseLead > 0.02 then
            C.parry.baseLead = math.max(0.02, C.parry.baseLead - 0.005)
            A.tune.streak = 0
            A.tune.adjusted = A.tune.adjusted + 1
            A.tune.last = ("5 clean -> lead -5ms (now %.0fms)"):format(C.parry.baseLead*1000)
        else
            A.tune.last = ("clean parry (streak %d)"):format(A.tune.streak)
        end
    end
end

local tuneHealthConn
local function tuneBindChar(c)
    if tuneHealthConn then pcall(function() tuneHealthConn:Disconnect() end) end
    if not c then return end
    -- ParryWindow flips true while a parry is actually blocking: a direct
    -- observation that one landed, rather than inferring it from the absence
    -- of damage.
    table.insert(A.conns, c:GetAttributeChangedSignal("ParryWindow"):Connect(function()
        if c:GetAttribute("ParryWindow")==true then
            A.windows=(A.windows or 0)+1
            A.winOpen=os.clock()
        elseif A.winOpen then
            -- How long the parry actually stays active. The charge has to be
            -- parried BEFORE the grab lands, so the window must be OPEN at
            -- t=+0.67s, not merely sent by then. Measuring it beats guessing.
            local dur=os.clock()-A.winOpen
            A.winOpen=nil
            -- One sample is not a measurement. The hit-point tuner already
            -- proved that lurching on two readings is worse than a sane
            -- default, so require several and keep it inside plausible
            -- bounds before it is allowed to influence timing.
            if dur>0.05 and dur<1.5 then
                SH.winN=(SH.winN or 0)+1
                SH.winSum=(SH.winSum or 0)+dur
                if SH.winN>=3 then
                    SH.winDur=math.clamp(SH.winSum/SH.winN, 0.15, 2.00)
                end
            end
        end
    end))
    local hum = c:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local last = hum.Health
    tuneHealthConn = hum.HealthChanged:Connect(function(hp)
        if hp < last then tuneOnDamage() end
        last = hp
    end)
    table.insert(A.conns, tuneHealthConn)
end

-- Ping hurts twice: half delays the swing animation reaching us, half
-- delays our packet reaching the server. Both were unaccounted for, which
-- is harmless on a private server and ~57ms late on a public one.
-- Smoothed, so one noisy Data Ping sample cannot swing the lead. A.pingS
-- is what every timing decision uses; A.lastPing is only the raw reading.
-- A swing's hit lands ~hitFrac into a ~1.10s animation, and we only learn the
-- swing started one ping late, so the time left to act is (hitAt - ping).
-- baseLead is a safety cushion, not a requirement: when ping eats into the
-- budget, spend less cushion instead of giving up. Only when the budget is
-- gone entirely is reacting actually impossible.
local SWING=1.10
-- RushGrab lands 0.67s into a 2.67s RushStart: measured, not assumed.
local RUSH_FRAC=0.25
local function parryBudget()
    local png=(A.pingS or A.lastPing or 0)
    local slack=SWING*C.parry.hitFrac-png
    local lead=math.min(C.parry.baseLead, math.max(0,slack))
    return png, slack, lead end

local function effectiveOffset()
    if not C.parry.autoPing then return C.parry.offset end
    local png,_,lead=parryBudget()
    return -(lead+png) end

-- The killer currently in play, or nil.
local function killerModel()
    local PL=workspace:FindFirstChild("PLAYERS")
    local K=PL and PL:FindFirstChild("KILLER")
    if not K then return nil end
    for _,m in ipairs(K:GetChildren()) do
        if m:FindFirstChild("HumanoidRootPart") then return m end end
    return nil end

-- ParryCharges is reported for information ONLY -- it must never gate firing.
-- Blocking on it was a regression: the attribute sits at 0 during normal play
-- (the 0/3 counter in the HUD is Dodges, and the basic parry is cooldown
-- based, not charge based), so the block refused two real parries in a row
-- and the player was nearly killed. Observed: fires 1, skipped (no charge) 2,
-- activations 0, while detection itself was working perfectly.
-- The parry has a ~30s COOLDOWN. The ability slot exposes CDEndsAt, a
-- SERVER-clock timestamp, so it must be compared against
-- workspace:GetServerTimeNow() -- os.time() was 20.8s adrift here.
-- Without this the script fires into a dead cooldown: measured
-- "fires 7, activations 2", i.e. five parries thrown away.
local function parryCD()
    local pg=LP:FindFirstChild("PlayerGui")
    if not pg then return 0 end
    local ok,slot=pcall(function()
        return pg.UI.UI.GameUIContainer.Abilities.List
                 :FindFirstChild(tostring(C.parry.slot))
    end)
    if not ok or not slot then return 0 end
    local e=slot:GetAttribute("CDEndsAt")
    if type(e)~="number" then return 0 end
    return math.max(0, e-workspace:GetServerTimeNow())
end

local function parryCharges()
    local c=char() if not c then return 0 end
    local v=c:GetAttribute("ParryCharges")
    if type(v)~="number" then return 1 end   -- unknown: assume usable
    return v
end
A.noCharge=0
A.windows=0

local lastFire=0
local function doParry(delay,why)
    local now=os.clock()
    -- charge holds re-fire deliberately; the normal cooldown must not eat them
    local cdGap=(why=="charge-hold") and 0.5 or C.parry.cooldown
    if now-lastFire<cdGap then return end
    -- never throw a parry into its own cooldown
    local cd=parryCD()
    if cd>0.05 then
        A.onCD=(A.onCD or 0)+1
        A.lastMode=("on cooldown %.1fs (%s)"):format(cd, why or "?")
        return
    end
    if parryCharges()<=0 then A.noCharge=A.noCharge+1 end  -- noted, never blocking
    lastFire=now A.lastDelay=delay or 0
    local function go()
        if fireWire(C.parry.slot) then A.lastMode="wire ("..(why or "?")..")"
        else fireKey(C.parry.slot) A.lastMode="key ("..(why or "?")..")" end
        A.fires=A.fires+1
        SH.fireLog=SH.fireLog or {}
        SH.fireLog[#SH.fireLog+1]=("%8.2f PARRY SENT (%s)")
            :format(os.clock()%10000, why or "?")
        if #SH.fireLog>30 then table.remove(SH.fireLog,1) end
    end
    if (delay or 0)<=0 then go() else task.delay(delay,go) end end

-- Springtrap's attack set, read from RS.Characters:
--   Swing, AxelessSwing                     ordinary swings
--   SwingKill, SwingKillEnemy, SwingKillF,
--   SwingKill AXELESS, SwingKillLMS, ...    the swings that actually DOWN you
--   Rush, RushStart, RushGrab_Springtrap    the dash attack
--   FinalKick                               finisher
--
-- The old filter skipped anything containing "kill" and only matched
-- swing/slash/lunge, so it watched 2 of 9 attacks: every killing blow and the
-- whole Rush were invisible to it. Measured live as "fires 1" against three
-- hits. Parrying something unparryable only wastes a cooldown; missing a
-- killing blow is fatal, so the bias is now firmly towards over-triggering.
local ATTACK={}
local AMBIG={}
do
    local function classify(name)
        local n=name:lower()
        if n:find("door") then return nil end        -- DoorKick is not an attack
        if n:find("throw") then return "throw" end
        if n:find("rush") then
            if n:find("end") then return nil end     -- RushEnd is the recovery
            return "rush"
        end
        if n:find("swing") or n:find("slash") or n:find("lunge")
           or n:find("kick") or n:find("grab") then return "melee" end
        return nil
    end
    -- Some ids are REUSED for unrelated actions. Measured: TrapPlace and
    -- SwingKillF are both 124796142935734, so placing a trap is
    -- indistinguishable from a killing swing by id alone -- and it was making
    -- the parry fire every time he set a trap across the map. Any id that
    -- maps to both an attack and a non-attack is flagged ambiguous and gated
    -- on a much tighter range, where a real swing can actually reach.
    local chars=RS:FindFirstChild("Characters")
    if chars then
        local kinds={}
        for _,f in ipairs(chars:GetChildren()) do
            if f.Name~="Survivor" then
                for _,d in ipairs(f:GetDescendants()) do
                    if d:IsA("Animation") and d.AnimationId~="" then
                        local c=classify(d.Name)
                        local k=kinds[d.AnimationId]
                        if not k then k={} kinds[d.AnimationId]=k end
                        k[c or "none"]=true
                        if c then ATTACK[d.AnimationId]=c end
                    end
                end
            end
        end
        for id,k in pairs(kinds) do
            if k["none"] and (k["melee"] or k["rush"] or k["throw"]) then
                AMBIG[id]=true
            end
        end
    end
end
-- Animation TRACKS are named generically ("Animation") at runtime and the
-- ids the killer actually plays do not all appear in RS.Characters, so name
-- matching alone provably misses attacks: measured 18 hits, 18 undetected.
-- Ids learned from damage correlation are therefore merged in, and persist
-- across reloads.
SH.learnedAnims = SH.learnedAnims or {}
-- Ids confirmed by observation rather than by name. RS.Characters does not
-- list every animation the killer actually plays, and the learner's scores
-- live in the shared table, which a REJOIN WIPES -- so every rejoin used to
-- drop back to name-matching alone and go half-blind until it had been hit
-- enough times to re-learn. Anything proven here is hardcoded so it
-- survives.
--
-- 127676372189607: observed playing ONCE (not looped) at 1.09s, which is
-- the same length as Swing's 1.10s, and it had independently reached a
-- learner score of 2 against real damage before a rejoin cleared it.
ATTACK["rbxassetid://127676372189607"] = ATTACK["rbxassetid://127676372189607"] or "melee"

-- Promotion threshold lowered from 4 back to 3. It was raised to 4 because
-- locomotion animations were being credited for hits -- but looped tracks
-- are now rejected outright at the source, and locomotion is looped. Of 13
-- animations observed from a live killer, 11 were looped and excluded, so
-- the failure mode that justified 4 can no longer occur. Three keeps real
-- attacks arming quickly after a rejoin, which is when it matters most.
for id,score in pairs(SH.learnedAnims) do
    if score >= 3 then ATTACK[id] = ATTACK[id] or "melee" end
end

A.attackCount=0
for _ in pairs(ATTACK) do A.attackCount=A.attackCount+1 end

local function threatened(m,maxRange)
    local mr,kr=root(),m:FindFirstChild("HumanoidRootPart")
    if not mr or not kr then return false end
    local d=mr.Position-kr.Position local dist=d.Magnitude
    if dist>(maxRange or C.parry.range) then return false end
    if dist<0.1 then return true end
    return kr.CFrame.LookVector:Dot(d.Unit)>=0.15 end

-- Only the KILLER can hurt you, so only the killer's animations may fire a
-- parry. Without this the handler listened to every hooked model, teammates
-- included -- and animation ids are shared across characters in this game,
-- so a Fighter swinging their own axe nearby, or a door barricade reusing a
-- Springtrap asset, triggered a parry. Observed live: id 99629190661567
-- (Springtrap.Normal.Assets.SwingKill) firing while the actual killer was a
-- Mimic 39 studs away and three Survivor-Fighters stood next to us.
--
-- Mirrors amKiller()'s test, but for an arbitrary model: the KILLER folder
-- is authoritative when present, and the role attribute covers the window
-- before a character has been reparented into it.
local function isKillerModel(m)
    if not m then return false end
    if m.Parent and m.Parent.Name=="KILLER" then return true end
    local a=m:GetAttribute("Character")
    if type(a)=="string" and a~="" and not a:find("^Survivor") then return true end
    return false
end

local hooked=setmetatable({},{__mode="k"})
local function hookModel(m)
    if hooked[m] then return end
    local h=m:FindFirstChildOfClass("Humanoid")
    local an=h and h:FindFirstChildOfClass("Animator") if not an then return end
    hooked[m]=true
    table.insert(A.conns, an.AnimationPlayed:Connect(function(tr)
        if not C.parry.on or m==char() then return end
        -- a teammate's swing is not an attack on us
        if not isKillerModel(m) then
            A.ignoredFriendly=(A.ignoredFriendly or 0)+1
            return
        end
        local a2=tr and tr.Animation local id=a2 and a2.AnimationId
        -- remember what the killer played, so damage can be traced back to
        -- the animation that caused it
        -- Looped tracks are locomotion and idles. An attack plays once.
        -- A looping walk cycle is playing during *every* hit, so the damage
        -- learner would correlate it with everything and eventually promote
        -- it -- the one failure mode that turns walking into a parry.
        local looped=false
        pcall(function() looped=tr.Looped end)
        if id and m.Parent and m.Parent.Name=="KILLER" and not looped then
            local rl=A.recentAnims
            rl[#rl+1]={id=id, t=os.clock()}
            if #rl>24 then table.remove(rl,1) end
        end
        local kind=id and (not looped) and ATTACK[id] or nil
        if not kind and id and not looped then
            local sc=SH.learnedAnims[id]
            if sc and sc>=3 then kind="melee" end
        end
        if not kind then
            -- track what we are choosing to ignore, so a missed attack type
            -- shows up as a number instead of as a silent death
            A.ignoredAnims=(A.ignoredAnims or 0)+1
            return
        end
        if kind=="melee" then
            -- Margin on top of the user's range. Proof this matters: the
            -- learner logged Swing (73874961376513) as an "undetected" hit
            -- while that id was already classified as melee -- the animation
            -- was seen and then thrown away by the range gate, and the hit
            -- landed anyway. The swing reaches further than the range people
            -- set, and the killer closes distance during the windup. A parry
            -- fired needlessly costs one cooldown; one skipped costs a life.
            -- an id shared with a non-attack (e.g. TrapPlace) only counts
            -- when he is close enough for a real swing to land
            local reach=AMBIG[id] and (C.parry.range*0.7) or (C.parry.range+10)
            if not threatened(m, reach) then return end
            local len=0 pcall(function() len=tr.Length or 0 end)
            if len<=0 then len=1.10 end
            local dly=math.max(0,len*C.parry.hitFrac+effectiveOffset())
            tuneRecordSwing(len, dly)
            -- log WHICH animation fired it, so a false parry can be traced
            -- to an id instead of guessed at
            doParry(dly,"melee "..(tostring(id):match("%d+$") or "?"))
        elseif kind=="rush" then
            -- ARM ONLY. The grab is NOT a fixed offset from RushStart -- it
            -- happens on CONTACT. Captured from the victim side:
            --   RushStart 8981.47 -> Rush 8984.06 -> RushEnd 8988.20
            -- i.e. he dashed for 2.6s before reaching anyone, whereas the
            -- killer-side capture showed a 0.67s grab purely because he was
            -- already standing next to his target. Scheduling a parry at a
            -- fixed fraction therefore fires at a moment that does not exist.
            -- The closing-distance watcher below is what actually caught it.
            if not threatened(m,90) then return end
            A.rush={m=m, t=os.clock()}
            -- A charge is a straight-line dash and the killer is already
            -- facing whoever he is going for when RushStart plays, so the
            -- direction he is pointing says who it is for.
            --
            -- Without this check ANY charge within 90 studs fired a parry,
            -- including one aimed at a different survivor on the far side of
            -- the map (observed: killer 39 studs away, charging someone
            -- else). That is not just noise -- it burns the ability for ~25s,
            -- so a real charge at us moments later finds it on cooldown. The
            -- fallback parry costs the hits it is meant to stop.
            local aimed=false
            do
                local mr2,kr=root(), m:FindFirstChild("HumanoidRootPart")
                if mr2 and kr then
                    local toUs=mr2.Position-kr.Position
                    local d=toUs.Magnitude
                    if d>0 then
                        local ang=math.deg(math.acos(
                            math.clamp(kr.CFrame.LookVector:Dot(toUs.Unit),-1,1)))
                        aimed = (ang<=35) and (d<=45)
                        A.lastChargeAng=ang A.lastChargeDist=d
                    end
                end
            end
            if aimed then
                -- Fire IMMEDIATELY. Measured: a close charge crosses the
                -- trigger distance in a single frame and grabs 0.69s after
                -- RushStart, so waiting for distance fires 30ms before the
                -- grab - under one ping. The window is ~540ms, so opening it
                -- at RushStart covers a close charge outright.
                A.lastCharge=os.clock()
                doParry(0,"charge-hold")
                A.tune.last="charge aimed at us - window opened"
            else
                -- still tracked: the contact net below catches him if he
                -- changes his mind and comes for us instead
                A.tune.last=("charge aimed elsewhere (%.0f deg off) - watching only")
                    :format(A.lastChargeAng or -1)
            end
        elseif kind=="throw" then
            -- Same: the axe has to travel. Mark the windup so the projectile
            -- watcher knows an axe is coming and can accept it even if the
            -- part is not named recognisably.
            if not threatened(m,250) then return end
            A.throwWind=os.clock()
            A.tune.last="axe throw windup - watching for the axe"
        end end)) end

local projectiles={}
tuneBindChar(char())
table.insert(A.conns, LP.CharacterAdded:Connect(function(c)
    task.wait(0.4) tuneBindChar(c) end))
-- Hook every character as it spawns. The 2s sweep would get there
-- eventually, but a killer who swings inside that window is unparryable.
for _,pl in ipairs(Players:GetPlayers()) do
    if pl.Character then pcall(function() hookModel(pl.Character) end) end
    table.insert(A.conns, pl.CharacterAdded:Connect(function(c)
        task.wait(0.3) pcall(function() hookModel(c) end) end))
end
table.insert(A.conns, Players.PlayerAdded:Connect(function(pl)
    table.insert(A.conns, pl.CharacterAdded:Connect(function(c)
        task.wait(0.3) pcall(function() hookModel(c) end) end))
end))
table.insert(A.conns, workspace.DescendantAdded:Connect(function(d)
    if not C.parry.on or not d:IsA("BasePart") then return end
    local n=d.Name:lower()
    local named=(n:find("axe") or n:find("cleaver") or n:find("hatchet")
                 or n:find("knife") or n:find("projectile"))
    -- during a throw windup, take any loose part: the thrown axe is not
    -- guaranteed to be named anything recognisable
    local windup=A.throwWind and (os.clock()-A.throwWind)<2
    if not (named or windup) then return end
    local m=d:FindFirstAncestorOfClass("Model")
    if m and m:FindFirstChildOfClass("Humanoid") then return end
    projectiles[d]=os.clock() end))

----------------------------------------------------------------------
local genBusy=false
local function handedEvent()
    local pg=LP:FindFirstChild("PlayerGui") if not pg then return end
    for _,d in ipairs(pg:GetDescendants()) do
        if d:IsA("RemoteEvent") and d.Name=="Event" and d.Parent and d.Parent.Name=="GeneratorMain" then
            return d end end end
local function distTo(e)
    local mr=root() if not mr or not e.root then return math.huge end
    return (e.root.Position-mr.Position).Magnitude end
local function fixOne(e)
    ST.gensTries=ST.gensTries+1
    local prompt
    for _,d in ipairs(e.model:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled then prompt=d break end end
    -- No enabled prompt means the generator is not accepting anyone right
    -- now (another survivor is on it, or it is mid-reset). Firing the
    -- completion anyway just gets rejected and counts as our failure, so
    -- say so and let the caller move on.
    if not prompt then
        ST.genStatus="gen busy or not ready - no prompt"
        return false
    end
    if prompt and type(fireproximityprompt)=="function" then
        ST.genStatus="engaging gen "..tostring(e.model:GetAttribute("CurrentGen"))
        pcall(fireproximityprompt,prompt) end
    local t0=os.clock() local ev
    repeat ev=handedEvent() if ev then break end task.wait(0.1) until os.clock()-t0>2
    if C.gens.delay>0 then
        local w=0
        while w<C.gens.delay and C.gens.on do
            ST.genStatus=("working gen %s  %.1f/%.1fs"):format(
                tostring(e.model:GetAttribute("CurrentGen")),w,C.gens.delay)
            task.wait(0.1) w=w+0.1 end end
    if not C.gens.on then ST.genStatus="cancelled" return end
    pcall(function() (ev or e.ev):FireServer({Wires=true,Switches=true,Lever=true}) end)
    task.wait(0.35)
    if genDone(e) then ST.gensFixed=ST.gensFixed+1
        ST.genStatus="fixed gen "..tostring(e.model:GetAttribute("CurrentGen"))
    else ST.genStatus="rejected gen "..tostring(e.model:GetAttribute("CurrentGen")) end end
-- Teleport to the next unfinished generator once the ones in range are done.
-- Lands slightly above and beside the generator so we do not spawn inside it.
-- Forward declaration: genTick needs this but the definition sits with the
-- killer-side code further down. Without it the reference compiles as a nil
-- global and silently never fires.
local amKiller

local function tpToGen(e)
    local r=root()
    if not r or not e.root then return false end
    local target=e.root.Position
    local from=r.Position
    local away=(from-target)
    if away.Magnitude<1 then away=Vector3.new(1,0,0) end
    away=Vector3.new(away.X,0,away.Z)
    if away.Magnitude<0.1 then away=Vector3.new(1,0,0) end
    -- The Fix prompt has MaxActivationDistance = 5, so landing further than
    -- that engages nothing. 3 studs keeps us inside it without spawning
    -- inside the generator's own collision.
    local spot=target+away.Unit*3+Vector3.new(0,C.gens.tpHeight,0)
    local ok=pcall(function() r.CFrame=CFrame.new(spot,target) end)
    return ok
end

-- The server refuses generator completions under some conditions (the
-- player reports 5am on the clock, or too few people in the server). That is
-- a game rule, not a bug -- but retrying forever hammers the server and looks
-- obvious, so back off after repeated refusals and say why.
A.genReject=0
A.genPause=0
A.genCool={}   -- model -> os.clock() until which to skip it

local function genTick()
    if genBusy or not C.gens.on then return end
    -- Generators are the survivors' objective. As the killer this should do
    -- nothing at all -- teleporting to gens while playing Springtrap is both
    -- useless and extremely obvious.
    if amKiller and amKiller() then
        ST.genStatus="idle - you are the killer"
        return
    end
    -- Do nothing until a round is actually running. Joining a server used to
    -- teleport us straight away: the generator models exist in the lobby, so
    -- the list was non-empty and teleporting began before the match had even
    -- started. The character's own role attribute is the reliable signal --
    -- it reads Survivor-Lobby between rounds.
    do
        local me=char()
        local role=me and me:GetAttribute("Character")
        if type(role)~="string" or role=="" or role:find("Lobby") then
            ST.genStatus="idle - waiting for the round to start"
            return
        end
    end
    if os.clock()<(A.genPause or 0) then
        ST.genStatus=("server refusing fixes - retrying in %.0fs")
            :format((A.genPause or 0)-os.clock())
        return
    end
    genBusy=true
    task.spawn(function()
        -- genBusy MUST be cleared even if something in here throws. It used
        -- to be set before the spawn and cleared only on the last line, so
        -- any error inside left it true forever and auto-fix silently
        -- stopped working for the rest of the session -- the "sometimes it
        -- just doesn't do anything" case. pcall + a guaranteed reset.
        local ok,err=pcall(function()
        local now=os.clock()
        local list={}
        for _,e in ipairs(generators()) do
            if not genDone(e) then
                -- With teleporting on, distance stops being a filter: we go
                -- to the generator. Without it, only ones already close
                -- enough for the prompt are worth trying.
                if C.gens.tp or distTo(e)<=C.gens.range then list[#list+1]=e end
            end
        end
        -- Skip generators that just refused us. Without this the list is
        -- sorted purely by distance, and after teleporting to a generator
        -- we are STANDING on it -- so a generator that will not complete is
        -- the nearest one on every following tick and gets retried forever
        -- while the others are never touched. That is the "stuck on the
        -- same gen" behaviour.
        local ready,cooling={},{}
        for _,e in ipairs(list) do
            if (A.genCool[e.model] or 0) > now then cooling[#cooling+1]=e
            else ready[#ready+1]=e end
        end
        -- everything is cooling down: take the one that has been waiting
        -- longest rather than stalling completely
        if #ready==0 and #cooling>0 then
            table.sort(cooling,function(a2,b)
                return (A.genCool[a2.model] or 0) < (A.genCool[b.model] or 0) end)
            ready={cooling[1]}
        end
        list=ready
        table.sort(list,function(a2,b) return distTo(a2)<distTo(b) end)
        if #list==0 then
            ST.genStatus = C.gens.tp and "all generators done" or "no gen in range"
        end
        for _,e in ipairs(list) do
            if not C.gens.on then break end
            -- The prompt will not fire from further than 5 studs, which is
            -- what made this retry forever at 24 studs away.
            if distTo(e)>4 then
                if C.gens.tp then
                    ST.genStatus=("teleporting to gen (%.0f studs)"):format(distTo(e))
                    tpToGen(e)
                    task.wait(0.3)
                else
                    ST.genStatus=("gen %.0f studs away - too far for the prompt")
                        :format(distTo(e))
                end
            end
            -- Finish this generator before moving on. fixOne can be
            -- rejected (the server drops the completion if the prompt never
            -- handed over), and previously that just fell through to the
            -- next one, leaving a half-done generator behind.
            local attempts=0
            while C.gens.on and not genDone(e) and attempts<4 do
                if distTo(e)>4 then
                    if not C.gens.tp then break end
                    tpToGen(e) task.wait(0.25)
                end
                if distTo(e)>6 then break end
                attempts=attempts+1
                ST.genStatus=("fixing gen (try %d)"):format(attempts)
                fixOne(e)
                if not genDone(e) then task.wait(0.25) end
            end
            if genDone(e) then
                ST.genStatus="gen done, moving on"
                A.genReject=0
                A.genCool[e.model]=nil
            elseif attempts>=4 then
                A.genReject=A.genReject+1
                -- park THIS generator for 20s and go and do another one,
                -- instead of standing on it and retrying until the round ends
                A.genCool[e.model]=os.clock()+20
                ST.genStatus="gen refused - parked 20s, trying another"
                if A.genReject>=3 then
                    A.genPause=os.clock()+25
                    A.genReject=0
                    ST.genStatus="server is refusing fixes - paused 25s"
                    break
                end
            end
            task.wait(0.15)
        end
        end)
        genBusy=false
        if not ok then ST.genStatus="gen error: "..tostring(err) end
    end) end

----------------------------------------------------------------------
local function remember(inst,prop)
    A.saved[inst]=A.saved[inst] or {}
    if A.saved[inst][prop]==nil then A.saved[inst][prop]=inst[prop] end end
local function restoreWhere(fn)
    for inst,props in pairs(A.saved) do
        if inst and inst.Parent then
            for p,v in pairs(props) do
                if (not fn) or fn(inst) then pcall(function() inst[p]=v end) end end end end end
local function optParticles(off)
    if off then for _,d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
           or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("Beam") then
            remember(d,"Enabled") pcall(function() d.Enabled=false end) end end
    else restoreWhere(function(i) return i:IsA("ParticleEmitter") or i:IsA("Trail")
        or i:IsA("Smoke") or i:IsA("Fire") or i:IsA("Sparkles") or i:IsA("Beam") end) end end
local function optPostFX(off)
    if off then for _,d in ipairs(Lighting:GetDescendants()) do
        if d:IsA("BlurEffect") or d:IsA("ColorCorrectionEffect") or d:IsA("BloomEffect")
           or d:IsA("SunRaysEffect") or d:IsA("DepthOfFieldEffect") then
            remember(d,"Enabled") pcall(function() d.Enabled=false end) end end
    else restoreWhere(function(i) return i:IsA("BlurEffect") or i:IsA("ColorCorrectionEffect")
        or i:IsA("BloomEffect") or i:IsA("SunRaysEffect") or i:IsA("DepthOfFieldEffect") end) end end
local function optShadows(off)
    remember(Lighting,"GlobalShadows")
    if off then pcall(function() Lighting.GlobalShadows=false end)
    else restoreWhere(function(i) return i==Lighting end) end end
local function optTextures(off)
    if off then local n=0
        for _,d in ipairs(workspace:GetDescendants()) do
            if d:IsA("BasePart") then remember(d,"Material")
                pcall(function() d.Material=Enum.Material.SmoothPlastic end) n=n+1
            elseif d:IsA("Decal") or d:IsA("Texture") then remember(d,"Transparency")
                pcall(function() d.Transparency=1 end)
            elseif d:IsA("SurfaceAppearance") then remember(d,"Parent")
                pcall(function() d.Parent=nil end) end
            if n>20000 then break end end
    else restoreWhere(function(i) return i:IsA("BasePart") or i:IsA("Decal")
        or i:IsA("Texture") or i:IsA("SurfaceAppearance") end) end end
local function optTerrain(off)
    local t=workspace:FindFirstChildOfClass("Terrain") if not t then return end
    remember(t,"Decoration") remember(t,"WaterWaveSize")
    remember(t,"WaterWaveSpeed") remember(t,"WaterReflectance")
    if off then pcall(function() t.Decoration=false t.WaterWaveSize=0
        t.WaterWaveSpeed=0 t.WaterReflectance=0 end)
    else restoreWhere(function(i) return i:IsA("Terrain") end) end end
local function optLowQ(off)
    local s=settings()
    pcall(function()
        s.Rendering.QualityLevel = off and Enum.QualityLevel.Level01 or Enum.QualityLevel.Automatic
        s.Rendering.MeshPartDetailLevel = off and Enum.MeshPartDetailLevel.Level04
                                              or Enum.MeshPartDetailLevel.DistanceBased end) end
local OPTS={
    {key="particles",label="Disable Particles & Trails",fn=optParticles},
    {key="postfx",   label="Disable Post Processing",   fn=optPostFX},
    {key="shadows",  label="Disable Shadows",           fn=optShadows},
    {key="textures", label="Strip Textures & Materials",fn=optTextures},
    {key="terrain",  label="Flatten Terrain Detail",    fn=optTerrain},
    {key="lowq",     label="Force Lowest Quality",      fn=optLowQ}, }

----------------------------------------------------------------------
local R6={{"Head","Torso"},{"Torso","Left Arm"},{"Torso","Right Arm"},
          {"Torso","Left Leg"},{"Torso","Right Leg"}}
local espFolder=Instance.new("Folder")
espFolder.Name="BBD_ESP"
espFolder.Parent=(gethui and gethui()) or game:GetService("CoreGui")
A.espFolder=espFolder
local function classOf(m)
    local a2=m:GetAttribute("Character")
    if type(a2)~="string" then return nil end
    return a2:match("^Survivor%-(.+)$") or a2 end
local function newDraw(k,p)
    local o=Drawing.new(k) for a2,b in pairs(p or {}) do o[a2]=b end
    A.drawings[#A.drawings+1]=o return o end
local pool={}
local function getPool(m)
    local p=pool[m] if p then return p end
    p={hl=nil,
       box=newDraw("Square",{Thickness=1,Filled=false,Visible=false,ZIndex=2}),
       tracer=newDraw("Line",{Thickness=1,Visible=false,ZIndex=1}),
       name=newDraw("Text",{Size=14,Center=true,Outline=true,Visible=false,ZIndex=4}),
       sub=newDraw("Text",{Size=12,Center=true,Outline=true,Visible=false,ZIndex=4}),
       dist=newDraw("Text",{Size=12,Center=true,Outline=true,Visible=false,ZIndex=3}),
       hpbg=newDraw("Square",{Thickness=1,Filled=true,Visible=false,ZIndex=2,Color=Color3.fromRGB(18,18,18)}),
       hp=newDraw("Square",{Thickness=1,Filled=true,Visible=false,ZIndex=3}),
       bones={}}
    for i=1,#R6 do p.bones[i]=newDraw("Line",{Thickness=1,Visible=false,ZIndex=2}) end
    pool[m]=p return p end
local function ensureHL(p,m,col)
    if not p.hl or not p.hl.Parent then
        p.hl=Instance.new("Highlight")
        p.hl.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
        p.hl.OutlineTransparency=0 p.hl.Adornee=m p.hl.Parent=espFolder end
    p.hl.FillColor=col p.hl.OutlineColor=col:Lerp(Color3.new(1,1,1),0.5)
    p.hl.FillTransparency=C.esp.fillAlpha p.hl.Enabled=true end
local function hidePool(p)
    if p.hl then p.hl.Enabled=false end
    p.box.Visible=false p.tracer.Visible=false p.name.Visible=false
    p.sub.Visible=false p.dist.Visible=false p.hp.Visible=false p.hpbg.Visible=false
    for _,b in ipairs(p.bones) do b.Visible=false end end
-- Drawing objects are not reclaimed when the pool table that held them
-- is dropped: they stay alive in the render pipeline and in A.drawings.
-- Character models are replaced on every respawn and round transition,
-- so merely forgetting a pool leaked 12 live drawings per generation --
-- measured at 8688 drawings (724 generations) in one session, which is
-- what was costing frames.
local function releasePool(m)
    local p=pool[m] if not p then return end
    hidePool(p) if p.hl then pcall(function() p.hl:Destroy() end) p.hl=nil end
    local dead={}
    local function kill(o)
        if o then dead[o]=true pcall(function() o:Remove() end) end end
    kill(p.box) kill(p.tracer) kill(p.name) kill(p.sub) kill(p.dist)
    kill(p.hpbg) kill(p.hp)
    for _,b in ipairs(p.bones) do kill(b) end
    local keep={}
    for _,o in ipairs(A.drawings) do
        if not dead[o] then keep[#keep+1]=o end end
    A.drawings=keep
    pool[m]=nil end
local function espTargets()
    local l={} local PL=workspace:FindFirstChild("PLAYERS") if not PL then return l end
    local Al,K=PL:FindFirstChild("ALIVE"),PL:FindFirstChild("KILLER")
    if Al then for _,m in ipairs(Al:GetChildren()) do
        if m~=char() and m:FindFirstChild("HumanoidRootPart") then l[#l+1]={model=m,killer=false} end end end
    if K then for _,m in ipairs(K:GetChildren()) do
        if m~=char() and m:FindFirstChild("HumanoidRootPart") then l[#l+1]={model=m,killer=true} end end end
    return l end
local trapCache, trapAt = {}, 0
local function traps()
    if os.clock()-trapAt > 1 then
        trapCache = {}
        for _, t in ipairs(CS:GetTagged("TRAP")) do
            if t:IsDescendantOf(workspace) and t:IsA("Model") then
                local core = t:FindFirstChild("Core") or t:FindFirstChild("Trap")
                if core and core:IsA("BasePart") then
                    trapCache[#trapCache+1] = { model=t, root=core }
                end
            end
        end
        trapAt = os.clock()
    end
    return trapCache
end

-- Runs in RenderStepped, never inside the namecall hook, because
-- workspace:Raycast is itself a namecall, and running a namecall before
-- forwarding overwrites the engine's current namecall method.
-- The hook only reads the plain Vector3 this leaves behind.
--
-- Targets come from the player list rather than a folder: in the lobby
-- characters sit directly in Workspace, and only once a round starts do
-- they move under PLAYERS.ALIVE. Walking Players keeps this correct in
-- both states. When ALIVE is populated we additionally require
-- membership, so downed and escaped players stop being aimed at.
-- RespectCanCollide matters: GetPartsObscuringTarget counts decorative
-- non-collidable parts, and this map wraps everything in a Fog volume
-- that reads as cover for every target, so the open-ground test would
-- reject everyone. A collision-respecting ray only stops on real walls.
local aimRP=RaycastParams.new()
aimRP.FilterType=Enum.RaycastFilterType.Exclude
aimRP.RespectCanCollide=true
aimRP.IgnoreWater=true

-- Confirmed from a live capture of a throw that hit:
--   triple[1] = hit position, triple[2] = unit direction, triple[3] = origin
-- and [1] == [3] + [2]*distance to within 7e-6 studs.
--
-- The origin sits at roughly ground level by the thrower, NOT at the camera,
-- so line of sight is tested from there. Testing from the camera approved
-- targets that are actually blocked from where the axe leaves, which is why
-- swapped throws were missing.
-- Rebuilt from the LIVE camera every frame using the offset measured at the
-- last throw, so it tracks you while running instead of being pinned to
-- wherever you last threw from. The absolute point is never reused.
-- Silent aim only means anything as the killer. Left running as a survivor
-- it locked onto a TEAMMATE and repainted them with the red lock colour and
-- tracer, which is what made ESP look broken on the survivor side.
function amKiller()
    local c=char()
    if not c then return false end
    if c.Parent and c.Parent.Name=="KILLER" then return true end
    local a=c:GetAttribute("Character")
    if type(a)=="string" and not a:find("^Survivor") then return true end
    return false
end

local function throwOrigin(me)
    local cp=CAM.CFrame.Position
    local off=SH.originVsCam
    if off and off.Magnitude<30 then return cp+off end
    local r=me and me:FindFirstChild("HumanoidRootPart")
    if r then return r.Position+Vector3.new(0,2,0) end
    return cp
end

local function pickAimTarget() LPH_ATTRIBUTES(VM(NONE))
    -- the hook reads SH, never these locals, so publish on every frame
    SH.silent=C.killer.silent

    -- Calibrate the ray origin against the camera the moment a new one
    -- arrives. This is done here, per frame, rather than inside the handler
    -- wrapper: those wrappers are closures installed once into the game's
    -- registry and a reload does NOT replace them, so new code added to the
    -- wrapper body never runs until a rejoin. Reading the timestamp it
    -- already publishes works with whatever version is resident.
    local t=SH.lastOriginT or 0
    if A.seenOriginT==nil then
        -- Baseline only. Calibrating on the first frame would measure a
        -- STALE origin against the CURRENT camera and invent a bogus offset
        -- (measured 30.6 studs, which is nothing like a real rig offset).
        A.seenOriginT=t
    elseif SH.lastOrigin and t~=A.seenOriginT then
        A.seenOriginT=t
        local off=SH.lastOrigin-CAM.CFrame.Position
        -- a genuine origin sits on the camera, within a few studs
        if off.Magnitude<=8 then SH.originVsCam=off else SH.originVsCam=nil end
    end
    if not C.killer.silent or not amKiller() then
        A.aimPos=nil SH.aimPos=nil A.aimName="-" A.aimModel=nil A.aimCount=0
        A.lastGoodModel=nil
        return end
    local me=char()
    if not me then
        A.aimPos=nil SH.aimPos=nil A.aimName="-" A.aimModel=nil A.aimCount=0 return end

    local camPos=CAM.CFrame.Position
    local look=CAM.CFrame.LookVector
    local origin=throwOrigin(me)
    A.aimOrigin=origin

    -- Visibility is tested from YOUR BODY, not from the camera. In third
    -- person the camera orbits as you turn, so a camera-anchored ray starts
    -- somewhere different every time you look around and clips geometry that
    -- is not actually between you and the target -- which is why the lock
    -- dropped whenever you faced away. The body does not move when you turn,
    -- so visibility stays stable through a full spin.
    --
    -- This costs nothing in accuracy: the server does not re-cast the ray
    -- (proven -- a 70-stud swapped throw landed), so line of sight is our own
    -- "out in the open" rule, not something the server checks.
    local losOrigin=origin
    do
        local hd=me:FindFirstChild("Head")
        local hr=me:FindFirstChild("HumanoidRootPart")
        if hd then losOrigin=hd.Position
        elseif hr then losOrigin=hr.Position+Vector3.new(0,2,0) end
    end
    local PL=workspace:FindFirstChild("PLAYERS")
    local ALIVE=PL and PL:FindFirstChild("ALIVE")
    local gateAlive=(ALIVE and #ALIVE:GetChildren()>0) and ALIVE or nil

    local ignore={workspace:FindFirstChild("IGNORE"), PL, me}
    local cands={}
    for _,pl in ipairs(Players:GetPlayers()) do
        local m=pl.Character
        if m and m~=me then
            ignore[#ignore+1]=m
            local hrp=m:FindFirstChild("HumanoidRootPart")
            local hum=m:FindFirstChildOfClass("Humanoid")
            -- An explicitly chosen player wins over every scoring rule.
            -- Deliberately strict: if they are dead or gone we lock nothing
            -- rather than quietly switching to someone else, because a
            -- silent fallback is indistinguishable from the pick being
            -- ignored. The readout says so.
            local picked = (C.killer.lockTo=="" or C.killer.lockTo==pl.Name)
            if hrp and hum and hum.Health>0 and picked
               and (not gateAlive or m:IsDescendantOf(gateAlive)) then
                cands[#cands+1]={m=m,hrp=hrp,hum=hum,name=pl.Name}
            end
        end
    end
    aimRP.FilterDescendantsInstances=ignore

    -- Several aim points per target instead of one. A torso clipped by a
    -- crate corner used to reject the whole target even with the head and
    -- shoulders in plain view, so a survivor standing behind anything at all
    -- was unlockable. The first visible point wins, torso first because it
    -- is the most forgiving hitbox and the head is the smallest.
    local function visiblePoint(c)
        local root=c.hrp.Position
        local dir=root-losOrigin
        local hit=workspace:Raycast(losOrigin,dir,aimRP)
        if hit==nil then return root end
        -- A blocker in the first 40% of the path defeats every body point:
        -- the 2.6-stud vertical spread at the target subtends under a stud
        -- that close in, so the extra rays would all land in the same wall.
        -- Skipping them keeps the common case at one ray per target.
        local span=dir.Magnitude
        if span<=0 or (hit.Position-losOrigin).Magnitude < span*0.4 then return nil end
        -- Partial cover: a crate or a generator hiding the torso while the
        -- head and shoulders are in plain view. One point open is enough.
        local hd=c.m:FindFirstChild("Head")
        local pts=A.aimPts
        pts[1]=root+Vector3.new(0,1.3,0)
        pts[2]=hd and hd.Position or (root+Vector3.new(0,2.4,0))
        pts[3]=root-Vector3.new(0,1.3,0)
        for i=1,3 do
            local p=pts[i]
            if workspace:Raycast(losOrigin,p-losOrigin,aimRP)==nil then return p end
        end
        return nil
    end

    local best,bestScore,bestName,bestModel=nil,math.huge,"-",nil
    local anyB,anyScore,anyName,anyModel=nil,math.huge,"-",nil
    local seen=0
    local mode=C.killer.mode

    for _,c in ipairs(cands) do
        local aimAt=c.hrp.Position
        local dist=(aimAt-origin).Magnitude
        if dist>0 and dist<=C.killer.maxDist then
            local camD=aimAt-camPos
            local ang=(camD.Magnitude>0)
                and math.deg(math.acos(math.clamp(look:Dot(camD.Unit),-1,1))) or 0
            if ang<=C.killer.fov then
                local clear=true
                if C.killer.los then
                    local p=visiblePoint(c)
                    if p then aimAt=p else clear=false end
                end
                -- Scores are normalised to 0..1 so each priority compares
                -- like with like instead of mixing degrees against studs.
                local score
                if mode=="distance" then
                    score=dist/math.max(C.killer.maxDist,1)
                elseif mode=="health" then
                    score=c.hum.Health/math.max(c.hum.MaxHealth,1)
                else
                    score=ang/math.max(C.killer.fov,1)
                end
                if score<anyScore then
                    anyScore=score anyB=aimAt anyName=c.name anyModel=c.m end
                if clear then
                    seen=seen+1
                    -- Hysteresis. The target already held keeps a 15% edge,
                    -- so two survivors at a similar angle stop trading the
                    -- lock every frame -- that flicker is what put the axe on
                    -- the wrong one at the instant of the throw.
                    local eff=score
                    if A.aimModel==c.m then eff=score*0.85 end
                    if eff<bestScore then
                        bestScore=eff best=aimAt bestName=c.name bestModel=c.m end
                end
            end
        end
    end

    if not best and C.killer.never and anyB then
        best,bestName,bestModel=anyB,anyName.." (thru cover)",anyModel
    end

    -- NO PREDICTIVE LEAD, deliberately. Measured on a live hit: 196ms of
    -- round trip and a 109.7-stud flight, and the server still resolved the
    -- damage from the position we sent. Leading a moving target aims at
    -- empty ground and CAUSES the misses it is meant to fix. Do not add it.
    if best then
        A.aimPos=best SH.aimPos=best A.aimName=bestName SH.aimName=bestName
        A.aimModel=bestModel A.aimCount=seen
        A.lastGood=os.clock() A.lastGoodName=bestName A.lastGoodModel=bestModel
    elseif A.lastGoodModel and (os.clock()-(A.lastGood or 0))<=C.killer.sticky then
        -- follow the held target's CURRENT position, not where it was when the
        -- lock was last clean, otherwise the axe is aimed at a stale point
        local hrp=A.lastGoodModel:FindFirstChild("HumanoidRootPart")
        local hum=A.lastGoodModel:FindFirstChildOfClass("Humanoid")
        -- A held target still has to be reachable. Holding a lock on someone
        -- who has run behind a wall throws the axe into the wall.
        local reach=true
        if hrp and C.killer.los and not C.killer.never then
            reach=(workspace:Raycast(losOrigin,hrp.Position-losOrigin,aimRP)==nil)
        end
        if hrp and hum and hum.Health>0 and reach then
            A.aimPos=hrp.Position SH.aimPos=hrp.Position
            A.aimName=A.lastGoodName.." (held)" SH.aimName=A.lastGoodName
            A.aimModel=A.lastGoodModel A.aimCount=seen
        else
            A.aimPos=nil SH.aimPos=nil A.aimName="-" A.aimModel=nil A.aimCount=seen
        end
    else
        A.aimPos=nil SH.aimPos=nil A.aimName="-" A.aimModel=nil A.aimCount=seen
    end
end

-- ---- stay behind the target (killer only) ---------------------------
-- Puts you just behind a survivor's back so a swing connects. It reuses the
-- silent-aim lock when there is one, so the crosshair, the lock line and
-- this all agree on who the target is, and falls back to the nearest living
-- survivor otherwise.
local behindLast=0
local function behindTick() LPH_ATTRIBUTES(VM(NONE))
    if A.stopped or not C.behind.on then return end
    -- Killer only, and never in the lobby: teleporting around as a survivor
    -- is pointless, and doing it between rounds is what made the generator
    -- teleport so obvious when it had no round gate.
    if not amKiller() then return end
    local me=char()
    local mr=me and me:FindFirstChild("HumanoidRootPart")
    if not mr then return end
    local role=me:GetAttribute("Character")
    if type(role)~="string" or role=="" or role:find("Lobby") then return end

    local now=os.clock()
    if now-behindLast < math.max(0.1,C.behind.rate) then return end

    -- prefer whoever silent aim is already holding
    local m=A.aimModel
    local hrp=m and m.Parent and m:FindFirstChild("HumanoidRootPart")
    local hum=m and m:FindFirstChildOfClass("Humanoid")
    if not (hrp and hum and hum.Health>0) then
        m,hrp,hum=nil,nil,nil
        local best=math.huge
        local PL=workspace:FindFirstChild("PLAYERS")
        local ALIVE=PL and PL:FindFirstChild("ALIVE")
        for _,pl in ipairs(Players:GetPlayers()) do
            local cm=pl.Character
            if cm and cm~=me then
                local r=cm:FindFirstChild("HumanoidRootPart")
                local h=cm:FindFirstChildOfClass("Humanoid")
                if r and h and h.Health>0
                   and (not ALIVE or cm:IsDescendantOf(ALIVE)) then
                    local d=(r.Position-mr.Position).Magnitude
                    if d<best then best=d m,hrp,hum=cm,r,h end
                end
            end
        end
    end
    if not hrp then return end

    local gap=(hrp.Position-mr.Position).Magnitude
    if gap>C.behind.maxDist then return end
    -- already behind them and in range: leave it alone rather than
    -- re-teleporting every tick, which looks far worse than it plays
    if gap<=C.behind.dist+1.5 then
        local toMe=mr.Position-hrp.Position
        if toMe.Magnitude>0 and hrp.CFrame.LookVector:Dot(toMe.Unit)<-0.4 then
            behindLast=now
            A.behindName=hrp.Parent and hrp.Parent.Name or "?"
            return
        end
    end

    behindLast=now
    -- Behind means behind THEIR facing, not ours, and at their own height so
    -- we do not land in the floor or hanging in the air above them.
    local spot=hrp.Position - hrp.CFrame.LookVector*math.max(1,C.behind.dist)
    local ok=pcall(function()
        if C.behind.faceThem then
            mr.CFrame=CFrame.new(spot, hrp.Position)
        else
            mr.CFrame=CFrame.new(spot) * (mr.CFrame-mr.CFrame.Position)
        end
    end)
    if ok then
        A.behindCount=(A.behindCount or 0)+1
        A.behindName=hrp.Parent and hrp.Parent.Name or "?"
    end
end
A.behindTick=behindTick

local function rigAnchors(m,hrp)
    local ok,cf,size=pcall(function() return m:GetBoundingBox() end)
    if ok and size and size.Y>0 then
        return cf.Position+Vector3.new(0,size.Y*0.5+0.6,0),
               cf.Position-Vector3.new(0,size.Y*0.5,0) end
    return hrp.Position+Vector3.new(0,3,0), hrp.Position-Vector3.new(0,3.2,0) end

-- The silent-aim lock is invisible otherwise: you cannot tell who the throw
-- will be redirected to until after it has gone. The locked target is drawn
-- in red with its tracer forced on, regardless of the tracer toggle.
local LOCKCOL=Color3.fromRGB(255,45,45)

local function drawESP() LPH_ATTRIBUTES(VM(NONE))
    local seen={}
    if not C.esp.on then for m in pairs(pool) do releasePool(m) end return end
    local mr=root() local vp=CAM.ViewportSize
    for _,t in ipairs(espTargets()) do
        local m=t.model seen[m]=true local p=getPool(m)
        local hrp=m:FindFirstChild("HumanoidRootPart")
        local locked=(C.killer.silent and A.aimModel~=nil and m==A.aimModel)
        if locked and not amKiller() then locked=false end
        local col=locked and LOCKCOL
                  or (t.killer and C.theme.killer or C.theme.survivor)
        if not hrp then hidePool(p) else
            local dist=mr and (hrp.Position-mr.Position).Magnitude or 0
            if dist>C.esp.maxDist then hidePool(p) else
                if C.esp.highlight then ensureHL(p,m,col) elseif p.hl then p.hl.Enabled=false end
                local topW,botW=rigAnchors(m,hrp)
                local topV,onTop=CAM:WorldToViewportPoint(topW)
                local botV=CAM:WorldToViewportPoint(botW)
                if not onTop then
                    p.box.Visible=false p.tracer.Visible=false p.name.Visible=false
                    p.sub.Visible=false p.dist.Visible=false p.hp.Visible=false p.hpbg.Visible=false
                    for _,b in ipairs(p.bones) do b.Visible=false end
                else
                    local h=math.abs(botV.Y-topV.Y) local w=h*0.48
                    local x,y=topV.X-w/2,topV.Y
                    if C.esp.boxes then p.box.Color=col p.box.Position=Vector2.new(x,y)
                        p.box.Size=Vector2.new(w,h) p.box.Visible=true else p.box.Visible=false end
                    -- A lock no longer forces a tracer on. It used to draw
                    -- one from the bottom of the screen even with ESP
                    -- Tracers switched off, which is the red line that ran
                    -- up the middle of the screen whenever silent aim held
                    -- someone. The blue lock line shows the same thing from
                    -- the crosshair, so this was just a second, louder copy.
                    -- Tracers now obey the ESP toggle and nothing else.
                    if C.esp.tracers then
                        p.tracer.Color=col
                        p.tracer.Thickness=1
                        p.tracer.From=Vector2.new(vp.X/2,vp.Y)
                        p.tracer.To=Vector2.new(botV.X,botV.Y)
                        p.tracer.Visible=true
                    else p.tracer.Visible=false end
                    local cls=classOf(m)
                    if C.esp.names then p.name.Color=col
                        p.name.Text=locked and (m.Name.."  [LOCKED]") or m.Name
                        p.name.Position=Vector2.new(topV.X,y-30) p.name.Visible=true
                    else p.name.Visible=false end
                    if C.esp.class and cls then
                        p.sub.Color=t.killer and C.theme.killer or Color3.fromRGB(215,215,225)
                        p.sub.Text=t.killer and ("KILLER  "..cls) or cls
                        p.sub.Position=Vector2.new(topV.X,y-16) p.sub.Visible=true
                    else p.sub.Visible=false end
                    if C.esp.distance then p.dist.Color=Color3.fromRGB(190,190,200)
                        p.dist.Text=("%dm"):format(math.floor(dist))
                        p.dist.Position=Vector2.new(topV.X,y+h+2) p.dist.Visible=true
                    else p.dist.Visible=false end
                    local hum=m:FindFirstChildOfClass("Humanoid")
                    if C.esp.health and hum and hum.MaxHealth>0 then
                        local f=math.clamp(hum.Health/hum.MaxHealth,0,1)
                        p.hpbg.Position=Vector2.new(x-6,y) p.hpbg.Size=Vector2.new(3,h) p.hpbg.Visible=true
                        p.hp.Color=Color3.fromRGB(255*(1-f),255*f,60)
                        p.hp.Position=Vector2.new(x-6,y+h*(1-f))
                        p.hp.Size=Vector2.new(3,h*f) p.hp.Visible=true
                    else p.hp.Visible=false p.hpbg.Visible=false end
                    if C.esp.skeleton then
                        for i,pr in ipairs(R6) do
                            local a2,b=m:FindFirstChild(pr[1]),m:FindFirstChild(pr[2]) local ln=p.bones[i]
                            if a2 and b then
                                local av,aOn=CAM:WorldToViewportPoint(a2.Position)
                                local bv,bOn=CAM:WorldToViewportPoint(b.Position)
                                if aOn and bOn then ln.Color=col
                                    ln.From=Vector2.new(av.X,av.Y) ln.To=Vector2.new(bv.X,bv.Y)
                                    ln.Visible=true else ln.Visible=false end
                            else ln.Visible=false end end
                    else for _,b in ipairs(p.bones) do b.Visible=false end end
                end end end end
    if C.esp.gens then
        for _,e in ipairs(generators()) do
            local m=e.model seen[m]=true local p=getPool(m)
            if not e.root then hidePool(p) else
                local dist=mr and (e.root.Position-mr.Position).Magnitude or 0
                local done=genDone(e)
                local col=done and Color3.fromRGB(105,105,105) or C.theme.gen
                if dist>C.esp.maxDist then hidePool(p) else
                    if C.esp.highlight then ensureHL(p,m,col) elseif p.hl then p.hl.Enabled=false end
                    local v,on=CAM:WorldToViewportPoint(e.root.Position+Vector3.new(0,3,0))
                    if on then
                        p.name.Color=col
                        p.name.Text=("GEN %s"):format(tostring(m:GetAttribute("CurrentGen") or "?"))
                        p.name.Position=Vector2.new(v.X,v.Y-14) p.name.Visible=true
                        p.sub.Color=col
                        p.sub.Text=done and "FIXED" or ("%d%%"):format(math.floor(m:GetAttribute("Progress") or 0))
                        p.sub.Position=Vector2.new(v.X,v.Y) p.sub.Visible=true
                        p.dist.Color=Color3.fromRGB(190,190,200)
                        p.dist.Text=("%dm"):format(math.floor(dist))
                        p.dist.Position=Vector2.new(v.X,v.Y+14) p.dist.Visible=true
                    else p.name.Visible=false p.sub.Visible=false p.dist.Visible=false end
                    p.box.Visible=false p.tracer.Visible=false
                    p.hp.Visible=false p.hpbg.Visible=false
                    for _,b in ipairs(p.bones) do b.Visible=false end end end end end
    if C.esp.traps then
        for _,e in ipairs(traps()) do
            local m=e.model seen[m]=true local p=getPool(m)
            local dist=mr and (e.root.Position-mr.Position).Magnitude or 0
            if dist>C.esp.maxDist then hidePool(p) else
                local col=C.theme.trap
                if C.esp.highlight then ensureHL(p,m,col) elseif p.hl then p.hl.Enabled=false end
                local v,on=CAM:WorldToViewportPoint(e.root.Position+Vector3.new(0,2.2,0))
                if on then
                    p.name.Color=col p.name.Text="TRAP"
                    p.name.Position=Vector2.new(v.X,v.Y-14) p.name.Visible=true
                    local hp=m:GetAttribute("HP")
                    p.sub.Color=col
                    p.sub.Text=hp and ("HP %d"):format(hp) or "armed"
                    p.sub.Position=Vector2.new(v.X,v.Y) p.sub.Visible=true
                    if C.esp.distance then
                        p.dist.Color=Color3.fromRGB(190,190,200)
                        p.dist.Text=("%dm"):format(math.floor(dist))
                        p.dist.Position=Vector2.new(v.X,v.Y+14) p.dist.Visible=true
                    else p.dist.Visible=false end
                else p.name.Visible=false p.sub.Visible=false p.dist.Visible=false end
                p.box.Visible=false p.tracer.Visible=false
                p.hp.Visible=false p.hpbg.Visible=false
                for _,b in ipairs(p.bones) do b.Visible=false end
            end end end
    for m in pairs(pool) do if not seen[m] or not m.Parent then releasePool(m) end end end

----------------------------------------------------------------------
----------------------------------------------------------------------
-- UI layer. Rebuilt from scratch: sidebar shell, Roboto throughout.
-- Every factory below keeps the exact signature the old one had, so all
-- tab-content code calls it unchanged and no game logic moved.
----------------------------------------------------------------------
local TweenService=game:GetService("TweenService")

local BG    = Color3.fromRGB(14,14,18)
local PANE  = Color3.fromRGB(23,23,29)
local PANE2 = Color3.fromRGB(31,31,39)
local RAIL  = Color3.fromRGB(18,18,23)
local TXT   = Color3.fromRGB(236,236,241)
local DIM   = Color3.fromRGB(138,138,152)
local FAINT = Color3.fromRGB(44,44,54)

-- Roboto ships with Roblox, so nothing is downloaded. Real weights give
-- typographic hierarchy instead of one face at three sizes.
local function roboto(w)
    return Font.new("rbxasset://fonts/families/Roboto.json",
                    w or Enum.FontWeight.Regular)
end
local function robotoMono(w)
    return Font.new("rbxasset://fonts/families/RobotoMono.json",
                    w or Enum.FontWeight.Regular)
end
local F_TITLE = roboto(Enum.FontWeight.Bold)
local F_TAB   = roboto(Enum.FontWeight.Medium)
local F_LABEL = roboto(Enum.FontWeight.Regular)
local F_VALUE = roboto(Enum.FontWeight.Medium)
local F_MONO  = robotoMono(Enum.FontWeight.Regular)

local function corner(o,r)
    local c=Instance.new("UICorner") c.CornerRadius=UDim.new(0,r or 6) c.Parent=o return c
end
local function tween(o,t,props)
    TweenService:Create(o,TweenInfo.new(t,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),props):Play()
end

local gui=Instance.new("ScreenGui")
gui.Name="BBD" gui.ResetOnSpawn=false gui.IgnoreGuiInset=true
gui.ZIndexBehavior=Enum.ZIndexBehavior.Global gui.DisplayOrder=99999
gui.Parent=(gethui and gethui()) or LP:WaitForChild("PlayerGui")
A.gui=gui

local MENU_HOME=UDim2.new(0.5,0,0.5,0)
local win=Instance.new("Frame")
win.Size=UDim2.fromOffset(528,436)
-- Dead centre of the screen, for every user on every load. AnchorPoint
-- rather than a hand-computed offset, so it stays centred at any resolution
-- and as the UI Scale slider changes the window's size. The position is
-- deliberately never saved: the menu belongs in the same place every time.
win.AnchorPoint=Vector2.new(0.5,0.5)
win.Position=MENU_HOME
win.BackgroundColor3=BG win.BorderSizePixel=0
win.Active=true win.Draggable=true win.Parent=gui corner(win,12)
A.win=win
local uiScale=Instance.new("UIScale") uiScale.Parent=win

local winStroke=Instance.new("UIStroke")
winStroke.Color=C.theme.accent winStroke.Transparency=0.62
winStroke.Thickness=1 winStroke.Parent=win

local bgImage=Instance.new("ImageLabel")
bgImage.Name="ThemeBG" bgImage.Size=UDim2.new(1,0,1,0)
bgImage.BackgroundTransparency=1 bgImage.ScaleType=Enum.ScaleType.Crop
bgImage.ZIndex=0 bgImage.Image="" bgImage.Parent=win corner(bgImage,12)

-- header --------------------------------------------------------------
-- scoped: Lua allows only 200 locals per chunk and these are never
-- referenced again once built
do
local header=Instance.new("Frame")
header.Size=UDim2.new(1,0,0,46) header.BackgroundTransparency=1
header.ZIndex=2 header.Parent=win

local dot=Instance.new("Frame")
dot.Size=UDim2.fromOffset(6,6) dot.Position=UDim2.fromOffset(18,20)
dot.BackgroundColor3=C.theme.accent dot.BorderSizePixel=0 dot.ZIndex=3
dot.Parent=header corner(dot,3)

local title=Instance.new("TextLabel")
title.Size=UDim2.new(0,300,0,20) title.Position=UDim2.fromOffset(32,13)
title.BackgroundTransparency=1 title.FontFace=F_TITLE title.TextSize=15
title.TextColor3=TXT title.Text="CRUSADER HUB" title.ZIndex=3
title.TextXAlignment=Enum.TextXAlignment.Left title.Parent=header

-- a slow sheen that travels across the wordmark. Subtle on purpose: it
-- should read as polish, not as a screensaver.
local sheen=Instance.new("UIGradient")
sheen.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0.00,TXT),
    ColorSequenceKeypoint.new(0.42,TXT),
    ColorSequenceKeypoint.new(0.50,C.theme.accent),
    ColorSequenceKeypoint.new(0.58,TXT),
    ColorSequenceKeypoint.new(1.00,TXT)})
sheen.Offset=Vector2.new(-1,0)
sheen.Parent=title
task.spawn(function()
    while title.Parent and not A.stopped do
        sheen.Color=ColorSequence.new({
            ColorSequenceKeypoint.new(0.00,TXT),
            ColorSequenceKeypoint.new(0.42,TXT),
            ColorSequenceKeypoint.new(0.50,C.theme.accent),
            ColorSequenceKeypoint.new(0.58,TXT),
            ColorSequenceKeypoint.new(1.00,TXT)})
        sheen.Offset=Vector2.new(-1,0)
        TweenService:Create(sheen,TweenInfo.new(1.6,Enum.EasingStyle.Sine),
            {Offset=Vector2.new(1,0)}):Play()
        task.wait(5.5)
    end
end)

-- the status dot breathes, so you can tell at a glance the script is alive
task.spawn(function()
    while dot.Parent and not A.stopped do
        TweenService:Create(dot,TweenInfo.new(1.1,Enum.EasingStyle.Sine),
            {BackgroundTransparency=0.55}):Play()
        task.wait(1.2)
        TweenService:Create(dot,TweenInfo.new(1.1,Enum.EasingStyle.Sine),
            {BackgroundTransparency=0}):Play()
        task.wait(1.2)
    end
end)

local hdrLine=Instance.new("Frame")
hdrLine.Size=UDim2.new(1,0,0,1) hdrLine.Position=UDim2.fromOffset(0,46)
hdrLine.BackgroundColor3=FAINT hdrLine.BorderSizePixel=0 hdrLine.ZIndex=2
hdrLine.Parent=win
end

-- repaintAll tints this; kept so that contract still holds
local glow=Instance.new("Frame")
glow.Size=UDim2.new(0,0,0,0) glow.BackgroundTransparency=1
glow.BorderSizePixel=0 glow.Parent=win

-- sidebar --------------------------------------------------------------
local RAILW=124
local rail=Instance.new("Frame")
rail.Size=UDim2.new(0,RAILW,1,-47) rail.Position=UDim2.fromOffset(0,47)
rail.BackgroundColor3=RAIL rail.BorderSizePixel=0 rail.ZIndex=2 rail.Parent=win
corner(rail,12)
-- square the inner edge so the rail meets the content area cleanly
local railPatch=Instance.new("Frame")
railPatch.Size=UDim2.new(0,14,1,0) railPatch.Position=UDim2.new(1,-14,0,0)
railPatch.BackgroundColor3=RAIL railPatch.BorderSizePixel=0 railPatch.ZIndex=2
railPatch.Parent=rail

do  -- divider only; nothing refers to it afterwards
local railLine=Instance.new("Frame")
railLine.Size=UDim2.new(0,1,1,0) railLine.Position=UDim2.new(1,-1,0,0)
railLine.BackgroundColor3=FAINT railLine.BorderSizePixel=0 railLine.ZIndex=3
railLine.Parent=rail
end

-- railList must stay in scope: addTab parents tabs into it and the profile
-- card resizes it to make room
local railList=Instance.new("Frame")
railList.Size=UDim2.new(1,0,1,-12) railList.Position=UDim2.fromOffset(0,10)
railList.BackgroundTransparency=1 railList.ZIndex=3 railList.Parent=rail
do
local rl=Instance.new("UIListLayout") rl.Padding=UDim.new(0,2)
rl.SortOrder=Enum.SortOrder.LayoutOrder rl.Parent=railList
end

local pages,tabs,current={},{},nil
local tabOrder=0

local function selectTab(n)
    current=n
    for k,pg in pairs(pages) do pg.Visible=(k==n) end
    for k,t in pairs(tabs) do
        local on=(k==n)
        t.bar.BackgroundColor3=C.theme.accent
        tween(t.bar,0.12,{BackgroundTransparency=on and 0 or 1})
        tween(t.btn,0.12,{BackgroundTransparency=on and 0 or 1})
        tween(t.lbl,0.12,{TextColor3=on and TXT or DIM})
        t.lbl.FontFace = on and F_TAB or F_LABEL
    end
end

local function addTab(name,_)
    tabOrder=tabOrder+1
    local btn=Instance.new("TextButton")
    btn.Size=UDim2.new(1,-12,0,32) btn.BackgroundColor3=PANE2
    btn.BackgroundTransparency=1 btn.BorderSizePixel=0
    btn.AutoButtonColor=false btn.Text="" btn.ZIndex=3
    btn.LayoutOrder=tabOrder btn.Parent=railList corner(btn,7)

    local bar=Instance.new("Frame")
    bar.Size=UDim2.fromOffset(3,16) bar.Position=UDim2.new(0,0,0.5,-8)
    bar.BackgroundColor3=C.theme.accent bar.BackgroundTransparency=1
    bar.BorderSizePixel=0 bar.ZIndex=4 bar.Parent=btn corner(bar,2)

    local lbl=Instance.new("TextLabel")
    lbl.Size=UDim2.new(1,-18,1,0) lbl.Position=UDim2.fromOffset(14,0)
    lbl.BackgroundTransparency=1 lbl.FontFace=F_LABEL lbl.TextSize=12.5
    lbl.TextColor3=DIM lbl.Text=name lbl.ZIndex=4
    lbl.TextXAlignment=Enum.TextXAlignment.Left lbl.Parent=btn

    btn.MouseEnter:Connect(function()
        if current~=name then tween(btn,0.1,{BackgroundTransparency=0.55}) end end)
    btn.MouseLeave:Connect(function()
        if current~=name then tween(btn,0.1,{BackgroundTransparency=1}) end end)

    local pg=Instance.new("ScrollingFrame")
    pg.Size=UDim2.new(1,-RAILW-20,1,-60) pg.Position=UDim2.fromOffset(RAILW+12,56)
    pg.BackgroundTransparency=1 pg.BorderSizePixel=0 pg.Visible=false pg.ZIndex=2
    pg.ScrollBarThickness=2 pg.ScrollBarImageColor3=C.theme.accent
    pg.CanvasSize=UDim2.new(0,0,0,0) pg.AutomaticCanvasSize=Enum.AutomaticSize.Y
    pg.Parent=win
    local l=Instance.new("UIListLayout") l.Padding=UDim.new(0,6)
    l.SortOrder=Enum.SortOrder.LayoutOrder l.Parent=pg

    pages[name]=pg tabs[name]={btn=btn,lbl=lbl,bar=bar}
    btn.MouseButton1Click:Connect(function() selectTab(name) end)
    return pg
end

A.panels={}
local function panel(o) A.panels[#A.panels+1]=o return o end

local function applyGlass()
    -- See-through panels are now a slider rather than a fixed 0.45, and no
    -- longer require a wallpaper to be set -- without a wallpaper they let
    -- the game itself show through, which is the point of a theme.
    local t = C.theme.glass and math.clamp(C.theme.panel or 0.45, 0, 0.95) or 0
    for _,o in ipairs(A.panels) do
        if o and o.Parent then o.BackgroundTransparency = t end end
    bgImage.ImageTransparency = C.theme.wall
    -- The window and sidebar stay more solid than the rows: at matching
    -- transparency the text loses its backing and becomes unreadable over a
    -- bright wallpaper.
    win.BackgroundTransparency  = t*0.30
    rail.BackgroundTransparency = t*0.80
    railPatch.BackgroundTransparency = rail.BackgroundTransparency
end
A.applyGlass = applyGlass

local ord=0 local function nextOrd() ord=ord+1 return ord end

-- every control sits on the same row shell, which is what makes the
-- spacing read as deliberate rather than arbitrary
local function row(page,h)
    local f=Instance.new("Frame")
    f.Size=UDim2.new(1,-2,0,h) f.BackgroundColor3=PANE f.BorderSizePixel=0
    f.ZIndex=2 f.LayoutOrder=nextOrd() f.Parent=page
    corner(f,8) panel(f)
    return f
end

local function mkToggle(page,label,get,set)
    local f=row(page,38)
    local btn=Instance.new("TextButton")
    btn.Size=UDim2.new(1,0,1,0) btn.BackgroundTransparency=1
    btn.Text="" btn.AutoButtonColor=false btn.ZIndex=3 btn.Parent=f

    local lbl=Instance.new("TextLabel")
    lbl.Size=UDim2.new(1,-74,1,0) lbl.Position=UDim2.fromOffset(14,0)
    lbl.BackgroundTransparency=1 lbl.FontFace=F_LABEL lbl.TextSize=12.5
    lbl.TextColor3=TXT lbl.Text=label lbl.ZIndex=4
    lbl.TextXAlignment=Enum.TextXAlignment.Left
    lbl.TextTruncate=Enum.TextTruncate.AtEnd lbl.Parent=btn

    local track=Instance.new("Frame")
    track.Size=UDim2.fromOffset(38,20) track.Position=UDim2.new(1,-52,0.5,-10)
    track.BackgroundColor3=Color3.fromRGB(52,52,62) track.BorderSizePixel=0
    track.ZIndex=4 track.Parent=btn corner(track,10)

    local knob=Instance.new("Frame")
    knob.Size=UDim2.fromOffset(14,14) knob.Position=UDim2.fromOffset(3,3)
    knob.BackgroundColor3=Color3.fromRGB(150,150,162) knob.BorderSizePixel=0
    knob.ZIndex=5 knob.Parent=track corner(knob,7)

    local function paint()
        local on=get() and true or false
        f:SetAttribute("ToggleOn",on)
        tween(track,0.14,{BackgroundColor3 = on and C.theme.accent or Color3.fromRGB(52,52,62)})
        tween(knob,0.14,{Position = on and UDim2.fromOffset(21,3) or UDim2.fromOffset(3,3),
                         BackgroundColor3 = on and Color3.fromRGB(16,20,18)
                                               or Color3.fromRGB(150,150,162)})
    end
    btn.MouseEnter:Connect(function() tween(f,0.1,{BackgroundColor3=PANE2}) end)
    btn.MouseLeave:Connect(function() tween(f,0.1,{BackgroundColor3=PANE}) end)
    btn.MouseButton1Click:Connect(function() pcall(set,not get()) paint() end)
    A.repaint[#A.repaint+1]=paint
    paint()
    return f
end

local function mkSlider(page,label,min,max,get,set,fmt)
    local f=row(page,48)
    local nm=Instance.new("TextLabel")
    nm.Size=UDim2.new(1,-180,0,16) nm.Position=UDim2.fromOffset(14,8)
    nm.BackgroundTransparency=1 nm.FontFace=F_LABEL nm.TextSize=12.5
    nm.TextColor3=TXT nm.Text=label nm.ZIndex=4
    nm.TextXAlignment=Enum.TextXAlignment.Left nm.Parent=f

    local val=Instance.new("TextLabel")
    val.Size=UDim2.new(0,160,0,16) val.Position=UDim2.new(1,-174,0,8)
    val.BackgroundTransparency=1 val.FontFace=F_VALUE val.TextSize=11.5
    val.TextColor3=C.theme.accent val.Text="" val.ZIndex=4
    val.TextXAlignment=Enum.TextXAlignment.Right val.Parent=f

    local bar=Instance.new("Frame")
    bar.Size=UDim2.new(1,-28,0,4) bar.Position=UDim2.fromOffset(14,32)
    bar.BackgroundColor3=Color3.fromRGB(48,48,58) bar.BorderSizePixel=0
    bar.ZIndex=4 bar.Parent=f corner(bar,2)
    local fill=Instance.new("Frame")
    fill.BackgroundColor3=C.theme.accent fill.BorderSizePixel=0 fill.ZIndex=5
    fill.Size=UDim2.new(0,0,1,0) fill.Parent=bar corner(fill,2)
    local knob=Instance.new("Frame")
    knob.Size=UDim2.fromOffset(11,11) knob.AnchorPoint=Vector2.new(0.5,0.5)
    knob.Position=UDim2.new(0,0,0.5,0) knob.BorderSizePixel=0 knob.ZIndex=6
    knob.BackgroundColor3=Color3.fromRGB(246,246,250) knob.Parent=bar corner(knob,6)
    local grab=Instance.new("TextButton")
    grab.Size=UDim2.new(1,0,0,26) grab.Position=UDim2.fromOffset(0,-11)
    grab.ZIndex=7 grab.BackgroundTransparency=1 grab.Text="" grab.Parent=bar

    local function paint()
        local v=get() local a=math.clamp((v-min)/(max-min),0,1)
        fill.Size=UDim2.new(a,0,1,0) fill.BackgroundColor3=C.theme.accent
        knob.Position=UDim2.new(a,0,0.5,0)
        val.TextColor3=C.theme.accent
        val.Text=fmt and fmt(v) or tostring(v)
    end
    local dragging=false
    local function apply(px)
        local a=math.clamp((px-bar.AbsolutePosition.X)/math.max(bar.AbsoluteSize.X,1),0,1)
        set(min+(max-min)*a) paint()
    end
    grab.MouseButton1Down:Connect(function()
        dragging=true tween(knob,0.1,{Size=UDim2.fromOffset(14,14)})
        apply(UIS:GetMouseLocation().X) end)
    table.insert(A.conns, UIS.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 and dragging then
            dragging=false tween(knob,0.1,{Size=UDim2.fromOffset(11,11)}) end end))
    table.insert(A.conns, UIS.InputChanged:Connect(function(i)
        if dragging and i.UserInputType==Enum.UserInputType.MouseMovement then
            apply(i.Position.X) end end))
    A.repaint[#A.repaint+1]=paint
    paint()
    return f
end

local function mkLabel(page,h)
    local f=row(page,h or 54)
    local l=Instance.new("TextLabel")
    l.Size=UDim2.new(1,-24,1,-14) l.Position=UDim2.fromOffset(14,7)
    l.BackgroundTransparency=1 l.FontFace=F_MONO l.TextSize=10.5
    l.TextColor3=DIM l.ZIndex=4
    l.TextXAlignment=Enum.TextXAlignment.Left l.TextYAlignment=Enum.TextYAlignment.Top
    l.TextWrapped=true l.Text="" l.Parent=f
    return l
end

local function mkButton(page,label,fn)
    local f=row(page,34)
    local b=Instance.new("TextButton")
    b.Size=UDim2.new(1,0,1,0) b.BackgroundTransparency=1 b.BorderSizePixel=0
    b.FontFace=F_VALUE b.TextSize=12 b.TextColor3=TXT b.Text=label
    b.AutoButtonColor=false b.ZIndex=4 b.Parent=f
    b.MouseEnter:Connect(function() tween(f,0.1,{BackgroundColor3=PANE2}) end)
    b.MouseLeave:Connect(function() tween(f,0.1,{BackgroundColor3=PANE}) end)
    b.MouseButton1Click:Connect(function() pcall(fn) end)
    return b
end

local function mkTextBox(page,placeholder,onEnter)
    local f=row(page,36)
    local tb=Instance.new("TextBox")
    tb.Size=UDim2.new(1,-26,1,-6) tb.Position=UDim2.fromOffset(13,0)
    tb.ZIndex=4 tb.BackgroundTransparency=1 tb.FontFace=F_MONO tb.TextSize=10.5
    tb.TextColor3=TXT tb.PlaceholderText=placeholder
    tb.PlaceholderColor3=Color3.fromRGB(104,104,118) tb.Text=""
    tb.ClearTextOnFocus=false tb.TextXAlignment=Enum.TextXAlignment.Left
    tb.TextTruncate=Enum.TextTruncate.AtEnd tb.Parent=f
    local under=Instance.new("Frame")
    under.Size=UDim2.new(1,-26,0,1) under.Position=UDim2.new(0,13,1,-7)
    under.BackgroundColor3=FAINT under.BorderSizePixel=0 under.ZIndex=4 under.Parent=f
    tb.Focused:Connect(function() tween(under,0.12,{BackgroundColor3=C.theme.accent}) end)
    tb.FocusLost:Connect(function(enter)
        tween(under,0.12,{BackgroundColor3=FAINT})
        if enter and onEnter then pcall(onEnter,tb.Text) end end)
    return tb
end

-- colour picker: saturation/value square, hue strip, hex field ----------
local function mkPicker(page,label,getCol,setCol)
    local f=row(page,150)
    local nm=Instance.new("TextLabel")
    nm.Size=UDim2.new(1,-28,0,16) nm.Position=UDim2.fromOffset(14,8)
    nm.BackgroundTransparency=1 nm.FontFace=F_LABEL nm.TextSize=12.5
    nm.TextColor3=TXT nm.Text=label nm.ZIndex=4
    nm.TextXAlignment=Enum.TextXAlignment.Left nm.Parent=f

    local swatch=Instance.new("Frame")
    swatch.Size=UDim2.fromOffset(34,14) swatch.Position=UDim2.new(1,-48,0,9)
    swatch.BackgroundColor3=getCol() swatch.BorderSizePixel=0 swatch.ZIndex=4
    swatch.Parent=f corner(swatch,4)

    local sv=Instance.new("Frame")
    sv.Size=UDim2.new(1,-28,0,74) sv.Position=UDim2.fromOffset(14,30)
    sv.BackgroundColor3=Color3.fromRGB(255,0,0) sv.BorderSizePixel=0
    sv.ZIndex=4 sv.Parent=f corner(sv,6)
    local gw=Instance.new("UIGradient")
    gw.Color=ColorSequence.new(Color3.new(1,1,1),Color3.new(1,1,1))
    gw.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,0),
        NumberSequenceKeypoint.new(1,1)})
    gw.Parent=sv
    local blk=Instance.new("Frame")
    blk.Size=UDim2.new(1,0,1,0) blk.BackgroundColor3=Color3.new(0,0,0)
    blk.BorderSizePixel=0 blk.ZIndex=5 blk.Parent=sv corner(blk,6)
    local gb=Instance.new("UIGradient")
    gb.Rotation=90
    gb.Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0,1),
        NumberSequenceKeypoint.new(1,0)})
    gb.Parent=blk
    local cur=Instance.new("Frame")
    cur.Size=UDim2.fromOffset(8,8) cur.AnchorPoint=Vector2.new(0.5,0.5)
    cur.BackgroundTransparency=1 cur.ZIndex=7 cur.Parent=sv
    local curS=Instance.new("UIStroke") curS.Color=Color3.new(1,1,1)
    curS.Thickness=1.6 curS.Parent=cur
    corner(cur,4)

    local hue=Instance.new("Frame")
    hue.Size=UDim2.new(1,-28,0,10) hue.Position=UDim2.fromOffset(14,112)
    hue.BorderSizePixel=0 hue.ZIndex=4 hue.Parent=f corner(hue,5)
    local hg=Instance.new("UIGradient")
    hg.Color=ColorSequence.new({
        ColorSequenceKeypoint.new(0.00,Color3.fromRGB(255,0,0)),
        ColorSequenceKeypoint.new(0.17,Color3.fromRGB(255,255,0)),
        ColorSequenceKeypoint.new(0.33,Color3.fromRGB(0,255,0)),
        ColorSequenceKeypoint.new(0.50,Color3.fromRGB(0,255,255)),
        ColorSequenceKeypoint.new(0.67,Color3.fromRGB(0,0,255)),
        ColorSequenceKeypoint.new(0.83,Color3.fromRGB(255,0,255)),
        ColorSequenceKeypoint.new(1.00,Color3.fromRGB(255,0,0))})
    hg.Parent=hue
    local hueKnob=Instance.new("Frame")
    hueKnob.Size=UDim2.fromOffset(3,14) hueKnob.AnchorPoint=Vector2.new(0.5,0.5)
    hueKnob.Position=UDim2.new(0,0,0.5,0) hueKnob.BackgroundColor3=Color3.new(1,1,1)
    hueKnob.BorderSizePixel=0 hueKnob.ZIndex=6 hueKnob.Parent=hue corner(hueKnob,2)

    local hx=Instance.new("TextBox")
    hx.Size=UDim2.new(0,74,0,16) hx.Position=UDim2.fromOffset(14,128)
    hx.BackgroundTransparency=1 hx.FontFace=F_MONO hx.TextSize=10.5
    hx.TextColor3=DIM hx.Text="" hx.ClearTextOnFocus=false hx.ZIndex=4
    hx.TextXAlignment=Enum.TextXAlignment.Left hx.Parent=f

    local h,s,v = 0,1,1
    do local c=getCol() h,s,v = Color3.toHSV(c) end
    local function push()
        local c=Color3.fromHSV(h,s,v)
        swatch.BackgroundColor3=c
        sv.BackgroundColor3=Color3.fromHSV(h,1,1)
        cur.Position=UDim2.new(s,0,1-v,0)
        hueKnob.Position=UDim2.new(h,0,0.5,0)
        hx.Text="#"..c:ToHex():upper()
        pcall(setCol,c)
    end
    local function fromCol()
        h,s,v = Color3.toHSV(getCol())
        local c=getCol()
        swatch.BackgroundColor3=c
        sv.BackgroundColor3=Color3.fromHSV(h,1,1)
        cur.Position=UDim2.new(s,0,1-v,0)
        hueKnob.Position=UDim2.new(h,0,0.5,0)
        hx.Text="#"..c:ToHex():upper()
    end

    local dragSV,dragH=false,false
    local svBtn=Instance.new("TextButton")
    svBtn.Size=UDim2.new(1,0,1,0) svBtn.BackgroundTransparency=1 svBtn.Text=""
    svBtn.ZIndex=6 svBtn.Parent=sv
    local hBtn=Instance.new("TextButton")
    hBtn.Size=UDim2.new(1,0,1,0) hBtn.BackgroundTransparency=1 hBtn.Text=""
    hBtn.ZIndex=6 hBtn.Parent=hue

    local function setSV(px,py)
        s=math.clamp((px-sv.AbsolutePosition.X)/math.max(sv.AbsoluteSize.X,1),0,1)
        v=1-math.clamp((py-sv.AbsolutePosition.Y)/math.max(sv.AbsoluteSize.Y,1),0,1)
        push()
    end
    local function setH(px)
        h=math.clamp((px-hue.AbsolutePosition.X)/math.max(hue.AbsoluteSize.X,1),0,1)
        push()
    end
    svBtn.MouseButton1Down:Connect(function()
        dragSV=true local m=UIS:GetMouseLocation() setSV(m.X,m.Y) end)
    hBtn.MouseButton1Down:Connect(function()
        dragH=true setH(UIS:GetMouseLocation().X) end)
    table.insert(A.conns, UIS.InputEnded:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 then
            dragSV=false dragH=false end end))
    table.insert(A.conns, UIS.InputChanged:Connect(function(i)
        if i.UserInputType~=Enum.UserInputType.MouseMovement then return end
        if dragSV then setSV(i.Position.X,i.Position.Y) end
        if dragH then setH(i.Position.X) end end))
    hx.FocusLost:Connect(function(enter)
        if not enter then fromCol() return end
        local t=hx.Text:gsub("#","")
        local ok,c=pcall(Color3.fromHex,t)
        if ok then h,s,v=Color3.toHSV(c) push() else fromCol() end end)

    A.repaint[#A.repaint+1]=fromCol
    fromCol()
    return f
end

-- profile card, pinned to the bottom of the sidebar ------------------
-- scoped for the same reason; it exports via A.updateWatermark / A.wmGui
do
local profCard=Instance.new("Frame")
profCard.Size=UDim2.new(1,-12,0,52) profCard.Position=UDim2.new(0,6,1,-58)
profCard.BackgroundColor3=PANE profCard.BorderSizePixel=0 profCard.ZIndex=3
profCard.Parent=rail corner(profCard,8)

local profDiv=Instance.new("Frame")
profDiv.Size=UDim2.new(1,-12,0,1) profDiv.Position=UDim2.new(0,6,1,-66)
profDiv.BackgroundColor3=FAINT profDiv.BorderSizePixel=0 profDiv.ZIndex=3
profDiv.Parent=rail

local avatar=Instance.new("ImageLabel")
avatar.Size=UDim2.fromOffset(32,32) avatar.Position=UDim2.fromOffset(9,10)
avatar.BackgroundColor3=Color3.fromRGB(38,38,46) avatar.BorderSizePixel=0
avatar.ZIndex=4 avatar.Image="" avatar.Parent=profCard corner(avatar,16)
local avStroke=Instance.new("UIStroke")
avStroke.Color=C.theme.accent avStroke.Transparency=0.45
avStroke.Thickness=1.2 avStroke.Parent=avatar

local uname=Instance.new("TextLabel")
uname.Size=UDim2.new(1,-50,0,14) uname.Position=UDim2.fromOffset(48,12)
uname.BackgroundTransparency=1 uname.FontFace=F_VALUE uname.TextSize=11.5
uname.TextColor3=TXT uname.Text=LP.Name uname.ZIndex=4
uname.TextXAlignment=Enum.TextXAlignment.Left
uname.TextTruncate=Enum.TextTruncate.AtEnd uname.Parent=profCard

local role=Instance.new("TextLabel")
role.Size=UDim2.new(1,-50,0,12) role.Position=UDim2.fromOffset(48,27)
role.BackgroundTransparency=1 role.FontFace=F_LABEL role.TextSize=9.5
-- "Developer" belongs to the script owner only; anyone else running this
-- sees Customer.
local OWNER="FadedMemoriez3"
local isOwner=(LP.Name==OWNER)
role.TextColor3= isOwner and C.theme.accent or DIM
role.Text= isOwner and "Developer" or "Customer"
role.ZIndex=4
role.TextXAlignment=Enum.TextXAlignment.Left role.Parent=profCard

-- make room for the card so the tab list cannot run underneath it
railList.Size=UDim2.new(1,0,1,-80)

-- watermark: draggable, shows live fps / ping / who you are -----------
local wmGui=Instance.new("ScreenGui")
wmGui.Name="BBD_Watermark" wmGui.ResetOnSpawn=false wmGui.IgnoreGuiInset=true
wmGui.ZIndexBehavior=Enum.ZIndexBehavior.Global wmGui.DisplayOrder=99998
wmGui.Parent=(gethui and gethui()) or LP:WaitForChild("PlayerGui")
A.wmGui=wmGui

local wm=Instance.new("Frame")
wm.Size=UDim2.fromOffset(250,34)
-- centred horizontally so it lands the same on any resolution;
-- AnchorPoint keeps it centred as the size slider changes it
wm.AnchorPoint=Vector2.new(0.5,0)
wm.Position=UDim2.new(0.5,0,0,128)
wm.BackgroundColor3=BG wm.BorderSizePixel=0
wm.Active=true wm.Draggable=true wm.Parent=wmGui corner(wm,8)
local wmScale=Instance.new("UIScale") wmScale.Parent=wm
local wmStroke=Instance.new("UIStroke")
wmStroke.Color=C.theme.accent wmStroke.Transparency=0.6
wmStroke.Thickness=1 wmStroke.Parent=wm

function A.wmApply()
    wmGui.Enabled = C.wm.on and true or false
    -- tween the scale so dragging the slider feels continuous
    TweenService:Create(wmScale,TweenInfo.new(0.12,Enum.EasingStyle.Quad),
        {Scale=C.wm.scale}):Play()
end

local wmAv=Instance.new("ImageLabel")
wmAv.Size=UDim2.fromOffset(22,22) wmAv.Position=UDim2.fromOffset(6,6)
wmAv.BackgroundColor3=Color3.fromRGB(38,38,46) wmAv.BorderSizePixel=0
wmAv.ZIndex=2 wmAv.Image="" wmAv.Parent=wm corner(wmAv,11)

local wmName=Instance.new("TextLabel")
wmName.Size=UDim2.new(0,0,0,22) wmName.Position=UDim2.fromOffset(34,6)
wmName.AutomaticSize=Enum.AutomaticSize.X
wmName.BackgroundTransparency=1 wmName.FontFace=F_VALUE wmName.TextSize=11.5
wmName.TextColor3=TXT wmName.Text=LP.Name wmName.ZIndex=2
wmName.TextXAlignment=Enum.TextXAlignment.Left wmName.Parent=wm

local wmStats=Instance.new("TextLabel")
wmStats.Size=UDim2.new(0,0,0,22) wmStats.Position=UDim2.new(1,-10,0,6)
wmStats.AnchorPoint=Vector2.new(1,0)
wmStats.AutomaticSize=Enum.AutomaticSize.X
wmStats.BackgroundTransparency=1 wmStats.FontFace=F_MONO wmStats.TextSize=11
wmStats.TextColor3=DIM wmStats.Text="-- fps   -- ms" wmStats.ZIndex=2
wmStats.TextXAlignment=Enum.TextXAlignment.Right wmStats.Parent=wm

-- one fetch, shared by both avatars
task.spawn(function()
    local ok,url=pcall(function()
        return Players:GetUserThumbnailAsync(LP.UserId,
            Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
    end)
    if ok and url then
        avatar.Image=url
        wmAv.Image=url
    end
end)

-- called from the existing status loop so there is no extra timer
A.wmApply()

-- The watermark's home: horizontally centred, just below the game's own
-- timer. Hardcoded on purpose and never persisted, so it is in the same
-- place for every user on every load no matter where it was dragged.
local WM_HOME_ANCHOR=Vector2.new(0.5,0)
local WM_HOME_POS=UDim2.new(0.5,0,0,128)
function A.wmReset()
    wm.AnchorPoint=WM_HOME_ANCHOR
    wm.Position=WM_HOME_POS
end
function A.updateWatermark()
    local fps=A.fps or 0
    local ms=(A.pingS or A.lastPing or 0)*1000
    wmStats.Text=("%d fps   %d ms"):format(math.floor(fps+0.5), math.floor(ms+0.5))
    -- green when healthy, amber when the connection is costing you parries
    wmStats.TextColor3 = (ms>=150) and Color3.fromRGB(255,170,70)
                       or (ms>=90) and Color3.fromRGB(235,215,120)
                       or DIM
    wmStroke.Color=C.theme.accent
    avStroke.Color=C.theme.accent
    role.TextColor3=C.theme.accent
end
A.repaint[#A.repaint+1]=function()
    wmStroke.Color=C.theme.accent
    avStroke.Color=C.theme.accent
    role.TextColor3=C.theme.accent
end
end

-- ---- aim FOV circle + crosshair --------------------------------------
-- Drawn with the Drawing API so it sits above the game without touching
-- the player's own GUI. Killer-only: it is an aiming aid and would just be
-- clutter as a survivor.
do
local CAMERA=workspace.CurrentCamera

local circle=Drawing.new("Circle")
circle.Thickness=1 circle.NumSides=64 circle.Filled=false
circle.Transparency=1 circle.Visible=false
A.drawings[#A.drawings+1]=circle

-- the star is stroked as individual lines so it can be rotated per frame
local starLines={}
for i=1,12 do
    local l=Drawing.new("Line")
    l.Thickness=1.6 l.Transparency=1 l.Visible=false
    starLines[i]=l
    A.drawings[#A.drawings+1]=l
end

local dotMark=Drawing.new("Circle")
dotMark.Thickness=1 dotMark.NumSides=12 dotMark.Filled=true
dotMark.Radius=2 dotMark.Transparency=1 dotMark.Visible=false
A.drawings[#A.drawings+1]=dotMark

local crossLines={}
for i=1,4 do
    local l=Drawing.new("Line")
    l.Thickness=1.6 l.Transparency=1 l.Visible=false
    crossLines[i]=l
    A.drawings[#A.drawings+1]=l
end

local spin=0

local function hideAll()
    circle.Visible=false dotMark.Visible=false
    for _,l in ipairs(starLines) do l.Visible=false end
    for _,l in ipairs(crossLines) do l.Visible=false end
end

-- six-pointed star drawn as two interlocking triangles
local function drawStar(cx,cy,r,rot,col)
    local pts={}
    for i=0,5 do
        local a=math.rad(rot + i*60 + 90)
        pts[i+1]=Vector2.new(cx+math.cos(a)*r, cy-math.sin(a)*r)
    end
    -- triangle A: points 1,3,5   triangle B: points 2,4,6
    local order={1,3,5,1, 2,4,6,2}
    local n=0
    for t=0,1 do
        for i=1,3 do
            n=n+1
            local a=pts[order[t*4+i]]
            local b=pts[order[t*4+i+1]]
            local l=starLines[n]
            l.From=a l.To=b l.Color=col l.Visible=true
        end
    end
    for i=n+1,#starLines do starLines[i].Visible=false end
end

local function drawCross(cx,cy,r,col)
    local gap=r*0.35
    local segs={
        {Vector2.new(cx,cy-r),    Vector2.new(cx,cy-gap)},
        {Vector2.new(cx,cy+gap),  Vector2.new(cx,cy+r)},
        {Vector2.new(cx-r,cy),    Vector2.new(cx-gap,cy)},
        {Vector2.new(cx+gap,cy),  Vector2.new(cx+r,cy)},
    }
    for i,s in ipairs(segs) do
        local l=crossLines[i]
        l.From=s[1] l.To=s[2] l.Color=col l.Visible=true
    end
end

-- the aim cone projected onto the screen, so the circle genuinely shows
-- which targets the FOV setting will accept
local function fovRadiusPx()
    local vp=CAMERA.ViewportSize
    local camFov=math.rad(CAMERA.FieldOfView)
    local half=math.rad(math.clamp(C.killer.fov,1,179))/2
    local r=math.tan(half)/math.tan(camFov/2)*(vp.Y/2)
    -- past the screen edge the number stops meaning anything useful
    return math.min(r, math.max(vp.X,vp.Y))
end

function A.drawCrosshair(dt) LPH_ATTRIBUTES(VM(NONE))
    if A.stopped or not C.cross.on or not amKiller() then hideAll() return end
    local vp=CAMERA.ViewportSize
    local m=UIS:GetMouseLocation()
    local cx,cy=m.X,m.Y            -- Drawing coords already exclude the inset
    A.crossXY=Vector2.new(cx,cy)   -- the lock line anchors on this exact point
    local col=C.cross.useAccent and C.theme.accent or C.cross.color

    spin=(spin + (C.cross.spin and (C.cross.spinSpeed*dt) or 0)) % 360

    if C.cross.fovCircle then
        circle.Position=Vector2.new(vp.X/2, vp.Y/2)
        circle.Radius=fovRadiusPx()
        circle.Color=col
        circle.Visible=true
    else
        circle.Visible=false
    end

    local style=C.cross.style
    if style=="star" then
        for _,l in ipairs(crossLines) do l.Visible=false end
        dotMark.Visible=false
        drawStar(cx,cy,C.cross.size,spin,col)
    elseif style=="cross" then
        for _,l in ipairs(starLines) do l.Visible=false end
        dotMark.Visible=false
        drawCross(cx,cy,C.cross.size,col)
    elseif style=="dot" then
        for _,l in ipairs(starLines) do l.Visible=false end
        for _,l in ipairs(crossLines) do l.Visible=false end
        dotMark.Position=Vector2.new(cx,cy)
        dotMark.Color=col dotMark.Visible=true
    else -- "none": FOV circle only
        for _,l in ipairs(starLines) do l.Visible=false end
        for _,l in ipairs(crossLines) do l.Visible=false end
        dotMark.Visible=false
    end
end
end

-- ---- lock indicator ---------------------------------------------------
-- While silent aim is holding someone, a line runs from the crosshair down
-- onto the exact point on their body the axe will be sent to. It reads the
-- live body position every frame, so the line sweeps along them as they move
-- rather than jumping between poses.
--
-- Always on with the lock, no toggle: it is the readout for silent aim, not
-- a separate feature. Chams were tried here and dropped -- the ESP already
-- fills the target in, so a second fill just muddied the colour.
do
local CAMERA=workspace.CurrentCamera

-- Drawing API transparency is inverted against Roblox: 1 is opaque.
local lockLine=Drawing.new("Line")
lockLine.Thickness=1.5 lockLine.Transparency=1 lockLine.Visible=false
A.drawings[#A.drawings+1]=lockLine

local lockDot=Drawing.new("Circle")
lockDot.NumSides=16 lockDot.Filled=false lockDot.Thickness=1.4
lockDot.Radius=5 lockDot.Transparency=1 lockDot.Visible=false
A.drawings[#A.drawings+1]=lockDot

local pulse=0

local function hideLock()
    lockLine.Visible=false lockDot.Visible=false
end

function A.drawLock(dt) LPH_ATTRIBUTES(VM(NONE))
    local m=A.aimModel
    if A.stopped or not C.killer.silent or not m or not amKiller() then
        hideLock() return end
    if not m.Parent then hideLock() return end

    local col=C.cross.useAccent and C.theme.accent or C.cross.color
    pulse=(pulse+dt) % 1.2

    -- Anchored on A.aimPos, the exact point the throw is sent to, so the
    -- line shows WHERE on the body the axe is going, not just who.
    local p=A.aimPos
    if not p then
        local hrp=m:FindFirstChild("HumanoidRootPart")
        p=hrp and hrp.Position
    end
    if not p then lockLine.Visible=false lockDot.Visible=false return end

    local v,onScreen=CAMERA:WorldToViewportPoint(p)
    if not onScreen then
        lockLine.Visible=false lockDot.Visible=false return end

    -- Anchor on the point drawCrosshair actually drew the star at, not a
    -- second reading of the mouse: if the two ever disagreed about the GUI
    -- inset the line would end 36px off the star.
    local ms=A.crossXY
    if not ms then local p=UIS:GetMouseLocation() ms=Vector2.new(p.X,p.Y) end
    lockLine.From=ms
    lockLine.To=Vector2.new(v.X,v.Y)
    lockLine.Color=col
    -- breathes, so a live lock reads differently from a static ESP tracer
    lockLine.Transparency=0.62+0.38*math.abs(math.sin(pulse*math.pi))
    lockLine.Visible=true

    lockDot.Position=Vector2.new(v.X,v.Y)
    lockDot.Color=col
    lockDot.Radius=5+1.5*math.abs(math.sin(pulse*math.pi))
    lockDot.Visible=true
end
end

-- dropdown: click to expand, pick one. Replaces cycling buttons, which
-- hide the available options until you have clicked through all of them.
local function mkDropdown(page,label,options,get,set)
    local f=row(page,44)
    f.ClipsDescendants=false
    local nm=Instance.new("TextLabel")
    nm.Size=UDim2.new(1,-28,0,14) nm.Position=UDim2.fromOffset(14,7)
    nm.BackgroundTransparency=1 nm.FontFace=F_LABEL nm.TextSize=11.5
    nm.TextColor3=DIM nm.Text=label nm.ZIndex=4
    nm.TextXAlignment=Enum.TextXAlignment.Left nm.Parent=f

    local head=Instance.new("TextButton")
    head.Size=UDim2.new(1,-28,0,18) head.Position=UDim2.fromOffset(14,22)
    head.BackgroundTransparency=1 head.AutoButtonColor=false
    head.FontFace=F_VALUE head.TextSize=12.5 head.TextColor3=TXT
    head.Text="" head.ZIndex=4
    head.TextXAlignment=Enum.TextXAlignment.Left head.Parent=f

    local arrow=Instance.new("TextLabel")
    arrow.Size=UDim2.fromOffset(14,14) arrow.Position=UDim2.new(1,-28,0,24)
    arrow.BackgroundTransparency=1 arrow.FontFace=F_VALUE arrow.TextSize=11
    arrow.TextColor3=DIM arrow.Text="v" arrow.ZIndex=4 arrow.Parent=f

    -- the list floats above following rows rather than pushing them down
    local list=Instance.new("Frame")
    list.Size=UDim2.new(1,-28,0,0) list.Position=UDim2.fromOffset(14,42)
    list.BackgroundColor3=Color3.fromRGB(31,31,39) list.BorderSizePixel=0
    list.ClipsDescendants=true list.Visible=false list.ZIndex=20 list.Parent=f
    corner(list,7)
    local ls=Instance.new("UIStroke") ls.Color=FAINT ls.Thickness=1 ls.Parent=list
    local ll=Instance.new("UIListLayout") ll.Padding=UDim.new(0,0)
    ll.SortOrder=Enum.SortOrder.LayoutOrder ll.Parent=list

    local open=false
    -- `options` may be a plain table OR a function returning one. A player
    -- list cannot be baked in at build time: people join, leave and die, and
    -- a dropdown built once would be stale the moment the round changed.
    local function optList()
        if type(options)=="function" then
            local ok,t=pcall(options)
            return (ok and type(t)=="table") and t or {}
        end
        return options or {}
    end
    local function labelFor(v)
        for _,o in ipairs(optList()) do if o.value==v then return o.text end end
        if v==nil or v=="" then return "-" end
        return tostring(v)
    end
    local function refresh() head.Text=labelFor(get()) end

    local setOpen
    -- rebuilt every time the list opens, so it always shows who is here now
    local function rebuild()
        for _,c in ipairs(list:GetChildren()) do
            if c:IsA("TextButton") then c:Destroy() end
        end
        local opts=optList()
        for i,o in ipairs(opts) do
            local it=Instance.new("TextButton")
            it.Size=UDim2.new(1,0,0,26) it.BackgroundTransparency=1
            it.BorderSizePixel=0 it.AutoButtonColor=false
            it.FontFace=F_LABEL it.TextSize=12 it.TextColor3=TXT
            it.Text="   "..o.text it.ZIndex=21 it.LayoutOrder=i
            it.TextXAlignment=Enum.TextXAlignment.Left it.Parent=list
            it.MouseEnter:Connect(function()
                tween(it,0.08,{BackgroundTransparency=0.55,
                               BackgroundColor3=C.theme.accent}) end)
            it.MouseLeave:Connect(function()
                tween(it,0.08,{BackgroundTransparency=1}) end)
            it.MouseButton1Click:Connect(function()
                pcall(set,o.value) refresh() setOpen(false) end)
        end
        return #opts
    end

    setOpen=function(v)
        open=v
        arrow.Text = v and "^" or "v"
        if v then
            local n=rebuild()
            list.Visible=true
            -- cap the height so a full lobby cannot run off the menu
            tween(list,0.14,{Size=UDim2.new(1,-28,0,math.min(n,7)*26)})
        else
            tween(list,0.12,{Size=UDim2.new(1,-28,0,0)})
            task.delay(0.13,function() if not open then list.Visible=false end end)
        end
    end
    rebuild()

    head.MouseButton1Click:Connect(function() setOpen(not open) end)
    f.MouseLeave:Connect(function()
        task.delay(0.35,function()
            -- only collapse if the pointer really left the whole control
            local m=UIS:GetMouseLocation()
            local p,sz=f.AbsolutePosition,f.AbsoluteSize
            local inside = m.X>=p.X and m.X<=p.X+sz.X
                       and m.Y>=p.Y and m.Y<=p.Y+sz.Y+list.AbsoluteSize.Y
            if open and not inside then setOpen(false) end
        end)
    end)

    A.repaint[#A.repaint+1]=refresh
    refresh()
    return f
end

local function toColor(x)
    if typeof(x)=="Color3" then return x end
    if type(x)=="table" and #x>=3 then
        return Color3.fromRGB(tonumber(x[1]) or 0,tonumber(x[2]) or 0,tonumber(x[3]) or 0) end
    if type(x)=="string" then
        local s2=x:gsub("^#",""):gsub("%s","")
        if #s2==6 and s2:match("^%x+$") then
            local ok,c=pcall(Color3.fromHex,s2) if ok then return c end end end
    return nil end
local function repaintAll()
    winStroke.Color=C.theme.accent glow.BackgroundColor3=C.theme.accent
    for _,pg in pairs(pages) do pg.ScrollBarImageColor3=C.theme.accent end
    for _,f in ipairs(A.repaint) do pcall(f) end
    pcall(applyGlass)
    if current then selectTab(current) end end
local GIF={}

local function rd16(s,i) return string.byte(s,i)+string.byte(s,i+1)*256 end

-- Standard GIF LZW. Codes are packed LSB-first across byte boundaries.
local function lzw(data, minCode)
    local clear=bit32.lshift(1,minCode)
    local eoi=clear+1
    local codeSize=minCode+1
    local next_=eoi+1
    local dict={}
    for i=0,clear-1 do dict[i]={i} end
    local out={}
    local n=0
    local acc,accBits,pos=0,0,1
    local prev=nil
    local len=#data
    while true do
        while accBits<codeSize do
            if pos>len then return out end
            acc=acc+bit32.lshift(string.byte(data,pos),accBits)
            accBits=accBits+8
            pos=pos+1
        end
        local code=bit32.band(acc,bit32.lshift(1,codeSize)-1)
        acc=bit32.rshift(acc,codeSize)
        accBits=accBits-codeSize

        if code==clear then
            dict={}
            for i=0,clear-1 do dict[i]={i} end
            codeSize=minCode+1
            next_=eoi+1
            prev=nil
        elseif code==eoi then
            return out
        else
            local entry
            if dict[code] then
                entry=dict[code]
            elseif prev then
                entry={}
                for i=1,#prev do entry[i]=prev[i] end
                entry[#entry+1]=prev[1]
            else
                return out
            end
            for i=1,#entry do n=n+1 out[n]=entry[i] end
            if prev then
                local ne={}
                for i=1,#prev do ne[i]=prev[i] end
                ne[#ne+1]=entry[1]
                dict[next_]=ne
                next_=next_+1
                if next_>=bit32.lshift(1,codeSize) and codeSize<12 then
                    codeSize=codeSize+1
                end
            end
            prev=entry
        end
    end
end

-- concatenates the sub-block chain starting at i, returns data and next index
local function subBlocks(s,i)
    local parts={}
    while true do
        local sz=string.byte(s,i)
        if not sz or sz==0 then return table.concat(parts), i+1 end
        parts[#parts+1]=string.sub(s,i+1,i+sz)
        i=i+1+sz
    end
end

function GIF.decode(s)
    if #s<13 or string.sub(s,1,3)~="GIF" then return nil,"not a GIF" end
    local W,H=rd16(s,7),rd16(s,9)
    local packed=string.byte(s,11)
    local gctFlag=bit32.band(packed,0x80)~=0
    local gctSize=bit32.lshift(1,bit32.band(packed,0x07)+1)
    local i=14
    local gct=nil
    if gctFlag then
        gct={}
        for k=0,gctSize-1 do
            gct[k]={string.byte(s,i),string.byte(s,i+1),string.byte(s,i+2)}
            i=i+3
        end
    end

    local frames={}
    local delay,transp=10,nil
    local disposal=0
    -- canvas persists between frames for disposal methods 0/1
    local canvas={}
    for p=1,W*H*4 do canvas[p]=0 end

    while i<=#s do
        local b=string.byte(s,i)
        if b==0x3B then break
        elseif b==0x21 then
            local label=string.byte(s,i+1)
            if label==0xF9 then
                local sz=string.byte(s,i+2)
                local pk=string.byte(s,i+3)
                delay=rd16(s,i+4)
                local ti=string.byte(s,i+6)
                disposal=bit32.band(bit32.rshift(pk,2),0x07)
                transp=(bit32.band(pk,1)~=0) and ti or nil
                i=i+3+sz
                i=i+1  -- block terminator
            else
                local _,ni=subBlocks(s,i+2)
                i=ni
            end
        elseif b==0x2C then
            local fx,fy=rd16(s,i+1),rd16(s,i+3)
            local fw,fh=rd16(s,i+5),rd16(s,i+7)
            local pk=string.byte(s,i+9)
            local lctFlag=bit32.band(pk,0x80)~=0
            local interlace=bit32.band(pk,0x40)~=0
            local lctSize=bit32.lshift(1,bit32.band(pk,0x07)+1)
            i=i+10
            local pal=gct
            if lctFlag then
                pal={}
                for k=0,lctSize-1 do
                    pal[k]={string.byte(s,i),string.byte(s,i+1),string.byte(s,i+2)}
                    i=i+3
                end
            end
            local minCode=string.byte(s,i) i=i+1
            local data,ni=subBlocks(s,i) i=ni
            local idx=lzw(data,minCode)

            -- interlaced GIFs store rows in four passes
            local rows={}
            if interlace then
                local r=0
                for _,st in ipairs({{0,8},{4,8},{2,4},{1,2}}) do
                    local y=st[1]
                    while y<fh do rows[r]=y r=r+1 y=y+st[2] end
                end
            end

            local k=1
            for row=0,fh-1 do
                local y=interlace and (rows[row] or row) or row
                for x=0,fw-1 do
                    local ci=idx[k] k=k+1
                    if ci and (not transp or ci~=transp) and pal and pal[ci] then
                        local px=((y+fy)*W+(x+fx))*4
                        if px>=0 and px+3<=W*H*4 then
                            canvas[px+1]=pal[ci][1]
                            canvas[px+2]=pal[ci][2]
                            canvas[px+3]=pal[ci][3]
                            canvas[px+4]=255
                        end
                    end
                end
            end

            local copy=table.create(W*H*4)
            for p=1,W*H*4 do copy[p]=canvas[p] end
            frames[#frames+1]={pixels=copy, delay=math.max(delay,2)/100}

            if disposal==2 then
                for p=1,W*H*4 do canvas[p]=0 end
            end
        else
            i=i+1
        end
    end
    if #frames==0 then return nil,"no frames decoded" end
    return {width=W,height=H,frames=frames}
end


-- ---- animated wallpaper + external audio ----------------------------
-- An ImageLabel cannot play a GIF, so each frame is decoded to pixels and
-- pushed into an EditableImage, which the loop below cycles on the GIF's own
-- per-frame delays. Verified against a reference GIF built with PIL: frame
-- count, per-frame colours and 120ms delays all matched exactly.
local MAXDIM=1024   -- CreateEditableImage rejects 2048; measured

local function downscale(px,w,h,tw,th)
    local out=table.create(tw*th*4)
    for y=0,th-1 do
        local sy=math.floor(y*h/th)
        for x=0,tw-1 do
            local sx=math.floor(x*w/tw)
            local si=(sy*w+sx)*4
            local di=(y*tw+x)*4
            out[di+1]=px[si+1] or 0
            out[di+2]=px[si+2] or 0
            out[di+3]=px[si+3] or 0
            out[di+4]=px[si+4] or 0
        end
    end
    return out
end

function A.stopGif()
    if A.gifLoop then A.gifLoop=false end
    A.gifFrames=nil
end

local function applyGif(body)
    local AS=game:GetService("AssetService")
    if not (AS and AS.CreateEditableImage) then return false,"no EditableImage API" end
    local g,err=GIF.decode(body)
    if not g then return false,(err or "decode failed") end

    local w,h=g.width,g.height
    local tw,th=w,h
    if w>MAXDIM or h>MAXDIM then
        local sc=MAXDIM/math.max(w,h)
        tw,th=math.max(1,math.floor(w*sc)),math.max(1,math.floor(h*sc))
    end

    A.stopGif()
    local imgs={}
    local MAXF=48   -- bound memory: each frame is a full-size image
    local step=math.max(1,math.ceil(#g.frames/MAXF))
    for i=1,#g.frames,step do
        local f=g.frames[i]
        local px=f.pixels
        if tw~=w or th~=h then px=downscale(px,w,h,tw,th) end
        local okI,ei=pcall(function()
            return AS:CreateEditableImage({Size=Vector2.new(tw,th)}) end)
        if not okI then return false,"CreateEditableImage failed" end
        local buf=buffer.create(tw*th*4)
        for pi=0,tw*th*4-1 do buffer.writeu8(buf,pi,px[pi+1] or 0) end
        local okW=pcall(function()
            ei:WritePixelsBuffer(Vector2.zero,Vector2.new(tw,th),buf) end)
        if not okW then return false,"WritePixelsBuffer failed" end
        imgs[#imgs+1]={content=Content.fromObject(ei), delay=f.delay}
    end
    if #imgs==0 then return false,"no frames" end

    A.gifFrames=imgs
    A.gifLoop=true
    SH.gifCount=#imgs SH.gifFrame=0
    task.spawn(function()
        local n=1
        while A.gifLoop and not A.stopped do
            local fr=A.gifFrames and A.gifFrames[n]
            if not fr then break end
            pcall(function() bgImage.ImageContent=fr.content end)
            SH.gifFrame=n SH.gifCount=#A.gifFrames
            task.wait(fr.delay)
            n=n+1
            if n>#A.gifFrames then n=1 end
        end
    end)
    return true,("gif: %d frames %dx%d"):format(#imgs,tw,th)
end

-- External audio. Sound.SoundId only takes rbxassetid, but getcustomasset
-- turns a downloaded file into one -- verified returning a usable
-- rbxasset://textures/... id for audio.
A.sound=nil
function A.stopSound()
    if A.sound then pcall(function() A.sound:Stop() A.sound:Destroy() end) A.sound=nil end
end
-- YouTube audio cannot be fetched directly: the page is not a media file.
-- A public extractor is needed to resolve a video id to a real audio stream,
-- so several are tried in turn and the first that answers is used. These are
-- third-party and do go down, which is why the failure is reported plainly
-- rather than pretending the link was bad.
local function ytId(url)
    return url:match("[?&]v=([%w_%-]+)")
        or url:match("youtu%.be/([%w_%-]+)")
        or url:match("/shorts/([%w_%-]+)")
        or url:match("/embed/([%w_%-]+)")
end

-- YouTube: NOT SUPPORTED, and this explains why rather than failing vaguely.
-- Resolution itself works (invidious.f5.si answers with 4 audio streams), but
-- the formats YouTube serves are:
--     audio/mp4; codecs="mp4a.40.2"   3.4 MB
--     audio/webm; codecs="opus"       1.2 - 3.4 MB
-- and Roblox's getcustomasset only loads mp3 / ogg / wav. WebM is not Ogg, so
-- none of them can be turned into a SoundId, and transcoding is not possible
-- here. Worse, fetching 3.4MB synchronously froze the client hard enough to
-- drop the executor connection entirely -- so attempting it is actively
-- harmful, not merely useless.
local function ytId(url)
    return url:match("[?&]v=([%w_%-]+)")
        or url:match("youtu%.be/([%w_%-]+)")
        or url:match("/shorts/([%w_%-]+)")
        or url:match("/embed/([%w_%-]+)")
end

-- A single synchronous fetch of a few MB freezes the client hard enough to
-- drop the executor connection (measured on a 3.4MB file). The fix is not a
-- small size limit -- that just makes real songs impossible -- but to pull the
-- file in chunks with a yield between each, so the game keeps running. A
-- normal 3-4 minute track is 3-5MB, hence the much larger ceiling.
local MAXAUDIO=12*1024*1024
local CHUNK=256*1024

-- Returns the whole body, fetched in pieces. Falls back to a single request
-- when the server will not do ranges and the file is small enough to be safe.
local function fetchChunked(url, onProgress)
    local ok,h=pcall(req,{Url=url,Method="GET",Headers={Range="bytes=0-1"}})
    local total,ranged=nil,false
    if ok and type(h)=="table" then
        local hd=h.Headers or {}
        local cr=hd["content-range"] or hd["Content-Range"]
        if cr then
            total=tonumber(tostring(cr):match("/(%d+)"))
            ranged=((h.StatusCode or h.Status)==206)
        end
    end
    if total and total>MAXAUDIO then
        return nil,("file is %.1fMB, over the %.0fMB limit")
            :format(total/1048576, MAXAUDIO/1048576)
    end
    if not ranged or not total then
        -- no range support: only safe for something small
        local ok2,r=pcall(req,{Url=url,Method="GET"})
        if not ok2 or type(r)~="table" then return nil,"fetch failed" end
        local code=r.StatusCode or r.Status
        if code~=200 then return nil,"http "..tostring(code) end
        if r.Body and #r.Body>MAXAUDIO then return nil,"file too large" end
        return r.Body
    end
    local parts,got={},0
    while got<total do
        local last=math.min(got+CHUNK-1,total-1)
        local okc,rc=pcall(req,{Url=url,Method="GET",
            Headers={Range=("bytes=%d-%d"):format(got,last)}})
        if not okc or type(rc)~="table" then return nil,"chunk fetch failed" end
        local code=rc.StatusCode or rc.Status
        if code~=206 and code~=200 then return nil,"chunk http "..tostring(code) end
        local body=rc.Body or ""
        if #body==0 then break end
        parts[#parts+1]=body
        got=got+#body
        if onProgress then onProgress(got,total) end
        task.wait()   -- the yield that keeps the game responsive
    end
    return table.concat(parts)
end

local function playSound(url,vol,looped)
    if not (writefile and getcustomasset) then return false,"no file access" end
    url=(url or ""):gsub("^%s+",""):gsub("%s+$","")
    if not url:match("^https?://") then return false,"must start with https://" end
    local title=nil
    if url:find("youtube%.com") or url:find("youtu%.be") then
        return false,"youtube cannot work: it serves mp4/AAC and webm/opus, "
                   .."roblox only loads mp3/ogg/wav. use a direct .mp3 link"
    end
    local body,ferr=fetchChunked(url,function(got,total)
        A.themeStatus=("downloading %.1f / %.1f MB"):format(got/1048576,total/1048576)
    end)
    if not body then return false,(ferr or "fetch failed") end
    if #body<64 then return false,"response too small to be audio" end
    local res={Body=body,Headers={}}
    -- Verify this is ACTUALLY audio before writing it. A /song/... page from
    -- a download site returns HTML, which then gets saved as .mp3 and fails
    -- inside getcustomasset with nothing useful to show the user. Checking
    -- the content type and the file's magic bytes gives a real answer.
    local hdrs=res.Headers or {}
    local ctype=tostring(hdrs["content-type"] or hdrs["Content-Type"] or ""):lower()
    local b=res.Body
    local magic =  (b:sub(1,3)=="ID3" and "mp3")
                or (b:byte(1)==0xFF and b:byte(2) and b:byte(2)>=0xE0 and "mp3")
                or (b:sub(1,4)=="OggS" and "ogg")
                or (b:sub(1,4)=="RIFF" and b:sub(9,12)=="WAVE" and "wav")
                or nil
    if not magic then
        if ctype:find("html") or b:sub(1,15):lower():find("<!doctype")
           or b:sub(1,6):lower():find("<html") then
            return false,"that link is a web page, not an audio file - "
                       .."you need the direct .mp3 the page plays"
        end
        return false,("not audio (content-type %q) - needs a direct mp3/ogg/wav")
            :format(ctype~="" and ctype:sub(1,24) or "unknown")
    end
    local ext=magic
    local path=("bbd_theme_sound.%s"):format(ext)
    if not pcall(writefile,path,res.Body) then return false,"writefile failed" end
    local okc,asset=pcall(getcustomasset,path)
    if not okc or not asset then return false,"getcustomasset failed" end
    A.stopSound()
    local snd=Instance.new("Sound")
    snd.SoundId=asset
    snd.Volume=math.clamp(tonumber(vol) or 0.5,0,1)
    snd.Looped=(looped~=false)
    snd.Parent=(gethui and gethui()) or game:GetService("CoreGui")
    local okp=pcall(function() snd:Play() end)
    if not okp then return false,"play failed" end
    A.sound=snd
    A.soundTitle=title or url:match("([^/]+)$") or "audio"
    return true,("playing %s"):format(A.soundTitle:sub(1,34))
end

local function applyImage(url,tr)
    if not (writefile and getcustomasset) then return false,"no file access" end
    local ok,res=pcall(req,{Url=url,Method="GET"})
    if not ok or type(res)~="table" then return false,"fetch failed" end
    local code=res.StatusCode or res.Status
    if code~=200 or not res.Body or #res.Body<32 then return false,"http "..tostring(code) end
    -- a GIF has to be decoded and animated; an ImageLabel cannot play one
    if res.Body:sub(1,3)=="GIF" then
        local okG,msg=applyGif(res.Body)
        if okG then
            C.theme.wall = tonumber(tr) or C.theme.wall
            applyGlass()
        end
        return okG,msg
    end
    A.stopGif()
    local ext=url:match("%.(%a%a%a%a?)[%?#]?") or "png"
    local path=("bbd_theme_bg.%s"):format(ext:lower())
    if not pcall(writefile,path,res.Body) then return false,"writefile failed" end
    local okc,asset=pcall(getcustomasset,path)
    if not okc then return false,"getcustomasset failed" end
    bgImage.Image=asset
    C.theme.wall = tonumber(tr) or C.theme.wall
    applyGlass()
    return true,"image applied" end
local function loadTheme(url)
    url=(url or ""):gsub("^%s+",""):gsub("%s+$","")
    if url=="" then A.themeStatus="paste a link first" return end
    if not url:match("^https?://") then A.themeStatus="must start with https://" return end
    A.themeStatus="fetching..."
    task.spawn(function()
        local ok,res=pcall(req,{Url=url,Method="GET"})
        if not ok or type(res)~="table" then A.themeStatus="request failed" return end
        local code=res.StatusCode or res.Status
        if code~=200 then A.themeStatus="http "..tostring(code) return end
        local ct=(res.Headers and (res.Headers["content-type"] or res.Headers["Content-Type"]) or ""):lower()
        if ct:find("image") or url:lower():match("%.png") or url:lower():match("%.jpe?g") then
            local okI,msg=applyImage(url,0.35)
            A.themeStatus=okI and "background applied" or ("image: "..msg) return end
        local okJ,data=pcall(function() return HttpSvc:JSONDecode(res.Body or "") end)
        if not okJ or type(data)~="table" then A.themeStatus="not JSON or image" return end
        local applied={}
        for k,f in pairs({accent="accent",survivor="survivor",killer="killer",generator="gen",gen="gen",trap="trap",traps="trap"}) do
            local c2=toColor(data[k]) if c2 then C.theme[f]=c2 applied[#applied+1]=k end end
        local bg=toColor(data.background) if bg then win.BackgroundColor3=bg applied[#applied+1]="background" end
        if data.image then local okI=applyImage(data.image,data.imageTransparency)
            applied[#applied+1]=okI and "image" or "image:failed" end
        repaintAll()
        A.themeStatus=("loaded %s -> %s"):format(tostring(data.name or "theme"),
            #applied>0 and table.concat(applied,", ") or "nothing recognised") end) end
local function exportTheme()
    local t=C.theme
    local j=('{\n  "name": "My Theme",\n  "accent": "#%s",\n  "survivor": "#%s",\n  "killer": "#%s",\n  "generator": "#%s",\n  "background": "#%s"\n}')
        :format(t.accent:ToHex():upper(),t.survivor:ToHex():upper(),
                t.killer:ToHex():upper(),t.gen:ToHex():upper(),
                win.BackgroundColor3:ToHex():upper())
    if setclipboard then pcall(setclipboard,j) end
    A.themeStatus="copied to clipboard" end

----------------------------------------------------------------------
-- one table instead of eight locals: Lua caps a chunk at 200 registers
local UIL={}

local pSurv =addTab("Survivor",54)
local pKill =addTab("Killer",44)
local pParry=addTab("Parry",40)
local pGens =addTab("Gens",38)
local pESP  =addTab("ESP",34)
local pTheme=addTab("Theme",42)
local pSet  =addTab("Settings",52)
local pFeed =addTab("Feedback",58)

do  -- scoped: Lua allows 200 locals per chunk
local notice=mkLabel(pSurv,56)
notice.Text="ANNOUNCEMENT\nMobile support is coming soon.\nSome features are still being worked on or fixed -\nif something misbehaves, please use the Feedback tab."
notice.TextColor3=C.theme.accent
A.repaint[#A.repaint+1]=function() notice.TextColor3=C.theme.accent end
end

mkToggle(pSurv,"Infinite Sprint",function() return C.sprint.on end,function(v) C.sprint.on=v end)
mkToggle(pSurv,"Never Stop Running",function() return C.sprint.forceRun end,function(v) C.sprint.forceRun=v end)
mkToggle(pSurv,"Speed Boost",function() return C.speed.on end,function(v)
    C.speed.on=v if not v then A.restoreSpeed() end end)
mkSlider(pSurv,"Walk Speed",12,60,function() return C.speed.walk end,
    function(v) C.speed.walk=math.floor(v) end,function(v) return ("%d"):format(v) end)
mkSlider(pSurv,"Run Speed",12,80,function() return C.speed.run end,
    function(v) C.speed.run=math.floor(v) end,function(v) return ("%d"):format(v) end)
mkToggle(pSurv,"No Stun / Ragdoll",function() return C.noStun.on end,function(v) C.noStun.on=v end)
mkToggle(pSurv,"Infinite Dodges",function() return C.dodges.on end,function(v) C.dodges.on=v end)
UIL.survInfo=mkLabel(pSurv,38)

mkToggle(pParry,"Auto Parry",function() return C.parry.on end,function(v) C.parry.on=v end)
mkSlider(pParry,"Parry Range",1,40,function() return C.parry.range end,
    function(v) C.parry.range=math.floor(v) end,
    function(v) return ("%d studs"):format(v) end)
-- Plain-language connection readout. The detailed diagnostics are dev-only
-- and hidden in the public build, which left users with a parry that simply
-- "did not work" on a bad connection and no way to tell why. This says it
-- in words, so the limit reads as a connection fact rather than a bug.
UIL.parryHealth=mkLabel(pParry,92)
UIL.parryHealth.FontFace=F_LABEL
UIL.parryHealth.TextSize=11.5
-- Everything else is self-managing: ping compensation and the closed-loop
-- tuner are always on and have no controls, because every knob they used to
-- expose is something the script measures better than it can be guessed.
-- Dev-only diagnostics. Detached rather than deleted so every
-- .Text write further down still works and cannot error.
UIL.parryInfo=Instance.new("TextLabel")

mkToggle(pKill,"Silent Aim (Axe Throw)",function() return C.killer.silent end,
    function(v) C.killer.silent=v if not v then A.aimPos=nil end end)
mkToggle(pKill,"Require Line of Sight",function() return C.killer.los end,
    function(v) C.killer.los=v end)
-- Never Miss, Auto Throw and Throw Cooldown removed. Never Miss locked
-- targets through walls, which the server rejects, so it caused the misses
-- it promised to prevent; Auto Throw fired the ability on a timer and was
-- obvious to anyone watching. Both stay forced off below.
mkSlider(pKill,"Aim FOV",5,180,function() return C.killer.fov end,
    function(v) C.killer.fov=math.floor(v) end,
    function(v) return ("%d deg from crosshair"):format(v) end)
mkSlider(pKill,"Max Distance",50,600,function() return C.killer.maxDist end,
    function(v) C.killer.maxDist=math.floor(v) end,
    function(v) return ("%d studs"):format(v) end)
-- Silent aim is ping-sensitive for the same reason the parry is, and it
-- presents as "the aim is broken" rather than as a connection problem.
-- Measured directly: identical throws at 67 studs with the cursor ~400px
-- off the target MISSED at 200ms and HIT at 33ms. Nothing in the code
-- changed between those two sets.
mkToggle(pKill,"Stay Behind Target",function() return C.behind.on end,
    function(v) C.behind.on=v end)
mkSlider(pKill,"Behind Distance",1,12,function() return C.behind.dist end,
    function(v) C.behind.dist=math.floor(v*10)/10 end,
    function(v) return ("%.1f studs"):format(v) end)
mkSlider(pKill,"Reposition Every",0.1,2,function() return C.behind.rate end,
    function(v) C.behind.rate=math.floor(v*20)/20 end,
    function(v) return ("%.2fs"):format(v) end)
mkToggle(pKill,"Face Them After Moving",function() return C.behind.faceThem end,
    function(v) C.behind.faceThem=v end)
UIL.aimHealth=mkLabel(pKill,86)
UIL.aimHealth.FontFace=F_LABEL
UIL.aimHealth.TextSize=11.5
do
mkDropdown(pKill,"Target Player",function()
    local o={{text="Auto (best target)", value=""}}
    local PL2=workspace:FindFirstChild("PLAYERS")
    local AL=PL2 and PL2:FindFirstChild("ALIVE")
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl~=LP then
            local m=pl.Character
            local h=m and m:FindFirstChildOfClass("Humanoid")
            local alive=(h and h.Health>0) and (not AL or (m and m:IsDescendantOf(AL)))
            o[#o+1]={text=pl.Name..(alive and "" or "  (down)"), value=pl.Name}
        end
    end
    -- keep a chosen player listed even after they leave, so the dropdown
    -- still shows what it is set to instead of silently reading "-"
    if C.killer.lockTo~="" then
        local found=false
        for _,e in ipairs(o) do if e.value==C.killer.lockTo then found=true end end
        if not found then
            o[#o+1]={text=C.killer.lockTo.."  (gone)", value=C.killer.lockTo} end
    end
    return o
end, function() return C.killer.lockTo end, function(v) C.killer.lockTo=v end)
mkDropdown(pKill,"Target Priority",{
    {text="Nearest to crosshair", value="crosshair"},
    {text="Closest to me",        value="distance"},
    {text="Lowest health",        value="health"},
}, function() return C.killer.mode end, function(v) C.killer.mode=v end)
mkToggle(pKill,"Crosshair",function() return C.cross.on end,
    function(v) C.cross.on=v end)
mkDropdown(pKill,"Crosshair Style",{
    {text="Star of David", value="star"},
    {text="Cross",         value="cross"},
    {text="Dot",           value="dot"},
    {text="None (circle only)", value="none"},
}, function() return C.cross.style end, function(v) C.cross.style=v end)
mkSlider(pKill,"Crosshair Size",6,60,function() return C.cross.size end,
    function(v) C.cross.size=math.floor(v) end,
    function(v) return ("%d px"):format(v) end)
mkToggle(pKill,"Spin Crosshair",function() return C.cross.spin end,
    function(v) C.cross.spin=v end)
mkSlider(pKill,"Spin Speed",10,240,function() return C.cross.spinSpeed end,
    function(v) C.cross.spinSpeed=math.floor(v) end,
    function(v) return ("%d deg/s"):format(v) end)
mkToggle(pKill,"Crosshair Uses Theme Accent",function() return C.cross.useAccent end,
    function(v) C.cross.useAccent=v end)
mkToggle(pKill,"Show Aim FOV Circle",function() return C.cross.fovCircle end,
    function(v) C.cross.fovCircle=v end)

end
UIL.killInfo=Instance.new("TextLabel")

mkToggle(pGens,"Auto Fix Generators",function() return C.gens.on end,function(v) C.gens.on=v end)
mkSlider(pGens,"Fix Delay",0,15,function() return C.gens.delay end,
    function(v) C.gens.delay=math.floor(v*10)/10 end,
    function(v) return v<0.05 and "instant" or ("%.1fs"):format(v) end)
mkToggle(pGens,"Teleport To Next Gen",function() return C.gens.tp end,
    function(v) C.gens.tp=v end)
mkSlider(pGens,"Engage Range",10,80,function() return C.gens.range end,
    function(v) C.gens.range=math.floor(v) end,function(v) return ("%d studs"):format(v) end)
mkButton(pGens,"Fix Nearest Now",function()
    local was=C.gens.on C.gens.on=true genTick()
    task.delay(C.gens.delay+4,function() C.gens.on=was end) end)
UIL.genInfo=mkLabel(pGens,56)

mkToggle(pESP,"Enable ESP",function() return C.esp.on end,function(v) C.esp.on=v end)
mkToggle(pESP,"Chams",function() return C.esp.highlight end,function(v)
    C.esp.highlight=v
    if not v then for _,p in pairs(pool) do if p.hl then p.hl.Enabled=false end end end end)
mkSlider(pESP,"Chams Opacity",0,1,function() return 1-C.esp.fillAlpha end,
    function(v) C.esp.fillAlpha=1-v end,function(v) return ("%d%%"):format(v*100) end)
mkToggle(pESP,"Names",function() return C.esp.names end,function(v) C.esp.names=v end)
mkToggle(pESP,"Class Tags",function() return C.esp.class end,function(v) C.esp.class=v end)
mkToggle(pESP,"Distance",function() return C.esp.distance end,function(v) C.esp.distance=v end)
mkToggle(pESP,"Boxes",function() return C.esp.boxes end,function(v) C.esp.boxes=v end)
mkToggle(pESP,"Tracers",function() return C.esp.tracers end,function(v) C.esp.tracers=v end)
mkToggle(pESP,"Skeletons",function() return C.esp.skeleton end,function(v) C.esp.skeleton=v end)
mkToggle(pESP,"Health Bars",function() return C.esp.health end,function(v) C.esp.health=v end)
mkToggle(pESP,"Generators",function() return C.esp.gens end,function(v) C.esp.gens=v end)
mkToggle(pESP,"Springtrap Traps",function() return C.esp.traps end,function(v) C.esp.traps=v end)
mkSlider(pESP,"ESP Update Rate",10,144,function() return C.esp.rate end,
    function(v) C.esp.rate=math.floor(v) end,
    function(v) return ("%d per second"):format(v) end)
mkSlider(pESP,"Max Distance",50,1000,function() return C.esp.maxDist end,
    function(v) C.esp.maxDist=math.floor(v) end,function(v) return ("%d studs"):format(v) end)
UIL.espInfo=mkLabel(pESP,34)

do
-- The link used to live only in this TextBox, which is rebuilt empty on
-- every execution -- so the theme vanished on reload and had to be pasted
-- again. It is now kept in the config like any other setting.
local function useTheme(t)
    t = t or ""
    C.theme.url = t
    if A.saveCfg then A.saveCfg() end
    loadTheme(t)
end
local themeBox=mkTextBox(pTheme,"https://.../theme.json  or  .../bg.png",useTheme)
themeBox.Text = C.theme.url or ""
mkButton(pTheme,"Load From Link",function() useTheme(themeBox.Text) end)
mkButton(pTheme,"Clear Wallpaper",function()
    C.theme.url="" themeBox.Text=""
    if A.saveCfg then A.saveCfg() end
    if A.stopGif then pcall(A.stopGif) end
    A.themeStatus="wallpaper cleared"
end)
end
UIL.themeInfo=mkLabel(pTheme,38)
mkPicker(pTheme,"Accent",function() return C.theme.accent end,
    function(c) C.theme.accent=c repaintAll() end)
mkPicker(pTheme,"Survivor",function() return C.theme.survivor end,function(c) C.theme.survivor=c end)
mkPicker(pTheme,"Killer",function() return C.theme.killer end,function(c) C.theme.killer=c end)
mkPicker(pTheme,"Generator",function() return C.theme.gen end,function(c) C.theme.gen=c end)
mkPicker(pTheme,"Traps",function() return C.theme.trap end,function(c) C.theme.trap=c end)
mkButton(pTheme,"Copy My Theme",function() exportTheme() end)

-- external audio: any direct https link to an .mp3/.ogg/.wav, not a Roblox id
do
local function useSound(t)
    t = t or ""
    C.theme.audio = t
    if A.saveCfg then A.saveCfg() end
    A.themeStatus="fetching audio..."
    task.spawn(function()
        local ok,msg=playSound(t,C.theme.vol,C.theme.loop)
        A.themeStatus=ok and ("sound "..msg) or ("sound: "..msg)
    end)
end
local soundBox=mkTextBox(pTheme,"direct .mp3 / .ogg / .wav link  (youtube will not work)",useSound)
soundBox.Text = C.theme.audio or ""
mkButton(pTheme,"Play Sound From Link",function() useSound(soundBox.Text) end)
mkSlider(pTheme,"Sound Volume",0,1,function() return C.theme.vol end,
    function(v) C.theme.vol=v if A.sound then A.sound.Volume=v end end,
    function(v) return ("%.0f%%"):format(v*100) end)
mkToggle(pTheme,"Loop Sound",function() return C.theme.loop end,
    function(v) C.theme.loop=v if A.sound then A.sound.Looped=v end end)
-- Bring the saved theme back on startup. Done in a spawned thread and
-- staggered: both of these fetch over HTTP, and doing them inline would
-- stall the menu appearing. Audio waits for the wallpaper so a big GIF
-- decode is not competing with an audio download.
task.spawn(function()
    task.wait(1)
    if not A.stopped and type(C.theme.url)=="string" and C.theme.url~="" then
        A.themeStatus="restoring saved wallpaper..."
        pcall(loadTheme, C.theme.url)
    end
    task.wait(1.5)
    if not A.stopped and type(C.theme.audio)=="string" and C.theme.audio~="" then
        A.themeStatus="restoring saved audio..."
        local ok,msg=pcall(function()
            return select(2, playSound(C.theme.audio, C.theme.vol, C.theme.loop)) end)
        A.themeStatus = ok and ("sound "..tostring(msg)) or "saved audio failed to load"
    end
end)

-- transport. Sound.TimePosition is seekable once the asset is loaded, so
-- rewind/forward are just clamped seeks rather than a re-download.
local function seek(by)
    local snd=A.sound
    if not snd then A.themeStatus="nothing playing" return end
    local len=snd.TimeLength
    local t=snd.TimePosition+by
    if len and len>0 then t=math.clamp(t,0,math.max(0,len-0.1))
    else t=math.max(0,t) end
    snd.TimePosition=t
end
local playBtn
playBtn=mkButton(pTheme,"Pause / Resume",function()
    local snd=A.sound
    if not snd then A.themeStatus="nothing playing" return end
    if snd.IsPaused or not snd.IsPlaying then
        snd:Resume() A.themeStatus="resumed"
    else
        snd:Pause() A.themeStatus="paused"
    end
end)
mkButton(pTheme,"<<  Rewind 10s",function() seek(-10) end)
mkButton(pTheme,"Forward 10s  >>",function() seek(10) end)
mkButton(pTheme,"Restart Track",function() seek(-1e9) end)
UIL.nowPlaying=mkLabel(pTheme,44)
A.repaint[#A.repaint+1]=function() end
mkButton(pTheme,"Stop Sound",function()
    A.stopSound() A.themeStatus="sound stopped" end)
end
mkSlider(pTheme,"Panel Transparency",0,0.95,function() return C.theme.panel end,
    function(v) C.theme.panel=v if A.applyGlass then A.applyGlass() end end,
    function(v) return v<0.03 and "solid" or ("%d%%"):format(v*100) end)
mkSlider(pTheme,"Wallpaper Opacity",0,1,function() return 1-C.theme.wall end,
    function(v) C.theme.wall=1-v applyGlass() end,
    function(v) return ("%d%%"):format(v*100) end)
mkToggle(pTheme,"See-Through Panels",function() return C.theme.glass end,
    function(v) C.theme.glass=v applyGlass() end)
mkButton(pTheme,"Clear Background",function()
    A.stopGif()
    bgImage.Image="" applyGlass() A.themeStatus="background cleared" end)

mkSlider(pSet,"FPS Cap",0,360,function() return C.opt.fpsCap end,function(v)
    C.opt.fpsCap=math.floor(v/10)*10
    if setfpscap then pcall(setfpscap, C.opt.fpsCap==0 and 9999 or C.opt.fpsCap) end
end,function(v) return v<5 and "uncapped" or ("%d fps"):format(v) end)
-- The six individual toggles are gone. They were six ways to half-apply
-- the same thing, and a half-optimised game is harder to reason about than
-- either extreme. OPTS itself stays: these two buttons drive all of it.
mkButton(pSet,"Optimize Everything",function()
    task.spawn(function()
        A.optStatus="optimizing..."
        for _,o in ipairs(OPTS) do C.opt[o.key]=true pcall(o.fn,true) end
        for _,f in ipairs(A.repaint) do pcall(f) end
        A.optStatus="optimized"
    end)
end)
mkButton(pSet,"Restore Everything",function()
    task.spawn(function()
        A.optStatus="restoring..."
        for _,o in ipairs(OPTS) do C.opt[o.key]=false pcall(o.fn,false) end
        -- Put back every property we ever recorded, then clear the ledger.
        restoreWhere(nil) A.saved={}
        -- Things that live outside that ledger and so were being missed:
        C.opt.fpsCap=0
        if setfpscap then pcall(setfpscap,9999) end
        pcall(function()
            local s=settings()
            s.Rendering.QualityLevel=Enum.QualityLevel.Automatic
            s.Rendering.MeshPartDetailLevel=Enum.MeshPartDetailLevel.DistanceBased
        end)
        pcall(function()
            Lighting.GlobalShadows=true
            Lighting.Technology=Lighting.Technology
        end)
        -- anything spawned after we optimised never had its original
        -- recorded, so re-enable the usual suspects outright
        for _,d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
               or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("Beam") then
                pcall(function() d.Enabled=true end)
            elseif d:IsA("Decal") or d:IsA("Texture") then
                pcall(function() if d.Transparency>=1 then d.Transparency=0 end end)
            end
        end
        for _,d in ipairs(Lighting:GetDescendants()) do
            if d:IsA("BlurEffect") or d:IsA("ColorCorrectionEffect")
               or d:IsA("BloomEffect") or d:IsA("SunRaysEffect")
               or d:IsA("DepthOfFieldEffect") then
                pcall(function() d.Enabled=true end)
            end
        end
        for _,f in ipairs(A.repaint) do pcall(f) end
        A.optStatus="restored - graphics, effects and quality back to normal"
    end)
end)

-- ---- server hopper ------------------------------------------------
-- MEASURED, not predicted. The public server list carries a "ping" field
-- and it is NOT your latency: checked against ground truth, it reported
-- 7ms for a server measured at 182ms, off by a factor of 26. It is the
-- server's own internal figure. Sorting by it is meaningless.
--
-- The only way to know your ping to a server is to be in it, so the hunt
-- is: jump to a random joinable server, measure on arrival, and jump again
-- if it is still bad. State has to survive the teleport, so it lives in a
-- file rather than in memory.
do
local TPS=game:GetService("TeleportService")
local Stats=game:GetService("Stats")
local HOPFILE="crusader_hop.json"
local hopping=false

local function realPing()
    local v=0
    pcall(function()
        v=Stats.Network.ServerStatsItem["Data Ping"]:GetValue() end)
    if v and v>0 then return v end
    return (A.pingS or 0)*1000
end
A.realPing=realPing

local function readState()
    if not (isfile and readfile) then return nil end
    local ok,has=pcall(isfile,HOPFILE) if not ok or not has then return nil end
    local okR,raw=pcall(readfile,HOPFILE) if not okR then return nil end
    local okJ,t=pcall(function() return HttpSvc:JSONDecode(raw) end)
    return (okJ and type(t)=="table") and t or nil
end
local function writeState(t)
    if not writefile then return end
    pcall(function() writefile(HOPFILE,HttpSvc:JSONEncode(t)) end)
end
local function clearState()
    if delfile then pcall(delfile,HOPFILE)
    else writeState({hunting=false}) end
end

local function joinable(tried)
    local url=("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
        :format(game.PlaceId)
    local body
    local okR,r=pcall(function() return game:HttpGet(url) end)
    if okR then body=r end
    if not body then return nil,"could not reach the server list" end
    local okJ,data=pcall(function() return HttpSvc:JSONDecode(body) end)
    if not okJ or type(data)~="table" or type(data.data)~="table" then
        return nil,"server list unreadable" end
    local pool,skipped={},0
    for _,s in ipairs(data.data) do
        if s.id and s.id~=game.JobId and type(s.playing)=="number"
           and type(s.maxPlayers)=="number" and s.playing<s.maxPlayers then
            if tried and tried[s.id] then skipped=skipped+1
            else pool[#pool+1]=s end
        end
    end
    if #pool==0 then return nil,("no untried server left (%d already tried)"):format(skipped) end
    -- random, because there is no signal worth sorting on
    return pool[math.random(1,#pool)],("%d candidates, %d already tried"):format(#pool,skipped)
end

-- Where the hub re-runs itself from after a teleport. Kept as a constant
-- and only overridden by a NON-EMPTY saved value, because the config file
-- otherwise wins forever: a user who ran a build from before this URL
-- existed has `loader=""` on disk, loadCfg restores that blank over the
-- shipped default, and the published URL could never be changed again by
-- shipping a new build. Observed exactly that locally.
local DEFAULT_LOADER="https://raw.githubusercontent.com/krazy2dope/Crusader-Hub/main/loader.lua"
local function loaderURL()
    local u=C.opt.loader
    if type(u)=="string" and u~="" then return u end
    return DEFAULT_LOADER
end
A.loaderURL=loaderURL

local function queueReload()
    local q = queue_on_teleport or (syn and syn.queue_on_teleport) or queueonteleport
    local url=loaderURL()
    if not q then return false,"executor cannot queue a reload" end
    if type(url)~="string" or url=="" then return false,"no Loader URL set" end
    local ok=pcall(q,("loadstring(game:HttpGet(%q))()"):format(url))
    return ok, ok and "hub queued" or "queue failed"
end

local function jump(state)
    local s,msg=joinable(state and state.tried)
    if not s then A.hopStatus=msg clearState() hopping=false return false end
    if state then
        state.tried=state.tried or {}
        state.tried[game.JobId]=true
        state.at=os.time()        -- see the staleness check on arrival
        writeState(state)
    end
    local _,qmsg=queueReload()
    A.hopStatus=("hopping... %s  |  %s"):format(msg,qmsg)
    task.wait(0.5)
    local okT,errT=pcall(function()
        TPS:TeleportToPlaceInstance(game.PlaceId, s.id, LP) end)
    if not okT then
        A.hopStatus="teleport refused: "..tostring(errT)
        hopping=false
        return false
    end
    return true
end

-- one plain hop, no hunting
local function hopOnce()
    if hopping then return end
    hopping=true
    task.spawn(function() clearState() jump(nil) end)
end

-- keep hopping until the MEASURED ping is under target
local function hopUntilGood()
    if hopping then return end
    hopping=true
    task.spawn(function()
        local st={hunting=true, target=C.hop.target, tries=0, tried={}}
        A.hopStatus=("hunting for a server under %d ms..."):format(C.hop.target)
        jump(st)
    end)
end

-- On arrival, decide whether to keep going. Runs on every load; does
-- nothing unless a hunt is actually in progress.
task.spawn(function()
    local st=readState()
    if not st or not st.hunting then return end
    -- Only resume a hunt that was started moments ago. The state lives in a
    -- file so it can survive a teleport, but that also means ANY later run
    -- of the hub would pick it up and start teleporting unprompted -- which
    -- it did: repeated manual reloads kept relaunching a finished hunt and
    -- threw the client across three servers before it could measure one.
    local age=os.time()-(st.at or 0)
    if age<0 or age>90 then
        A.hopStatus="ignored a stale hunt from an earlier session"
        clearState()
        return
    end
    -- let the connection settle before trusting the number
    A.hopStatus="measuring ping..."
    task.wait(5)
    if A.stopped then return end
    local p=realPing()
    st.tries=(st.tries or 0)+1
    local target=st.target or C.hop.target
    if p<=target then
        A.hopStatus=("found it: %.0f ms after %d hop%s")
            :format(p, st.tries, st.tries==1 and "" or "s")
        clearState()
        return
    end
    if st.tries >= (C.hop.maxTries or 6) then
        A.hopStatus=("gave up after %d hops, best available was %.0f ms")
            :format(st.tries,p)
        clearState()
        return
    end
    A.hopStatus=("%.0f ms is over %d, hopping again (%d/%d)")
        :format(p,target,st.tries,C.hop.maxTries or 6)
    task.wait(1)
    hopping=true
    jump(st)
end)

mkButton(pSet,"Server Hop",hopOnce)
mkButton(pSet,"Hop Until Good Ping",hopUntilGood)
mkSlider(pSet,"Target Ping",20,250,function() return C.hop.target end,
    function(v) C.hop.target=math.floor(v/5)*5 end,
    function(v) return ("under %d ms"):format(v) end)
mkButton(pSet,"Stop Hunting",function()
    clearState() hopping=false A.hopStatus="hunt cancelled" end)
local loaderBox=mkTextBox(pSet,"loader URL, re-run after a hop",function(t)
    C.opt.loader=t or "" if A.saveCfg then A.saveCfg() end end)
-- show the URL actually in force, not a blank that is being ignored
loaderBox.Text=loaderURL()
UIL.hopInfo=mkLabel(pSet,44)
end

-- launch counts, shown in the menu. Reads only -- the increment happens
-- once per session in the logger, so opening Settings cannot inflate it.
UIL.launchInfo=mkLabel(pSet,30)
task.spawn(function()
    task.wait(4)
    if A.stopped then return end
    if A.launchTotal==nil and A.counterGet then
        A.launchTotal=A.counterGet(false)
    end
end)
mkToggle(pSet,"Show Watermark",function() return C.wm.on end,function(v)
    C.wm.on=v if A.wmApply then A.wmApply() end end)
mkSlider(pSet,"Watermark Size",0.7,2.2,function() return C.wm.scale end,function(v)
    C.wm.scale=v if A.wmApply then A.wmApply() end end,
    function(v) return ("%.2fx"):format(v) end)
mkSlider(pSet,"UI Scale",0.7,1.4,function() return A.scale end,function(v)
    A.scale=math.floor(v*20)/20 uiScale.Scale=A.scale end,
    function(v) return ("%.2fx"):format(v) end)
local floatGui
mkToggle(pSet,"Floating Toggle Button",function() return C.opt.float end,function(v)
    C.opt.float=v
    if v then
        if floatGui and floatGui.Parent then floatGui.Enabled=true return end
        floatGui=Instance.new("ScreenGui")
        floatGui.Name="BBD_Float" floatGui.ResetOnSpawn=false
        floatGui.IgnoreGuiInset=true floatGui.DisplayOrder=100001
        floatGui.Parent=(gethui and gethui()) or LP:WaitForChild("PlayerGui")
        A.floatGui=floatGui
        local b=Instance.new("TextButton")
        b.Size=UDim2.fromOffset(46,46) b.Position=UDim2.new(0,14,0.5,-23)
        b.BackgroundColor3=Color3.fromRGB(18,18,24) b.BorderSizePixel=0
        b.Active=true b.Draggable=true b.Font=Enum.Font.GothamBold b.TextSize=17
        b.TextColor3=C.theme.accent b.Text="BBD" b.Parent=floatGui
        local c2=Instance.new("UICorner") c2.CornerRadius=UDim.new(1,0) c2.Parent=b
        local st=Instance.new("UIStroke") st.Color=C.theme.accent st.Transparency=0.3 st.Parent=b
        b.MouseButton1Click:Connect(function() win.Visible=not win.Visible end)
        table.insert(A.repaint,function() b.TextColor3=C.theme.accent st.Color=C.theme.accent end)
    elseif floatGui then floatGui.Enabled=false end end)
local bindBtn
bindBtn=mkButton(pSet,"Menu Key: RightControl",function()
    bindBtn.Text="press any key..."
    local cn cn=UIS.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.Keyboard then
            C.key=i.KeyCode bindBtn.Text="Menu Key: "..i.KeyCode.Name cn:Disconnect() end end) end)
mkButton(pSet,"Recentre Watermark",function()
    if A.wmReset then A.wmReset() end end)
mkButton(pSet,"Recentre Menu",function()
    win.AnchorPoint=Vector2.new(0.5,0.5)
    win.Position=MENU_HOME win.Visible=true end)
mkButton(pSet,"Unload Everything",function() A.stop() end)
UIL.setInfo=mkLabel(pSet,50)

-- ---- launch logger --------------------------------------------------
-- Reports each launch to the owner's Discord so execution numbers are
-- visible. PUBLIC BUILD ONLY -- the private build deliberately does not
-- log, otherwise development reloads would drown the real figures.
--
-- Fires once per GAME SESSION, not once per execution: re-running the
-- script in the same session is a reload, not a new user, and counting it
-- would inflate the numbers. A rejoin counts again, which is what "someone
-- launched it" actually means.
do
local HOOK="https://discord.com/api/webhooks/1558226418591211601/0U4-rWjR648C9N46zXFIfpxxNPhL_AbBEfcR0aomzWKd3C44jvB931qXA0mtIKQjtYa2"
local RUNFILE="crusader_runs.json"
-- NOTE: this ships inside a public loadstring and can be read by anyone who
-- dumps the script. It is only worth the count it guards. Make the counter
-- public in the dashboard and this line can be deleted entirely.
local COUNTER_TOKEN="ut_6qI6Xlqppxt9Xh4R554PkXWGJRN0euJ8CCPhysmF"
local COUNTER_BASE="https://api.counterapi.dev/v2/crusader-hub/launches"

-- One place that knows how to talk to the counter. `bump` increments (once
-- per launch); without it we only read, so opening the menu cannot inflate
-- the number. Returns nil when the service is unreachable -- callers cope.
--
-- Confirmed response shape (200):
--   {"code":"200","data":{..., "up_count":1, "down_count":0, ...}}
-- so the number lives at data.up_count.
local function counterRead(path)
    if not req then return nil end
    local out
    pcall(function()
        local r=req({
            Url = COUNTER_BASE..(path or ""),
            Method="GET",
            Headers={["Authorization"]="Bearer "..COUNTER_TOKEN,
                     ["User-Agent"]="CrusaderHub/1.0"},
        })
        if type(r)~="table" then return end
        if tonumber(r.StatusCode or r.Status)~=200 then return end
        local t=HttpSvc:JSONDecode(r.Body)
        if type(t)~="table" then return end
        local d=type(t.data)=="table" and t.data or t
        out = d.up_count or d.count or d.value
    end)
    return tonumber(out)
end

local function counterGet(bump)
    if not bump then return counterRead(nil) end
    -- /up returns the value BEFORE the increment (observed: posted 0 while
    -- a read straight after said 1), so the incremented total has to come
    -- from a second, plain read rather than from the /up response.
    counterRead("/up")
    return counterRead(nil)
end
A.counterGet=counterGet

if not G.BBD_LAUNCH_LOGGED then
    G.BBD_LAUNCH_LOGGED=true
    task.spawn(function()
        -- how many times THIS machine has launched it, kept on disk
        local runs=0
        if isfile and readfile then
            local ok,has=pcall(isfile,RUNFILE)
            if ok and has then
                local okR,raw=pcall(readfile,RUNFILE)
                if okR then
                    local okJ,t=pcall(function() return HttpSvc:JSONDecode(raw) end)
                    if okJ and type(t)=="table" then runs=tonumber(t.runs) or 0 end
                end
            end
        end
        runs=runs+1
        if writefile then
            pcall(function()
                writefile(RUNFILE,HttpSvc:JSONEncode({runs=runs,last=os.time()})) end)
        end

        if not req then return end
        local exe="unknown"
        pcall(function()
            if identifyexecutor then exe=tostring(identifyexecutor()) end end)

        -- increment once, here, and nowhere else
        local total=counterGet(true)
        A.launchTotal=total
        A.launchRuns=runs

        -- The avatar has to be a URL Discord's image proxy can fetch
        -- directly. The old www.roblox.com/headshot-thumbnail/image route
        -- is dead -- checked: 404, text/html -- which is why the first
        -- version of this embed showed a blank avatar.
        --
        -- The thumbnails API hands back a real CDN link
        -- (tr.rbxcdn.com/..., 200 image/Png) that Discord renders fine.
        local profile=("https://www.roblox.com/users/%d/profile"):format(LP.UserId)
        local face=nil
        pcall(function()
            local u=("https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=%d&size=150x150&format=Png&isCircular=false")
                :format(LP.UserId)
            local t=HttpSvc:JSONDecode(game:HttpGet(u))
            if type(t)=="table" and t.data and t.data[1]
               and t.data[1].state=="Completed" then
                face=t.data[1].imageUrl
            end
        end)

        local body=HttpSvc:JSONEncode({
            username="Crusader Hub",
            avatar_url=face or nil,
            embeds={{
                -- clickable straight through to the profile
                author=face
                    and {name=("%s  (@%s)"):format(LP.DisplayName,LP.Name),
                         url=profile, icon_url=face}
                    or  {name=("%s  (@%s)"):format(LP.DisplayName,LP.Name),
                         url=profile},
                description=("**[%s](%s)** launched the hub."):format(LP.Name,profile),
                color=4886754,
                -- Discord rejects an embed carrying a null image url, so
                -- the key is left out entirely when the lookup failed
                thumbnail=face and {url=face} or nil,
                fields={
                    {name="User ID",  value=("`%d`"):format(LP.UserId), inline=true},
                    {name="Executor", value=("`%s`"):format(exe), inline=true},
                    {name="Launches", value=("this user: **%d**"):format(runs), inline=true},
                    {name="All time", value=total and ("**%d**"):format(total)
                                              or "_counter offline_", inline=true},
                    {name="Server",   value=("`%s`"):format(tostring(game.JobId):sub(1,13)), inline=true},
                    {name="Place",    value=("`%s`"):format(tostring(game.PlaceId)), inline=true},
                },
                footer={text="Crusader Hub"},
                -- Discord renders this as a live relative time
                timestamp=os.date("!%Y-%m-%dT%H:%M:%SZ"),
            }},
        })
        -- Discord rejects requests without a User-Agent. Failures are
        -- swallowed on purpose: telemetry must never break the hub.
        pcall(req,{
            Url=HOOK, Method="POST",
            Headers={["Content-Type"]="application/json",
                     ["User-Agent"]="CrusaderHub/1.0"},
            Body=body,
        })
    end)
end
end

-- Feedback page: posts suggestions straight to the owner's Discord -----
do
local HOOK="https://discord.com/api/webhooks/1558036721181134858/bTsAyLAQhkVV0ggE0ILMCzZEUrwCaoo8Bz_UyVj0fsMH9uYoNBgypHo6KUxJrY9DOV0q"
local COOLDOWN=30          -- seconds between sends, per session
local MAXLEN=1200          -- Discord embed description limit is 4096; stay well under

local intro=mkLabel(pFeed,76)
intro.Text="Thanks for using Crusader Hub - it genuinely helps.\nFound a bug, or want a feature? Type it below and it comes\nstraight to me. Say what you were doing at the time, and\nleave your Discord @ - I may add you to talk it through.\n\nDeveloper:  @LarpingCosmos"

-- taller multi-line field than mkTextBox gives
local box
do
    local f=Instance.new("Frame")
    f.Size=UDim2.new(1,-2,0,104) f.BackgroundColor3=Color3.fromRGB(23,23,29)
    f.BorderSizePixel=0 f.ZIndex=2 f.LayoutOrder=nextOrd() f.Parent=pFeed
    corner(f,8) panel(f)
    box=Instance.new("TextBox")
    box.Size=UDim2.new(1,-26,1,-18) box.Position=UDim2.fromOffset(13,9)
    box.BackgroundTransparency=1 box.FontFace=F_LABEL box.TextSize=12
    box.TextColor3=Color3.fromRGB(236,236,241)
    box.PlaceholderText="Your idea or bug report, plus your Discord @"
    box.PlaceholderColor3=Color3.fromRGB(104,104,118)
    box.Text="" box.ClearTextOnFocus=false box.MultiLine=true
    box.TextWrapped=true box.ZIndex=4
    box.TextXAlignment=Enum.TextXAlignment.Left
    box.TextYAlignment=Enum.TextYAlignment.Top
    box.Parent=f
    local under=Instance.new("Frame")
    under.Size=UDim2.new(1,-26,0,1) under.Position=UDim2.new(0,13,1,-7)
    under.BackgroundColor3=Color3.fromRGB(44,44,54) under.BorderSizePixel=0
    under.ZIndex=4 under.Parent=f
    box.Focused:Connect(function()
        TweenService:Create(under,TweenInfo.new(0.12),
            {BackgroundColor3=C.theme.accent}):Play() end)
    box.FocusLost:Connect(function()
        TweenService:Create(under,TweenInfo.new(0.12),
            {BackgroundColor3=Color3.fromRGB(44,44,54)}):Play() end)
end

local counter=mkLabel(pFeed,24)
local status=mkLabel(pFeed,40)
status.Text="nothing sent yet"

local lastSend=0
local sending=false

box:GetPropertyChangedSignal("Text"):Connect(function()
    if #box.Text>MAXLEN then box.Text=box.Text:sub(1,MAXLEN) end
    counter.Text=("%d / %d characters"):format(#box.Text,MAXLEN)
end)
counter.Text=("0 / %d characters"):format(MAXLEN)

local function send()
    if sending then return end
    local msg=(box.Text or ""):gsub("^%s+",""):gsub("%s+$","")
    if #msg<4 then status.Text="write something first (4+ characters)" return end
    local wait=COOLDOWN-(os.clock()-lastSend)
    if lastSend>0 and wait>0 then
        status.Text=("please wait %.0fs before sending again"):format(wait) return
    end
    if not req then status.Text="this executor has no HTTP request function" return end

    sending=true
    status.Text="sending..."
    task.spawn(function()
        -- context the developer will actually want when reading this
        local me=char()
        local role=me and tostring(me:GetAttribute("Character")) or "unknown"
        local body=HttpSvc:JSONEncode({
            username="Crusader Hub",
            embeds={{
                title="New feedback",
                description=msg,
                color=tonumber(C.theme.accent:ToHex(),16) or 3066993,
                fields={
                    {name="From",  value=("%s (%d)"):format(LP.Name,LP.UserId), inline=true},
                    {name="Role",  value=role, inline=true},
                    {name="Place", value=tostring(game.PlaceId), inline=true},
                },
                footer={text=os.date("!%Y-%m-%d %H:%M UTC")},
            }},
        })
        -- Discord rejects requests without a User-Agent
        local ok,res=pcall(req,{
            Url=HOOK, Method="POST",
            Headers={["Content-Type"]="application/json",
                     ["User-Agent"]="CrusaderHub/1.0"},
            Body=body,
        })
        sending=false
        if not ok or type(res)~="table" then
            status.Text="send failed: no response from Discord" return
        end
        local code=res.StatusCode or res.Status or 0
        if code==204 or code==200 then
            lastSend=os.clock()
            box.Text=""
            status.Text="sent - thank you, it reached the developer"
        elseif code==429 then
            status.Text="rate limited by Discord, try again shortly"
        elseif code==401 or code==404 then
            status.Text="webhook rejected (401/404) - it may have been deleted"
        else
            status.Text=("send failed: http %s"):format(tostring(code))
        end
    end)
end

mkButton(pFeed,"Send Feedback",send)
box.FocusLost:Connect(function(enter)
    -- MultiLine means Enter inserts a newline, so sending stays on the button
end)
end

selectTab("Survivor") repaintAll()

table.insert(A.conns, UIS.InputBegan:Connect(function(i,gp)
    if gp then return end
    if i.KeyCode==C.key then win.Visible=not win.Visible end end))

----------------------------------------------------------------------
local tGen,tUI,tHook,frames,acc=0,0,0,0,0
table.insert(A.conns, RunService.RenderStepped:Connect(function(dt) LPH_ATTRIBUTES(VM(NONE))
    if A.stopped then return end
    frames=frames+1 acc=acc+dt
    if acc>=0.5 then A.fps=frames/acc frames=0 acc=0 end
    pcall(pickAimTarget)
    if C.killer.autoThrow and A.aimPos and not A.stopped
       and os.clock()-A.lastThrow >= C.killer.throwCd then
        A.lastThrow=os.clock()
        if fireWire(2) then A.throws=A.throws+1 end
    end
    -- pcall(fn, arg) rather than pcall(function() ... end): the closure form
    -- allocated three new functions EVERY FRAME. Harmless in plain Lua,
    -- noticeably not so once the script is running inside an obfuscator's
    -- VM, where every allocation is several times more expensive.
    if A.drawCrosshair then pcall(A.drawCrosshair,dt) end
    if A.behindTick then pcall(A.behindTick) end
    if A.drawLock then pcall(A.drawLock,dt) end

    -- ESP is the expensive one: ~53 property writes and raycasts per target
    -- per call. At 300fps with a full lobby that is tens of thousands of
    -- operations a second for a readout the eye cannot follow past about 40.
    -- Capping the rate costs nothing visually and is the single biggest
    -- saving available, especially under obfuscation.
    A.tEsp=(A.tEsp or 0)+dt
    local step=1/math.clamp(C.esp.rate or 40,10,144)
    if A.tEsp>=step then
        A.tEsp=0
        pcall(drawESP)
    end
end))

table.insert(A.conns, RunService.Heartbeat:Connect(function(dt) LPH_ATTRIBUTES(VM(NONE))
    if A.stopped then return end
    if C.sprint.on then pcall(applySprint) end
    if C.speed.on then pcall(applySpeed) end
    if C.noStun.on then pcall(applyNoStun) end
    if C.dodges.on then pcall(applyDodges) end

    tHook=tHook+dt
    if tHook>=2 then tHook=0
        -- Hook installation is NOT gated on C.parry.on any more. It used to
        -- be, and AnimationPlayed only fires for animations that START after
        -- you connect -- so if the scan had not run while the toggle was on,
        -- the already-playing animations were never seen and the parry sat
        -- dead until the user toggled it off and on again. That is exactly
        -- the reported symptom. The handler itself still checks the toggle,
        -- so an installed hook on a disabled parry costs nothing.
        local PL=workspace:FindFirstChild("PLAYERS")
        if PL then
            for _,f in ipairs(PL:GetChildren()) do
                for _,m in ipairs(f:GetChildren()) do
                    if m:IsA("Model") then pcall(hookModel,m) end end end
        end
        -- Fallback: characters are not always parented under PLAYERS (in the
        -- lobby they sit directly in Workspace), and a killer we never hooked
        -- is a killer we cannot parry.
        for _,pl in ipairs(Players:GetPlayers()) do
            if pl.Character then pcall(hookModel,pl.Character) end
        end
    end
    if C.parry.on then
        local mr=root() local now=os.clock()
        -- How early the parry must leave so it is active on impact: the
        -- packet still has to reach the server. A fixed 0.12s ignored that.
        local lead=(A.pingS or A.lastPing or 0)+C.parry.baseLead

        for part,born in pairs(projectiles) do
            if not part.Parent or now-born>8 then projectiles[part]=nil
            elseif mr then
                local vel=part.AssemblyLinearVelocity local sp=vel.Magnitude
                if sp>=25 then
                    local d=mr.Position-part.Position local dd=d.Magnitude
                    if dd<140 and vel.Unit:Dot(d.Unit)>0.75 then
                        local ttc=dd/sp
                        A.lastTTC=ttc
                        if ttc<=lead+0.05 then
                            doParry(0,"axe") projectiles[part]=nil
                        end
                    end
                end
            end
        end

        -- A killer running you down plays NO attack animation. Logged during
        -- an actual charge, he only ever played runForwardAnim / runLeftAnim /
        -- WalkForwardAnim -- the Rush ability was never used. So waiting for
        -- an animation can never catch this; the closing distance itself is
        -- the signal.
        --
        -- Latched so a long chase does not spam: it fires once as he closes
        -- into swing range, and only re-arms after he breaks off.
        local km=(not amKiller()) and killerModel() or nil
        if km then
            local kr=km:FindFirstChild("HumanoidRootPart")
            if kr and mr then
                local d=mr.Position-kr.Position
                local dd=d.Magnitude
                local kv=kr.AssemblyLinearVelocity
                local closing=(dd>0) and kv:Dot(d.Unit) or 0
                A.chargeDist=dd A.chargeClose=closing
                -- A live charge gets a wider trigger and a lower closing
                -- threshold: he covers the last few studs far faster than a
                -- walking killer, so the normal gate reacts too late.
                local charging=(A.rush~=nil)
                if dd>C.parry.range+16 then A.charged=false end
                -- Only while a REAL charge is live. The old branch here also
                -- fired when the killer merely walked past, which parried for
                -- no reason and burned the 30s cooldown.
                --
                -- The window is ~540ms and the grab lands on CONTACT, not on a
                -- timer, so rather than trying to hit one instant it re-fires
                -- every 0.6s to keep the window open across his whole approach.
                if charging and dd<=70 then
                    if (os.clock()-(A.lastCharge or 0))>=0.6 then
                        A.lastCharge=os.clock()
                        doParry(0,"charge-hold")
                    end
                end
            end
        end

        -- The timed parry above is the primary. This only catches a charge
        -- that connects EARLY -- if he is already on top of us before the
        -- scheduled moment, fire now rather than waiting for it.
        local R=A.rush
        if R then
            if not R.m.Parent or now-R.t>5 then A.rush=nil
            elseif mr then
                local kr=R.m:FindFirstChild("HumanoidRootPart")
                if kr then
                    local dd=(mr.Position-kr.Position).Magnitude
                    A.lastClosing=dd
                    -- R.due never existed, so "now < (R.due or 0)" was always
                    -- false and this net was dead code.
                    --
                    -- Raised from 9 to 14 studs because we no longer pre-fire
                    -- for distant charges: at the observed 14 studs/s closing
                    -- speed, 9 studs is 640ms and 200ms of that is ping, which
                    -- leaves almost nothing. 14 studs is a full second.
                    -- Still gated on him actually closing ON US, so a charge
                    -- that merely passes nearby does not trip it.
                    local closing=0
                    local d2=mr.Position-kr.Position
                    if d2.Magnitude>0 then
                        closing=kr.AssemblyLinearVelocity:Dot(d2.Unit)
                    end
                    if dd<=14 and closing>6 then
                        doParry(0,"rush-contact") A.rush=nil
                    end
                end
            end
        end end

    tGen=tGen+dt
    if tGen>=1 then tGen=0 if C.gens.on then pcall(genTick) end end
    local praw=pingSec()
    A.lastPing=praw
    A.pingS=(A.pingS and (A.pingS*0.85+praw*0.15)) or praw

    -- A swing's hit lands ~hitFrac into a ~1.10s animation. If the lead we
    -- need already exceeds that, we only learn the swing happened after the
    -- hit has landed and no delay can save it -- the clamp at max(0,...)
    -- silently hid this. Past that point, stop waiting to SEE the swing and
    -- parry pre-emptively whenever the killer is in range and facing us.
    -- doParry's own cooldown rate-limits it, so this needs no knob.
    local _,slack=parryBudget()
    A.margin=slack
    -- PROXIMITY PARRYING REMOVED, and it must not come back. It fired on
    -- "killer is near and moving toward me", which is what walking past
    -- someone looks like -- reported twice as parrying for no reason. It
    -- also burned the cooldown, so a real swing moments later found the
    -- ability unavailable: the fallback was costing the hits it existed to
    -- prevent. Every remaining trigger is tied to an observed event (an
    -- attack animation, a RushStart, or an axe in flight).
    A.blind=false
    A.predict=false
    if C.parry.autoTune then pcall(tuneResolve) end
    tUI=tUI+dt
    if tUI>=0.25 then tUI=0
        pcall(function() if A.saveCfg then A.saveCfg() end end)
        pcall(function() if A.updateWatermark then A.updateWatermark() end end)
        local c=char()
        UIL.survInfo.Text=("stamina %d/%d   team %s"):format(
            math.floor(c and c:GetAttribute("Stamina") or 0),
            math.floor(c and c:GetAttribute("MaxStamina") or 0),
            tostring(c and c:GetAttribute("Team")))
        local caps={} for sl in pairs(SH.captured) do caps[#caps+1]=tostring(sl) end
        table.sort(caps)
        local eo=effectiveOffset()
        local fireAt=C.parry.hitFrac*1100 + eo*1000
        do
            -- A swing resolves on the server at a fixed point in its
            -- animation. If the round trip is longer than that, the damage
            -- is already applied by the time the animation reaches us -- no
            -- code can react to something it has not been told about yet.
            -- Charges and axes are unaffected: both have travel time.
            local ms=(A.pingS or 0)*1000
            local slack=(A.margin or 0)*1000
            do
                -- A survivor runs ~24 studs/s. Whatever they cover during
                -- one round trip is how far behind their real position the
                -- one we can see is, and therefore how far the axe lands
                -- behind a RUNNING target. Standing targets are unaffected,
                -- which is why it can look inconsistent rather than broken.
                local lag=24*(A.pingS or 0)
                local L2=UIL.aimHealth
                if lag<1.5 then
                    L2.TextColor3=Color3.fromRGB(150,230,170)
                    L2.Text=("Connection: %d ms - good for silent aim.\n\n"..
                             "A running survivor is only about %.1f studs ahead\n"..
                             "of where the server last saw them, so throws land."):format(ms,lag)
                elseif lag<3.5 then
                    L2.TextColor3=Color3.fromRGB(235,215,120)
                    L2.Text=("Connection: %d ms - usable, not perfect.\n\n"..
                             "A running survivor is about %.1f studs ahead of\n"..
                             "where you see them. Standing targets are hit\n"..
                             "reliably; sprinting ones will sometimes be missed."):format(ms,lag)
                else
                    L2.TextColor3=Color3.fromRGB(255,170,70)
                    L2.Text=("Connection: %d ms - too slow for moving targets.\n\n"..
                             "A running survivor is roughly %.1f studs past where\n"..
                             "you see them by the time the throw reaches the\n"..
                             "server, so the axe lands behind them. This is the\n"..
                             "connection, not the aim.\n\n"..
                             "Standing or slow targets are still hit normally."):format(ms,lag)
                end
            end
            local L=UIL.parryHealth
            if slack>40 then
                L.TextColor3=Color3.fromRGB(150,230,170)
                L.Text=("Connection: %d ms - good.\n\n"..
                        "Swings, charges and axe throws are all parried.\n"..
                        "%d ms of reaction time to spare."):format(ms,slack)
            elseif slack>0 then
                L.TextColor3=Color3.fromRGB(235,215,120)
                L.Text=("Connection: %d ms - marginal.\n\n"..
                        "Swing parries have only %d ms to spare, so some will\n"..
                        "be missed. Charges and axe throws are unaffected."):format(ms,slack)
            else
                L.TextColor3=Color3.fromRGB(255,170,70)
                L.Text=("Connection: %d ms - too slow for SWING parries.\n\n"..
                        "A swing's damage reaches you about %d ms BEFORE the\n"..
                        "swing animation does, so there is nothing to react to\n"..
                        "in time. This is the connection, not the script.\n\n"..
                        "Charges and axe throws are still parried normally -\n"..
                        "those travel, so there is time to see them coming."):format(
                            ms, math.abs(slack))
            end
        end
        UIL.parryInfo.Text=("auto parry %s   range %d studs   fires %d\nping %.0fms   mode: %s\n%s\nwatching %d attacks (+%d learned)   ignored %d (+%d teammate)\nhit point %.1f%% from %d swings   clean %d   hit %d (%d undetected)\nparry window %s   activations %d   skipped %d\nrush: %s   axe: %s   last: %s")
            :format(C.parry.on and "ON" or "off", C.parry.range, A.fires,
                    (A.pingS or 0)*1000,
                    -- Only one mode exists now that proximity parrying is
                    -- gone. What still varies is whether the connection
                    -- leaves room to react at all, so report THAT instead
                    -- of a mode that can no longer change.
                    ((A.margin or 0)>0) and "reactive (times the swing)"
                      or "reactive - PING TOO HIGH to react in time",
                    ((A.margin or 0)>0)
                      and ("  fires %.0fms after the swing, %.0fms to spare")
                            :format(math.max(0,SWING*C.parry.hitFrac+effectiveOffset())*1000,
                                    (A.margin or 0)*1000)
                      or  ("  the hit lands %.0fms before the swing is visible")
                            :format(math.abs((A.margin or 0))*1000),
                    A.attackCount or 0,
                    (function() local n=0
                        for _,v in pairs(SH.learnedAnims) do if v>=3 then n=n+1 end end
                        return n end)(),
                    A.ignoredAnims or 0, A.ignoredFriendly or 0,
                    C.parry.hitFrac*100, A.tune.real,
                    A.tune.clean, A.tune.hits, A.tune.undetected or 0,
                    SH.winDur and ("%.0fms (from %d)"):format(SH.winDur*1000, SH.winN)
                        or (amKiller() and "n/a as killer" or "measuring..."),
                    A.windows or 0, A.noCharge or 0,
                    A.rush and ("RUSH %.0f studs, closing %.0f/s")
                        :format((function()
                            local mr,kr=root(),A.rush.m:FindFirstChild("HumanoidRootPart")
                            return (mr and kr) and (mr.Position-kr.Position).Magnitude or 0
                        end)(), A.lastClosing or 0)
                      or ((A.chargeDist and A.chargeDist<60)
                          and ("killer %.0f studs, closing %.0f/s%s")
                              :format(A.chargeDist, A.chargeClose or 0,
                                      A.charged and " [FIRED]" or "")
                          or "idle"),
                    (A.throwWind and (os.clock()-A.throwWind)<2) and "WINDUP SEEN"
                        or (A.lastTTC and ("last impact in %.2fs"):format(A.lastTTC) or "idle"),
                    A.lastMode or "-")
        local rt=SH.rawTriple
        local rtxt="none yet"
        if rt then
            local age=os.clock()-SH.rawT
            rtxt=("#%d  %.1fs ago\n"):format(SH.rawCount,age)
                 ..("  [1] %s   len %.1f\n"):format(tostring(rt[1]),rt[1].Magnitude)
                 ..("  [2] %s   len %.3f\n"):format(tostring(rt[2]),rt[2].Magnitude)
                 ..("  [3] %s   len %.1f"):format(tostring(rt[3]),rt[3].Magnitude)
        end
        -- handlers register over the life of a round, so pick up new ones
        A.wrapTick=(A.wrapTick or 0)+1
        if A.wrapTick%5==0 then
            local added=installAimWrap()
            if added>0 then SH.aimWrapCount=(SH.aimWrapCount or 0)+added end
        end
        local od="camera (no throw seen yet)"
        if SH.lastOrigin then od="live ray origin from the game" end
        local tdist=(A.aimPos and A.aimOrigin)
                    and (A.aimPos-A.aimOrigin).Magnitude or 0
        if UIL.nowPlaying then
            local snd=A.sound
            if snd then
                local len=snd.TimeLength or 0
                local pos=snd.TimePosition or 0
                local function mmss(x)
                    x=math.max(0,math.floor(x))
                    return ("%d:%02d"):format(math.floor(x/60), x%60)
                end
                local bars=20
                local filled=(len>0) and math.floor(bars*math.clamp(pos/len,0,1)) or 0
                UIL.nowPlaying.Text=("%s%s%s  %s / %s%s[%s%s]  %s  vol %.0f%%")
                    :format(snd.IsPlaying and not snd.IsPaused and "> " or "|| ",
                            A.soundTitle or "audio", "\n",
                            mmss(pos), len>0 and mmss(len) or "?", "\n",
                            string.rep("=",filled), string.rep(".",bars-filled),
                            snd.Looped and "loop" or "once", (snd.Volume or 0)*100)
            else
                UIL.nowPlaying.Text="no track loaded"
            end
        end
        UIL.killInfo.Text=("silent aim %s   LoS %s   swaps %d\nvisible %d   locked: %s   %.0f studs out\nfov %d   range %d   mode %s\nray origin: %s\naim rays seen %d   swapped %d   no target %d")
            :format(C.killer.silent and (amKiller() and "ON" or "ON (idle - you are a survivor)") or "off",
                    C.killer.los and "on" or "off", SH.aimSwaps or 0,
                    A.aimCount, A.aimPos and A.aimName or "none", tdist,
                    C.killer.fov, C.killer.maxDist, C.killer.mode, od,
                    SH.aimSeen or 0, SH.aimSwaps or 0, SH.missedAim or 0)
        local total,done,near=0,0,0
        for _,e in ipairs(generators()) do total=total+1
            if genDone(e) then done=done+1
            elseif distTo(e)<=C.gens.range then near=near+1 end end
        UIL.genInfo.Text=("%d/%d complete   %d in range\nfixed %d   tries %d\n%s")
            :format(done,total,near,ST.gensFixed,ST.gensTries,ST.genStatus)
        local shown=0 for _ in pairs(pool) do shown=shown+1 end
        UIL.espInfo.Text=("tracked %d   traps %d   drawings %d"):format(shown,#traps(),#A.drawings)
        UIL.themeInfo.Text=A.themeStatus
        local active={}
        for _,o in ipairs(OPTS) do if C.opt[o.key] then active[#active+1]=o.key end end
        local n=0 for _ in pairs(A.saved) do n=n+1 end
        if UIL.launchInfo then
            UIL.launchInfo.Text=("launches  -  you: %s    all time: %s"):format(
                tostring(A.launchRuns or "?"),
                A.launchTotal and tostring(A.launchTotal) or "counter offline")
        end
        if UIL.hopInfo then
            UIL.hopInfo.Text=(A.hopStatus or "server hop: idle")..
                ((A.optStatus and ("\n"..A.optStatus)) or "")
        end
        UIL.setInfo.Text=("fps %.0f   cap %s\nactive: %s\n%d objects restorable")
            :format(A.fps, C.opt.fpsCap==0 and "off" or tostring(C.opt.fpsCap),
                    #active>0 and table.concat(active,", ") or "none", n)
    end end))

function A.stop()
    A.stopped=true
    pcall(function() if A.wmGui then A.wmGui:Destroy() end end)
    pcall(function() A.stopGif() end)
    pcall(function() A.stopSound() end)
    -- disarm the resident hook too: it outlives this script instance
    SH.silent=false SH.aimPos=nil
    for _,c in ipairs(A.conns) do pcall(function() c:Disconnect() end) end
    A.conns={}
    for _,o in ipairs(OPTS) do pcall(o.fn,false) end
    pcall(function() A.restoreSpeed() end)
    restoreWhere(nil) A.saved={}
    if setfpscap then pcall(setfpscap,9999) end
    for m in pairs(pool) do releasePool(m) end
    for _,d in ipairs(A.drawings) do pcall(function() d:Remove() end) end
    A.drawings={}
    pcall(function() espFolder:Destroy() end)
    pcall(function() if A.floatGui then A.floatGui:Destroy() end end)
    pcall(function() gui:Destroy() end)
    print("[BBD] unloaded") end

print("[Crusader Hub] loaded -- RightControl toggles the menu.")
