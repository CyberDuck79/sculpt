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
-- K3 load a sample
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
}

local redraw_loop

function init()
  parameters.add(state)
  ui.init(state, parameters)

  -- réponse de l'engine à un chargement : durée (0 = échec), puis les crêtes
  osc.event = function(path, args)
    if path ~= "/sculpt/loaded" then return end
    state.loading = false
    state.seconds = args[1]
    state.failed = args[1] <= 0
    state.wave = nil
    if not state.failed then
      state.wave = {}
      for i = 2, #args do state.wave[i - 1] = args[i] end
    end
  end

  local p = poll.set("play_pos", function(x) state.pos = x end)
  p.time = 1 / 15
  p:start()
  local pm = poll.set("mos_phase", function(x) state.mos_phase = x end)
  pm.time = 1 / 15
  pm:start()

  -- charge le dernier preset s'il existe, puis envoie tout au moteur
  params:default()

  redraw_loop = clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
end

function enc(n, d) ui.enc(n, d) end

function key(n, z) ui.key(n, z) end

function redraw() ui.redraw() end

function cleanup()
  if redraw_loop then clock.cancel(redraw_loop) end
  osc.event = nil
end
