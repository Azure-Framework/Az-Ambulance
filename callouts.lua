


AzCallouts = AzCallouts or {}
local AC = AzCallouts

AC.Scenes = AC.Scenes or {} 





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

local function offsetFromHeading(origin, headingDeg, forwardDist, sideDist)
    local h  = math.rad(headingDeg)
    local fx = math.sin(h)
    local fy = math.cos(h)
    local sx = -fy
    local sy = fx 

    local x = origin.x + fx * forwardDist + sx * sideDist
    local y = origin.y + fy * forwardDist + sy * sideDist
    return vector3(x, y, origin.z)
end

local resolveSceneCoord
local isReasonableZ
local isWaterPoint

local function getRoadPositionAround(coords)
    local pos, heading = resolveSceneCoord(coords, coords.heading or 0.0, true)
    local fwd  = math.random(0, 6)
    local side = math.random(-2, 2)
    local shifted = offsetFromHeading(pos, heading, fwd, side)
    local finalPos = resolveSceneCoord(shifted, heading, false)
    return finalPos
end


local function getPavementPositionAround(coords)
    local heading = coords.heading or 0.0
    local candidates = {
        { fwd = 0.0, side = 0.0 },
        { fwd = 1.0, side = 0.0 },
        { fwd = -1.0, side = 0.0 },
        { fwd = 0.0, side = 1.0 },
        { fwd = 0.0, side = -1.0 },
        { fwd = 1.5, side = 1.0 },
        { fwd = 1.5, side = -1.0 },
        { fwd = -1.5, side = 1.0 },
        { fwd = -1.5, side = -1.0 },
        { fwd = 2.0, side = 0.0 },
        { fwd = 0.0, side = 2.0 },
        { fwd = 0.0, side = -2.0 },
    }

    for _, entry in ipairs(candidates) do
        local shifted = offsetFromHeading(coords, heading, entry.fwd, entry.side)
        local resolvedPos, resolvedHeading = resolveSceneCoord(shifted, heading, false)
        local x, y, z = resolvedPos.x + 0.0, resolvedPos.y + 0.0, resolvedPos.z + 0.0

        if isReasonableZ(z, coords.z, 3.0, 5.0) and not isWaterPoint(x, y, z + 1.0) and not IsPointOnRoad(x + 0.0, y + 0.0, z + 0.0, 0) then
            return resolvedPos, resolvedHeading
        end
    end

    return resolveSceneCoord(coords, heading, false)
end

local function chooseRandom(list, defaultVal)
    if not list or #list == 0 then return defaultVal end
    return list[math.random(1, #list)]
end

local function getGroundZSafe(x, y, refZ)
    local probes = { (refZ or 0.0) + 25.0, (refZ or 0.0) + 75.0, (refZ or 0.0) + 150.0, 1000.0 }
    local bestZ = nil
    for _, probeZ in ipairs(probes) do
        if GetGroundZExcludingObjectsFor_3dCoord then
            local foundEx, gzEx = GetGroundZExcludingObjectsFor_3dCoord(x + 0.0, y + 0.0, probeZ + 0.0, false)
            if foundEx and (not bestZ or gzEx > bestZ) then
                bestZ = gzEx
            end
        end

        local found, gz = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probeZ + 0.0, false)
        if found and (not bestZ or gz > bestZ) then
            bestZ = gz
        end
    end

    if bestZ then
        return true, bestZ + 0.02
    end

    return false, refZ or 0.0
end

isReasonableZ = function(candidateZ, seedZ, maxDrop, maxRise)
    candidateZ = (candidateZ or 0.0) + 0.0
    seedZ = (seedZ or 0.0) + 0.0
    maxDrop = maxDrop or 4.0
    maxRise = maxRise or 6.0
    return candidateZ >= (seedZ - maxDrop) and candidateZ <= (seedZ + maxRise)
end

isWaterPoint = function(x, y, z)
    local ok, waterZ = GetWaterHeightNoWaves(x + 0.0, y + 0.0, z + 0.0)
    if ok and waterZ and math.abs((waterZ + 0.0) - (z + 0.0)) < 4.0 then
        return true
    end

    ok, waterZ = GetWaterHeightNoWaves(x + 0.0, y + 0.0, z + 6.0)
    return ok and waterZ and true or false
end

local function waitForCollisionAt(x, y, z)
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    for _ = 1, 25 do
        Wait(0)
        RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 0.0)
    end
end

