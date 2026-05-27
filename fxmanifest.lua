fx_version 'cerulean'
game 'gta5'

name 'az_ambulance'
author 'MadebyAzure'
description 'Ambulance / EMS system with callouts, CPR mini‑game and medical HUD'

lua54 'yes'

shared_script 'config.lua'

shared_scripts {
    '@ox_lib/init.lua',
}

client_scripts {
    'callouts.lua',
    'client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua', 
    'server.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html'
}
