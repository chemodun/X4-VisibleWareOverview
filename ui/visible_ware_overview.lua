-- Visible Ware Overview (visible_ware_overview)
-- Adds a "Sector Wares" tab to the Object List panel in the map.
--
-- The tab shows the same ware breakdown as the Ware Overview Tab mod, but
-- scoped to stations currently rendered in the map view (not limited to a
-- single sector - the map may show a cluster, the whole galaxy, etc.):
--   - Player-owned stations: always included.
--   - NPC stations: included only when IsInfoUnlockedForPlayer returns true
--     for "storage_warelist" (the same visibility gate the Logical Station
--     Overview uses to decide what ware data to expose to the player).
--
-- Layout mirrors ware_overview_tab:
--   [+/-] [Ware icon + name] [Prod/h] [Cons/h] [...] [Stock] [Stations]
-- Expandable to per-station sub-rows with a Logical Station Overview button.
--
-- Compatible with X4 8.00 and 9.00.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;

  typedef struct {
    int major;
    int minor;
  } GameVersion;

  GameVersion GetGameVersion(void);
  UniverseID  GetPlayerID(void);

  double   GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
  double   GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);

  uint32_t GetNumWares(const char* tags, bool research, const char* licenceownerid, const char* exclusiontags);
  uint32_t GetWares(const char** result, uint32_t resultlen, const char* tags, bool research, const char* licenceownerid, const char* exclusiontags);

  bool     IsInfoUnlockedForPlayer(UniverseID containerid, const char* infokey);
  bool     IsComponentWrecked(UniverseID componentid);
]]

-- *** constants ***

local PAGE_ID  = 1972092423
local MODE     = "visibleWareOverview"
local TAB_ICON = "mapst_fs_trade"

-- Visible sectors option: a sector counts with half of its hex on screen, else the one covering most of the screen
local MAP_VISIBLE_SECTORS = "1.00"
local VS                  = __MAP_VISIBLE_SECTORS[MAP_VISIBLE_SECTORS]
local VISIBLE_RULE        = { minHexShare = 0.5, largest = true }

-- Transport type display order (matches ware_overview_tab convention).
local TRANSPORT_ORDER = { "container", "solid", "liquid", "condensate" }
local TRANSPORT_TEXT_IDS = {
  container = { page = 20109, id = 101 },
  solid = { page = 20109, id = 301 },
  liquid = { page = 20109, id = 601 },
  condensate = { page = 20109, id = 9801 },
}

-- *** module table ***

local vwo = {
  menuMap       = nil,
  menuMapConfig = {},
  isV9          = C.GetGameVersion().major >= 9,
  playerId      = nil,
  visibleSectors = false, -- true: all known stations of the sectors on the map view
  sectorCache    = nil,   -- { key, turnCounter, playerStations, npcStations } of the last sector set
  maxSectorStations = 150, -- more known stations than this in the visible sectors: a notice, no wares; 0 = no limit

  -- Ware expand state: vwo.expandedWares[wareId] = true when that row is open.
  expandedWares = {},

  -- Ware registry: built once at init.
  -- wareRegistry[wareId] = { name, icon, transport }
  wareRegistry  = nil,

  -- Data cache: rebuilt when the station list hash changes or turnCounter expires.
  dataRefreshInterval = 3,   -- configurable via Extension options (1-10 ticks)
  dataCache           = nil,
  -- dataCache = {
  --   turnCounter     : int,
  --   stationListHash : string,
  --   data            : { [wareId] = wareEntry }
  -- }
  -- wareEntry = {
  --   name, icon, transport,
  --   stationCount, stock, production, consumption,
  --   stations = [{ id, id64, name, sector, isNpc, stock, production, consumption }]
  -- }
}

-- *** debug helpers ***

local debugLevel = "none"   -- "none" | "debug" | "trace"

