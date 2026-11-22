-- map_visible_sectors: the sectors shown on the map in any camera orientation, by vanilla calls only.
-- Copied verbatim into each mod (master: the X4-MapVisibleSectors repository) and listed in its ui.xml before the
-- files using it, in a menus environment that depends on ego_detailmonitor. A mod takes its copy from
-- __MAP_VISIBLE_SECTORS[<version>].
-- HoloMapState, GetMapState, GetPositionalOffset, GetAllFactions, GetSectorsByOwner, GetContextByClass and
-- IsKnownToPlayer come from vanilla's cdefs.

---@diagnostic disable-next-line: unresolved-require
local ffi = require("ffi")
local C = ffi.C

local VERSION = "1.00"

---@diagnostic disable-next-line: global-in-non-module
__MAP_VISIBLE_SECTORS = __MAP_VISIBLE_SECTORS or {}
-- same version = same bytes: the first copy serves every mod
if __MAP_VISIBLE_SECTORS[VERSION] then return end

local GALAXY_TO_MAP   = 1 / 25
local HEX_RADIUS      = 400000
local HEX_AREA_FACTOR = 1.5 * math.sqrt(3) -- hex area = factor * radius^2
local TAN_HALF_V      = 0.75

local cos, sin, sqrt, abs = math.cos, math.sin, math.sqrt, math.abs
local HEX_COS, HEX_SIN = {}, {}
for k = 0, 5 do
  HEX_COS[k + 1] = cos(k * math.pi / 3)
  HEX_SIN[k + 1] = sin(k * math.pi / 3)
end

local M = { VERSION = VERSION }

local layout    -- every sector hex of the galaxy map
local viewCache -- { signature, entries } of the last camera state

-- Hex slots of the sectors inside one cluster, as the holomap places them: { sector, x, z, scale }.
local function placeSectors(list)
  local n = #list
  if n == 1 then
    return { { list[1], 0, 0, 1 } }
  elseif n == 2 then
    local a, b = list[1], list[2]
    local sx = (a.x - b.x > 0) and 1 or -1
    local sz = (a.z - b.z > 0) and 1 or -1
    return { { a, sx * 100000, sz * 173205, 0.5 }, { b, -sx * 100000, -sz * 173205, 0.5 } }
  elseif n == 3 then
    local s = { list[1], list[2], list[3] }
    for i = 1, 2 do
      for j = 1, 3 - i do
        if s[j].z > s[j + 1].z then s[j], s[j + 1] = s[j + 1], s[j] end
      end
    end
    local sg = (s[2].x < (s[1].x + s[2].x + s[3].x) / 3) and 1 or -1
    return { { s[1], sg * 100000, -173205, 0.5 }, { s[2], -sg * 200000, 0, 0.5 }, { s[3], sg * 100000, 173205, 0.5 } }
  elseif n == 4 then
    local s = { list[1], list[2], list[3], list[4] }
    for i = 1, 3 do
      for j = 1, 4 - i do
        if s[j].x > s[j + 1].x then s[j], s[j + 1] = s[j + 1], s[j] end
      end
    end
    local up = s[2].x < s[2].z
    return {
      { s[1], -200000, 0,                        0.3 },
      { s[2], 0,       up and 173205 or -173205, 0.3 },
      { s[3], 0,       up and -173205 or 173205, 0.3 },
      { s[4], 200000,  0,                        0.3 },
    }
  end
  -- 5 or more: the map draws no sector hexes
  return {}
end

