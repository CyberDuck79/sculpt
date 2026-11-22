-- sculpt
-- a sample through a chain
-- of texture effects,
-- inspired by the Torso S4
--
-- E1 page, E2 / E3 controls
-- K2 / K3: see top of screen
-- hold K1: E1 stage
-- (+ E2 / E3: setting mode)
-- source: K2 play / stop,
-- K3 load a sample,
-- K1 + K2 reverse
-- mosaic: K2 on / off,
-- K3 lock the buffer

engine.name = "Sculpt"

local parameters = include("lib/params")
local ui = include("lib/ui")

-- ce que l'engine nous apprend, partagé avec l'interface
local state = {
  pos = 0,         -- position de lecture, 0..1
  seconds = 0,     -- durée du sample chargé (0 = aucun)
  wave = nil,      -- forme d'onde : crêtes 0..1, une par colonne d'écran
  loading = false, -- un chargement est en cours
  failed = false,  -- le dernier chargement a échoué
  mos_phase = 0,   -- tête d'écriture de MOSAIC dans son buffer, 0..1
  mos_read = 0,    -- sa tête de lecture en mode stretch, 0..1
  mos_env = {},    -- niveau écrit dans le buffer de MOSAIC, une case par colonne
  mos_col = nil,   -- dernière colonne écrite
}

-- le buffer de MOSAIC, vu par l'écran : une colonne par pixel
local MOS_COLS = 128
for i = 1, MOS_COLS do state.mos_env[i] = 0 end

-- Efface ce que l'écran garde du buffer de MOSAIC. L'engine efface le sien
-- quand l'effet s'éteint : les deux doivent rester d'accord.
function state.clear_mos_env()
  for i = 1, MOS_COLS do state.mos_env[i] = 0 end
  state.mos_col = nil
end

local redraw_loop

-- L'engine dit, 32 fois par seconde, où en est la tête d'écriture de MOSAIC
-- et quel niveau passe sous elle. On range ce niveau dans la colonne que la
-- tête occupe : l'écran garde ainsi l'image de ce que contient le buffer.
-- Tant que la tête ne bouge pas (buffer verrouillé), rien n'est réécrit.
local function mosaic_wrote(phase, peak, read)
  state.mos_phase = phase
  state.mos_read = read or 0
  local col = math.floor(phase * MOS_COLS) % MOS_COLS
  local last = state.mos_col
  if last == col then return end
  if last then
    -- un message en retard peut sauter des colonnes : on les comble
    local skipped = (col - last) % MOS_COLS
    for k = 1, math.min(skipped, 8) do
      state.mos_env[(last + k) % MOS_COLS + 1] = peak
    end
  end
  state.mos_env[col + 1] = peak
  state.mos_col = col
end

function init()
  parameters.add(state)
  ui.init(state, parameters)

  -- réponse de l'engine à un chargement : durée (0 = échec), puis les crêtes
  osc.event = function(path, args)
    if path == "/sculpt/mos" then return mosaic_wrote(args[1], args[2], args[3]) end
    if path ~= "/sculpt/loaded" then return end
    state.loading = false
    state.seconds = args[1]
    state.failed = args[1] <= 0
    state.wave = nil
    if not state.failed then
      state.wave = {}
      for i = 2, #args do state.wave[i - 1] = args[i] end
    end
    -- la grille et la région dépendent de la durée du sample
    parameters.src_refresh()
  end

  local p = poll.set("play_pos", function(x) state.pos = x end)
  p.time = 1 / 15
  p:start()

  -- charge le dernier preset s'il existe, puis envoie tout au moteur
  params:default()

  -- le retard calé sur le tempo suit un changement d'horloge
  local tempo = params:get("clock_tempo")
  redraw_loop = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      if params:get("clock_tempo") ~= tempo then
        tempo = params:get("clock_tempo")
        if params:get("vast_time_mode") > 1 then params:bang("vast_time") end
        parameters.mos_tempo_changed()
        parameters.ring_tempo_changed()
      end
      redraw()
    end
  end)
end

function enc(n, d) ui.enc(n, d) end

function key(n, z) ui.key(n, z) end

-- norns peut demander un dessin pendant le chargement, avant que les
-- paramètres existent
function redraw()
  if params.lookup["play"] then ui.redraw() end
end

function cleanup()
  if redraw_loop then clock.cancel(redraw_loop) end
  osc.event = nil
end
