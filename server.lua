local Config = Config or {}
local fw = exports['Az-Framework']

Config.Payments = Config.Payments or {
    Enabled = true,

    BaseByType = {
        DRUNK     = 200,
        MVA       = 260,
        MVA_MINOR = 240,
        MVA_MAJOR = 420,
        GSW       = 520,
        CARDIAC   = 650,
    },

    DefaultBase = 220,

    PerExtraPatient = 180,

    Distance = {
        ResponsePerKm = 90,
        ResponseMax   = 650,
        TransportPerKm= 140,
        TransportMax  = 950,
    },

    Speed = {
        ResponseTargetSec  = 90,
        ResponseMaxBonus   = 420,
        CompletionTargetSec= 420,
        CompletionMaxBonus = 650,
    },

    CPR = {
        Enabled = true,
        MinQuality = 60,
        PerQualityPoint = 4,
        MaxBonus = 350,
    },

    MinPay = 260,
    MaxPay = 2600,
    PrimaryMultiplier = 1.0,
    AssistMultiplier = 0.65,
}

local EMS_DEBUG = true

local function sdebug(...)
    if not EMS_DEBUG then return end

end

Config.GetPlayerJob = Config.GetPlayerJob or function(source)
    local job = exports['Az-Framework']:getPlayerJob(source)
    return job and string.lower(job) or 'civ'
end

Config.EMSJobs = Config.EMSJobs or {
    ['ambulance'] = true,
    ['ems']       = true,
    ['doctor']    = true,
}

Config.CallBlipSprite = Config.CallBlipSprite or 153
Config.CallBlipColour = Config.CallBlipColour or 1
Config.CallBlipScale  = Config.CallBlipScale  or 0.85

Config.InteractDistance   = Config.InteractDistance   or 3.0
Config.CPRDurationSeconds = Config.CPRDurationSeconds or 30
Config.CPRGoodMinMs       = Config.CPRGoodMinMs       or 450
Config.CPRGoodMaxMs       = Config.CPRGoodMaxMs       or 600

Config.CalloutsEnabled      = (Config.CalloutsEnabled ~= false)
Config.CalloutIntervalMin   = Config.CalloutIntervalMin   or (5 * 60 * 1000)
Config.CalloutIntervalMax   = Config.CalloutIntervalMax   or (15 * 60 * 1000)
Config.MaxSimultaneousCalls = Config.MaxSimultaneousCalls or 3

Config.CalloutMinDistance   = Config.CalloutMinDistance or 800.0
Config.CalloutMaxDistance   = Config.CalloutMaxDistance or 3500.0
Config.CalloutPickAttempts  = Config.CalloutPickAttempts or 25

Config.CardiacCPRRequiredQuality = Config.CardiacCPRRequiredQuality or 60


Config.MDT = Config.MDT or {}
Config.MDT.Enabled = Config.MDT.Enabled ~= false
Config.MDT.MirrorAcceptedCalls = Config.MDT.MirrorAcceptedCalls ~= false
Config.MDT.ResourceNames = Config.MDT.ResourceNames or { 'Az-MDT', 'az_mdt', 'Az-Mdt-Standalone' }

local emsDuty     = {}
local emsDutyDepartment = {}
local activeCalls = {}
local nextCallId  = 1
local pendingCalloutValidation = {}
local nextValidationRequestId  = 1

local pushJobState
local reconcileEMSResponderWithMDT
local lastMDTDutySync = {}
local lastMDTStatusSync = {}

local function setPlayerEMSState(src, isEMSAllowed, onDuty, dutyDepartment)
    src = tonumber(src) or 0
    if src <= 0 then return end
    local ply = Player(src)
    if ply and ply.state then
        ply.state.az_ambulance_isEMS = isEMSAllowed == true
        ply.state.az_ambulance_onDuty = onDuty == true
        ply.state.az_ambulance_onduty = onDuty == true
        ply.state.az_ambulance_department = dutyDepartment or emsDutyDepartment[src] or nil
    end
end

local function getResponderName(src)
    local name = GetPlayerName(src)
    if name and name ~= '' then return name end
    return ('EMS %s'):format(tostring(src))
end

local function getEffectiveMDTUnitStatusForResponder(src)
    src = tonumber(src) or 0
    if src <= 0 then return 'OFFDUTY' end
    if not emsDuty[src] then return 'OFFDUTY' end
    for _, call in pairs(activeCalls) do
        if call and call.responders and call.responders[src] then
            local responderStatus = tostring((call.responders[src] and call.responders[src].status) or 'ENROUTE'):upper()
            if responderStatus == '' then responderStatus = 'ENROUTE' end
            return responderStatus
        end
    end
    return 'AVAILABLE'
end

local function buildEMSMDTUnitContext(src)
    return {
        department = emsDutyDepartment[src] or 'ems',
        role = 'leo',
        isLEO = true,
        name = getResponderName(src),
        callsign = ('E-%s'):format(tostring(src)),
        source = src,
        playerSource = src
    }
end


local function mdtTrim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function resolveMDTResourceName()
    if not (Config.MDT and Config.MDT.Enabled) then return nil end
    for _, name in ipairs((Config.MDT and Config.MDT.ResourceNames) or {}) do
        if name and name ~= '' then
            local state = GetResourceState(name)
            if state == 'started' or state == 'starting' then
                return name
            end
        end
    end
    return nil
end

local function getCallMDTStatus(call)
    local hasResponder = false
    local hasEnroute = false
    if call and call.responders then
        for _, info in pairs(call.responders) do
            hasResponder = true
            local st = tostring((info and info.status) or 'ENROUTE'):upper()
            if st == 'ONSCENE' then return 'ONSCENE' end
            if st == 'ENROUTE' or st == 'RESPONDING' or st == 'ASSIGNED' or st == 'AVAILABLE' then
                hasEnroute = true
            end
        end
    end
    if hasEnroute then return 'ENROUTE' end
    if hasResponder then return 'ACTIVE' end
    return 'PENDING'
end

local function buildMDTCallMessage(call)
    local title = tostring((call and call.title) or 'EMS Request')
    local details = mdtTrim(call and call.details or '')
    if details ~= '' then
        return ('[EMS] %s\n%s'):format(title, details)
    end
    return ('[EMS] %s'):format(title)
end

local function syncUnitStatusToMDT(src, status, force)
    src = tonumber(src) or 0
    if src <= 0 then return false end
    local normalized = string.upper(tostring(status or 'AVAILABLE'))
    if not force and lastMDTStatusSync[src] == normalized then
        return true
    end
    local mdtResource = resolveMDTResourceName()
    if not mdtResource then return false end
    local ctx = buildEMSMDTUnitContext(src)
    if normalized == 'OFFDUTY' and force == true then
        ctx.forceOffDuty = true
    end
    local ok = pcall(function()
        exports[mdtResource]:SetUnitStatusFromExternal(src, normalized, ctx)
    end)
    if ok then
        lastMDTStatusSync[src] = normalized
    end
    return ok
end

local function syncDutyStateToMDT(src, onDuty, status, force)
    src = tonumber(src) or 0
    if src <= 0 then return false end
    local desiredDuty = onDuty == true
    local desiredStatus = status and string.upper(tostring(status)) or nil
    if not force and lastMDTDutySync[src] == desiredDuty and (desiredStatus == nil or lastMDTStatusSync[src] == desiredStatus) then
        return true
    end
    local mdtResource = resolveMDTResourceName()
    if not mdtResource then return false end
    local ctx = buildEMSMDTUnitContext(src)
    if desiredStatus and desiredStatus ~= '' then
        ctx.status = desiredStatus
    end
    if not desiredDuty and force == true then
        ctx.forceOffDuty = true
    end
    local ok = pcall(function()
        exports[mdtResource]:SetDutyStateFromExternal(src, desiredDuty, ctx)
    end)
    if ok then
        lastMDTDutySync[src] = desiredDuty
        if desiredStatus and desiredStatus ~= '' then
            lastMDTStatusSync[src] = desiredStatus
        end
    end
    return ok
end

