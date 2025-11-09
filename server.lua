
local Config = Config or {}

---------------------------------------------------------------------
-- DEBUG
---------------------------------------------------------------------

local EMS_DEBUG = true

local function sdebug(...)
    if not EMS_DEBUG then return end
    print(('[Az-Ambulance][S] %s'):format(table.concat({...}, ' ')))
end

---------------------------------------------------------------------
-- CONFIG FALLBACKS
---------------------------------------------------------------------

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

-- Callout behaviour (fallbacks – you override in config.lua)
Config.CalloutsEnabled      = (Config.CalloutsEnabled ~= false)
Config.CalloutIntervalMin   = Config.CalloutIntervalMin   or (5 * 60 * 1000)
Config.CalloutIntervalMax   = Config.CalloutIntervalMax   or (15 * 60 * 1000)
Config.MaxSimultaneousCalls = Config.MaxSimultaneousCalls or 3

---------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------

local emsDuty     = {}   -- [src] = true/false
local activeCalls = {}   -- [callId] = call table
local nextCallId  = 1

---------------------------------------------------------------------
-- UTIL
---------------------------------------------------------------------

local function isEMS(source)
    local job = Config.GetPlayerJob(source)
    local j   = job and string.lower(job) or 'civ'
    local ok  = Config.EMSJobs[j] == true
    sdebug('isEMS src='..tostring(source)..' job='..tostring(j)..' -> '..tostring(ok))
    return ok
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
        if call.assigned == src then
            return true
        end
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
    for src, on in pairs(emsDuty) do
        if on then return true end
    end
    return false
end

local function countActiveCalls()
    local n = 0
    for _, _ in pairs(activeCalls) do
        n = n + 1
    end
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

---------------------------------------------------------------------
-- CIVILIAN /ems CALLOUTS
---------------------------------------------------------------------

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

    -- must have at least one EMS on duty
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
    if not ped or ped == 0 then
        sdebug('createUserEMSCall -> GetPlayerPed failed for src='..tostring(src))
        return
    end

    local x, y, z = table.unpack(GetEntityCoords(ped))

    local callType, title = normaliseUserCallType(rawType)
    local callId = nextCallId
    nextCallId   = nextCallId + 1

    local coords = { x = x, y = y, z = z }

    local call = {
        id           = callId,
        type         = callType,
        title        = title,
        details      = description or '',
        address      = 'Unknown address',
        coords       = coords,
        patientNetId = 0,
        vitals       = makeRandomVitals(callType),

        cprRequired  = (callType == 'CARDIAC'),
        cprDone      = false,
        cprQuality   = 0,
        cprOk        = false,

        -- IMPORTANT: user-created call – do NOT auto-spawn scene
        noScene      = true,

        assigned     = nil,
        assignedLabel= nil,
        createdAt    = os.time(),
        callerSrc    = src,
    }

    activeCalls[callId] = call

    sdebug(('createUserEMSCall -> id=%d type=%s from src=%d'):format(callId, callType, src))

    -- send popup to all EMS on duty who are free
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
    createUserEMSCall(src, callType, description)
end)

-- A unit explicitly DENIES a call from the popup
RegisterNetEvent('az_ambulance:denyCallout', function(callId)
    local src  = source
    local call = activeCalls[callId]

    sdebug('denyCallout src='..tostring(src)..' callId='..tostring(callId))

    if not call then
        sendNotify(src, 'error', 'Call no longer active.', 4000)
        return
    end

    -- track who denied (useful for logs / future logic)
    call.declined        = call.declined or {}
    call.declined[src]   = true

    sendNotify(src, 'info', ('You denied call %s.'):format(callId), 4000)
end)




---------------------------------------------------------------------
-- RANDOM CALLOUT GENERATOR
---------------------------------------------------------------------

local callTemplates = {
    {
        type   = 'DRUNK',
        title  = 'Drunk person down',
        detail = 'Caller reports an intoxicated person collapsed on the sidewalk.',
    },
    {
        type   = 'MVA_MINOR',
        title  = 'Minor vehicle accident',
        detail = 'Low-speed collision, one patient complaining of pain.',
    },
    {
        type   = 'MVA_MAJOR',
        title  = 'Major vehicle accident',
        detail = 'Serious crash with significant damage, injuries unknown.',
    },
    {
        type   = 'CARDIAC',
        title  = 'Unresponsive patient',
        detail = 'Caller reports patient not breathing, CPR may be required.',
    }
}

