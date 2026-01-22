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
}

local EMS_DEBUG = true

local function sdebug(...)
    if not EMS_DEBUG then return end
    print(('[Az-Ambulance][S] %s'):format(table.concat({...}, ' ')))
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

local emsDuty     = {}
local activeCalls = {}
local nextCallId  = 1

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
    syncJobAllowed(source)
end)

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
        if call.assigned == src then return true end
    end
    return false
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

local function pickFromConfiguredPoints()
    local pts = Config.CalloutPoints or {}
    if #pts == 0 then return nil end

    local minDist = Config.CalloutMinDistance or 800.0
    local tries   = Config.CalloutPickAttempts or 25

    for _ = 1, tries do
        local raw = pts[math.random(1, #pts)]
        local p   = unpackCalloutPoint(raw)
        if p then
            local pos = vector3(p.x, p.y, p.z)
            if isFarEnoughFromAllEMS(pos, minDist) then
                return p
            end
        end
    end

    local raw = pts[math.random(1, #pts)]
    return unpackCalloutPoint(raw)
end

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

local function pickRandomCallCoords()
    local p = pickFromConfiguredPoints()
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

    call.patientNetId = netId
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
    }

    activeCalls[callId] = call

    for emsSrc, on in pairs(emsDuty) do
        if on and not hasAssignedCall(emsSrc) then
            TriggerClientEvent('az_ambulance:newCallout', emsSrc, call)
        end
    end

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

    local coords = pickRandomCallCoords()

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
    }

    activeCalls[callId] = call

    for src, on in pairs(emsDuty) do
        if on and not hasAssignedCall(src) then
            TriggerClientEvent('az_ambulance:newCallout', src, call)
        end
    end

    sdebug(('createRandomCall -> id=%s type=%s minDist=%.1f')
        :format(tostring(callId), tostring(tpl.type), (Config.CalloutMinDistance or 0.0)))
end

local function toggleEMSDuty(src)
    if src == 0 then
        print('[Az-Ambulance] Console cannot toggle duty.')
        return
    end

    if not allowedJob(src) then
        sendNotify(src, 'error', 'You are not allowed to use EMS systems.', 6000)
        return
    end

    local jobLower = tostring(Config.GetPlayerJob(src) or 'unknown'):lower()
    if not Config.EMSJobs[jobLower] then
        sendNotify(src, 'error', 'You are not EMS. Job: '..tostring(jobLower), 6000)
        return
    end

    local newState = not emsDuty[src]
    emsDuty[src] = newState

    syncJobAllowed(src)
    TriggerClientEvent('az_ambulance:setDuty', src, newState)

    sdebug('toggleEMSDuty -> emsDuty['..src..']='..tostring(newState))
end

RegisterCommand('ems_duty', function(src)
    if src ~= 0 and not allowedJob(src) then return end
    toggleEMSDuty(src)
end, false)

RegisterNetEvent('az_ambulance:toggleDuty', function()
    local src = source
    if not allowedJob(src) then return end
    toggleEMSDuty(src)
end)

RegisterNetEvent('az_ambulance:statusUpdate', function(newStatus)
    local src = source
    if not allowedJob(src) then return end
    if not emsDuty[src] then return end
    sdebug(('statusUpdate src=%d -> %s'):format(src, tostring(newStatus)))
end)

RegisterNetEvent('az_ambulance:acceptCallout', function(callId)
    local src  = source
    if not allowedJob(src) then return end

    local call = activeCalls[callId]
    if not call then
        sendNotify(src, 'error', 'Call no longer active.', 4000)
        return
    end

    if hasAssignedCall(src) and call.assigned ~= src then
        sendNotify(src, 'error', 'You already have an active EMS call.', 4000)
        return
    end

    if call.assigned and call.assigned ~= src then
        sendNotify(src, 'error', 'Call already taken by another unit.', 4000)
        return
    end

    call.assigned      = src
    call.assignedLabel = ('Unit %s'):format(src)

    call.acceptAtMs = GetGameTimer()
    local ped = GetPlayerPed(src)
    if ped and ped ~= 0 then
        local p = GetEntityCoords(ped)
        call.acceptPos = { x = p.x, y = p.y, z = p.z }
    end

    sdebug('acceptCallout -> call '..callId..' assigned to '..src)
    TriggerClientEvent('az_ambulance:callAccepted', -1, call)
end)

local function clearCall(callId, reason)
    local call = activeCalls[callId]
    if not call then return end

    for src, _ in pairs(emsDuty) do
        TriggerClientEvent('az_ambulance:callCleared', src, callId, reason or 'cleared')
    end

    activeCalls[callId] = nil
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
        if call.assigned == src then callId = id break end
    end

    if not callId then
        sendNotify(src, 'info', 'You have no active call to clear.', 4000)
        return
    end

    clearCall(callId, 'Unit cleared call.')
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

local function payEMSTransport(src, call)
    local amount, b = calcTransportPayout(call)
    if amount <= 0 then
        sdebug('payEMSTransport -> amount <= 0, skipping')
        return
    end

    fw:addMoney(src, amount)

    local msg = ('Transport complete! $%d | Base %d | Pts %d(+%d) | Resp %dm $%d +%ds $%d | Trans %dm $%d | Speed +%d | CPR +%d')
        :format(
            amount,
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

    sendNotify(src, 'success', msg, 9000)
    sdebug(('Paid EMS transport -> src=%d amount=%d callId=%s type=%s')
        :format(src, amount, tostring(call and call.id), tostring(call and call.type)))
end

RegisterNetEvent('az_ambulance:onScene', function(callId)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    if not call then return end
    if call.assigned ~= src then return end
    if call.onSceneAtMs and call.onSceneAtMs > 0 then return end
    call.onSceneAtMs = GetGameTimer()
    sdebug(('onScene callId=%s src=%s'):format(tostring(callId), tostring(src)))
end)

RegisterNetEvent('az_ambulance:patientLoaded', function(callId, patientNetId)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    patientNetId = tonumber(patientNetId) or 0
    local call = callId and activeCalls[callId] or nil
    if not call then return end
    if call.assigned ~= src then return end
    if patientNetId <= 0 then return end

    call.patients = call.patients or {}
    if not call.patients[patientNetId] then
        call.patients[patientNetId] = true
        local c = 0
        for _k, _v in pairs(call.patients) do c = c + 1 end
        call.patientCount = c
        sdebug(('patientLoaded callId=%s src=%s netId=%s count=%s'):format(tostring(callId), tostring(src), tostring(patientNetId), tostring(c)))
    end
end)

RegisterNetEvent('az_ambulance:transportStart', function(callId, hospName, hx, hy, hz)
    local src = source
    if not allowedJob(src) then return end
    callId = tonumber(callId)
    local call = callId and activeCalls[callId] or nil
    if not call then return end
    if call.assigned ~= src then return end

    if not call.transportAtMs or call.transportAtMs <= 0 then
        call.transportAtMs = GetGameTimer()
    end

    call.transportHosp = tostring(hospName or 'Hospital')
    call.transportHospPos = { x = tonumber(hx) or 0.0, y = tonumber(hy) or 0.0, z = tonumber(hz) or 0.0 }

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

    if call.assigned ~= src then
        sdebug('completeTransport -> src not assigned to this call')
        return
    end

    if call.transportPaid then
        sdebug('completeTransport -> already paid for callId='..tostring(callId))
        return
    end
    call.transportPaid = true

    if not call.patientCount or call.patientCount <= 0 then
        call.patientCount = 1
    end

    payEMSTransport(src, call)
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
    emsDuty[src] = nil

    for id, call in pairs(activeCalls) do
        if call.assigned == src then
            clearCall(id, 'Unit disconnected.')
        end
    end
end)