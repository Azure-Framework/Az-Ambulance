Config = {}


Config.EMSJobs = {
    ['police'] = true,
    ['ems']       = true,
    ['doctor']    = true,
}

-- Use Az-Framework job export
Config.GetPlayerJob = function(source)
    local job = exports['Az-Framework']:getPlayerJob(source)

    -- Az-Framework might return a string or a table; support both.
    if type(job) == 'string' then
        return string.lower(job)
    elseif type(job) == 'table' and job.name then
        return string.lower(job.name)
    end

    return nil
end

-- CALL OUT CONFIG
Config.CalloutsEnabled      = true
Config.CalloutIntervalMin   = 1 * 60 * 1000  -- 5 minutes
Config.CalloutIntervalMax   = 1 * 60 * 1000 -- 15 minutes
Config.MaxSimultaneousCalls = 3

-- Blip + distance settings
Config.CallBlipSprite   = 153
Config.CallBlipColour   = 1
Config.CallBlipScale    = 1.0
Config.AcceptDistance   = 50.0 -- distance from call origin to press E and "go on scene"
Config.InteractDistance = 3.0  -- distance to patient for CPR / assessment

-- Locations for random callouts (examples only, add your own)
Config.CalloutLocations = {
    drunk = {
        { x = 199.53,  y = -1023.41, z = 29.45, heading = 180.0 }, -- outside Legion
        { x = -560.21, y = 286.40,   z = 82.18, heading = 180.0 }, -- Vinewood
    },
    mvc_small = {
        { x = 422.34,  y = -1014.56, z = 29.04, heading = 90.0 },
        { x = -322.21, y = -922.12,  z = 31.08, heading = 340.0 },
    },
    mvc_major = {
        { x = -1507.92, y = -438.88, z = 35.45, heading = 140.0 },
        { x = 1174.71,  y = -1321.13,z = 34.92, heading = 180.0 },
    }
}

-- PEDESTAL MODELS
Config.PatientModels = {
    `a_m_m_skidrow_01`,
    `a_m_m_business_01`,
    `a_f_y_business_02`,
    `a_m_y_stbla_02`,
}

-- VEHICLE model used for MVC scenes
Config.MVCVehicleModel = `blista`

-- PATIENT STATES / VITALS
Config.VitalsPresets = {
    drunk = {
        heartRate = {90, 120},
        systolic  = {110, 140},
        diastolic = {70, 90},
        respRate  = {18, 26},
        spo2      = {95, 100},
        gcs       = {13, 15},
        state     = 'conscious',
        description = 'Intoxicated, unsteady on feet, slurred speech.'
    },
    mvc_small = {
        heartRate = {90, 110},
        systolic  = {110, 130},
        diastolic = {70, 85},
        respRate  = {18, 24},
        spo2      = {95, 100},
        gcs       = {14, 15},
        state     = 'conscious',
        description = 'Minor lacerations and bruising, complains of pain.'
    },
    mvc_major = {
        heartRate = {120, 150},
        systolic  = {80, 100},
        diastolic = {50, 65},
        respRate  = {24, 32},
        spo2      = {88, 95},
        gcs       = {8, 12},
        state     = 'unconscious',
        description = 'Significant trauma, reduced GCS, possible internal bleeding.'
    },
    arrest = {
        heartRate = {0, 0},
        systolic  = {0, 0},
        diastolic = {0, 0},
        respRate  = {0, 0},
        spo2      = {0, 0},
        gcs       = {3, 3},
        state     = 'arrest',
        description = 'Pulseless and apneic. Begin CPR immediately.'
    }
}

-- How long CPR mini‑game runs (seconds) and how many good compressions required
Config.CPRDurationSeconds = 30
Config.CPRRequiredGood    = 25

-- CPR good timing window (milliseconds between clicks)
-- corresponds roughly to 100–120 compressions per minute
Config.CPRGoodMinMs = 450
Config.CPRGoodMaxMs = 600

-- UI KEYS (client will just show them; we still use key mapping)
Config.Keys = {
    ToggleStatus = 'F6',
    StartCPR     = 'F7',
    Assessment   = 'F8'
}

Config.HospitalArriveDistance = 18.0  -- metres around hospital entrance to complete call

Config.Hospitals = {
    -- Front doors / ambulance bays – tweak as you like
    {
        name = 'Pillbox Hill Medical',
        x = 295.0,   y = -1446.0, z = 29.0
    },
    {
        name = 'Sandy Shores Medical',
        x = 1839.0,  y = 3672.0,  z = 34.3
    },
    {
        name = 'Paleto Bay Medical',
        x = -247.0,  y = 6331.0,  z = 32.4
    },
}
