resource "opx_skin"
version "1.0.0"
open77_version ">=0.0.1"
auto_start true

-- OPX//77 skin: the clothing API (provider slot `skin` of opx_core). Saved clothes go through the platform
-- (Open77.clothing.set -> open77_equipment relay -> open77_appearance record); uniforms and fitting-room
-- previews share the platform's single temporary outfit, which opx_skin alone holds and arbitrates.
-- Saved outfits (named sets) live in its own table opx_skin_outfits. Garment lists for UIs on the client.
-- opx_menu and opx_dialog are dependencies because require('@...') only loads a declared, running one
-- (the outfits menu and its name form).
dependencies {
    "opx_core",
    "opx_menu",
    "opx_dialog",
    "open77_appearance >=0.5.0",
}

permissions {
    "network.events",        -- both: menu requests and answers; server: Open77.clothing.set / requestSnapshot
    "database.access",       -- server: opx_skin_outfits (schema at start, loads, writes)
    "player.equipment.read", -- client: Open77.equipment.records / family (garment lists)
    "http.request", -- server: Open77.http.get (update check, Config.versionCheck)
}

shared_script "config.lua"

-- No `require` on the server: the files share globals, loaded in this order.
server_scripts {
    "server/state.lua",
    "server/outfits.lua",
    "server/main.lua",
    "server/version.lua",
}

client_script "client/main.lua"

files {
    "client/modules/*.lua",
    "locales/*.json",
}
