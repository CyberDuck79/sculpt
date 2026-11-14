-- sculpt : les paramètres
--
-- les réglages du menu PARAMETERS et leurs actions vers l'engine.
-- Nombres, contrôles et interrupteurs plutôt que listes quand c'est
-- possible : matrix ne module pas les listes.

local scales = include("lib/scales")

local parameters = {}

-- ce que le script partage avec nous (voir sculpt.lua)
local state

local function pct(param)
  return util.round(param:get() * 100) .. "%"
end

function parameters.add(s)
  state = s
  params:add_separator("sculpt_sep", "sculpt")

  -- le sample de la source, chargé en RAM par l'engine (5 min au plus)
  params:add_file("sample", "sample", "")
  params:set_action("sample", function(path)
    if path == nil or path == "" or path == "-" then return end
    state.loading = true
    state.failed = false
    engine.file(path)
  end)

  -- lu ici : l'argument de l'action ignore la modulation de matrix
  params:add_binary("play", "play", "toggle", 0)
  params:set_action("play", function() engine.play(params:get("play")) end)

  params:add_control("level", "level", controlspec.new(0, 2, "lin", 0, 1), pct)
  params:set_action("level", function(x) engine.level(x) end)

  -- la tonique des gammes qui placent des notes absolues (RING)
  params:add_option("root", "root", { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }, 1)
  params:set_action("root", function() parameters.send_ring_bands() end)

  parameters.add_mosaic()
  parameters.add_ring()
  parameters.add_deform()
  parameters.add_vast()
end

-- durée lisible : millisecondes, puis secondes
local function seconds(t)
  if t < 1 then return util.round(t * 1000) .. " ms" end
  return string.format("%.2f s", t)
end

