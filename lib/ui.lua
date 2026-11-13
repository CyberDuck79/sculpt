-- sculpt : l'interface
--
-- E1 page dans l'étage, E2 / E3 les deux réglages de la page, K2 / K3 les
-- deux actions de l'étage (leur rôle est écrit en haut de l'écran).
-- K1 maintenu : E1 change d'étage dans la chaîne ; E2 / E3 changeront le
-- mode du réglage (pas encore de réglage à modes).
--
-- Écran (64 px) : 8 px de ligne du haut, 39 px de visualisation, 16 px
-- pour les deux réglages.

local fileselect = require "fileselect"

local ui = {}

local state
local shift = false
-- le sélecteur de fichiers de norns est ouvert
local selecting = false

-- Les étages, dans l'ordre du signal. pages : deux identifiants de params
-- par page (E2, E3), false pour un encodeur sans réglage.
-- keys : ce que font K2 et K3 dans l'étage (label, actif ?, action).
local STAGES = {
  {
    name = "source",
    short = "SRC",
    pages = { { "level", false } },
    keys = {
      {
        label = function() return "PLAY", params:get("play") == 1 end,
        press = function() params:delta("play", 1) end,
      },
      {
        label = function() return "LOAD", state.loading end,
        press = function()
          -- le sélecteur dessine lui-même l'écran : on se tait jusqu'à sa fermeture
          selecting = true
          fileselect.enter(_path.audio, function(path)
            selecting = false
            if path ~= "cancel" then params:set("sample", path) end
          end)
        end,
      },
    },
  },
  {
    name = "settings",
    short = "SET",
    pages = { { "clock_tempo", false } },
    keys = {},
  },
}

local stage = 1
-- la page où on était dans chaque étage
local page_of = {}
for i = 1, #STAGES do page_of[i] = 1 end

function ui.init(s)
  state = s
end

function ui.enc(n, d)
  local st = STAGES[stage]
  if n == 1 then
    if shift then
      stage = util.clamp(stage + d, 1, #STAGES)
    else
      page_of[stage] = util.clamp(page_of[stage] + d, 1, #st.pages)
    end
  elseif not shift then
    local id = st.pages[page_of[stage]][n - 1]
    if id then params:delta(id, d) end
  end
end

function ui.key(n, z)
  if n == 1 then
    shift = z == 1
  elseif z == 1 and not shift then
    local k = STAGES[stage].keys[n - 1]
    if k then k.press() end
  end
end

-- position 0..1 d'un paramètre, quel que soit son type
local function raw(p)
  if p.get_raw then return p:get_raw() end
  if p.options then return (p:get() - 1) / math.max(1, #p.options - 1) end
  if p.min and p.max then return (p:get() - p.min) / (p.max - p.min) end
  return 0
end

local function mmss(seconds)
  local s = math.floor(seconds)
  return string.format("%d:%02d", s // 60, s % 60)
end

-- ligne du haut : l'étage et ses points de page, le rôle de K2 et K3,
-- l'horloge. K1 maintenu : toute la chaîne, l'étage courant en clair.
local function draw_top()
  if shift then
    local x = 0
    for i, st in ipairs(STAGES) do
      screen.level(i == stage and 15 or 3)
      screen.move(x, 7)
      screen.text(st.short)
      x = x + screen.text_extents(st.short) + 5
    end
    return
  end

  local st = STAGES[stage]
  screen.level(15)
  screen.move(0, 7)
  screen.text(st.name)
  if #st.pages > 1 then
    local x = screen.text_extents(st.name) + 4
    for i = 1, #st.pages do
      screen.level(i == page_of[stage] and 15 or 2)
      screen.rect(x + (i - 1) * 4, 4, 2, 2)
      screen.fill()
    end
  end

  -- labels alignés à gauche : ils partent toujours du même point
  local blink = util.time() % 0.5 < 0.25
  for i, x in ipairs { 76, 101 } do
    local k = st.keys[i]
    if k then
      local label, on = k.label()
      -- un chargement en cours clignote
      if label == "LOAD" and on then
        screen.level(blink and 15 or 5)
      else
        screen.level(on and 15 or 3)
      end
      screen.move(x, 7)
      screen.text(label)
    end
  end

  -- horloge : un éclair à chaque temps, plus grand sur le premier de la mesure
  local beats = clock.get_beats()
  local flash = beats % 1 < 0.2
  if math.floor(beats) % 4 == 0 then
    screen.level(flash and 15 or 3)
    screen.rect(123, 2, 5, 5)
  else
    screen.level(flash and 10 or 2)
    screen.rect(124, 3, 3, 3)
  end
  screen.fill()
end

-- visualisation de la source : la forme d'onde et la tête de lecture
local VIZ_TOP, VIZ_MID, VIZ_HALF = 9, 28, 18

local function centered(text, level)
  screen.level(level)
  screen.move(64, VIZ_MID + 2)
  screen.text_center(text)
end

local function draw_source()
  if state.loading then return centered("loading...", 8) end
  if state.failed then return centered("cannot read this file", 8) end
  if not state.wave then return centered("K3: load a sample", 4) end

  local playing = params:get("play") == 1
  local head = util.clamp(math.floor(state.pos * 128), 0, 127)
  -- les crêtes sont ramenées à la plus haute : un sample faible reste lisible
  local top = 0.001
  for _, v in ipairs(state.wave) do top = math.max(top, v) end
  for i, v in ipairs(state.wave) do
    local h = math.max(1, util.round(VIZ_HALF * v / top))
    -- ce qui est déjà lu est plus clair
    screen.level((playing and i - 1 <= head) and 8 or 3)
    screen.rect(i - 1, VIZ_MID - h, 1, 2 * h)
    screen.fill()
  end
  if playing then
    screen.level(15)
    screen.rect(head, VIZ_TOP, 1, 2 * VIZ_HALF + 1)
    screen.fill()
  end

  -- position et durée, sur un fond noir pour rester lisibles
  local text = (playing and (mmss(state.pos * state.seconds) .. " / ") or "") .. mmss(state.seconds)
  local w = screen.text_extents(text)
  screen.level(0)
  screen.rect(126 - w - 2, VIZ_TOP, w + 4, 8)
  screen.fill()
  screen.level(6)
  screen.move(127, VIZ_TOP + 6)
  screen.text_right(text)
end

-- un réglage : nom à gauche, valeur à droite, barre fine dessous
local function draw_param(id, x)
  if not id then return end
  local p = params:lookup_param(id)
  screen.level(4)
  screen.move(x, 55)
  screen.text(p.name)
  screen.level(15)
  screen.move(x + 60, 55)
  -- le tempo peut arriver non arrondi : on l'affiche entier
  screen.text_right(id == "clock_tempo" and string.format("%d", util.round(params:get(id))) or params:string(id))
  screen.level(2)
  screen.rect(x, 59, 60, 2)
  screen.fill()
  screen.level(12)
  screen.rect(x, 59, math.max(1, util.round(60 * util.clamp(raw(p), 0, 1))), 2)
  screen.fill()
end

function ui.redraw()
  if selecting then return end
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  draw_top()
  if STAGES[stage].name == "source" then draw_source() end

  local page = STAGES[stage].pages[page_of[stage]]
  draw_param(page[1], 0)
  draw_param(page[2], 68)

  screen.update()
end

return ui
