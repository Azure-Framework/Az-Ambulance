local currentCall      = nil
local callBlip         = nil
local hospitalBlip     = nil
local isEMSOnDuty      = false
local status           = 'AVAILABLE'

local nearbyPatient    = nil
local lastPatientCheck = 0
local pendingCallId    = nil

local stretchers = {}

local activeHospital   = nil

local isEMSAllowed   = false
local emsActionsOpen = false

local EMS_DEBUG = true

local sceneNotified = false

local function cdebug(...)
    if not EMS_DEBUG then return end
    print(('[Az-Ambulance][C] %s'):format(table.concat({...}, ' ')))
end

CreateThread(function()
    Wait(2000)
    cdebug('Requesting EMS job allowed state from server...')
    TriggerServerEvent('az_ambulance:requestJobAllowed')
end)

RegisterNetEvent('az_ambulance:setJobAllowed', function(allowed)
    isEMSAllowed = allowed and true or false
    cdebug('event setJobAllowed allowed='..tostring(isEMSAllowed))

    if not isEMSAllowed then
        isEMSOnDuty    = false
        pendingCallId  = nil
        nearbyPatient  = nil
        currentCall    = nil
        activeHospital = nil
        status         = 'AVAILABLE'
        emsActionsOpen = false
        sceneNotified  = false

        for netId, st in pairs(stretchers) do
            if st and st.bed and DoesEntityExist(st.bed) then
                DeleteEntity(st.bed)
            end
            stretchers[netId] = nil
        end

        SetNuiFocus(false, false)
        SendNUIMessage({ action = 'hud_hide' })
        SendNUIMessage({ action = 'call_popup_hide' })
        SendNUIMessage({ action = 'ems_actions_close' })
        SendNUIMessage({ action = 'assessment_close' })

        if callBlip and DoesBlipExist(callBlip) then RemoveBlip(callBlip) end
        callBlip = nil
        if hospitalBlip and DoesBlipExist(hospitalBlip) then RemoveBlip(hospitalBlip) end
        hospitalBlip = nil

        cdebug('EMS job not allowed on client -> all features disabled')
    else
        cdebug('EMS job allowed on client -> EMS features enabled (still need /ems_duty)')
    end
end)

local function ui(msg)
    SendNUIMessage(msg)
end

local function notify(text, kind, durationMs)
    cdebug('notify kind='..tostring(kind)..' text='..tostring(text)..' dur='..tostring(durationMs))
    ui({
        action   = 'notify',
        text     = text or '',
        kind     = kind or 'info',
        duration = durationMs or 4000
    })
end

RegisterNetEvent('az_ambulance:notify', function(data)
    if not isEMSAllowed then return end

    if type(data) == 'string' then
        notify(data, 'info')
    elseif type(data) == 'table' then
        notify(data.text or '', data.kind or 'info', data.duration)
    end
end)

local function isPlayerEMS()
    return isEMSAllowed and isEMSOnDuty
end

local function clearHospitalBlip()
    if hospitalBlip and DoesBlipExist(hospitalBlip) then
        RemoveBlip(hospitalBlip)
    end
    hospitalBlip   = nil
    activeHospital = nil
end

local function clearCallBlip()
    if callBlip and DoesBlipExist(callBlip) then
        RemoveBlip(callBlip)
    end
    callBlip = nil
end

local function clearStretcherFor(patientNetId)
    local st = stretchers[patientNetId]
    if not st then return end

    if st.bed and DoesEntityExist(st.bed) then
        DeleteEntity(st.bed)
    end

    stretchers[patientNetId] = nil
end

local function clearAllStretchers()
    for netId, st in pairs(stretchers) do
        if st and st.bed and DoesEntityExist(st.bed) then
            DeleteEntity(st.bed)
        end
        stretchers[netId] = nil
    end
end

local function updateHUD()
    cdebug('updateHUD isEMSAllowed='..tostring(isEMSAllowed)..' isEMSOnDuty='..tostring(isEMSOnDuty))
    if not isEMSAllowed or not isEMSOnDuty then
        ui({ action = 'hud_hide' })
        return
    end

    local callInfo
    if currentCall then
        callInfo = {
            id      = currentCall.id,
            type    = currentCall.type or 'UNKNOWN',
            status  = status,
            address = currentCall.address or '',
            details = currentCall.details or ''
        }
    end

    ui({
        action   = 'hud_update',
        onDuty   = isEMSOnDuty,
        status   = status,
        unit     = GetPlayerServerId(PlayerId()),
        callInfo = callInfo
    })
