-- sculpt : les modulateurs
--
-- Quatre emplacements, chacun d'un type au choix, à la manière du S4 :
--   wave   : un LFO qu'on déforme (skew, fold, curve)
--   random : une suite de paliers au hasard
--   follow : le niveau d'un son, suivi par l'engine
-- Chaque emplacement est déclaré comme source dans le mod matrix, à côté de
-- celles de toolkit : c'est matrix qui relie une source à un réglage.
--
-- Les valeurs sont calculées ici, 30 fois par seconde. L'engine lisse les
-- réglages qu'elles déplacent ; au-delà de quelques hertz, un LFO devient
-- un escalier, d'où la vitesse libre plafonnée à 8 Hz.

local mods = {}

mods.N = 4
mods.current = 1

local TYPES = { "off", "wave", "random", "follow" }
local OFF, WAVE, RANDOM, FOLLOW = 1, 2, 3, 4
local RATE_HZ = 30
-- deux secondes de niveau gardées pour le retard de FOLLOW
local QUEUE = 64
-- ce que l'écran garde de la sortie d'un emplacement
mods.HISTORY = 100

local matrix
do
  local ok, m = pcall(require, "matrix/lib/matrix")
  if ok and type(m) == "table" then matrix = m end
end

local function id(s, name) return "mod" .. s .. "_" .. name end
local function get(s, name) return params:get(id(s, name)) end
local function source_id(s) return "sculpt_mod_" .. s end

mods.id = id

-- l'état de chaque emplacement
local slots = {}
for s = 1, mods.N do
  -- une suite de départ propre à l'emplacement, la même à chaque lancement
  local seq, x = {}, s * 7919
  for k = 1, 16 do
    x = (x * 1103515245 + 12345) % 2147483648
    seq[k] = (x / 1073741824) - 1
  end
  local hist = {}
  for i = 1, mods.HISTORY do hist[i] = 0 end
  slots[s] = {
    out = 0,        -- la sortie, -1..1
    ph = 0,         -- phase libre de WAVE, compteur de pas de RANDOM
    raw = 0,        -- position dans le cycle, 0..1, avant PHASE
    seq = seq,      -- les paliers de RANDOM
    step = 1,       -- le palier courant
    last = nil,     -- dernier numéro de pas vu
    smooth = 0,     -- la valeur lissée de RANDOM
    level = 0,      -- le dernier niveau reçu de l'engine
    queue = {}, qi = 0,
    held = 0, hph = 0, hlast = nil,
    hist = hist, hi = 0,
  }
end

function mods.slot(s) return slots[s] end
function mods.type(s) return get(s, "type") end
function mods.type_name(s) return TYPES[get(s, "type")] end

-- ------------------------------------------------------------ vitesses

-- une période, en temps (une mesure = 4 temps)
local DIVS = {
  { "4/1", 16 }, { "2/1", 8 }, { "1/1", 4 }, { "1/2", 2 }, { "1/4", 1 },
  { "1/8", 1 / 2 }, { "1/16", 1 / 4 }, { "1/32", 1 / 8 },
}

