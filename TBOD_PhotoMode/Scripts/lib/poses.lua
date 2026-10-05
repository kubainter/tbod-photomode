local core = require("lib.core")
local State = core.State
local Subsystem = core.Subsystem
local logMsg = core.logMsg
local dbg = core.dbg
local spawner = require("lib.spawner")
local M = {}

-- Pose library organized by animation family. The game shares one human skeleton
-- (/Game/_Dawnwalker/Animation/Humans/_Assets/DW_Human_Skeleton) across all human
-- characters; Coen_Human / Male_Human / Female_Human / Child_Human are authored
-- variations on that skeleton.
M.FAMILY_ORDER = { "coen", "male", "female", "child", "uriash" }
M.DEFAULT_FAMILY = "coen"


M.POSES = {
    coen = {
        { name = "Off" },
        { name = "Unarmed Idle",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Locomotion/Coen_Human_Unarmed/Coen_Idle.Coen_Idle" },
        { name = "Longsword Guard", path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Locomotion/Coen_Human_Unarmed/A_Coen_Human_Longsword_Idle_01.A_Coen_Human_Longsword_Idle_01" },
        { name = "Vampire Combat",  path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Vampire/Animation/Locomotion/Coen_Vampire_Combat/Coen_Vampire_Combat_Idle_01.Coen_Vampire_Combat_Idle_01" },
        { name = "Fists Guard",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Locomotion/Coen_Human_Fists/Coen_Human_Fists_Aim_Idle.Coen_Human_Fists_Aim_Idle" },
        { name = "Fencing Stance",  path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Combat/Coen_Human_Combat_Longsword_Defence/CombatRework/Coen_Human_CombatFencing_Left_Pose_Strafe_Guard_Right_Idle.Coen_Human_CombatFencing_Left_Pose_Strafe_Guard_Right_Idle" },
        { name = "Sword Dodge",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Combat/Coen_Human_Combat_Longsword_Defence/Coen_Human_Combat_Longsword_Right_Pose_Dodge_Back.Coen_Human_Combat_Longsword_Right_Pose_Dodge_Back", loop = false },
        { name = "Crouch Idle",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Locomotion/Coen_Human_Unarmed/Coen_Crouch_Idle.Coen_Crouch_Idle" },
        { name = "Death Lying",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Coen_Human/Animation/Locomotion/Coen_Human_Unarmed/A_Coen_Human_Fall_Death_Loop_01.A_Coen_Human_Fall_Death_Loop_01", z_offset = -85.0, ground = true },
    },
    male = {
        { name = "Off" },
        { name = "Combat 2H Idle",  path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_2h_Defense/Male_Human_Combat_2h_Right_Pose_Combat_Idle.Male_Human_Combat_2h_Right_Pose_Combat_Idle", weapon = true },
        { name = "2H Guard Top",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_2h_Defense/Male_Human_Combat_2h_Right_Pose_Guard_Top.Male_Human_Combat_2h_Right_Pose_Guard_Top", weapon = true },
        { name = "2H Attack",       path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_2h_Attacks/CombatRework/Male_Human_CombatFencing_2h_Right_Pose_Attack_Top_impact.Male_Human_CombatFencing_2h_Right_Pose_Attack_Top_impact", loop = false, weapon = true },
        { name = "Fists Attack",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_Fists_Attacks/A_MaleHuman_Fists_PoseLeft_Attack_Left_01.A_MaleHuman_Fists_PoseLeft_Attack_Left_01", loop = false, weapon = false },
        { name = "Fists Parry",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_Fists_Reactions/A_MaleHuman_Fists_PoseLeft_ParryReaction_Bottom_01.A_MaleHuman_Fists_PoseLeft_ParryReaction_Bottom_01", loop = false, weapon = false },
        { name = "Fists Guard",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_Fists_Defense/A_MaleHuman_Fists_Guard_Left_01.A_MaleHuman_Fists_Guard_Left_01", weapon = false },
        { name = "Sit Ground A",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Sitting_B/Male_Human_Community_Sitting_Ground_A_Loop_01.Male_Human_Community_Sitting_Ground_A_Loop_01", z_offset = -45.0, ground = true },
        { name = "Sit Eat",         path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Sitting/Male_Human_Community_Sitting_Eating_Loop_01.Male_Human_Community_Sitting_Eating_Loop_01", z_offset = -45.0, ground = true, prop_l = "bread" },
        { name = "Ground Sit B",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Sitting_B/Male_Human_Community_Sitting_Ground_B_Loop_01.Male_Human_Community_Sitting_Ground_B_Loop_01", z_offset = -45.0, ground = true },
        { name = "Wall Lean",       path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Standing/Male_Human_Community_Wall_E_Loop_01.Male_Human_Community_Wall_E_Loop_01" },
        { name = "Digging",         path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Working/Male_Human_Community_Kneeling_Digging_Loop_01.Male_Human_Community_Kneeling_Digging_Loop_01", z_offset = -45.0, ground = true },
        { name = "Drink",           path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Standing/Male_Human_Community_Drinking_Loop_03.Male_Human_Community_Drinking_Loop_03", prop_l = "bottle" },
        { name = "Hammer",          path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Working/Male_Human_Community_Hammering_Loop_01.Male_Human_Community_Hammering_Loop_01", prop = "hammer", prop_l = "stake" },
        { name = "Death Pose",      path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Combat/Male_Human_Combat_VS/Male_Human_Combat_Death_01.Male_Human_Combat_Death_01", z_offset = -85.0, ground = true, weapon = false },
        { name = "Threatening",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Soldier/Male_Human_Community_Soldier_Threatening_Loop_02.Male_Human_Community_Soldier_Threatening_Loop_02", weapon = true },
        { name = "Holy Blessing",   path = "/Game/_Dawnwalker/Animation/Dialogues/Custom/sq001/sq001_04_Vladimir_cross_02.sq001_04_Vladimir_cross_02", loop = false, weapon = false },
        { name = "Feeding",         path = "/Game/_Dawnwalker/Animation/Dialogues/Custom/q002/q002_03/q002_03_dis_feeding_mother_Coen.q002_03_dis_feeding_mother_Coen", loop = false, weapon = false, prop = "spoon" },
        { name = "Kindle Bonfire",  path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Working_E/Male_Human_Community_Starting_Bonfire_Loop_01.Male_Human_Community_Starting_Bonfire_Loop_01", z_offset = -40.0, ground = true, weapon = false },
        { name = "Executioner",     path = "/Game/_Dawnwalker/Animation/Dialogues/Custom/sq710/sq710_15_BloodGuard_kills_Npc_Sync_B_01.sq710_15_BloodGuard_kills_Npc_Sync_B_01", loop = false, weapon = false },
    },
    female = {
        { name = "Off" },
        { name = "Idle",            path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Locomotion/Locomotion_NEW/Female_Human_Idle_01.Female_Human_Idle_01" },
        { name = "Sit A",           path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_community_Sitting/Female_Community_Sitting_A_Loop_01.Female_Community_Sitting_A_Loop_01", z_offset = -45.0, ground = true },
        { name = "Arms Crossed",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Arms_Crossed_Loop_01.Female_Human_Community_Arms_Crossed_Loop_01" },
        { name = "Hands On Hips",   path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Hands_On_Hips_Loop_01.Female_Human_Community_Hands_On_Hips_Loop_01" },
        { name = "Look Down",       path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Looking_Down_Loop_01.Female_Human_Community_Looking_Down_Loop_01" },
        { name = "Look Flowers",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Looking_Flowers_Loop_01.Female_Human_Community_Looking_Flowers_Loop_01" },
        { name = "Sit Depressed",   path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Sitting_B/Female_Human_Esme_Sitting_Depressed_Loop_01.Female_Human_Esme_Sitting_Depressed_Loop_01", z_offset = -45.0, ground = true },
        { name = "Wall Waiting",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Wall_Waiting_Loop_01.Female_Human_Community_Wall_Waiting_Loop_01" },
        { name = "Zombie Resurrect",path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Combat/ZombieNun_Combat_Reactions/A_ZombieNun_Resurrect_01.A_ZombieNun_Resurrect_01", loop = false },
        { name = "Tired",           path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Tired_Stop.Female_Human_Community_Tired_Stop" },
        { name = "Witch Spellcast", path = "/Game/_Dawnwalker/Animation_MH/Humans/Witch/Animation/Combat/Witch_Combat_Attacks/Witch_Combat_Projectile_R.Witch_Combat_Projectile_R", loop = false, weapon = false },
        { name = "Glamour Pose",    path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Dialogue/Female_Human_Sexy_Pose_Loop_04.Female_Human_Sexy_Pose_Loop_04", weapon = false },
        { name = "Weeping Nun",     path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Combat/ZombieNun_Action_Points/A_ZombieNun_AP_Standing_Crying_A_Loop_01.A_ZombieNun_AP_Standing_Crying_A_Loop_01", weapon = false },
        { name = "Duelist Idle",    path = "/Game/_Dawnwalker/Animation/Dialogues/Custom/q301/q301_07_Xanthe_phase_01_idle_01.q301_07_Xanthe_phase_01_idle_01", weapon = false },
        { name = "Praying",         path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Praying/Female_Human_Community_Standing_Praying_B_Loop_01.Female_Human_Community_Standing_Praying_B_Loop_01", weapon = false },
        { name = "Eat Stop",        path = "/Game/_Dawnwalker/Animation_MH/Humans/Female_Human/Animation/Community/Female_Community_Backround_Standing/Female_Human_Community_Eating_Stop.Female_Human_Community_Eating_Stop", loop = false, weapon = false, prop_l = "bread" },
        { name = "Eating",          path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Standing/Male_Human_Community_Eating_Loop_01.Male_Human_Community_Eating_Loop_01", weapon = false, prop_l = "bread" },
        { name = "Read Book",       path = "/Game/_Dawnwalker/Animation_MH/Humans/Male_Human/Animation/Community/Male_Human_Community_Background_Sitting_B/Male_Human_Community_Sitting_Reading_Book_Loop_01.Male_Human_Community_Sitting_Reading_Book_Loop_01", z_offset = -45.0, ground = true, weapon = false, prop_l = "book" },
    },
    child = {
        { name = "Off" },
        { name = "Play Toy",        path = "/Game/_Dawnwalker/Animation_MH/Humans/Child_Human/Animation/Community/Playing/Child_Human_Community_playing_Toy_Loop_01.Child_Human_Community_playing_Toy_Loop_01" },
        { name = "Hopscotch",       path = "/Game/_Dawnwalker/Animation_MH/Humans/Child_Human/Animation/Community/Playing/Child_Human_Community_playing_Hopscotch_Loop_01.Child_Human_Community_playing_Hopscotch_Loop_01" },
        { name = "Play Monster",  path = "/Game/_Dawnwalker/Animation_MH/Humans/Child_Human/Animation/Community/Playing/Child_Human_Community_playing_Monster_Loop_01.Child_Human_Community_playing_Monster_Loop_01" },
        { name = "Digging",         path = "/Game/_Dawnwalker/Animation_MH/Humans/Child_Human/Animation/Community/Working/Child_Human_Community_Playing_Digging_Loop_01.Child_Human_Community_Playing_Digging_Loop_01", z_offset = -35.0, ground = true },
        { name = "Kneeling",        path = "/Game/_Dawnwalker/Animation_MH/Humans/Child_Human/Animation/Community/FastOut/Child_Human_Community_Kneeling_C_FastOut.Child_Human_Community_Kneeling_C_FastOut", loop = false, z_offset = -30.0, ground = true },
    },
    -- Uriash (Ocha etc.) run SKEL_UMA, not DW_Human_Skeleton â€” human
    -- AnimSequences can't play on them; "Off" leaves the native AnimBP. Add
    -- Uriash paths once dumped (AnimDumper near the Uriash village).
    uriash = {
        { name = "Off" },
    },
}

-- Hand props: preset name -> { mesh, socket?, loc?, rot?, scale? }.
-- socket defaults to the right-hand weapon socket; loc/rot/scale are applied
-- Ground truth (HeldDump of live NPCs): the game attaches prop meshes to the
-- authored prop_r / prop_l sockets with an IDENTITY relative transform â€” the
-- grip offset/rotation is baked into the socket itself, so NO loc/rot here.
-- Long tools go on socket_weapon_r instead (weapon-style grip, live rake NPC).
M.PROP_PRESETS = {
    spoon     = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/LargeWoodenSpoon/SM_LargeWoodenSpoon_02_withFood.SM_LargeWoodenSpoon_02_withFood" },
    book      = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/Books/Book_wldodgk/SM_BookClosed_01.SM_BookClosed_01" },
    bottle    = { mesh = "/Game/_Dawnwalker/Environment/Meshes/ManMade/Props/ClayPotsBowlsJarsCups/SM_OldCeramicBottle.SM_OldCeramicBottle" },
    cup       = { mesh = "/Game/_Dawnwalker/Environment/Meshes/ManMade/Props/ClayPotsBowlsJarsCups/SM_ClayCup.SM_ClayCup" },
    pitcher   = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/OldClayPitcher/SM_OldClayPitcher.SM_OldClayPitcher" },
    bowl      = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/WoodenBowls/SM_WoodenBowls_withFood.SM_WoodenBowls_withFood" },
    bread     = { mesh = "/Game/_Dawnwalker/Environment/Meshes/Nature/Food/BakedGoods/SM_HalfBread_A.SM_HalfBread_A" },
    meatpie   = { mesh = "/Game/_Dawnwalker/Environment/Meshes/Nature/Food/BakedGoods/SM_MeatPie_B.SM_MeatPie_B" },
    carrot    = { mesh = "/Game/_Dawnwalker/Environment/Meshes/Nature/Food/Carrot/SM_Carrot.SM_Carrot" },
    sausage   = { mesh = "/Game/_Dawnwalker/Environment/Meshes/Nature/Food/Sausage/SM_SausageA.SM_SausageA" },
    cleaver   = { mesh = "/Game/_Dawnwalker/Environment/Meshes/CustomMeshes/SQ716/SM_CleaverA.SM_CleaverA" },
    whetstone = { mesh = "/Game/_Dawnwalker/Environment/Meshes/ManMade/Props/Whetstone/SM_WhetStoneB.SM_WhetStoneB" },
    basket    = { mesh = "/Game/_Dawnwalker/Environment/Outsource/Woven_Basket_Set/SM_Woven_Basket_B.SM_Woven_Basket_B" },
    basket2   = { mesh = "/Game/_Dawnwalker/Environment/Outsource/Basket_Set/SM_Basket_C.SM_Basket_C" },
    shovel    = { mesh = "/Game/_Dawnwalker/Environment/Marketplace/Medieval_Environment/Medieval_Props_Vol3/Meshes/SM_Tool_Shovel_02.SM_Tool_Shovel_02",
                  socket = "socket_weapon_r" },
    hammer    = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/OldHammer/SM_OldHammer.SM_OldHammer",
                  socket = "socket_weapon_r" },
    rake      = { mesh = "/Game/_Dawnwalker/Environment/Marketplace/Medieval_Environment/Medieval_Props_Vol3/Meshes/SM_Tool_Rake_01.SM_Tool_Rake_01",
                  socket = "socket_weapon_r" },
    horseshoe = { mesh = "/Game/_Dawnwalker/Environment/Marketplace/Medieval_Environment/Medieval_Props_Vol3/Meshes/SM_Horseshoe_01.SM_Horseshoe_01" },
    tongs     = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/BlacksmithTongs/SM_BlacksmithTongs.SM_BlacksmithTongs" },
    stake     = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/StakesAndWedges/SM_StakesAndWedges_01.SM_StakesAndWedges_01" },
    wallhook  = { mesh = "/Game/_Dawnwalker/Environment/Megascans/3D_Assets/WallMountedMetalHook/SM_WallMountedMetalHook.SM_WallMountedMetalHook" },
    hook      = { mesh = "/Game/_Dawnwalker/Environment/Meshes/ManMade/Props/FishingRod/SM_Hook.SM_Hook" },
    axe       = { mesh = "/Game/_Dawnwalker/Environment/Marketplace/Medieval_Environment/Medieval_Props_Vol3/Meshes/SM_Tool_Axe_01.SM_Tool_Axe_01",
                  socket = "socket_weapon_r" },
    knife     = { mesh = "/Game/_Dawnwalker/Environment/Marketplace/Medieval_Environment/Medieval_Props_Vol3/Meshes/SM_Tool_Knife_02.SM_Tool_Knife_02",
                  socket = "socket_weapon_r" },
    bucket    = { mesh = "/Game/_Dawnwalker/Environment/Meshes/ManMade/Props/Buckets/SM_Bucket_A.SM_Bucket_A" },
}

-- entry.prop / entry.prop_l may be a preset name, a raw /Game/ mesh path
-- (INI), a { mesh=... } table, or nil. prop_l attaches to the LEFT hand.
local function resolveProp(p)
    if not p then return nil end
    if type(p) == "string" then
        if p:find("/Game/") then return { mesh = p } end
        return M.PROP_PRESETS[p]
    end
    if type(p) == "table" and (p.mesh or p[1]) then return p end
    return nil
end

-- Auto-detect pose metadata when not explicitly provided.
-- Keywords are weapon-specific on purpose: "combat"/"guard"/"attack" produced
-- false positives (Fists Guard, Vampire Combat, ZombieNun paths all live
-- under .../Combat/... but are unarmed anims).
local function wantsWeapon(entry)
    if entry.weapon ~= nil then return entry.weapon end
    local n = ((entry.path or "") .. " " .. (entry.name or "")):lower()
    local found = n:find("longsword") or n:find("sword") or n:find("fencing") or n:find("gladius") or n:find("weapon")
    return found ~= nil
end

local function wantsLoop(entry)
    if entry.loop ~= nil then return entry.loop end
    local n = (entry.path or ""):lower()
    if n:find("_start") or n:find("_stop") or n:find("_to_") or n:find("fastout") or n:find("transition") then return false end
    return true
end

-- Coen-family targets get the union of the coen and male libraries (TIK-008).
-- Coen entries first (stable indices), male appended, deduped by name.
-- Rebuilt lazily; loadCustomPoses invalidates the cache on INI re-merge.
local mergedCoenList = nil

-- Merge optional [CustomPoseN] entries from photo_mode.ini into the requested
-- family (default coen). Users can add up to 50 custom poses. Re-runnable:
-- entries are tagged _custom and stripped before re-merge so an INI reload
-- cannot duplicate them. Iterates 1..50 for deterministic list order.
local function loadCustomPoses()
    for _, list in pairs(M.POSES) do
        for i = #list, 1, -1 do
            if list[i]._custom then table.remove(list, i) end
        end
    end
    for n = 1, 50 do
        local cp = (core.CustomPoses or {})[n]
        if cp and cp.name and cp.path then
            local family = (cp.family or "coen"):lower()
            if not M.POSES[family] then family = "coen" end
            local function strTrue(v) return v and (v == "1" or v:lower() == "true") end
            local function strFalse(v) return v and (v == "0" or v:lower() == "false") end
            table.insert(M.POSES[family], {
                name = cp.name,
                path = cp.path,
                weapon = strTrue(cp.weapon),
                loop = not strFalse(cp.loop),
                z_offset = tonumber(cp.z_offset) or 0.0,
                ground = not strFalse(cp.ground),
                prop = cp.prop,
                prop_l = cp.prop_l,
                _custom = true,
            })
        end
    end
    core.customPosesDirty = false
    mergedCoenList = nil
end
loadCustomPoses()

M.targetIdx = 0 -- 0 = Player, 1+ = Clones
M.poseState = {} -- map of targetIdx -> pose index
M.replayEpoch = {} -- targetIdx -> token invalidating pending one-shot replays
M.epochCounter = 0 -- monotonic; never reset, so a stale callback from an
                   -- earlier PM session can never collide with a fresh token

local function nextEpoch(targetIdx)
    M.epochCounter = M.epochCounter + 1
    M.replayEpoch[targetIdx] = M.epochCounter
end

local function setAnimMode(mesh, mode)
    if not mesh or not mesh:IsValid() then return end
    pcall(function() mesh:SetAnimationMode(mode, false) end)
end

-- Modular actors may have an empty ACharacter::Mesh. Find a SkeletalMeshComponent
-- that is actually skinned and visible; prefer LeaderMesh, then Mesh, then the
-- component with the most bones.
local function findAnimMesh(target)
    if not target or not target:IsValid() then return nil end
    local comps, seen = {}, {}
    local function add(c, label)
        if c and c:IsValid() and not seen[c] then
            seen[c] = true
            table.insert(comps, { comp = c, label = label })
        end
    end
    for _, f in ipairs({ "LeaderMesh", "Mesh", "HandMesh", "TorsoMesh", "HeadMesh",
                         "LegMesh", "FeetMesh", "HairMesh", "EyebrowMeshComponent" }) do
        local c; pcall(function() c = target[f] end)
        add(c, f)
    end
    local skCls = core.findStatic("/Script/Engine.SkeletalMeshComponent")
    if skCls then
        local okL, list = pcall(function() return target:K2_GetComponentsByClass(skCls) end)
        if okL and type(list) == "table" then
            for _, c in pairs(list) do add(c, "?") end
        end
    end

    local best, bestScore
    for _, e in ipairs(comps) do
        local c = e.comp
        local isFollower = false
        pcall(function()
            local leader = c.LeaderPoseComponent
            if leader and leader:IsValid() then
                isFollower = true
            end
        end)
        
        local nb = -1; pcall(function() nb = c:GetNumBones() end)
        dbg("Poses: findAnimMesh checking '%s', isFollower=%s, nb=%s", e.label, tostring(isFollower), tostring(nb))

        if not isFollower then
            local vis = false; pcall(function() vis = c:IsVisible() end)
            
            local labelBonus = 0
            if e.label == "LeaderMesh" then labelBonus = 10000
            elseif e.label == "Mesh" then labelBonus = 5000
            elseif e.label == "TorsoMesh" then labelBonus = 1000
            end
            
            local score = nb + (vis and 2 or 0) + labelBonus
            if not best or score > bestScore then
                best, bestScore = c, score
            end
        end
    end
    if not best then
        logMsg("Poses: findAnimMesh failed! comps checked: %d", #comps)
    end
    return best
end

function M.getTargetFamily(targetIdx)
    if targetIdx == 0 then return "coen" end
    local info = spawner.cloneInfos[targetIdx]
    if info and info.family then return info.family end
    return M.DEFAULT_FAMILY
end

local function getCoenMergedList()
    if mergedCoenList then return mergedCoenList end
    local seen, merged = {}, {}
    for _, src in ipairs({ M.POSES.coen, M.POSES.male }) do
        for _, e in ipairs(src or {}) do
            if not seen[e.name] then
                seen[e.name] = true
                table.insert(merged, e)
            end
        end
    end
    mergedCoenList = merged
    return merged
end

function M.getPoseList(targetIdx)
    -- core.reloadConfig marks custom poses dirty; re-merge lazily so INI
    -- edits apply without restarting the mod.
    if core.customPosesDirty then loadCustomPoses() end
    local family = M.getTargetFamily(targetIdx)
    local list = M.POSES[family]
    if family == "coen" or not list then return getCoenMergedList() end
    return list
end

function M.getActiveTarget()
    if M.targetIdx == 0 then
        local pawn = State.playerPawn
        if not pawn or not pawn:IsValid() then
            pawn = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerCharacterBase", "BP_PlayerCharacter"})
            if pawn and pawn:IsValid() then State.playerPawn = pawn end
        end
        return pawn
    end
    local clone = spawner.spawnedClones[M.targetIdx]
    if not (clone and clone:IsValid()) then
        M.poseState[M.targetIdx] = nil
        M.targetIdx = 0
        return M.getActiveTarget()
    end
    return clone
end

function M.getTargetLabel()
    if M.targetIdx == 0 then return "Player" end
    local c = spawner.spawnedClones[M.targetIdx]
    if not (c and c:IsValid()) then return "Clone " .. tostring(M.targetIdx) .. " (gone)" end
    local info = spawner.cloneInfos[M.targetIdx]
    local label = info and info.label or ("Clone " .. tostring(M.targetIdx))
    return label .. " (#" .. tostring(M.targetIdx) .. ")"
end

function M.adjustTarget(delta)
    if core.cutsceneBlocked("target selection") then return end
    local maxTarget = #spawner.spawnedClones
    M.targetIdx = M.targetIdx + delta
    if M.targetIdx < 0 then M.targetIdx = maxTarget end
    if M.targetIdx > maxTarget then M.targetIdx = 0 end
end

-- Non-looping poses end on their last frame and would need manual re-trigger.
-- Schedule a replay one anim-length later; the epoch cancels it the moment
-- the pose changes, the target is cleared, or PhotoMode exits.
local function scheduleReplay(targetIdx, target, mesh, anim)
    local epoch = M.replayEpoch[targetIdx]
    local delayFn = core.delayGameThread
    if not (epoch and delayFn) then return end
    local lenMs = 3000
    pcall(function()
        local l = anim:GetPlayLength()
        if type(l) == "number" and l > 0 then lenMs = math.floor(l * 1000) end
    end)
    delayFn(lenMs + 100, function()
        if not State.photoModeActive then return end
        if M.replayEpoch[targetIdx] ~= epoch then return end
        if not (target and target:IsValid() and mesh and mesh:IsValid()) then return end
        local ok = pcall(function() mesh:PlayAnimation(anim, false) end)
        if ok then scheduleReplay(targetIdx, target, mesh, anim) end
    end)
end

function M.applyPose()
    dbg("Poses: applyPose called for targetIdx=%d", M.targetIdx)
    -- Invalidate any pending one-shot replay for this target.
    nextEpoch(M.targetIdx)
    local target = M.getActiveTarget()
    if not target or not target:IsValid() then 
        dbg("Poses: early return - invalid target (targetIdx=%d, target=%s)", M.targetIdx, tostring(target))
        return 
    end

    local idx = M.poseState[M.targetIdx]
    if not idx then 
        idx = (M.targetIdx == 0) and 1 or 2 
        M.poseState[M.targetIdx] = idx
    end
    local list = M.getPoseList(M.targetIdx)
    local entry = list[idx]
    if not entry then 
        dbg("Poses: early return - no pose entry (idx=%d, targetIdx=%d)", idx, M.targetIdx)
        return 
    end
    spawner.setPoseMetadata(M.targetIdx, entry.z_offset or 0.0, entry.ground)
    -- Clone targets: re-seat immediately so ground-snap/z_offset take effect
    -- now instead of waiting for the next move press. Strip the previous
    -- applied offset so it isn't re-added. The player is never moved.
    if M.targetIdx > 0 then
        local c = spawner.spawnedClones[M.targetIdx]
        if c and c:IsValid() then
            local m = spawner.poseMetadata[M.targetIdx]
            local loc = c:K2_GetActorLocation()
            if m and m.appliedOffset then loc.Z = loc.Z - m.appliedOffset end
            spawner.setCloneLocation(c, loc)
        end
    end

    local mesh = findAnimMesh(target)
    if not mesh or not mesh:IsValid() then
        logMsg("Poses: no animatable mesh on target")
        return
    end

    if not entry.path then
        pcall(function() setAnimMode(mesh, 0) end)
        spawner.applyPropState(M.targetIdx, nil, nil)
        spawner.applyWeaponState(M.targetIdx, false)
        logMsg("Poses: Restored AnimBP for target")
        return
    end

    local anim = core.findStatic(entry.path)
    if not (anim and anim:IsValid()) then
        local helpers = core.findStatic("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        if helpers then
            local pkg, name = entry.path:match("^(.+)%.([^%.]+)$")
            if pkg and name then
                local ok, loaded = pcall(function()
                    local assetData = { PackageName = FName(pkg), AssetName = FName(name) }
                    return helpers:GetAsset(assetData)
                end)
                loaded = (type(Unwrap) == "function") and Unwrap(loaded) or loaded
                if ok and loaded and loaded:IsValid() then anim = loaded end
            end
        end
    end
    if not anim or not anim:IsValid() then
        logMsg("Poses: Anim not found or not loaded: %s", tostring(entry.path))
        spawner.applyPropState(M.targetIdx, nil, nil)
        spawner.applyWeaponState(M.targetIdx, false)
        return
    end

    local okP, errP = pcall(function()
        setAnimMode(mesh, 1)
        mesh:PlayAnimation(anim, wantsLoop(entry))
    end)
    if okP then
        logMsg("Poses: Applied '%s' to target (family=%s)", entry.name, M.getTargetFamily(M.targetIdx))
        local propDef  = resolveProp(entry.prop)
        local propDefL = resolveProp(entry.prop_l)
        spawner.applyPropState(M.targetIdx, propDef, propDefL)
        -- A right-hand prop shares the weapon socket â€” it suppresses the
        -- weapon. A left-hand prop can coexist with one.
        spawner.applyWeaponState(M.targetIdx, not propDef and wantsWeapon(entry))
        if not wantsLoop(entry) then
            scheduleReplay(M.targetIdx, target, mesh, anim)
        end
    else
        logMsg("Poses: apply failed (%s)", tostring(errP))
    end
end

function M.resetPose()
    M.poseState[M.targetIdx] = 1
    M.applyPose()
end

function M.resetAllPoses()
    local function restore(target, isPlayer)
        if isPlayer and not (target and target:IsValid()) then
            target = core.findValid({"BP_PlayerCharacter_C", "DawnwalkerPlayerCharacter", "BP_PlayerCharacter"})
        end
        if target and target:IsValid() then
            pcall(function()
                local mesh = findAnimMesh(target)
                if mesh and mesh:IsValid() then setAnimMode(mesh, 0) end
            end)
        end
    end
    restore(State.playerPawn, true)
    for idx, clone in ipairs(spawner.spawnedClones) do
        restore(clone, false)
    end
    M.poseState = {}
    M.replayEpoch = {}
    M.targetIdx = 0
    spawner.clearAllProps()
    spawner.clearPlayerWeapon()
    logMsg("Poses: Reset all poses and restored AnimBPs")
end

function M.resetClonePoses()
    for idx, clone in ipairs(spawner.spawnedClones) do
        if clone and clone:IsValid() then
            pcall(function()
                local mesh = findAnimMesh(clone)
                if mesh and mesh:IsValid() then setAnimMode(mesh, 0) end
            end)
        end
        M.poseState[idx] = nil
        nextEpoch(idx)
        spawner.applyPropState(idx, nil, nil)
        spawner.applyWeaponState(idx, false)
    end
    if M.targetIdx > 0 then M.targetIdx = 0 end
    logMsg("Poses: Reset clone poses")
end

function M.adjustPose(delta)
    if core.cutsceneBlocked("pose editing") then return end
    local target = M.getActiveTarget()
    if not target or not target:IsValid() then return end

    local list = M.getPoseList(M.targetIdx)
    local idx = M.poseState[M.targetIdx]
    if not idx then idx = (M.targetIdx == 0) and 1 or 2 end
    idx = idx + delta
    if idx < 1 then idx = #list end
    if idx > #list then idx = 1 end

    M.poseState[M.targetIdx] = idx
    M.applyPose()
end

function M.getPoseLabel()
    local list = M.getPoseList(M.targetIdx)
    local idx = M.poseState[M.targetIdx]
    if not idx then idx = (M.targetIdx == 0) and 1 or 2 end
    local entry = list[idx]
    return entry and entry.name or "Off"
end

return M