local function attachCallToMDT(call, src)
    src = tonumber(src) or 0
    if not call or src <= 0 then return false end
    if not call.mdtCallId then
        syncCallToMDT(call)
    end
    if not call.mdtCallId then
        sdebug(('attachCallToMDT skipped; no MDT call id for EMS call %s'):format(tostring(call.id)))
        return false
    end
    local mdtResource = resolveMDTResourceName()
    if not mdtResource then return false end
    local ok, result = pcall(function()
        return exports[mdtResource]:AttachUnitToExternalCall(call.mdtCallId, src, true)
    end)
    if not ok or result == false then
        sdebug(('attachCallToMDT failed emsCall=%s mdtCall=%s src=%s err=%s'):format(tostring(call.id), tostring(call.mdtCallId), tostring(src), tostring(result)))
        return false
    end
    return true
end

local function detachCallFromMDT(call, src)
    src = tonumber(src) or 0
    if not call or src <= 0 or not call.mdtCallId then return false end
    local mdtResource = resolveMDTResourceName()
    if not mdtResource then return false end
    local ok, result = pcall(function()
        return exports[mdtResource]:DetachUnitFromExternalCall(call.mdtCallId, src)
    end)
    if not ok or result == false then
        sdebug(('detachCallFromMDT failed emsCall=%s mdtCall=%s src=%s err=%s'):format(tostring(call.id), tostring(call.mdtCallId), tostring(src), tostring(result)))
        return false
    end
    return true
end

local function syncCallToMDT(call, opts)
    if not (call and Config.MDT and Config.MDT.Enabled and Config.MDT.MirrorAcceptedCalls ~= false) then return end
    local mdtResource = resolveMDTResourceName()
    if not mdtResource then return end
    local payload = {
        caller = 'EMS Dispatch',
        message = buildMDTCallMessage(call),
        location = call.address or 'Unknown location',
        street = call.address or '',
        coords = call.coords or {},
        status = getCallMDTStatus(call),
        type = '911',
        kind = '911',
        source = 'Az-Ambulance',
        sourceResource = GetCurrentResourceName(),
        externalResource = GetCurrentResourceName(),
        metadata = { emsCallId = tostring(call.id or ''), callType = tostring(call.type or ''), street = tostring(call.address or '') },
        notify = opts and opts.notify == true,
        notificationTitle = 'EMS Dispatch',
        notificationType = 'call',
        notificationMessage = ('%s • %s'):format(tostring(call.title or 'Medical call'), tostring(call.address or 'Unknown location'))
    }
    if call.mdtCallId then
        pcall(function()
            exports[mdtResource]:UpdateExternalCall(call.mdtCallId, payload)
        end)
        return
    end
    local ok, result = pcall(function()
        return exports[mdtResource]:CreateExternalCall(payload)
    end)
    if ok and result then
        call.mdtCallId = tonumber(result) or result
        sdebug(('MDT mirror create ok emsCall=%s mdtCall=%s'):format(tostring(call.id), tostring(call.mdtCallId)))
    elseif not ok then
        sdebug(('MDT mirror create failed emsCall=%s err=%s'):format(tostring(call.id), tostring(result)))
    end
end

local function clearCallFromMDT(call)
    if not (call and call.mdtCallId) then return end
    local mdtResource = resolveMDTResourceName()
    if not mdtResource then return end
    pcall(function()
        exports[mdtResource]:DeleteExternalCall(call.mdtCallId)
    end)
    call.mdtCallId = nil
end

local function isResponderOnCall(call, src)
    return call and call.responders and call.responders[src] ~= nil
end

local function getResponderCount(call)
    local n = 0
    if call and call.responders then
        for _ in pairs(call.responders) do n = n + 1 end
    end
    return n
end

local function serializeCallFor(src, call)
    local responders = {}
    if call.responders then
        for responderSrc, info in pairs(call.responders) do
            responders[#responders+1] = {
                id = responderSrc,
                label = ('Unit %s'):format(responderSrc),
                status = info.status or 'ENROUTE'
            }
        end
    end
    table.sort(responders, function(a,b) return (a.id or 0) < (b.id or 0) end)

    return {
        id = call.id,
        type = call.type,
        title = call.title,
        details = call.details,
        address = call.address,
        coords = call.coords,
        patientNetId = call.patientNetId,
        vitals = call.vitals,
        assigned = call.assigned,
        assignedLabel = call.assignedLabel,
        responderCount = getResponderCount(call),
        responders = responders,
        myStatus = call.responders and call.responders[src] and call.responders[src].status or nil,
        myAttached = isResponderOnCall(call, src),
        cprRequired = call.cprRequired,
        cprDone = call.cprDone,
        cprOk = call.cprOk,
    }
end