local function tryGetSafePedCoord(x, y, z)
    local ok, found, safePos = pcall(GetSafeCoordForPed, x + 0.0, y + 0.0, z + 2.0, true, 16)
    if ok and found and safePos then
        if type(safePos) == 'vector3' then
            return safePos
        elseif type(safePos) == 'table' and safePos.x and safePos.y and safePos.z then
            return vector3(safePos.x + 0.0, safePos.y + 0.0, safePos.z + 0.0)
        end
    end
    return nil
end

resolveSceneCoord = function(coords, heading, requireRoad)
    local x, y, z = coords.x + 0.0, coords.y + 0.0, coords.z + 0.0
    local h = heading or coords.heading or 0.0

    waitForCollisionAt(x, y, z + 50.0)

    if requireRoad then
        local ok, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(x, y, z, false, 3.0, 0)
        if ok and nodePos and isReasonableZ(nodePos.z, coords.z, 4.0, 6.0) then
            x, y, z = nodePos.x + 0.0, nodePos.y + 0.0, nodePos.z + 0.0
            if nodeHeading then h = nodeHeading + 0.0 end
        end
    end

    local safePos = tryGetSafePedCoord(x, y, z)
    if safePos and isReasonableZ(safePos.z, coords.z, 4.0, 6.0) then
        x, y, z = safePos.x + 0.0, safePos.y + 0.0, safePos.z + 0.0
    end

    local foundGround, gz = getGroundZSafe(x, y, z)
    if foundGround then
        z = gz
    end

    if isWaterPoint(x, y, z) then
        local foundFallback, fgz = getGroundZSafe(coords.x + 0.0, coords.y + 0.0, coords.z + 0.0)
        if foundFallback then
            x, y, z = coords.x + 0.0, coords.y + 0.0, fgz
        else
            x, y, z = coords.x + 0.0, coords.y + 0.0, coords.z + 0.0
        end
    end

    return vector3(x, y, z), h
end






local defaultPatientModels = Config and Config.PatientModels or {
    `a_m_m_skidrow_01`,
    `a_m_m_business_01`,
    `a_f_y_business_02`,
    `a_m_y_stbla_02`,
}

local function applyScenarioPatientPose(ped, scenario, x, y, z, heading)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    waitForCollisionAt(x, y, (z or 0.0) + 6.0)

    local foundGround, groundZ = getGroundZSafe(x, y, (z or 0.0) + 2.0)
    local baseZ = (foundGround and groundZ or z or 0.0) + 0.03

    ClearPedTasksImmediately(ped)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)
    SetEntityLoadCollisionFlag(ped, true)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, baseZ, false, false, false)
    SetEntityHeading(ped, heading or 0.0)

    TaskStartScenarioAtPosition(ped, scenario, x + 0.0, y + 0.0, baseZ, heading or 0.0, -1, true, false)
    Wait(600)

    local pedPos = GetEntityCoords(ped)
    if (not foundGround) or pedPos.z < ((groundZ or baseZ) - 0.25) then
        SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, baseZ, false, false, false)
        TaskStartScenarioAtPosition(ped, scenario, x + 0.0, y + 0.0, baseZ, heading or 0.0, -1, true, false)
        Wait(300)
    end

    FreezeEntityPosition(ped, true)
    SetPedKeepTask(ped, true)
end

local function applyGroundPatientPose(ped, x, y, z, heading)
    applyScenarioPatientPose(ped, 'WORLD_HUMAN_SUNBATHE_BACK', x, y, z, heading)
end

local function applyPassedOutPatientPose(ped, x, y, z, heading)
    applyScenarioPatientPose(ped, 'WORLD_HUMAN_SUNBATHE_BACK', x, y, z, heading)
end

local function playPatientDownedAnim(ped, x, y, z, heading, callType)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local normalizedType = tostring(callType or ''):upper()
    if normalizedType == 'DRUNK' then
        applyPassedOutPatientPose(ped, x, y, z, heading)
        return
    end

    local dict = 'combat@damage@rb_writhe'
    RequestAnimDict(dict)
    local started = GetGameTimer()
    while not HasAnimDictLoaded(dict) and GetGameTimer() - started < 2500 do
        Wait(0)
    end

    if HasAnimDictLoaded(dict) then
        TaskPlayAnimAdvanced(ped, dict, 'rb_writhe_loop', x + 0.0, y + 0.0, z + 0.0, 0.0, 0.0, heading or 0.0, 8.0, -8.0, -1, 1, 0.0, 0, 0)
        Wait(200)

        local pedPos = GetEntityCoords(ped)
        local foundGround, groundZ = getGroundZSafe(x, y, z + 2.0)
        if (not foundGround) or pedPos.z < ((groundZ or z) - 0.35) then
            applyGroundPatientPose(ped, x, y, foundGround and groundZ or z, heading)
        else
            FreezeEntityPosition(ped, true)
            SetPedKeepTask(ped, true)
        end
    else
        applyGroundPatientPose(ped, x, y, z, heading)
    end