--- Every sector hex of the galaxy map as { id, x, z, r } in map units, unknown sectors included (they decide
--- the slots). Built once per Lua state; rebuild() drops it.
function M.hexes()
  if layout then return layout end
  local numFactions = C.GetNumAllFactions(true)
  local factionBuf = ffi.new("const char*[?]", numFactions)
  numFactions = C.GetAllFactions(factionBuf, numFactions, true)
  local owners = { "ownerless" }
  for i = 0, numFactions - 1 do
    owners[#owners + 1] = ffi.string(factionBuf[i])
  end
  local clusters, seen = {}, {}
  for _, owner in ipairs(owners) do
    local n = C.GetNumSectorsByOwner(owner)
    if n > 0 then
      local buf = ffi.new("UniverseID[?]", n)
      n = C.GetSectorsByOwner(buf, n, owner)
      for i = 0, n - 1 do
        local sector = ConvertStringTo64Bit(tostring(buf[i]))
        if not seen[sector] then
          seen[sector] = true
          local cluster = ConvertStringTo64Bit(tostring(C.GetContextByClass(sector, "cluster", false)))
          local entry = clusters[cluster]
          if not entry then
            local offset = C.GetPositionalOffset(cluster, 0)
            entry = { x = offset.x * GALAXY_TO_MAP, z = offset.z * GALAXY_TO_MAP, sectors = {} }
            clusters[cluster] = entry
          end
          local position = C.GetPositionalOffset(sector, cluster)
          entry.sectors[#entry.sectors + 1] = { id = sector, x = position.x, z = position.z }
        end
      end
    end
  end
  layout = {}
  for _, entry in pairs(clusters) do
    for _, slot in ipairs(placeSectors(entry.sectors)) do
      layout[#layout + 1] = { id = slot[1].id, x = entry.x + slot[2], z = entry.z + slot[3], r = HEX_RADIUS * slot[4] }
    end
  end
  return layout
end

--- Drop the layout and the cached view, for a galaxy whose sectors changed.
function M.rebuild()
  layout, viewCache = nil, nil
end

-- Part of a camera-space polygon on the positive side of the plane ar * x + au * y + af * z + c0 = 0.
local function clipPolygon(poly, n, ar, au, af, c0)
  local out, m = {}, 0
  for i = 1, n do
    local a, b = poly[i], poly[i % n + 1]
    local da = ar * a[1] + au * a[2] + af * a[3] + c0
    local db = ar * b[1] + au * b[2] + af * b[3] + c0
    if da >= 0 then
      m = m + 1
      out[m] = a
    end
    if (da >= 0) ~= (db >= 0) then
      local t = da / (da - db)
      m = m + 1
      out[m] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
    end
  end
  return out, m
end

-- Area of a planar camera-space polygon and its share of the screen.
local function polygonShares(poly, n, tanH)
  local cx, cy, cz, screen = 0, 0, 0, 0
  for i = 1, n do
    local a, b = poly[i], poly[i % n + 1]
    cx = cx + a[2] * b[3] - a[3] * b[2]
    cy = cy + a[3] * b[1] - a[1] * b[3]
    cz = cz + a[1] * b[2] - a[2] * b[1]
    screen = screen + (a[1] / a[3]) * (b[2] / b[3]) - (b[1] / b[3]) * (a[2] / a[3])
  end
  return 0.5 * sqrt(cx * cx + cy * cy + cz * cz), abs(screen) / (8 * tanH * TAN_HALF_V)
end

--- Every sector hex overlapping the map render target, known or not, as { id, hexShare, screenShare }: the part
--- of the hex on screen and the part of the screen it covers, both 0..1. holomap, rtWidth, rtHeight: the map
--- menu's holomap, rendertargetWidth, rendertargetHeight. Cached until the camera moves; do not change the result.
function M.view(holomap, rtWidth, rtHeight)
  if (not holomap) or (holomap == 0) then return {} end
  local state = ffi.new("HoloMapState")
  C.GetMapState(holomap, state)
  local yaw, pitch, dist = state.offset.yaw, state.offset.pitch, state.cameradistance
  local tanH = TAN_HALF_V * rtWidth / rtHeight
  local signature = string.format("%s:%.0f:%.0f:%.0f:%.4f:%.4f:%.0f:%.4f",
    tostring(holomap), state.offset.x, state.offset.y, state.offset.z, yaw, pitch, dist, tanH)
  if viewCache and viewCache.signature == signature then return viewCache.entries end

  local cp, sp, cy, sy = cos(pitch), sin(pitch), cos(yaw), sin(yaw)
  local fx, fy, fz = cp * sy, sp, cp * cy
  local rx, rz = cy, -sy
  local ux, uy, uz = -sp * sy, cp, -sp * cy
  local camX, camY, camZ = state.offset.x - dist * fx, state.offset.y - dist * fy, state.offset.z - dist * fz
  local nH, nV = 1 / sqrt(1 + tanH * tanH), 1 / sqrt(1 + TAN_HALF_V * TAN_HALF_V)

  local entries = {}
  for _, hex in ipairs(M.hexes()) do
    local vx, vy, vz = hex.x - camX, -camY, hex.z - camZ
    local r = vx * rx + vz * rz
    local u = vx * ux + vy * uy + vz * uz
    local f = vx * fx + vy * fy + vz * fz
    local R = hex.r
    local d1, d2 = (f * tanH - r) * nH, (f * tanH + r) * nH
    local d3, d4 = (f * TAN_HALF_V - u) * nV, (f * TAN_HALF_V + u) * nV
    local d5 = f - 1
    if d1 >= -R and d2 >= -R and d3 >= -R and d4 >= -R and d5 >= -R then
      local poly, n = {}, 6
      for k = 1, 6 do
        local px, pz = vx + R * HEX_COS[k], vz + R * HEX_SIN[k]
        poly[k] = { px * rx + pz * rz, px * ux + vy * uy + pz * uz, px * fx + vy * fy + pz * fz }
      end
      local full = d1 >= R and d2 >= R and d3 >= R and d4 >= R and d5 >= R
      if not full then
        poly, n = clipPolygon(poly, n, 0, 0, 1, -1)
        if n > 0 then poly, n = clipPolygon(poly, n, -1, 0, tanH, 0) end
        if n > 0 then poly, n = clipPolygon(poly, n, 1, 0, tanH, 0) end
        if n > 0 then poly, n = clipPolygon(poly, n, 0, -1, TAN_HALF_V, 0) end
        if n > 0 then poly, n = clipPolygon(poly, n, 0, 1, TAN_HALF_V, 0) end
      end
      if n >= 3 then
        local area, screenShare = polygonShares(poly, n, tanH)
        entries[#entries + 1] = {
          id          = hex.id,
          hexShare    = full and 1 or math.min(1, area / (HEX_AREA_FACTOR * R * R)),
          screenShare = math.min(1, screenShare),
        }
      end
    end
  end
  viewCache = { signature = signature, entries = entries }
  return entries
end

--- The known sectors on the map view and a key of that set (the sorted ids, for change detection).
--- opts, all optional: minHexShare and minScreenShare (a sector counts when it reaches either one; with neither
--- given any overlap counts), largest = true (when none counts, take the one covering most of the screen).
function M.get(holomap, rtWidth, rtHeight, opts)
  local minHex = opts and opts.minHexShare
  local minScreen = opts and opts.minScreenShare
  local sectors, best, bestShare = {}, nil, 0
  for _, entry in ipairs(M.view(holomap, rtWidth, rtHeight)) do
    if C.IsKnownToPlayer(entry.id) then
      local counts = not (minHex or minScreen)
      if minHex and (entry.hexShare >= minHex) then counts = true end
      if minScreen and (entry.screenShare >= minScreen) then counts = true end
      if counts then
        sectors[#sectors + 1] = entry.id
      elseif entry.screenShare > bestShare then
        best, bestShare = entry.id, entry.screenShare
      end
    end
  end
  if (#sectors == 0) and best and opts and opts.largest then
    sectors[1] = best
  end
  local ids = {}
  for i, sector in ipairs(sectors) do ids[i] = tostring(sector) end
  table.sort(ids)
  return sectors, table.concat(ids, ",")
end

__MAP_VISIBLE_SECTORS[VERSION] = M