end

local function setEMSOnDuty(value)
    isEMSOnDuty = (value and true or false) and isEMSAllowed
    cdebug('setEMSOnDuty -> '..tostring(isEMSOnDuty))

    if (not isEMSAllowed) or (not isEMSOnDuty) then
        pendingCallId  = nil
        nearbyPatient  = nil
        currentCall    = nil
        clearAllStretchers()
        clearCallBlip()
        clearHospitalBlip()
        status = 'AVAILABLE'
        sceneNotified = false
    end
    updateHUD()
end

local function getCurrentPatientPed()
    if nearbyPatient and DoesEntityExist(nearbyPatient) then
        return nearbyPatient
    end

    if currentCall and currentCall.patientNetId then
        local p = NetToPed(currentCall.patientNetId)
        if p ~= 0 and DoesEntityExist(p) then
            return p
        end
    end

    return nil
end

local function getCurrentPatientNetId()
    local ped = getCurrentPatientPed()
    if ped and DoesEntityExist(ped) then
        local netId = PedToNet(ped)
        if netId and netId ~= 0 then
            return netId
        end
    end
    return (currentCall and currentCall.patientNetId) or 0
end

local function getTargetPatientPed()
    return getCurrentPatientPed()
end

local function getPatientKeyFromPed(ped)
    if not ped or not DoesEntityExist(ped) then return nil end
    local netId = PedToNet(ped)
    if not netId or netId == 0 then return nil end
    return netId
end

local function getStretcherState(patientNetId)
    if not patientNetId or patientNetId == 0 then return nil end
    stretchers[patientNetId] = stretchers[patientNetId] or { bed = nil, patient = nil, onBed = false }
    return stretchers[patientNetId]
end

local function getStretcherIfClose(patientNetId, maxDist)
    local st = stretchers[patientNetId]
    if st and st.bed and DoesEntityExist(st.bed) then
        local ped   = PlayerPedId()
        local myPos = GetEntityCoords(ped)
        local sPos  = GetEntityCoords(st.bed)
        local dist  = #(myPos - sPos)
        if dist <= (maxDist or 5.0) then
            return st.bed, dist
        end
    end
    return nil
end

local function getClosestLoadedStretcher(maxDist)
    maxDist = maxDist or 6.0
    local ped   = PlayerPedId()
    local myPos = GetEntityCoords(ped)

    local bestNet, bestSt, bestDist
    for netId, st in pairs(stretchers) do
        if st and st.bed and DoesEntityExist(st.bed) and st.onBed then
            local sPos = GetEntityCoords(st.bed)
            local d = #(myPos - sPos)
            if d <= maxDist and (not bestDist or d < bestDist) then
                bestNet, bestSt, bestDist = netId, st, d
            end
        end
    end
    return bestNet, bestSt, bestDist
end

local function isCardiacCall()
    return currentCall and (currentCall.type or ''):upper() == 'CARDIAC'
end

local function cardiacCPROk()
    if not isCardiacCall() then return true end
    return currentCall and currentCall.cprOk == true
end

RegisterNetEvent('az_ambulance:updateCPRState', function(callId, ok, quality)
    if not isEMSAllowed then return end
    cdebug(('event updateCPRState callId=%s ok=%s quality=%s'):format(
        tostring(callId), tostring(ok), tostring(quality))
    )
    if currentCall and currentCall.id == callId then
        currentCall.cprOk      = ok and true or false
        currentCall.cprQuality = quality or 0
    end
end)

RegisterNetEvent('az_ambulance:setDuty', function(onDuty)
    if not isEMSAllowed then
        cdebug('event setDuty ignored: EMS job not allowed')
        return
    end
    cdebug('event setDuty onDuty='..tostring(onDuty))
    setEMSOnDuty(onDuty)
    if onDuty then
        notify('You are now on duty as EMS.', 'success')
    else
        notify('You are now off duty.', 'info')
        ui({ action = 'call_popup_hide' })
        ui({ action = 'ems_actions_close' })
    end
end)

RegisterCommand('ems_duty_key', function()
    if not isEMSAllowed then return end
    cdebug('command ems_duty_key -> TriggerServerEvent az_ambulance:toggleDuty')
    TriggerServerEvent('az_ambulance:toggleDuty')
end, false)
RegisterKeyMapping('ems_duty_key', 'EMS: Toggle duty', 'keyboard', 'F5')