local function debug(msg)
  if debugLevel ~= "none" then
    UIDebug("VisibleWareOverview: " .. msg)
  end
end

local function trace(msg)
  if debugLevel == "trace" then
    UITrace("VisibleWareOverview: " .. msg)
  end
end

-- *** formatting helpers ***

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

local function fmtRate(v)
  if v <= 0 then return "--" end
  return fmt(v)
end

-- *** ware registry ***

--- Build the ware registry once at init: all economy wares grouped by transport type.
local function buildWareRegistry()
  local registry = {}
  for _, transportKey in ipairs(TRANSPORT_ORDER) do
    local n = tonumber(C.GetNumWares(transportKey, false, "", ""))
    if n and n > 0 then
      local buf = ffi.new("const char*[?]", n)
      n = tonumber(C.GetWares(buf, n, transportKey, false, "", ""))
      for i = 0, n - 1 do
        local ware = ffi.string(buf[i])
        if not registry[ware] then
          local wareName, wareIcon, wareTags = GetWareData(ware, "name", "icon", "tags")
          if wareTags and wareTags["economy"] then
            registry[ware] = {
              name      = wareName or ware,
              icon      = (wareIcon and wareIcon ~= "") and wareIcon or "solid",
              transport = transportKey,
            }
          end
        end
      end
    end
  end
  trace("buildWareRegistry: found " ..
    (function() local c = 0; for _ in pairs(registry) do c = c + 1 end; return c end)() ..
    " economy wares")
  return registry
end


-- *** data collection ***

