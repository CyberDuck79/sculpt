-- sculpt : le lien avec le mod matrix
--
-- matrix relie une source de modulation à un réglage, avec une dose. Sa
-- page est au fond de SYSTEM > MODS ; d'ici on l'ouvre directement sur un
-- réglage donné, et on revient au script en sortant.
--
-- Deux choses s'appuient sur le fonctionnement interne du menu de matrix,
-- qu'une mise à jour du mod pourrait changer : la place d'un réglage dans
-- sa liste (row_of refait le même parcours que lui), et l'appui simulé sur
-- K3 qui fait entrer dans la liste des sources. Si cela casse, il reste à
-- ouvrir la page telle quelle : link.open sans les trois dernières lignes.

local link = {}

-- le mode « liste des sources » du menu de matrix
local SOURCES = 1

local function matrix()
  local ok, m = pcall(require, "matrix/lib/matrix")
  return ok and type(m) == "table" and m or nil
end

-- la page de matrix dans le menu de norns ; nil si le mod n'est pas actif
local function page()
  return _menu and _menu.m and _menu.m["matrix"] or nil
end

function link.available()
  return page() ~= nil and matrix() ~= nil
end

-- ce réglage est-il modulé par au moins une source ?
function link.modulated(id)
  local m = matrix()
  if not m or not m.matrix then return false end
  for _, targets in pairs(m.matrix) do
    if targets[id] then return true end
  end
  return false
end

-- matrix ne module ni les listes ni les fichiers
function link.can(id)
  if not id or not params.lookup[id] then return false end
  local t = params:t(params.lookup[id])
  return t == params.tCONTROL or t == params.tNUMBER or t == params.tTAPER
    or t == params.tBINARY
end

-- la ligne d'un réglage dans la liste de matrix : les réglages visibles,
-- dans l'ordre, un groupe comptant pour une ligne
local function row_of(index)
  local row, i = 0, 1
  repeat
    if params:visible(i) then
      row = row + 1
      if i == index then return row end
    end
    if params:t(i) == params.tGROUP then
      i = i + params:get(i) + 1
    else
      i = i + 1
    end
  until i > params.count
  return nil
end

-- la touche d'origine de la page, le temps qu'on la détourne
local orig_key

local function restore()
  local p = page()
  if p and orig_key then p.key = orig_key end
  orig_key = nil
  if p then p.reset() end
  -- le menu de norns rouvrira sur son accueil, pas sur matrix
  _menu.page = "HOME"
end

function link.close()
  _menu.set_mode(false)
  restore()
end

-- Ouvre matrix sur les sources d'un réglage. K2 ramène au script.
function link.open(id)
  local p = page()
  if not p or not link.can(id) then return false end
  local row = row_of(params.lookup[id])
  if not row then return false end

  p.reset()
  orig_key = orig_key or p.key
  local base = orig_key
  p.key = function(n, z)
    if n == 2 and z == 1 and p.mode == SOURCES then return link.close() end
    base(n, z)
  end
  _menu.set_mode(true)
  _menu.set_page("matrix")
  -- le curseur sur le réglage, puis K3 : on entre dans ses sources
  p.pos = row - 1
  base(3, 1)
  return true
end

-- Appelé quand le script dessine : si on est revenu autrement que par K2
-- (un appui court sur K1), on remet la page de matrix comme elle était.
function link.tick()
  if orig_key and _menu.mode == false then restore() end
end

return link
