
AzCallouts = AzCallouts or {}
local AC = AzCallouts

AC.Scenes = AC.Scenes or {} -- [callId] = { peds = {}, vehicles = {} }

---------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------

local function addSceneEntity(callId, kind, entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end
    AC.Scenes[callId] = AC.Scenes[callId] or { peds = {}, vehicles = {} }
    table.insert(AC.Scenes[callId][kind], entity)
end

function AC.CleanupScene(callId)
    local scene = AC.Scenes[callId]
    if not scene then return end

    if scene.peds then
        for _, ped in ipairs(scene.peds) do
            if DoesEntityExist(ped) then
                DeleteEntity(ped)
            end
        end
    end
    if scene.vehicles then
        for _, veh in ipairs(scene.vehicles) do
            if DoesEntityExist(veh) then
                DeleteEntity(veh)
            end
        end
    end

    AC.Scenes[callId] = nil
end

function AC.GetScenePeds(callId)
    local scene = AC.Scenes[callId]
    if scene and scene.peds then
        return scene.peds
    end
    return {}
end


local function getRoadPositionAround(coords)
    -- coords is expected to be a table with x,y,z (from call.coords)
    local x, y, z = coords.x, coords.y, coords.z

    -- FiveM native: returns ok, vector3
    local ok, outPos = GetClosestVehicleNode(x, y, z, false, 3.0, 0)
    if ok and outPos then
        return outPos -- already a vector3
    end

    -- fallback: snap to ground
    local found, gz = GetGroundZFor_3dCoord(x, y, z + 10.0, false)
    if found then
        z = gz
    end
    return vector3(x, y, z)
end

local function offsetFromHeading(origin, headingDeg, forwardDist, sideDist)
    local h  = math.rad(headingDeg)
    local fx = math.sin(h)
    local fy = math.cos(h)
    local sx = -fy
    local sy = fx -- 90° left

    local x = origin.x + fx * forwardDist + sx * sideDist
    local y = origin.y + fy * forwardDist + sy * sideDist
    return vector3(x, y, origin.z)
end

local function chooseRandom(list, defaultVal)
    if not list or #list == 0 then return defaultVal end
    return list[math.random(1, #list)]
end

---------------------------------------------------------------------
-- primitive spawners
---------------------------------------------------------------------

local defaultPatientModels = Config and Config.PatientModels or {
    `a_m_m_skidrow_01`,
    `a_m_m_business_01`,
    `a_f_y_business_02`,
    `a_m_y_stbla_02`,
}

local function spawnPatientPed(callId, coords, heading, isPrimary)
    local model = chooseRandom(defaultPatientModels, `a_m_m_business_01`)
    RequestModel(model)
    local start = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - start < 5000 do
        Wait(0)
    end
    if not HasModelLoaded(model) then
        print('[Az-Ambulance][Callouts] Failed to load patient ped model '..tostring(model))
        return nil
    end

    local x, y, z = coords.x, coords.y, coords.z
    local found, gz = GetGroundZFor_3dCoord(x, y, z + 10.0, false)
    if found then z = gz end

    local ped = CreatePed(4, model, x, y, z, heading or 0.0, true, true)

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)

    local dict = 'combat@damage@rb_writhe'
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end
    TaskPlayAnim(ped, dict, 'rb_writhe_loop', 8.0, -8.0, -1, 1, 0.0, false, false, false)

    addSceneEntity(callId, 'peds', ped)

    if isPrimary then
        local netId = PedToNet(ped)
        SetNetworkIdCanMigrate(netId, true)
        return netId, ped
    end

    return nil, ped
end

local function spawnMVCVehicle(callId, coords, heading)
    local model = Config and Config.MVCVehicleModel or `blista`
    RequestModel(model)
    local start = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - start < 5000 do
        Wait(0)
    end
    if not HasModelLoaded(model) then
        print('[Az-Ambulance][Callouts] Failed to load MVC vehicle model '..tostring(model))
        return nil
    end

    local x, y, z = coords.x, coords.y, coords.z
    local found, gz = GetGroundZFor_3dCoord(x, y, z + 10.0, false)
    if found then z = gz end

    local veh = CreateVehicle(model, x, y, z, heading or 0.0, true, true)
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, false, true, false)
    SetVehicleDoorsLocked(veh, 1)

    addSceneEntity(callId, 'vehicles', veh)
    return veh
end

---------------------------------------------------------------------
-- scene builders per call-type
---------------------------------------------------------------------

-- simple 1-patient on the ground
local function spawnSimpleSinglePatient(call)
    local callId  = call.id
    local basePos = getRoadPositionAround(call.coords)
    local heading = call.coords.heading or 0.0
    local netId   = spawnPatientPed(callId, basePos, heading, true)
    return netId
end

-- MVC with 1–N vehicles and 1–M peds
local function spawnMVCScene(call, vehMin, vehMax, pedMin, pedMax)
    local callId = call.id
    local center = getRoadPositionAround(call.coords)

    -- heading along the road (and optionally refine center)
    local ok, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(
        center.x, center.y, center.z, false, 3.0, 0
    )

    local heading = call.coords.heading or 0.0
    if ok then
        if nodePos then center = nodePos end
        if nodeHeading then heading = nodeHeading end
    end

    -- vehicles
    local vehCount = math.random(vehMin, vehMax)
    local vehs     = {}

    for i = 1, vehCount do
        local fwdOffset = (i - ((vehCount + 1) / 2)) * 6.0  -- 6m between cars
        local vehPos    = offsetFromHeading(center, heading, fwdOffset, 0.0)
        local veh       = spawnMVCVehicle(callId, vehPos, heading)
        if veh then
            table.insert(vehs, veh)
        end
    end

    -- peds (1–4) around the vehicles
    local pedCount     = math.random(pedMin, pedMax)
    local primaryNetId = nil

    for i = 1, pedCount do
        local basePos = center
        if #vehs > 0 then
            basePos = GetEntityCoords(vehs[((i - 1) % #vehs) + 1])
        end

        local fwd  = math.random(-3, 3)
        local side = math.random(-3, 3)
        local pPos = offsetFromHeading(basePos, heading, fwd, side)

        local isPrimary = (i == 1)
        local netId, _  = spawnPatientPed(callId, pPos, heading, isPrimary)
        if isPrimary then
            primaryNetId = netId
        end
    end

    return primaryNetId
end

---------------------------------------------------------------------
-- public API
---------------------------------------------------------------------

-- decide what to spawn for this call.type and return the "main" patient netId
function AC.SpawnForCallType(call)
    if not call or not call.coords or not call.id then return nil end

    local t = (call.type or 'UNKNOWN'):upper()

    if t == 'DRUNK' then
        return spawnSimpleSinglePatient(call)

    elseif t == 'MVA_MINOR' then
        -- 1–2 cars, 1–3 peds
        return spawnMVCScene(call, 1, 2, 1, 3)

    elseif t == 'MVA_MAJOR' then
        -- 2–3 cars, 2–4 peds
        return spawnMVCScene(call, 2, 3, 2, 4)

    elseif t == 'CARDIAC' then
        return spawnSimpleSinglePatient(call)

    else
        -- fallback: simple single patient
        return spawnSimpleSinglePatient(call)
    end
end