RegisterCommand('ems_status', function(_, args)
    cdebug('command /ems_status')
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end

    local newStatus = (args[1] or ''):upper()
    if newStatus == '' then
        notify('Usage: /ems_status AVAILABLE|ENROUTE|ONSCENE|TRANSPORT|HOSPITAL', 'info')
        return
    end

    status = newStatus
    updateHUD()
    TriggerServerEvent('az_ambulance:statusUpdate', newStatus)
end, false)

local function buildAddressFromCoords(coords)
    if not coords then return nil end
    local x, y, z = coords.x, coords.y, coords.z
    local streetHash, crossingHash = GetStreetNameAtCoord(x, y, z)
    local street  = GetStreetNameFromHashKey(streetHash)
    local cross   = (crossingHash ~= 0) and GetStreetNameFromHashKey(crossingHash) or nil
    local zone    = GetNameOfZone(x, y, z)
    if cross and cross ~= '' then
        return street .. ' / ' .. cross .. ' (' .. zone .. ')'
    else
        return street .. ' (' .. zone .. ')'
    end
end

RegisterNetEvent('az_ambulance:newCallout', function(call)
    if not isEMSAllowed then
        cdebug('event newCallout ignored: EMS job not allowed')
        return
    end

    cdebug('event newCallout id='..tostring(call and call.id))

    if currentCall then
        cdebug(('newCallout %s ignored; already on call %s')
            :format(tostring(call and call.id), tostring(currentCall.id)))
        return
    end

    if not isPlayerEMS() then
        cdebug('newCallout ignored, not on duty')
        return
    end

    if (not call.address or call.address == 'Unknown address') and call.coords then
        call.address = buildAddressFromCoords(call.coords)
    end

    notify(('[CALL %s] %s'):format(call.id, call.title or 'Medical call'), 'warning')
    pendingCallId = call.id

    ui({ action = 'call_popup', call = call })
end)

local function spawnInitialPatientForCall(call)
    if not call or not call.coords then return end
    if call.noScene then
        cdebug(('Call %s is marked noScene; skipping automatic patient spawn.'):format(tostring(call.id)))
        return
    end

    if AzCallouts and AzCallouts.SpawnForCallType then
        local netId = AzCallouts.SpawnForCallType(call)
        if netId and netId ~= 0 then
            currentCall.patientNetId = netId
            TriggerServerEvent('az_ambulance:registerPatientNet', currentCall.id, netId)
            return
        end
    end

    local model = `a_m_m_business_01`
    RequestModel(model)
    local start = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - start < 5000 do Wait(0) end
    if not HasModelLoaded(model) then
        cdebug('Failed to load patient model')
        return
    end

    local x, y, z = call.coords.x, call.coords.y, call.coords.z
    local found, groundZ = GetGroundZFor_3dCoord(x, y, z + 10.0, false)
    if found then z = groundZ end

    local ped = CreatePed(4, model, x, y, z, call.coords.heading or 0.0, true, true)

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityInvincible(ped, true)
    FreezeEntityPosition(ped, true)

    local dict = 'combat@damage@rb_writhe'
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do Wait(0) end
    TaskPlayAnim(ped, dict, 'rb_writhe_loop', 8.0, -8.0, -1, 1, 0.0, false, false, false)

    local netId = PedToNet(ped)
    SetNetworkIdCanMigrate(netId, true)

    currentCall.patientNetId = netId
    TriggerServerEvent('az_ambulance:registerPatientNet', currentCall.id, netId)
end

