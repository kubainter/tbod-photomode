local core = require("lib.core")
local State = core.State
local Config = core.Config
local Subsystem = core.Subsystem
local logMsg = core.logMsg
local dbg = core.dbg
local M = {}

M.spawnedClones = {}
M.spawnedWeapons = {} -- index-aligned spawned weapon actors
M.knownWeapons = {}   -- set: every weapon actor PM ever spawned (main+offhand)
M.hijackedComps = {}  -- weapon comp -> saved orig state (native SheathedWeaponMesh repurposed in-hand)
M.weaponDraw = {}     -- weapon comp -> hand-socket draw params (re-draw after sheathe)
M.spawnedProps = {}   -- targetIdx -> prop actor, RIGHT hand (book, spoon...)
M.spawnedPropsL = {}  -- targetIdx -> prop actor, LEFT hand
M.propKeys = {}       -- targetIdx -> resolved propDef table, right hand (detect prop changes)
M.propKeysL = {}      -- targetIdx -> resolved propDef table, left hand
M.cloneInfos = {}       -- index -> { label, family, canUseWeapon, appearance }
M.poseMetadata = {}     -- targetIdx -> { z_offset, ground }
M.coenMirror = {}       -- clone -> { keep={name->true}, pending={src,dst} } player visual mirror
M.cloneOrigLocs = {}    -- index -> initial spawn location {X, Y, Z}
M.cloneOrigRots = {}    -- index -> initial spawn rotation {Pitch, Yaw, Roll}

-- UObject userdata wrappers can differ for the same underlying object;
-- compare by address (fall back to full name).
local function sameObject(a, b)
    if a == b then return true end
    if not (a and b) then return false end
    local okA, pa = pcall(function() return a:GetAddress() end)
    local okB, pb = pcall(function() return b:GetAddress() end)
    if okA and okB and pa and pb then return pa == pb end
    local okN, na = pcall(function() return a:GetFullName() end)
    local okM, nb = pcall(function() return b:GetFullName() end)
    return okN and okM and na == nb
end

-- Register a spawned weapon actor so destroyAll can always find it again.
-- Registered at creation time — after the owning CombatComponent dies its
-- pointer reads as nil, so "dead owner" can never identify orphans later.
local function trackWeapon(w)
    if w and w:IsValid() then M.knownWeapons[w] = true end
end