local function createRandomCall(preferredSrc)
    local targetSrc = preferredSrc

    if not targetSrc or targetSrc == 0 then
        targetSrc = getRandomEMS()
        if not targetSrc then
            sdebug('createRandomCall -> no available EMS (none on duty or all busy)')
            return
        end
    else
        -- targeted call (like /ems_testcall): don’t give if already on a call
        if hasAssignedCall(targetSrc) then
            sendNotify(targetSrc, 'info', 'You already have an active EMS call.', 6000)
            return
        end
    end

    if not isEMS(targetSrc) then
        sendNotify(targetSrc, 'error', 'You are not EMS.', 4000)
        return
    end
    if not emsDuty[targetSrc] then
        sendNotify(targetSrc, 'error', 'You must be on EMS duty. Use /ems_duty.', 6000)
        return
    end

    local ped = GetPlayerPed(targetSrc)
    if not ped or ped == 0 then
        sdebug('createRandomCall -> GetPlayerPed failed for src='..tostring(targetSrc))
        return
    end

    local x, y, z = table.unpack(GetEntityCoords(ped))

    local offsetDist = math.random(30, 80)
    local heading    = math.rad(math.random(0, 359))
    local cx         = x + math.cos(heading) * offsetDist
    local cy         = y + math.sin(heading) * offsetDist
    local cz         = z

    local tplIdx = math.random(1, #callTemplates)
    local tpl    = callTemplates[tplIdx]

    local callId = nextCallId
    nextCallId   = nextCallId + 1

    local coords = { x = cx, y = cy, z = cz }

local call = {
    id           = callId,
    type         = tpl.type,
    title        = tpl.title,
    details      = tpl.detail,
    address      = 'Unknown address',
    coords       = coords,
    patientNetId = 0,
    vitals       = makeRandomVitals(tpl.type),

    -- NEW: cardiac / CPR state
    cprRequired  = (tpl.type == 'CARDIAC'),
    cprDone      = false,
    cprQuality   = 0,
    cprOk        = false,

    assigned     = nil,
    assignedLabel= nil,
    createdAt    = os.time(),
}


    activeCalls[callId] = call

    sdebug(('createRandomCall -> callId=%d type=%s for src=%d'):format(callId, tpl.type, targetSrc))

    -- only send to EMS on duty who do NOT currently have an assigned call
    for src, on in pairs(emsDuty) do
        if on and not hasAssignedCall(src) then
            TriggerClientEvent('az_ambulance:newCallout', src, call)
        end
    end
end

---------------------------------------------------------------------
-- DUTY TOGGLE
---------------------------------------------------------------------

local function toggleEMSDuty(src)
    if src == 0 then
        print('[Az-Ambulance] Console cannot toggle duty.')
        return
    end

    local job = Config.GetPlayerJob(src)
    local jobLower = job and string.lower(job) or 'unknown'
    sdebug('toggleEMSDuty src='..tostring(src)..' job='..tostring(jobLower))

    if not Config.EMSJobs[jobLower] then
        sendNotify(src, 'error', 'You are not EMS. Job: '..tostring(jobLower), 6000)
        return
    end

    local newState = not emsDuty[src]
    emsDuty[src]   = newState

    sdebug('toggleEMSDuty -> emsDuty['..src..']='..tostring(newState))
    TriggerClientEvent('az_ambulance:setDuty', src, newState)
end

-- Chat: /ems_duty
RegisterCommand('ems_duty', function(src, args, raw)
    sdebug('command /ems_duty from src='..tostring(src))
    toggleEMSDuty(src)
end, false)

-- Client keybind: az_ambulance:toggleDuty
RegisterNetEvent('az_ambulance:toggleDuty', function()
    local src = source
    sdebug('event az_ambulance:toggleDuty from src='..tostring(src))
    toggleEMSDuty(src)
end)

---------------------------------------------------------------------
-- STATUS UPDATE
---------------------------------------------------------------------

RegisterNetEvent('az_ambulance:statusUpdate', function(newStatus)
    local src = source
    if not emsDuty[src] then
        sdebug('statusUpdate from src='..tostring(src)..' but not on duty')
        return
    end
    sdebug(('statusUpdate src=%d -> %s'):format(src, tostring(newStatus)))
end)

---------------------------------------------------------------------
-- ACCEPT / CLEAR CALLS
---------------------------------------------------------------------

RegisterNetEvent('az_ambulance:acceptCallout', function(callId)
    local src  = source
    local call = activeCalls[callId]

    sdebug('acceptCallout src='..tostring(src)..' callId='..tostring(callId))

    if not call then
        sendNotify(src, 'error', 'Call no longer active.', 4000)
        return
    end

    -- if someone already has a different assigned call, they shouldn't take another
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

    sdebug('acceptCallout -> call '..callId..' assigned to '..src)

    TriggerClientEvent('az_ambulance:callAccepted', -1, call)
end)

local function clearCall(callId, reason)
    local call = activeCalls[callId]
    if not call then return end

    sdebug('clearCall callId='..tostring(callId)..' reason='..tostring(reason))

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
    if not emsDuty[src] then
        sendNotify(src, 'error', 'You are not EMS on duty.', 4000)
        return
    end

    local callId
    for id, call in pairs(activeCalls) do
        if call.assigned == src then
            callId = id
            break
        end
    end

    if not callId then
        sendNotify(src, 'info', 'You have no active call to clear.', 4000)
        return
    end

    clearCall(callId, 'Unit cleared call.')
end, false)


