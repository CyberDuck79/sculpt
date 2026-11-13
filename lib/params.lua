-- sculpt : les paramètres
--
-- les réglages du menu PARAMETERS et leurs actions vers l'engine.
-- Nombres, contrôles et interrupteurs plutôt que listes quand c'est
-- possible : matrix ne module pas les listes.

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

  parameters.add_mosaic()
  parameters.add_ring()
  parameters.add_deform()
end

-- durée lisible : millisecondes, puis secondes
local function seconds(t)
  if t < 1 then return util.round(t * 1000) .. " ms" end
  return string.format("%.2f s", t)
end

-- retard maximal de SCAN en mode delay (même valeur dans l'engine)
parameters.MOS_SCAN_SECONDS = 3.5

-- MOSAIC : granulaire sur les 4 dernières secondes du flux
function parameters.add_mosaic()
  params:add_separator("mosaic_sep", "mosaic")

  -- les effets sont éteints au départ. Lu ici : l'argument de l'action
  -- ignore la modulation de matrix
  params:add_binary("mos_on", "mosaic on", "toggle", 0)
  params:set_action("mos_on", function()
    local on = params:get("mos_on")
    -- l'engine vide son buffer en s'éteignant : l'écran suit
    if on == 0 then state.clear_mos_env() end
    engine.mos_bypass(1 - on)
  end)
  params:add_binary("mos_lock", "lock", "toggle", 0)
  params:set_action("mos_lock", function() engine.mos_lock(params:get("mos_lock")) end)

  params:add_number("mos_pitch", "pitch", -24, 24, 0, function(p)
    local v = p:get()
    return (v > 0 and "+" or "") .. v .. " st"
  end)
  params:set_action("mos_pitch", function(x) engine.mos_pitch(x) end)
  params:add_control("mos_rate", "rate", controlspec.new(0.25, 64, "exp", 0, 8), function(p)
    return string.format(p:get() < 10 and "%.1f hz" or "%.0f hz", p:get())
  end)
  params:set_action("mos_rate", function(x) engine.mos_rate(x) end)

  params:add_control("mos_size", "size", controlspec.new(0.005, 1, "exp", 0, 0.15), function(p)
    return seconds(p:get())
  end)
  params:set_action("mos_size", function(x) engine.mos_size(x) end)
  -- Forme du grain : au centre une cloche, vers le bas une attaque franche
  -- qui s'éteint, vers le haut une montée. Affiché en pourcentage signé,
  -- comme sur le S4 : les mots ne tiennent pas à côté du nom du réglage.
  params:add_control("mos_contour", "contour", controlspec.new(-1, 1, "lin", 0, 0), function(p)
    local v = util.round(p:get() * 100)
    return (v > 0 and "+" or "") .. v .. "%"
  end)
  params:set_action("mos_contour", function(x) engine.mos_contour(x) end)

  -- où les grains lisent : un retard derrière l'écriture, ou un point fixe
  params:add_option("mos_scan_mode", "scan mode", { "delay", "position" }, 1)
  params:set_action("mos_scan_mode", function(i) engine.mos_scan_mode(i - 1) end)
  params:add_control("mos_scan", "scan", controlspec.new(0, 1, "lin", 0, 0.1), function(p)
    if params:get("mos_scan_mode") == 1 then
      return seconds(p:get() * parameters.MOS_SCAN_SECONDS)
    end
    return pct(p)
  end)
  params:set_action("mos_scan", function(x) engine.mos_scan(x) end)
  params:add_control("mos_spray", "spray", controlspec.new(0, 1, "lin", 0, 0.1), pct)
  params:set_action("mos_spray", function(x) engine.mos_spray(x) end)

  params:add_control("mos_feedback", "feedback", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("mos_feedback", function(x) engine.mos_feedback(x) end)
  params:add_control("mos_wet", "wet", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("mos_wet", function(x) engine.mos_wet(x) end)
end

-- pourcentage signé, comme contour : les mots ne tiennent pas à côté du nom
local function signed(p)
  local v = util.round(p:get() * 100)
  return (v > 0 and "+" or "") .. v .. "%"
end

-- RING : un banc de 48 filtres résonnants
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

  params:add_number("ring_pitch", "pitch", -24, 24, 0, function(p)
    local v = p:get()
    return (v > 0 and "+" or "") .. v .. " st"
  end)
  params:set_action("ring_pitch", function(x) engine.ring_pitch(x) end)
  params:add_control("ring_wet", "wet", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("ring_wet", function(x) engine.ring_wet(x) end)
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

  -- Trois réglages en cours de calage, qui n'ont pas de page à l'écran :
  -- une fois la valeur choisie à l'oreille, ils deviendront des constantes
  -- et disparaîtront d'ici. Le S4 n'expose rien de tout ça non plus.
  params:add_separator("def_cal_sep", "deform : calage")
  -- 1 = pas de companding ; plus bas, plus les niveaux faibles gardent de
  -- la résolution (0,5 revient à quantifier la racine du signal)
  params:add_control("def_law", "law", controlspec.new(0.3, 1, "lin", 0, 1), function(p)
    return string.format("%.2f", p:get())
  end)
  params:set_action("def_law", function(x) engine.def_law(x) end)
  -- l'erreur de quantification, retirée (négatif) ou accentuée (positif)
  params:add_control("def_grain", "grain", controlspec.new(-0.6, 0.6, "lin", 0, 0), signed)
  params:set_action("def_grain", function(x) engine.def_grain(x) end)
  params:add_control("def_grain_tone", "grain tone", controlspec.new(100, 8000, "exp", 0, 2000), hz)
  params:set_action("def_grain_tone", function(x) engine.def_grainTone(x) end)
end

return parameters