end

local function spawnPatientPed(callId, coords, heading, isPrimary, callType)
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

    local resolvedPos, resolvedHeading = resolveSceneCoord(coords, heading or 0.0, false)
    local x, y, z = resolvedPos.x + 0.0, resolvedPos.y + 0.0, resolvedPos.z + 0.0
    waitForCollisionAt(x, y, z + 6.0)

    local spawnZ = z + 0.35
    local ped = CreatePed(4, model, x, y, spawnZ, resolvedHeading or heading or 0.0, true, true)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, spawnZ + 0.0, false, false, false)

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
    SetEntityCollision(ped, true, true)
    SetEntityLoadCollisionFlag(ped, true)
    if SetPedCanPlayAmbientAnims then
        SetPedCanPlayAmbientAnims(ped, false)
    end
    if SetPedCanPlayAmbientBaseAnims then
        SetPedCanPlayAmbientBaseAnims(ped, false)
    end

    playPatientDownedAnim(ped, x, y, z, resolvedHeading or heading or 0.0, callType)

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

    local resolvedPos, resolvedHeading = resolveSceneCoord(coords, heading or 0.0, true)
    local x, y, z = resolvedPos.x + 0.0, resolvedPos.y + 0.0, resolvedPos.z + 0.0

    local veh = CreateVehicle(model, x, y, z, resolvedHeading or heading or 0.0, true, true)
    SetEntityCoordsNoOffset(veh, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetVehicleOnGroundProperly(veh)
    SetVehicleEngineOn(veh, false, true, false)
    SetVehicleDoorsLocked(veh, 1)

    addSceneEntity(callId, 'vehicles', veh)
    return veh
end





local function spawnSimpleSinglePatient(call)
    local callId  = call.id
    local heading = call.coords.heading or 0.0
    local basePos = nil

    if (call.type or ''):upper() == 'DRUNK' then
        basePos, heading = getPavementPositionAround(call.coords)
    else
        basePos = getRoadPositionAround(call.coords)
    end

    local netId   = spawnPatientPed(callId, basePos, heading, true, call.type)
    return netId
end

local function spawnMVCScene(call, vehMin, vehMax, pedMin, pedMax)
    local callId = call.id
    local center = getRoadPositionAround(call.coords)

    local ok, nodePos, nodeHeading = GetClosestVehicleNodeWithHeading(
        center.x, center.y, center.z, false, 3.0, 0
    )

    local heading = call.coords.heading or 0.0
    if ok then
        if nodePos then center = nodePos end
        if nodeHeading then heading = nodeHeading end
    end

    local vehCount = math.random(vehMin, vehMax)
    local vehs     = {}

    for i = 1, vehCount do
        local fwdOffset = (i - ((vehCount + 1) / 2)) * 6.0
        local vehPos    = offsetFromHeading(center, heading, fwdOffset, 0.0)
        local veh       = spawnMVCVehicle(callId, vehPos, heading)
        if veh then
            table.insert(vehs, veh)
        end
    end

    local pedCount     = math.random(pedMin, pedMax)
    local primaryNetId = nil

    for i = 1, pedCount do
        local basePos = center
        if #vehs > 0 then
            basePos = GetEntityCoords(vehs[((i - 1) % #vehs) + 1])
        end

        local fwd  = math.random(-3, 3)
        local side = math.random(-3, 3)
        local roughPos = offsetFromHeading(basePos, heading, fwd, side)
        local pPos = resolveSceneCoord(roughPos, heading, false)

        local isPrimary = (i == 1)
        local netId, _  = spawnPatientPed(callId, pPos, heading, isPrimary, call.type)
        if isPrimary then
            primaryNetId = netId
        end
    end

    return primaryNetId
end





function AC.SpawnForCallType(call)
    if not call or not call.coords or not call.id then return nil end

    local t = (call.type or 'UNKNOWN'):upper()

    if t == 'DRUNK' then
        return spawnSimpleSinglePatient(call)

    elseif t == 'MVA_MINOR' then
        return spawnMVCScene(call, 1, 2, 1, 3)

    elseif t == 'MVA_MAJOR' then
        return spawnMVCScene(call, 2, 3, 2, 4)

    elseif t == 'CARDIAC' then
        return spawnSimpleSinglePatient(call)

    else
        return spawnSimpleSinglePatient(call)
    end
end