-- retard maximal de SCAN en mode delay (même valeur dans l'engine)
parameters.MOS_SCAN_SECONDS = 3.5

-- Les divisions du tempo, en temps (une mesure = 4 temps). RATE va de 4
-- mesures à 1/64 comme sur le S4 ; SIZE et le retard de SCAN s'arrêtent là
-- où le buffer de 4 s ne suit plus.
local DIVS = {
  rate = {
    { "4/1", 16 }, { "2/1", 8 }, { "1/1", 4 }, { "1/2", 2 }, { "1/4", 1 },
    { "1/8", 1 / 2 }, { "1/16", 1 / 4 }, { "1/32", 1 / 8 }, { "1/64", 1 / 16 },
  },
  size = {
    { "1/64", 1 / 16 }, { "1/32", 1 / 8 }, { "1/16", 1 / 4 }, { "1/8", 1 / 2 },
    { "1/4", 1 }, { "1/2", 2 }, { "1/1", 4 },
  },
  scan = {
    { "1/32", 1 / 8 }, { "1/16", 1 / 4 }, { "1/8", 1 / 2 }, { "1/4", 1 },
    { "1/2", 2 }, { "1/1", 4 },
  },
}

-- la division que désigne un réglage, d'après sa position dans sa course
local function div_index(id, list)
  local raw = params:lookup_param(id):get_raw()
  return util.clamp(util.round(raw * (#list - 1)) + 1, 1, #list)
end

-- combien les bandes restantes de RING sont remontées quand une gamme en
-- retire : (48 / restantes) à cette puissance. Mesuré au bruit rose.
local RING_LIFT = 0.5

local function beat_seconds()
  return 60 / params:get("clock_tempo")
end

-- un réglage calé avance d'une division par cran
local function div_delta(id, list, d)
  local p = params:lookup_param(id)
  local i = util.clamp(div_index(id, list) + d, 1, #list)
  p:set_raw((i - 1) / (#list - 1))
end

local function rate_synced() return params:get("mos_rate_mode") == 2 end
local function size_synced() return params:get("mos_size_mode") == 2 end
local function scan_mode() return params:get("mos_scan_mode") end

-- grains par seconde
function parameters.mos_rate_hz()
  if not rate_synced() then return params:get("mos_rate") end
  local beats = DIVS.rate[div_index("mos_rate", DIVS.rate)][2]
  return util.clamp(1 / (beats * beat_seconds()), 0.02, 64)
end

-- durée d'un grain, en secondes
function parameters.mos_size_seconds()
  if not size_synced() then return params:get("mos_size") end
  local beats = DIVS.size[div_index("mos_size", DIVS.size)][2]
  return util.clamp(beats * beat_seconds(), 0.005, 2)
end

-- SCAN tel que l'engine l'attend : 0..1. En delay c'est une part du retard
-- maximal, en position un point du buffer, en stretch la moitié de la vitesse.
function parameters.mos_scan_value()
  if scan_mode() ~= 2 then return params:get("mos_scan") end
  local beats = DIVS.scan[div_index("mos_scan", DIVS.scan)][2]
  return util.clamp(beats * beat_seconds() / parameters.MOS_SCAN_SECONDS, 0, 1)
end

-- la hauteur réellement jouée : calée sur la gamme
function parameters.mos_pitch_semis()
  return scales.snap(params:get("mos_scale"), params:get("mos_pitch"))
end

-- Le motif de PATTERN : 8 nombres entre -1 et 1, toujours les mêmes pour un
-- numéro de motif donné. Le premier est 0 : le motif part de la hauteur de
-- PITCH. Un générateur à part, pour ne pas dépendre de math.random.
function parameters.mos_pattern_shape()
  local x = params:get("mos_pattern_seed") * 7919
  local out = { 0 }
  for k = 2, 8 do
    x = (x * 1103515245 + 12345) % 2147483648
    out[k] = (x / 1073741824) - 1
  end
  return out
end

-- les 8 notes du motif, en demi-tons : jusqu'à une octave de part et d'autre
function parameters.mos_pattern_semis()
  local scale, amount = params:get("mos_scale"), params:get("mos_pattern")
  local out = {}
  for k, r in ipairs(parameters.mos_pattern_shape()) do
    out[k] = scales.snap(scale, r * amount * 12)
  end
  return out
end

local function send_pattern()
  engine.mos_pat(table.unpack(parameters.mos_pattern_semis()))
  engine.mos_pattern(params:get("mos_pattern"))
end

local function send_rand_pitch_mode()
  local mode = params:get("mos_rand_pitch_mode")
  -- sans gamme, les notes au hasard sont libres
  if mode == 2 and scales.is_free(params:get("mos_scale")) then mode = 3 end
  engine.mos_rand_pitch_mode(mode - 1)
end

-- Recale la cadence des grains sur la prochaine mesure. L'engine garde
-- ensuite le pas tout seul : son horloge et celle de norns ne dérivent que
-- de quelques millisecondes sur plusieurs minutes.
local resync
local function mos_resync()
  if resync then clock.cancel(resync) end
  resync = clock.run(function()
    clock.sync(4)
    resync = nil
    if rate_synced() then engine.mos_sync(1) end
  end)
end

local function send_rate()
  engine.mos_rate(parameters.mos_rate_hz())
  if rate_synced() then mos_resync() end
end
local function send_size() engine.mos_size(parameters.mos_size_seconds()) end
local function send_scan() engine.mos_scan(parameters.mos_scan_value()) end

-- le tempo a changé : ce qui est calé dessus suit
function parameters.mos_tempo_changed()
  if rate_synced() then send_rate() end
  if size_synced() then send_size() end
  if scan_mode() == 2 then send_scan() end
end

-- Les réglages dont un cran d'encodeur n'est pas un centième de course :
-- PITCH saute de note en note, un réglage calé de division en division.
parameters.deltas = {
  mos_pitch = function(d)
    local scale = params:get("mos_scale")
    if scales.is_free(scale) then
      params:set("mos_pitch", params:get("mos_pitch") + d * 0.1)
    else
      params:set("mos_pitch", scales.step(scale, params:get("mos_pitch"), d, -24, 24))
    end
  end,
  mos_rate = function(d)
    if rate_synced() then div_delta("mos_rate", DIVS.rate, d) else params:delta("mos_rate", d) end
  end,
  mos_size = function(d)
    if size_synced() then div_delta("mos_size", DIVS.size, d) else params:delta("mos_size", d) end
  end,
  mos_scan = function(d)
    if scan_mode() == 2 then div_delta("mos_scan", DIVS.scan, d) else params:delta("mos_scan", d) end
  end,
}

-- MOSAIC : granulaire sur les 4 dernières secondes du flux
function parameters.add_mosaic()
  params:add_separator("mosaic_sep", "mosaic")

  -- les effets sont éteints au départ. Lu ici : l'argument de l'action
  -- ignore la modulation de matrix
  params:add_binary("mos_on", "mosaic on", "toggle", 0)
  params:set_action("mos_on", function()
    local on = params:get("mos_on")
    -- l'engine vide son buffer en s'éteignant : l'écran suit. Verrouillé,
    -- le buffer est gardé des deux côtés.
    local locked = params.lookup["mos_lock"] and params:get("mos_lock") == 1
    if on == 0 and locked ~= true then state.clear_mos_env() end
    engine.mos_bypass(1 - on)
  end)
  params:add_binary("mos_lock", "lock", "toggle", 0)
  params:set_action("mos_lock", function() engine.mos_lock(params:get("mos_lock")) end)

  -- La gamme de MOSAIC : PITCH, le motif et les notes au hasard s'y calent.
  -- Ce sont des intervalles par rapport au son qui entre, pas des notes
  -- absolues : il n'y a pas de tonique à choisir.
  params:add_option("mos_scale", "scale", scales.NAMES, 1)
  params:set_action("mos_scale", function(i)
    engine.mos_pitch(parameters.mos_pitch_semis())
    engine.mos_snap(table.unpack(scales.classes(i)))
    send_pattern()
    send_rand_pitch_mode()
  end)
  params:add_control("mos_pitch", "pitch", controlspec.new(-24, 24, "lin", 0, 0), function()
    local v = parameters.mos_pitch_semis()
    local text = v == math.floor(v) and string.format("%d", v) or string.format("%.1f", v)
    return (v > 0 and "+" or "") .. text .. " st"
  end)
  params:set_action("mos_pitch", function() engine.mos_pitch(parameters.mos_pitch_semis()) end)

  params:add_option("mos_rate_mode", "rate mode", { "free", "sync" }, 1)
  params:set_action("mos_rate_mode", send_rate)
  params:add_control("mos_rate", "rate", controlspec.new(0.25, 64, "exp", 0, 8), function(p)
    if rate_synced() then return DIVS.rate[div_index("mos_rate", DIVS.rate)][1] end
    return string.format(p:get() < 10 and "%.1f hz" or "%.0f hz", p:get())
  end)
  params:set_action("mos_rate", send_rate)

  params:add_option("mos_size_mode", "size mode", { "free", "sync" }, 1)
  params:set_action("mos_size_mode", send_size)
  params:add_control("mos_size", "size", controlspec.new(0.005, 1, "exp", 0, 0.15), function(p)
    if size_synced() then return DIVS.size[div_index("mos_size", DIVS.size)][1] end
    return seconds(p:get())
  end)
  params:set_action("mos_size", send_size)
  -- Forme du grain : au centre une cloche, vers le bas une attaque franche
  -- qui s'éteint, vers le haut une montée. Affiché en pourcentage signé,
  -- comme sur le S4 : les mots ne tiennent pas à côté du nom du réglage.
  params:add_control("mos_contour", "contour", controlspec.new(-1, 1, "lin", 0, 0), function(p)
    local v = util.round(p:get() * 100)
    return (v > 0 and "+" or "") .. v .. "%"
  end)
  params:set_action("mos_contour", function(x) engine.mos_contour(x) end)

  -- Où les grains lisent : un retard derrière l'écriture (en secondes ou
  -- calé sur le tempo), un point fixe, ou une tête qui avance à sa vitesse.
  params:add_option("mos_scan_mode", "scan mode", { "delay", "sync", "position", "stretch" }, 1)
  params:set_action("mos_scan_mode", function(i)
    engine.mos_scan_mode(({ 0, 0, 1, 2 })[i])
    send_scan()
  end)
  params:add_control("mos_scan", "scan", controlspec.new(0, 1, "lin", 0, 0.1), function(p)
    local mode = scan_mode()
    if mode == 1 then return seconds(p:get() * parameters.MOS_SCAN_SECONDS) end
    if mode == 2 then return DIVS.scan[div_index("mos_scan", DIVS.scan)][1] end
    -- stretch : la vitesse de la lecture par rapport à l'écriture
    if mode == 4 then return util.round(p:get() * 200) .. "%" end
    return pct(p)
  end)
  params:set_action("mos_scan", send_scan)
  params:add_option("mos_spray_mode", "spray mode", { "random", "warp" }, 1)
  params:set_action("mos_spray_mode", function(i) engine.mos_spray_mode(i - 1) end)
  params:add_control("mos_spray", "spray", controlspec.new(0, 1, "lin", 0, 0.1), pct)
  params:set_action("mos_spray", function(x) engine.mos_spray(x) end)

  params:add_control("mos_feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("mos_feedback", function(x) engine.mos_feedback(x) end)
  params:add_control("mos_wet", "wet", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("mos_wet", function(x) engine.mos_wet(x) end)

  -- PATTERN : un motif fixe de 8 notes, une par grain. Le réglage dose son
  -- étendue, le numéro choisit le motif.
  params:add_number("mos_pattern_seed", "pattern number", 1, 32, 1)
  params:set_action("mos_pattern_seed", send_pattern)
  params:add_control("mos_pattern", "pattern", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("mos_pattern", send_pattern)

  -- le hasard, tiré pour chaque grain
  params:add_option("mos_rand_pitch_mode", "rnd pitch mode", { "detune", "random" }, 1)
  params:set_action("mos_rand_pitch_mode", send_rand_pitch_mode)
  for _, r in ipairs {
    { "pitch", "randPitch" }, { "rate", "randRate" }, { "size", "randSize" },
    { "amp", "randAmp" }, { "rev", "randRev" },
  } do
    local id = "mos_rand_" .. r[1]
    params:add_control(id, "rnd " .. r[1], controlspec.new(0, 1, "lin", 0, 0), pct)
    params:set_action(id, function(x) engine["mos_" .. r[2]](x) end)
  end
end

-- pourcentage signé, comme contour : les mots ne tiennent pas à côté du nom
local function signed(p)
  local v = util.round(p:get() * 100)
  return (v > 0 and "+" or "") .. v .. "%"
end

-- RING : un banc de 48 filtres résonnants
-- RING : la place des 48 bandes. Sans gamme, elles sont à intervalle égal
-- de 40 Hz à 16 kHz. Avec une gamme, chacune va sur la note la plus proche ;
-- quand plusieurs tombent sur la même note, une seule reste. Les bandes qui
-- restent sont remontées pour que le niveau ne s'effondre pas avec leur
-- nombre.
parameters.RING_BANDS, parameters.RING_SPAN = 48, 8.64

function parameters.ring_bands()
  local nb, scale, root = parameters.RING_BANDS, params:get("ring_scale"), params:get("root") - 1
  local freqs, mute, kept = {}, {}, 0
  local last
  for i = 1, nb do
    local f = 40 * 2 ^ ((i - 1) * parameters.RING_SPAN / (nb - 1))
    local on = 1
    if not scales.is_free(scale) then
      local midi = 69 + 12 * math.log(f / 440, 2)
      local note = root + scales.snap(scale, midi - root)
      f = 440 * 2 ^ ((note - 69) / 12)
      if note == last then on = 0 end
      last = note
    end
    freqs[i], mute[i] = f, on
    kept = kept + on
  end
  local lift = (nb / kept) ^ RING_LIFT
  for i = 1, nb do mute[i] = mute[i] * lift end
  return freqs, mute
end

function parameters.send_ring_bands()
  local freqs, mute = parameters.ring_bands()
  engine.ring_freqs(table.unpack(freqs))
  engine.ring_mute(table.unpack(mute))
end

-- Vitesse de WAVES et de NOISE : libre, de 0,05 à 20 Hz, ou une période
-- calée sur le tempo. Ternaire : un tiers plus court ; pointé : moitié plus long.
local LFO_DIVS = {
  { "4/1", 16 }, { "2/1", 8 }, { "1/1", 4 }, { "1/2", 2 }, { "1/4", 1 },
  { "1/8", 1 / 2 }, { "1/16", 1 / 4 },
}

local function lfo_hz(id)
  local mode = params:get(id .. "_mode")
  if mode == 1 then return 0.05 * (400 ^ params:get(id)) end
  local beats = LFO_DIVS[div_index(id, LFO_DIVS)][2]
  if mode == 3 then beats = beats * 2 / 3 end
  if mode == 4 then beats = beats * 1.5 end
  return 1 / (beats * beat_seconds())
end
parameters.lfo_hz = lfo_hz

local function lfo_string(id)
  local mode = params:get(id .. "_mode")
  if mode == 1 then
    local hz = lfo_hz(id)
    return string.format(hz < 10 and "%.2f hz" or "%.1f hz", hz)
  end
  return LFO_DIVS[div_index(id, LFO_DIVS)][1] .. ({ "", "", "t", "." })[mode]
end

local function send_ring_rates()
  engine.ring_wavesRate(lfo_hz("ring_waves_rate"))
  engine.ring_noiseRate(lfo_hz("ring_noise_rate"))
end

function parameters.ring_tempo_changed()
  send_ring_rates()
end

for _, id in ipairs { "ring_waves_rate", "ring_noise_rate" } do
  parameters.deltas[id] = function(d)
    if params:get(id .. "_mode") > 1 then div_delta(id, LFO_DIVS, d) else params:delta(id, d) end
  end
end

function parameters.add_ring()
  params:add_separator("ring_sep", "ring")

  params:add_binary("ring_on", "ring on", "toggle", 0)
  params:set_action("ring_on", function() engine.ring_bypass(1 - params:get("ring_on")) end)

  params:add_control("ring_cutoff", "cutoff", controlspec.new(40, 16000, "exp", 0, 16000), function(p)
    local f = p:get()
    if f < 1000 then return util.round(f) .. " hz" end
    return string.format("%.1fk", f / 1000)
  end)
  params:set_action("ring_cutoff", function(x) engine.ring_cutoff(x) end)
  -- bosse du profil autour de la coupure
  params:add_control("ring_reso", "resonance", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("ring_reso", function(x) engine.ring_reso(x) end)

  -- choke : le profil coupe aussi les bandes qui sonnent ; sustain : elles
  -- finissent de sonner quand le profil se referme
  params:add_option("ring_decay_mode", "decay mode", { "choke", "sustain" }, 1)
  params:set_action("ring_decay_mode", function(i) engine.ring_sustain(i - 1) end)
  -- combien de temps chaque bande continue de sonner
  params:add_control("ring_decay", "decay", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("ring_decay", function(x) engine.ring_decay(x) end)
  -- incline cette durée : vers le haut les aigus sonnent plus longtemps
  params:add_control("ring_tilt", "tilt", controlspec.new(-1, 1, "lin", 0, 0), signed)
  params:set_action("ring_tilt", function(x) engine.ring_tilt(x) end)

  -- -100 % passe-bas, 0 passe-bande, +100 % passe-haut
  params:add_control("ring_slope", "slope", controlspec.new(-1, 1, "lin", 0, -1), signed)
  params:set_action("ring_slope", function(x) engine.ring_slope(x) end)
  -- pente générale : vers le haut, plus d'aigus
  params:add_control("ring_tone", "tone", controlspec.new(-1, 1, "lin", 0, 0), signed)
  params:set_action("ring_tone", function(x) engine.ring_tone(x) end)

  -- La gamme des bandes. La tonique est un réglage général (SET).
  params:add_option("ring_scale", "scale", scales.NAMES, scales.FREE)
  params:set_action("ring_scale", parameters.send_ring_bands)
  params:add_number("ring_pitch", "pitch", -24, 24, 0, function(p)
    local v = p:get()
    return (v > 0 and "+" or "") .. v .. " st"
  end)
  params:set_action("ring_pitch", function(x) engine.ring_pitch(x) end)
  params:add_control("ring_wet", "wet", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("ring_wet", function(x) engine.ring_wet(x) end)

  -- le niveau des bandes ondule, en vague qui parcourt le banc
  params:add_control("ring_waves", "waves", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("ring_waves", function(x) engine.ring_waves(x) end)
  -- le niveau de chaque bande bouge au hasard
  params:add_control("ring_noise", "noise", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("ring_noise", function(x) engine.ring_noise(x) end)
  for _, r in ipairs { { "ring_waves_rate", "waves r", 0.5 }, { "ring_noise_rate", "noise r", 0.6 } } do
    params:add_option(r[1] .. "_mode", r[2] .. " mode", { "free", "straight", "triplet", "dotted" }, 1)
    params:set_action(r[1] .. "_mode", send_ring_rates)
    params:add_control(r[1], r[2], controlspec.new(0, 1, "lin", 0, r[3]), function()
      return lfo_string(r[1])
    end)
    params:set_action(r[1], send_ring_rates)
  end
  -- la place des bandes flotte, à part pour chaque côté
  params:add_control("ring_detune", "detune", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("ring_detune", function(x) engine.ring_detune(x) end)
end

-- fréquence lisible
local function hz(p)
  local f = p:get()
  if f < 1000 then return util.round(f) .. " hz" end
  return string.format("%.1fk", f / 1000)
end

-- les trois coupures du S4
parameters.DEF_XOVER = { 80, 650, 2500 }

-- DEFORM : distorsion en deux bandes, avec un bruit qui suit le signal
function parameters.add_deform()
  params:add_separator("def_sep", "deform")

  params:add_binary("def_on", "deform on", "toggle", 0)
  params:set_action("def_on", function() engine.def_bypass(1 - params:get("def_on")) end)

  params:add_control("def_drive", "drive", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("def_drive", function(x) engine.def_drive(x) end)
  -- la valeur dit ce que fait le mode choisi : des bits, ou une fréquence
  params:add_control("def_crush", "crush", controlspec.new(0, 1, "lin", 0, 0), function(p)
    local mode = params:get("def_crush_mode")
    if mode == 1 then return string.format("%.1f b", 12 - (p:get() * 8)) end
    if mode == 2 then
      local f = 20000 * ((700 / 20000) ^ p:get())
      return f < 1000 and (util.round(f) .. " hz") or string.format("%.1fk", f / 1000)
    end
    return pct(p)
  end)
  params:set_action("def_crush", function(x) engine.def_crush(x) end)
  params:add_option("def_crush_mode", "crush mode", { "bits", "redux", "both" }, 1)
  params:set_action("def_crush_mode", function(i) engine.def_crushMode(i - 1) end)

  params:add_control("def_comp", "compress", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("def_comp", function(x) engine.def_comp(x) end)
  -- vers le bas les graves saturent les premiers, vers le haut les aigus
  params:add_control("def_tilt", "tilt", controlspec.new(-1, 1, "lin", 0, 0), signed)
  params:set_action("def_tilt", function(x) engine.def_tilt(x) end)
  params:add_option("def_xover", "crossover", { "80 hz", "650 hz", "2.5k" }, 2)
  params:set_action("def_xover", function(i) engine.def_xover(parameters.DEF_XOVER[i]) end)

  params:add_control("def_noise", "noise", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("def_noise", function(x) engine.def_noise(x) end)
  params:add_option("def_noise_type", "noise type", { "white", "pink", "dust" }, 2)
  params:set_action("def_noise_type", function(i) engine.def_noiseType(i - 1) end)
  params:add_control("def_noise_decay", "decay", controlspec.new(0.01, 2, "exp", 0, 0.2), function(p)
    return seconds(p:get())
  end)
  params:set_action("def_noise_decay", function(x) engine.def_noiseDecay(x) end)
  params:add_control("def_noise_tone", "tone", controlspec.new(100, 8000, "exp", 0, 1200), hz)
  params:set_action("def_noise_tone", function(x) engine.def_noiseTone(x) end)

  params:add_control("def_wet", "wet", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("def_wet", function(x) engine.def_wet(x) end)

end

-- VAST : les divisions de TIME quand il est calé sur le tempo, en temps
parameters.TIME_DIVS = { 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4 }

-- Le retard en secondes : libre, ou calé sur le tempo de l'horloge. Le mode
-- ternaire raccourcit d'un tiers, le pointé rallonge de moitié.
function parameters.vast_time_seconds()
  local mode = params:get("vast_time_mode")
  local x = params:get("vast_time")
  if mode == 1 then return 0.01 * (200 ^ x) end
  local divs = parameters.TIME_DIVS
  local beats = divs[util.clamp(util.round(x * (#divs - 1)) + 1, 1, #divs)]
  if mode == 3 then beats = beats * 2 / 3 end
  if mode == 4 then beats = beats * 1.5 end
  return util.clamp(beats * 60 / params:get("clock_tempo"), 0.01, 2)
end

local function send_time()
  engine.vast_time(parameters.vast_time_seconds())
end

-- VAST : un delay et une réverbe, chacun avec son dosage
function parameters.add_vast()
  params:add_separator("vast_sep", "vast")

  params:add_binary("vast_on", "vast on", "toggle", 0)
  params:set_action("vast_on", function() engine.vast_bypass(1 - params:get("vast_on")) end)

  params:add_control("vast_dly", "delay", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("vast_dly", function(x) engine.vast_dlyMix(x) end)
  params:add_control("vast_time", "time", controlspec.new(0, 1, "lin", 0, 0.5), function()
    local t = parameters.vast_time_seconds()
    return t < 1 and (util.round(t * 1000) .. " ms") or string.format("%.2f s", t)
  end)
  params:set_action("vast_time", send_time)
  params:add_option("vast_time_mode", "time mode", { "free", "straight", "triplet", "dotted" }, 1)
  params:set_action("vast_time_mode", send_time)

  params:add_control("vast_feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0.4), pct)
  params:set_action("vast_feedback", function(x) engine.vast_feedback(x) end)
  -- ce qui anime le delay : décalage entre les côtés, renvoi d'un côté à
  -- l'autre, ou diffusion dans la boucle
  params:add_control("vast_spread", "spread", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("vast_spread", function(x) engine.vast_spread(x) end)
  params:add_option("vast_spread_mode", "spread mode", { "phase", "ping pong", "diffuse" }, 1)
  params:set_action("vast_spread_mode", function(i) engine.vast_spreadMode(i - 1) end)

  params:add_control("vast_rev", "reverb", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("vast_rev", function(x) engine.vast_revMix(x) end)
  params:add_control("vast_size", "size", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("vast_size", function(x) engine.vast_size(x) end)

  params:add_control("vast_decay", "decay", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("vast_decay", function(x) engine.vast_decay(x) end)
  -- un seul réglage : passe-bas vers le bas, passe-haut vers le haut
  params:add_control("vast_tone", "tone", controlspec.new(-1, 1, "lin", 0, 0), signed)
  params:set_action("vast_tone", function(x) engine.vast_tone(x) end)

  params:add_binary("vast_freeze", "freeze", "toggle", 0)
  params:set_action("vast_freeze", function() engine.vast_freeze(params:get("vast_freeze")) end)
end

return parameters
