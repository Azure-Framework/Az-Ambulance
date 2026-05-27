local currentCall      = nil
local callBlip         = nil
local hospitalBlip     = nil
local isEMSOnDuty      = false
local lastDutyStateNotified = nil
local status           = 'AVAILABLE'

local nearbyPatient    = nil
local lastPatientCheck = 0
local pendingCallId    = nil

local stretchers = {}

local activeHospital   = nil

local isEMSAllowed   = false
local emsActionsOpen = false
local emsGuideOpen   = false
local emsBoardOpen   = false
local callPopupOpen  = false
local dispatchCalls  = {}
local selectedCallId = nil

local EMS_DEBUG = true
local isPlayerEMS

local sceneNotified = false
local spawnedSceneCalls = {}
local pendingSceneSpawnCalls = {}
local oxTargetReady = false
local oxTargetZones = {}
local oxTargetGlobalRegistered = false
local hudEditingOpen = false
local pendingDutyStateFromServer = nil
local setEMSOnDuty
local updateHUD

local function cdebug(...)
    if not EMS_DEBUG then return end
    
end

local function oxTargetEnabled()
    local thirdEye = Config.ThirdEye or {}
    if thirdEye.Enabled == false or thirdEye.UseOxTarget == false then return false end
    return GetResourceState('ox_target') == 'started'
end

local function emsUsesMDTDuty()
    local mdtCfg = Config and Config.MDT or {}
    local names = (mdtCfg and mdtCfg.ResourceNames) or { 'Az-MDT', 'az_mdt', 'Az-Mdt-Standalone' }
    for _, name in ipairs(names) do
        if name and name ~= '' then
            local state = GetResourceState(name)
            if state == 'started' or state == 'starting' then
                return true
            end
        end
    end
    return false
end

local function prettyDutyLabel(name)
    local s = tostring(name or ''):gsub('_', ' ')
    return (s:gsub("(%a)([%w_']*)", function(a, b)
        return string.upper(a) .. string.lower(b)
    end))
end