local function sendCallBoardSnapshot(src)
    local payload = {}
    for _, call in pairs(activeCalls) do
        payload[#payload+1] = serializeCallFor(src, call)
    end
    table.sort(payload, function(a,b) return (a.id or 0) < (b.id or 0) end)
    TriggerClientEvent('az_ambulance:callBoardData', src, payload)
end

local function broadcastCallBoard()
    for src, on in pairs(emsDuty) do
        if on then
            sendCallBoardSnapshot(src)
        end
    end
end

local function allowedJob(source)
    if source == 0 then return true end
    local job = Config.GetPlayerJob(source)
    local j   = job and string.lower(job) or 'civ'
    local ok  = Config.EMSJobs[j] == true
    sdebug('allowedJob src='..tostring(source)..' job='..tostring(j)..' -> '..tostring(ok))
    return ok
end

local function syncJobAllowed(src)
    local ok = allowedJob(src)
    TriggerClientEvent('az_ambulance:setJobAllowed', src, ok)
    sdebug(('syncJobAllowed -> src=%s job=%s ok=%s'):format(
        tostring(src),
        tostring(Config.GetPlayerJob(src)),
        tostring(ok)
    ))
end

RegisterNetEvent('az_ambulance:requestJobAllowed', function()
    pushJobState(source)
end)

local function detachResponderFromAllCalls(src, keepCallOpen)
    src = tonumber(src)
    if not src then return end

    for callId, call in pairs(activeCalls) do
        if isResponderOnCall(call, src) then
            detachCallFromMDT(call, src)
            call.responders[src] = nil

            if call.assigned == src then
                call.assigned, call.assignedLabel = nil, nil
                for responderSrc, _ in pairs(call.responders or {}) do
                    call.assigned = responderSrc
                    call.assignedLabel = ('Unit %s'):format(responderSrc)
                    break
                end
            end

            if (not keepCallOpen) and getResponderCount(call) == 0 then
                clearCallFromMDT(call)
                activeCalls[callId] = nil
                for targetSrc, on in pairs(emsDuty) do
                    if on and allowedJob(targetSrc) then
                        TriggerClientEvent('az_ambulance:callRemoved', targetSrc, callId)
                    end
                end
            end
        end
    end
end

pushJobState = function(src, opts)
    src = tonumber(src)
    if not src or src == 0 then return end
    opts = type(opts) == 'table' and opts or {}

    local ok = allowedJob(src)
    local onDuty = emsDuty[src] == true
    TriggerClientEvent('az_ambulance:setJobAllowed', src, ok)

    if not ok and onDuty then
        emsDuty[src] = nil
        emsDutyDepartment[src] = nil
        detachResponderFromAllCalls(src, true)
        setPlayerEMSState(src, false, false)
        lastMDTDutySync[src] = nil
        lastMDTStatusSync[src] = nil
        syncDutyStateToMDT(src, false, 'OFFDUTY', true)
        syncUnitStatusToMDT(src, 'OFFDUTY', true)
        TriggerClientEvent('az_ambulance:setDuty', src, false)
        TriggerClientEvent('az_ambulance:callBoardData', src, {})
        TriggerClientEvent('az_ambulance:notify', src, { kind = 'error', text = 'You lost your EMS job and were forced off duty.', duration = 7000, durationMs = 7000 })
        broadcastCallBoard()
        return
    end

    if ok and onDuty then
        reconcileEMSResponderWithMDT(src)
    end

    TriggerClientEvent('az_ambulance:setDuty', src, onDuty)
    setPlayerEMSState(src, ok or onDuty, onDuty, emsDutyDepartment[src])

    if onDuty then
        syncUnitStatusToMDT(src, getEffectiveMDTUnitStatusForResponder(src), opts.forceSync == true)
    else
        if opts.forceOffDutySync == true or opts.revokeOnInvalidJob == true then
            syncDutyStateToMDT(src, false, 'OFFDUTY', opts.forceSync == true)
            syncUnitStatusToMDT(src, 'OFFDUTY', opts.forceSync == true)
        end
    end

    if ok and onDuty then
        sendCallBoardSnapshot(src)
    else
        TriggerClientEvent('az_ambulance:callBoardData', src, {})
    end
end

local function sendNotify(src, kind, text, durationMs)
    TriggerClientEvent('az_ambulance:notify', src, {
        kind       = kind or 'info',
        text       = text or '',
        duration   = durationMs,
        durationMs = durationMs
    })
end

local function hasAssignedCall(src)
    for _, call in pairs(activeCalls) do
        if isResponderOnCall(call, src) then return true end
    end
    return false
end

reconcileEMSResponderWithMDT = function(src)
    src = tonumber(src) or 0
    if src <= 0 or not emsDuty[src] or not allowedJob(src) then return end

    local attached = false
    for _, call in pairs(activeCalls) do
        if call and isResponderOnCall(call, src) then
            attached = true
            syncCallToMDT(call)
            attachCallToMDT(call, src)
            syncUnitStatusToMDT(src, getEffectiveMDTUnitStatusForResponder(src))
        end
    end

    if not attached then
        syncUnitStatusToMDT(src, getEffectiveMDTUnitStatusForResponder(src))
    end
end

local function queueEMSMDTReconcile(src, callId, delayMs)
    src = tonumber(src) or 0
    local waitMs = math.max(100, tonumber(delayMs) or 500)
    if src <= 0 then return end
    SetTimeout(waitMs, function()
        if GetPlayerPing(src) <= 0 or not emsDuty[src] or not allowedJob(src) then return end
        local call = callId and activeCalls[tonumber(callId) or 0] or nil
        if call and isResponderOnCall(call, src) then
            syncCallToMDT(call)
            attachCallToMDT(call, src)
            syncUnitStatusToMDT(src, getEffectiveMDTUnitStatusForResponder(src))
        else
            reconcileEMSResponderWithMDT(src)
        end
    end)
end

local function getRandomEMS()
    local list = {}
    for src, on in pairs(emsDuty) do
        if on and not hasAssignedCall(src) then
            list[#list+1] = src
        end
    end
    if #list == 0 then return nil end
    local chosen = list[math.random(1, #list)]
    sdebug('getRandomEMS -> chose '..tostring(chosen))
    return chosen
end

local function hasOnDutyEMS()
    for _, on in pairs(emsDuty) do
        if on then return true end
    end
    return false
end

local function countActiveCalls()
    local n = 0
    for _, _ in pairs(activeCalls) do n = n + 1 end
    return n
end

local function makeRandomVitals(templateType)
    local desc
    local state = 'unstable'

    if templateType == 'DRUNK' then
        desc  = 'Disoriented adult, strong alcohol smell, bystanders report collapse.'
    elseif templateType == 'MVA' or templateType == 'MVA_MINOR' then
        desc  = 'Vehicle collision; patient complaining of neck/back pain.'
    elseif templateType == 'MVA_MAJOR' then
        desc  = 'High-speed collision, multiple injuries, possible internal bleeding.'
        state = 'critical'
    elseif templateType == 'GSW' then
        desc  = 'Gunshot wound with severe bleeding. Control hemorrhage immediately.'
        state = 'critical'
    elseif templateType == 'CARDIAC' then
        desc  = 'Unresponsive patient in cardiac arrest. Begin CPR immediately.'
        state = 'cardiac_arrest'
    else
        desc  = 'Adult patient, unknown history, unwell.'
    end

    return {
        description = desc,
        heartRate   = math.random(60, 130),
        systolic    = math.random(90, 160),
        diastolic   = math.random(60, 100),
        respRate    = math.random(10, 26),
        spo2        = math.random(88, 99),
        gcs         = math.random(8, 15),
        state       = state,
    }
end

local function getOnDutyEMSCoords()
    local coords = {}
    for src, on in pairs(emsDuty) do
        if on then
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then
                coords[#coords+1] = GetEntityCoords(ped)
            end
        end
    end
    return coords
end

local function getOnDutyEMSSources()
    local list = {}
    for src, on in pairs(emsDuty) do
        if on and allowedJob(src) then
            list[#list + 1] = src
        end
    end
    table.sort(list)
    return list
end

local function isFarEnoughFromAllEMS(testPos, minDist)
    local emsList = getOnDutyEMSCoords()
    if #emsList == 0 then return true end

    for _, c in ipairs(emsList) do
        if #(testPos - c) < minDist then
            return false
        end
    end
    return true
end

local function unpackCalloutPoint(p)
    if type(p) == 'vector4' then
        return { x = p.x, y = p.y, z = p.z, heading = p.w or 0.0 }
    end
    if type(p) == 'table' then
        return { x = p.x, y = p.y, z = p.z, heading = p.heading or p.w or 0.0 }
    end
    return nil
end

local function getConfiguredCalloutPointPool()
    local pts = {}

    if type(Config.CalloutPoints) == 'table' then
        for _, raw in ipairs(Config.CalloutPoints) do
            local p = unpackCalloutPoint(raw)
            if p then
                pts[#pts + 1] = p
            end
        end
    end

    if #pts == 0 and type(Config.CalloutLocations) == 'table' then
        for _, group in pairs(Config.CalloutLocations) do
            if type(group) == 'table' then
                for _, raw in ipairs(group) do
                    local p = unpackCalloutPoint(raw)
                    if p then
                        pts[#pts + 1] = p
                    end
                end
            end
        end
    end

    return pts
end

local function pickFromConfiguredPoints()
    local pts = getConfiguredCalloutPointPool()
    if #pts == 0 then return nil end

    local minDist = Config.CalloutMinDistance or 800.0
    local tries   = Config.CalloutPickAttempts or 25

    for _ = 1, tries do
        local p = pts[math.random(1, #pts)]
        if p then
            local pos = vector3(p.x, p.y, p.z)
            if isFarEnoughFromAllEMS(pos, minDist) then
                return p
            end
        end
    end

    return pts[math.random(1, #pts)]
end

local function getCalloutValidatorSource(preferredSrc)
    preferredSrc = tonumber(preferredSrc)
    if preferredSrc and emsDuty[preferredSrc] and allowedJob(preferredSrc) then
        return preferredSrc
    end

    local pool = getOnDutyEMSSources()
    if #pool == 0 then return nil end
    return pool[math.random(1, #pool)]
end

local function requestValidatedCalloutFromClient(preferredSrc)
    local dynamicCfg = Config.DynamicCallouts or {}
    if dynamicCfg.Enabled == false then
        return nil
    end

    local validatorSrc = getCalloutValidatorSource(preferredSrc)
    if not validatorSrc then
        return nil
    end

    local ped = GetPlayerPed(validatorSrc)
    if not ped or ped == 0 then
        return nil
    end

    local anchor = GetEntityCoords(ped)
    local requestId = nextValidationRequestId
    nextValidationRequestId = nextValidationRequestId + 1

    pendingCalloutValidation[requestId] = {
        src = validatorSrc,
        done = false,
        result = nil,
    }

    TriggerClientEvent('az_ambulance:requestValidatedCalloutPoint', validatorSrc, requestId, {
        anchor = { x = anchor.x, y = anchor.y, z = anchor.z },
        minDist = Config.CalloutMinDistance or 800.0,
        maxDist = Config.CalloutMaxDistance or 3500.0,
        attempts = dynamicCfg.Attempts or Config.CalloutPickAttempts or 25,
        requireRoad = dynamicCfg.RequireRoad ~= false,
        useRoadBias = dynamicCfg.UseRoadBias ~= false,
        rejectWater = dynamicCfg.RejectWater ~= false,
    })

    local timeoutMs = dynamicCfg.TimeoutMs or 5000
    local started = GetGameTimer()

    while (GetGameTimer() - started) < timeoutMs do
        local state = pendingCalloutValidation[requestId]
        if state and state.done then
            local result = state.result
            pendingCalloutValidation[requestId] = nil
            return result
        end
        Wait(50)
    end

    pendingCalloutValidation[requestId] = nil
    return nil
end

RegisterNetEvent('az_ambulance:validatedCalloutPoint', function(requestId, point)
    local src = source
    requestId = tonumber(requestId)
    local state = requestId and pendingCalloutValidation[requestId] or nil
    if not state or state.src ~= src then
        return
    end

    if type(point) == 'table' and point.x and point.y and point.z then
        state.result = {
            x = point.x + 0.0,
            y = point.y + 0.0,
            z = point.z + 0.0,
            heading = (point.heading or point.w or 0.0) + 0.0,
        }
    else
        state.result = nil
    end

    state.done = true
end)

local function pickRandomFarPoint()
    local minDist = Config.CalloutMinDistance or 800.0
    local maxDist = Config.CalloutMaxDistance or 3500.0
    local tries   = Config.CalloutPickAttempts or 25

    local anchor = vector3(215.0, -810.0, 30.0)
    local emsList = getOnDutyEMSCoords()
    if #emsList > 0 then
        anchor = emsList[math.random(1, #emsList)]
    end

    for _ = 1, tries do
        local angle  = math.random() * math.pi * 2
        local radius = minDist + (math.random() * (maxDist - minDist))

        local x = anchor.x + math.cos(angle) * radius
        local y = anchor.y + math.sin(angle) * radius
        local z = anchor.z

        local pos = vector3(x, y, z)

        if isFarEnoughFromAllEMS(pos, minDist) then
            return {
                x = x,
                y = y,
                z = z,
                heading = math.random(0, 359) + 0.0
            }
        end
    end

    local angle  = math.random() * math.pi * 2
    local radius = minDist + ((maxDist - minDist) * 0.5)

    return {
        x = anchor.x + math.cos(angle) * radius,
        y = anchor.y + math.sin(angle) * radius,
        z = anchor.z,
        heading = 0.0
    }
end

local function pickRandomCallCoords(preferredSrc)
    local p = requestValidatedCalloutFromClient(preferredSrc)
    if p then return p end

    p = pickFromConfiguredPoints()
    if p then return p end

    return pickRandomFarPoint()
end

RegisterNetEvent('az_ambulance:registerPatientNet', function(callId, netId)
    local src = source
    if not allowedJob(src) then return end

    callId = tonumber(callId)
    netId  = tonumber(netId) or 0
    if not callId then return end

    local call = activeCalls[callId]
    if not call then
        sdebug('registerPatientNet -> no call for id='..tostring(callId))
        return
    end

    if not isResponderOnCall(call, src) then
        sdebug(('registerPatientNet ignored; src %s is not attached to call %s'):format(tostring(src), tostring(callId)))
        return
    end

    local existingNetId = tonumber(call.patientNetId) or 0
    if existingNetId > 0 and netId > 0 and existingNetId ~= netId then
        sdebug(('registerPatientNet ignored; callId=%s already has patientNetId=%s (src=%s tried %s)'):format(tostring(callId), tostring(existingNetId), tostring(src), tostring(netId)))
        if tonumber(call.sceneSpawnReservedBy) == src then
            call.sceneSpawnReservedBy = nil
            call.sceneSpawnReservedAt = nil
        end
        TriggerClientEvent('az_ambulance:updateCallPatient', src, callId, existingNetId)
        return
    end

    call.patientNetId = netId
    call.sceneSpawnReservedBy = nil
    call.sceneSpawnReservedAt = nil
    markEMSActivity(call, src, 'register_patient')
    sdebug(('registerPatientNet -> callId=%s netId=%s'):format(tostring(callId), tostring(netId)))

    TriggerClientEvent('az_ambulance:updateCallPatient', -1, callId, netId)
end)

local function normaliseUserCallType(t)
    t = (t or ''):upper()

    if t == 'MVA' then
        return 'MVA', 'Motor vehicle accident'
    elseif t == 'GSW' then
        return 'GSW', 'Gunshot wound'
    elseif t == 'CARDIAC' or t == 'CARDIAC ARREST'
        or t == 'CARDIACT' or t == 'CARDIACT ARREST' then
        return 'CARDIAC', 'Cardiac arrest'
    else
        return 'DRUNK', 'Medical emergency'
    end
end

local function createUserEMSCall(src, rawType, description)
    if src == 0 then return end

    if not hasOnDutyEMS() then
        sendNotify(src, 'error', 'No EMS units are currently on duty.', 6000)
        return
    end

    local activeCount = countActiveCalls()
    local maxCalls    = Config.MaxSimultaneousCalls or 3
    if activeCount >= maxCalls then
        sendNotify(src, 'error', 'EMS is currently dealing with other emergencies.', 6000)
        return
    end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end

    local x, y, z = table.unpack(GetEntityCoords(ped))

    local callType, title = normaliseUserCallType(rawType)
    local callId = nextCallId
    nextCallId   = nextCallId + 1

    local nowMs = GetGameTimer()

    local call = {
        id           = callId,
        type         = callType,
        title        = title,
        details      = description or '',
        address      = 'Unknown address',
        coords       = { x = x, y = y, z = z, heading = GetEntityHeading(ped) },
        patientNetId = 0,
        vitals       = makeRandomVitals(callType),

        cprRequired  = (callType == 'CARDIAC'),
        cprDone      = false,
        cprQuality   = 0,
        cprOk        = false,

        noScene      = true,

        assigned     = nil,
        assignedLabel= nil,
        createdAt    = os.time(),
        createdAtMs  = nowMs,
        callerSrc    = src,

        acceptAtMs   = 0,
        acceptPos    = nil,
        onSceneAtMs  = 0,
        transportAtMs= 0,
        transportHosp= nil,
        transportHospPos = nil,

        patients     = {},
        patientCount = 0,

        transportPaid = false,
        responders    = {},
    }

    activeCalls[callId] = call
    syncCallToMDT(call, { notify = true })

    for emsSrc, on in pairs(emsDuty) do
        if on then
            TriggerClientEvent('az_ambulance:newCallout', emsSrc, serializeCallFor(emsSrc, call))
        end
    end
    broadcastCallBoard()

    sendNotify(src, 'success', 'EMS has been notified of your emergency.', 6000)
end

RegisterNetEvent('az_ambulance:userEMSCall', function(callType, description)
    local src = source
    sdebug(('userEMSCall from src=%d type=%s'):format(src, tostring(callType)))
    if not allowedJob(src) then return end
    createUserEMSCall(src, callType, description)
end)

RegisterNetEvent('az_ambulance:denyCallout', function(callId)
    local src  = source
    if not allowedJob(src) then return end

    local call = activeCalls[callId]
    if not call then
        sendNotify(src, 'error', 'Call no longer active.', 4000)
        return
    end

    call.declined      = call.declined or {}
    call.declined[src] = true

    sendNotify(src, 'info', ('You denied call %s.'):format(callId), 4000)
end)

local callTemplates = {
    { type = 'DRUNK',     title = 'Drunk person down',      detail = 'Caller reports an intoxicated person collapsed on the sidewalk.' },
    { type = 'MVA_MINOR', title = 'Minor vehicle accident', detail = 'Low-speed collision, one patient complaining of pain.' },
    { type = 'MVA_MAJOR', title = 'Major vehicle accident', detail = 'Serious crash with significant damage, injuries unknown.' },
    { type = 'CARDIAC',   title = 'Unresponsive patient',   detail = 'Caller reports patient not breathing, CPR may be required.' }
}

local function createRandomCall(preferredSrc)
    local targetSrc = preferredSrc

    if not targetSrc or targetSrc == 0 then
        targetSrc = getRandomEMS()
        if not targetSrc then return end
    else
        if hasAssignedCall(targetSrc) then
            sendNotify(targetSrc, 'info', 'You already have an active EMS call.', 6000)
            return
        end
    end

    if not allowedJob(targetSrc) then return end
    if not emsDuty[targetSrc] then
        sendNotify(targetSrc, 'error', 'You must be on EMS duty. Use /ems_duty.', 6000)
        return
    end

    local activeCount = countActiveCalls()
    local maxCalls    = Config.MaxSimultaneousCalls or 3
    if activeCount >= maxCalls then return end

    local coords = pickRandomCallCoords(targetSrc)

    if not coords then
        local ped = GetPlayerPed(targetSrc)
        if not ped or ped == 0 then return end
        local p = GetEntityCoords(ped)
        coords = { x = p.x + 1200.0, y = p.y + 1200.0, z = p.z, heading = 0.0 }
    end

    local tpl = callTemplates[math.random(1, #callTemplates)]

    local callId = nextCallId
    nextCallId   = nextCallId + 1

    local nowMs = GetGameTimer()

    local call = {
        id           = callId,
        type         = tpl.type,
        title        = tpl.title,
        details      = tpl.detail,
        address      = 'Unknown address',
        coords       = coords,
        patientNetId = 0,
        vitals       = makeRandomVitals(tpl.type),

        cprRequired  = (tpl.type == 'CARDIAC'),
        cprDone      = false,
        cprQuality   = 0,
        cprOk        = false,

        assigned     = nil,
        assignedLabel= nil,
        createdAt    = os.time(),
        createdAtMs  = nowMs,

        acceptAtMs   = 0,
        acceptPos    = nil,
        onSceneAtMs  = 0,
        transportAtMs= 0,
        transportHosp= nil,
        transportHospPos = nil,

        patients     = {},
        patientCount = 0,

        transportPaid = false,
        responders    = {},
    }

    activeCalls[callId] = call
    syncCallToMDT(call, { notify = true })

    for src, on in pairs(emsDuty) do
        if on then
            TriggerClientEvent('az_ambulance:newCallout', src, serializeCallFor(src, call))
        end
    end
    broadcastCallBoard()

    sdebug(('createRandomCall -> id=%s type=%s minDist=%.1f')
        :format(tostring(callId), tostring(tpl.type), (Config.CalloutMinDistance or 0.0)))
end

AddEventHandler('playerJoining', function()
    local src = source
    SetTimeout(1500, function()
        if GetPlayerPing(src) > 0 then
            pushJobState(src)
        end
    end)
end)

RegisterNetEvent('Az-Framework:jobChanged', function(changedSrc)
    local src = tonumber(changedSrc) or tonumber(source)
    if not src or src <= 0 then return end
    pushJobState(src)
end)

CreateThread(function()
    local interval = math.max(2000, tonumber(Config.JobSyncIntervalMs) or 5000)
    while true do
        Wait(interval)
        for _, src in ipairs(GetPlayers()) do
            pushJobState(tonumber(src))
        end
    end
end)


local function setEMSDutyState(src, desiredState, silent, selectedDepartment)
    src = tonumber(src) or 0
    if src <= 0 then return false end
    if not allowedJob(src) then
        if not silent then
            sendNotify(src, 'error', 'You are not allowed to use EMS systems.', 6000)
        end
        return false
    end

    local jobLower = tostring(Config.GetPlayerJob(src) or 'unknown'):lower()
    if not Config.EMSJobs[jobLower] then
        if not silent then
            sendNotify(src, 'error', 'You are not EMS. Job: '..tostring(jobLower), 6000)
        end
        return false
    end

    desiredState = desiredState == true
    emsDuty[src] = desiredState
    if desiredState then
        local chosen = tostring(selectedDepartment or emsDutyDepartment[src] or jobLower or 'ems'):lower()
        if chosen == '' then chosen = 'ems' end
        emsDutyDepartment[src] = chosen
    else
        emsDutyDepartment[src] = nil
        detachResponderFromAllCalls(src, true)
    end

    pushJobState(src, { forceSync = true, forceOffDutySync = not desiredState })
    if desiredState then
        syncDutyStateToMDT(src, true, getEffectiveMDTUnitStatusForResponder(src), true)
        queueEMSMDTReconcile(src, nil, 250)
        queueEMSMDTReconcile(src, nil, 1000)
        queueEMSMDTReconcile(src, nil, 2500)
        queueEMSMDTReconcile(src, nil, 5000)
        queueEMSMDTReconcile(src, nil, 8000)
    else
        syncDutyStateToMDT(src, false, 'OFFDUTY', true)
    end
    broadcastCallBoard()

    sdebug('setEMSDutyState -> emsDuty['..src..']='..tostring(desiredState)..' dept='..tostring(emsDutyDepartment[src]))
    return true
end

local function toggleEMSDuty(src)
    if src == 0 then
        print('[Az-Ambulance] Console cannot toggle duty.')
        return
    end
    return setEMSDutyState(src, not emsDuty[src], false)
end

RegisterCommand('ems_duty', function(src)
    if src ~= 0 and resolveMDTResourceName() then
        sendNotify(src, 'info', 'Use Az-MDT to go on/off duty for EMS.', 5000)
        return
    end
    if src ~= 0 and not allowedJob(src) then return end
    toggleEMSDuty(src)
end, false)

RegisterNetEvent('az_ambulance:toggleDuty', function()
    local src = source
    if resolveMDTResourceName() then
        sendNotify(src, 'info', 'Use Az-MDT to go on/off duty for EMS.', 5000)
        return
    end
    if not allowedJob(src) then return end
    toggleEMSDuty(src)
end)

RegisterNetEvent('az_ambulance:setDutyState', function(desiredState, selectedDepartment)
    local src = source
    if resolveMDTResourceName() then
        sendNotify(src, 'info', 'Use Az-MDT to go on/off duty for EMS.', 5000)
        return
    end
    setEMSDutyState(src, desiredState == true, true, selectedDepartment)
end)

RegisterNetEvent('az_ambulance:statusUpdate', function(newStatus, callId)
    local src = source
    if not allowedJob(src) then return end
    if not emsDuty[src] then return end
    newStatus = tostring(newStatus or 'AVAILABLE'):upper()
    callId = tonumber(callId)
    if callId and activeCalls[callId] and isResponderOnCall(activeCalls[callId], src) then
        activeCalls[callId].responders[src].status = newStatus
        markEMSActivity(activeCalls[callId], src, 'status_update', { contributed = false })
        if newStatus == 'ONSCENE' and (not activeCalls[callId].onSceneAtMs or activeCalls[callId].onSceneAtMs <= 0) then
            activeCalls[callId].onSceneAtMs = GetGameTimer()
            markEMSActivity(activeCalls[callId], src, 'on_scene')
        elseif newStatus == 'TRANSPORT' then
            markEMSActivity(activeCalls[callId], src, 'transport_started')
        end
        syncCallToMDT(activeCalls[callId])
        syncUnitStatusToMDT(src, newStatus)
        broadcastCallBoard()
    end
    sdebug(('statusUpdate src=%d -> %s callId=%s'):format(src, tostring(newStatus), tostring(callId)))
end)

local function tryReserveSceneSpawn(call, src)
    if not call or not src then return false end
    if (tonumber(call.patientNetId) or 0) > 0 then return false end

    local now = GetGameTimer()
    local ttl = math.max(2000, tonumber(Config.CallSceneSpawnReserveMs) or 8000)
    local reservedBy = tonumber(call.sceneSpawnReservedBy) or 0
    local reservedAt = tonumber(call.sceneSpawnReservedAt) or 0
    local reserveExpired = reservedBy == 0 or reservedBy == src or (reservedAt > 0 and (now - reservedAt) >= ttl) or (reservedBy > 0 and not emsDuty[reservedBy])

    if not reserveExpired then
        return false
    end

    call.sceneSpawnReservedBy = src
    call.sceneSpawnReservedAt = now
    return true
end

RegisterNetEvent('az_ambulance:acceptCallout', function(callId, derivedAddress)
    local src  = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)

    local call = activeCalls[callId]
    if not call then
        sendNotify(src, 'error', 'Call no longer active.', 4000)
        return
    end

    if not emsDuty[src] then
        sendNotify(src, 'error', 'You must be on EMS duty.', 4000)
        return
    end

    if isResponderOnCall(call, src) then
        sdebug('acceptCallout ignored; src '..src..' already attached to call '..callId)
        syncCallToMDT(call)
        attachCallToMDT(call, src)
        queueEMSMDTReconcile(src, callId, 350)
        queueEMSMDTReconcile(src, callId, 1200)
        queueEMSMDTReconcile(src, callId, 2500)
        queueEMSMDTReconcile(src, callId, 5000)
        queueEMSMDTReconcile(src, callId, 8000)
        local serializedCall = serializeCallFor(src, call)
        TriggerClientEvent('az_ambulance:callAccepted', src, serializedCall)
        if tryReserveSceneSpawn(call, src) then
            TriggerClientEvent('az_ambulance:spawnSceneForCall', src, serializedCall)
        end
        broadcastCallBoard()
        return
    end

    if hasAssignedCall(src) then
        sendNotify(src, 'error', 'You already have an active EMS call.', 4000)
        return
    end

    local cleanAddress = mdtTrim(derivedAddress)
    if cleanAddress ~= '' and cleanAddress:lower() ~= 'unknown address' and cleanAddress:lower() ~= 'unknown location' then
        call.address = cleanAddress
    end

    call.responders = call.responders or {}
    call.responders[src] = call.responders[src] or { status = 'ENROUTE', joinedAt = os.time() }
    call.responders[src].status = call.responders[src].status or 'ENROUTE'
    markEMSActivity(call, src, 'attached', { contributed = false })

    if not call.assigned then
        call.assigned      = src
        call.assignedLabel = ('Unit %s'):format(src)
        call.acceptAtMs = GetGameTimer()
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local p = GetEntityCoords(ped)
            call.acceptPos = { x = p.x, y = p.y, z = p.z }
        end
    end

    sdebug('acceptCallout -> call '..callId..' joined by '..src)

    
    
    syncUnitStatusToMDT(src, 'ENROUTE')
    syncCallToMDT(call)
    attachCallToMDT(call, src)
    queueEMSMDTReconcile(src, callId, 350)
    queueEMSMDTReconcile(src, callId, 1200)
    queueEMSMDTReconcile(src, callId, 2500)
    queueEMSMDTReconcile(src, callId, 5000)
    queueEMSMDTReconcile(src, callId, 8000)

    local serializedCall = serializeCallFor(src, call)
    TriggerClientEvent('az_ambulance:callAccepted', src, serializedCall)
    if tryReserveSceneSpawn(call, src) then
        TriggerClientEvent('az_ambulance:spawnSceneForCall', src, serializedCall)
    end
    sendNotify(src, 'success', ('Attached to EMS call %s.'):format(callId), 4000)
    broadcastCallBoard()
end)

RegisterNetEvent('az_ambulance:detachCall', function(callId)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    if not call or not isResponderOnCall(call, src) then return end
    call.responders[src] = nil
    if (tonumber(call.patientNetId) or 0) <= 0 and tonumber(call.sceneSpawnReservedBy) == src then
        call.sceneSpawnReservedBy = nil
        call.sceneSpawnReservedAt = nil
    end
    if call.assigned == src then
        call.assigned, call.assignedLabel = nil, nil
        for responderSrc, _ in pairs(call.responders or {}) do
            call.assigned = responderSrc
            call.assignedLabel = ('Unit %s'):format(responderSrc)
            break
        end
    end
    detachCallFromMDT(call, src)
    syncCallToMDT(call)
    syncUnitStatusToMDT(src, 'AVAILABLE')
    TriggerClientEvent('az_ambulance:callDetached', src, callId)
    sendNotify(src, 'info', ('Detached from EMS call %s.'):format(callId), 4000)
    broadcastCallBoard()
end)

RegisterNetEvent('az_ambulance:closeCall', function(callId)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    if not call or not isResponderOnCall(call, src) then
        sendNotify(src, 'error', 'You are not attached to that call.', 4000)
        return
    end
    clearCall(callId, 'EMS call closed.')
end)

RegisterNetEvent('az_ambulance:forceCancelCall', function(callId)
    local src = source
    if not allowedJob(src) then return end
    if not emsDuty[src] then
        sendNotify(src, 'error', 'You must be on EMS duty.', 4000)
        return
    end

    callId = tonumber(callId)
    if not callId then
        for id, call in pairs(activeCalls) do
            if isResponderOnCall(call, src) then
                callId = id
                break
            end
        end
    end

    local call = callId and activeCalls[callId] or nil
    if not call then
        sendNotify(src, 'error', 'No active EMS call found to force cancel.', 4000)
        return
    end

    clearCall(callId, ('Force cancelled by Unit %s.'):format(src))
    sendNotify(src, 'warning', ('Force cancelled EMS call %s.'):format(callId), 4500)
end)

local function clearCall(callId, reason)
    local call = activeCalls[callId]
    if not call then return end

    if call.responders then
        for responderSrc in pairs(call.responders) do
            syncUnitStatusToMDT(responderSrc, 'AVAILABLE')
        end
    end

    clearCallFromMDT(call)

    for src, _ in pairs(emsDuty) do
        TriggerClientEvent('az_ambulance:callCleared', src, callId, reason or 'cleared')
    end

    activeCalls[callId] = nil
    broadcastCallBoard()
end

RegisterCommand('ems_clearcall', function(src)
    if src == 0 then
        print('[Az-Ambulance] Use in-game to clear calls.')
        return
    end
    if not allowedJob(src) then return end
    if not emsDuty[src] then
        sendNotify(src, 'error', 'You are not EMS on duty.', 4000)
        return
    end

    local callId
    for id, call in pairs(activeCalls) do
        if isResponderOnCall(call, src) then callId = id break end
    end

    if not callId then
        sendNotify(src, 'info', 'You have no active call to clear.', 4000)
        return
    end

    clearCall(callId, 'Unit cleared call.')
end, false)

RegisterCommand('ems_forcecancel', function(src, args)
    if src == 0 then
        print('[Az-Ambulance] Use in-game to force cancel calls.')
        return
    end
    if not allowedJob(src) then return end
    if not emsDuty[src] then
        sendNotify(src, 'error', 'You are not EMS on duty.', 4000)
        return
    end

    local callId = tonumber(args and args[1])
    if not callId then
        for id, call in pairs(activeCalls) do
            if isResponderOnCall(call, src) then
                callId = id
                break
            end
        end
    end

    if not callId or not activeCalls[callId] then
        sendNotify(src, 'error', 'No active EMS call found to force cancel.', 4000)
        return
    end

    clearCall(callId, ('Force cancelled by Unit %s.'):format(src))
    sendNotify(src, 'warning', ('Force cancelled EMS call %s.'):format(callId), 4500)
end, false)


local function normalisePayType(callType)
    callType = (callType or ''):upper()
    if callType == 'MVA_MINOR' or callType == 'MVA_MAJOR' then return callType end
    if callType == 'MVA' then return 'MVA' end
    if callType == 'CARDIAC' or callType == 'CARDIAC ARREST' then return 'CARDIAC' end
    if callType == 'GSW' then return 'GSW' end
    if callType == 'DRUNK' then return 'DRUNK' end
    return callType
end

local function clamp(n, a, b)
    if n < a then return a end
    if n > b then return b end
    return n
end

local function calcBonusBySpeed(seconds, target, maxBonus)
    if not seconds or seconds <= 0 then return 0 end
    if not target or target <= 0 then return 0 end
    if not maxBonus or maxBonus <= 0 then return 0 end
    local ratio = clamp(target / seconds, 0.0, 2.0)
    local bonus = (ratio - 1.0) * maxBonus
    if bonus < 0 then bonus = 0 end
    return math.floor(bonus + 0.5)
end

local function calcDistancePay(meters, perKm, maxPay)
    if not meters or meters <= 0 then return 0 end
    if not perKm or perKm <= 0 then return 0 end
    local km = meters / 1000.0
    local v = km * perKm
    if maxPay and maxPay > 0 then
        v = math.min(v, maxPay)
    end
    return math.floor(v + 0.5)
end

local function vec3from(pos)
    if not pos then return nil end
    return vector3(pos.x or 0.0, pos.y or 0.0, pos.z or 0.0)
end

local function ensureEMSActivityEntry(call, src)
    if not call or not src then return nil end
    local sid = tonumber(src) or src
    call.activity = call.activity or {}
    local entry = call.activity[sid]
    if not entry then
        entry = { joinedAt = os.time(), actions = {}, contributed = false }
        call.activity[sid] = entry
    end
    return entry
end

local function markEMSActivity(call, src, action, opts)
    local entry = ensureEMSActivityEntry(call, src)
    if not entry then return end
    opts = type(opts) == 'table' and opts or {}
    action = tostring(action or '')
    if action ~= '' then
        entry.actions[action] = true
    end
    if opts.contributed ~= false and action ~= '' and action ~= 'attached' and action ~= 'status_update' then
        entry.contributed = true
    elseif opts.contributed == true then
        entry.contributed = true
    end
    entry.lastAt = os.time()
end

local function hasEMSContribution(call, src)
    if not call or not call.activity or not src then return false end
    local entry = call.activity[tonumber(src) or src]
    if not entry then return false end
    if entry.contributed == true then return true end
    local actions = entry.actions or {}
    return actions.on_scene == true
        or actions.register_patient == true
        or actions.vitals == true
        or actions.cpr == true
        or actions.patient_loaded == true
        or actions.transport_started == true
        or actions.transport_completed == true
end

local function buildEMSPayoutRecipients(call, leadSrc)
    local recipients, seen = {}, {}
    local function push(src, role)
        src = tonumber(src) or 0
        if src <= 0 or seen[src] then return end
        seen[src] = true
        recipients[#recipients + 1] = { src = src, role = role }
    end

    push(leadSrc, 'primary')
    for responderSrc in pairs((call and call.responders) or {}) do
        if responderSrc ~= leadSrc and hasEMSContribution(call, responderSrc) then
            push(responderSrc, 'assist')
        end
    end

    if #recipients == 0 and leadSrc then
        push(leadSrc, 'primary')
    end

    table.sort(recipients, function(a, b) return (a.src or 0) < (b.src or 0) end)
    return recipients
end

local function calcTransportPayout(call)
    if not Config.Payments or Config.Payments.Enabled == false then
        return 0, {}
    end

    local p = Config.Payments
    local t = normalisePayType(call and call.type)
    local base = (p.BaseByType and p.BaseByType[t]) or p.DefaultBase or 0

    local patientCount = tonumber(call and call.patientCount) or 0
    if patientCount <= 0 then patientCount = 1 end
    local extraPatients = math.max(0, patientCount - 1)
    local patientPay = extraPatients * (p.PerExtraPatient or 0)

    local callPos = call and call.coords and vector3(call.coords.x or 0.0, call.coords.y or 0.0, call.coords.z or 0.0) or nil
    local acceptPos = vec3from(call and call.acceptPos)
    local hospPos = vec3from(call and call.transportHospPos)

    local responseDist = 0.0
    if callPos and acceptPos then
        responseDist = #(acceptPos - callPos)
    end

    local transportDist = 0.0
    if callPos and hospPos then
        transportDist = #(callPos - hospPos)
    end

    local responsePay = calcDistancePay(responseDist, p.Distance and p.Distance.ResponsePerKm, p.Distance and p.Distance.ResponseMax)
    local transportPay = calcDistancePay(transportDist, p.Distance and p.Distance.TransportPerKm, p.Distance and p.Distance.TransportMax)

    local acceptAt = tonumber(call and call.acceptAtMs) or 0
    local onSceneAt = tonumber(call and call.onSceneAtMs) or 0
    local doneAt = GetGameTimer()

    local responseSec = 0
    if acceptAt > 0 and onSceneAt > 0 and onSceneAt >= acceptAt then
        responseSec = (onSceneAt - acceptAt) / 1000.0
    end

    local completionSec = 0
    if acceptAt > 0 and doneAt >= acceptAt then
        completionSec = (doneAt - acceptAt) / 1000.0
    end

    local responseSpeedBonus = calcBonusBySpeed(responseSec, p.Speed and p.Speed.ResponseTargetSec, p.Speed and p.Speed.ResponseMaxBonus)
    local completionSpeedBonus = calcBonusBySpeed(completionSec, p.Speed and p.Speed.CompletionTargetSec, p.Speed and p.Speed.CompletionMaxBonus)

    local cprBonus = 0
    if p.CPR and p.CPR.Enabled and (call and (call.type or ''):upper() == 'CARDIAC') then
        local q = tonumber(call and call.cprQuality) or 0
        local minQ = tonumber(p.CPR.MinQuality) or 0
        if q >= minQ then
            cprBonus = (q - minQ) * (tonumber(p.CPR.PerQualityPoint) or 0)
            cprBonus = math.floor(cprBonus + 0.5)
            if p.CPR.MaxBonus and p.CPR.MaxBonus > 0 then
                cprBonus = math.min(cprBonus, p.CPR.MaxBonus)
            end
        end
    end

    local total = base + patientPay + responsePay + transportPay + responseSpeedBonus + completionSpeedBonus + cprBonus
    total = clamp(total, p.MinPay or 0, p.MaxPay or 999999)

    local breakdown = {
        base = base,
        patients = patientPay,
        responseDist = math.floor(responseDist + 0.5),
        responsePay = responsePay,
        transportDist = math.floor(transportDist + 0.5),
        transportPay = transportPay,
        responseSec = math.floor(responseSec + 0.5),
        responseSpeed = responseSpeedBonus,
        completionSec = math.floor(completionSec + 0.5),
        completionSpeed = completionSpeedBonus,
        cpr = cprBonus,
        total = total,
        patientCount = patientCount,
    }

    return total, breakdown
end

local function payEMSTransport(src, call, amount, breakdown, payoutRole)
    local total = tonumber(amount) or 0
    local b = breakdown or {}
    payoutRole = tostring(payoutRole or 'primary')

    if total <= 0 then
        sdebug('payEMSTransport -> amount <= 0, skipping for src='..tostring(src))
        return
    end

    fw:addMoney(src, total)

    local msg
    if payoutRole == 'assist' then
        msg = ('EMS assist payout: $%d for helping complete call %s.'):format(total, tostring(call and call.id or '?'))
    else
        msg = ('Transport complete! $%d | Base %d | Pts %d(+%d) | Resp %dm $%d +%ds $%d | Trans %dm $%d | Speed +%d | CPR +%d')
            :format(
                total,
                b.base or 0,
                b.patientCount or 1,
                b.patients or 0,
                b.responseDist or 0,
                b.responsePay or 0,
                b.responseSec or 0,
                b.responseSpeed or 0,
                b.transportDist or 0,
                b.transportPay or 0,
                (b.completionSpeed or 0),
                (b.cpr or 0)
            )
    end

    sendNotify(src, 'success', msg, 9000)
    sdebug(('Paid EMS transport -> src=%d amount=%d role=%s callId=%s type=%s')
        :format(src, total, payoutRole, tostring(call and call.id), tostring(call and call.type)))
end

local function payEMSTransportTeam(call, leadSrc)
    local amount, breakdown = calcTransportPayout(call)
    if amount <= 0 then
        sdebug('payEMSTransportTeam -> amount <= 0, skipping')
        return
    end

    local recipients = buildEMSPayoutRecipients(call, leadSrc)
    local primaryMultiplier = clamp(tonumber(Config.Payments and Config.Payments.PrimaryMultiplier) or 1.0, 0.0, 5.0)
    local assistMultiplier = clamp(tonumber(Config.Payments and Config.Payments.AssistMultiplier) or 0.65, 0.0, 5.0)

    for _, recipient in ipairs(recipients) do
        local multiplier = recipient.role == 'assist' and assistMultiplier or primaryMultiplier
        local payout = math.floor((amount * multiplier) + 0.5)
        if payout > 0 then
            payEMSTransport(recipient.src, call, payout, breakdown, recipient.role)
        end
    end
end

RegisterNetEvent('az_ambulance:onScene', function(callId)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    if not call then return end
    if not isResponderOnCall(call, src) then return end
    if call.onSceneAtMs and call.onSceneAtMs > 0 then return end
    call.onSceneAtMs = GetGameTimer()
    markEMSActivity(call, src, 'on_scene')
    sdebug(('onScene callId=%s src=%s'):format(tostring(callId), tostring(src)))
end)

RegisterNetEvent('az_ambulance:patientLoaded', function(callId, patientNetId)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    patientNetId = tonumber(patientNetId) or 0
    local call = callId and activeCalls[callId] or nil
    if not call then return end
    if not isResponderOnCall(call, src) then return end
    if patientNetId <= 0 then return end

    call.patients = call.patients or {}
    if not call.patients[patientNetId] then
        call.patients[patientNetId] = true
        local c = 0
        for _k, _v in pairs(call.patients) do c = c + 1 end
        call.patientCount = c
        markEMSActivity(call, src, 'patient_loaded')
        sdebug(('patientLoaded callId=%s src=%s netId=%s count=%s'):format(tostring(callId), tostring(src), tostring(patientNetId), tostring(c)))
    end
end)

RegisterNetEvent('az_ambulance:transportStart', function(callId, hospName, hx, hy, hz)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    if not call then return end
    if not isResponderOnCall(call, src) then return end

    if not call.transportAtMs or call.transportAtMs <= 0 then
        call.transportAtMs = GetGameTimer()
    end

    call.transportHosp = tostring(hospName or 'Hospital')
    call.transportHospPos = { x = tonumber(hx) or 0.0, y = tonumber(hy) or 0.0, z = tonumber(hz) or 0.0 }
    markEMSActivity(call, src, 'transport_started')

    sdebug(('transportStart callId=%s src=%s hosp=%s'):format(tostring(callId), tostring(src), tostring(call.transportHosp)))
end)

RegisterNetEvent('az_ambulance:completeTransport', function(callId)
    local src  = source
    if not allowedJob(src) then
        sdebug('completeTransport blocked: src not allowedJob')
        return
    end

    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    sdebug('completeTransport src='..tostring(src)..' callId='..tostring(callId))

    if not call then
        sdebug('completeTransport -> no call found')
        return
    end

    if not isResponderOnCall(call, src) then
        sdebug('completeTransport -> src not attached to this call')
        return
    end

    markEMSActivity(call, src, 'transport_completed')

    if call.transportPaid then
        sdebug('completeTransport -> already paid for callId='..tostring(callId))
        return
    end
    call.transportPaid = true

    if not call.patientCount or call.patientCount <= 0 then
        call.patientCount = 1
    end

    payEMSTransportTeam(call, src)
    clearCall(callId, 'Patient transported to hospital.')
end)

RegisterNetEvent('az_ambulance:requestVitals', function(callId, patientNetId)
    local src  = source
    if not allowedJob(src) then return end

    local call = activeCalls[callId]
    if not call then
        TriggerClientEvent('az_ambulance:vitalsData', src, nil)
        return
    end
    markEMSActivity(call, src, 'vitals')
    TriggerClientEvent('az_ambulance:vitalsData', src, call.vitals)
end)

RegisterNetEvent('az_ambulance:cprResult', function(callId, patientNetId, quality)
    local src  = source
    if not allowedJob(src) then return end

    local call = activeCalls[callId]
    if not call then return end

    quality = tonumber(quality) or 0
    local okThreshold = Config.CardiacCPRRequiredQuality or 60
    local cprOk = (quality >= okThreshold)

    local msg

    if call.type == 'CARDIAC' then
        call.cprDone    = true
        call.cprQuality = quality
        call.cprOk      = cprOk
        markEMSActivity(call, src, 'cpr')

        if cprOk then
            call.vitals.state = 'improving'
            msg = ('High-quality CPR (%d%%). ROSC achieved, patient improving.'):format(quality)
        else
            call.vitals.state = 'cardiac_arrest'
            msg = ('CPR quality %d%% – patient remains in cardiac arrest. Keep going.'):format(quality)
        end

        TriggerClientEvent('az_ambulance:updateCPRState', -1, callId, call.cprOk, call.cprQuality)
    else
        if quality >= 80 then
            call.vitals.state = 'improving'
            msg = ('High-quality CPR (%d%%). Patient improving.'):format(quality)
        elseif quality >= 50 then
            call.vitals.state = 'critical'
            msg = ('CPR (%d%%). Patient remains critical.'):format(quality)
        else
            call.vitals.state = 'poor'
            msg = ('Low-quality CPR (%d%%). Patient condition poor.'):format(quality)
        end
    end

    sendNotify(src, 'info', msg, 8000)
end)

local function runTestEMScall(src)
    if src == 0 then
        createRandomCall(nil)
        return
    end
    createRandomCall(src)
end

RegisterCommand('ems_testcall', function(src)
    if src ~= 0 and not allowedJob(src) then return end
    runTestEMScall(src)
end, false)

RegisterCommand('testemscall', function(src)
    if src ~= 0 and not allowedJob(src) then return end
    runTestEMScall(src)
end, false)


RegisterNetEvent('az_ambulance:requestCallBoard', function()
    local src = source
    if not allowedJob(src) then return end
    sendCallBoardSnapshot(src)
end)
CreateThread(function()
    sdebug('Random EMS callout loop started.')
    while true do
        local minDelay = Config.CalloutIntervalMin or (5 * 60 * 1000)
        local maxDelay = Config.CalloutIntervalMax or minDelay
        if maxDelay < minDelay then maxDelay = minDelay end

        Wait(math.random(minDelay, maxDelay))

        if not Config.CalloutsEnabled then
            sdebug('Callouts disabled.')
        else
            if not hasOnDutyEMS() then
                sdebug('No EMS on duty; skipping random callout.')
            else
                local activeCount = countActiveCalls()
                local maxCalls    = Config.MaxSimultaneousCalls or 3
                if activeCount < maxCalls then
                    createRandomCall(nil)
                end
            end
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    setPlayerEMSState(src, false, false)
    emsDuty[src] = nil
    emsDutyDepartment[src] = nil
    lastMDTDutySync[src] = nil
    lastMDTStatusSync[src] = nil

    for id, call in pairs(activeCalls) do
        if isResponderOnCall(call, src) then
            detachCallFromMDT(call, src)
            call.responders[src] = nil
            if (tonumber(call.patientNetId) or 0) <= 0 and tonumber(call.sceneSpawnReservedBy) == src then
                call.sceneSpawnReservedBy = nil
                call.sceneSpawnReservedAt = nil
            end
            if call.assigned == src then
                call.assigned, call.assignedLabel = nil, nil
                for responderSrc, _ in pairs(call.responders or {}) do
                    call.assigned = responderSrc
                    call.assignedLabel = ('Unit %s'):format(responderSrc)
                    break
                end
            end
            if getResponderCount(call) == 0 then
                clearCall(id, 'Unit disconnected.')
            end
        end
    end
    broadcastCallBoard()
end)


exports('IsResponderOnDuty', function(src)
    src = tonumber(src) or 0
    if src <= 0 then return false end
    return emsDuty[src] == true
end)

exports('GetResponderMDTStatus', function(src)
    return getEffectiveMDTUnitStatusForResponder(src)
end)

exports('SetDutyStateFromExternal', function(src, desiredState, ctxOrSilent)
    local silent = ctxOrSilent == true
    local selectedDepartment = nil
    if type(ctxOrSilent) == 'table' then
        selectedDepartment = ctxOrSilent.department or ctxOrSilent.job or ctxOrSilent.role
        silent = ctxOrSilent.silent == true
    end
    return setEMSDutyState(src, desiredState == true, silent, selectedDepartment)
end)