--- Build a hash string from the combined player + NPC station LuaID lists.
--- Used to detect when the visible station set changes.
local function stationListHash(playerStations, npcStations)
  local ids = {}
  for _, st in ipairs(playerStations) do
    ids[#ids + 1] = "p:" .. tostring(st)
  end
  for _, st in ipairs(npcStations) do
    ids[#ids + 1] = "n:" .. tostring(st)
  end
  return table.concat(ids, ",")
end

--- Collect ware data for one station (player or NPC) into wareData.
--- luaId     : Lua component ID
--- station64 : 64-bit UniverseID (for C FFI calls)
--- isNpc     : boolean
local function accumulateStation(wareData, luaId, station64, isNpc)
  local name, sectorName = GetComponentData(luaId, "name", "sector")
  name = name or ""
  sectorName = sectorName or ""

  local cargo, products, allResources, tradeWares =
      GetComponentData(luaId, "cargo", "products", "allresources", "tradewares")
  cargo = cargo or {}
  products = products or {}
  allResources = allResources or {}
  tradeWares = tradeWares or {}

  -- Union of all ware IDs this station handles.
  local wareSet = {}
  for ware in pairs(cargo) do wareSet[ware] = true end
  for _, ware in ipairs(products) do wareSet[ware] = true end
  for _, ware in ipairs(allResources) do wareSet[ware] = true end
  for _, ware in ipairs(tradeWares) do wareSet[ware] = true end

  if not next(wareSet) then return end

  for ware in pairs(wareSet) do
    local entry = wareData[ware]
    if not entry then goto nextWare end

    local stockAtStation = cargo[ware] or 0
    local prodAtStation  = math.max(0, C.GetContainerWareProduction(station64, ware, false))
    local consAtStation  = math.max(0, C.GetContainerWareConsumption(station64, ware, false))

    if stockAtStation > 0 or prodAtStation > 0 or consAtStation > 0 then
      entry.stationCount = entry.stationCount + 1
      entry.stock = entry.stock + stockAtStation
      entry.production = entry.production + prodAtStation
      entry.consumption = entry.consumption + consAtStation
      table.insert(entry.stations, {
        id         = luaId,
        id64       = station64,
        name       = name,
        sector     = sectorName,
        isNpc      = isNpc,
        stock      = stockAtStation,
        production = Helper.round(prodAtStation),
        consumption= Helper.round(consAtStation),
      })
    end

    ::nextWare::
  end
end

--- Collect ware data for all stations rendered in the current map view.
--- playerStations : list of LuaIDs (from infoTableData.playerStations)
--- npcStations    : list of LuaIDs (from infoTableData.npcStations)
local function collectAllWareData(playerStations, npcStations)
  -- Pre-populate wareData from the registry (zero stats for all economy wares).
  local wareData = {}
  for wareId, info in pairs(vwo.wareRegistry) do
    wareData[wareId] = {
      name         = info.name,
      icon         = info.icon,
      transport    = info.transport,
      stationCount = 0,
      stock        = 0,
      production   = 0,
      consumption  = 0,
      stations     = {},
    }
  end

  -- Player stations: always included.
  for _, luaId in ipairs(playerStations) do
    local station64 = ConvertIDTo64Bit(luaId)
    if IsValidComponent(station64) and not C.IsComponentWrecked(station64) then
      accumulateStation(wareData, luaId, station64, false)
    end
  end

  -- NPC stations: include only when storage_warelist info is unlocked for the player.
  -- This mirrors the Logical Station Overview gate: only show ware data the player
  -- can legitimately observe (docked, allied, scanned, etc.).
  for _, luaId in ipairs(npcStations) do
    local station64 = ConvertIDTo64Bit(luaId)
    if IsValidComponent(station64) and not C.IsComponentWrecked(station64) then
      if C.IsInfoUnlockedForPlayer(station64, "storage_warelist") then
        accumulateStation(wareData, luaId, station64, true)
      end
    end
  end

  -- Round aggregated totals; sort per-ware station lists.
  for _, entry in pairs(wareData) do
    entry.production  = Helper.round(entry.production)
    entry.consumption = Helper.round(entry.consumption)
    table.sort(entry.stations, function(a, b) return (a.name or "") < (b.name or "") end)
  end

  return wareData
end

--- The sector selected on the map, nil when the selection is no sector.
local function selectedSector()
  local selected = vwo.menuMap.infoSubmenuObject
  if selected and (selected ~= 0) and C.IsComponentClass(selected, "sector") then
    return ConvertStringTo64Bit(tostring(selected))
  end
  return nil
end

--- Known stations of the selected sector, else of the sectors on the map view, split like
--- infoTableData.playerStations / npcStations.
local function sectorStations(selected)
  local menuMap = vwo.menuMap
  local sectors, key
  if selected then
    sectors, key = { selected }, "selected:" .. tostring(selected)
  else
    sectors, key = VS.get(menuMap.holomap, menuMap.rendertargetWidth, menuMap.rendertargetHeight, VISIBLE_RULE)
  end
  local cache = vwo.sectorCache
  if cache and (cache.key == key) and (cache.turnCounter < vwo.dataRefreshInterval) then
    cache.turnCounter = cache.turnCounter + 1
    return cache.playerStations, cache.npcStations, cache.sectors
  end
  local playerStations, npcStations = {}, {}
  for _, sector in ipairs(sectors) do
    for _, station in ipairs(GetContainedStations(sector, true)) do
      if GetComponentData(station, "isplayerowned") then
        playerStations[#playerStations + 1] = station
      else
        npcStations[#npcStations + 1] = station
      end
    end
  end
  trace("visible sectors: " .. tostring(#sectors) .. ", stations: " .. tostring(#playerStations) .. " player + "
    .. tostring(#npcStations) .. " npc")
  vwo.sectorCache = { key = key, turnCounter = 1, sectors = sectors, playerStations = playerStations, npcStations = npcStations }
  return playerStations, npcStations, sectors
end

--- Sectors holding the given stations, as 64-bit ids.
local function sectorsOf(playerStations, npcStations)
  local sectors, seen = {}, {}
  for _, list in ipairs({ playerStations, npcStations }) do
    for _, station in ipairs(list) do
      local sector = GetComponentData(station, "sectorid")
      local key = tostring(sector)
      if sector and not seen[key] then
        seen[key] = true
        sectors[#sectors + 1] = ConvertIDTo64Bit(sector)
      end
    end
  end
  return sectors
end

--- Vanilla heads the list with the sector under the camera: name the selected sector or the visible sectors, and
--- their stations, instead.
local function retitleList(ftable, sectors, stationCount, selected)
  local menuMap = vwo.menuMap
  local current = menuMap.currentsector and ConvertStringTo64Bit(tostring(menuMap.currentsector))
  if (#sectors == 1) and (sectors[1] == current) then return end
  for index, row in ipairs(ftable.rows) do
    local cell = row[1]
    if cell and (cell.type == "text") and (cell.properties.text == menuMap.title) then
      if selected then
        cell.properties.text = ReadText(20001, 201) .. ReadText(1001, 120) .. " " .. tostring(GetComponentData(selected, "name"))
      else
        cell.properties.text = string.format("%s (%d)", ReadText(PAGE_ID, 3), #sectors)
      end
      local ownerRow = ftable.rows[index + 1]
      local ownerCell = ownerRow and ownerRow[1]
      local stationsText = ReadText(1001, 4) .. ReadText(1001, 120) .. " " .. tostring(stationCount)
      if ownerCell and (ownerCell.type == "text") and (type(ownerCell.properties.text) == "function") then
        ownerCell.properties.text = stationsText
      elseif ownerCell and (ownerCell.type == "icon") and ownerRow[2] and (ownerRow[2].type == "text") then
        -- 8.00: the owner icon and name are two cells
        ownerCell.properties.color = Color["icon_hidden"]
        ownerRow[2].properties.text = stationsText
      end
      break
    end
  end
end

--- Return cached ware data, rebuilding when the station list changes or cache is stale.
local function getWareData(playerStations, npcStations)
  local hash = stationListHash(playerStations, npcStations)

  if vwo.dataCache == nil
      or vwo.dataCache.stationListHash ~= hash
      or vwo.dataCache.turnCounter >= vwo.dataRefreshInterval then
    trace("rebuilding ware cache for "
      .. tostring(#playerStations) .. " player + "
      .. tostring(#npcStations) .. " npc stations")
    local data = collectAllWareData(playerStations, npcStations)
    vwo.dataCache = {
      turnCounter     = 1,
      stationListHash = hash,
      data            = data,
    }
  else
    vwo.dataCache.turnCounter = vwo.dataCache.turnCounter + 1
  end

  return vwo.dataCache.data
end

-- *** tab registration ***

function vwo.setupTab()
  local cfg        = vwo.menuMapConfig
  local categories = cfg and cfg.objectCategories or nil
  if categories == nil then
    debug("objectCategories not found in menuMapConfig")
    return
  end

  local insertAfter = nil
  local fallbackIdx = nil
  for i, cat in ipairs(categories) do
    if cat.category == MODE then
      trace("tab already registered")
      return
    end
    -- Place after "stations" tab when present.
    if cat.category == "stations" then
      insertAfter = i
    end
    -- Track last non-custom position as fallback.
    if string.sub(cat.category, 1, 10) ~= "custom_tab" then
      fallbackIdx = i
    end
  end

  local idx = insertAfter or fallbackIdx
  if idx then
    table.insert(categories, idx + 1, {
      category = MODE,
      name     = ReadText(PAGE_ID, 1),
      icon     = TAB_ICON,
    })
    trace("tab registered at position " .. tostring(idx + 1))
  end
end

-- *** station sub-row renderer ***

--- Renders a single per-station row inside a ware expansion block.
--- Column layout (keyed on maxIcons, same as ware_overview_tab):
---   col 1              : empty indent spacer
---   col 2              : name (\n sector)
---   col 3              : production/h  (green)
---   col 4              : consumption/h (red)
---   col maxIcons, +4   : stock
---   col maxIcons+4, +2 : LSO button
local function createStationSubRow(tblOrGroup, stEntry, maxIcons)
  local comp64 = stEntry.id64
  local name, color, bgColor, font, mouseover =
      vwo.menuMap.getContainerNameAndColors(stEntry.id, 0, true, false, true)
  local sectorName = stEntry.sector or GetComponentData(stEntry.id, "sector") or ""

  local displayText = Helper.convertColorToText(color) .. name .. "\027X"
      .. "\n" .. sectorName

  local row = tblOrGroup:addRow({ "property", stEntry.id, nil, 1 }, {
    bgColor       = bgColor,
    multiSelected = vwo.menuMap.isSelectedComponent(stEntry.id),
  })

  row[2]:createText(displayText, { font = font, mouseOverText = mouseover })
  local rowHeight = row[2]:getMinTextHeight(true)

  -- Production/h (dark green).
  row[3]:createText(fmtRate(stEntry.production), { halign = "right", color = Color["text_player_lowlight"] })

  -- Consumption/h (dark red).
  row[4]:createText(fmtRate(stEntry.consumption), { halign = "right", color = Color["faction_xenon"] })

  -- Stock (spans cols maxIcons to maxIcons+3).
  row[maxIcons]:setColSpan(4)
      :createText(stEntry.stock > 0 and fmt(stEntry.stock) or "--", { halign = "right" })

  -- Logical Station Overview button (spans cols maxIcons+4 to maxIcons+5).
  local lsoCell = row[maxIcons + 4]
  lsoCell:setColSpan(2)
  local cellWidth = lsoCell:getWidth()
  local iconSize  = math.min(cellWidth, rowHeight or vwo.menuMap.getShipIconWidth())
  local iconX     = (cellWidth - iconSize) / 2
  local iconY     = rowHeight and ((rowHeight - iconSize) / 2) or 0
  lsoCell:createButton({ mouseOverText = ReadText(1001, 7903), scaling = false })
      :setIcon("stationbuildst_lsov", { scaling = false,
        width = iconSize, height = iconSize, x = iconX, y = iconY })
  lsoCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(vwo.menuMap, "StationOverviewMenu", { 0, 0, comp64 })
    vwo.menuMap.cleanup()
  end
  if rowHeight then lsoCell.properties.height = rowHeight end
end

-- *** display callback ***

--- Main render function: builds ware rows when the "Sector Wares" tab is active.
--- Signature matches createObjectList_on_createPropertySection:
---   callback(numdisplayed, instance, objecttable, infoTableData) -> { numdisplayed }
function vwo.displayTabData(numDisplayed, instance, ftable, infoTableData)
  if vwo.menuMap == nil then return { numdisplayed = numDisplayed } end
  if vwo.menuMap.objectMode ~= MODE then return { numdisplayed = numDisplayed } end
  if infoTableData == nil then return { numdisplayed = numDisplayed } end

  -- Only active in normal map mode (not selectCV, orderparam_object, etc.).
  if vwo.menuMap.mode == "selectCV" then return { numdisplayed = numDisplayed } end

  local playerStations = infoTableData.playerStations or {}
  local npcStations = infoTableData.npcStations or {}
  local tooMany = nil
  local selected = selectedSector()
  if vwo.visibleSectors or selected then
    local sectors
    playerStations, npcStations, sectors = sectorStations(selected)
    retitleList(ftable, sectors, #playerStations + #npcStations, selected)
    if (not selected) and (vwo.maxSectorStations > 0) and (#playerStations + #npcStations > vwo.maxSectorStations) then
      tooMany = #playerStations + #npcStations
      playerStations, npcStations = {}, {}
    end
  elseif #playerStations + #npcStations > 0 then
    retitleList(ftable, sectorsOf(playerStations, npcStations), #playerStations + #npcStations)
  end
  local wareData       = getWareData(playerStations, npcStations)
  local maxIcons       = infoTableData.maxIcons or 5

  if not vwo.isV9 then
    -- *** Section header ***
    local headerRow = ftable:addRow(false, Helper.headerRowProperties)
    headerRow[1]:setColSpan(5 + maxIcons)
        :createText(ReadText(PAGE_ID, 1), Helper.headerRowCenteredProperties)
    numDisplayed = numDisplayed + 1
  end

  -- *** Gather visible ware IDs and all-expand state (used for header button) ***
  local visibleWareIds = {}
  for _, transportKey in ipairs(TRANSPORT_ORDER) do
    for wareId, entry in pairs(wareData) do
      if entry.transport == transportKey and entry.stationCount > 0 then
        table.insert(visibleWareIds, wareId)
      end
    end
  end
  local allExpanded = #visibleWareIds > 0
  for _, wareId in ipairs(visibleWareIds) do
    if not vwo.expandedWares[wareId] then
      allExpanded = false
      break
    end
  end

  -- *** Column headers ***
  local chRow = ftable:addRow("vwo_col_headers", { fixed = true })
  chRow[1]:createButton({
    scaling        = true,
    bgColor        = Color["row_background"],
    highlightColor = Color["row_background"],
  })
      :setText(allExpanded and "-" or "+", { scaling = true, halign = "center" })
  chRow[1].handlers.onClick = function()
    local newState = not allExpanded
    for _, wareId in ipairs(visibleWareIds) do
      vwo.expandedWares[wareId] = newState
    end
    vwo.menuMap.noupdate = true
    vwo.menuMap.refreshInfoFrame()
  end
  chRow[2]:createText(ReadText(1001, 45), Helper.headerRowCenteredProperties) -- Ware
  chRow[3]:createText(ReadText(1001, 1600), Helper.headerRowCenteredProperties)   -- Production
  chRow[4]:createText(ReadText(1001, 1609), Helper.headerRowCenteredProperties)   -- Consumption
  chRow[maxIcons]:setColSpan(4):createText(ReadText(1001, 20), Helper.headerRowCenteredProperties) -- Stock
  chRow[maxIcons + 4]:setColSpan(2):createText(ReadText(1001, 4), Helper.headerRowCenteredProperties) -- Stations
  numDisplayed = numDisplayed + 1

  -- RowGroup wrapper for 9.00+.
  local tblOrGroup = ftable
  if vwo.isV9 then
    tblOrGroup = ftable:addRowGroup({})
  end

  local prevDisplayed = numDisplayed

  -- *** Render one section per transport type ***
  for _, transportKey in ipairs(TRANSPORT_ORDER) do
    local typeName = ReadText(TRANSPORT_TEXT_IDS[transportKey].page, TRANSPORT_TEXT_IDS[transportKey].id)

    -- Collect wares for this transport type that have at least one station
    -- or a non-zero global total (show all with activity).
    local typeWares = {}
    for wareId, entry in pairs(wareData) do
      if entry.transport == transportKey and entry.stationCount > 0 then
        table.insert(typeWares, { id = wareId, entry = entry })
      end
    end

    if #typeWares > 0 then
      table.sort(typeWares, function(a, b) return a.entry.name < b.entry.name end)

      -- Transport-type section header.
      local typeRow = tblOrGroup:addRow(false, Helper.headerRowProperties)
      typeRow[1]:setColSpan(5 + maxIcons):createText(typeName, Helper.headerRowCenteredProperties)
      numDisplayed = numDisplayed + 1

      for _, item in ipairs(typeWares) do
        local wareId     = item.id
        local entry      = item.entry
        local isExpanded = vwo.expandedWares[wareId] or false
        numDisplayed     = numDisplayed + 1

        -- Ware summary row.
        local wareRow = tblOrGroup:addRow(wareId, { bgColor = Color["row_background"] })

        -- Expand / collapse button.
        wareRow[1]:createButton({
          scaling        = true,
          bgColor        = Color["row_background"],
          highlightColor = Color["row_background"],
        })
            :setText(isExpanded and "-" or "+", { scaling = true, halign = "center" })
        wareRow[1].handlers.onClick = function()
          vwo.expandedWares[wareId] = not (vwo.expandedWares[wareId] or false)
          vwo.menuMap.noupdate = true
          vwo.menuMap.refreshInfoFrame()
        end

        -- Ware icon + name.
        wareRow[2]:createText("\027[" .. entry.icon .. "] " .. entry.name, { halign = "left" })

        -- Production total (green).
        wareRow[3]:createText(fmtRate(entry.production),
          { halign = "right", color = Color["text_player_lowlight"] })

        -- Consumption total (red).
        wareRow[4]:createText(fmtRate(entry.consumption),
          { halign = "right", color = Color["faction_xenon"] })

        -- Total stock.
        wareRow[maxIcons]:setColSpan(4)
            :createText(entry.stock > 0 and fmt(entry.stock) or "--",
              { halign = "right" })

        -- Station count.
        wareRow[maxIcons + 4]:setColSpan(2)
            :createText(tostring(entry.stationCount), { halign = "right" })

        -- Expanded per-station sub-rows.
        if isExpanded then
          for _, stEntry in ipairs(entry.stations) do
            createStationSubRow(tblOrGroup, stEntry, maxIcons)
            numDisplayed = numDisplayed + 1
          end
        end
      end
    end
  end

  -- Empty state placeholder.
  if numDisplayed == prevDisplayed then
    local emptyRow = tblOrGroup:addRow(MODE, { interactive = false })
    local text = tooMany and string.format(ReadText(PAGE_ID, 1003), tooMany, vwo.maxSectorStations) or ReadText(PAGE_ID, 1000)
    emptyRow[2]:setColSpan(4 + maxIcons):createText(text, { wordwrap = true })
  end

  return { numdisplayed = numDisplayed }
end

-- *** init ***

function vwo.Init(menuMap)
  trace("Init called")
  vwo.menuMap       = menuMap
  vwo.menuMapConfig = menuMap.uix_getConfig() or {}
  vwo.wareRegistry  = buildWareRegistry()

  menuMap.registerCallback(
    "createObjectList_on_createPropertySection",
    vwo.displayTabData)

  vwo.setupTab()
end

--- Read the config from player.entity.$visibleWareOverviewConfig; on init and on VisibleWareOverview.ConfigChanged.
local function vwoOnConfigChanged()
  if vwo.playerId == nil then return end
  local cfg = GetNPCBlackboard(vwo.playerId, "$visibleWareOverviewConfig")
  if not cfg then return end
  debugLevel              = cfg.debugMode and tostring(cfg.debugMode) or "none"
  vwo.dataRefreshInterval = math.max(1, math.min(10, tonumber(cfg.dataRefreshInterval) or 3))
  vwo.visibleSectors      = (cfg.visibleSectors == true) or (cfg.visibleSectors == 1)
  vwo.maxSectorStations   = math.floor(math.max(0, math.min(2000, tonumber(cfg.maxSectorStations) or 150)))
  vwo.dataCache           = nil
  vwo.sectorCache         = nil
  debug("config: debug " .. debugLevel .. ", refresh interval " .. tostring(vwo.dataRefreshInterval)
    .. ", visible sectors " .. tostring(vwo.visibleSectors) .. ", station limit " .. tostring(vwo.maxSectorStations))
end

local function Init()
  debug("Initialising Visible Ware Overview")

  vwo.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  RegisterEvent("VisibleWareOverview.ConfigChanged", vwoOnConfigChanged)
  vwoOnConfigChanged()

  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("MapMenu not found - kuertee UI Extensions not loaded?")
    return
  end

  vwo.Init(menuMap)
end

Register_OnLoad_Init(Init)