local function getEMSDutyOptions()
    local options, seen = {}, {}
    local currentJob = LocalPlayer and LocalPlayer.state and (LocalPlayer.state.department or LocalPlayer.state.job) or nil
    currentJob = currentJob and tostring(currentJob):lower() or nil
    if currentJob and Config.EMSJobs and Config.EMSJobs[currentJob] then
        seen[currentJob] = true
        options[#options + 1] = { value = currentJob, label = prettyDutyLabel(currentJob) }
    end
    for jobName, enabled in pairs(Config.EMSJobs or {}) do
        if enabled and not seen[jobName] then
            seen[jobName] = true
            options[#options + 1] = { value = tostring(jobName), label = prettyDutyLabel(jobName) }
        end
    end
    table.sort(options, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return options
end

local function openEMSDutyDialog()
    if emsUsesMDTDuty() then
        SendNUIMessage({ action = 'notify', text = 'Use Az-MDT to go on/off duty for EMS.', kind = 'info', duration = 5000 })
        return
    end
    if not isEMSAllowed then
        SendNUIMessage({ action = 'notify', text = 'You are not allowed to use EMS systems.', kind = 'error', duration = 5000 })
        return
    end
    if isEMSOnDuty then
        TriggerServerEvent('az_ambulance:setDutyState', false)
        return
    end
    local options = getEMSDutyOptions()
    if type(lib) ~= 'table' or type(lib.inputDialog) ~= 'function' or #options == 0 then
        TriggerServerEvent('az_ambulance:setDutyState', true, nil)
        return
    end
    local input = lib.inputDialog('Select On-Duty Department', {{
        type = 'select',
        label = 'Department',
        options = options,
        required = true
    }}, { allowCancel = true })
    if not input then return end
    TriggerServerEvent('az_ambulance:setDutyState', true, input[1])
end

local function isCurrentScenePed(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    if IsPedAPlayer(entity) then return false end
    if not currentCall then return false end

    if currentCall.patientNetId then
        local ped = NetToPed(currentCall.patientNetId)
        if ped ~= 0 and ped == entity then
            return true
        end
    end

    if AzCallouts and AzCallouts.GetScenePeds and currentCall.id then
        local scenePeds = AzCallouts.GetScenePeds(currentCall.id)
        for _, ped in ipairs(scenePeds) do
            if ped == entity then
                return true
            end
        end
    end

    return false
end
local function isLikelyAmbulance(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) or not IsEntityAVehicle(entity) then
        return false
    end

    local model = GetEntityModel(entity)
    if table.type(Config.LikelyAmbulanceModels) == 'array' then
        for i = 1, #Config.LikelyAmbulanceModels do
            if model == Config.LikelyAmbulanceModels[i] then
                return true
            end
        end
    end

    local class = GetVehicleClass(entity)
    if Config.LikelyAmbulanceClasses[class] then
        return true
    end

    return false
end

local function getThirdEyeStations()
    local dutyStations = (Config.DutyStations and #Config.DutyStations > 0) and Config.DutyStations or nil
    local list = dutyStations or ((Config.EMSStations and #Config.EMSStations > 0) and Config.EMSStations or Config.Hospitals or {})
    return list
end

local function requestHudLayoutApply()
    local saved = GetResourceKvpString('az_ambulance_hudLayout')
    if not saved or saved == '' then return end
    local ok, layout = pcall(json.decode, saved)
    if ok and type(layout) == 'table' then
        SendNUIMessage({ action = 'layout_apply', layout = layout })
    end
end


CreateThread(function()
    Wait(2000)
    cdebug('Requesting EMS job allowed state from server...')
    TriggerServerEvent('az_ambulance:requestJobAllowed')
end)

CreateThread(function()
    local interval = math.max(2000, tonumber(Config.JobSyncIntervalMs) or 5000)
    while true do
        Wait(interval)
        TriggerServerEvent('az_ambulance:requestJobAllowed')
    end
end)

CreateThread(function()
    Wait(1200)
    requestHudLayoutApply()
end)

RegisterNetEvent('az_ambulance:setJobAllowed', function(allowed)
    local wasAllowed = isEMSAllowed
    local wasOnDuty = isEMSOnDuty
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
        callPopupOpen = false
        sceneNotified  = false
        lastDutyStateNotified = false

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
        SendNUIMessage({ action = 'dispatch_close' })
        SendNUIMessage({ action = 'guide_close' })
        SendNUIMessage({ action = 'layout_force_cancel' })
        hudEditingOpen = false

        if callBlip and DoesBlipExist(callBlip) then RemoveBlip(callBlip) end
        callBlip = nil
        if hospitalBlip and DoesBlipExist(hospitalBlip) then RemoveBlip(hospitalBlip) end
        hospitalBlip = nil

        if wasAllowed or wasOnDuty then
            notify('EMS access removed. You were forced off duty.', 'error', 7000)
        end
        cdebug('EMS job not allowed on client -> all features disabled')
    else
        cdebug('EMS job allowed on client -> EMS features enabled (still need /ems_duty)')
        if pendingDutyStateFromServer ~= nil then
            local pending = pendingDutyStateFromServer == true
            pendingDutyStateFromServer = nil
            setEMSOnDuty(pending)
        end
        TriggerServerEvent('az_ambulance:requestCallBoard')
        updateHUD()
    end
end)

local function ui(msg)
    SendNUIMessage(msg)
end

local function refreshNuiFocus()
    local wantsFocus = emsActionsOpen or emsGuideOpen or emsBoardOpen or callPopupOpen or hudEditingOpen
    local allowGameInput = callPopupOpen and not emsActionsOpen and not emsGuideOpen and not emsBoardOpen and not hudEditingOpen

    SetNuiFocus(wantsFocus, wantsFocus)
    if SetNuiFocusKeepInput then
        SetNuiFocusKeepInput(allowGameInput)
    end
end

local function clearPopupFocus()
    if not callPopupOpen then return end
    callPopupOpen = false
    refreshNuiFocus()
end

local function showPopupFocus()
    callPopupOpen = true
    refreshNuiFocus()
end

local function toVector3FromTable(t, fallback)
    if type(t) ~= 'table' then return fallback end
    if t.x and t.y and t.z then
        return vector3((t.x + 0.0), (t.y + 0.0), (t.z + 0.0))
    end
    return fallback
end

local function tryGetSafePedCoord(x, y, z, onlyOnPavement, flags)
    local ok, found, safePos = pcall(GetSafeCoordForPed, x + 0.0, y + 0.0, z + 0.0, onlyOnPavement and true or false, flags or 0)
    if ok and found and safePos then
        if type(safePos) == 'vector3' then
            return true, safePos
        end
        local vec = toVector3FromTable(safePos)
        if vec then
            return true, vec
        end
    end
    return false, nil
end

local function getGroundZSafe(x, y, refZ)
    local probes = { (refZ or 0.0) + 100.0, (refZ or 0.0) + 250.0, 800.0, 1000.0 }
    for _, probeZ in ipairs(probes) do
        local found, groundZ = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, probeZ + 0.0, false)
        if found then
            return true, groundZ
        end
    end
    return false, refZ or 0.0
end

local function isWaterSpawnPoint(x, y, z)
    local ok, waterZ = GetWaterHeightNoWaves(x + 0.0, y + 0.0, z + 0.0)
    if ok and waterZ and math.abs((waterZ + 0.0) - (z + 0.0)) < 4.0 then
        return true
    end

    ok, waterZ = GetWaterHeightNoWaves(x + 0.0, y + 0.0, (z + 6.0))
    if ok and waterZ then
        return true
    end

    return false
end

local function findValidatedDynamicCalloutPoint(data)
    local ped = PlayerPedId()
    local anchor = toVector3FromTable(data and data.anchor, GetEntityCoords(ped)) or GetEntityCoords(ped)

    local minDist = math.max(150.0, tonumber(data and data.minDist) or 500.0)
    local maxDist = math.max(minDist + 50.0, tonumber(data and data.maxDist) or 900.0)
    local attempts = math.max(10, tonumber(data and data.attempts) or 35)
    local requireRoad = not (data and data.requireRoad == false)
    local useRoadBias = not (data and data.useRoadBias == false)
    local rejectWater = not (data and data.rejectWater == false)

    for _ = 1, attempts do
        Wait(0)

        local angle = math.random() * math.pi * 2.0
        local radius = minDist + (math.random() * (maxDist - minDist))
        local seedX = anchor.x + math.cos(angle) * radius
        local seedY = anchor.y + math.sin(angle) * radius
        local candX, candY, candZ = seedX, seedY, anchor.z
        local heading = math.random(0, 359) + 0.0

        if useRoadBias then
            local ok, roadPos, roadHeading = GetClosestVehicleNodeWithHeading(seedX, seedY, anchor.z + 0.0, false, 3.0, 0)
            if ok and roadPos then
                candX, candY, candZ = roadPos.x + 0.0, roadPos.y + 0.0, roadPos.z + 0.0
                if roadHeading then
                    heading = roadHeading + 0.0
                end
            end
        end

        local safeFound, safePos = tryGetSafePedCoord(candX, candY, candZ + 2.0, true, 16)
        if safeFound and safePos then
            candX, candY, candZ = safePos.x + 0.0, safePos.y + 0.0, safePos.z + 0.0
        end

        local groundFound, groundZ = getGroundZSafe(candX, candY, candZ)
        if groundFound then
            candZ = groundZ + 0.0
        end

        local pos = vector3(candX, candY, candZ)
        local dist = #(pos - anchor)
        local onRoad = IsPointOnRoad(candX + 0.0, candY + 0.0, candZ + 0.0, 0)

        if dist >= minDist and dist <= (maxDist + 200.0) and ((not requireRoad) or onRoad) then
            if (not rejectWater) or (not isWaterSpawnPoint(candX, candY, candZ + 1.0)) then
                return {
                    x = candX + 0.0,
                    y = candY + 0.0,
                    z = candZ + 0.0,
                    heading = heading + 0.0
                }
            end
        end
    end

    return nil
end

RegisterNetEvent('az_ambulance:requestValidatedCalloutPoint', function(requestId, data)
    local point = findValidatedDynamicCalloutPoint(data)
    TriggerServerEvent('az_ambulance:validatedCalloutPoint', requestId, point)
end)

local function notify(text, kind, durationMs)
    cdebug('notify kind='..tostring(kind)..' text='..tostring(text)..' dur='..tostring(durationMs))
    ui({
        action   = 'notify',
        text     = text or '',
        kind     = kind or 'info',
        duration = durationMs or 4000
    })
end


local function shouldUseMDTDispatchAlert()
    local mdtCfg = Config and Config.MDT or {}
    if mdtCfg and mdtCfg.UseMDTDispatchNotifications == false then return false end
    local names = (mdtCfg and mdtCfg.ResourceNames) or { 'Az-MDT', 'az_mdt', 'Az-Mdt-Standalone' }
    for _, name in ipairs(names) do
        if name and name ~= '' then
            local state = GetResourceState(name)
            if state == 'started' or state == 'starting' then
                return true
            end
        end
    end
    return false
end


RegisterNetEvent('az_ambulance:notify', function(data)
    if not isEMSAllowed then return end

    if type(data) == 'string' then
        notify(data, 'info')
    elseif type(data) == 'table' then
        notify(data.text or '', data.kind or 'info', data.duration)
    end
end)

local function getCallById(callId)
    callId = tonumber(callId)
    if not callId then return nil end
    for _, call in ipairs(dispatchCalls) do
        if tonumber(call.id) == callId then return call end
    end
    return nil
end

local function getSelectedCall()
    return getCallById(selectedCallId) or dispatchCalls[1]
end

local function setSelectedCall(callId)
    selectedCallId = tonumber(callId) or selectedCallId
end

local function getDistanceTextForCall(call)
    if not call or not call.coords then return '—' end
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local dist = #(pos - vector3(call.coords.x, call.coords.y, call.coords.z))
    if dist >= 1000.0 then
        return ('%.1f km'):format(dist / 1000.0)
    end
    return ('%dm'):format(math.floor(dist + 0.5))
end

local function syncBoardToUI(openAfter)
    local payload = {
        action = 'dispatch_data',
        calls = dispatchCalls,
        selectedCallId = selectedCallId,
        currentCallId = currentCall and currentCall.id or nil,
    }
    ui(payload)
    if openAfter then
        emsBoardOpen = true
        refreshNuiFocus()
        ui({ action = 'dispatch_open' })
    end
end

local function openGuide()
    if emsGuideOpen then return end
    emsGuideOpen = true
    refreshNuiFocus()
    ui({
        action = 'guide_open',
        bindings = {
            duty = (Config.Keys and Config.Keys.ToggleStatus) or 'F5',
            calls = (Config.Keys and Config.Keys.CallBoard) or 'F4',
            accept = (Config.Keys and Config.Keys.AcceptCall) or 'E',
            cpr = (Config.Keys and Config.Keys.StartCPR) or 'F7',
            assess = (Config.Keys and Config.Keys.Assessment) or 'F8',
            actions = (Config.Keys and Config.Keys.ActionsMenu) or 'F6',
            guide = (Config.Keys and Config.Keys.Guide) or 'F10',
        }
    })
end

local function closeGuide()
    if not emsGuideOpen then return end
    emsGuideOpen = false
    refreshNuiFocus()
    ui({ action = 'guide_close' })
end

local function openCallBoard()
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end
    TriggerServerEvent('az_ambulance:requestCallBoard')
    syncBoardToUI(true)
end

local function closeCallBoard()
    if not emsBoardOpen then return end
    emsBoardOpen = false
    refreshNuiFocus()
    ui({ action = 'dispatch_close' })
end

isPlayerEMS = function()
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

local getHotkeyAcceptCallId
local buildAddressFromCoords

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
    if not isEMSAllowed then
        ui({ action = 'hud_hide' })
        return
    end

    local focusCall = currentCall or getSelectedCall()
    local focusText = 'Stand by at a station'
    local distanceText = '—'
    local nextActions = emsUsesMDTDuty() and 'Open MDT • MDT Duty' or 'F5 Duty • F10 Guide'

    if isEMSOnDuty then
        focusText = currentCall and ((currentCall.title or 'Assigned call') .. ' ID ' .. tostring(currentCall.id)) or 'Ready for next dispatch'
        nextActions = currentCall and 'F4 Board • F7 CPR • F8 Assess • F10 Guide' or 'F4 Calls • F5 Duty • F10 Guide'
        local hotkeyAcceptCallId = tonumber(pendingCallId)
        if not hotkeyAcceptCallId then
            local selected = getSelectedCall()
            if selected and not selected.myAttached then
                hotkeyAcceptCallId = tonumber(selected.id)
            end
        end
        if focusCall and not currentCall then
            focusText = (focusCall.title or 'Dispatch call') .. ' ID ' .. tostring(focusCall.id)
            if hotkeyAcceptCallId then
                nextActions = 'E Accept • F4 Calls • F10 Guide'
            else
                nextActions = 'F4 Calls • F5 Duty • F10 Guide'
            end
        end
        distanceText = getDistanceTextForCall(focusCall)
    else
        local ped = PlayerPedId()
        if DoesEntityExist(ped) then
            local coords = GetEntityCoords(ped)
            local stations = getThirdEyeStations() or {}
            local best, bestDist = nil, nil
            for _, station in ipairs(stations) do
                if station and station.x and station.y and station.z then
                    local dist = #(coords - vector3(station.x + 0.0, station.y + 0.0, station.z + 0.0))
                    if not best or dist < bestDist then
                        best, bestDist = station, dist
                    end
                end
            end
            if best and bestDist then
                distanceText = ('%.1f m to %s'):format(bestDist, tostring(best.name or best.label or 'EMS Station'))
                if emsUsesMDTDuty() then
                    focusText = 'Open MDT and go on duty'
                    nextActions = 'Open MDT • MDT Duty'
                elseif bestDist <= 3.0 then
                    focusText = 'Ready to start shift'
                    nextActions = 'E Start Duty • F10 Guide'
                else
                    focusText = 'Head to an EMS station'
                    nextActions = 'F5 Duty • F10 Guide'
                end
            else
                if emsUsesMDTDuty() then
                    focusText = 'Open MDT and go on duty'
                    nextActions = 'Open MDT • MDT Duty'
                end
            end
        end
    end

    ui({
        action = 'hud_update',
        onDuty = isEMSOnDuty,
        status = status,
        unit = GetPlayerServerId(PlayerId()),
        focus = focusText,
        distance = distanceText,
        hospital = activeHospital and activeHospital.name or nil,
        callCount = #dispatchCalls,
        nextActions = nextActions,
        currentCallId = currentCall and currentCall.id or nil,
    })
end

setEMSOnDuty = function(value)
    isEMSOnDuty = (value and true or false) and isEMSAllowed
    cdebug('setEMSOnDuty -> '..tostring(isEMSOnDuty))

    if (not isEMSAllowed) or (not isEMSOnDuty) then
        if hudEditingOpen then
            SetNuiFocus(false, false)
            ui({ action = 'layout_force_cancel' })
            hudEditingOpen = false
        end
        pendingCallId  = nil
        nearbyPatient  = nil
        currentCall    = nil
        callPopupOpen  = false
        dispatchCalls  = {}
        selectedCallId = nil
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
    local normalized = onDuty and true or false
    if not isEMSAllowed then
        pendingDutyStateFromServer = normalized
        cdebug('event setDuty deferred until EMS access is available -> '..tostring(normalized))
        return
    end

    pendingDutyStateFromServer = nil
    local previousState = isEMSOnDuty and true or false

    cdebug('event setDuty onDuty='..tostring(normalized)..' previous='..tostring(previousState))
    setEMSOnDuty(normalized)

    if previousState == normalized and lastDutyStateNotified == normalized then
        return
    end

    local shouldNotify = (previousState ~= normalized) or (normalized and lastDutyStateNotified == nil)
    lastDutyStateNotified = normalized

    if not shouldNotify then
        return
    end

    if normalized then
        notify('You are now on duty as EMS.', 'success')
    else
        notify('You are now off duty.', 'info')
        ui({ action = 'call_popup_hide' })
        ui({ action = 'ems_actions_close' })
    end
end)

getHotkeyAcceptCallId = function()
    if pendingCallId then
        return tonumber(pendingCallId)
    end

    local selected = getSelectedCall()
    if selected and not selected.myAttached then
        return tonumber(selected.id)
    end

    return nil
end

local function acceptSelectedEMSCall()
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end

    if currentCall and currentCall.id then
        local refreshed = getCallById(currentCall.id)
        if not refreshed or not refreshed.myAttached then
            cdebug('acceptSelectedEMSCall clearing stale currentCall '..tostring(currentCall.id))
            currentCall = nil
            clearCallBlip()
            clearHospitalBlip()
            nearbyPatient = nil
            sceneNotified = false
            status = 'AVAILABLE'
        else
            cdebug('acceptSelectedEMSCall blocked; already attached to call '..tostring(currentCall.id))
            return
        end
    end

    local callId = tonumber(pendingCallId)
    if not callId then
        local selected = getSelectedCall()
        if selected and not selected.myAttached then
            callId = tonumber(selected.id) or nil
        end
    end

    if not callId then
        cdebug('acceptSelectedEMSCall ignored; no pending/selectable call')
        return
    end

    local selected = getCallById(callId) or getSelectedCall()
    local address = selected and selected.address or nil
    if (not address or address == 'Unknown address') and selected and selected.coords then
        address = buildAddressFromCoords(selected.coords)
    end

    pendingCallId = nil
    clearPopupFocus()
    ui({ action = 'call_popup_hide' })
    if emsBoardOpen then
        closeCallBoard()
    end
    TriggerServerEvent('az_ambulance:acceptCallout', callId, address)
end

RegisterCommand('ems_duty_key', function()
    if not isEMSAllowed then return end
    cdebug('command ems_duty_key -> openEMSDutyDialog')
    openEMSDutyDialog()
end, false)
RegisterKeyMapping('ems_duty_key', 'EMS: Toggle duty', 'keyboard', 'F5')

RegisterCommand('ems_accept_key', function()
    if not isPlayerEMS() then return end
    acceptSelectedEMSCall()
end, false)
RegisterKeyMapping('ems_accept_key', 'EMS: Accept selected / pending call', 'keyboard', (Config.Keys and Config.Keys.AcceptCall) or 'E')

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

buildAddressFromCoords = function(coords)
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

    pendingCallId = call.id
    selectedCallId = call.id

    clearPopupFocus()
    ui({ action = 'call_popup_hide' })

    if not shouldUseMDTDispatchAlert() then
        notify(('[CALL %s] %s - press E to accept.'):format(call.id, call.title or 'Medical call'), 'warning')
    end
    syncBoardToUI(false)
    updateHUD()
end)

local function spawnInitialPatientForCall(call)
    if not call or not call.coords then return end

    local callId = tonumber(call.id)
    if not callId then return end
    if spawnedSceneCalls[callId] or pendingSceneSpawnCalls[callId] then return end

    if currentCall and currentCall.id == callId and currentCall.patientNetId and currentCall.patientNetId ~= 0 then
        spawnedSceneCalls[callId] = true
        return
    end

    if call.patientNetId and tonumber(call.patientNetId) and tonumber(call.patientNetId) ~= 0 then
        spawnedSceneCalls[callId] = true
        return
    end

    if call.noScene then
        cdebug(('Call %s is marked noScene; skipping automatic patient spawn.'):format(tostring(call.id)))
        return
    end

    pendingSceneSpawnCalls[callId] = true

    if AzCallouts and AzCallouts.SpawnForCallType then
        local netId = AzCallouts.SpawnForCallType(call)
        if netId and netId ~= 0 then
            pendingSceneSpawnCalls[callId] = nil
            spawnedSceneCalls[callId] = true
            if currentCall and currentCall.id == callId then
                currentCall.patientNetId = netId
            end
            TriggerServerEvent('az_ambulance:registerPatientNet', callId, netId)
            return
        end
    end

    local model = `a_m_m_business_01`
    RequestModel(model)
    local start = GetGameTimer()
    while not HasModelLoaded(model) and GetGameTimer() - start < 5000 do Wait(0) end
    if not HasModelLoaded(model) then
        cdebug('Failed to load patient model')
        pendingSceneSpawnCalls[callId] = nil
        return
    end

    local x, y, z = call.coords.x, call.coords.y, call.coords.z
    RequestCollisionAtCoord(x + 0.0, y + 0.0, z + 50.0)
    for _ = 1, 20 do
        Wait(0)
        local found, groundZ = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, z + 50.0, false)
        if found then
            z = groundZ + 0.05
            break
        end
    end

    local groundOffset = (Config and Config.PatientGroundOffset) or 0.72
    local animZ = z + groundOffset

    local ped = CreatePed(4, model, x, y, animZ, call.coords.heading or 0.0, true, true)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, animZ + 0.0, false, false, false)

    SetEntityAsMissionEntity(ped, true, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetEntityInvincible(ped, true)
    SetEntityVisible(ped, true, false)
    ResetEntityAlpha(ped)
    SetEntityCollision(ped, true, true)
    SetEntityLoadCollisionFlag(ped, true)

    TaskStartScenarioAtPosition(ped, 'WORLD_HUMAN_SUNBATHE_BACK', x + 0.0, y + 0.0, z + 0.03, call.coords.heading or 0.0, -1, true, false)
    Wait(250)
    FreezeEntityPosition(ped, true)

    local netId = PedToNet(ped)
    SetNetworkIdCanMigrate(netId, true)

    pendingSceneSpawnCalls[callId] = nil
    spawnedSceneCalls[callId] = true
    if currentCall and currentCall.id == callId then
        currentCall.patientNetId = netId
    end
    TriggerServerEvent('az_ambulance:registerPatientNet', callId, netId)
end

RegisterNetEvent('az_ambulance:spawnSceneForCall', function(call)
    if not isEMSAllowed then return end
    if not call or not call.id then return end

    local callId = tonumber(call.id)
    if not callId then return end

    if call.patientNetId and tonumber(call.patientNetId) and tonumber(call.patientNetId) ~= 0 then
        spawnedSceneCalls[callId] = true
        pendingSceneSpawnCalls[callId] = nil
        if currentCall and currentCall.id == callId then
            currentCall.patientNetId = tonumber(call.patientNetId)
        end
        return
    end

    CreateThread(function()
        Wait(250)
        spawnInitialPatientForCall(call)
    end)
end)

RegisterNetEvent('az_ambulance:callAccepted', function(call)
    if not isEMSAllowed then return end

    cdebug('event callAccepted id='..tostring(call and call.id)..' assigned='..tostring(call and call.assigned))
    notify(('[CALL %s] Attached to dispatch.'):format(call.id), 'info')

    if not isPlayerEMS() then return end

    pendingCallId = nil
    clearPopupFocus()
    ui({ action = 'call_popup_hide' })

    currentCall = call
    setSelectedCall(call.id)
    status      = call.myStatus or 'ENROUTE'
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

    if currentCall.patientNetId and currentCall.patientNetId ~= 0 then
        spawnedSceneCalls[currentCall.id] = true
        pendingSceneSpawnCalls[currentCall.id] = nil
    end

    syncBoardToUI(false)
end)

RegisterNetEvent('az_ambulance:updateCallPatient', function(callId, netId)
    if not isEMSAllowed then return end
    cdebug('event updateCallPatient callId='..tostring(callId)..' netId='..tostring(netId))
    pendingSceneSpawnCalls[callId] = nil
    if netId and tonumber(netId) and tonumber(netId) ~= 0 then
        spawnedSceneCalls[callId] = true
    end
    if currentCall and currentCall.id == callId then
        currentCall.patientNetId = netId
    end
end)

RegisterNetEvent('az_ambulance:callBoardData', function(calls)
    if not isEMSAllowed then return end
    dispatchCalls = calls or {}
    if (not selectedCallId) and dispatchCalls[1] then
        selectedCallId = dispatchCalls[1].id
    elseif selectedCallId and not getCallById(selectedCallId) and dispatchCalls[1] then
        selectedCallId = dispatchCalls[1].id
    end

    if currentCall and currentCall.id then
        local refreshed = getCallById(currentCall.id)
        if refreshed and refreshed.myAttached then
            currentCall = refreshed
        elseif currentCall then
            pendingSceneSpawnCalls[currentCall.id] = nil
            currentCall = nil
            clearCallBlip()
            sceneNotified = false
            status = 'AVAILABLE'
        end
    end

    syncBoardToUI(false)
    updateHUD()
end)

RegisterNetEvent('az_ambulance:callDetached', function(callId)
    if not isEMSAllowed then return end
    callId = tonumber(callId)
    if currentCall and currentCall.id == callId then
        currentCall = nil
        clearCallBlip()
        clearHospitalBlip()
        nearbyPatient = nil
        sceneNotified = false
        status = 'AVAILABLE'
        updateHUD()
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
    clearPopupFocus()
    clearAllStretchers()
    sceneNotified = false

    ui({ action = 'call_popup_hide' })
    if selectedCallId == id then selectedCallId = nil end
    notify('Call cleared: '..(reason or 'completed'), 'success')
    syncBoardToUI(false)
    updateHUD()
end)

RegisterNUICallback('accept_call', function(data, cb)
    if not isEMSAllowed then cb({}) return end
    if data and data.id then
        pendingCallId = tonumber(data.id) or pendingCallId
    end
    clearPopupFocus()
    acceptSelectedEMSCall()
    cb({})
end)

RegisterNUICallback('deny_call', function(data, cb)
    if not isEMSAllowed then cb({}) return end
    if not data or not data.id then cb({}) return end

    local id = data.id
    pendingCallId = nil
    clearPopupFocus()
    ui({ action = 'call_popup_hide' })
    TriggerServerEvent('az_ambulance:denyCallout', id)
    cb({})
end)

RegisterNUICallback('dismiss_call', function(_, cb)
    if not isEMSAllowed then cb({}) return end
    pendingCallId = nil
    clearPopupFocus()
    ui({ action = 'call_popup_hide' })
    cb({})
end)

RegisterNUICallback('dispatch_close', function(_, cb)
    closeCallBoard()
    cb({})
end)

RegisterNUICallback('dispatch_select', function(data, cb)
    setSelectedCall(data and data.id)
    syncBoardToUI(false)
    updateHUD()
    cb({})
end)

RegisterNUICallback('dispatch_action', function(data, cb)
    local action = data and data.actionName or nil
    local callId = tonumber(data and data.id)
    if action == 'gps' then
        local call = getCallById(callId)
        if call and call.coords then
            SetNewWaypoint(call.coords.x, call.coords.y)
            notify(('GPS set for EMS call %s.'):format(callId), 'info')
        end
    elseif action == 'join' then
        if callId then
            pendingCallId = callId
        end
        acceptSelectedEMSCall()
    elseif action == 'detach' then
        TriggerServerEvent('az_ambulance:detachCall', callId)
    elseif action == 'close' then
        TriggerServerEvent('az_ambulance:closeCall', callId)
    elseif action == 'force_cancel' then
        TriggerServerEvent('az_ambulance:forceCancelCall', callId)
    elseif action == 'status' then
        local newStatus = tostring(data.status or 'ENROUTE'):upper()
        status = newStatus
        updateHUD()
        TriggerServerEvent('az_ambulance:statusUpdate', newStatus, callId)
    end
    cb({})
end)

RegisterNUICallback('guide_close', function(_, cb)
    closeGuide()
    cb({})
end)

RegisterNUICallback('guide_action', function(data, cb)
    local action = data and data.actionName or nil
    if action == 'board' then
        closeGuide()
        openCallBoard()
    elseif action == 'duty' then
        closeGuide()
        TriggerServerEvent('az_ambulance:toggleDuty')
    elseif action == 'rebind' then
        local target = tostring(data.target or '')
        local key = tostring(data.key or ''):lower()
        local commandMap = {
            duty = 'ems_duty_key',
            calls = 'ems_calls_board_key',
            accept = 'ems_accept_key',
            cpr = 'ems_cpr',
            assess = 'ems_assess',
            actions = 'ems_actions_key',
            guide = 'ems_guide_key',
        }
        local cmd = commandMap[target]
        if cmd and key ~= '' then
            ExecuteCommand(('bind keyboard %s "%s"'):format(key, cmd))
            notify(('Bound %s to %s.'):format(target, key:upper()), 'success')
        end
    end
    cb({})
end)

CreateThread(function()
    while true do
        if not isPlayerEMS() then
            Wait(1000)
        else
            local hotkeyCallId = nil
            if pendingCallId then
                hotkeyCallId = tonumber(pendingCallId)
            else
                local selected = getSelectedCall()
                if selected and not selected.myAttached then
                    hotkeyCallId = tonumber(selected.id)
                end
            end

            if hotkeyCallId then
                local acceptPressed = IsControlJustPressed(0, 38) or IsDisabledControlJustPressed(0, 38)
                local denyPressed = pendingCallId and (IsControlJustPressed(0, 73) or IsDisabledControlJustPressed(0, 73))

                if acceptPressed then
                    cdebug('E pressed for call '..tostring(hotkeyCallId))
                    acceptSelectedEMSCall()
                elseif denyPressed then
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
    end
end)

local startCPR

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

startCPR = function()
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
    requestVitalsForTarget(getTargetPatientPed())
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


local function deployStretcherForPed(patient)
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end
    if not currentCall then
        notify('You need an active call to deploy a stretcher.', 'error')
        return
    end
    if not patient or not DoesEntityExist(patient) then
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

    notify(('Stretcher deployed for patient [%s]. Use /ems_loadpatient or third eye load.'):format(patientNetId), 'info', 12000)
end

local function loadPatientOntoAssignedStretcher(patient)
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end
    if not currentCall then
        notify('No active patient to load.', 'error')
        return
    end
    if isCardiacCall() and not cardiacCPROk() then
        notify('Patient is in cardiac arrest. Perform effective CPR before loading them on the stretcher.', 'error', 8000)
        return
    end
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
        notify('No stretcher close for this patient. Deploy one first.', 'error', 7000)
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

    notify('Patient loaded on stretcher. Move it near your ambulance then use /ems_load or the third eye vehicle option.', 'success', 15000)
end

local function requestVitalsForTarget(patient)
    if not isPlayerEMS() then
        notify('You are not EMS on duty.', 'error')
        return
    end
    if not patient or not DoesEntityExist(patient) then
        notify('No patient nearby for assessment.', 'error')
        return
    end

    nearbyPatient = patient
    TriggerServerEvent('az_ambulance:requestVitals', currentCall and currentCall.id or 0, getPatientKeyFromPed(patient) or 0)
end

local function startCPRForTarget(patient)
    nearbyPatient = patient
    startCPR()
end


RegisterCommand('ems_stretcher', function()
    cdebug('command /ems_stretcher')
    if not isPlayerEMS() then return end
    deployStretcherForPed(getTargetPatientPed())
end, false)

RegisterCommand('ems_loadpatient', function()
    cdebug('command /ems_loadpatient')
    if not isPlayerEMS() then return end
    loadPatientOntoAssignedStretcher(getTargetPatientPed())
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
    refreshNuiFocus()
    ui({ action = 'ems_actions_open' })
end

local function closeEMSMenu()
    if not emsActionsOpen then return end
    emsActionsOpen = false
    refreshNuiFocus()
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

RegisterCommand('ems_calls_board', function()
    if not isEMSAllowed then return end
    if emsBoardOpen then closeCallBoard() else openCallBoard() end
end, false)

RegisterCommand('ems_calls_board_key', function()
    if not isEMSAllowed then return end
    if emsBoardOpen then closeCallBoard() else openCallBoard() end
end, false)
RegisterKeyMapping('ems_calls_board_key', 'EMS: Open dispatch board', 'keyboard', (Config.Keys and Config.Keys.CallBoard) or 'F4')

RegisterCommand('emscalls', function()
    if not isEMSAllowed then return end
    openCallBoard()
end, false)

RegisterCommand('ems_guide_key', function()
    if not isEMSAllowed then return end
    if emsGuideOpen then closeGuide() else openGuide() end
end, false)
RegisterKeyMapping('ems_guide_key', 'EMS: Open guide', 'keyboard', (Config.Keys and Config.Keys.Guide) or 'F10')

local function showEMSHelp()
    if not isEMSAllowed then
        notify('You are not allowed to use EMS systems.', 'error')
        return
    end
    openGuide()
end

RegisterCommand('emshelp', function()
    showEMSHelp()
end, false)





RegisterCommand('moveemshud', function()
    if emsGuideOpen then
        closeGuide()
    end
    if emsBoardOpen then
        closeCallBoard()
    end
    if emsActionsOpen then
        SetNuiFocus(false, false)
        ui({ action = 'ems_actions_close' })
        emsActionsOpen = false
    end
    if not isPlayerEMS() then
        notify('You must be on duty EMS to edit the EMS HUD.', 'error')
        return
    end
    if hudEditingOpen then
        ui({ action = 'layout_force_cancel' })
        SetNuiFocus(false, false)
        hudEditingOpen = false
        notify('EMS HUD layout edit canceled.', 'info')
        return
    end
    hudEditingOpen = true
    SetNuiFocus(true, true)
    ui({ action = 'layout_edit' })
    notify('EMS HUD layout mode: drag the status card and notifications, then Save or Cancel.', 'info', 6000)
end, false)

TriggerEvent('chat:addSuggestion', '/moveemshud', 'Move the EMS HUD and notification anchors', {})

RegisterNUICallback('layout_saved', function(data, cb)
    if data and data.layout then
        local ok, encoded = pcall(json.encode, data.layout)
        if ok and encoded then
            SetResourceKvp('az_ambulance_hudLayout', encoded)
        end
    end
    SetNuiFocus(false, false)
    hudEditingOpen = false
    cb({})
end)

RegisterNUICallback('layout_cancel', function(_, cb)
    SetNuiFocus(false, false)
    hudEditingOpen = false
    cb({})
end)

local function registerOxTargetIntegration()
    if oxTargetGlobalRegistered or not oxTargetEnabled() then return end

    local thirdEye = Config.ThirdEye or {}
    local patientDistance = thirdEye.PatientDistance or 2.5
    local vehicleDistance = thirdEye.VehicleDistance or 3.0

    for index, loc in ipairs(getThirdEyeStations()) do
        if loc.x and loc.y and loc.z then
            local zoneName = ('az_ambulance_station_%s'):format(index)
            local zoneId = exports.ox_target:addSphereZone({
                name = zoneName,
                coords = vector3(loc.x + 0.0, loc.y + 0.0, loc.z + 0.0),
                radius = thirdEye.StationRadius or 2.25,
                debug = thirdEye.Debug == true,
                drawSprite = thirdEye.DrawSprite == true,
                options = {
                    {
                        name = zoneName .. '_onduty',
                        label = 'Go On Duty',
                        icon = 'fas fa-user-check',
                        distance = 2.5,
                        canInteract = function()
                            return isEMSAllowed and not isEMSOnDuty and not emsUsesMDTDuty()
                        end,
                        onSelect = function()
                            openEMSDutyDialog()
                        end,
                    },
                    {
                        name = zoneName .. '_offduty',
                        label = 'Go Off Duty',
                        icon = 'fas fa-user-slash',
                        distance = 2.5,
                        canInteract = function()
                            return isEMSAllowed and isEMSOnDuty and not emsUsesMDTDuty()
                        end,
                        onSelect = function()
                            TriggerServerEvent('az_ambulance:setDutyState', false)
                        end,
                    },
                    {
                        name = zoneName .. '_board',
                        label = 'Open EMS Dispatch',
                        icon = 'fas fa-tablet-screen-button',
                        distance = 2.5,
                        canInteract = function()
                            return isPlayerEMS()
                        end,
                        onSelect = function()
                            openCallBoard()
                        end,
                    },
                    {
                        name = zoneName .. '_actions',
                        label = 'Open EMS Actions',
                        icon = 'fas fa-briefcase-medical',
                        distance = 2.5,
                        canInteract = function()
                            return isPlayerEMS()
                        end,
                        onSelect = function()
                            openEMSMenu()
                        end,
                    },
                    {
                        name = zoneName .. '_guide',
                        label = 'Open EMS Guide',
                        icon = 'fas fa-circle-question',
                        distance = 2.5,
                        canInteract = function()
                            return isEMSAllowed
                        end,
                        onSelect = function()
                            openGuide()
                        end,
                    },
                    {
                        name = zoneName .. '_cancel',
                        label = 'Force Cancel Current Call',
                        icon = 'fas fa-ban',
                        distance = 2.5,
                        canInteract = function()
                            return isPlayerEMS() and currentCall and currentCall.id ~= nil
                        end,
                        onSelect = function()
                            if currentCall and currentCall.id then
                                TriggerServerEvent('az_ambulance:forceCancelCall', currentCall.id)
                            end
                        end,
                    },
                }
            })
            oxTargetZones[#oxTargetZones+1] = zoneId or zoneName
        end
    end

    exports.ox_target:addGlobalPed({
        {
            name = 'az_ambulance_target_assess',
            label = 'Assess Patient',
            icon = 'fas fa-stethoscope',
            distance = patientDistance,
            canInteract = function(entity)
                return isPlayerEMS() and isCurrentScenePed(entity)
            end,
            onSelect = function(data)
                requestVitalsForTarget(data.entity)
            end,
        },
        {
            name = 'az_ambulance_target_cpr',
            label = 'Start CPR',
            icon = 'fas fa-heart-pulse',
            distance = patientDistance,
            canInteract = function(entity)
                return isPlayerEMS() and isCurrentScenePed(entity)
            end,
            onSelect = function(data)
                startCPRForTarget(data.entity)
            end,
        },
        {
            name = 'az_ambulance_target_stretcher',
            label = 'Deploy Stretcher',
            icon = 'fas fa-bed-pulse',
            distance = patientDistance,
            canInteract = function(entity)
                return isPlayerEMS() and isCurrentScenePed(entity)
            end,
            onSelect = function(data)
                deployStretcherForPed(data.entity)
            end,
        },
        {
            name = 'az_ambulance_target_loadpatient',
            label = 'Load Onto Stretcher',
            icon = 'fas fa-truck-medical',
            distance = patientDistance,
            canInteract = function(entity)
                return isPlayerEMS() and isCurrentScenePed(entity)
            end,
            onSelect = function(data)
                loadPatientOntoAssignedStretcher(data.entity)
            end,
        },
    })

    exports.ox_target:addGlobalVehicle({
        {
            name = 'az_ambulance_target_vehicleload',
            label = 'Load Patient Into Ambulance',
            icon = 'fas fa-van-shuttle',
            distance = vehicleDistance,
            canInteract = function(entity)
                return isPlayerEMS() and isLikelyAmbulance(entity)
            end,
            onSelect = function()
                ExecuteCommand('ems_load')
            end,
        },
        {
            name = 'az_ambulance_target_dispatch',
            label = 'Open EMS Dispatch',
            icon = 'fas fa-tablet-screen-button',
            distance = vehicleDistance,
            canInteract = function(entity)
                return isPlayerEMS() and isLikelyAmbulance(entity)
            end,
            onSelect = function()
                openCallBoard()
            end,
        },
    })

    oxTargetGlobalRegistered = true
    oxTargetReady = true
    cdebug('ox_target integration registered')
end

CreateThread(function()
    Wait(1500)
    if oxTargetEnabled() then
        registerOxTargetIntegration()
    else
        cdebug('ox_target not started; skipping third-eye EMS integration')
    end
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= 'ox_target' then return end
    Wait(500)
    if GetCurrentResourceName() then
        registerOxTargetIntegration()
    end
end)

RegisterCommand('ems_help', function()
    showEMSHelp()
end, false)


AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    emsGuideOpen = false
    emsBoardOpen = false
    SetNuiFocus(false, false)

    if oxTargetEnabled() then
        for _, zoneId in ipairs(oxTargetZones) do
            pcall(function() exports.ox_target:removeZone(zoneId) end)
        end
        pcall(function() exports.ox_target:removeGlobalPed({
            'az_ambulance_target_assess',
            'az_ambulance_target_cpr',
            'az_ambulance_target_stretcher',
            'az_ambulance_target_loadpatient',
        }) end)
        pcall(function() exports.ox_target:removeGlobalVehicle({
            'az_ambulance_target_vehicleload',
            'az_ambulance_target_dispatch',
        }) end)
    end
end)
