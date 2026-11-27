-- sculpt : la bande
--
-- La source a deux matières : un fichier, ou une bande qu'on enregistre.
-- La bande remplit le buffer que relit le même lecteur : région, vitesse,
-- sens et calage s'y appliquent comme à un fichier.
--
-- États : empty (rien), armed (attend la mesure), rec (première prise),
-- play, dub (overdub), stop.

local tape = {}

local state, parameters

tape.state = "empty"
-- durée maximale d'une prise, un peu sous celle du buffer de l'engine
local MAX_SECONDS = 118
local COLS = 128

-- la prise en cours : ses niveaux (30 par seconde), son départ en temps
local levels = {}
local start_beat
local waiting      -- la coroutine qui attend une mesure
local sample_rate = 48000

-- ce que l'écran montre du fichier, mis de côté pendant qu'on est sur la bande
local file_view = { wave = nil, seconds = 0 }
local tape_view = { wave = nil, seconds = 0 }

function tape.init(s, p)
  state, parameters = s, p
end

function tape.on()
  return params:get("src_material") == 2
end

local function cancel_wait()
  if waiting then clock.cancel(waiting) end
  waiting = nil
end

-- l'écran passe d'une matière à l'autre
local function show(view)
  state.wave, state.seconds = view.wave, view.seconds
  state.failed = false
  parameters.src_refresh()
end

-- un fichier vient d'être chargé : c'est lui qu'on regarde
function tape.file_loaded()
  file_view.wave, file_view.seconds = state.wave, state.seconds
  if tape.on() then params:set("src_material", 1) end
end

function tape.material_changed()
  cancel_wait()
  if tape.state == "rec" or tape.state == "armed" then tape.state = "empty" end
  engine.tape_rec(0)
  engine.tape_dub(0)
  if tape.state == "dub" then tape.state = "play" end
  engine.tape_mode(tape.on() and 1 or 0)
  if tape.on() then
    show(tape_view)
    -- le lecteur ne joue la bande que s'il y a quelque chose dessus
    if tape_view.seconds <= 0 then params:set("play", 0) end
  else
    show(file_view)
  end
end

local function bar_beats() return 4 end

-- ------------------------------------------------------------- la prise

local function begin_rec()
  levels = {}
  start_beat = clock.get_beats()
  tape.state = "rec"
  params:set("play", 0, true)
  engine.tape_rec(1)
  -- longueur fixée : la prise se ferme toute seule
  local bars = ({ 0, 1, 2, 4, 8 })[params:get("tape_bars")]
  if bars > 0 then
    waiting = clock.run(function()
      local target = start_beat + bars * bar_beats()
      while clock.get_beats() < target - 0.001 do clock.sleep(0.005) end
      waiting = nil
      tape.close(bars * bar_beats())
    end)
  else
    waiting = clock.run(function()
      clock.sleep(MAX_SECONDS)
      waiting = nil
      tape.close()
    end)
  end
end

function tape.rec()
  if not tape.on() then return end
  cancel_wait()
  if params:get("tape_start") == 2 then
    tape.state = "armed"
    waiting = clock.run(function()
      clock.sync(bar_beats())
      waiting = nil
      begin_rec()
    end)
  else
    begin_rec()
  end
end

-- Ferme la prise. beats : la longueur voulue, en temps, quand elle est
-- imposée ; sinon, une prise partie sur la mesure est arrondie à la mesure.
function tape.close(beats)
  if tape.state ~= "rec" then return end
  cancel_wait()
  local played = clock.get_beats() - start_beat
  if not beats and params:get("tape_start") == 2 then
    beats = math.max(1, util.round(played / bar_beats())) * bar_beats()
    if beats > played + 0.02 then
      -- la mesure n'est pas finie : on enregistre jusqu'à son bout
      local target = start_beat + beats
      waiting = clock.run(function()
        while clock.get_beats() < target - 0.001 do clock.sleep(0.005) end
        waiting = nil
        tape.close(beats)
      end)
      return
    end
  end
  tape.pending_beats = beats
  tape.state = "play"
  engine.tape_rec(0)
