Config = {}
Config.EMSJobs = {
    ['police'] = true,
    ['ems']       = true,
    ['doctor']    = true,
}


Config.GetPlayerJob = function(source)
    local job = exports['Az-Framework']:getPlayerJob(source)

    
    if type(job) == 'string' then
        return string.lower(job)
    elseif type(job) == 'table' and job.name then
        return string.lower(job.name)
    end

    return nil
end


Config.CalloutsEnabled      = true
Config.CalloutIntervalMin   = 1 * 60 * 1000  
Config.CalloutIntervalMax   = 1 * 60 * 1000 
Config.MaxSimultaneousCalls = 3



Config.CalloutMinDistance = 500.0     
Config.CalloutMaxDistance = 750.0    
Config.CalloutPickAttempts = 25



Config.CallBlipSprite   = 153
Config.CallBlipColour   = 1
Config.CallBlipScale    = 1.0
Config.AcceptDistance   = 50.0 
Config.InteractDistance = 3.0  


Config.CalloutLocations = {
    drunk = {
        { x = 199.53,  y = -1023.41, z = 29.45, heading = 180.0 }, 
        { x = -560.21, y = 286.40,   z = 82.18, heading = 180.0 }, 
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


Config.PatientModels = {
    `a_m_m_skidrow_01`,
    `a_m_m_business_01`,
    `a_f_y_business_02`,
    `a_m_y_stbla_02`,
}


Config.MVCVehicleModel = `blista`


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


Config.CPRDurationSeconds = 30
Config.CPRRequiredGood    = 25



Config.CPRGoodMinMs = 450
Config.CPRGoodMaxMs = 600


Config.Keys = {
    ToggleStatus = 'F6',
    StartCPR     = 'F7',
    Assessment   = 'F8'
}

Config.HospitalArriveDistance = 18.0  

Config.Hospitals = {
    
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
