-- sculpt : les gammes
--
-- Les 19 gammes du S4, dans son ordre, plus « free » qui ne cale rien.
-- Une gamme est la liste de ses notes dans l'octave, en demi-tons depuis
-- la tonique. Les étages s'en servent pour des intervalles (MOSAIC) ou des
-- notes absolues (RING).

local scales = {}

local DEFS = {
  { "chromatic", { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 } },
  { "major", { 0, 2, 4, 5, 7, 9, 11 } },
  { "minor", { 0, 2, 3, 5, 7, 8, 10 } },
  { "dorian", { 0, 2, 3, 5, 7, 9, 10 } },
  { "lydian", { 0, 2, 4, 6, 7, 9, 11 } },
  { "superlocrian", { 0, 1, 3, 4, 6, 8, 10 } },
  { "mixolydian", { 0, 2, 4, 5, 7, 9, 10 } },
  { "hex aeolian", { 0, 3, 5, 7, 8, 10 } },
  { "hex dorian", { 0, 2, 3, 5, 7, 10 } },
  { "blues", { 0, 3, 5, 6, 7, 10 } },
  { "pentatonic", { 0, 3, 5, 7, 10 } },
  { "hirajoshi", { 0, 2, 3, 7, 8 } },
  { "kumoi", { 0, 2, 3, 7, 9 } },
  { "iwato", { 0, 1, 5, 6, 10 } },
  { "whole tone", { 0, 2, 4, 6, 8, 10 } },
  { "pelog", { 0, 1, 3, 7, 8 } },
  { "tetratonic", { 0, 4, 7, 11 } },
  { "fifths", { 0, 7 } },
  { "octaves", { 0 } },
}

scales.NAMES = {}
for i, d in ipairs(DEFS) do scales.NAMES[i] = d[1] end
table.insert(scales.NAMES, "free")
scales.FREE = #scales.NAMES

function scales.is_free(i)
  return i == scales.FREE
end

-- les notes de la gamme entre lo et hi demi-tons, dans l'ordre
local function notes_between(i, lo, hi)
  local out = {}
  for oct = math.floor(lo / 12), math.floor(hi / 12) do
    for _, n in ipairs(DEFS[i][2]) do
      local v = oct * 12 + n
      if v >= lo and v <= hi then table.insert(out, v) end
    end
  end
  return out
end

-- la note de la gamme la plus proche (la plus basse en cas d'égalité)
function scales.snap(i, semis)
  if scales.is_free(i) then return semis end
  local best, dist
  for _, v in ipairs(notes_between(i, semis - 12, semis + 12)) do
    local d = math.abs(v - semis)
    if not dist or d < dist then best, dist = v, d end
  end
  return best
end

-- la note suivante de la gamme dans le sens de d, bornée à lo..hi
function scales.step(i, semis, d, lo, hi)
  local from = scales.snap(i, semis)
  local list = notes_between(i, lo, hi)
  local at = 1
  for k, v in ipairs(list) do
    if v <= from then at = k end
  end
  return list[util.clamp(at + d, 1, #list)]
end

-- pour l'engine : à chacun des 12 demi-tons de l'octave, la note de la
-- gamme juste en dessous
function scales.classes(i)
  local out = {}
  for c = 0, 11 do
    local below = 0
    if scales.is_free(i) then
      below = c
    else
      for _, n in ipairs(DEFS[i][2]) do
        if n <= c then below = n end
      end
    end
    out[c + 1] = below
  end
  return out
end

return scales
