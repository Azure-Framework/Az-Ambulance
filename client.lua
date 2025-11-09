
local currentCall      = nil   -- active call table from server
local callBlip         = nil
local hospitalBlip     = nil
local isEMSOnDuty      = false
local status           = 'AVAILABLE' -- AVAILABLE, ENROUTE, ONSCENE, TRANSPORT, HOSPITAL

local nearbyPatient    = nil
local lastPatientCheck = 0
local pendingCallId    = nil   -- call we have a popup for

-- stretcher / transport
local stretcherEntity     = nil
local stretcherPatientPed = nil
local patientOnStretcher  = false
local activeHospital      = nil -- table from Config.Hospitals for current transport

---------------------------------------------------------------------
-- DEBUG
---------------------------------------------------------------------

local EMS_DEBUG = true

local function cdebug(...)
    if not EMS_DEBUG then return end
    print(('[Az-Ambulance][C] %s'):format(table.concat({...}, ' ')))
end

---------------------------------------------------------------------
-- UTIL / UI
---------------------------------------------------------------------

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

-- networked notify from server
RegisterNetEvent('az_ambulance:notify', function(data)
    if type(data) == 'string' then
        notify(data, 'info')
    elseif type(data) == 'table' then
        notify(data.text or '', data.kind or 'info', data.duration)
    end
end)

local function isPlayerEMS()
    return isEMSOnDuty
end

local function clearStretcher()
    if stretcherEntity and DoesEntityExist(stretcherEntity) then
        DeleteEntity(stretcherEntity)
    end
    stretcherEntity     = nil
    stretcherPatientPed = nil
    patientOnStretcher  = false
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

local function updateHUD()
    cdebug('updateHUD isEMSOnDuty='..tostring(isEMSOnDuty))
    if not isEMSOnDuty then
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
    isEMSOnDuty = value and true or false
    cdebug('setEMSOnDuty -> '..tostring(isEMSOnDuty))
    if not isEMSOnDuty then
        pendingCallId = nil
        nearbyPatient = nil
        currentCall   = nil
        clearStretcher()
        clearCallBlip()
        clearHospitalBlip()
        status = 'AVAILABLE'
    end
    updateHUD()
end

---------------------------------------------------------------------
-- CURRENT PATIENT HELPERS (multi-patient support)
---------------------------------------------------------------------

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

---------------------------------------------------------------------
-- DUTY / STATUS
---------------------------------------------------------------------

local function isCardiacCall()
    return currentCall and (currentCall.type or ''):upper() == 'CARDIAC'
end

local function cardiacCPROk()
    -- default: not OK until server says so
    if not isCardiacCall() then return true end
    return currentCall and currentCall.cprOk == true
end


RegisterNetEvent('az_ambulance:updateCPRState', function(callId, ok, quality)
    cdebug(('event updateCPRState callId=%s ok=%s quality=%s'):format(
        tostring(callId), tostring(ok), tostring(quality))
    )
    if currentCall and currentCall.id == callId then
        currentCall.cprOk      = ok and true or false
        currentCall.cprQuality = quality or 0
    end
end)

