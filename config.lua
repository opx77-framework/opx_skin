Config = {}

-- Player-facing text follows opx_core's language (opx_core Config.locale, files in locales/).

-- Milliseconds waited after the client confirmed a SetClothing, so its equipment changes reach
-- open77_appearance (which stores them) before anything else happens. Raise it if clothes are lost on a
-- relog right after a change.
Config.settleMs = 700

-- Longest wait for the player's client to answer a clothing request (the platform gives up at 10 s).
Config.requestTimeoutMs = 12000

-- Minimum milliseconds between two SetPreview of one player (faster calls answer 'rate_limited').
Config.previewMinMs = 80

-- Minimum milliseconds between two outfits-menu requests of one player (anything faster is ignored).
Config.rateLimitMs = 400

-- Garments hidden from the lists (GetGarments): Lua patterns tested on the item record.
Config.hide = {
	'Crafting$',
	'_Test',
	'[Dd]ebug',
}

-- Saved outfits: at most `max` per character. The outfits menu (OpenOutfits) stays usable for
-- `sessionMinutes`, and while the player stays within `sessionDistance` metres of where it opened.
Config.outfits = {
	max = 12,
	sessionMinutes = 5,
	sessionDistance = 4.0,
}

-- Optional command that opens your own outfits menu anywhere, e.g. 'outfits'. nil = no command.
Config.command = nil
-- true: the command needs the ACL right `command.<name>` (staff / testing only).
Config.commandRestricted = true

-- Update check at start: compares this version with the one published on GitHub and prints a line in the
-- server console when an update is out. Needs outbound HTTP in server.jsonc ("http": "enabled": true, with
-- "raw.githubusercontent.com" in "allowedHosts"). false = no request.
Config.versionCheck = true