RegisterNetEvent('az_ambulance:callAccepted', function(call)
    if not isEMSAllowed then return end

    cdebug('event callAccepted id='..tostring(call and call.id)..' assigned='..tostring(call and call.assigned))
    notify(('[CALL %s] Assigned to %s'):format(call.id, call.assignedLabel or 'unit'), 'info')

    local myId = GetPlayerServerId(PlayerId())
    if call.assigned ~= myId then return end
    if not isPlayerEMS() then return end

    pendingCallId = nil
    ui({ action = 'call_popup_hide' })

    currentCall = call
    status      = 'ENROUTE'
    sceneNotified = false

    if (not currentCall.address or currentCall.address == 'Unknown address') and currentCall.coords then
        currentCall.address = buildAddressFromCoords(currentCall.coords)
    end

    clearCallBlip()
    clearHospitalBlip()

    callBlip = AddBlipForCoord(call.coords.x, call.coords.y, call.coords.z)
    SetBlipSprite(callBlip, Config.CallBlipSprite or 153)
    SetBlipColour(callBlip, Config.CallBlipColour or 1)
    SetBlipScale(callBlip, Config.CallBlipScale or 1.0)
    SetBlipRoute(callBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString('EMS Call '..call.id)
    EndTextCommandSetBlipName(callBlip)

    updateHUD()

    if not currentCall.patientNetId or currentCall.patientNetId == 0 then
        cdebug('Spawning patient for call '..tostring(call.id))
        spawnInitialPatientForCall(call)
    end
end)

RegisterNetEvent('az_ambulance:updateCallPatient', function(callId, netId)
    if not isEMSAllowed then return end
    cdebug('event updateCallPatient callId='..tostring(callId)..' netId='..tostring(netId))
    if currentCall and currentCall.id == callId then
        currentCall.patientNetId = netId
    end
end)

RegisterNetEvent('az_ambulance:callCleared', function(id, reason)
    if not isEMSAllowed then return end
    cdebug('event callCleared id='..tostring(id)..' reason='..tostring(reason))

    if currentCall and currentCall.id == id then
        if AzCallouts and AzCallouts.CleanupScene then
            AzCallouts.CleanupScene(currentCall.id)
        end
        currentCall = nil
    end

    status        = 'AVAILABLE'
    clearCallBlip()
    clearHospitalBlip()
    nearbyPatient = nil
    pendingCallId = nil
    clearAllStretchers()
    sceneNotified = false

    ui({ action = 'call_popup_hide' })
    notify('Call cleared: '..(reason or 'completed'), 'success')
    updateHUD()
end)

RegisterNUICallback('accept_call', function(data, cb)
    if not isEMSAllowed then cb({}) return end
    if not data or not data.id then cb({}) return end
    pendingCallId = nil
    SetNuiFocus(false, false)
    ui({ action = 'call_popup_hide' })
    TriggerServerEvent('az_ambulance:acceptCallout', data.id)
    cb({})
end)

RegisterNUICallback('deny_call', function(data, cb)
    if not isEMSAllowed then cb({}) return end
    if not data or not data.id then cb({}) return end

    local id = data.id
    pendingCallId = nil
    SetNuiFocus(false, false)
    ui({ action = 'call_popup_hide' })
    TriggerServerEvent('az_ambulance:denyCallout', id)
    cb({})
end)

RegisterNUICallback('dismiss_call', function(_, cb)
    if not isEMSAllowed then cb({}) return end
    pendingCallId = nil
    SetNuiFocus(false, false)
    ui({ action = 'call_popup_hide' })
    cb({})
end)

CreateThread(function()
    while true do
        if not isEMSAllowed then
            Wait(1000)
        elseif pendingCallId then
            if IsControlJustPressed(0, 38) then
                cdebug('E pressed for pending call '..tostring(pendingCallId))
                TriggerServerEvent('az_ambulance:acceptCallout', pendingCallId)
                ui({ action = 'call_popup_hide' })
                pendingCallId = nil
            elseif IsControlJustPressed(0, 73) then
                cdebug('X pressed to ignore pending call '..tostring(pendingCallId))
                TriggerServerEvent('az_ambulance:denyCallout', pendingCallId)
                ui({ action = 'call_popup_hide' })
                pendingCallId = nil
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

local function refreshNearbyPatient()
    nearbyPatient = nil
    if not currentCall then return end

    local ped     = PlayerPedId()
    local myPos   = GetEntityCoords(ped)
    local maxDist = Config.InteractDistance or 3.0

    local bestPed, bestDist

    if AzCallouts and AzCallouts.GetScenePeds and currentCall.id then
        local scenePeds = AzCallouts.GetScenePeds(currentCall.id)
        for _, p in ipairs(scenePeds) do
            if p and DoesEntityExist(p) then
                local pPos = GetEntityCoords(p)
                local d = #(myPos - pPos)
                if d <= maxDist and (not bestDist or d < bestDist) then
                    bestPed, bestDist = p, d
                end
            end
        end
    end

    if not bestPed and currentCall.patientNetId then
        local p = NetToPed(currentCall.patientNetId)
        if p ~= 0 and DoesEntityExist(p) then
            local pPos = GetEntityCoords(p)
            local d = #(myPos - pPos)
            if d <= maxDist then
                bestPed = p
            end
        end
    end

    nearbyPatient = bestPed

    if bestPed and currentCall and not sceneNotified then
        sceneNotified = true
        TriggerServerEvent('az_ambulance:onScene', currentCall.id)
    end
end

CreateThread(function()
    while true do
        if isEMSAllowed and currentCall then
            local now = GetGameTimer()
            if now - lastPatientCheck > 1000 then
                lastPatientCheck = now
                refreshNearbyPatient()
            end
            Wait(250)
        else
            nearbyPatient = nil
            Wait(1000)
        end
    end
end)

local cprActive = false

local function stopCPRAnim()
    ClearPedTasks(PlayerPedId())
end

local function startCPR()
    cdebug('startCPR nearbyPatient='..tostring(nearbyPatient))
    if not nearbyPatient then
        notify('No patient close enough for CPR.', 'error')
        return
    end

    cprActive = true
    TaskStartScenarioInPlace(PlayerPedId(), 'CODE_HUMAN_MEDIC_TEND_TO_DEAD', 0, true)

    SetNuiFocus(true, true)
    ui({
        action    = 'cpr_start',
        duration  = Config.CPRDurationSeconds or 30,
        goodMinMs = Config.CPRGoodMinMs or 450,
        goodMaxMs = Config.CPRGoodMaxMs or 600
    })
end

RegisterCommand('ems_cpr', function()
    if not isPlayerEMS() then return end
    if not currentCall then
        notify('No active call.', 'error')
        return
    end
    startCPR()
end, false)

RegisterKeyMapping('ems_cpr', 'EMS: Start CPR mini-game', 'keyboard', (Config.Keys and Config.Keys.StartCPR) or 'F7')

RegisterNUICallback('cpr_finish', function(data, cb)
    if not isEMSAllowed then cb({}) return end

    cprActive = false
    SetNuiFocus(false, false)
    stopCPRAnim()

    local good  = data and data.good or 0
    local total = data and data.total or 0
    local quality = 0
    if total > 0 then quality = math.floor((good / total) * 100) end

    TriggerServerEvent('az_ambulance:cprResult',
        currentCall and currentCall.id or 0,
        getCurrentPatientNetId(),
        quality
    )

    notify(('CPR complete. Good compressions: %s%%'):format(quality), 'info')
    cb({})
end)

RegisterNUICallback('cpr_cancel', function(_, cb)
    if not isEMSAllowed then cb({}) return end
    cprActive = false
    SetNuiFocus(false, false)
    stopCPRAnim()
    cb({})
end)

RegisterCommand('ems_assess', function()
    if not isPlayerEMS() then return end
    if not nearbyPatient then
        notify('No patient nearby for assessment.', 'error')
        return
    end

    TriggerServerEvent('az_ambulance:requestVitals',
        currentCall and currentCall.id or 0,
        getCurrentPatientNetId()
    )
end, false)

RegisterKeyMapping('ems_assess', 'EMS: Patient assessment', 'keyboard', (Config.Keys and Config.Keys.Assessment) or 'F8')

RegisterNetEvent('az_ambulance:vitalsData', function(vitals)
    if not isEMSAllowed then return end
    if not vitals then
        notify('No vitals available.', 'error')
        return
    end

    ui({ action = 'assessment_open', vitals = vitals })
    SetNuiFocus(true, true)

    notify('Assessment done. Spawn a stretcher for each patient with /ems_stretcher then load with /ems_loadpatient.', 'info', 15000)
    notify('When ready to transport, move the loaded stretcher to your ambulance and use /ems_load.', 'info', 15000)
end)

RegisterNUICallback('assessment_close', function(_, cb)
    SetNuiFocus(false, false)
    ui({ action = 'assessment_close' })
    cb({})
end)

local stretcherModels = {
    -213759178,
}

local function loadFirstAvailableModel(list, timeoutMs)
    timeoutMs = timeoutMs or 8000
    for _, model in ipairs(list) do
        if model and model ~= 0 then
            cdebug('Trying stretcher model '..tostring(model))
            RequestModel(model)
            local start = GetGameTimer()
            while not HasModelLoaded(model) and (GetGameTimer() - start) < timeoutMs do
                Wait(0)
            end
            if HasModelLoaded(model) then
                cdebug('Loaded stretcher model '..tostring(model))
                return model
            end
        end
    end
    return nil
end

RegisterCommand('ems_stretcher', function()
    cdebug('command /ems_stretcher')
    if not isPlayerEMS() then return end
    if not currentCall then
        notify('You need an active call to deploy a stretcher.', 'error')
        return
    end

    local patient = getTargetPatientPed()
    if not patient then
        notify('No patient found for stretcher assignment.', 'error')
        return
    end

    local patientNetId = getPatientKeyFromPed(patient)
    if not patientNetId then
        notify('Patient is not networked yet.', 'error')
        return
    end

    local st = getStretcherState(patientNetId)
    if st.bed and DoesEntityExist(st.bed) then
        notify('A stretcher is already deployed for this patient.', 'info')
        return
    end

    local model = loadFirstAvailableModel(stretcherModels, 8000)
    if not model then
        notify('Could not load stretcher / hospital bed model on this build.', 'error', 8000)
        return
    end

    local ped = PlayerPedId()
    local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 1.8, 0.0)

    st.bed = CreateObject(model, pos.x, pos.y, pos.z, true, true, false)
    SetEntityHeading(st.bed, GetEntityHeading(ped))
    PlaceObjectOnGroundProperly(st.bed)

    st.patient = nil
    st.onBed   = false

    notify(('Stretcher deployed for patient [%s]. Use /ems_loadpatient.'):format(patientNetId), 'info', 12000)
end, false)

RegisterCommand('ems_loadpatient', function()
    cdebug('command /ems_loadpatient')
    if not isPlayerEMS() then return end
    if not currentCall then
        notify('No active patient to load.', 'error')
        return
    end

    if isCardiacCall() and not cardiacCPROk() then
        notify('Patient is in cardiac arrest. Perform effective CPR before loading them on the stretcher.', 'error', 8000)
        return
    end

    local patient = getTargetPatientPed()
    if not patient or not DoesEntityExist(patient) then
        notify('Patient entity not available.', 'error')
        return
    end

    local patientNetId = getPatientKeyFromPed(patient)
    if not patientNetId then
        notify('Patient is not networked yet.', 'error')
        return
    end

    local ped   = PlayerPedId()
    local myPos = GetEntityCoords(ped)
    local pPos  = GetEntityCoords(patient)
    local pDist = #(myPos - pPos)

    if pDist > 5.0 then
        notify('Move closer to the patient to load them.', 'error', 7000)
        return
    end

    local stretcher = getStretcherIfClose(patientNetId, 5.0)
    if not stretcher then
        notify('No stretcher close for this patient. Use /ems_stretcher.', 'error', 7000)
        return
    end

    local st = getStretcherState(patientNetId)
    local sPos = GetEntityCoords(stretcher)

    FreezeEntityPosition(patient, false)
    ClearPedTasksImmediately(patient)
    SetEntityCoords(patient, sPos.x, sPos.y, sPos.z + 0.9, false, false, false, true)

    local dict = 'combat@damage@rb_writhe'
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do Wait(0) end

    AttachEntityToEntity(
        patient, stretcher, 0,
        0.0, 0.0, 0.9,
        0.0, 0.0, 180.0,
        false, false, false, false, 2, true
    )

    TaskPlayAnim(patient, dict, 'rb_writhe_loop', 8.0, -8.0, -1, 1, 0.0, false, false, false)

    st.patient = patient
    st.onBed   = true

    TriggerServerEvent('az_ambulance:patientLoaded', currentCall.id, patientNetId)

    notify('Patient loaded on stretcher. Move it near your ambulance then use /ems_load.', 'success', 15000)
end, false)

local function getClosestAmbulance(maxDist)
    maxDist = maxDist or 12.0
    local ped     = PlayerPedId()
    local pCoords = GetEntityCoords(ped)

    local handle, veh = FindFirstVehicle()
    local success
    local closest, closestDist

    repeat
        if DoesEntityExist(veh) then
            local vCoords = GetEntityCoords(veh)
            local dist    = #(pCoords - vCoords)
            if dist < maxDist then
                if not closest or dist < closestDist then
                    closest, closestDist = veh, dist
                end
            end
        end
        success, veh = FindNextVehicle(handle)
    until not success
    EndFindVehicle(handle)

    return closest, closestDist or 9999.0
end

local function getNearestHospitalFromCoords(coords)
    local list = Config.Hospitals or {}
    if not coords or #list == 0 then return nil end

    local best, bestDist
    for _, h in ipairs(list) do
        local hv   = vector3(h.x, h.y, h.z)
        local dist = #(coords - hv)
        if not best or dist < bestDist then
            best, bestDist = h, dist
        end
    end
    return best
end

local function getAmbRearPos(vehicle)
    local candidates = { 'door_dside_r', 'door_pside_r', 'boot' }
    for _, boneName in ipairs(candidates) do
        local idx = GetEntityBoneIndexByName(vehicle, boneName)
        if idx and idx ~= -1 then
            return GetWorldPositionOfEntityBone(vehicle, idx)
        end
    end
    return GetOffsetFromEntityInWorldCoords(vehicle, 0.0, -2.5, 0.0)
end

RegisterCommand('ems', function()
    if not isEMSAllowed then return end

    if not lib or not lib.inputDialog then
        notify('EMS call UI is not available (missing inputDialog).', 'error', 6000)
        return
    end

    local result = lib.inputDialog('Call EMS', {
        {
            type     = 'select',
            label    = 'What is the emergency?',
            required = true,
            options  = {
                { value = 'MVA',     label = 'Motor Vehicle Accident' },
                { value = 'GSW',     label = 'Gunshot Wound (GSW)' },
                { value = 'CARDIAC', label = 'Cardiac Arrest' },
            }
        },
        {
            type     = 'textarea',
            label    = 'Describe what happened',
            required = true,
            min      = 10,
            max      = 250,
        }
    })

    if not result then return end
    TriggerServerEvent('az_ambulance:userEMSCall', result[1], result[2])
end, false)

RegisterCommand('ems_load', function()
    cdebug('command /ems_load')
    if not isPlayerEMS() then return end

    if isCardiacCall() and not cardiacCPROk() then
        notify('Patient is still in cardiac arrest. Achieve ROSC with CPR before transporting.', 'error', 8000)
        return
    end

    local patientNetId, st = getClosestLoadedStretcher(6.0)
    if not patientNetId or not st or not st.bed or not DoesEntityExist(st.bed) then
        notify('No loaded stretcher nearby.', 'error')
        return
    end

    local amb = select(1, getClosestAmbulance(12.0))
    if not amb or amb == 0 then
        notify('No ambulance nearby.', 'error')
        return
    end

    local bedPos   = GetEntityCoords(st.bed)
    local rearPos  = getAmbRearPos(amb)
    local distRear = #(bedPos - rearPos)
    local distBody = #(bedPos - GetEntityCoords(amb))

    local maxRear = Config.LoadMaxRearDist or 6.0
    local maxBody = Config.LoadMaxVehicleDist or 5.5

    cdebug(('[ems_load] distRear=%.2f distBody=%.2f maxRear=%.2f maxBody=%.2f')
        :format(distRear, distBody, maxRear, maxBody))

    if distRear > maxRear and distBody > maxBody then
        notify('Move the stretcher closer to the rear doors of your ambulance.', 'error', 7000)
        return
    end

    local nearestHosp = getNearestHospitalFromCoords(GetEntityCoords(amb))
    if not nearestHosp then
        notify('No hospital locations configured.', 'error')
        return
    end

    clearCallBlip()
    clearHospitalBlip()

    hospitalBlip = AddBlipForCoord(nearestHosp.x, nearestHosp.y, nearestHosp.z)
    SetBlipSprite(hospitalBlip, 61)
    SetBlipColour(hospitalBlip, 2)
    SetBlipScale(hospitalBlip, 1.0)
    SetBlipRoute(hospitalBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(nearestHosp.name or 'Hospital')
    EndTextCommandSetBlipName(hospitalBlip)

    SetNewWaypoint(nearestHosp.x, nearestHosp.y)
    activeHospital = nearestHosp

    TriggerServerEvent('az_ambulance:transportStart', currentCall.id, nearestHosp.name or 'Hospital', nearestHosp.x, nearestHosp.y, nearestHosp.z)

    if st.patient and DoesEntityExist(st.patient) then
        DeleteEntity(st.patient)
    end
    if st.bed and DoesEntityExist(st.bed) then
        DeleteEntity(st.bed)
    end
    stretchers[patientNetId] = nil

    status = 'TRANSPORT'
    updateHUD()
    notify(('Patient loaded. Proceed to %s.'):format(nearestHosp.name or 'hospital'), 'success', 8000)
    TriggerServerEvent('az_ambulance:statusUpdate', status)
end, false)

CreateThread(function()
    while true do
        if isEMSAllowed and isEMSOnDuty and activeHospital and hospitalBlip then
            local ped  = PlayerPedId()
            local pos  = GetEntityCoords(ped)
            local hPos = vector3(activeHospital.x, activeHospital.y, activeHospital.z)
            local dist = #(pos - hPos)
            local arriveDist = Config.HospitalArriveDistance or 18.0

            if dist <= arriveDist then
                cdebug(('Arrived at hospital %s dist=%.2f'):format(activeHospital.name or 'Hospital', dist))
                notify('Patient handed over to hospital staff. Call complete.', 'success', 8000)

                local finishedCallId = currentCall and currentCall.id or nil

                if finishedCallId then
                    cdebug('Triggering completeTransport for callId='..tostring(finishedCallId))
                    TriggerServerEvent('az_ambulance:completeTransport', finishedCallId)
                end

                clearHospitalBlip()
                clearAllStretchers()
                currentCall   = nil
                nearbyPatient = nil
                status        = 'AVAILABLE'
                updateHUD()
                sceneNotified = false

                if finishedCallId and AzCallouts and AzCallouts.CleanupScene then
                    AzCallouts.CleanupScene(finishedCallId)
                end
            end

            Wait(1000)
        else
            Wait(1500)
        end
    end
end)
local function openEMSMenu()
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end
    if emsActionsOpen then return end
    emsActionsOpen = true
    SetNuiFocus(true, true)
    ui({ action = 'ems_actions_open' })
end

local function closeEMSMenu()
    if not emsActionsOpen then return end
    emsActionsOpen = false
    SetNuiFocus(false, false)
    ui({ action = 'ems_actions_close' })
end

RegisterCommand('ems_actions', function()
    if not isEMSAllowed then return end
    if emsActionsOpen then closeEMSMenu() else openEMSMenu() end
end, false)

RegisterCommand('ems_actions_key', function()
    if not isEMSAllowed then return end
    if emsActionsOpen then closeEMSMenu() else openEMSMenu() end
end, false)

RegisterKeyMapping(
    'ems_actions_key',
    'EMS: Open Actions Menu',
    'keyboard',
    (Config.Keys and Config.Keys.ActionsMenu) or 'F6'
)

RegisterNUICallback('ems_action', function(data, cb)
    local cmd = data and data.cmd
    if not isPlayerEMS() then
        closeEMSMenu()
        cb({})
        return
    end

    closeEMSMenu()
    if cmd and cmd ~= '' then
        ExecuteCommand(cmd)
    end
    cb({})
end)

RegisterNUICallback('ems_actions_close', function(_, cb)
    closeEMSMenu()
    cb({})
end)

local function showEMSHelp()
    if not isEMSAllowed then
        notify('You are not allowed to use EMS systems.', 'error')
        return
    end

    notify('EMS HELP — Quick Start', 'info', 9000)
    notify('1) Go on duty: /ems_duty (or press F5). Off duty disables EMS UI/features.', 'info', 12000)
    notify('2) Calls: When a call pops up, accept with the popup OR press E. Deny with X.', 'info', 12000)
    notify('3) Optional status: /ems_status AVAILABLE|ENROUTE|ONSCENE|TRANSPORT|HOSPITAL', 'info', 12000)
    notify('4) On scene: Get near the patient. Use /ems_assess (F8) to view vitals.', 'info', 12000)
    notify('5) CPR: /ems_cpr (F7). For CARDIAC calls you must get good CPR before loading.', 'info', 12000)
    notify('6) Stretcher flow: /ems_stretcher -> /ems_loadpatient -> move to ambulance -> /ems_load', 'info', 12000)
    notify('7) Actions menu: /ems_actions or press '..tostring((Config.Keys and Config.Keys.ActionsMenu) or 'F6')..'.', 'info', 12000)
    notify('Caller command: /ems opens the emergency call dialog (requires ox_lib inputDialog).', 'info', 12000)
end

RegisterCommand('emshelp', function()
    showEMSHelp()
end, false)

RegisterCommand('ems_help', function()
    showEMSHelp()
end, false)


AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    SetNuiFocus(false, false)
end)