RegisterNetEvent('az_ambulance:setDuty', function(onDuty)
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

-- F5 keybind → toggle duty on server
RegisterCommand('ems_duty_key', function()
    cdebug('command ems_duty_key -> TriggerServerEvent az_ambulance:toggleDuty')
    TriggerServerEvent('az_ambulance:toggleDuty')
end, false)
RegisterKeyMapping('ems_duty_key', 'EMS: Toggle duty', 'keyboard', 'F5')

-- /ems_status (client → server)
RegisterCommand('ems_status', function(_, args)
    cdebug('command /ems_status')
    if not isPlayerEMS() then
        notify('You are not EMS.', 'error')
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

---------------------------------------------------------------------
-- CALLOUTS (POPUP / ACCEPT / CLEAR)
---------------------------------------------------------------------

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
    cdebug('event newCallout id='..tostring(call and call.id))

    -- ignore new callouts if we already have an active call
    if currentCall then
        cdebug(
            ('newCallout %s ignored; already on call %s'):format(
                tostring(call and call.id),
                tostring(currentCall.id)
            )
        )
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

    ui({
        action = 'call_popup',
        call   = call
    })
end)

local function spawnInitialPatientForCall(call)
    if not call or not call.coords then return end

    -- /ems (user) calls can mark themselves as noScene so we don't spawn peds/vehicles
    if call.noScene then
        cdebug(('Call %s is marked noScene; skipping automatic patient spawn.'):format(tostring(call.id)))
        return
    end

    -- use callouts.lua if present
    if AzCallouts and AzCallouts.SpawnForCallType then
        local netId = AzCallouts.SpawnForCallType(call)
        if netId and netId ~= 0 then
            currentCall.patientNetId = netId
            TriggerServerEvent('az_ambulance:registerPatientNet', currentCall.id, netId)
            return
        end
    end

    -- fallback: single basic patient (old behaviour)
    local model = `a_m_m_business_01`
    RequestModel(model)
    local start = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - start < 5000 do
        Wait(0)
    end
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
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end
    TaskPlayAnim(ped, dict, 'rb_writhe_loop', 8.0, -8.0, -1, 1, 0.0, false, false, false)

    local netId = PedToNet(ped)
    SetNetworkIdCanMigrate(netId, true)

    currentCall.patientNetId = netId
    TriggerServerEvent('az_ambulance:registerPatientNet', currentCall.id, netId)
end


RegisterNetEvent('az_ambulance:callAccepted', function(call)
    cdebug('event callAccepted id='..tostring(call and call.id)..' assigned='..tostring(call and call.assigned))
    notify(('[CALL %s] Assigned to %s'):format(call.id, call.assignedLabel or 'unit'), 'info')

    local myId = GetPlayerServerId(PlayerId())
    if call.assigned ~= myId then
        cdebug('callAccepted -> not my call')
        return
    end

    pendingCallId = nil
    ui({ action = 'call_popup_hide' })

    currentCall = call
    status      = 'ENROUTE'

    if (not currentCall.address or currentCall.address == 'Unknown address')
       and currentCall.coords then
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
    cdebug('event updateCallPatient callId='..tostring(callId)..' netId='..tostring(netId))
    if currentCall and currentCall.id == callId then
        currentCall.patientNetId = netId
    end
end)

RegisterNetEvent('az_ambulance:callCleared', function(id, reason)
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
    clearStretcher()
    ui({ action = 'call_popup_hide' })
    notify('Call cleared: '..(reason or 'completed'), 'success')
    updateHUD()
end)

-- NUI callbacks (mouse click Accept/Ignore)
RegisterNUICallback('accept_call', function(data, cb)
    cdebug('NUI accept_call id='..tostring(data and data.id))
    if not data or not data.id then cb({}) return end
    pendingCallId = nil
    SetNuiFocus(false, false)
    ui({ action = 'call_popup_hide' })
    TriggerServerEvent('az_ambulance:acceptCallout', data.id)
    cb({})
end)

-- NUI: explicit DENY button
RegisterNUICallback('deny_call', function(data, cb)
    cdebug('NUI deny_call id='..tostring(data and data.id))
    if not data or not data.id then cb({}) return end

    local id = data.id

    pendingCallId = nil
    SetNuiFocus(false, false)
    ui({ action = 'call_popup_hide' })

    -- tell server we denied this call
    TriggerServerEvent('az_ambulance:denyCallout', id)
    cb({})
end)


RegisterNUICallback('dismiss_call', function(_, cb)
    cdebug('NUI dismiss_call')
    pendingCallId = nil
    SetNuiFocus(false, false)
    ui({ action = 'call_popup_hide' })
    cb({})
end)

-- GAME-SIDE "E" ACCEPT / "X" DENY (does NOT rely on NUI keyboard)
CreateThread(function()
    while true do
        if pendingCallId then
            -- E = accept
            if IsControlJustPressed(0, 38) then -- INPUT_CONTEXT (E)
                cdebug('E pressed for pending call '..tostring(pendingCallId))
                TriggerServerEvent('az_ambulance:acceptCallout', pendingCallId)
                ui({ action = 'call_popup_hide' })
                pendingCallId = nil

            -- X = ignore / deny
            elseif IsControlJustPressed(0, 73) then -- INPUT_VEH_DUCK (X)
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


---------------------------------------------------------------------
-- PATIENT NEARBY CHECK (multi-patient)
---------------------------------------------------------------------

local function refreshNearbyPatient()
    nearbyPatient = nil
    if not currentCall then return end

    local ped    = PlayerPedId()
    local myPos  = GetEntityCoords(ped)
    local maxDist = Config.InteractDistance or 3.0

    local bestPed, bestDist

    -- Prefer scene peds from callouts.lua
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

    -- Fallback: the single "main" patient
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
end

CreateThread(function()
    while true do
        if currentCall then
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

---------------------------------------------------------------------
-- CPR MINI-GAME
---------------------------------------------------------------------

local cprActive = false

local function stopCPRAnim()
    local ped = PlayerPedId()
    ClearPedTasks(ped)
end

local function startCPR()
    cdebug('startCPR nearbyPatient='..tostring(nearbyPatient))
    if not nearbyPatient then
        notify('No patient close enough for CPR.', 'error')
        return
    end

    cprActive = true
    local ped = PlayerPedId()
    TaskStartScenarioInPlace(ped, 'CODE_HUMAN_MEDIC_TEND_TO_DEAD', 0, true)

    SetNuiFocus(true, true)
    ui({
        action    = 'cpr_start',
        duration  = Config.CPRDurationSeconds or 30,
        goodMinMs = Config.CPRGoodMinMs or 450,
        goodMaxMs = Config.CPRGoodMaxMs or 600
    })
end

RegisterCommand('ems_cpr', function()
    cdebug('command /ems_cpr')
    if not isPlayerEMS() then return end
    if not currentCall then
        notify('No active call.', 'error')
        return
    end
    startCPR()
end, false)

RegisterKeyMapping('ems_cpr', 'EMS: Start CPR mini-game', 'keyboard', (Config.Keys and Config.Keys.StartCPR) or 'F7')

RegisterNUICallback('cpr_finish', function(data, cb)
    cdebug('NUI cpr_finish')
    cprActive = false
    SetNuiFocus(false, false)
    stopCPRAnim()

    local good  = data and data.good or 0
    local total = data and data.total or 0
    local quality = 0
    if total > 0 then
        quality = math.floor((good / total) * 100)
    end

    local patientNetId = getCurrentPatientNetId()

    TriggerServerEvent('az_ambulance:cprResult',
        currentCall and currentCall.id or 0,
        patientNetId,
        quality
    )

    notify(('CPR complete. Good compressions: %s%%'):format(quality), 'info')
    cb({})
end)

RegisterNUICallback('cpr_cancel', function(_, cb)
    cdebug('NUI cpr_cancel')
    cprActive = false
    SetNuiFocus(false, false)
    stopCPRAnim()
    cb({})
end)

---------------------------------------------------------------------
-- ASSESSMENT / VITALS
---------------------------------------------------------------------

RegisterCommand('ems_assess', function()
    cdebug('command /ems_assess')
    if not isPlayerEMS() then return end
    if not nearbyPatient then
        notify('No patient nearby for assessment.', 'error')
        return
    end

    local patientNetId = getCurrentPatientNetId()

    TriggerServerEvent('az_ambulance:requestVitals',
        currentCall and currentCall.id or 0,
        patientNetId
    )
end, false)

RegisterKeyMapping('ems_assess', 'EMS: Patient assessment', 'keyboard', (Config.Keys and Config.Keys.Assessment) or 'F8')

RegisterNetEvent('az_ambulance:vitalsData', function(vitals)
    cdebug('event vitalsData got='..tostring(vitals ~= nil))
    if not vitals then
        notify('No vitals available.', 'error')
        return
    end

    ui({
        action = 'assessment_open',
        vitals = vitals
    })
    SetNuiFocus(true, true)

    notify('Assessment done. Stabilise C-spine, then spawn stretcher with /ems_stretcher and load patient with /ems_loadpatient.', 'info', 15000)
    notify('When ready to transport, move stretcher to your ambulance and use /ems_load.', 'info', 15000)
end)

RegisterNUICallback('assessment_close', function(_, cb)
    cdebug('NUI assessment_close')
    SetNuiFocus(false, false)
    ui({ action = 'assessment_close' })
    cb({})
end)

---------------------------------------------------------------------
-- STRETCHER / TRANSPORT
---------------------------------------------------------------------

-- Try several possible stretcher / bed models.
-- The first one that actually loads will be used.
local stretcherModels = {
    -213759178, -- custom stretcher model
}

-- tolerant loader: *always* RequestModel and just see what loads
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
            else
                cdebug('Model '..tostring(model)..' did not load in time, trying next.')
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

    if stretcherEntity and DoesEntityExist(stretcherEntity) then
        notify('Stretcher already deployed.', 'info')
        return
    end

    local model = loadFirstAvailableModel(stretcherModels, 8000)
    if not model then
        notify('Could not load stretcher / hospital bed model on this build.', 'error', 8000)
        return
    end

    local ped = PlayerPedId()
    local pos = GetOffsetFromEntityInWorldCoords(ped, 0.0, 1.8, 0.0)

    stretcherEntity = CreateObject(model, pos.x, pos.y, pos.z, true, true, false)
    SetEntityHeading(stretcherEntity, GetEntityHeading(ped))
    PlaceObjectOnGroundProperly(stretcherEntity)

    stretcherPatientPed = nil
    patientOnStretcher  = false

    notify('Stretcher deployed. Use /ems_loadpatient near the patient to load them.', 'info', 12000)
end, false)

local function getStretcherIfClose(maxDist)
    if stretcherEntity and DoesEntityExist(stretcherEntity) then
        local ped    = PlayerPedId()
        local myPos  = GetEntityCoords(ped)
        local sPos   = GetEntityCoords(stretcherEntity)
        local dist   = #(myPos - sPos)
        if dist <= (maxDist or 5.0) then
            return stretcherEntity, dist
        end
    end
    return nil
end

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

    local patient = getCurrentPatientPed()
    if not patient or not DoesEntityExist(patient) then
        notify('Patient entity not available.', 'error')
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

    local stretcher = getStretcherIfClose(5.0)
    if not stretcher then
        notify('Move closer to the stretcher or deploy one with /ems_stretcher.', 'error', 7000)
        return
    end

    local sPos = GetEntityCoords(stretcher)

    FreezeEntityPosition(patient, false)
    ClearPedTasksImmediately(patient)
    SetEntityCoords(patient, sPos.x, sPos.y, sPos.z + 0.9, false, false, false, true)

    local dict = 'combat@damage@rb_writhe'
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        Wait(0)
    end

    AttachEntityToEntity(
        patient, stretcher, 0,
        0.0, 0.0, 0.9,      -- Z raised on bed
        0.0, 0.0, 180.0,    -- facing 180 (head at foot end)
        false, false, false, false, 2, true
    )

    TaskPlayAnim(patient, dict, 'rb_writhe_loop', 8.0, -8.0, -1, 1, 0.0, false, false, false)

    stretcherPatientPed = patient
    patientOnStretcher  = true

    notify('Patient loaded on stretcher. Move the stretcher near your ambulance then use /ems_load.', 'success', 15000)
end, false)

-- ambulance finder
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

local EMS_LOAD_MAX_DIST = 4.0 -- max distance between bed and rear doors


---------------------------------------------------------------------
-- CIVILIAN EMS CALL (/ems)
---------------------------------------------------------------------

RegisterCommand('ems', function()
    -- ox_lib style inputDialog
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

    -- player cancelled dialog
    if not result then return end

    local callType    = result[1]
    local description = result[2]

    TriggerServerEvent('az_ambulance:userEMSCall', callType, description)
end, false)


RegisterCommand('ems_load', function()
    cdebug('command /ems_load')
    if not isPlayerEMS() then return end
    if isCardiacCall() and not cardiacCPROk() then
        notify('Patient is still in cardiac arrest. Achieve ROSC with CPR before transporting.', 'error', 8000)
        return
    end
    if not stretcherEntity or not DoesEntityExist(stretcherEntity) then
        notify('No stretcher deployed.', 'error')
        return
    end

    if not patientOnStretcher or not stretcherPatientPed or not DoesEntityExist(stretcherPatientPed) then
        notify('No patient loaded on the stretcher.', 'error')
        return
    end

    local amb, ambDist = getClosestAmbulance(12.0)
    if not amb or amb == 0 then
        notify('No ambulance nearby.', 'error')
        return
    end

    local rearPos   = GetOffsetFromEntityInWorldCoords(amb, 0.0, -3.0, 0.0)
    local bedPos    = GetEntityCoords(stretcherEntity)
    local distRear  = #(bedPos - rearPos)
    local distToAmb = #(bedPos - GetEntityCoords(amb))

    cdebug(('[ems_load] rearDist=%.2f bedToAmb=%.2f ambDistFromPlayer=%.2f')
        :format(distRear, distToAmb, ambDist))

    if distRear > EMS_LOAD_MAX_DIST then
        notify('Move the stretcher closer to the rear doors of your ambulance.', 'error', 7000)
        return
    end

    local ambPos      = GetEntityCoords(amb)
    local nearestHosp = getNearestHospitalFromCoords(ambPos)

    if not nearestHosp then
        notify('No hospital locations configured.', 'error')
        return
    end

    clearCallBlip()
    clearHospitalBlip()

    hospitalBlip = AddBlipForCoord(nearestHosp.x, nearestHosp.y, nearestHosp.z)
    SetBlipSprite(hospitalBlip, 61)  -- hospital icon
    SetBlipColour(hospitalBlip, 2)
    SetBlipScale(hospitalBlip, 1.0)
    SetBlipRoute(hospitalBlip, true)
    BeginTextCommandSetBlipName("STRING")
    AddTextComponentString(nearestHosp.name or 'Hospital')
    EndTextCommandSetBlipName(hospitalBlip)

    SetNewWaypoint(nearestHosp.x, nearestHosp.y)

    activeHospital = nearestHosp

    DeleteEntity(stretcherPatientPed)
    DeleteEntity(stretcherEntity)
    stretcherEntity     = nil
    stretcherPatientPed = nil
    patientOnStretcher  = false

    status = 'TRANSPORT'
    updateHUD()
    notify(('Patient loaded. Proceed to %s.'):format(nearestHosp.name or 'hospital'), 'success', 8000)
    TriggerServerEvent('az_ambulance:statusUpdate', status)
end, false)

-- watch for arrival at hospital; auto-complete call
CreateThread(function()
    while true do
        if isEMSOnDuty and activeHospital and hospitalBlip then
            local ped  = PlayerPedId()
            local pos  = GetEntityCoords(ped)
            local hPos = vector3(activeHospital.x, activeHospital.y, activeHospital.z)
            local dist = #(pos - hPos)
            local arriveDist = Config.HospitalArriveDistance or 18.0

            if dist <= arriveDist then
                cdebug(('Arrived at hospital %s dist=%.2f'):format(activeHospital.name or 'Hospital', dist))
                notify('Patient handed over to hospital staff. Call complete.', 'success', 8000)

                local finishedCallId = currentCall and currentCall.id or nil

                -- locally reset state so the HUD is correct even if server hiccups
                clearHospitalBlip()
                clearStretcher()
                currentCall   = nil
                nearbyPatient = nil
                status        = 'AVAILABLE'
                updateHUD()

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

---------------------------------------------------------------------
-- EMS ACTIONS MENU (ALT)
---------------------------------------------------------------------

local emsActionsOpen = false

local function openEMSMenu()
    if not isPlayerEMS() then
        notify('You are not EMS.', 'error')
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
    if emsActionsOpen then
        closeEMSMenu()
    else
        openEMSMenu()
    end
end, false)

-- EMS ACTIONS MENU (CTRL + ALT)
CreateThread(function()
    while true do
        -- only let EMS use this, optional:
        if isPlayerEMS() then
            -- Hold CTRL and tap ALT to toggle
            if IsControlPressed(0, 36) and IsControlJustPressed(0, 19) then
                if emsActionsOpen then
                    closeEMSMenu()
                else
                    openEMSMenu()
                end
            end
        end

        Wait(0)
    end
end)


-- NUI calls this when a button is clicked
RegisterNUICallback('ems_action', function(data, cb)
    local cmd = data and data.cmd
    cdebug('NUI ems_action cmd='..tostring(cmd))
    if cmd and cmd ~= '' then
        closeEMSMenu()
        ExecuteCommand(cmd)
    else
        closeEMSMenu()
    end
    cb({})
end)

-- NUI close from X button
RegisterNUICallback('ems_actions_close', function(_, cb)
    cdebug('NUI ems_actions_close')
    closeEMSMenu()
    cb({})
end)

---------------------------------------------------------------------
-- HELP
---------------------------------------------------------------------

RegisterCommand('ems_help', function()
    notify('EMS: /ems_duty, /ems_status, /ems_cpr, /ems_assess, /ems_stretcher, /ems_loadpatient, /ems_load, /ems_actions (ALT).', 'info', 15000)
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    cdebug('onResourceStop -> clearing NUI focus')
    SetNuiFocus(false, false)
end)