-- Extract valid weapon actors from a CombatComponent's SpawnedWeapons map
-- into a plain Lua table. pairs() works when UE4SS hands us a converted Lua
-- table; ForEach covers the raw TMap userdata form.
local function collectWeapons(mapObj)
    local out = {}
    if not mapObj then return out end
    pcall(function()
        for _, w in pairs(mapObj) do
            if w and w:IsValid() then out[#out + 1] = w end
        end
    end)
    if #out == 0 and type(mapObj) == "userdata" then
        pcall(function()
            mapObj:ForEach(function(_, w)
                if w and w:IsValid() then out[#out + 1] = w end
            end)
        end)
    end
    return out
end

-- Iterate a reflected TMap: pairs() silently yields nothing on raw TMap
-- userdata; ForEach covers the userdata form.
local function forEachMapEntry(mapObj, fn)
    if not mapObj then return end
    local seen = false
    pcall(function()
        for k, v in pairs(mapObj) do
            seen = true
            fn(k, v)
        end
    end)
    if not seen and type(mapObj) == "userdata" then
        pcall(function()
            mapObj:ForEach(function(k, v) fn(k, v) end)
        end)
    end
end

-- Forward declaration — applyWeaponState cleans up stale weapons before
-- destroyWeaponActor's definition appears later in the file.
local destroyWeaponActor

-- First component of a class on an actor (K2_GetComponentsByClass wrapper).
local function findActorComponent(actor, classPath)
    local cls = core.findStatic(classPath)
    if not (cls and actor and actor:IsValid()) then return nil end
    local ok, list = pcall(function() return actor:K2_GetComponentsByClass(cls) end)
    if ok and type(list) == "table" then
        for _, c in pairs(list) do
            if c and c:IsValid() then return c end
        end
    end
    return nil
end

-- SetLeaderPoseComponent requires a shared USkeleton — binding a mismatched
-- comp makes bone-transform refresh write out of bounds (game-thread AV).
local function sameSkeleton(a, b)
    local skA, skB
    pcall(function() local m = a:GetSkinnedAsset() if m then skA = m.Skeleton end end)
    pcall(function() local m = b:GetSkinnedAsset() if m then skB = m.Skeleton end end)
    if not (skA and skB) then return nil end
    return sameObject(skA, skB)
end

-- ApplyAppearance spawns garment/groom/equipment comps asynchronously; some
-- bind to a non-animating mesh or the actor root -> gear floats regardless of
-- pose. Rebind skinned followers to the animated leader, reattach socketed
-- statics, hide what cannot be placed.
local function fixupAppearanceAttachments(clone, tag)
    if not (clone and clone:IsValid()) then return end
    local skCls = core.findStatic("/Script/Engine.SkeletalMeshComponent")
    if not skCls then return end
    local okL, list = pcall(function() return clone:K2_GetComponentsByClass(skCls) end)
    if not (okL and type(list) == "table") then return end

    -- Same leader pick as poses.findAnimMesh: named fields first, else the
    -- non-follower comp with the most bones.
    local leader
    for _, f in ipairs({ "LeaderMesh", "Mesh" }) do
        local c; pcall(function() c = clone[f] end)
        if c and c:IsValid() then
            local nb = 0; pcall(function() nb = c:GetNumBones() end)
            if nb > 0 then leader = c break end
        end
    end
    if not leader then
        local best = -1
        for _, c in pairs(list) do
            if c and c:IsValid() then
                local follower = false
                pcall(function()
                    local lp = c.LeaderPoseComponent
                    follower = lp ~= nil and lp:IsValid()
                end)
                local nb = -1; pcall(function() nb = c:GetNumBones() end)
                if not follower and nb > best then best, leader = nb, c end
            end
        end
    end
    if not leader then return end

    local noneName
    pcall(function() noneName = FName("None") end)
    local rebound, skipped = 0, 0
    for _, c in pairs(list) do
        if c and c:IsValid() and not sameObject(c, leader) then
            local bound, hadLeader = false, false
            pcall(function()
                local lp = c.LeaderPoseComponent
                hadLeader = lp ~= nil
                bound = lp ~= nil and lp:IsValid() and sameObject(lp, leader)
            end)
            if not bound then
                -- Bind only provably-compatible skeletons (mismatch -> AV in
                -- bone refresh); unreadable skeleton = trust native intent.
                local compat = sameSkeleton(c, leader)
                local canBind = (compat == true) or (compat == nil and hadLeader)
                if canBind then
                    pcall(function() c:SetLeaderPoseComponent(leader) end)
                    rebound = rebound + 1
                else
                    -- Never hide mismatched comps — head/hair/face rigs
                    -- legitimately use their own skeleton (socket-attached).
                    skipped = skipped + 1
                end
            end
            -- Manually spawned garment comps (Coen outfit fallback) arrive
            -- unparented — park them on the leader.
            local parent
            pcall(function() parent = c:GetAttachParent() end)
            if not (parent and parent:IsValid()) then
                pcall(function() c:K2_AttachToComponent(leader, noneName, 0, 0, 0, false) end)
            end
        end
    end
    if skipped > 0 then
        logMsg("Spawner: %s — skipped %d skinned comps (skeleton mismatch)", tag, skipped)
    end

    -- Only refresh bone transforms when we actually changed bindings —
    -- the native call walks every follower and writes through a null
    -- scene-proxy path when a bound comp is incompatible (AV on GT).
    if rebound > 0 then
        local cac; pcall(function() cac = clone.AppearanceComponent end)
        if cac and cac:IsValid() then
            pcall(function() cac:LeaderMeshRefreshBoneTransforms() end)
        end
    end

    -- Statics that missed a skeletal parent float at their own transform.
    -- Socketed ones re-attach to the leader at the same socket; the rest are
    -- equipment previews we cannot place -> hide them.
    local stCls = core.findStatic("/Script/Engine.StaticMeshComponent")
    local reattached, hidden = 0, 0
    if stCls then
        local okS, slist = pcall(function() return clone:K2_GetComponentsByClass(stCls) end)
        if okS and type(slist) == "table" then
            for _, st in pairs(slist) do
                if st and st:IsValid() then
                    local parent
                    pcall(function() parent = st:GetAttachParent() end)
                    local onSkinned = false
                    if parent and parent:IsValid() then
                        pcall(function() onSkinned = parent:IsA(skCls) end)
                    end
                    if not onSkinned then
                        local sock, moved
                        pcall(function() sock = st:GetAttachSocketName() end)
                        if sock then
                            pcall(function()
                                if leader:DoesSocketExist(sock) then
                                    st:K2_AttachToComponent(leader, sock, 2, 2, 0, false)
                                    moved = true
                                end
                            end)
                        end
                        if moved then
                            reattached = reattached + 1
                        else
                            pcall(function() st:SetVisibility(false, true) end)
                            hidden = hidden + 1
                            local nm; pcall(function() nm = st:GetName() end)
                            logMsg("Spawner: %s — hid stray static '%s'", tag, tostring(nm))
                        end
                    end
                end
            end
        end
    end

    -- Groom (strand hair) components that never got a mesh parent.
    local gCls = core.findStatic("/Script/HairStrandsCore.GroomComponent")
    if gCls then
        local okG, glist = pcall(function() return clone:K2_GetComponentsByClass(gCls) end)
        if okG and type(glist) == "table" then
            for _, g in pairs(glist) do
                if g and g:IsValid() then
                    local parent
                    pcall(function() parent = g:GetAttachParent() end)
                    local onMesh = false
                    if parent and parent:IsValid() then
                        pcall(function() onMesh = parent:IsA(skCls) end)
                    end
                    if not onMesh then
                        local head
                        for _, f in ipairs({ "HeadMeshComponent", "HeadMesh", "HairMeshComponent" }) do
                            local c; pcall(function() c = clone[f] end)
                            if c and c:IsValid() then head = c break end
                        end
                        local tgt = head or leader
                        local okA = pcall(function() g:K2_AttachToComponent(tgt, "head", 0, 0, 0, false) end)
                        if not okA then pcall(function() g:AttachToComponent(tgt, "head", 0, 0, 0, false) end) end
                        rebound = rebound + 1
                    end
                end
            end
        end
    end

    if rebound + reattached + hidden > 0 then
        logMsg("Spawner: %s — appearance fixup: %d skinned rebound, %d statics reattached, %d strays hidden",
               tag, rebound, reattached, hidden)
    end
end

-- Copy skinned asset + materials + visibility from a player skinned comp to
-- a clone comp. Returns false when the source carries no asset yet — garment
-- assets stream in async, so callers queue a retry instead of giving up.
local function copyVisuals(src, dst)
    local asset
    pcall(function() asset = src:GetSkinnedAsset() end)
    if not (asset and asset:IsValid()) then
        pcall(function() asset = src.SkeletalMesh end)
    end
    if not (asset and asset:IsValid()) then return false end
    local okAsset = pcall(function() dst:SetSkinnedAssetAndUpdate(asset, true) end)
    if not okAsset then pcall(function() dst:SetSkeletalMeshAsset(asset) end) end
    if not okAsset then pcall(function() dst:SetSkeletalMesh(asset) end) end
    local nm = 0; pcall(function() nm = src:GetNumMaterials() end)
    for i = 0, nm - 1 do
        local m; pcall(function() m = src:GetMaterial(i) end)
        if m and m:IsValid() then pcall(function() dst:SetMaterial(i, m) end) end
    end
    -- Mirror visibility too — the player class carries hidden
    -- alternate-form meshes (wolf/vampire); without this they all render
    -- on the clone at once, looking like stacked NPCs.
    pcall(function() dst:SetVisibility(src:IsVisible(), true) end)
    pcall(function() dst:SetHiddenInGame(src.bHiddenInGame == true, true) end)
    return true
end

local function compHasAsset(c)
    local ok = false
    pcall(function()
        local a = c:GetSkinnedAsset()
        ok = a ~= nil and a:IsValid()
    end)
    return ok
end

-- UObject:GetName() is not exposed in this UE4SS build (errors under pcall).
-- GetFName():ToString() works; GetFullName's last segment is the fallback.
local function compName(c)
    local n
    pcall(function() n = c:GetFName():ToString() end)
    if n and n ~= "" then return n end
    pcall(function()
        local fn = c:GetFullName()
        if fn then n = fn:match("[^%.:]+$") end
    end)
    return n
end

-- Short asset name for diagnostics ("SK_HMA_..._A" out of the full path).
local function assetName(c)
    local a; pcall(function() a = c:GetSkinnedAsset() end)
    if not (a and a:IsValid()) then return nil end
    local fn; pcall(function() fn = a:GetFullName() end)
    if fn then return fn:match("[^%.:]+$") end
    return "?"
end

-- The Coen clone is the SAME class as the player — mirror the player's
-- current visual state directly onto same-named skinned comps (assets +
-- materials). Bypasses the appearance/inventory pipeline entirely.
local function copyPlayerVisuals(clone, pawn, nativeOK)
    local smCls = core.findStatic("/Script/Engine.SkeletalMeshComponent")
    if not smCls then return 0 end
    local okC, clist = pcall(function() return clone:K2_GetComponentsByClass(smCls) end)
    local okP, plist = pcall(function() return pawn:K2_GetComponentsByClass(smCls) end)
    if not (okC and okP and type(clist) == "table" and type(plist) == "table") then return 0 end

    local byName = {}
    for _, src in pairs(plist) do
        if src and src:IsValid() then
            local n = compName(src)
            if n then byName[n] = src end
        end
    end

    -- Clone leader (same pick as fixupAppearanceAttachments).
    local cleader
    for _, f in ipairs({ "LeaderMesh", "Mesh" }) do
        local c; pcall(function() c = clone[f] end)
        if c and c:IsValid() then
            local nb = 0; pcall(function() nb = c:GetNumBones() end)
            if nb > 0 then cleader = c break end
        end
    end
    if not cleader then
        local best = -1
        for _, c in pairs(clist) do
            if c and c:IsValid() then
                local follower = false
                pcall(function()
                    local lp = c.LeaderPoseComponent
                    follower = lp ~= nil and lp:IsValid()
                end)
                local nb = -1; pcall(function() nb = c:GetNumBones() end)
                if not follower and nb > best then best, cleader = nb, c end
            end
        end
    end
    if not cleader then return 0 end

    -- `keep` = names of clone comps allowed to render; `pending` = copies to
    -- retry while source assets stream in. The clone's own BeginPlay pipeline
    -- keeps spawning comps after this pass — reassertPlayerMirror re-hides
    -- anything not in `keep` on every pulse.
    local mirror = { keep = {}, pending = {}, followers = {}, nativeOK = nativeOK }
    M.coenMirror[clone] = mirror

    local copied, added = 0, 0
    local matched = {}
    for _, cc in pairs(clist) do
        if cc and cc:IsValid() then
            local n = compName(cc)
            local src = n and byName[n]
            if src then
                matched[src] = true
                if copyVisuals(src, cc) then
                    copied = copied + 1
                    if n then mirror.keep[n] = true end
                    logMsg("Spawner: coen mirror '%s' <= '%s' (asset=%s vis=%s)",
                           tostring(n), tostring(compName(src)),
                           tostring(assetName(src)), tostring(src:IsVisible()))
                else
                    -- Player's same-named comp has no skinned asset (yet —
                    -- async streaming): hide the clone's default mesh or the
                    -- naked CDO body renders as a second figure; retry later.
                    pcall(function() cc:SetVisibility(false, true) end)
                    pcall(function() cc:SetHiddenInGame(true, true) end)
                    mirror.pending[#mirror.pending + 1] = { src = src, dst = cc }
                end
            else
                -- No counterpart on the player (the clone's own runtime
                -- garment comps from BeginPlay) — the player isn't rendering
                -- this, so the clone shouldn't either. Exact mirror.
                if compHasAsset(cc) then
                    pcall(function() cc:SetVisibility(false, true) end)
                    pcall(function() cc:SetHiddenInGame(true, true) end)
                    logMsg("Spawner: coen hid unmatched '%s' (asset=%s)",
                           tostring(n), tostring(assetName(cc)))
                end
            end
        end
    end

    -- Player garment comps have no name-matched counterpart on the clone, and
    -- spawned followers render in BIND POSE (garment skeletons can't
    -- leader-bind). Garments are slot-synced onto the clone's OWN garment
    -- comps in reassertPlayerMirror — the native pipeline poses those.

    -- Hidden comps must keep evaluating the pose — the anim-driving leader
    -- may itself be hidden; OnlyTickPoseWhenRendered would freeze followers
    -- in T-pose. AlwaysTickPoseAndRefreshBones = 0.
    for _, c in pairs(clist) do
        if c and c:IsValid() then
            pcall(function() c.VisibilityBasedAnimTickOption = 0 end)
        end
    end
    local rb; pcall(function() rb = cleader.VisibilityBasedAnimTickOption end)
    logMsg("Spawner: coen mirror — keep=%d pending=%d leaderTickOpt=%s",
           (function() local n = 0 for _ in pairs(mirror.keep) do n = n + 1 end return n end)(),
           #mirror.pending, tostring(rb))
    return copied + added
end

-- Re-enforce the player mirror on a Coen clone: the clone's own appearance
-- pipeline spawns comps asynchronously — without re-runs they pop in as a
-- second body. Also retries pending copies whose assets were still streaming.
local function reassertPlayerMirror(clone)
    local mirror = M.coenMirror and M.coenMirror[clone]
    if not (mirror and clone and clone:IsValid()) then return end
    local smCls = core.findStatic("/Script/Engine.SkeletalMeshComponent")
    if not smCls then return end
    local okL, list = pcall(function() return clone:K2_GetComponentsByClass(smCls) end)
    if not (okL and type(list) == "table") then return end

    -- Leader pick — same rules as fixupAppearanceAttachments.
    local cleader
    for _, f in ipairs({ "LeaderMesh", "Mesh" }) do
        local c; pcall(function() c = clone[f] end)
        if c and c:IsValid() then
            local nb = 0; pcall(function() nb = c:GetNumBones() end)
            if nb > 0 then cleader = c break end
        end
    end
    if not cleader then
        local best = -1
        for _, c in pairs(list) do
            if c and c:IsValid() then
                local follower = false
                pcall(function()
                    local lp = c.LeaderPoseComponent
                    follower = lp ~= nil and lp:IsValid()
                end)
                local nb = -1; pcall(function() nb = c:GetNumBones() end)
                if not follower and nb > best then best, cleader = nb, c end
            end
        end
    end

    -- Retry copies whose player-side assets were still streaming.
    local stillPending = {}
    for _, p in ipairs(mirror.pending) do
        if p.src:IsValid() and p.dst:IsValid() then
            if copyVisuals(p.src, p.dst) then
                if cleader then
                    local compat = sameSkeleton(p.dst, cleader)
                    if compat ~= false then
                        pcall(function() p.dst:SetLeaderPoseComponent(cleader) end)
                    end
                    pcall(function() p.dst:K2_AttachToComponent(cleader, FName("None"), 0, 0, 0, false) end)
                end
                local nn = compName(p.dst)
                if nn then mirror.keep[nn] = true end
                logMsg("Spawner: coen mirror retry OK — comp '%s'", tostring(nn))
            else
                stillPending[#stillPending + 1] = p
            end
        end
    end
    mirror.pending = stillPending

    -- Slot sync: write the player's garment asset+materials+visibility onto
    -- the clone's OWN garment comp per EAppearanceSlot — the native pipeline
    -- keeps those attached and bone-synced. Player's empty slots get hidden;
    -- late-spawned comps retry on the next pulse.
    if mirror.nativeOK then
        local cac; pcall(function() cac = clone.AppearanceComponent end)
        local pawn = State.playerPawn
        local pac
        if pawn and pawn:IsValid() then
            pcall(function() pac = pawn.AppearanceComponent end)
        end
        if cac and cac:IsValid() and pac and pac:IsValid() then
            for slot = 0, 6 do
                local pgc, cgc
                pcall(function() pgc = pac:GetGarmentMeshComponent(slot) end)
                pcall(function() cgc = cac:GetGarmentMeshComponent(slot) end)
                if cgc and cgc:IsValid() then
                    local n = compName(cgc)
                    if pgc and pgc:IsValid() and compHasAsset(pgc) then
                        local ok2, did = pcall(copyVisuals, pgc, cgc)
                        if ok2 and did then
                            if n then mirror.keep[n] = true end
                            pcall(function() cgc:SetVisibility(true, true) end)
                            pcall(function() cgc:SetHiddenInGame(false, true) end)
                            logMsg("Spawner: coen garment slot=%d synced '%s' <= '%s' (asset=%s)",
                                   slot, tostring(n), tostring(compName(pgc)), tostring(assetName(pgc)))
                        end
                    elseif compHasAsset(cgc) then
                        -- Player wears nothing in this slot — hide the clone's
                        -- own garment so it can't render a default outfit.
                        pcall(function() cgc:SetVisibility(false, true) end)
                        pcall(function() cgc:SetHiddenInGame(true, true) end)
                        if n then mirror.keep[n] = nil end
                        logMsg("Spawner: coen garment slot=%d hidden (player slot empty) '%s'", slot, tostring(n))
                    end
                end
            end
            -- Bone-transform refresh so freshly synced garments pose now.
            pcall(function() cac:LeaderMeshRefreshBoneTransforms() end)
        end
    end

    -- Hide any skinned comp that isn't an approved mirror — this is what
    -- catches the clone's own asynchronously-spawned garment/body comps.
    local hidden = 0
    for _, c in pairs(list) do
        if c and c:IsValid() then
            local n = compName(c)
            if not (n and mirror.keep[n]) and compHasAsset(c) then
                local vis = false
                pcall(function() vis = c:IsVisible() end)
                if vis then
                    pcall(function() c:SetVisibility(false, true) end)
                    pcall(function() c:SetHiddenInGame(true, true) end)
                    hidden = hidden + 1
                    logMsg("Spawner: coen sweep hid '%s' (asset=%s)",
                           tostring(n), tostring(assetName(c)))
                end
            end
            pcall(function() c.VisibilityBasedAnimTickOption = 0 end)
        end
    end
    if hidden > 0 then
        logMsg("Spawner: coen mirror sweep — hid %d late-spawned clone comps", hidden)
    end
end

-- Hardcoded NPC selector. Coen player-class clone DISABLED: its garment
-- pipeline only spawns comps for inventory the clone owns, so the outfit
-- can't be replicated from Lua. Use Target=Player + PM move instead; the
-- mirror code stays for possible re-enable.
M.NPC_CLASSES = {
    -- { label = "Coen (clone)", family = "coen", canUseWeapon = true },
    { label = "Anca",         family = "female", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_Anca_A_default.APP_Anca_A_default" },
    { label = "Lacra",        family = "female", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_HFA_Lacra_A_default.APP_HFA_Lacra_A_default" },
    { label = "Brencis",      family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_Brencis_A.APP_Brencis_A" },
    { label = "Marat",        family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_HMA_Marat_A_default.APP_HMA_Marat_A_default" },
    { label = "Ambrus",       family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_Ambrus_A.APP_Ambrus_A" },
    { label = "Vera",         family = "female", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Secondary_NPC/APP_HFA_Witch_A.APP_HFA_Witch_A" },
    { label = "Bandit",       family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Commoner_NPC/NEW/Bandits/APP_HMA_Bandit_A.APP_HMA_Bandit_A" },
    { label = "Villager",     family = "male", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Commoner_NPC/NEW/Villagers/APP_HMA_Poor_Q102_withwound.APP_HMA_Poor_Q102_withwound" },
    -- Story characters (1.5.0) — appearance paths verified against
    -- UE4SS_ObjectDump. Uriash run their own skeleton (SKEL_UMA), so human
    -- poses cannot play on them — Ocha gets the "uriash" family (Off only).
    { label = "Bakhir",       family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_Bakhir_A.APP_Bakhir_A" },
    { label = "Xanthe",       family = "female", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_Xanthe_A.APP_Xanthe_A" },
    { label = "Leonica",      family = "female", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_HFA_Leonica_A.APP_HFA_Leonica_A" },
    { label = "Esme",         family = "female", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Secondary_NPC/APP_HFA_Esme_A.APP_HFA_Esme_A" },
    { label = "Vladimir",     family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Secondary_NPC/APP_HMA_Vladimir_A.APP_HMA_Vladimir_A" },
    { label = "Vicho",        family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Secondary_NPC/APP_HMA_Vicho_default.APP_HMA_Vicho_default" },
    { label = "Mihai",        family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Secondary_NPC/APP_HMA_Mihai_Day.APP_HMA_Mihai_Day" },
    { label = "Neberu",       family = "male", canUseWeapon = true,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Main_NPC/APP_HMA_Neberu_B_with_cape.APP_HMA_Neberu_B_with_cape" },
    { label = "Lunka",        family = "child", canUseWeapon = false,
      classPath = "/Game/_Dawnwalker/NPC/BasicNPC/BP_NonPlayerCharacter.BP_NonPlayerCharacter_C",
      appearancePath = "/Game/_Dawnwalker/Characters/Appearance/Secondary_NPC/APP_HKA_Lunka_A_Default.APP_HKA_Lunka_A_Default" },
    -- Ocha removed from roster: Uriash run SKEL_UMA, not DW_Human_Skeleton —
    -- human poses can't play, generic BP leaves her T-posed. Re-add once
    -- Uriash AnimSequence paths are dumped (AnimDumper).
}
M.selectedNpcClassIndex = 1

function M.getSelectedNpcClassLabel()
    local cfg = M.NPC_CLASSES[M.selectedNpcClassIndex]
    return cfg and cfg.label or "?"
end

function M.adjustNpcClass(delta)
    if core.cutsceneBlocked("spawn class selection") then return end
    M.selectedNpcClassIndex = M.selectedNpcClassIndex + delta
    if M.selectedNpcClassIndex < 1 then M.selectedNpcClassIndex = #M.NPC_CLASSES end
    if M.selectedNpcClassIndex > #M.NPC_CLASSES then M.selectedNpcClassIndex = 1 end
end

function M.spawnClone()
    if core.cutsceneBlocked("clone spawning") then return end
    local maxClones = Config.max_clones or 5
    if maxClones > 0 and #M.spawnedClones >= maxClones then
        logMsg("Spawner: Max clones limit reached (%d)", maxClones)
        return nil
    end

    local pawn = State.playerPawn
    if not pawn or not pawn:IsValid() then return end

    local cfg = M.NPC_CLASSES[M.selectedNpcClassIndex]
    if not cfg then return end

    local cls
    if cfg.classPath then
        cls = core.findStatic(cfg.classPath)
        if not cls then
            logMsg("Spawner: NPC class not found: %s", cfg.classPath)
            return nil
        end
    else
        cls = pawn:GetClass()
        if not cls then return end
    end

    local cam = Subsystem.photoCamera()
    if not cam or not cam:IsValid() then return end

    local gs = core.findStatic("/Script/Engine.Default__GameplayStatics")
    local mathLib = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
    if not (gs and mathLib) then
        logMsg("Spawner: GameplayStatics/KismetMathLibrary not found")
        return nil
    end

    local camLoc = cam:K2_GetActorLocation()
    local camRot = cam:K2_GetActorRotation()
    local forward = mathLib:GetForwardVector(camRot)
    local right = mathLib:GetRightVector(camRot)

    local spawnLoc = {
        X = camLoc.X + forward.X * State.cloneDist + right.X * State.cloneSide,
        Y = camLoc.Y + forward.Y * State.cloneDist + right.Y * State.cloneSide,
        Z = pawn:K2_GetActorLocation().Z + State.cloneHeight
    }
    local spawnRot = { Pitch = 0, Yaw = camRot.Yaw + State.cloneYaw, Roll = 0 }
    local t = mathLib:MakeTransform(spawnLoc, spawnRot, {X=1, Y=1, Z=1})

    -- ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn = 3
    local clone = nil
    local ok, err = pcall(function()
        local ok6 = pcall(function()
            clone = gs:BeginDeferredActorSpawnFromClass(pawn, cls, t, 3, nil, 1)
        end)
        if not ok6 then
            clone = gs:BeginDeferredActorSpawnFromClass(pawn, cls, t, 3, nil)
        end
        if clone and clone:IsValid() then
            -- Prevent the freshly spawned pawn from being possessed by an AI controller.
            pcall(function() clone.AutoPossessAI = 0 end)
            local okF = pcall(function() clone = gs:FinishSpawningActor(clone, t, 1) end)
            if not okF then pcall(function() clone = gs:FinishSpawningActor(clone, t) end) end
        end
    end)
    if not ok then logMsg("Spawner Error: " .. tostring(err)) end

    if not clone or not clone:IsValid() then
        logMsg("Spawner: Failed to spawn %s", cfg.label)
        return nil
    end

    -- Frozen world (pause_on_enter / F2) stalls the appearance assembly and
    -- anim evaluation on paused ticks -> headless clones, half-applied poses.
    core.setActorTickableWhenPaused(clone, true)

    -- Generic NPCs: keep hidden until appearance is applied (avoids floating hair).
    if cfg.classPath then
        pcall(function() clone:SetActorHiddenInGame(true) end)
    end

    pcall(function()
        local ctrl = clone:GetController()
        if ctrl and ctrl:IsValid() then ctrl:K2_DestroyActor() end
        local moveComp = clone.CharacterMovement
        if moveComp and moveComp:IsValid() then
            moveComp.GravityScale = 0.0
            moveComp:SetMovementMode(0, 0)
            moveComp.Velocity = {X=0, Y=0, Z=0}
        end
        clone:SetActorEnableCollision(false)
    end)

    if cfg.classPath and cfg.appearancePath then
        local appAsset = M.loadAsset(cfg.appearancePath)
        local appearanceOk = false
        if appAsset and appAsset:IsValid() then
            pcall(function()
                local ac = clone.AppearanceComponent
                if ac and ac:IsValid() then
                    ac:SetIgnoreInventoryEquipEvents(true)
                    ac:ApplyAppearance(appAsset)
                    appearanceOk = true
                end
            end)
        end
        if not appearanceOk then
            logMsg("Spawner: appearance failed for %s, destroying incomplete clone", cfg.label)
            pcall(function() clone:K2_DestroyActor() end)
            return nil
        end
        pcall(function() clone:SetActorHiddenInGame(false) end)
    end

    -- Coen clone (player class, no static appearancePath): copy the player's
    -- live appearance — body preset + current outfit — so the clone wears the
    -- same armor instead of the naked default body (TIK-008).
    if not cfg.classPath then
        pcall(function() clone:SetActorHiddenInGame(true) end)
        local appearanceCopied = false
        pcall(function()
            local pac = pawn.AppearanceComponent
            local cac = clone.AppearanceComponent
            if not (pac and pac:IsValid() and cac and cac:IsValid()) then return end
            cac:SetIgnoreInventoryEquipEvents(true)
            local body
            pcall(function() body = pac.CurrentBody end)
            if body and body:IsValid() then
                pcall(function() cac:ApplyBody(body) end)
            end
            local app
            pcall(function() app = pac:GetCurrentAppearance() end)
            if not (app and app:IsValid()) then
                -- Inventory-driven look may leave CurrentAppearance nil; the
                -- player class carries a DefaultAppearance asset as fallback.
                pcall(function() app = pawn.DefaultAppearance end)
            end
            if app and app:IsValid() then
                cac:ApplyAppearance(app)
                appearanceCopied = true
            end

            -- The outfit lives outside the appearance asset: garment meshes
            -- come from EquipmentSlots -> ItemAppearanceMap ->
            -- SpawnedGarmentMeshComponents. Mirror equipped items into the
            -- clone's EquipmentSlots and re-run the native refresh.
            local outfitDone = false
            local pinv, cinv
            pcall(function() pinv = pawn.InventoryComponent end)
            if not (pinv and pinv:IsValid()) then pinv = findActorComponent(pawn, "/Script/DogwoodInventory.InventoryComponent") end
            pcall(function() cinv = clone.InventoryComponent end)
            if not (cinv and cinv:IsValid()) then cinv = findActorComponent(clone, "/Script/DogwoodInventory.InventoryComponent") end

            -- Diagnostics: EquipmentSlots/SpawnedGarmentMeshComponents are
            -- TMaps — count via forEachMapEntry (pairs() yields nothing on
            -- the userdata form).
            local nEquip, nGar = 0, 0
            if pinv and pinv:IsValid() then
                pcall(function()
                    forEachMapEntry(pinv.EquipmentSlots, function(_, it)
                        if it and it:IsValid() then nEquip = nEquip + 1 end
                    end)
                end)
            end
            pcall(function()
                forEachMapEntry(pac.SpawnedGarmentMeshComponents, function() nGar = nGar + 1 end)
            end)
            logMsg("Spawner: coen outfit probe — inv p/c=%s/%s equipSlots=%d playerGarments=%d",
                   tostring(pinv ~= nil and pinv:IsValid()), tostring(cinv ~= nil and cinv:IsValid()), nEquip, nGar)

            if pinv and pinv:IsValid() and cinv and cinv:IsValid() and nEquip > 0 then
                pcall(function()
                    forEachMapEntry(pinv.EquipmentSlots, function(slot, item)
                        if item and item:IsValid() then
                            cinv.EquipmentSlots[slot] = item
                        end
                    end)
                end)
                local copied = 0
                pcall(function()
                    forEachMapEntry(cinv.EquipmentSlots, function(_, item)
                        if item and item:IsValid() then copied = copied + 1 end
                    end)
                end)
                if copied > 0 then
                    pcall(function() cac:SetIgnoreInventoryEquipEvents(false) end)
                    pcall(function() cac:OnInventoryContentsChanged() end)
                    pcall(function() cac:SetIgnoreInventoryEquipEvents(true) end)
                    local spawned = 0
                    pcall(function()
                        forEachMapEntry(cac.SpawnedGarmentMeshComponents, function() spawned = spawned + 1 end)
                    end)
                    outfitDone = spawned > 0
                    logMsg("Spawner: coen outfit — %d equipped items mirrored, %d garment comps spawned", copied, spawned)
                end
            end

            -- Fallback: brute-force visual snapshot — same class as the
            -- player, overwrite same-named skinned comps with the player's
            -- assets/materials. Independent of the appearance pipeline.
            if not outfitDone then
                local n = copyPlayerVisuals(clone, pawn, appearanceCopied)
                logMsg("Spawner: coen outfit visual-snapshot — %d comps mirrored", n)
            end
        end)
        if not appearanceCopied then
            logMsg("Spawner: player appearance copy failed for %s — clone stays default", cfg.label)
        end
        pcall(function() clone:SetActorHiddenInGame(false) end)
    end

    fixupAppearanceAttachments(clone, cfg.label)

    -- Second pass: components registered during ApplyAppearance (head/body
    -- part meshes) missed the first flagging above.
    core.setActorTickableWhenPaused(clone, true)

    M.setCloneLocation(clone, spawnLoc)

    local poses = require("lib.poses")
    
    local idx = #M.spawnedClones + 1
    table.insert(M.spawnedClones, clone)
    M.spawnedWeapons[idx] = nil
    M.cloneOrigLocs[idx] = { X = spawnLoc.X, Y = spawnLoc.Y, Z = spawnLoc.Z }
    pcall(function() M.cloneOrigRots[idx] = clone:K2_GetActorRotation() end)
    M.cloneInfos[idx] = {
        label = cfg.label,
        family = cfg.family,
        canUseWeapon = cfg.canUseWeapon,
    }
    
    poses.poseState[idx] = 2

    -- Delayed work must run on the game thread: async-thread callbacks create
    -- UObjects with the Async GC-keep flag — never collected, they leak the
    -- World at save load (TIK-008).
    local delayFn = core.delayGameThread
    if delayFn then
        delayFn(300, function()
            local p = require("lib.poses")
            -- Only apply if the SAME clone still occupies this slot — a
            -- despawn+respawn inside the 300ms window must not pose the
            -- wrong actor.
            local c = M.spawnedClones[idx]
            if c and c:IsValid() and sameObject(c, clone) then
                -- Async-spawned garments/grooms need a second rebind before
                -- the pose; Coen: re-enforce the player mirror too.
                reassertPlayerMirror(clone)
                fixupAppearanceAttachments(clone, cfg.label)
                local prevTarget = p.targetIdx
                p.targetIdx = idx
                p.applyPose()
                p.targetIdx = prevTarget
            end
        end)
        -- Very late async loads (heavy garments/grooms on story NPCs) get one
        -- more rebind pass.
        delayFn(1500, function()
            local c = M.spawnedClones[idx]
            if c and c:IsValid() and sameObject(c, clone) then
                reassertPlayerMirror(clone)
                fixupAppearanceAttachments(clone, cfg.label .. " (late)")
            end
        end)

        -- Deferred garment assembly stalls while the world is frozen — pulse
        -- brief unpauses so the appearance pipeline can tick, then rebind.
        -- Clone stays hidden until pulses finish (no piece-by-piece flicker).
        if State.paused then
            pcall(function() clone:SetActorHiddenInGame(true) end)
            local pc2 = Subsystem.playerController()
            local gs2 = Subsystem.gameplayStatics()
            local pulses = 3
            local function finish(tag)
                local c = M.spawnedClones[idx]
                if c and c:IsValid() and sameObject(c, clone) then
                    core.setActorTickableWhenPaused(clone, true)
                    reassertPlayerMirror(clone)
                    fixupAppearanceAttachments(clone, tag)
                    pcall(function() clone:SetActorHiddenInGame(false) end)
                    dbg("Spawner: %s revealed after pulses", cfg.label)
                end
            end
            for i = 1, pulses do
                delayFn(200 * i, function()
                    local c = M.spawnedClones[idx]
                    if not (c and c:IsValid() and sameObject(c, clone)) then return end
                    -- Last pulse (or world unfrozen meanwhile): final pass,
                    -- then reveal the fully assembled clone.
                    if i == pulses or not (State.photoModeActive and State.paused) then
                        finish(cfg.label .. " (pulse " .. i .. ")")
                        return
                    end
                    if not (pc2 and gs2) then return end
                    pcall(function() gs2:SetGamePaused(pc2, false) end)
                    delayFn(40, function()
                        -- Re-freeze only if PM still owns the pause — never
                        -- re-pause a world the user manually unfroze.
                        if State.photoModeActive and State.paused then
                            pcall(function() gs2:SetGamePaused(pc2, true) end)
                        end
                        local c2 = M.spawnedClones[idx]
                        if c2 and c2:IsValid() and sameObject(c2, clone) then
                            core.setActorTickableWhenPaused(clone, true)
                            reassertPlayerMirror(clone)
                            fixupAppearanceAttachments(clone, cfg.label .. " (pulse " .. i .. ")")
                        end
                    end)
                end)
            end
            -- Safety: never leave a spawned clone hidden.
            delayFn(3000, function()
                local c = M.spawnedClones[idx]
                if c and c:IsValid() and sameObject(c, clone) then
                    pcall(function() clone:SetActorHiddenInGame(false) end)
                end
            end)
        end
    else
        local prevTarget = poses.targetIdx
        poses.targetIdx = idx
        poses.applyPose()
        poses.targetIdx = prevTarget
    end

    logMsg("Spawner: Spawned %s (#%d, family=%s)", cfg.label, idx, cfg.family)
    return clone
end

---------------------------------------------------------------------------- Generic asset loader
-- StaticFindObject only sees loaded assets; AssetRegistryHelpers pulls in any
-- asset on demand (appearance data, AnimSequences, prop StaticMeshes).
function M.loadAsset(fullPath)
    if not fullPath then return nil end
    local found = core.findStatic(fullPath)
    if found and found:IsValid() then return found end

    local helpers = core.findStatic("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not helpers then return nil end

    local pkg, name = fullPath:match("^(.+)%.([^%.]+)$")
    if not pkg or not name then return nil end

    local loaded
    local ok = pcall(function()
        local assetData = {
            PackageName = FName(pkg),
            AssetName   = FName(name),
        }
        loaded = helpers:GetAsset(assetData)
    end)
    loaded = (type(Unwrap) == "function") and Unwrap(loaded) or loaded
    if ok and loaded and loaded:IsValid() then return loaded end
    return nil
end
M.loadAppearanceAsset = M.loadAsset

---------------------------------------------------------------------------- Clone transform controls

function M.setCloneLocation(clone, desiredLoc)
    if not (clone and clone:IsValid()) then return end

    -- Per-pose placement metadata (z_offset / ground-snap flag).
    local idx = nil
    for i, c in ipairs(M.spawnedClones) do
        if sameObject(c, clone) then idx = i break end
    end
    local meta = idx and M.poseMetadata[idx]

    -- Ground snap via LineTraceSingle — the ret-out signature proven by
    -- Auto-Focus (optics.lua). CapsuleTraceSingleByProfile is NOT used: it
    -- CTDs on TArray/FHitResult out params in this UE4SS build.
    local doGroundSnap = not meta or (meta.ground ~= false)
    if doGroundSnap then
        local ks = Subsystem.kismetSystem()
        local halfH = 90.0
        pcall(function()
            local cap = clone.CapsuleComponent
            if cap and cap:IsValid() then halfH = cap:GetUnscaledCapsuleHalfHeight() end
        end)
        if ks then
            local okT, hitZ = pcall(function()
                local start  = { X = desiredLoc.X, Y = desiredLoc.Y, Z = desiredLoc.Z + 400.0 }
                local finish = { X = desiredLoc.X, Y = desiredLoc.Y, Z = desiredLoc.Z - 500.0 }
                local hit, outHit = ks:LineTraceSingle(
                    clone, start, finish, 0, false, {}, 0,
                    true, -- bIgnoreSelf ignores the context actor (the clone)
                    {R=0,G=0,B=0,A=0}, {R=0,G=0,B=0,A=0}, 0.0)
                if hit and outHit and outHit.ImpactPoint then
                    return outHit.ImpactPoint.Z
                end
                return nil
            end)
            if okT and hitZ then
                desiredLoc.Z = hitZ + halfH
            end
        end
    end
    -- z_offset applies on top of the snapped/base Z. Record it so moveClone
    -- can strip it from the actor's current location — otherwise the offset
    -- would be re-added on every move and the clone sinks cumulatively.
    desiredLoc.Z = desiredLoc.Z + (meta and meta.z_offset or 0.0)
    if meta then meta.appliedOffset = meta.z_offset or 0.0 end

    local hitRes = {}
    pcall(function() clone:K2_SetActorLocationAndRotation(desiredLoc, clone:K2_GetActorRotation(), false, hitRes, true) end)
end

-- One-time prep for moving the real player: switch capsule collision to QueryOnly
-- (allows spatial queries/overlaps so AInteriorVolume and lighting remain active,
-- while disabling rigid physical collision simulation) + gravity frozen.
-- Restored on PM exit — original collision profile and settings are fully restored.
function M.preparePlayerMove(pawn)
    if core.cutsceneBlocked("player movement") then return end
    if State.playerMovePrepared then return end
    State.playerMovePrepared = true

    -- TIK-014: Keep pawn:SetActorEnableCollision(true) active so OnBrushEndOverlap
    -- is NOT fired on AInteriorVolume (which causes interior lighting/fog blowout).
    -- Instead, set capsule to QueryOnly and relax blocking channels to Overlap.
    local capsule = pawn.CapsuleComponent or pawn.RootComponent
    if capsule and capsule:IsValid() then
        pcall(function()
            State.origCapsuleCollisionEnabled = capsule:GetCollisionEnabled()
            State.origCapsuleProfileName = capsule:GetCollisionProfileName()
            capsule:SetCollisionEnabled(1) -- ECollisionEnabled::QueryOnly
            capsule:SetCollisionResponseToChannel(0, 1) -- ECC_WorldStatic -> ECR_Overlap
            capsule:SetCollisionResponseToChannel(1, 1) -- ECC_WorldDynamic -> ECR_Overlap
            capsule:SetCollisionResponseToChannel(2, 1) -- ECC_Pawn -> ECR_Overlap
        end)
    end

    pcall(function()
        local mc = pawn.CharacterMovement
        if mc and mc:IsValid() then
            State.origPlayerGravityScale = mc.GravityScale
            mc.GravityScale = 0.0
            -- Walking mode snaps the capsule to the floor every tick (the
            -- world is NOT paused in PM), which resets Height moves. Flying
            -- skips floor-adherence entirely.
            State.origPlayerMovementMode = mc.MovementMode
            mc:SetMovementMode(5, 0) -- MOVE_Flying
        end
    end)
    logMsg("Spawner: player collision switched to QueryOnly (overlaps preserved) + gravity suspended")
end

function M.moveClone(clone, axis, delta)
    if core.cutsceneBlocked("clone movement") then return end
    if not (clone and clone:IsValid()) then return end
    local isPlayer = sameObject(clone, State.playerPawn)
    local step
    if axis == "fwd"        then step = Config.clone_step_fwd    or 5.0
    elseif axis == "side"   then step = Config.clone_step_side   or 5.0
    elseif axis == "height" then step = Config.clone_step_height or 5.0
    elseif axis == "yaw"    then step = Config.clone_step_yaw    or 15.0
    else return end

    local cam = Subsystem.photoCamera()
    local mathLib = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
    if not (cam and cam:IsValid() and mathLib) then return end

    local loc = clone:K2_GetActorLocation()
    local rot = clone:K2_GetActorRotation()
    -- The actor's stored Z already carries the pose z_offset applied by
    -- setCloneLocation; strip it so the offset isn't re-added cumulatively
    -- (every move press would otherwise sink the clone by the offset).
    local idx
    for i, c in ipairs(M.spawnedClones) do
        if sameObject(c, clone) then idx = i break end
    end
    local meta = idx and M.poseMetadata[idx]
    if meta and meta.appliedOffset then loc.Z = loc.Z - meta.appliedOffset end
    if axis == "fwd" then
        -- Horizontal only: pitching the camera must not sink/fly the clone.
        local f = mathLib:GetForwardVector(cam:K2_GetActorRotation())
        loc.X = loc.X + f.X * step * delta
        loc.Y = loc.Y + f.Y * step * delta
    elseif axis == "side" then
        local r = mathLib:GetRightVector(cam:K2_GetActorRotation())
        loc.X = loc.X + r.X * step * delta
        loc.Y = loc.Y + r.Y * step * delta
    elseif axis == "height" then
        loc.Z = loc.Z + step * delta
    elseif axis == "yaw" then
        rot.Yaw = rot.Yaw + step * delta
        pcall(function() clone:K2_SetActorRotation(rot, true) end)
        return
    end

    -- Wall clamp for horizontal moves: sweep a line to the target and pull
    -- back short of the impact. LineTraceSingle ret-out variant (capsule
    -- traces CTD on out params); bIgnoreSelf skips the clone itself.
    if axis == "fwd" or axis == "side" then
        local ks = Subsystem.kismetSystem()
        if ks then
            local from = clone:K2_GetActorLocation()
            pcall(function()
                local traceEnd = { X = loc.X, Y = loc.Y, Z = from.Z }
                local hit, outHit = ks:LineTraceSingle(
                    clone, from, traceEnd, 0, false, {}, 0,
                    true, {R=0,G=0,B=0,A=0}, {R=0,G=0,B=0,A=0}, 0.0)
                if hit and outHit and outHit.Distance then
                    local wantX, wantY = loc.X - from.X, loc.Y - from.Y
                    local wantLen = math.sqrt(wantX * wantX + wantY * wantY)
                    local allowed = outHit.Distance - 30.0 -- capsule-radius skin
                    if wantLen > 0 and allowed < wantLen then
                        local s = math.max(0.0, allowed) / wantLen
                        loc.X = from.X + wantX * s
                        loc.Y = from.Y + wantY * s
                    end
                end
            end)
        end
    end
    if isPlayer then
        -- Player path: no ground-snap/z_offset (they would fight Height
        -- moves); teleport-set so physics doesn't sweep the displacement.
        M.preparePlayerMove(clone)
        local hitRes = {}
        pcall(function() clone:K2_SetActorLocationAndRotation(loc, clone:K2_GetActorRotation(), false, hitRes, true) end)
        return
    end
    M.setCloneLocation(clone, loc)
end

function M.faceCamera(clone)
    if core.cutsceneBlocked("clone rotation") then return end
    if not (clone and clone:IsValid()) then return end    local cam = Subsystem.photoCamera()
    if not cam or not cam:IsValid() then return end
    local rot = clone:K2_GetActorRotation()
    -- +180 like spawn's clone_yaw: "Face Cam" means facing TOWARD the camera,
    -- not looking the same direction the camera does.
    rot.Yaw = cam:K2_GetActorRotation().Yaw + 180.0
    pcall(function() clone:K2_SetActorRotation(rot, true) end)
end

function M.setPoseMetadata(idx, zOffset, ground)
    -- Merge, don't replace: appliedOffset must survive — the actor's current Z
    -- still carries the previous pose's offset until the next setCloneLocation.
    local m = M.poseMetadata[idx] or {}
    m.z_offset = zOffset or 0.0
    m.ground = ground ~= false
    M.poseMetadata[idx] = m
end

----------------------------------------------------------------------------
-- Weapon diagnostics. tostring(FName) prints the address — :ToString()
-- reads the actual name.
local function fnameStr(fn)
    if fn == nil then return "nil" end
    local ok, s = pcall(function() return fn:ToString() end)
    if ok and s then return s end
    return tostring(fn)
end


-- "Socket" names in this build may actually be BONE names (skeleton has no
-- named sockets — GetAllSocketNames returns 0). Accept either.
local function nameExistsOnMesh(mesh, name)
    -- DoesSocketExist/GetBoneIndex dereference comp.SkeletalMesh — leader-pose
    -- follower comps carry SkeletalMesh=null and dereferencing it AVs (~0x70).
    local okSk, skMesh = pcall(function() return mesh.SkeletalMesh end)
    if not (okSk and skMesh and skMesh:IsValid()) then return false, nil end
    -- Native APIs take FName — a Lua string may not auto-convert for these.
    local fn = name
    if type(name) == "string" then
        local okN, f = pcall(function() return FName(name) end)
        if okN and f then fn = f end
    end
    local okS, isSocket = pcall(function() return mesh:DoesSocketExist(fn) end)
    if okS and isSocket then return true, "socket" end
    local okB, idx = pcall(function() return mesh:GetBoneIndex(fn) end)
    if okB and type(idx) == "number" and idx >= 0 then return true, "bone#" .. idx end
    return false, nil
end

-- Dumps every socket getter result and the skeleton's socket/bone list so a
-- single in-game run tells us exactly which resolution path works.
local function dumpSockets(mesh, tag)
    local ok, names = pcall(function() return mesh:GetAllSocketNames() end)
    if not (ok and type(names) == "table") then
        dbg("Spawner: [%s] GetAllSocketNames failed", tag)
        return
    end
    local total, hits = 0, {}
    for _, n in pairs(names) do
        total = total + 1
        local s = tostring(n)
        local l = s:lower()
        if l:find("weap") or l:find("sword") or l:find("hand") or
           l:find("item") or l:find("attach") or l:find("sheath") then
            table.insert(hits, s)
        end
    end
    table.sort(hits)
    dbg("Spawner: [%s] sockets total=%d matched=[%s]", tag, total, table.concat(hits, ", "))

    -- Weapon "sockets" here are bones — dump matching bone names too.
    local okN, numBones = pcall(function() return mesh:GetNumBones() end)
    if okN and type(numBones) == "number" then
        local bhits = {}
        for i = 0, numBones - 1 do
            local okB, bn = pcall(function() return mesh:GetBoneName(i) end)
            if okB and bn then
                local s = fnameStr(bn)
                local l = s:lower()
                if l:find("weap") or l:find("sword") or l:find("hand") or
                   l:find("item") or l:find("attach") or l:find("sheath") or l:find("prop") then
                    table.insert(bhits, s)
                end
            end
        end
        table.sort(bhits)
        dbg("Spawner: [%s] bones total=%d matched=[%s]", tag, numBones, table.concat(bhits, ", "))
    end
end

local function logSlotSockets(cc, tag)
    for _, fn in ipairs({ "GetWeaponSocketNameForSlot", "GetSocketNameForSlot" }) do
        for slot = 0, 2 do
            local ok, s = pcall(function() return cc[fn](cc, slot) end)
            dbg("Spawner: [%s] %s(%d) -> %s", tag, fn, slot,
                ok and fnameStr(s) or ("ERR:" .. tostring(s)))
        end
    end
end

-- Modular character: LeaderMesh + follower parts share one skeleton while
-- ACharacter::Mesh may be an empty driver — find which comp actually owns the
-- socket on THIS actor. A socket resolving to the component origin is a
-- bind-pose trap — prefer a visible, boned comp whose socket sits on the body.
local function findSocketComponent(target, sockName, quiet)
    if sockName == nil then return nil end
    local comps, seen = {}, {}
    local function add(c, label)
        if c and c:IsValid() and not seen[c] then
            seen[c] = true
            comps[#comps+1] = { label = label, comp = c }
        end
    end
    for _, f in ipairs({ "LeaderMesh", "Mesh", "HandMesh", "TorsoMesh", "HeadMesh",
                         "LegMesh", "FeetMesh", "HairMesh", "EyebrowMeshComponent",
                         "BeardMeshComponent" }) do
        local c; pcall(function() c = target[f] end)
        add(c, f)
    end
    local skCls = core.findStatic("/Script/Engine.SkeletalMeshComponent")
    if skCls then
        local okL, list = pcall(function() return target:K2_GetComponentsByClass(skCls) end)
        if okL and type(list) == "table" then
            for _, c in pairs(list) do
                local n = "?"
                pcall(function() n = c:GetName() end)
                add(c, n)
            end
        end
    end

    local actorLoc
    pcall(function() actorLoc = target:K2_GetActorLocation() end)
    local sockFName = sockName
    if type(sockName) == "string" then
        local okN, f = pcall(function() return FName(sockName) end)
        if okN and f then sockFName = f end
    end
    local winner, fallback
    for _, e in ipairs(comps) do
        local comp = e.comp
        local has, kind = nameExistsOnMesh(comp, sockName)
        local nb, vis = -1, false
        pcall(function() nb = comp:GetNumBones() end)
        pcall(function() vis = comp:IsVisible() end)
        local dz = "n/a"
        if has then
            pcall(function()
                local l = comp:GetSocketLocation(sockFName)
                if l and actorLoc then dz = string.format("%.0f", (l.Z or 0) - actorLoc.Z) end
            end)
        end
        if not quiet then
            logMsg("Spawner:   comp %s: bones=%s vis=%s ownsSocket=%s dZ=%scm",
                e.label, tostring(nb), tostring(vis), tostring(kind), dz)
        end
        if has then
            if vis and nb ~= 0 and not winner then winner = comp
            elseif not fallback then fallback = comp end
        end
    end
    local picked = winner or fallback
    if picked then
        local pn = "?"
        pcall(function() pn = picked:GetName() end)
        logMsg("Spawner: socket '%s' attach component = %s", fnameStr(sockName), pn)
    end
    return picked
end

-- resolveHandSocket validates CombatComponent slot names against the mesh and
-- falls back to a scored bone scan — NPC skeletons use BONE names (no named
-- sockets), so props must resolve the same way weapons do.
local resolveHandSocket

-- Resolve a hand attach point (component + socket/bone) on any target.
-- hand="l" resolves the left hand; an explicit prop socket overrides.
local function resolveHandAttach(target, sockName, hand)
    -- Attach component: first boned skeletal comp (same pick equipWeapon makes).
    local comp
    for _, f in ipairs({ "LeaderMesh", "Mesh", "HandMesh", "TorsoMesh", "HeadMesh" }) do
        local c; pcall(function() c = target[f] end)
        if c and c:IsValid() then
            local nb = 0; pcall(function() nb = c:GetNumBones() end)
            if nb > 0 then comp = c break end
        end
    end

    local name = sockName
    if name then
        -- Explicit prop socket: attach to whichever component owns it.
        local owner = findSocketComponent(target, name, true)
        if owner then comp = owner end
    else
        -- The game's authored hand-prop sockets: live NPCs attach prop
        -- components to prop_r/prop_l with an IDENTITY relative transform —
        -- the grip offset/rotation is baked into the socket itself.
        local propSock = (hand == "l") and "prop_l" or "prop_r"
        if comp then
            local exists = nameExistsOnMesh(comp, propSock)
            if exists then
                name = propSock
                logMsg("Spawner: prop socket '%s' onMesh=socket", propSock)
            end
        end
        if not name then
            -- Prefer the TARGET's own CombatComponent (clone slot map may
            -- differ), then the player's. resolveHandSocket returns a name
            -- that exists on comp as socket OR bone (bone-scan fallback).
            local cc
            pcall(function() cc = target.CombatComponent end)
            if not (cc and cc:IsValid()) then
                local pawn = State.playerPawn
                pcall(function() cc = pawn and pawn.CombatComponent end)
            end
            if comp then name = resolveHandSocket(cc, comp, hand) end
            name = name or (hand == "l" and "socket_weapon_l" or "socket_weapon_r")
        end
    end
    if not comp then comp = findSocketComponent(target, name, true) end
    return comp, name
end

---------------------------------------------------------------------------- Hand props (book, spoon, bottle, shovel...)
-- StaticMeshActor attached to the hand socket — same visual mechanism as the
-- weapon path, driven by pose metadata (entry.prop).

function M.spawnProp(target, propDef, hand)
    if not (target and target:IsValid() and propDef) then return nil end
    hand = hand or "r"
    local meshPath = propDef.mesh or propDef[1]
    if not meshPath then return nil end
    local mesh = M.loadAsset(meshPath)
    if not (mesh and mesh:IsValid()) then
        logMsg("Spawner: prop mesh not found: %s", tostring(meshPath))
        return nil
    end

    local comp, sockName = resolveHandAttach(target, propDef.socket, hand)
    if not comp then
        logMsg("Spawner: no attach component for prop on target")
        return nil
    end
    logMsg("Spawner: prop resolved sock=%s", tostring(sockName and fnameStr(sockName) or "nil"))
    -- Native attach APIs expect an FName; configured/default socket names are
    -- Lua strings. Getters already return FName userdata — pass those through.
    if type(sockName) == "string" then
        local okN, fn = pcall(function() return FName(sockName) end)
        if okN and fn then sockName = fn end
    end

    -- Game-accurate path: NPCs attach a plain UStaticMeshComponent to
    -- prop_r/prop_l with identity transform — owned by the target, dies with it.
    local smcCls = core.findStatic("/Script/Engine.StaticMeshComponent")
    if smcCls then
        local smc
        -- RelativeTransform is a required FTransform& — nil does not marshal.
        local ml = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
        local t = ml and ml:MakeTransform({X=0,Y=0,Z=0}, {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1})
        local okAdd = pcall(function()
            smc = target:AddComponentByClass(smcCls, false, t, false)
        end)
        if not okAdd then
            okAdd = pcall(function()
                smc = target:AddComponentByClass(smcCls, false, nil, false)
            end)
        end
        if okAdd and smc and smc:IsValid() then
            pcall(function() smc:SetMobility(2) end)
            pcall(function()
                smc:K2_AttachToComponent(comp, sockName, 2, 2, 0, false)
            end)
            local okM = pcall(function() return smc:SetStaticMesh(mesh) end)
            if not okM then pcall(function() smc.StaticMesh = mesh end) end
            if propDef.loc   then pcall(function() smc.RelativeLocation = propDef.loc end) end
            if propDef.rot   then pcall(function() smc.RelativeRotation = propDef.rot end) end
            if propDef.scale then pcall(function() smc.RelativeScale3D  = propDef.scale end) end
            pcall(function() smc:SetVisibility(true, true) end)
            local sn, vis = "?", "?"
            pcall(function() sn = fnameStr(smc:GetAttachSocketName()) end)
            pcall(function() vis = tostring(smc:IsVisible()) end)
            logMsg("Spawner: prop comp '%s' on '%s' sock='%s' vis=%s hand=%s",
                tostring(propDef.name or meshPath), fnameStr(sockName), sn, vis, hand)
            return smc
        else
            logMsg("Spawner: AddComponentByClass failed ok=%s", tostring(okAdd))
        end
    end

    -- Fallback: plain AStaticMeshActor. (The old secondary carrier spawned a
    -- real AWeaponBase — removed: pending-kill weapon actors leaked the old
    -- world at save load, TIK-008.)
    local gs = core.findStatic("/Script/Engine.Default__GameplayStatics")
    local mathLib = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
    local cls = core.findStatic("/Script/Engine.StaticMeshActor")
    if not (gs and mathLib and cls) then return nil end

    local t = mathLib:MakeTransform(target:K2_GetActorLocation(), {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1})
    local sma
    pcall(function()
        local ok6 = pcall(function()
            sma = gs:BeginDeferredActorSpawnFromClass(target, cls, t, 3, nil, 1)
        end)
        if not ok6 then
            sma = gs:BeginDeferredActorSpawnFromClass(target, cls, t, 3, nil)
        end
        if sma and sma:IsValid() then
            local okF = pcall(function() sma = gs:FinishSpawningActor(sma, t, 1) end)
            if not okF then pcall(function() sma = gs:FinishSpawningActor(sma, t) end) end
        end
    end)
    if not (sma and sma:IsValid()) then
        logMsg("Spawner: prop actor spawn failed")
        return nil
    end

    local smc
    local okA, errA = pcall(function()
        smc = sma.StaticMeshComponent
        local okS = pcall(function() smc:SetStaticMesh(mesh) end)
        if not okS then smc.StaticMesh = mesh end
        -- AStaticMeshActor's component defaults to Static mobility; UE refuses
        -- to attach a Static child under the Movable skeletal mesh — the
        -- attach silently no-ops and the prop stays unparented/invisible.
        pcall(function() smc:SetMobility(2) end) -- EComponentMobility::Movable
        sma:SetActorEnableCollision(false)
        -- Try every attach entry point in turn — return values in this build
        -- are unreliable, so ground-truth is GetAttachParent() after each
        -- call. K2_AttachToComponent alone silently no-ops here.
        local function attachWorked()
            local ap
            pcall(function() ap = smc:GetAttachParent() end)
            return ap and ap:IsValid() and sameObject(ap, comp)
        end
        local attached = false
        for i, fn in ipairs({
            function() return smc:AttachToComponent(comp, sockName, 2, 2, 0, false) end,
            function() return sma:K2_AttachToComponent(comp, sockName, 2, 2, 0, false) end,
            function() return sma:K2_AttachRootComponentTo(comp, sockName, 2, false) end,
        }) do
            local okCall, ret = pcall(fn)
            if attachWorked() then
                attached = true
                logMsg("Spawner: prop attach ok via method #%d (call ok=%s ret=%s)", i, tostring(okCall), tostring(ret))
                break
            else
                logMsg("Spawner: prop attach method #%d failed (call ok=%s ret=%s)", i, tostring(okCall), tostring(ret))
            end
        end
        if not attached then
            error("all attach methods failed")
        end
        if propDef.loc   then smc.RelativeLocation = propDef.loc end
        if propDef.rot   then smc.RelativeRotation = propDef.rot end
        if propDef.scale then smc.RelativeScale3D  = propDef.scale end
    end)
    if not okA then
        logMsg("Spawner: prop attach failed (%s)", tostring(errA))
        pcall(function() sma:K2_DestroyActor() end)
        return nil
    end
    -- Verify the attach actually took: a silent no-op leaves the prop
    -- unparented at the spawn transform (invisible inside the body/ground).
    pcall(function()
        local ap = smc and smc:GetAttachParent()
        local apn = "none"
        if ap and ap:IsValid() then pcall(function() apn = ap:GetName() end) end
        local pl = sma:K2_GetActorLocation()
        local sl; pcall(function() sl = comp:GetSocketLocation(sockName) end)
        local hasMesh; pcall(function() hasMesh = smc.StaticMesh ~= nil end)
        logMsg("Spawner: prop verify parent=%s mesh=%s propZ=%s sockZ=%s",
            tostring(apn), tostring(hasMesh),
            pl and string.format("%.0f", pl.Z) or "?",
            sl and string.format("%.0f", sl.Z) or "?")
    end)
    logMsg("Spawner: prop '%s' on '%s' hand=%s", tostring(propDef.name or meshPath), fnameStr(sockName), hand)
    return sma
end

-- Per-pose prop show/hide for one hand; propDef=nil clears. Reuse compares
-- the resolved def TABLE by reference — any field change recreates the
-- entity. Props may be actors (legacy) or components; destroy either kind.
local function destroyPropEntity(e)
    -- Actor carriers (weapon/prop actors): detach first so the attach
    -- reference into the PersistentLevel can't outlive the destroy (TIK-008).
    pcall(function() e:K2_DetachFromActor(1, 1, 1) end)
    local okA = pcall(function() e:K2_DestroyActor() end)
    if okA then return end
    -- DestroyComponent is unbound in this UE4SS build — the owning actor must
    -- destroy it, and must still be ALIVE: pending-kill owners leave
    -- uncollectable garbage that trips the world-leak check (TIK-008).
    local owner, ownerValid
    pcall(function() owner = e:GetOwner() end)
    if owner then pcall(function() ownerValid = owner:IsValid() end) end
    local okK = false
    if ownerValid then
        pcall(function() e:K2_DetachFromComponent(1, 1, 1, false) end)
        okK = pcall(function() owner:K2_DestroyComponent(e) end)
    end
    dbg("Spawner: destroyProp ownerValid=%s ownerK2=%s", tostring(ownerValid), tostring(okK))
    if not okK then
        -- Last resort (all reflected UFUNCTIONs): hide/disable/detach.
        pcall(function() e:SetVisibility(false, true) end)
        pcall(function() e:SetHiddenInGame(true, true) end)
        pcall(function() e:SetCollisionEnabled(0) end)
        pcall(function() e:SetComponentTickEnabled(false) end)
        pcall(function() e:K2_DetachFromComponent(1, 1, 1, false) end)
    end
end

local function applyHandProp(targetIdx, spawned, keys, hand, propDef)
    local target = (targetIdx == 0) and State.playerPawn or M.spawnedClones[targetIdx]
    local existing = spawned[targetIdx]
    if existing then
        local okV, valid = pcall(function() return existing:IsValid() end)
        dbg("Spawner: prop existing check hand=%s idx=%d valid=%s", hand, targetIdx, tostring(okV and valid))
        if okV and valid then
            if propDef and propDef == keys[targetIdx] then
                pcall(function() existing:SetActorHiddenInGame(false) end)
                pcall(function() existing:SetVisibility(true, true) end)
                return existing
            end
            destroyPropEntity(existing)
        else
            -- IsValid can misreport on live components; a truly dangling ptr would
            -- have AV'd on the call above, so attempting destroy is safe here.
            destroyPropEntity(existing)
        end
    end
    spawned[targetIdx] = nil
    keys[targetIdx] = nil
    if not (propDef and target and target:IsValid()) then return nil end
    dbg("Spawner: prop spawn start mesh=%s hand=%s", tostring(propDef.mesh or propDef[1]), hand)
    local p = M.spawnProp(target, propDef, hand)
    if p then
        spawned[targetIdx] = p
        keys[targetIdx] = propDef
    end
    return p
end

-- Apply right-hand (propDef) and left-hand (propDefL) props for a pose.
function M.applyPropState(targetIdx, propDef, propDefL)
    local r = applyHandProp(targetIdx, M.spawnedProps,  M.propKeys,  "r", propDef)
    local l = applyHandProp(targetIdx, M.spawnedPropsL, M.propKeysL, "l", propDefL)
    return r or l
end

function M.clearAllProps()
    for _, spawned in ipairs({ M.spawnedProps, M.spawnedPropsL }) do
        for _, p in pairs(spawned) do
            if p then destroyPropEntity(p) end
        end
    end
    M.spawnedProps = {}
    M.spawnedPropsL = {}
    M.propKeys = {}
    M.propKeysL = {}
end

-- Resolve the in-hand weapon attach name on the clone's skeleton: combat
-- getters validated against sockets AND bones (the game may use bone names),
-- then literal left-hand names, then a scored bone scan. hand="l" = left.
resolveHandSocket = function(cc, mesh, hand)
    local left = (hand == "l")
    if cc and cc:IsValid() then
        for _, fn in ipairs({ "GetWeaponSocketNameForSlot", "GetSocketNameForSlot" }) do
            local slots = left and {0, 2} or {1}
            for _, slot in ipairs(slots) do
                local ok, s = pcall(function() return cc[fn](cc, slot) end)
                if ok and s then
                    local sStr = fnameStr(s)
                    if sStr ~= "" and sStr ~= "None" then
                        local looksLeft = sStr:lower():find("_l") ~= nil
                            or sStr:lower():find("left") ~= nil
                        if not left or looksLeft then
                            local exists, kind = nameExistsOnMesh(mesh, s)
                            logMsg("Spawner: %s(slot=%d)='%s' onMesh=%s", fn, slot, sStr, tostring(kind))
                            if exists then return s end
                        end
                    end
                end
            end
        end
    end
    if left then
        -- CC slot map may not cover the left hand — try the conventional names.
        for _, n in ipairs({ "socket_weapon_l", "weapon_l", "hand_l" }) do
            local exists, kind = nameExistsOnMesh(mesh, n)
            if exists then
                logMsg("Spawner: left-hand name '%s' onMesh=%s", n, tostring(kind))
                return n
            end
        end
    end
    -- Fallback: scored scan over bone names (skeleton has no sockets).
    local okN, numBones = pcall(function() return mesh:GetNumBones() end)
    if okN and type(numBones) == "number" then
        local best, bestBone
        for i = 0, numBones - 1 do
            local okB, bn = pcall(function() return mesh:GetBoneName(i) end)
            if okB and bn then
                local s = fnameStr(bn)
                local l = s:lower()
                local score = 0
                if l:find("weap") then score = score + 4 end
                if l:find("sword") then score = score + 3 end
                if left then
                    if l:find("left") or l:find("_l") then score = score + 2 end
                else
                    if l:find("right") or l:find("_r") then score = score + 2 end
                end
                if l:find("hand") then score = score + 1 end
                if score >= 4 and (not best or score > best) then
                    best, bestBone = score, bn
                end
            end
        end
        if bestBone then
            logMsg("Spawner: bone scan picked '%s' (score %d)", fnameStr(bestBone), best)
            return bestBone
        end
    end
    return nil
end

-- Restore a hijacked native component (SheathedWeaponMesh) to its saved
-- attach/socket/mesh/vis — the "sheathed" state: mandatory cleanup on the
-- player pawn, the sheathed look on clones.
local function restoreWeaponComp(wcomp)
    local orig = M.hijackedComps[wcomp]
    if not orig or not (wcomp and wcomp:IsValid()) then return end
    if orig.parent and orig.parent:IsValid() then
        pcall(function()
            wcomp:K2_AttachToComponent(orig.parent, orig.sock or FName("None"), 0, 0, 0, false)
        end)
    end
    if orig.relLoc then pcall(function() wcomp.RelativeLocation = orig.relLoc end) end
    if orig.relRot then pcall(function() wcomp.RelativeRotation = orig.relRot end) end
    if orig.relScale then pcall(function() wcomp.RelativeScale3D = orig.relScale end) end
    if orig.mesh and orig.mesh:IsValid() then
        local okS = pcall(function() wcomp:SetStaticMesh(orig.mesh) end)
        if not okS then pcall(function() wcomp.StaticMesh = orig.mesh end) end
    end
    if orig.vis ~= nil then pcall(function() wcomp:SetVisibility(orig.vis, true) end) end
    if orig.hidden ~= nil then pcall(function() wcomp:SetHiddenInGame(orig.hidden, true) end) end
end

-- Re-apply the in-hand attach on a previously sheathed (restored) hijacked
-- component — draw/sheathe cycling without re-running equipWeapon.
local function drawWeaponComp(wcomp)
    local d = M.weaponDraw[wcomp]
    if not (d and wcomp and wcomp:IsValid()) then return end
    pcall(function()
        if d.mesh and d.mesh:IsValid() then wcomp:SetStaticMesh(d.mesh) end
        if d.attachComp and d.attachComp:IsValid() then
            wcomp:K2_AttachToComponent(d.attachComp, d.sock, 2, 2, 0, false)
        end
        if d.relLoc then wcomp.RelativeLocation = d.relLoc end
        if d.relRot then wcomp.RelativeRotation = d.relRot end
        if d.relScale then wcomp.RelativeScale3D = d.relScale end
        wcomp:SetVisibility(true, true)
        wcomp:SetHiddenInGame(false, true)
    end)
end

-- Mirror the player's weapon onto a target as a StaticMeshComponent owned by
-- it. No native AWeaponBase is spawned — pending-kill weapon actors leaked
-- the old world at save load (TIK-008); components die with their owner.
function M.equipWeapon(target, allowReal, quiet)
    if not quiet then dbg("Spawner: equipWeapon called for target") end
    local pawn = State.playerPawn
    if not (pawn and pawn:IsValid() and target and target:IsValid()) then 
        if not quiet then dbg("Spawner: equipWeapon early return - pawn or target invalid") end
        return 
    end

    local cloneMesh
    for _, f in ipairs({ "LeaderMesh", "Mesh", "HandMesh", "TorsoMesh", "HeadMesh",
                         "LegMesh", "FeetMesh", "HairMesh" }) do
        local c; pcall(function() c = target[f] end)
        if c and c:IsValid() then
            local nb = 0
            pcall(function() nb = c:GetNumBones() end)
            if nb > 0 then cloneMesh = c break end
        end
    end
    if not cloneMesh then
        local skCls = core.findStatic("/Script/Engine.SkeletalMeshComponent")
        if skCls then
            local okL, list = pcall(function() return target:K2_GetComponentsByClass(skCls) end)
            if okL and type(list) == "table" then
                for _, c in pairs(list) do
                    if c and c:IsValid() then
                        local nb = 0
                        pcall(function() nb = c:GetNumBones() end)
                        if nb > 0 then cloneMesh = c break end
                    end
                end
            end
        end
    end
    if not (cloneMesh and cloneMesh:IsValid()) then
        logMsg("Spawner: target has no SkeletalMeshComponent for weapon attach")
        return
    end

    local okC, cc = pcall(function() return pawn.CombatComponent end)
    if not (okC and cc and cc:IsValid()) then
        logMsg("Spawner: no CombatComponent on player")
        return
    end

    local cloneCC
    if allowReal then
        local okCC, c = pcall(function() return target.CombatComponent end)
        cloneCC = (okCC and c and c:IsValid()) and c or nil
        dbg("Spawner: player CC ok, clone CC %s", cloneCC and "present" or "MISSING")
    end

    if not quiet and Config.debug then
        -- Diagnostics: what the game's socket API reports, and what the
        -- skeleton actually has. One run pins down the failing lookup.
        logSlotSockets(cc, "playerCC")
        if cloneCC then logSlotSockets(cloneCC, "cloneCC") end
        dumpSockets(cloneMesh, "targetMesh")
    end

    -- Authoritative in-hand socket name (EWeaponSlot::RightHand = 1).
    local handSock
    for _, fn in ipairs({ "GetWeaponSocketNameForSlot", "GetSocketNameForSlot" }) do
        local ok, s = pcall(function() return cc[fn](cc, 1) end)
        if ok and s then
            local sStr = fnameStr(s)
            if sStr ~= "" and sStr ~= "None" then handSock = s break end
        end
    end

    -- Which skeletal component really owns that socket on this actor.
    local attachComp = handSock and findSocketComponent(target, handSock, quiet) or nil
    if handSock and not attachComp then
        dbg("Spawner: no component owns '%s' — falling back to Mesh", fnameStr(handSock))
    end
    attachComp = attachComp or cloneMesh

    -- Visual-only in-hand weapon: a StaticMeshComponent owned by the target —
    -- dies with it, nothing left to leak (TIK-008).
    local forcedHand = false
    local sock

    -- Mesh discovery: player CC's EquippedWeaponMesh -> weapon actor's
    -- BaseMesh -> sheathed meshes. GetMainWeapon is nil when sheathed; no
    -- GetAttachedActors fallback — that call CTDs in this build.
    local sm, weapon, baseMesh
    pcall(function()
        local m = cc.EquippedWeaponMesh
        if m and m:IsValid() then sm = m end
    end)
    for _, getter in ipairs({ "GetMainWeapon", "GetCurrentAttackWeapon" }) do
        local okW, w = pcall(function() return cc[getter](cc) end)
        if okW and w and w:IsValid() then weapon = w break end
    end
    dbg("Spawner: player weapon actor %s", weapon and "found" or "NOT FOUND (sheathed?)")
    if weapon then
        pcall(function()
            baseMesh = weapon.BaseMesh
            if baseMesh and baseMesh:IsValid() then
                local okG, r = pcall(function() return baseMesh.StaticMesh end)
                sm = sm or ((okG and r) or baseMesh.StaticMesh)
            end
        end)
    end
    -- Last resort: reuse a sheathed sword mesh so the clone can still hold
    -- a blade in hand.
    if not sm then
        for _, src in ipairs({ pawn, target }) do
            local got
            pcall(function()
                local sh = src.SheathedWeaponMesh
                if sh and sh:IsValid() then
                    local okG, r = pcall(function() return sh.StaticMesh end)
                    got = (okG and r) or sh.StaticMesh
                end
            end)
            if got then sm = got break end
        end
        if sm then logMsg("Spawner: using sheathed mesh as hand weapon") end
    end

    local mathLib = core.findStatic("/Script/Engine.Default__KismetMathLibrary")
    if not mathLib then
        logMsg("Spawner: KismetMathLibrary not found")
        return
    end

    -- Prefer the hand socket (EWeaponSlot::RightHand=1): the weapon's current
    -- attach parent may be the sheathe socket when the sword is stowed.
    local attachSock
    if weapon then
        pcall(function() attachSock = weapon:GetAttachParentSocketName() end)
    end
    sock = handSock or resolveHandSocket(cc, attachComp)
    if not sock then sock = attachSock end
    forcedHand = sock and (fnameStr(sock) ~= fnameStr(attachSock))
    if not sm then logMsg("Spawner: weapon has no visible mesh (fists?)") return end
    if not sock then logMsg("Spawner: could not read weapon attach socket") return end

    -- Grip offset = the weapon mesh's transform relative to the socket
    -- (compose root-relative * mesh-relative when nested). Only valid when the
    -- target socket is the weapon's own — forcing the hand socket keeps
    -- identity and lets the socket's authored grip do the work.
    local relLoc, relRot, relScale = {X=0,Y=0,Z=0}, {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1}
    if weapon and not forcedHand then
        pcall(function()
            local root = weapon:K2_GetRootComponent()
            local function relT(c)
                return mathLib:MakeTransform(c.RelativeLocation, c.RelativeRotation, c.RelativeScale3D)
            end
            local t = relT(root)
            if baseMesh and baseMesh:IsValid() and baseMesh ~= root then
                t = mathLib:ComposeTransforms(relT(root), relT(baseMesh))
            end
            local l = t.Translation
            local s = t.Scale3D
            if l and l.X then
                relLoc, relScale = l, s
                -- Rotation remains default as FQuat extraction to FRotator requires mathLib without out params
            end
        end)
    end

    -- Weapon visuals: hijack the target's NATIVE SheathedWeaponMesh and move
    -- it to the hand socket — registered, game-rendered, dies with its owner.
    -- (bManualAttachment components never register/render from Lua.) Orig
    -- state is cached for restore on sheathe/exit.
    local wcomp
    pcall(function()
        local sh = target.SheathedWeaponMesh
        if sh and sh:IsValid() then wcomp = sh end
    end)

    if wcomp then
        if not M.hijackedComps[wcomp] then
            local orig = {}
            pcall(function() orig.parent = wcomp:GetAttachParent() end)
            pcall(function() orig.sock = wcomp:GetAttachSocketName() end)
            pcall(function() orig.relLoc = wcomp.RelativeLocation end)
            pcall(function() orig.relRot = wcomp.RelativeRotation end)
            pcall(function() orig.relScale = wcomp.RelativeScale3D end)
            pcall(function() orig.mesh = wcomp.StaticMesh end)
            pcall(function() orig.vis = wcomp:IsVisible() end)
            pcall(function() orig.hidden = wcomp.bHiddenInGame end)
            M.hijackedComps[wcomp] = orig
        end
        M.weaponDraw[wcomp] = {
            attachComp = attachComp, sock = sock,
            relLoc = relLoc, relRot = relRot, relScale = relScale, mesh = sm,
        }
        local okA, errA = pcall(function()
            local okS = pcall(function() wcomp:SetStaticMesh(sm) end)
            if not okS then wcomp.StaticMesh = sm end
            -- EAttachmentRule: SnapToTarget(2) for loc/rot, KeepRelative(0) scale
            wcomp:K2_AttachToComponent(attachComp, sock, 2, 2, 0, false)
            wcomp.RelativeLocation = relLoc
            wcomp.RelativeRotation = relRot
            wcomp.RelativeScale3D = relScale
            wcomp:SetVisibility(true, true)
            wcomp:SetHiddenInGame(false, true)
        end)
        if okA then
            dbg("Spawner: weapon drawn on native SheathedWeaponMesh -> '%s'%s",
                fnameStr(sock), forcedHand and " (forced hand)" or "")
        else
            logMsg("Spawner: weapon hijack attach failed (%s)", tostring(errA))
            wcomp = nil
        end
    else
        -- Fallback for classes without SheathedWeaponMesh: spawned component.
        -- Renders only if the engine registers it — kept as best-effort.
        local smcCls = core.findStatic("/Script/Engine.StaticMeshComponent")
        if not smcCls then
            logMsg("Spawner: no SheathedWeaponMesh and no StaticMeshComponent class")
            return
        end
        local t0 = mathLib:MakeTransform({X=0,Y=0,Z=0}, {Pitch=0,Yaw=0,Roll=0}, {X=1,Y=1,Z=1})
        local okAdd = pcall(function()
            wcomp = target:AddComponentByClass(smcCls, false, t0, false)
        end)
        if not okAdd then
            okAdd = pcall(function()
                wcomp = target:AddComponentByClass(smcCls, false, nil, false)
            end)
        end
        if not (wcomp and wcomp:IsValid()) then
            logMsg("Spawner: weapon component spawn failed ok=%s", tostring(okAdd))
            return nil
        end
        local okA, errA = pcall(function()
            local okS = pcall(function() wcomp:SetStaticMesh(sm) end)
            if not okS then wcomp.StaticMesh = sm end
            pcall(function() wcomp:SetMobility(2) end)
            pcall(function() wcomp:SetCollisionEnabled(0) end)
            wcomp:K2_AttachToComponent(attachComp, sock, 2, 2, 0, false)
            wcomp.RelativeLocation = relLoc
            wcomp.RelativeRotation = relRot
            wcomp.RelativeScale3D = relScale
            wcomp:SetVisibility(true, true)
        end)
        if okA then
            trackWeapon(wcomp)
            pcall(function()
                local af = (EInternalObjectFlags and EInternalObjectFlags.Async) or 0x04000000
                dbg("Spawner: weapon comp async-flag=%s", tostring(wcomp:HasAnyInternalFlags(af)))
            end)
            dbg("Spawner: weapon mirrored on socket '%s'%s", fnameStr(sock),
                forcedHand and " (forced hand)" or "")
        else
            logMsg("Spawner: weapon attach failed (%s)", tostring(errA))
            destroyPropEntity(wcomp)
            wcomp = nil
        end
    end

    local weaponInHand = (wcomp ~= nil)

    -- Sheathed sword/scabbard comps spawn empty on the clone — copy the
    -- player's meshes/visibility; hide the sheathed copy while the in-hand
    -- weapon shows (no double render).
    pcall(function()
        for _, name in ipairs({ "SheathedWeaponMesh", "ScabbardMesh" }) do
            local src = pawn[name]
            local dst = target[name]
            if src and src:IsValid() and dst and dst:IsValid()
               and not (wcomp and sameObject(dst, wcomp)) then
                local m
                local okG, r = pcall(function() return src.StaticMesh end)
                if okG and r then m = r else m = src.StaticMesh end
                if m then
                    local okSet = pcall(function() dst:SetStaticMesh(m) end)
                    if not okSet then dst.StaticMesh = m end
                end
                local vis = src:IsVisible()
                if weaponInHand and name == "SheathedWeaponMesh" then vis = false end
                pcall(function() dst:SetVisibility(vis, true) end)
            end
        end
    end)

    return wcomp
end

-- Clones get the same visual-only weapon component as the player proxy —
-- no native weapon actors are ever spawned anymore (TIK-008).
function M.equipCloneWeapon(clone)
    return M.equipWeapon(clone, true, false)
end

---------------------------------------------------------------------------- Player weapon (visual proxy only)

M.playerWeaponProxy = nil
M.playerSheathedVis = nil

function M.ensurePlayerWeapon()
    local pawn = State.playerPawn
    if not (pawn and pawn:IsValid()) then
        pawn = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerPlayerCharacter", "BP_PlayerCharacter"})
        if pawn and pawn:IsValid() then State.playerPawn = pawn end
    end
    if not (pawn and pawn:IsValid()) then return end

    -- Player already has the real weapon drawn — hide our proxy so the blade
    -- doesn't render twice.
    local okC, cc = pcall(function() return pawn.CombatComponent end)
    if okC and cc and cc:IsValid() then
        local okW, w = pcall(function() return cc:GetMainWeapon() end)
        if okW and w and w:IsValid() then
            local proxy = M.playerWeaponProxy
            if proxy and proxy:IsValid() then
                pcall(function() proxy:SetActorHiddenInGame(true) end)
                pcall(function() proxy:SetVisibility(false, true) end)
            end
            return
        end
    end

    if not (M.playerWeaponProxy and M.playerWeaponProxy:IsValid()) then
        M.playerWeaponProxy = M.equipWeapon(pawn, false, true)
    elseif M.weaponDraw[M.playerWeaponProxy] then
        -- Hijacked native comp currently restored to the sheath — re-draw.
        drawWeaponComp(M.playerWeaponProxy)
    else
        pcall(function() M.playerWeaponProxy:SetActorHiddenInGame(false) end)
        pcall(function() M.playerWeaponProxy:SetVisibility(true, true) end)
    end

    -- Hide the player's sheathed copy so the sword doesn't render twice —
    -- unless the proxy IS that comp (hijacked SheathedWeaponMesh moved to
    -- the hand): hiding it would hide the in-hand sword.
    pcall(function()
        local sh = pawn.SheathedWeaponMesh
        if sh and sh:IsValid()
           and not (M.playerWeaponProxy and sameObject(sh, M.playerWeaponProxy)) then
            if M.playerSheathedVis == nil then M.playerSheathedVis = sh:IsVisible() end
            sh:SetVisibility(false, true)
        end
    end)
end

function M.clearPlayerWeapon()
    local proxy = M.playerWeaponProxy
    if proxy and proxy:IsValid() then
        if M.hijackedComps[proxy] then
            -- Native comp on the player pawn: back on the sheath socket —
            -- keep the hijacked/draw entries so a later weapon pose can
            -- re-draw it; destroyAll clears the tables for good.
            restoreWeaponComp(proxy)
        else
            pcall(function() proxy:SetActorHiddenInGame(true) end)
            pcall(function() proxy:SetVisibility(false, true) end)
        end
    end
    local pawn = State.playerPawn
    if pawn and pawn:IsValid() and M.playerSheathedVis ~= nil then
        pcall(function()
            local sh = pawn.SheathedWeaponMesh
            if sh and sh:IsValid()
               and not (proxy and sameObject(sh, proxy)) then
                sh:SetVisibility(M.playerSheathedVis, true)
            end
        end)
        M.playerSheathedVis = nil
    end
end

-- Per-pose weapon show/hide. targetIdx: 0 = player, 1+ = clone index.
-- wantWeapon=false hides the in-hand weapon and restores the sheathed look.
function M.applyWeaponState(targetIdx, wantWeapon)
    dbg("Spawner: applyWeaponState(targetIdx=%s, wantWeapon=%s)", tostring(targetIdx), tostring(wantWeapon))
    if targetIdx == 0 then
        if wantWeapon then M.ensurePlayerWeapon() else M.clearPlayerWeapon() end
        return
    end
    local clone = M.spawnedClones[targetIdx]
    if not (clone and clone:IsValid()) then 
        dbg("Spawner: applyWeaponState - clone invalid")
        return 
    end
    local info = M.cloneInfos[targetIdx]
    dbg("Spawner: applyWeaponState - info.canUseWeapon=%s", tostring(info and info.canUseWeapon))
    -- NPC classes that can't carry weapons skip weapon visuals entirely.
    if info and info.canUseWeapon == false then
        -- Defensive: a weapon should never exist here, but clean up a stale
        -- one — destroyWeaponActor restores hijacked native comps instead of
        -- destroying them.
        local stale = M.spawnedWeapons[targetIdx]
        if stale and stale:IsValid() then
            destroyWeaponActor(stale)
        end
        M.spawnedWeapons[targetIdx] = nil
        pcall(function()
            local sh = clone.SheathedWeaponMesh
            if sh and sh:IsValid() then sh:SetVisibility(true, true) end
        end)
        dbg("Spawner: applyWeaponState - canUseWeapon is false, returning")
        return
    end
    local w = M.spawnedWeapons[targetIdx]
    dbg("Spawner: applyWeaponState - current w is %s", w and "VALID" or "INVALID/NIL")
    if wantWeapon and not (w and w:IsValid()) then
        dbg("Spawner: applyWeaponState - calling equipWeapon")
        w = M.equipWeapon(clone, true, false)
        M.spawnedWeapons[targetIdx] = w
        dbg("Spawner: applyWeaponState - equipWeapon returned %s", w and "VALID" or "NIL")
    end
    if w and w:IsValid() then
        if M.hijackedComps[w] then
            -- Native SheathedWeaponMesh hijack: draw = hand socket, sheathe =
            -- restore the saved attach — real sheathed look, not a hide.
            if wantWeapon then
                drawWeaponComp(w)
            else
                restoreWeaponComp(w)
            end
        else
            -- Spawned-component fallback: visibility only. SetVisibility's
            -- first param is the NEW visibility — passing `not wantWeapon`
            -- here hid the sword right after equipping it.
            pcall(function() w:SetVisibility(wantWeapon, true) end)
            pcall(function() w:SetHiddenInGame(not wantWeapon, true) end)
        end
    end
    pcall(function()
        local sh = clone.SheathedWeaponMesh
        -- When the sheathed comp IS the in-hand weapon (hijack), never touch
        -- its visibility here — the draw/restore above already handled it.
        if sh and sh:IsValid() and not (w and sameObject(sh, w)) then
            sh:SetVisibility(not wantWeapon, true)
        end
    end)
end

-- Detach, hide and destroy a weapon/prop actor. Detaching first severs the
-- attach reference into the PersistentLevel so nothing keeps the actor (or
-- the whole world) reachable at level transition (TIK-008 world-leak CTD).
destroyWeaponActor = function(w)
    if not (w and w:IsValid()) then return end
    if M.hijackedComps[w] then
        -- A hijacked native component is never destroyed — restore it to the
        -- sheathed state (on clones this is a no-op since the owner dies).
        restoreWeaponComp(w)
        M.hijackedComps[w] = nil
        M.weaponDraw[w] = nil
        return
    end
    local name; pcall(function() name = w:GetFullName() end)
    pcall(function() w:K2_DetachFromActor(1, 1, 1) end)
    pcall(function() w:SetActorHiddenInGame(true) end)
    pcall(function() w:K2_DestroyActor() end)
    local stillValid
    pcall(function() stillValid = w:IsValid() end)
    if stillValid then
        -- Component path: weapon visuals are StaticMeshComponents owned by
        -- the target — the owning actor must destroy them.
        pcall(function() w:SetVisibility(false, true) end)
        local owner, ownerValid
        pcall(function() owner = w:GetOwner() end)
        if owner then pcall(function() ownerValid = owner:IsValid() end) end
        if ownerValid then
            pcall(function() w:K2_DetachFromComponent(1, 1, 1, false) end)
            pcall(function() owner:K2_DestroyComponent(w) end)
        end
        pcall(function() stillValid = w:IsValid() end)
    end
    if stillValid then
        -- AActor::Destroy() is not a UFUNCTION (unreachable from Lua) —
        -- SetLifeSpan schedules engine-side destruction on the next tick,
        -- which now runs because exitPhotoMode unfreezes before teardown.
        logMsg("Spawner: weapon destroy failed for %s — SetLifeSpan fallback", tostring(name))
        pcall(function() w:SetLifeSpan(0.001) end)
        pcall(function() stillValid = w:IsValid() end)
        if stillValid then
            logMsg("Spawner: weapon STILL VALID after SetLifeSpan: %s", tostring(name))
        else
            dbg("Spawner: destroyed %s", tostring(name))
        end
    else
        dbg("Spawner: destroyed %s", tostring(name))
    end
end

-- The CombatComponent's SpawnedWeapons TMap holds main AND offhand actors —
-- including ones GetMainWeapon never returned. Cache the map FIRST
-- (RemoveAllWeapons clears it), run native cleanup while actors are valid,
-- then destroy anything still alive (TIK-008).
local function destroyNativeWeapons(clone)
    pcall(function()
        local cc = clone.CombatComponent
        if not (cc and cc:IsValid()) then return end
        local cached = collectWeapons(cc.SpawnedWeapons)
        pcall(function() cc:RemoveAllWeapons(false) end)
        for _, w in ipairs(cached) do destroyWeaponActor(w) end
        for _, w in ipairs(collectWeapons(cc.SpawnedWeapons)) do
            destroyWeaponActor(w)
        end
    end)
end

function M.destroyAll()
    -- Destroy runtime objects FIRST while owners are alive — a pending-kill
    -- owner can't K2_DestroyComponent, leaving uncollectable garbage (TIK-008).
    for w in pairs(M.knownWeapons) do
        destroyWeaponActor(w)
    end
    for _, w in pairs(M.spawnedWeapons) do
        destroyWeaponActor(w)
    end
    M.clearAllProps()
    if M.playerWeaponProxy and M.playerWeaponProxy:IsValid() then
        destroyWeaponActor(M.playerWeaponProxy)
    end
    M.playerWeaponProxy = nil
    for _, c in ipairs(M.spawnedClones) do
        if c and c:IsValid() then
            destroyNativeWeapons(c)
            pcall(function() c:K2_DestroyActor() end)
        end
    end
    M.spawnedClones = {}
    M.spawnedWeapons = {}
    M.knownWeapons = {}
    M.hijackedComps = {}
    M.weaponDraw = {}
    M.cloneInfos = {}
    M.poseMetadata = {}
    M.coenMirror = {}
    M.cloneOrigLocs = {}
    M.cloneOrigRots = {}
    M.playerSheathedVis = nil
    -- Force a GC pass (plus a delayed second one) so nothing pending-kill
    -- survives into the next save load's world-leak check.
    pcall(function() collectgarbage("collect") end)
    pcall(function() core.consoleCommand("obj gc") end)
    pcall(function()
        local pc = Subsystem.playerController()
        if pc then pc:ClientForceGarbageCollection() end
    end)
    if core.delayGameThread then
        core.delayGameThread(500, function()
            pcall(function() collectgarbage("collect") end)
            pcall(function() core.consoleCommand("obj gc") end)
        end)
    end
    logMsg("Spawner: Destroyed all clones")
end

function M.resetTargetLocation(target)
    if not (target and target:IsValid()) then return end
    if sameObject(target, State.playerPawn) then
        if State.playerOrigLoc then
            local hitRes = {}
            pcall(function()
                target:K2_SetActorLocationAndRotation(State.playerOrigLoc, State.playerOrigRot or target:K2_GetActorRotation(), false, hitRes, true)
            end)
            logMsg("Spawner: Player location reset to initial")
        end
    else
        local idx = nil
        for i, c in ipairs(M.spawnedClones) do
            if sameObject(c, target) then idx = i break end
        end
        if idx and M.cloneOrigLocs[idx] then
            local loc = M.cloneOrigLocs[idx]
            local rot = M.cloneOrigRots[idx]
            local hitRes = {}
            pcall(function()
                target:K2_SetActorLocationAndRotation(loc, rot or target:K2_GetActorRotation(), false, hitRes, true)
            end)
            logMsg("Spawner: Clone %d location reset to initial", idx)
        end
    end
end

return M