end

-- L'engine dit la longueur de la prise, en images. Calée, on lui rend la
-- longueur exacte : un nombre entier de temps au tempo de l'horloge.
function tape.length_in(frames, sr)
  sample_rate = sr or sample_rate
  local beats = tape.pending_beats
  tape.pending_beats = nil
  if beats then
    frames = beats * clock.get_beat_sec() * sample_rate
    engine.tape_len(frames)
    -- le lecteur sait alors se caler tout seul
    params:set("src_bpm", util.clamp(util.round(params:get("clock_tempo")), 40, 240))
  end
  local seconds = frames / sample_rate
  -- la forme d'onde : le plus fort de chaque colonne
  local wave = {}
  local n = math.max(1, math.floor(seconds * 30))
  for c = 1, COLS do
    local a = math.floor((c - 1) * n / COLS) + 1
    local b = math.max(a, math.floor(c * n / COLS))
    local top = 0
    for i = a, b do top = math.max(top, levels[i] or 0) end
    wave[c] = top
  end
  tape_view.wave, tape_view.seconds = wave, seconds
  params:set("src_start", 0)
  params:set("src_length", 1)
  params:set("play", 1, true)
  if tape.on() then show(tape_view) end
end

-- pendant une prise ou un overdub : le niveau qui s'écrit, et où
function tape.level_in(wph, amp, ph)
  if tape.state == "rec" then
    table.insert(levels, amp)
  elseif tape.state == "dub" and tape_view.wave and tape_view.seconds > 0 then
    local c = math.floor(ph / (tape_view.seconds * sample_rate) * COLS) % COLS + 1
    tape_view.wave[c] = math.max(tape_view.wave[c] or 0, amp)
  end
end

-- les derniers niveaux de la prise en cours, pour l'écran
function tape.live() return levels end
function tape.elapsed()
  if tape.state ~= "rec" or not start_beat then return 0 end
  return (clock.get_beats() - start_beat) * clock.get_beat_sec()
end

-- ---------------------------------------------------------- les touches

-- K3 : enregistrer, fermer, puis overdub
function tape.k3()
  local st = tape.state
  if st == "empty" then
    tape.rec()
  elseif st == "armed" then
    cancel_wait()
    tape.state = "empty"
  elseif st == "rec" then
    tape.close()
  elseif st == "play" then
    tape.state = "dub"
    engine.tape_dub(1)
  elseif st == "dub" then
    tape.state = "play"
    engine.tape_dub(0)
  elseif st == "stop" then
    -- à l'arrêt : repartir en overdub
    params:set("play", 1)
    tape.state = "dub"
    engine.tape_dub(1)
  end
end

function tape.k3_label()
  local st = tape.state
  if st == "armed" then return "ARM", true, true end
  if st == "rec" then return "REC", true, true end
  if st == "dub" then return "DUB", true, true end
  if st == "empty" then return "REC", false, false end
  return "DUB", false, false
end

-- K3 tenu : effacer la bande
function tape.clear()
  cancel_wait()
  engine.tape_clear(1)
  tape.state = "empty"
  levels = {}
  tape_view.wave, tape_view.seconds = nil, 0
  params:set("play", 0, true)
  if tape.on() then show(tape_view) end
end

-- K2 pendant une prise : la fermer
function tape.recording()
  return tape.state == "rec" or tape.state == "armed"
end

-- la lecture a été lancée ou arrêtée
function tape.play_changed(on)
  if not tape.on() then return end
  if tape.state == "dub" and on == 0 then engine.tape_dub(0) end
  if tape.state == "play" or tape.state == "dub" or tape.state == "stop" then
    tape.state = on == 1 and "play" or "stop"
  end
end

-- K2 tenu : écrire la bande dans un fichier
function tape.save()
  if tape_view.seconds <= 0 then return nil end
  local dir = _path.audio .. "sculpt/"
  util.make_dir(dir)
  local path = dir .. "tape-" .. os.date("%y%m%d-%H%M%S") .. ".wav"
  engine.tape_save(path)
  return path
end

return tape