-- called by client when they arrive at hospital after transport
RegisterNetEvent('az_ambulance:completeTransport', function(callId)
    local src  = source
    local call = activeCalls[callId]
    sdebug('completeTransport src='..tostring(src)..' callId='..tostring(callId))

    if not call then return end
    if call.assigned ~= src then
        sdebug('completeTransport -> src not assigned to this call')
        return
    end

    clearCall(callId, 'Patient transported to hospital.')
end)

---------------------------------------------------------------------
-- VITALS / CPR
---------------------------------------------------------------------

RegisterNetEvent('az_ambulance:requestVitals', function(callId, patientNetId)
    local src  = source
    local call = activeCalls[callId]
    sdebug('requestVitals src='..src..' callId='..tostring(callId))
    if not call then
        TriggerClientEvent('az_ambulance:vitalsData', src, nil)
        return
    end
    TriggerClientEvent('az_ambulance:vitalsData', src, call.vitals)
end)

RegisterNetEvent('az_ambulance:cprResult', function(callId, patientNetId, quality)
    local src  = source
    local call = activeCalls[callId]
    if not call then
        sdebug('cprResult src='..src..' callId '..tostring(callId)..' (no call)')
        return
    end

    quality = tonumber(quality) or 0
    sdebug('cprResult src='..src..' callId='..callId..' quality='..quality..' patientNetId='..tostring(patientNetId))

    local msg
    local okThreshold = Config.CardiacCPRRequiredQuality or 60
    local cprOk = (quality >= okThreshold)

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

        -- tell all EMS clients the updated CPR state for this call
        TriggerClientEvent('az_ambulance:updateCPRState', -1, callId, call.cprOk, call.cprQuality)
    else
        -- non-cardiac, just informational
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


---------------------------------------------------------------------
-- TEST CALL COMMANDS
---------------------------------------------------------------------



local function runTestEMScall(src)
    sdebug('runTestEMScall src='..tostring(src))
    if src == 0 then
        createRandomCall(nil)
        return
    end

    createRandomCall(src)
end

RegisterCommand('ems_testcall', function(src, args)
    sdebug('command /ems_testcall from src='..tostring(src))
    runTestEMScall(src)
end, false)

RegisterCommand('testemscall', function(src, args)
    sdebug('command /testemscall from src='..tostring(src))
    runTestEMScall(src)
end, false)

---------------------------------------------------------------------
-- RANDOM CALLOUT LOOP (AUTO)
---------------------------------------------------------------------

CreateThread(function()
    sdebug('Random EMS callout loop started.')
    while true do
        local minDelay = Config.CalloutIntervalMin or (5 * 60 * 1000)
        local maxDelay = Config.CalloutIntervalMax or minDelay
        if maxDelay < minDelay then maxDelay = minDelay end

        local waitMs = math.random(minDelay, maxDelay)
        sdebug(('Random callout loop sleeping for %d ms'):format(waitMs))
        Wait(waitMs)

        if not Config.CalloutsEnabled then
            sdebug('Config.CalloutsEnabled is false; skipping this interval.')
        else
            if not hasOnDutyEMS() then
                sdebug('No EMS on duty; skipping random callout.')
            else
                local activeCount = countActiveCalls()
                local maxCalls    = Config.MaxSimultaneousCalls or 3
                if activeCount >= maxCalls then
                    sdebug(('Active call count %d >= MaxSimultaneousCalls %d; skipping.')
                        :format(activeCount, maxCalls))
                else
                    sdebug('Creating automatic random EMS callout.')
                    createRandomCall(nil) -- behaves like /ems_testcall but automatic
                end
            end
        end
    end
end)

---------------------------------------------------------------------
-- CLEANUP WHEN PLAYER DROPS
---------------------------------------------------------------------

AddEventHandler('playerDropped', function()
    local src = source
    sdebug('playerDropped src='..tostring(src))
    emsDuty[src] = nil

    for id, call in pairs(activeCalls) do
        if call.assigned == src then
            clearCall(id, 'Unit disconnected.')
        end
    end
end)