local function div_of(x)
  return DIVS[util.clamp(util.round(x * (#DIVS - 1)) + 1, 1, #DIVS)]
end

-- mode : 1 libre, 2 droit, 3 ternaire, 4 pointé. nil en mode libre.
local function period_beats(x, mode)
  if mode == 1 then return nil end
  local b = div_of(x)[2]
  if mode == 3 then b = b * 2 / 3 end
  if mode == 4 then b = b * 1.5 end
  return b
end

local function rate_hz(x, mode)
  local b = period_beats(x, mode)
  if b then return params:get("clock_tempo") / 60 / b end
  return 0.02 * (400 ^ x)
end

local function rate_string(x, mode)
  if mode == 1 then
    local hz = rate_hz(x, 1)
    return string.format(hz < 1 and "%.2f hz" or "%.1f hz", hz)
  end
  return div_of(x)[1] .. ({ "", "", "t", "." })[mode]
end

-- un cran d'encodeur : une division quand la vitesse est calée
local function rate_delta(pid, mode, d)
  if mode == 1 then return params:delta(pid, d) end
  local p = params:lookup_param(pid)
  local i = util.clamp(util.round(p:get_raw() * (#DIVS - 1)) + 1 + d, 1, #DIVS)
  p:set_raw((i - 1) / (#DIVS - 1))
end

-- ---------------------------------------------------------------- WAVE

-- La forme de l'onde à la position p du cycle (0..1), PHASE comprise.
-- Sert au calcul et au dessin.
function mods.wave_at(s, p)
  p = (p + get(s, "phase")) % 1
  -- SKEW déplace le milieu du cycle : à fond, la montée ou la descente
  -- devient presque instantanée, comme une enveloppe
  local b = 0.5 + 0.49 * get(s, "skew")
  p = p < b and (0.5 * p / b) or (0.5 + 0.5 * (p - b) / (1 - b))
  local shape = get(s, "shape")
  local v
  if shape == 1 then
    v = math.sin(2 * math.pi * p)
  elseif shape == 2 then
    v = 1 - 4 * math.abs(((p + 0.25) % 1) - 0.5)
  else
    v = p < 0.5 and 1 or -1
  end
  -- CURVE : vers le haut les sommets s'élargissent, vers le bas ils se pincent
  local c = get(s, "curve")
  if c ~= 0 then
    v = (v < 0 and -1 or 1) * (math.abs(v) ^ (2 ^ (-2 * c)))
  end
  -- FOLD : l'onde est amplifiée, et ce qui dépasse est replié
  local f = get(s, "fold")
  if f > 0 then
    v = ((v * (1 + 4 * f)) + 1) % 4
    v = v < 2 and (v - 1) or (3 - v)
  end
  return util.clamp(v + get(s, "offset"), -1, 1)
end

local function wave_value(s, st, dt)
  local x, mode = get(s, "rate"), get(s, "rate_mode")
  local beats = period_beats(x, mode)
  if beats then
    -- calé : la phase vient de l'horloge, elle ne dérive pas
    st.raw = (clock.get_beats() / beats) % 1
  else
    st.ph = (st.ph + rate_hz(x, 1) * dt) % 1
    st.raw = st.ph
  end
  return mods.wave_at(s, st.raw)
end

-- -------------------------------------------------------------- RANDOM

local function random_value(s, st, dt)
  local x, mode = get(s, "rate"), get(s, "rate_mode")
  local hz = rate_hz(x, mode)
  local beats = period_beats(x, mode)
  local pos
  if beats then
    pos = clock.get_beats() / beats
  else
    st.ph = st.ph + hz * dt
    pos = st.ph
  end
  pos = pos + get(s, "phase")
  local n = math.floor(pos)
  st.raw = pos - n
  if n ~= st.last then
    st.last = n
    local len = get(s, "length")
    st.step = (n % len) + 1
    -- VARIATION : la chance que ce palier soit retiré au sort à son tour
    if math.random() < get(s, "variation") then
      st.seq[st.step] = math.random() * 2 - 1
    end
  end
  local target = st.seq[st.step]
  local sm = get(s, "smooth")
  if sm <= 0 then
    st.smooth = target
  else
    local tau = sm * 0.5 / math.max(hz, 0.01)
    st.smooth = st.smooth + (target - st.smooth) * (1 - math.exp(-dt / tau))
  end
  return util.clamp(st.smooth + get(s, "offset"), -1, 1)
end

-- -------------------------------------------------------------- FOLLOW

-- l'engine envoie le niveau d'un emplacement (0..1)
function mods.level_in(s, v)
  local st = slots[s]
  if st then st.level = v end
end

local function follow_value(s, st, dt)
  -- le retard : on relit le niveau d'il y a quelques instants
  st.qi = (st.qi % QUEUE) + 1
  st.queue[st.qi] = st.level
  local back = util.clamp(util.round(get(s, "delay") * RATE_HZ), 0, QUEUE - 1)
  local v = st.queue[((st.qi - 1 - back) % QUEUE) + 1] or 0
  -- HOLD : le niveau n'est relevé qu'à intervalles réguliers
  local hmode = get(s, "hold_mode")
  if hmode > 1 then
    local x = get(s, "hold")
    local beats = period_beats(x, hmode - 1)
    local tick
    if beats then
      local n = math.floor(clock.get_beats() / beats)
      tick = n ~= st.hlast
      st.hlast = n
    else
      st.hph = st.hph + rate_hz(x, 1) * dt
      tick = st.hph >= 1
      if tick then st.hph = st.hph % 1 end
    end
    if tick then st.held = v end
    v = st.held
  end
  return util.clamp(v + get(s, "offset"), -1, 1)
end

-- ------------------------------------------------------------- réglages

-- les réglages de chaque type, pour ne montrer que ceux qui servent
local OWNERS = {
  rate = { WAVE, RANDOM }, rate_mode = { WAVE, RANDOM }, phase = { WAVE, RANDOM },
  offset = { WAVE, RANDOM, FOLLOW },
  shape = { WAVE }, skew = { WAVE }, fold = { WAVE }, curve = { WAVE },
  length = { RANDOM }, variation = { RANDOM }, smooth = { RANDOM },
  input = { FOLLOW }, gain = { FOLLOW }, tone = { FOLLOW }, rise = { FOLLOW },
  fall = { FOLLOW }, hold = { FOLLOW }, hold_mode = { FOLLOW }, delay = { FOLLOW },
}

local function refresh_visibility(s)
  local t = get(s, "type")
  for name, owners in pairs(OWNERS) do
    local show = false
    for _, o in ipairs(owners) do
      if o == t then show = true end
    end
    if show then params:show(id(s, name)) else params:hide(id(s, name)) end
  end
  if _menu and _menu.rebuild_params then _menu.rebuild_params() end
end

local function send_follower(s)
  engine.fol_set(s - 1, get(s, "type") == FOLLOW and 1 or 0, get(s, "input") - 1)
end

local function pct(p) return util.round(p:get() * 100) .. "%" end
local function signed(p)
  local v = util.round(p:get() * 100)
  return (v > 0 and "+" or "") .. v .. "%"
end
local function time_string(t)
  if t < 1 then return util.round(t * 1000) .. " ms" end
  return string.format("%.2f s", t)
end

-- les temps de FOLLOW, en secondes
local function rise_seconds(x) return 0.001 * (2000 ^ x) end
local function fall_seconds(x) return 0.005 * (1000 ^ x) end

function mods.add_params(deltas)
  params:add_separator("mods_sep", "modulators")
  local defaults = { WAVE, RANDOM, FOLLOW, OFF }
  for s = 1, mods.N do
    if matrix then matrix:add_bipolar(source_id(s), "mod " .. s) end
    local function add(name, label, spec, formatter, action)
      params:add_control(id(s, name), "m" .. s .. " " .. label, spec, formatter)
      if action then params:set_action(id(s, name), action) end
    end
    local unit = controlspec.new(0, 1, "lin", 0, 0)
    local bi = controlspec.new(-1, 1, "lin", 0, 0)

    params:add_option(id(s, "type"), "m" .. s .. " type", TYPES, defaults[s])
    params:set_action(id(s, "type"), function()
      refresh_visibility(s)
      send_follower(s)
    end)

    params:add_option(id(s, "rate_mode"), "m" .. s .. " rate mode",
      { "free", "straight", "triplet", "dotted" }, 1)
    add("rate", "rate", controlspec.new(0, 1, "lin", 0, 0.5), function()
      return rate_string(get(s, "rate"), get(s, "rate_mode"))
    end)
    deltas[id(s, "rate")] = function(d) rate_delta(id(s, "rate"), get(s, "rate_mode"), d) end
    add("phase", "phase", unit, pct)
    add("offset", "offset", bi, signed)

    params:add_option(id(s, "shape"), "m" .. s .. " shape", { "sine", "triangle", "square" }, 1)
    add("skew", "skew", bi, signed)
    add("fold", "fold", unit, pct)
    add("curve", "curve", bi, signed)

    params:add_number(id(s, "length"), "m" .. s .. " length", 1, 16, 8)
    add("variation", "variation", unit, pct)
    add("smooth", "smooth", unit, pct)

    params:add_option(id(s, "input"), "m" .. s .. " input", { "source", "output", "input" }, 2)
    params:set_action(id(s, "input"), function() send_follower(s) end)
    -- de 0 à +36 dB : un son faible doit pouvoir remplir la course
    add("gain", "gain", controlspec.new(0, 1, "lin", 0, 0.5), function(p)
      return "+" .. util.round(p:get() * 36) .. " dB"
    end, function(x) engine.fol_gain(s - 1, 10 ^ (x * 36 / 20)) end)
    add("tone", "tone", bi, signed, function(x) engine.fol_tone(s - 1, x) end)
    add("rise", "rise", controlspec.new(0, 1, "lin", 0, 0.3), function(p)
      return time_string(rise_seconds(p:get()))
    end, function(x) engine.fol_rise(s - 1, rise_seconds(x)) end)
    add("fall", "fall", controlspec.new(0, 1, "lin", 0, 0.5), function(p)
      return time_string(fall_seconds(p:get()))
    end, function(x) engine.fol_fall(s - 1, fall_seconds(x)) end)
    params:add_option(id(s, "hold_mode"), "m" .. s .. " hold mode",
      { "off", "free", "straight", "triplet", "dotted" }, 1)
    add("hold", "hold", controlspec.new(0, 1, "lin", 0, 0.5), function()
      local m = get(s, "hold_mode")
      if m == 1 then return "off" end
      return rate_string(get(s, "hold"), m - 1)
    end)
    deltas[id(s, "hold")] = function(d)
      rate_delta(id(s, "hold"), math.max(1, get(s, "hold_mode") - 1), d)
    end
    add("delay", "delay", unit, function(p) return time_string(p:get() * 2) end)
  end
end

-- Les pages d'un emplacement, selon son type. Les noms à l'écran sont
-- courts : dans les menus, chaque réglage porte le numéro de son emplacement.
function mods.pages(s)
  local function e(name, mode)
    return { id(s, name), mode = mode and id(s, mode) or nil, label = name }
  end
  local t = get(s, "type")
  if t == WAVE then
    return {
      { e("type"), e("rate", "rate_mode") },
      { e("shape"), e("phase") },
      { e("skew"), e("fold") },
      { e("curve"), e("offset") },
    }
  elseif t == RANDOM then
    return {
      { e("type"), e("rate", "rate_mode") },
      { e("length"), e("variation") },
      { e("smooth"), e("phase") },
      { e("offset"), false },
    }
  elseif t == FOLLOW then
    return {
      { e("type"), e("input") },
      { e("gain"), e("tone") },
      { e("rise"), e("fall") },
      { e("hold", "hold_mode"), e("delay") },
      { e("offset"), false },
    }
  end
  return { { e("type"), false } }
end

-- -------------------------------------------------------------- boucle

local loop

function mods.start()
  for s = 1, mods.N do
    refresh_visibility(s)
  end
  local last = util.time()
  loop = clock.run(function()
    while true do
      clock.sleep(1 / RATE_HZ)
      local now = util.time()
      local dt = math.min(now - last, 0.2)
      last = now
      for s = 1, mods.N do
        local st, t = slots[s], get(s, "type")
        local v = 0
        if t == WAVE then
          v = wave_value(s, st, dt)
        elseif t == RANDOM then
          v = random_value(s, st, dt)
        elseif t == FOLLOW then
          v = follow_value(s, st, dt)
        end
        st.hi = (st.hi % mods.HISTORY) + 1
        st.hist[st.hi] = v
        -- une source au repos n'a rien à redire
        if matrix and (v ~= st.out or t ~= OFF) then
          matrix:set(source_id(s), v)
        end
        st.out = v
      end
    end
  end)
end

function mods.stop()
  if loop then clock.cancel(loop) end
  loop = nil
end

mods.WAVE, mods.RANDOM, mods.FOLLOW, mods.OFF = WAVE, RANDOM, FOLLOW, OFF

return mods
