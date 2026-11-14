-- sculpt : l'interface
--
-- E1 page dans l'étage, E2 / E3 les deux réglages de la page, K2 / K3 les
-- deux actions de l'étage (leur rôle est écrit en haut de l'écran).
-- K1 maintenu : E1 change d'étage dans la chaîne ; E2 / E3 changent le mode
-- du réglage correspondant, quand il en a un (comme l'encodeur maintenu du S4).
--
-- Écran (64 px) : 8 px de ligne du haut, 39 px de visualisation, 16 px
-- pour les deux réglages.

local fileselect = require "fileselect"

local ui = {}

local state, parameters
local shift = false
-- le sélecteur de fichiers de norns est ouvert
local selecting = false

local draw_source, draw_mosaic, draw_ring, draw_deform, draw_vast

-- Les étages, dans l'ordre du signal.
-- pages : deux réglages par page (E2, E3). Un réglage est un identifiant de
--   param, ou { id, mode = id du param de mode }, ou false (encodeur libre).
-- keys : ce que font K2 et K3 dans l'étage (label, actif ?, action).
-- on : pour un effet, l'identifiant de son interrupteur (bypass = éteint).
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
    draw = function() draw_source() end,
  },
  {
    name = "mosaic",
    short = "MOS",
    on = "mos_on",
    pages = {
      { { "mos_pitch", mode = "mos_scale" }, { "mos_rate", mode = "mos_rate_mode" } },
      { { "mos_size", mode = "mos_size_mode" }, "mos_contour" },
      { { "mos_scan", mode = "mos_scan_mode" }, { "mos_spray", mode = "mos_spray_mode" } },
      { "mos_feedback", "mos_wet" },
      { { "mos_pattern", mode = "mos_pattern_seed" },
        { "mos_rand_pitch", mode = "mos_rand_pitch_mode" } },
      { "mos_rand_rate", "mos_rand_size" },
      { "mos_rand_amp", "mos_rand_rev" },
    },
    keys = {
      {
        label = function() return "ON", params:get("mos_on") == 1 end,
        press = function() params:delta("mos_on", 1) end,
      },
      {
        label = function() return "LOCK", params:get("mos_lock") == 1 end,
        press = function() params:delta("mos_lock", 1) end,
      },
    },
    draw = function() draw_mosaic() end,
  },
  {
    name = "ring",
    short = "RNG",
    on = "ring_on",
    pages = {
      { "ring_cutoff", "ring_reso" },
      { "ring_decay", "ring_tilt" },
      { "ring_slope", "ring_tone" },
      { "ring_pitch", "ring_wet" },
    },
    keys = {
      {
        label = function() return "ON", params:get("ring_on") == 1 end,
        press = function() params:delta("ring_on", 1) end,
      },
    },
    draw = function() draw_ring() end,
  },
  {
    name = "deform",
    short = "DEF",
    on = "def_on",
    pages = {
      { "def_drive", { "def_crush", mode = "def_crush_mode" } },
      { "def_comp", { "def_tilt", mode = "def_xover" } },
      { { "def_noise", mode = "def_noise_type" }, "def_noise_decay" },
      { "def_noise_tone", "def_wet" },
    },
    keys = {
      {
        label = function() return "ON", params:get("def_on") == 1 end,
        press = function() params:delta("def_on", 1) end,
      },
    },
    draw = function() draw_deform() end,
  },
  {
    name = "vast",
    short = "VST",
    on = "vast_on",
    pages = {
      { "vast_dly", { "vast_time", mode = "vast_time_mode" } },
      { "vast_feedback", { "vast_spread", mode = "vast_spread_mode" } },
      { "vast_rev", "vast_size" },
      { "vast_decay", "vast_tone" },
    },
    keys = {
      {
        label = function() return "ON", params:get("vast_on") == 1 end,
        press = function() params:delta("vast_on", 1) end,
      },
      {
        label = function() return "FRZ", params:get("vast_freeze") == 1 end,
        press = function() params:delta("vast_freeze", 1) end,
      },
    },
    -- K1 maintenu + K3 : vider les deux boucles
    shift_keys = {
      [2] = { press = function() engine.vast_clear(1) end },
    },
    draw = function() draw_vast() end,
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

function ui.init(s, p)
  state, parameters = s, p
end

-- un réglage de page : son identifiant et celui de son mode (ou nil)
local function slot(entry)
  if type(entry) == "table" then return entry[1], entry.mode end
  return entry or nil, nil
end

function ui.enc(n, d)
  local st = STAGES[stage]
  if n == 1 then
    if shift then
      stage = util.clamp(stage + d, 1, #STAGES)
    else
      page_of[stage] = util.clamp(page_of[stage] + d, 1, #st.pages)
    end
    return
  end
  local id, mode = slot(st.pages[page_of[stage]][n - 1])
  if shift then
    if mode then params:delta(mode, d) end
  elseif id then
    -- certains réglages avancent par notes ou par divisions (voir params)
    local custom = parameters.deltas[id]
    if custom then custom(d) else params:delta(id, d) end
  end
end

function ui.key(n, z)
  if n == 1 then
    shift = z == 1
  elseif z == 1 then
    local st = STAGES[stage]
    -- K1 maintenu donne la seconde action de la touche, et rien quand elle
    -- n'existe pas : K1 sert aussi à changer d'étage, et une touche pressée
    -- en chemin ne doit pas déclencher son action ordinaire.
    local set = shift and (st.shift_keys or {}) or st.keys
    local k = set[n - 1]
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

-- un réglage qui va du négatif au positif : sa barre part du centre
local function bipolar(p)
  if p.controlspec then return p.controlspec.minval < 0 end
  return p.min ~= nil and p.min < 0
end

local function mmss(seconds)
  local s = math.floor(seconds)
  return string.format("%d:%02d", s // 60, s % 60)
end

-- ligne du haut : l'étage et ses points de page, le rôle de K2 et K3,
-- l'horloge. K1 maintenu : toute la chaîne, l'étage courant en clair, un
-- effet éteint en minuscules.
local function draw_top()
  if shift then
    local x = 0
    for i, st in ipairs(STAGES) do
      local off = st.on and params:get(st.on) == 0
      local text = off and string.lower(st.short) or st.short
      screen.level(i == stage and 15 or (off and 2 or 5))
      screen.move(x, 7)
      screen.text(text)
      x = x + screen.text_extents(text) + 5
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

-- la zone de visualisation : de y = 9 à y = 47
local VIZ_TOP, VIZ_MID, VIZ_HALF = 9, 28, 18

local function centered(text, level)
  screen.level(level)
  screen.move(64, VIZ_MID + 2)
  screen.text_center(text)
end

-- source : la forme d'onde et la tête de lecture
draw_source = function()
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

-- MOSAIC : le buffer de 4 s sur toute la largeur, et les grains qui y lisent.
-- Les grains affichés sont simulés à partir des réglages (cadence, taille,
-- hauteur, position) : ils montrent ce que fait le moteur, pas ses grains réels.
local MOS_SECONDS = 4
-- le bas de l'échelle de la forme d'onde du buffer, en décibels
local MOS_FLOOR_DB = -48
local PX_PER_S = 128 / MOS_SECONDS
local mos_grains = {}
local mos_acc, mos_last, mos_next = 0, nil, 1

-- enveloppe approchée d'un grain, pour sa hauteur à l'écran
local function grain_env(x, contour)
  local bell = math.sin(math.pi * x) ^ 2
  local ramp = contour < 0 and (1 - x) or x
  local k = math.abs(contour)
  return bell * (1 - k) + ramp * k
end

-- Hauteur d'une colonne du buffer. L'échelle est fixe, graduée en
-- décibels : l'image garde la même taille quoi qu'il passe dedans, et
-- un passage faible reste lisible.
local function env_height(v)
  local db = 20 * math.log(v, 10)
  if db <= MOS_FLOOR_DB then return 0 end
  return math.max(1, util.round((VIZ_HALF - 2) * (1 - (db / MOS_FLOOR_DB))))
end

-- VAST : l'écran coupé en deux, comme sur le S4. À gauche le delay, des
-- cercles qui s'enfoncent vers le centre ; à droite la réverbe, une salle
-- vue de trois quarts et le niveau qui la remplit. Les deux sont dessinés
-- d'après les réglages, pas lus dans l'engine.
local VAST_R = 18

-- un demi-cercle : côté -1 à gauche, +1 à droite
local function half_ring(cx, r, side, level)
  if level < 1 or r < 0.5 then return end
  screen.level(math.min(15, util.round(level)))
  -- on se place d'abord au départ de l'arc : sinon il est relié par un
  -- trait au dernier point laissé par ce qui a été dessiné avant
  if side < 0 then
    screen.move(cx, VIZ_MID + r)
    screen.arc(cx, VIZ_MID, r, math.pi / 2, math.pi * 3 / 2)
  else
    screen.move(cx, VIZ_MID - r)
    screen.arc(cx, VIZ_MID, r, -math.pi / 2, math.pi / 2)
  end
  screen.stroke()
end

-- Le delay. Le grand cercle est le son qui entre ; chaque répétition est
-- un cercle plus petit et plus sombre. TIME fixe l'écart entre deux
-- cercles, FEEDBACK la vitesse à laquelle ils s'éteignent, DELAY leur
-- éclat. SPREAD sépare les deux moitiés, gauche et droite, chacune à sa
-- façon selon le mode.
local function draw_vast_delay(cx, on, frozen)
  local t = parameters.vast_time_seconds()
  local fb = frozen and 1 or params:get("vast_feedback")
  local dly = params:get("vast_dly")
  local sp = params:get("vast_spread")
  local mode = params:get("vast_spread_mode")
  -- l'écart suit le temps sur une échelle logarithmique : 10 ms à 2 s
  local gap = 2 + 5 * (math.log(t / 0.01) / math.log(200))
  local base = (dly > 0 and (5 + 10 * dly) or 3) * (on and 1 or 0.3)
  -- décalage : la voie droite est plus longue, ses cercles tombent plus loin
  local gap_r = gap * (1 + (mode == 1 and sp * 0.4 or 0))

  half_ring(cx, VAST_R, -1, base)
  half_ring(cx, VAST_R, 1, base)
  for k = 1, 16 do
    local lvl = base * (fb ^ k)
    if frozen then lvl = base * 0.6 end
    if lvl < 1 then break end
    local rl, rr = VAST_R - k * gap, VAST_R - k * gap_r
    if rl < 1 and rr < 1 then break end
    local ll, lr = lvl, lvl
    -- ping-pong : les répétitions alternent d'un côté à l'autre
    if mode == 2 then
      if k % 2 == 1 then lr = lvl * (1 - sp) else ll = lvl * (1 - sp) end
    end
    -- diffus : chaque répétition s'étale, un second trait la double
    if mode == 3 and sp > 0 then
      half_ring(cx, rl + 1, -1, ll * sp * 0.6)
      half_ring(cx, rr + 1, 1, lr * sp * 0.6)
    end
    half_ring(cx, rl, -1, ll)
    half_ring(cx, rr, 1, lr)
  end
end

-- La réverbe. SIZE agrandit la salle, DECAY monte la plaque qui la
-- remplit, REVERB éclaire ses arêtes et TONE la plaque : sombre quand il
-- coupe l'aigu, claire quand il coupe le grave. Gelée, la salle est pleine.
local function draw_vast_reverb(cx, on, frozen)
  local size, rev = params:get("vast_size"), params:get("vast_rev")
  local decay = frozen and 1 or params:get("vast_decay")
  local dim = on and 1 or 0.3
  -- demi-côté du sol et hauteur ; à l'écran une unité de sol vaut 2 pixels
  -- en largeur et 1 en hauteur
  local s = util.round(6 + 6 * size)
  local h = util.round(s * 0.85)
  local top = VIZ_MID - util.round(h / 2)

  local function diamond(y)
    screen.move(cx, y - s)
    screen.line(cx + 2 * s, y)
    screen.line(cx, y + s)
    screen.line(cx - 2 * s, y)
    screen.close()
  end
  local function seg(x1, y1, x2, y2)
    screen.move(x1, y1)
    screen.line(x2, y2)
    screen.stroke()
  end

  -- le niveau
  local py = top + util.round(h * (1 - decay))
  local fill = math.max(1, util.round((6 + 5 * params:get("vast_tone")) * dim))
  local edge = math.max(1, util.round((3 + 12 * rev) * dim))
  screen.level(fill)
  diamond(py)
  screen.fill()

  -- les trois arêtes du fond, vues à travers : à mi-chemin entre la plaque
  -- et les arêtes, mais jamais à moins de trois niveaux de la plaque, un
  -- écart plus petit ne se voit pas sur l'écran
  local back = (fill + edge) / 2
  if math.abs(back - fill) < 3 then back = fill + (fill > 8 and -3 or 3) end
  screen.level(util.clamp(util.round(back), 0, 15))
  seg(cx, top - s, cx, top + h - s)
  seg(cx, top + h - s, cx + 2 * s, top + h)
  seg(cx, top + h - s, cx - 2 * s, top + h)

  -- le reste de la salle
  screen.level(edge)
  diamond(top)
  screen.stroke()
  seg(cx - 2 * s, top, cx - 2 * s, top + h)
  seg(cx + 2 * s, top, cx + 2 * s, top + h)
  seg(cx, top + s, cx, top + h + s)
  seg(cx - 2 * s, top + h, cx, top + h + s)
  seg(cx + 2 * s, top + h, cx, top + h + s)
end

draw_vast = function()
  local on = params:get("vast_on") == 1
  local frozen = params:get("vast_freeze") == 1
  draw_vast_delay(31, on, frozen)
  draw_vast_reverb(96, on, frozen)
end

-- DEFORM : la courbe qui dit ce que devient chaque niveau d'entrée. On y
-- lit l'écrêtage du drive, l'escalier du crush et le coude du compresseur.
-- La réduction d'échantillonnage, elle, ne s'y voit pas : elle est dans le
-- temps, pas dans les niveaux.
-- le companding du crush, même valeur que dans l'engine
local DEF_CRUSH_LAW = 0.32

local function tanh(x)
  local e = math.exp(2 * x)
  return (e - 1) / (e + 1)
end

draw_deform = function()
  local on = params:get("def_on") == 1
  local crush, cmode = params:get("def_crush"), params:get("def_crush_mode")
  local comp, tilt = params:get("def_comp"), params:get("def_tilt")
  local noise = params:get("def_noise")
  local dv = params:get("def_drive")
  local d = 50 ^ dv
  local step = 2 ^ (1 - (12 - (crush * 8)))
  local law = DEF_CRUSH_LAW
  local thr = 1 - (comp * 0.95)
  local slope = 1 - (comp * 0.8)
  local makeup = math.min(thr ^ ((slope - 1) * 0.5), 1.6)
  local size = 2 * VIZ_HALF
  local x0, half = 64 - (size / 2), size / 2

  screen.level(on and 2 or 1)
  screen.rect(x0 - 0.5, VIZ_MID - half - 0.5, size, size)
  screen.stroke()

  for px = 0, size - 1 do
    local x = ((px / (size - 1)) * 2) - 1
    local y = (x * (1 - dv)) + ((tanh(x * d) / tanh(d)) * dv * (d ^ -0.75))
    -- l'escalier n'existe pas en réduction d'échantillonnage seule ; le
    -- companding le resserre vers le bas, où la résolution est gardée
    if cmode ~= 2 then
      local sgn = y < 0 and -1 or 1
      local c = sgn * (math.abs(y) ^ law)
      y = sgn * ((math.abs(util.round(c / step) * step)) ^ (1 / law))
    end
    local a = math.abs(y)
    if a > thr then y = (y < 0 and -1 or 1) * (thr + ((a - thr) * slope)) end
    local py = VIZ_MID - util.round(util.clamp(y * makeup, -1, 1) * half)
    -- le bruit brouille la courbe à hauteur de ce qu'on en met
    if noise > 0 and math.random() < 0.7 then
      screen.level(on and 5 or 1)
      screen.rect(x0 + px, py + util.round((math.random() * 2 - 1) * noise * 7), 1, 1)
      screen.fill()
    end
    screen.level(on and 15 or 3)
    screen.rect(x0 + px, py, 1, 1)
    screen.fill()
  end

  -- de chaque côté, la bande qui part la première dans la saturation
  for i, db in ipairs({ -tilt * 6, tilt * 6 }) do
    local h = math.max(1, util.round(size * (db + 6) / 12))
    local bx = (i == 1) and (x0 - 12) or (x0 + size + 9)
    screen.level(on and 6 or 1)
    screen.rect(bx, VIZ_MID + half - h, 3, h)
    screen.fill()
  end

  if not on then
    screen.level(0)
    screen.rect(52, VIZ_MID - 5, 24, 9)
    screen.fill()
    centered("off", 5)
  end
end

-- RING : la réponse du banc, une barre par bande. La formule est celle de
-- l'engine ; les refaire ici coûte moins que de les faire voyager.
local RING_BANDS, RING_SPAN = 48, 8.64

draw_ring = function()
  local on = params:get("ring_on") == 1
  local cutoff = params:get("ring_cutoff")
  local slope, tone = params:get("ring_slope"), params:get("ring_tone")
  local reso, decay, tilt = params:get("ring_reso"), params:get("ring_decay"), params:get("ring_tilt")
  local ratio = 2 ^ (params:get("ring_pitch") / 12)
  local hi, lo = (1 - slope) * 12, (1 + slope) * 12
  local ring = decay * decay * 4
  local bottom = VIZ_MID + VIZ_HALF

  for i = 0, RING_BANDS - 1 do
    local f = 40 * 2 ^ (i * RING_SPAN / (RING_BANDS - 1)) * ratio
    local x = math.log(f / cutoff, 2)
    local db = (-math.max(x, 0) * hi) + (math.min(x, 0) * lo)
      + (x * tone * 6) + (reso * 18 * math.exp(x * x * -5.5))
    -- de -48 dB en bas à +18 dB en haut
    local h = util.round((2 * VIZ_HALF) * util.clamp((db + 48) / 66, 0, 1))
    -- une bande qui sonne longtemps est plus claire
    local r = (ring * 2 ^ (x * tilt * 0.5)) + 0.0015
    local lit = util.clamp(math.log(r / 0.0015, 10) / 3, 0, 1)
    screen.level(on and util.round(3 + 11 * lit) or 1)
    if h > 0 then
      screen.rect(util.round(i * 127 / (RING_BANDS - 1)), bottom - h, 2, h)
      screen.fill()
    end
  end

  -- où se place la coupure sur cet axe
  local cx = math.log(cutoff / 40, 2) / RING_SPAN * 127
  if cx >= 0 and cx <= 127 then
    screen.level(on and 15 or 3)
    screen.rect(util.round(cx), VIZ_TOP, 1, 3)
    screen.fill()
  end

  if not on then
    screen.level(0)
    screen.rect(52, VIZ_MID - 5, 24, 9)
    screen.fill()
    centered("off", 5)
  end
end

draw_mosaic = function()
  local on = params:get("mos_on") == 1
  local locked = params:get("mos_lock") == 1
  local scan_mode = params:get("mos_scan_mode")
  -- position et stretch : l'axe est le buffer, pas le temps écoulé
  local fixed = scan_mode >= 3
  local rate, size = parameters.mos_rate_hz(), parameters.mos_size_seconds()
  local rand_rate, rand_size = params:get("mos_rand_rate"), params:get("mos_rand_size")
  local rand_rev = params:get("mos_rand_rev")
  local dur = math.min(size, 48 / (rate * (1 + 0.2 * rand_rate)))
  local ratio = 2 ^ (parameters.mos_pitch_semis() / 12)
  local scan, spray = parameters.mos_scan_value(), params:get("mos_spray")
  -- en stretch, le point de lecture est la tête que l'engine fait avancer
  if scan_mode == 4 then scan = state.mos_read end
  local contour = params:get("mos_contour")
  local now = util.time()
  local dt = mos_last and math.min(now - mos_last, 0.5) or 0
  mos_last = now

  -- l'axe : en mode delay, la droite est « maintenant » et la gauche 4 s
  -- plus tôt ; en mode position, c'est le buffer, de son début à sa fin
  local head = fixed and state.mos_phase * 128 or 127
  local zone_a, zone_b
  -- l'étendue de SPRAY, calculée comme dans l'engine
  local spray_amt = spray * spray
  if fixed then
    zone_a = (scan - 0.5 * spray_amt) * 128
    zone_b = (scan + 0.5 * spray_amt) * 128
  else
    -- mêmes bornes que l'engine : un grain ne croise jamais l'écriture
    local min_d = dur * math.max(ratio - 1, 0) + 0.01
    local max_d = MOS_SECONDS - dur - 0.05
    local d = util.clamp(scan * parameters.MOS_SCAN_SECONDS, min_d, max_d)
    zone_a = 127 - (d + (max_d - d) * spray_amt) * PX_PER_S
    zone_b = 127 - d * PX_PER_S
  end
  local zone_lo, zone_hi = zone_a, zone_b
  if zone_hi < zone_lo then zone_lo, zone_hi = zone_hi, zone_lo end

  -- le buffer : une ligne, un repère par seconde
  screen.level(on and 3 or 1)
  screen.rect(0, VIZ_MID, 128, 1)
  screen.fill()
  for s = 0, MOS_SECONDS do
    screen.rect(math.min(127, s * PX_PER_S), VIZ_MID - 1, 1, 3)
    screen.fill()
  end

  -- Ce que contient le buffer, une colonne par pixel. En mode delay, la
  -- droite est « maintenant » et le son défile vers la gauche : la zone
  -- reste à sa distance pendant que la matière passe dessous. En mode
  -- position, l'axe est le buffer lui-même et c'est la tête qui avance.
  -- La part que les grains lisent est en clair.
  local col = state.mos_col or 0
  local zone_w = zone_hi - zone_lo
  for x = 0, 127 do
    local i = x
    if not fixed then i = (col - (127 - x)) % 128 end
    local h = env_height(state.mos_env[i + 1] or 0)
    if h > 0 then
      local lit
      if fixed then lit = ((x - zone_lo) % 128) <= zone_w
      else lit = x >= zone_lo and x <= zone_hi end
      screen.level(on and (lit and 10 or 3) or 1)
      screen.rect(x, VIZ_MID - h, 1, 2 * h + 1)
      screen.fill()
    end
  end

  -- les bords de la zone : elle reste lisible même sur un buffer silencieux
  screen.level(on and 5 or 1)
  for _, x in ipairs({ zone_lo, zone_hi }) do
    screen.rect(math.floor(x) % 128, VIZ_TOP + 2, 1, 2 * VIZ_HALF - 3)
    screen.fill()
  end
  -- la tête d'écriture : fixe si le buffer est verrouillé
  screen.level(locked and 4 or (on and 15 or 5))
  screen.rect(util.clamp(head, 0, 127), VIZ_TOP, 1, 2 * VIZ_HALF + 1)
  screen.fill()

  -- les grains : chacun naît dans la zone et suit ce qu'il lit
  if on then
    mos_acc = mos_acc + rate * dt
    while mos_acc >= mos_next do
      mos_acc = mos_acc - mos_next
      -- le prochain grain arrive plus ou moins tôt, comme dans l'engine
      mos_next = 2 ^ ((math.random() * 3 - 1.5) * rand_rate)
      if #mos_grains < 96 then
        table.insert(mos_grains, {
          x = zone_a + math.random() * (zone_b - zone_a),
          y = VIZ_MID + (math.random() * 2 - 1) * (VIZ_HALF - 6),
          born = now,
          dur = dur * 2 ^ (-3 * math.random() * rand_size),
          rev = math.random() < rand_rev,
        })
      end
    end
  else
    mos_grains = {}
  end
  for i = #mos_grains, 1, -1 do
    local g = mos_grains[i]
    local age = now - g.born
    if age >= g.dur then
      table.remove(mos_grains, i)
    else
      local dur = g.dur
      -- en mode delay, un grain à vitesse normale reste à la même distance
      -- de « maintenant » ; plus rapide, il s'en rapproche. En mode position,
      -- il avance dans le buffer à sa vitesse de lecture.
      local speed = fixed and ratio or (ratio - 1)
      -- à l'envers, il remonte le buffer
      if g.rev then speed = fixed and -ratio or (-ratio - 1) end
      local x = (g.x + speed * age * PX_PER_S) % 128
      local h = math.max(1, util.round(5 * grain_env(age / dur, contour)))
      screen.level(util.round(3 + 12 * grain_env(age / dur, contour)))
      screen.rect(x, g.y - h, 1, 2 * h)
      screen.fill()
    end
  end

  if not on then
    screen.level(0)
    screen.rect(52, VIZ_MID - 5, 24, 9)
    screen.fill()
    centered("off", 5)
  end
end

-- un réglage : nom à gauche, valeur à droite, barre fine dessous.
-- K1 maintenu : un réglage à modes affiche son mode, les autres s'effacent.
local function draw_param(entry, x)
  local id, mode = slot(entry)
  if not id then return end
  local p = params:lookup_param(id)
  local dim = shift and not mode
  screen.level(dim and 1 or 4)
  screen.move(x, 55)
  screen.text(p.name)
  -- la valeur peut être plus longue que la place laissée par le nom
  -- (« decay 100 % » par exemple) : elle passe devant, sur du noir, plutôt
  -- que de se mêler aux lettres du nom
  local value
  if shift and mode then
    value = params:string(mode)
  else
    -- le tempo peut arriver non arrondi : on l'affiche entier
    value = id == "clock_tempo" and string.format("%d", util.round(params:get(id))) or params:string(id)
  end
  local w = screen.text_extents(value)
  screen.level(0)
  screen.rect(x + 58 - w, 49, w + 3, 8)
  screen.fill()
  screen.level(dim and 2 or 15)
  screen.move(x + 60, 55)
  screen.text_right(value)
  screen.level(dim and 1 or 2)
  screen.rect(x, 59, 60, 2)
  screen.fill()
  screen.level(dim and 3 or 12)
  local r = util.clamp(raw(p), 0, 1)
  if bipolar(p) then
    local w = util.round(60 * (r - 0.5))
    screen.rect(x + 30 + math.min(w, 0), 59, math.max(math.abs(w), 1), 2)
  else
    screen.rect(x, 59, math.max(1, util.round(60 * r)), 2)
  end
  screen.fill()
end

function ui.redraw()
  if selecting then return end
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)

  draw_top()
  local st = STAGES[stage]
  if st.draw then st.draw() end

  local page = st.pages[page_of[stage]]
  draw_param(page[1], 0)
  draw_param(page[2], 68)

  screen.update()
end

return ui
