local MOD_NAME = "DeepBideTelemetry"
local CONFIG_PATH = "config.json"

local config = nil
local socket = nil
local redSocketApi = nil
local sessionId = nil
local connected = false
local initialized = false
local pollElapsed = 0.0
local reconnectElapsed = 0.0
local heartbeatElapsed = 0.0
local socketResetPending = false
local lastValues = {}
local targetSampleSeq = 0
local targetBaselinePending = true
local targetRenewElapsed = 0.0
local reportedErrors = {}
local INVENTORY_MAX_ENTRIES = 1024
local DISTRICT_MAX_HIERARCHY_LEVELS = 8
local inventorySnapshotPending = false
local inventoryDeltaBaseline = nil
-- Tracks the completeness of the last snapshot offered in this TCP epoch,
-- independently of whether a current local baseline is available.
local inventoryCompletePublished = false
local inventoryDeltaElapsed = 0.0
local gameSessionReady = false
local worldContextOffered = false
local requestSocketReset
-- Bounded current-epoch ACK window. IDs are allocated by this producer only.
-- Time is elapsed onUpdate time; ACK is ingestion feedback, not native proof.
local ACK_MAX_PENDING = 256
local ACK_TIMEOUT_SECONDS = 15.0
local pendingAcks = {}
local pendingAckCount = 0
local pendingInventoryAck = nil
local ackClock = 0.0
local ackCheckElapsed = 0.0
-- Recovery is evidence-based, never a timeout that assumes a load finished.
-- A tracker initialized AFTER a load started must be corroborated by two
-- successive current native UI/world reads. A reconnect is not a game load.
local loadingRecoveryTracker = false
local loadingRecoverySamples = 0
local loadingProgressUnknown = false
local nativeCandidate25 = nil
local journalElapsed = 0.0
local journalSeq = { ACTIVE_OBJECTIVE = 0, ACTIVE_QUEST = 0 }
local journalBaseline = { ACTIVE_OBJECTIVE = true, ACTIVE_QUEST = true }
local JOURNAL_RENEW_SECONDS = 2.0
local journalGeneration = 0
local journalLifecycleState = "DETACHED"
local journalLoadingRecoveryAllowed = false
local menuContext = {
  is_loading = false,
  raw_menu_scenario = nil,
  raw_menu_item = nil
}

local menuItemCategories = {
  Map = "map",
  Inventory = "inventory",
  Backpack = "inventory",
  Gear = "inventory",
  Journal = "journal",
  Character = "character",
  Stats = "character",
  Cyberware = "cyberware",
  Crafting = "crafting",
  Trade = "vendor",
  RipperDoc = "vendor"
}

local menuScenarioCategories = {
  MenuScenario_PauseMenu = "pause",
  MenuScenario_FastTravel = "map",
  MenuScenario_Vendor = "vendor"
}

local function log(message)
  print("[" .. MOD_NAME .. "] " .. tostring(message))
end

local function reportOnce(key, message)
  if not reportedErrors[key] then
    reportedErrors[key] = true
    log(message)
  end
end

local function loadConfig()
  local handle, openError = io.open(CONFIG_PATH, "r")
  if handle == nil then
    error("cannot open " .. CONFIG_PATH .. ": " .. tostring(openError))
  end
  local contents = handle:read("*a")
  handle:close()

  local ok, decoded = pcall(json.decode, contents)
  if not ok or type(decoded) ~= "table" then
    error("invalid JSON in " .. CONFIG_PATH)
  end

  local required = { "schema_version", "host", "port", "game_id", "game_version", "user_id", "run_id" }
  for _, key in ipairs(required) do
    if decoded[key] == nil then
      error("missing config field: " .. key)
    end
  end
  if decoded.host ~= "127.0.0.1" then
    error("telemetry only permits host 127.0.0.1")
  end
  -- Validate the complete enabled profile before registering observers or
  -- creating the socket. The disabled example intentionally contains UUID placeholders.
  if decoded.native_candidate_25 ~= nil and type(decoded.native_candidate_25) ~= "boolean" then
    error("invalid config field: native_candidate_25")
  end
  if decoded.native_candidate_25 == true then
    local function uuid(value)
      return type(value) == "string" and value == value:lower()
        and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
    end
    if decoded.game_id ~= "cyberpunk-2077" or decoded.game_version ~= "2.5" or decoded.schema_version ~= "0.03" then
      error("unsupported game/schema configuration")
    end
    for _, key in ipairs({"user_id", "run_id"}) do
      if not uuid(decoded[key]) then error("invalid UUID config field: " .. key) end
    end
    local port = decoded.port
    if type(port) ~= "number" or port < 1 or port > 65535 or port ~= math.floor(port) then
      error("invalid config field: port")
    end
    -- These are elapsed-second intervals, not frame counts. Bound both
    -- accidental busy polling and impractically long inactivity.
    for _, key in ipairs({"poll_interval_seconds", "inventory_delta_poll_seconds",
        "reconnect_interval_seconds", "heartbeat_interval_seconds", "target_renewal_seconds"}) do
      local value = decoded[key]
      if value ~= nil and (type(value) ~= "number" or value ~= value or value < 0.1 or value > 300) then
        error("invalid seconds config field: " .. key)
      end
    end
    for _, key in ipairs({"journal_verification_0_1", "target_live_contract_0_1"}) do
      if decoded[key] ~= nil and type(decoded[key]) ~= "boolean" then
        error("invalid boolean config field: " .. key)
      end
    end
  end
  if decoded.journal_verification_0_1 == true and decoded.schema_version ~= "0.03" then
    error("journal verification requires schema 0.03")
  end
  if decoded.target_live_contract_0_1 == true then
    local interval = decoded.target_renewal_seconds
    if decoded.schema_version ~= "0.03" or type(interval) ~= "number"
        or interval <= 0 or interval ~= interval or interval == math.huge then
      error("target live contract requires schema 0.03 and finite positive target_renewal_seconds")
    end
  end
  return decoded
end

local function randomHex(count)
  local result = ""
  for _ = 1, count do
    result = result .. string.format("%x", math.random(0, 15))
  end
  return result
end

local function newUuid()
  return randomHex(8)
    .. "-" .. randomHex(4)
    .. "-4" .. randomHex(3)
    .. "-" .. string.format("%x", math.random(8, 11)) .. randomHex(3)
    .. "-" .. randomHex(12)
end

local function timestampUtc()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function stableJson(value)
  local ok, encoded = pcall(json.encode, value)
  if not ok then
    return nil
  end
  return encoded
end

-- Explicitly opt-in, diagnostic candidate output; never admitted on Core's live wire.
local function initializeNativeCandidate25()
  if config.game_version ~= "2.5" or config.native_candidate_25 ~= true then return end
  if config.native_candidate_profile == "baseline" then return end
  local ok, result = pcall(function()
    local candidate = require("native_candidate_25")
    local equipment = require("native_equipment_25")
    local reader = candidate.new(function(row)
      row.producer_session = sessionId
      local encoded = stableJson(row)
      if type(encoded) ~= "string" or #encoded > 32768 then return false end
      log("CANDIDATE_JSON=" .. encoded)
      return true
    end,equipment)
    reader:register()
    log("READY_CANDIDATE_CONTRACT=cp25-native-candidate/0.3")
    return reader
  end)
  if ok then nativeCandidate25 = result
  else reportOnce("candidate25-init", "CP2.5 candidate source unavailable") end
end

local function suspendNativeCandidate25(reason)
  if nativeCandidate25 then nativeCandidate25:suspend(reason) end
end

local function clearPendingAcks()
  pendingAcks = {}
  pendingAckCount = 0
  pendingInventoryAck = nil
  ackClock = 0.0
  ackCheckElapsed = 0.0
end

local function checkPendingAcks(delta)
  ackClock = ackClock + delta
  if pendingAckCount == 0 then
    ackCheckElapsed = 0.0
    return true
  end
  ackCheckElapsed = ackCheckElapsed + delta
  if ackCheckElapsed < 1.0 then return true end
  ackCheckElapsed = 0.0
  for _, offeredAt in pairs(pendingAcks) do
    if ackClock - offeredAt >= ACK_TIMEOUT_SECONDS then
      reportOnce("receiver-ack-timeout", "receiver acknowledgment timeout; resynchronizing")
      requestSocketReset()
      return false
    end
  end
  return true
end

local function sendObservation(observationType, payload, method, deduplicate, stateKey, observedAt)
  if not connected or socket == nil then
    return false
  end

  -- The complete envelope is encoded below. Reuse a caller's already
  -- computed comparison key rather than serializing its payload twice.
  local comparisonKey = stateKey or stableJson(payload)
  if comparisonKey == nil then
    reportOnce("encode-" .. observationType, "cannot encode payload for " .. observationType)
    return false
  end
  local shouldDeduplicate = deduplicate ~= false
  if shouldDeduplicate and lastValues[observationType] == comparisonKey then
    return true
  end

  local inventoryMessage = observationType == "INVENTORY_SNAPSHOT" or observationType == "INVENTORY_DELTA"
  if inventoryMessage and pendingInventoryAck ~= nil then return false end
  if pendingAckCount >= ACK_MAX_PENDING then
    reportOnce("receiver-ack-budget", "receiver acknowledgment window exhausted; resynchronizing")
    requestSocketReset()
    return false
  end
  local envelope = {
    schema_version = config.schema_version,
    message_id = newUuid(),
    session_id = sessionId,
    game_id = config.game_id,
    game_version = config.game_version,
    user_id = config.user_id,
    run_id = config.run_id,
    source = "chumpilot.cet",
    observation_type = observationType,
    timestamp = observedAt or timestampUtc(),
    payload = payload,
    provenance = {
      sensor = "cyberpunk_runtime",
      adapter = "chumpilot_cet",
      method = method
    },
    confidence = 1.0
  }
  local liveTarget = observationType == "TARGETED_ENTITY" and config.target_live_contract_0_1 == true
  local liveJournal = config.journal_verification_0_1 == true and journalSeq[observationType] ~= nil
  if liveJournal then
    envelope.provenance.journal_reference_contract = {
      version = "0.2", sample_seq = journalSeq[observationType] + 1,
      generation = journalGeneration, baseline = journalBaseline[observationType]
    }
  end
  if liveTarget then
    envelope.provenance.live_contract = {
      version = "0.1",
      sample_seq = targetSampleSeq + 1,
      baseline = targetBaselinePending
    }
  end

  local encoded = stableJson(envelope)
  if encoded == nil then
    reportOnce("envelope-" .. observationType, "cannot encode envelope for " .. observationType)
    return false
  end
  -- Sequence is allocated when a complete Observation is materialized, before
  -- SendCommand can fail or a later transport callback can reorder delivery.
  if liveTarget then targetSampleSeq = targetSampleSeq + 1 end
  if liveJournal then journalSeq[observationType] = journalSeq[observationType] + 1 end

  -- Register before SendCommand: even a synchronous callback must match.
  local id = envelope.message_id
  if pendingAcks[id] ~= nil then requestSocketReset(); return false end
  pendingAcks[id] = ackClock
  pendingAckCount = pendingAckCount + 1
  if inventoryMessage then pendingInventoryAck = id end
  local ok, offered = pcall(function()
    return socket:SendCommand(encoded, 3)
  end)
  -- Native SendCommand is void; false is the CET wrapper's refusal.
  if not ok or offered == false then
    requestSocketReset()
    reportOnce("send", "send failed; reconnection will be attempted")
    return false
  end
  if not connected or socketResetPending then return false end
  if shouldDeduplicate or liveTarget or liveJournal then
    lastValues[observationType] = comparisonKey
  end
  if liveTarget then targetBaselinePending = false end
  if liveJournal then journalBaseline[observationType] = false end
  return true
end

local function invalidateJournal(reason, terminal)
  if config == nil or config.journal_verification_0_1 ~= true then return end
  journalBaseline = { ACTIVE_OBJECTIVE = true, ACTIVE_QUEST = true }
  lastValues["ACTIVE_OBJECTIVE"] = nil
  lastValues["ACTIVE_QUEST"] = nil
  sendObservation("JOURNAL_UNAVAILABLE", {
    reason = reason, generation = journalGeneration,
    terminal = terminal == true,
    last_sample_seq = {
      ACTIVE_OBJECTIVE = journalSeq.ACTIVE_OBJECTIVE,
      ACTIVE_QUEST = journalSeq.ACTIVE_QUEST
    }
  }, "journal verification invalidated")
end

local function beginProducerSession()
  -- Producer sessions track TCP connections; game loads use journalGeneration.
  -- No consecutive readiness sample may straddle a TCP epoch.
  loadingRecoverySamples = 0
  inventoryCompletePublished = false
  worldContextOffered = false
  clearPendingAcks()
  sessionId = newUuid()
  journalBaseline = { ACTIVE_OBJECTIVE = true, ACTIVE_QUEST = true }
  journalElapsed = JOURNAL_RENEW_SECONDS
  targetBaselinePending = true
  targetRenewElapsed = 0.0
  lastValues = {}
end

-- A known loading state is an explicit world boundary. If readiness is
-- ambiguous and the current wire cannot express it, retire the TCP epoch.
-- Consumers must revoke/expire facts on these boundaries, not infer absence.
local function revokeWorldContext(reason, terminal, transportBoundary)
  if not worldContextOffered then return end
  worldContextOffered = false
  for kind in pairs(lastValues) do
    if kind ~= "MENU_STATE" and kind ~= "JOURNAL_UNAVAILABLE" then lastValues[kind] = nil end
  end
  inventorySnapshotPending = gameSessionReady
  inventoryDeltaBaseline = nil
  inventoryCompletePublished = false
  inventoryDeltaElapsed = 0.0
  targetBaselinePending = true
  targetRenewElapsed = 0.0
  -- A witnessed loading transition already invalidates the previous Journal
  -- generation in its lifecycle callback. Never terminally close a new
  -- VERIFYING generation merely because the loading screen is still present.
  if reason ~= "loading" or journalLifecycleState == "READY" then
    invalidateJournal(reason, terminal)
  end
  if transportBoundary and connected then requestSocketReset() end
end

local function sendHeartbeat()
  if not connected or socket == nil then
    return
  end
  local encoded = stableJson({
    control_type = "heartbeat",
    schema_version = config.schema_version,
    session_id = sessionId,
    timestamp = timestampUtc()
  })
  if encoded == nil then
    reportOnce("heartbeat-encode", "cannot encode transport heartbeat")
    return
  end
  local ok, offered = pcall(function()
    return socket:SendCommand(encoded, 1)
  end)
  if not ok or offered == false then
    requestSocketReset()
    reportOnce("heartbeat-send", "heartbeat failed; reconnection will be attempted")
  end
end

local function nativeMenuName(candidate)
  if candidate == nil then
    return nil
  end
  local ok, value = pcall(function()
    return Game.NameToString(candidate)
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function nativeHubMenuItem(candidate)
  if candidate == nil then
    return nil
  end
  local ok, value = pcall(function()
    local enumValue = EnumValueToName("HubMenuItems", candidate.menuData.identifier)
    return enumValue ~= nil and enumValue.value or nil
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function setMenuScenario(candidate)
  local value = nativeMenuName(candidate)
  if value == nil then
    reportOnce("menu-scenario", "MENU_STATE could not resolve native menu scenario")
    return
  end
  menuContext.raw_menu_scenario = value
  menuContext.raw_menu_item = nil
end

local function registerMenuObservers()
  local scenarioSources = {
    "MenuScenario_Idle",
    "MenuScenario_BaseMenu",
    "MenuScenario_PreGameSubMenu",
    "MenuScenario_SingleplayerMenu"
  }
  for _, source in ipairs(scenarioSources) do
    Observe(source, "OnLeaveScenario", function(selfOrMenu, maybeMenu)
      local candidate = maybeMenu
      if type(candidate) ~= "userdata" then
        candidate = selfOrMenu
      end
      setMenuScenario(candidate)
    end)
  end

  Observe("MenuScenario_HubMenu", "OnSelectMenuItem", function(selfOrItem, maybeItem)
    local candidate = maybeItem
    if type(candidate) ~= "userdata" then
      candidate = selfOrItem
    end
    local value = nativeHubMenuItem(candidate)
    if value == nil then
      reportOnce("menu-item", "MENU_STATE could not resolve native HubMenuItems value")
      return
    end
    menuContext.raw_menu_scenario = "MenuScenario_HubMenu"
    menuContext.raw_menu_item = value
  end)

  Observe("MenuScenario_HubMenu", "OnCloseHubMenu", function()
    menuContext.raw_menu_item = nil
  end)

  Observe("MenuScenario_Vendor", "OnSwitchToVendor", function()
    menuContext.raw_menu_scenario = "MenuScenario_Vendor"
    menuContext.raw_menu_item = "Trade"
  end)
  Observe("MenuScenario_Vendor", "OnSwitchToRipperDoc", function()
    menuContext.raw_menu_scenario = "MenuScenario_Vendor"
    menuContext.raw_menu_item = "RipperDoc"
  end)
  Observe("MenuScenario_Vendor", "OnSwitchToCrafting", function()
    menuContext.raw_menu_scenario = "MenuScenario_Vendor"
    menuContext.raw_menu_item = "Crafting"
  end)

  Observe("LoadingScreenProgressBarController", "SetProgress", function(selfOrProgress, maybeProgress)
    local progress = maybeProgress
    if type(progress) ~= "number" then
      progress = selfOrProgress
    end
    if type(progress) ~= "number" or progress ~= progress or progress < 0.0 or progress > 1.0 then
      -- Ambiguous callback: revoke readiness, but do not invent a loading value.
      loadingProgressUnknown = true
      loadingRecoveryTracker = false
      loadingRecoverySamples = 0
      lastValues["MENU_STATE"] = nil
      suspendNativeCandidate25("LOADING")
      revokeWorldContext("read_error", false, true)
      reportOnce("menu-loading", "MENU_STATE loading progress invalid")
      return
    end
    loadingProgressUnknown = false
    loadingRecoverySamples = 0
    local enteringLoading = progress < 1.0 and not menuContext.is_loading
    if enteringLoading then loadingRecoveryTracker = false end
    if progress == 1.0 then
      loadingRecoveryTracker = false
      -- A load can begin and finish between polls. If no loading boundary was
      -- offered, retire the old world epoch before any new world sample.
      if menuContext.is_loading then revokeWorldContext("loading", true, true) end
    end
    if enteringLoading then
      -- TARGETED_ENTITY has its own live renewal lifecycle, independent of the
      -- optional Journal verification latch.
      targetBaselinePending = true
      targetRenewElapsed = 0.0
    end
    if enteringLoading then
      journalLoadingRecoveryAllowed = false
      suspendNativeCandidate25("LOADING")
    end
    if enteringLoading and journalLifecycleState == "READY" then
      journalLifecycleState = "SUSPENDED"
      invalidateJournal("loading", true)
    end
    menuContext.is_loading = progress < 1.0
    if not menuContext.is_loading then journalLoadingRecoveryAllowed = false end
    if menuContext.is_loading then
      menuContext.raw_menu_scenario = nil
      menuContext.raw_menu_item = nil
    end
  end)
end

local function registerInventoryLifecycleObservers()
  -- QuestTrackerGameController is initialized when an actual gameplay session
  -- starts. Game.GetPlayer() can already expose a frontend puppet before that,
  -- whose TransactionSystem list is not the loaded save inventory.
  Observe("QuestTrackerGameController", "OnInitialize", function()
    gameSessionReady = true
    if menuContext.is_loading or loadingProgressUnknown then
      loadingRecoveryTracker = true
      loadingRecoverySamples = 0
    end
    targetBaselinePending = true
    targetRenewElapsed = 0.0
    inventorySnapshotPending = true
    inventoryDeltaBaseline = nil
    inventoryDeltaElapsed = 0.0
    lastValues["INVENTORY_SNAPSHOT"] = nil
    lastValues["VEHICLE_STATE"] = nil
    lastValues["CURRENT_DISTRICT"] = nil
    lastValues["TARGETED_ENTITY"] = nil
  end)

  ObserveAfter("QuestTrackerGameController", "OnInitialize", function()
    if config == nil or config.journal_verification_0_1 ~= true then return end
    -- A second initialize callback is not a generation boundary. Only a
    -- detached/suspended lifecycle can start a new Journal generation.
    if journalLifecycleState ~= "DETACHED" and journalLifecycleState ~= "SUSPENDED" then
      if journalLifecycleState == "VERIFYING" and menuContext.is_loading then
        journalLoadingRecoveryAllowed = true
      end
      return
    end
    journalGeneration = journalGeneration + 1
    journalLifecycleState = "VERIFYING"
    journalLoadingRecoveryAllowed = menuContext.is_loading
    journalBaseline = { ACTIVE_OBJECTIVE = true, ACTIVE_QUEST = true }
    lastValues["ACTIVE_OBJECTIVE"] = nil
    lastValues["ACTIVE_QUEST"] = nil
    journalElapsed = JOURNAL_RENEW_SECONDS
  end)

  Observe("QuestTrackerGameController", "OnUninitialize", function()
    local wasAttached = journalLifecycleState ~= "DETACHED"
    journalLifecycleState = "DETACHED"
    journalLoadingRecoveryAllowed = false
    if wasAttached then
      invalidateJournal("session_boundary", true)
    end
    gameSessionReady = false
    loadingRecoveryTracker = false
    loadingRecoverySamples = 0
    lastValues["MENU_STATE"] = nil
    suspendNativeCandidate25("GAMEPLAY_END")
    if not menuContext.is_loading or loadingProgressUnknown then
      revokeWorldContext("session_boundary", true, true)
    end
    targetBaselinePending = true
    inventorySnapshotPending = false
    inventoryDeltaBaseline = nil
    inventoryDeltaElapsed = 0.0
    lastValues["INVENTORY_SNAPSHOT"] = nil
    lastValues["VEHICLE_STATE"] = nil
    lastValues["CURRENT_DISTRICT"] = nil
    lastValues["TARGETED_ENTITY"] = nil
  end)
end

local function normalizeMenuCategory(isMenu)
  if menuContext.is_loading then
    return "loading"
  end
  if not isMenu then
    return "gameplay"
  end
  if menuContext.raw_menu_item ~= nil then
    return menuItemCategories[menuContext.raw_menu_item] or "other"
  end
  if menuContext.raw_menu_scenario == "MenuScenario_HubMenu" then
    return "unknown"
  end
  if menuContext.raw_menu_scenario ~= nil then
    return menuScenarioCategories[menuContext.raw_menu_scenario] or "other"
  end
  return "unknown"
end

local function readMenuState()
  local ok, isMenu = pcall(function()
    local definitions = Game.GetAllBlackboardDefs()
    local uiBlackboard = Game.GetBlackboardSystem():Get(definitions.UI_System)
    return uiBlackboard:GetBool(definitions.UI_System.IsInMenu)
  end)
  if not ok or type(isMenu) ~= "boolean" then
    reportOnce("menu-blackboard", "MENU_STATE UI_System.IsInMenu unavailable")
    return nil
  end
  return isMenu
end

-- Reuse the existing Journal native attachment/pregame witness. Missing
-- methods, nils and non-boolean values are not evidence of a playable world.
local function readAttachedWorld(player)
  if player == nil then return false end
  local ok, ready = pcall(function()
    if player:IsAttached() ~= true then return false end
    local scenario = GetSingleton("inkMenuScenario")
    if scenario == nil then return false end
    local handler = scenario:GetSystemRequestsHandler()
    return handler ~= nil and handler:IsPreGame() == false
  end)
  return ok and ready == true
end

local function reconcileLoading(isMenu, worldReady)
  if not menuContext.is_loading and not loadingProgressUnknown then return end
  if not connected or not gameSessionReady or not loadingRecoveryTracker
      or isMenu ~= false or not worldReady then
    loadingRecoverySamples = 0
    return
  end
  loadingRecoverySamples = loadingRecoverySamples + 1
  if loadingRecoverySamples < 2 then return end
  -- Positive post-load lifecycle + fresh UI and world state; no quest text,
  -- timeout, player existence alone, or previous TCP epoch can release this.
  menuContext.is_loading = false
  loadingProgressUnknown = false
  loadingRecoveryTracker = false
  loadingRecoverySamples = 0
  journalLoadingRecoveryAllowed = false
  lastValues["MENU_STATE"] = nil
  log("loading latch recovered from fresh gameplay lifecycle and native reads")
end

local function observeMenuState(isMenu, worldReady)
  -- The wire cannot encode an unknown non-menu/non-loading state. Silence
  -- (and native generation revocation) is safer than claiming gameplay.
  if isMenu == nil or loadingProgressUnknown or (not menuContext.is_loading and
      not isMenu and (not gameSessionReady or not worldReady)) then
    lastValues["MENU_STATE"] = nil
    return
  end
  if not isMenu then
    menuContext.raw_menu_item = nil
    if menuContext.raw_menu_scenario ~= "MenuScenario_Idle" then
      menuContext.raw_menu_scenario = nil
    end
  end

  return sendObservation(
    "MENU_STATE",
    {
      is_menu = isMenu,
      is_loading = menuContext.is_loading,
      raw_menu_scenario = menuContext.raw_menu_scenario,
      raw_menu_item = menuContext.raw_menu_item,
      normalized_category = normalizeMenuCategory(isMenu)
    },
    "UI_System.IsInMenu;MenuScenario.OnLeaveScenario;MenuScenario_HubMenu.OnSelectMenuItem;LoadingScreenProgressBarController.SetProgress;QuestTrackerGameController.OnInitialize;player.IsAttached;inkMenuScenario.IsPreGame"
  )
end

local function observePosition(player)
  local ok, position = pcall(function()
    return player:GetWorldPosition()
  end)
  if not ok or position == nil then
    reportOnce("position", "PLAYER_POSITION API unavailable: " .. tostring(position))
    return
  end
  sendObservation("PLAYER_POSITION", {
    x = tonumber(string.format("%.3f", position.x)),
    y = tonumber(string.format("%.3f", position.y)),
    z = tonumber(string.format("%.3f", position.z))
  }, "Game.GetPlayer():GetWorldPosition")
end

local function inventoryRecordId(itemId)
  local ok, value = pcall(function()
    local tweakId = itemId.tdbid
    if tweakId == nil then
      tweakId = ItemID.GetTDBID(itemId)
    end
    return TDBID.ToStringDEBUG(tweakId)
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function inventoryItemType(itemData)
  local ok, value = pcall(function()
    local nativeType = itemData:GetItemType()
    if nativeType == nil then
      return nil
    end
    if type(nativeType.value) == "string" and nativeType.value ~= "" then
      return nativeType.value
    end
    local text = tostring(nativeType)
    if text == "" then
      return nil
    end
    return text
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function inventoryEntry(itemData, stashScope)
  local ok, entry = pcall(function()
    local itemId = itemData:GetID()
    local nativeId = tostring(ItemID.GetCombinedHash(itemId))
    local quantity = itemData:GetQuantity()
    if nativeId == "" or nativeId == "0" or nativeId == "0ULL" then
      return nil
    end
    if type(quantity) ~= "number" or quantity <= 0 or quantity ~= math.floor(quantity) then
      return nil
    end

    local result = {
      item_id = nativeId,
      quantity = quantity
    }
    local recordId = inventoryRecordId(itemId)
    if recordId ~= nil then
      result.record_id = recordId
    end
    -- Candidate refs are harvested from the very same native list entry.
    if nativeCandidate25 and nativeCandidate25.active then
      local refOk, ref = pcall(function() return nativeCandidate25:offer_record(itemId,recordId) end)
      if stashScope then result.record_id = refOk and ref and (ref.record_id or ref.record_ref) or nil end
    end
    local itemType = inventoryItemType(itemData)
    if itemType ~= nil then
      result.item_type = itemType
    end
    return result
  end)
  if not ok then
    return nil
  end
  return entry
end

local function inventoryEntryLess(left, right)
  if left.item_id ~= right.item_id then
    return left.item_id < right.item_id
  end
  local leftRecord = left.record_id or ""
  local rightRecord = right.record_id or ""
  if leftRecord ~= rightRecord then
    return leftRecord < rightRecord
  end
  local leftType = left.item_type or ""
  local rightType = right.item_type or ""
  if leftType ~= rightType then
    return leftType < rightType
  end
  return left.quantity < right.quantity
end

local function readInventoryState(player, stashScope)
  local ok, firstResult, secondResult = pcall(function()
    return Game.GetTransactionSystem():GetItemList(player)
  end)
  if not ok then
    reportOnce("inventory-list", "inventory GetItemList failed: " .. tostring(firstResult))
    return nil
  end

  local sourceItems = firstResult
  if type(firstResult) == "boolean" then
    if not firstResult then
      reportOnce("inventory-list", "inventory GetItemList returned false")
      return nil
    end
    sourceItems = secondResult
  end
  if type(sourceItems) ~= "table" then
    reportOnce("inventory-list", "inventory GetItemList returned no item array")
    return nil
  end

  local limit = stashScope and 4096 or INVENTORY_MAX_ENTRIES
  if stashScope and #sourceItems > limit then
    return {entries={},entry_count=0,source_entry_count=#sourceItems,
      excluded_entry_count=#sourceItems,max_entries=limit,truncated=true}
  end
  local entries = {}
  local sourceEntryCount = 0
  local excludedEntryCount = 0
  for _, itemData in ipairs(sourceItems) do
    sourceEntryCount = sourceEntryCount + 1
    local entry = inventoryEntry(itemData,stashScope)
    if entry == nil then
      excludedEntryCount = excludedEntryCount + 1
    else
      table.insert(entries, entry)
    end
  end
  table.sort(entries, inventoryEntryLess)

  local truncated = #entries > limit
  while #entries > limit do
    table.remove(entries)
    excludedEntryCount = excludedEntryCount + 1
  end

  reportedErrors["inventory-list"] = nil
  return {
    entries = entries,
    entry_count = #entries,
    source_entry_count = sourceEntryCount,
    excluded_entry_count = excludedEntryCount,
    max_entries = limit,
    truncated = truncated
  }
end

local function inventoryStateIsComplete(state)
  return state ~= nil
    and not state.truncated
    and state.excluded_entry_count == 0
end

-- Both initial synchronization and recovery publish the SAME state that
-- becomes the delta baseline. A local read alone never establishes a new baseline.
local function publishInventorySnapshot(state)
  if state == nil then return false end
  local payload = {
    sync_kind = "STATE_SYNC",
    scope = "player_transaction_inventory",
    entries = state.entries,
    entry_count = state.entry_count,
    source_entry_count = state.source_entry_count,
    excluded_entry_count = state.excluded_entry_count,
    max_entries = state.max_entries,
    truncated = state.truncated
  }
  local sent = sendObservation(
    "INVENTORY_SNAPSHOT",
    payload,
    "TransactionSystem:GetItemList(player);gameItemData:GetID/GetQuantity/GetItemType;TDBID.ToStringDEBUG",
    false -- STATE_SYNC is required even if the payload matches an earlier epoch.
  )
  if sent then
    inventorySnapshotPending = false
    inventoryDeltaElapsed = 0.0
    inventoryCompletePublished = inventoryStateIsComplete(state)
    if inventoryCompletePublished then
      inventoryDeltaBaseline = state.entries
      reportedErrors["inventory-delta-incomplete"] = nil
    else
      inventoryDeltaBaseline = nil
      reportOnce(
        "inventory-delta-incomplete",
        "INVENTORY_DELTA baseline deferred because the inventory state is incomplete"
      )
    end
    log(
      "inventory snapshot sent: entries=" .. tostring(state.entry_count)
        .. " source=" .. tostring(state.source_entry_count)
        .. " excluded=" .. tostring(state.excluded_entry_count)
        .. " truncated=" .. tostring(state.truncated)
    )
  end
  return sent
end

local function observeInventorySnapshot(player)
  if not gameSessionReady or not inventorySnapshotPending or pendingInventoryAck ~= nil then return false end
  return publishInventorySnapshot(readInventoryState(player))
end

local function inventoryIdentityKey(entry)
  return stableJson({ entry.item_id, entry.record_id or "", entry.item_type or "" })
end

local function inventoryGroups(entries)
  local groups = {}
  for _, entry in ipairs(entries) do
    local key = inventoryIdentityKey(entry)
    if groups[key] == nil then
      groups[key] = {}
    end
    table.insert(groups[key], entry)
  end
  return groups
end

local function copyInventoryIdentity(target, source)
  target.item_id = source.item_id
  if source.record_id ~= nil then
    target.record_id = source.record_id
  end
  if source.item_type ~= nil then
    target.item_type = source.item_type
  end
end

local function inventoryChange(source, changeType, beforeQuantity, afterQuantity, occurrences, ambiguous)
  local change = {
    change_type = changeType,
    before_quantity = beforeQuantity,
    after_quantity = afterQuantity,
    quantity_delta = afterQuantity - beforeQuantity,
    occurrences = occurrences,
    identity_ambiguous = ambiguous
  }
  copyInventoryIdentity(change, source)
  return change
end

local function quantityCounts(entries)
  local counts = {}
  for _, entry in ipairs(entries or {}) do
    counts[entry.quantity] = (counts[entry.quantity] or 0) + 1
  end
  return counts
end

local function sortedNumericKeys(values)
  local keys = {}
  for key, _ in pairs(values) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

local function inventoryChangeLess(left, right)
  if left.item_id ~= right.item_id then
    return left.item_id < right.item_id
  end
  local leftRecord = left.record_id or ""
  local rightRecord = right.record_id or ""
  if leftRecord ~= rightRecord then
    return leftRecord < rightRecord
  end
  local leftType = left.item_type or ""
  local rightType = right.item_type or ""
  if leftType ~= rightType then
    return leftType < rightType
  end
  if left.change_type ~= right.change_type then
    return left.change_type < right.change_type
  end
  if left.before_quantity ~= right.before_quantity then
    return left.before_quantity < right.before_quantity
  end
  if left.after_quantity ~= right.after_quantity then
    return left.after_quantity < right.after_quantity
  end
  return left.occurrences < right.occurrences
end

local function compareInventoryStates(beforeEntries, afterEntries)
  local beforeGroups = inventoryGroups(beforeEntries)
  local afterGroups = inventoryGroups(afterEntries)
  local identityKeys = {}
  local seen = {}
  for key, _ in pairs(beforeGroups) do
    seen[key] = true
    table.insert(identityKeys, key)
  end
  for key, _ in pairs(afterGroups) do
    if not seen[key] then
      table.insert(identityKeys, key)
    end
  end
  table.sort(identityKeys)

  local changes = {}
  local affectedEntryCount = 0
  for _, key in ipairs(identityKeys) do
    local beforeGroup = beforeGroups[key] or {}
    local afterGroup = afterGroups[key] or {}
    if #beforeGroup <= 1 and #afterGroup <= 1 then
      if #beforeGroup == 0 then
        table.insert(changes, inventoryChange(afterGroup[1], "added", 0, afterGroup[1].quantity, 1, false))
        affectedEntryCount = affectedEntryCount + 1
      elseif #afterGroup == 0 then
        table.insert(changes, inventoryChange(beforeGroup[1], "removed", beforeGroup[1].quantity, 0, 1, false))
        affectedEntryCount = affectedEntryCount + 1
      elseif beforeGroup[1].quantity ~= afterGroup[1].quantity then
        table.insert(
          changes,
          inventoryChange(
            afterGroup[1],
            "quantity_changed",
            beforeGroup[1].quantity,
            afterGroup[1].quantity,
            1,
            false
          )
        )
        affectedEntryCount = affectedEntryCount + 1
      end
    else
      -- Repeated native identities are a multiset. Cancel exact tuples and
      -- preserve unmatched multiplicity without inventing pairwise identity.
      local beforeCounts = quantityCounts(beforeGroup)
      local afterCounts = quantityCounts(afterGroup)
      local quantities = {}
      for quantity, _ in pairs(beforeCounts) do
        quantities[quantity] = true
      end
      for quantity, _ in pairs(afterCounts) do
        quantities[quantity] = true
      end
      for _, quantity in ipairs(sortedNumericKeys(quantities)) do
        local beforeCount = beforeCounts[quantity] or 0
        local afterCount = afterCounts[quantity] or 0
        if beforeCount > afterCount then
          local occurrences = beforeCount - afterCount
          table.insert(changes, inventoryChange(beforeGroup[1], "removed", quantity, 0, occurrences, true))
          affectedEntryCount = affectedEntryCount + occurrences
        elseif afterCount > beforeCount then
          local occurrences = afterCount - beforeCount
          table.insert(changes, inventoryChange(afterGroup[1], "added", 0, quantity, occurrences, true))
          affectedEntryCount = affectedEntryCount + occurrences
        end
      end
    end
  end
  table.sort(changes, inventoryChangeLess)
  return changes, affectedEntryCount
end

local function observeInventoryDelta(player)
  if not gameSessionReady or inventorySnapshotPending or pendingInventoryAck ~= nil then
    return
  end

  local startedAt = os.clock()
  local state = readInventoryState(player)
  if not inventoryStateIsComplete(state) then
    inventoryDeltaBaseline = nil
    -- A missing list is unknown, not empty. Keep the outstanding obligation
    -- to replace the last complete snapshot until a partial or complete
    -- STATE_SYNC has actually been offered in this epoch.
    if inventoryCompletePublished and state ~= nil then publishInventorySnapshot(state) end
    reportOnce(
      "inventory-delta-incomplete",
      "INVENTORY_DELTA comparison deferred because the inventory state is incomplete"
    )
    return
  end
  reportedErrors["inventory-delta-incomplete"] = nil

  if inventoryDeltaBaseline == nil then
    -- Resume with a complete STATE_SYNC, not a delta against stale consumer state.
    publishInventorySnapshot(state)
    return
  end

  local beforeEntries = inventoryDeltaBaseline
  local changes, affectedEntryCount = compareInventoryStates(beforeEntries, state.entries)
  if #changes == 0 then
    inventoryDeltaBaseline = state.entries
    return
  end

  local payload = {
    sync_kind = "STATE_CHANGE",
    scope = "player_transaction_inventory",
    changes = changes,
    change_count = #changes,
    affected_entry_count = affectedEntryCount
  }
  local sent = sendObservation(
    "INVENTORY_DELTA",
    payload,
    "derived:TransactionSystem:GetItemList(player) multiset diff",
    false
  )
  if sent then
    inventoryDeltaBaseline = state.entries
    local encodedPayload = stableJson(payload) or ""
    local elapsedMs = (os.clock() - startedAt) * 1000.0
    log(
      "inventory delta sent: changes=" .. tostring(#changes)
        .. " affected=" .. tostring(affectedEntryCount)
        .. " compared=" .. tostring(#beforeEntries + #state.entries)
        .. " bytes=" .. tostring(#encodedPayload)
        .. " elapsed_ms=" .. string.format("%.3f", elapsedMs)
    )
  end
end

local function observeCombat(player)
  local ok, inCombat = pcall(function()
    return player:IsInCombat()
  end)
  if not ok or type(inCombat) ~= "boolean" then
    reportOnce("combat", "COMBAT_STATE API unavailable: " .. tostring(inCombat))
    return
  end
  sendObservation("COMBAT_STATE", { in_combat = inCombat }, "PlayerPuppet:IsInCombat")
end

local function observeLife(player)
  local ok, currentHealth, maxHealth, isDead = pcall(function()
    local entityId = player:GetEntityID()
    local statsObjectId = StatsObjectID.new({
      entityHash = entityId.hash,
      idType = gameStatIDType.EntityID
    })
    local statPools = Game.GetStatPoolsSystem()
    return statPools:GetStatPoolValue(
      statsObjectId,
      gamedataStatPoolType.Health,
      false
    ), statPools:GetStatPoolMaxPointValue(
      statsObjectId,
      gamedataStatPoolType.Health
    ), player:IsDead()
  end)

  if not ok then
    reportOnce("life", "PLAYER_LIFE_STATE API unavailable: " .. tostring(currentHealth))
    return
  end
  if type(currentHealth) ~= "number" or type(maxHealth) ~= "number" then
    reportOnce("life-values", "PLAYER_LIFE_STATE returned non-numeric health values")
    return
  end
  if type(isDead) ~= "boolean" then
    reportOnce("life-dead", "PLAYER_LIFE_STATE returned a non-boolean death state")
    return
  end
  if maxHealth <= 0 then
    reportOnce(
      "life-uninitialized",
      "PLAYER_LIFE_STATE health pool is not initialized yet; observation deferred"
    )
    return
  end

  sendObservation(
    "PLAYER_LIFE_STATE",
    {
      health_current = tonumber(string.format("%.3f", currentHealth)),
      health_max = tonumber(string.format("%.3f", maxHealth)),
      life_state = isDead and "dead" or "alive"
    },
    "StatPoolsSystem:GetStatPoolValue/GetStatPoolMaxPointValue(Health);PlayerPuppet:IsDead"
  )
end

local function journalHash(manager, entry)
  if entry == nil then
    return nil
  end
  local ok, value = pcall(function()
    return manager:GetEntryHash(entry)
  end)
  if not ok or value == nil then
    return nil
  end
  return tostring(value)
end

local function localizedText(localizationKey)
  if localizationKey == nil then
    return nil
  end
  local ok, value = pcall(function()
    return Game.GetLocalizedText(localizationKey)
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function questTitle(manager, quest)
  if quest == nil then
    return nil
  end
  local ok, localizationKey = pcall(function()
    return quest:GetTitle(manager)
  end)
  if not ok then
    return nil
  end
  return localizedText(localizationKey)
end

local function objectiveText(objective)
  if objective == nil then
    return nil
  end
  local ok, localizationKey = pcall(function()
    return objective:GetDescription()
  end)
  if not ok then
    return nil
  end
  return localizedText(localizationKey)
end

local function observeJournal(player, worldReady)
  local liveJournal = config.journal_verification_0_1 == true
  -- Journal retains its separate verification lifecycle and uses the same
  -- current attachment/pregame witness as the loading reconciliation.
  if liveJournal and menuContext.is_loading
      and (not gameSessionReady or not journalLoadingRecoveryAllowed) then return end
  if liveJournal and (not gameSessionReady
      or journalLifecycleState == "DETACHED" or journalLifecycleState == "SUSPENDED") then
    invalidateJournal("loading", true)
    return
  end
  if liveJournal then
    if not worldReady then
      -- Player attachment and pregame APIs can be temporarily unavailable while
      -- the current game generation remains valid. Keep VERIFYING/READY and
      -- require a fresh baseline before publishing again.
      invalidateJournal("read_error", false)
      return
    end
    if journalLifecycleState ~= "VERIFYING" and journalLifecycleState ~= "READY" then return end
  end
  local observedAt = timestampUtc()
  local ok, manager, objective, quest = pcall(function()
    local journal = Game.GetJournalManager()
    local tracked = journal:GetTrackedEntry()
    if tracked == nil then
      return journal, nil, nil
    end
    local phase = journal:GetParentEntry(tracked)
    local parentQuest = phase ~= nil and journal:GetParentEntry(phase) or nil
    return journal, tracked, parentQuest
  end)
  if not ok or manager == nil then
    if nativeCandidate25 then nativeCandidate25:journal_unavailable() end
    lastValues["ACTIVE_OBJECTIVE"] = nil
    lastValues["ACTIVE_QUEST"] = nil
    invalidateJournal("read_error", false)
    reportOnce("journal", "journal telemetry API unavailable")
    return
  end

  if nativeCandidate25 then
    local witnessOK=pcall(function() nativeCandidate25:tracked_root(manager,objective) end)
    if not witnessOK then nativeCandidate25:journal_unavailable() end
  end
  local objectiveHash = journalHash(manager, objective)
  local questHash = journalHash(manager, quest)
  local resolvedObjectiveText = objectiveText(objective)
  local resolvedQuestTitle = questTitle(manager, quest)
  -- A failed hash/localization/parent lookup is unknown, never active=false.
  if objective ~= nil and (
      objectiveHash == nil or not string.find(objectiveHash, "%S")
      or resolvedObjectiveText == nil or quest == nil
      or questHash == nil or not string.find(questHash, "%S")
      or resolvedQuestTitle == nil
      or not string.find(resolvedObjectiveText, "%S")
      or not string.find(resolvedQuestTitle, "%S")) then
    -- Legacy receivers have no Journal invalidation envelope. Suppress the
    -- invalid pair and force a fresh valid pair rather than asserting absence.
    lastValues["ACTIVE_OBJECTIVE"] = nil
    lastValues["ACTIVE_QUEST"] = nil
    invalidateJournal("read_error", false)
    return
  end
  -- A successful, fully resolved read is the only event that completes
  -- VERIFYING and can re-open a temporarily unavailable Journal stream.
  if liveJournal and journalLifecycleState == "VERIFYING" then
    journalLifecycleState = "READY"
  end
  local renew = liveJournal and journalElapsed >= JOURNAL_RENEW_SECONDS
  if liveJournal then lastValues["JOURNAL_UNAVAILABLE"] = nil end
  sendObservation(
    "ACTIVE_OBJECTIVE",
    {
      active = objectiveHash ~= nil,
      objective_hash = objectiveHash,
      objective_text = resolvedObjectiveText
    },
    "JournalManager:GetTrackedEntry/GetEntryHash;gameJournalQuestObjective:GetDescription;Game.GetLocalizedText",
    not renew, nil, observedAt
  )
  sendObservation(
    "ACTIVE_QUEST",
    {
      active = questHash ~= nil,
      quest_hash = questHash,
      quest_title = resolvedQuestTitle
    },
    "JournalManager:GetParentEntry/GetEntryHash;gameJournalQuest:GetTitle;Game.GetLocalizedText",
    not renew, nil, observedAt
  )
  if renew then journalElapsed = 0.0 end
end

local function weaponIdentifier(item)
  local itemId = item:GetItemID()
  local okHash, combinedHash = pcall(function()
    return ItemID.GetCombinedHash(itemId)
  end)
  if okHash and combinedHash ~= nil then
    return tostring(combinedHash)
  end
  return tostring(itemId)
end

local function observeWeapon(player)
  local ok, item = pcall(function()
    local transaction = Game.GetTransactionSystem()
    local slot = TweakDBID.new("AttachmentSlots.WeaponRight")
    return transaction:GetItemInSlot(player, slot)
  end)
  if not ok then
    reportOnce("weapon", "CURRENT_WEAPON API unavailable: " .. tostring(item))
    return
  end
  if item == nil then
    sendObservation(
      "CURRENT_WEAPON",
      { equipped = false, item_id = nil },
      "TransactionSystem:GetItemInSlot(AttachmentSlots.WeaponRight)"
    )
    return
  end

  local okId, identifier = pcall(weaponIdentifier, item)
  if not okId or identifier == nil or identifier == "" then
    reportOnce("weapon-id", "cannot resolve CURRENT_WEAPON item id: " .. tostring(identifier))
    return
  end
  sendObservation(
    "CURRENT_WEAPON",
    { equipped = true, item_id = identifier },
    "TransactionSystem:GetItemInSlot(AttachmentSlots.WeaponRight)"
  )
end

local function nativeVehicleRecordId(vehicle)
  local ok, value = pcall(function()
    return TDBID.ToStringDEBUG(vehicle:GetRecordID())
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function nativeVehicleType(vehicle)
  local ok, value = pcall(function()
    return tostring(vehicle:GetVehicleType())
  end)
  if not ok or type(value) ~= "string" or value == "" then
    return nil
  end
  return value
end

local function observeVehicle(player)
  if not gameSessionReady then
    return
  end

  local startedAt = os.clock()
  local ok, vehicle = pcall(function()
    return Game.GetMountedVehicle(player)
  end)
  if not ok then
    reportOnce("vehicle", "VEHICLE_STATE API unavailable: " .. tostring(vehicle))
    return
  end

  local payload = {
    mounted = vehicle ~= nil,
    role = "unknown"
  }
  if vehicle ~= nil then
    local identityOk, vehicleId = pcall(function()
      return tostring(vehicle:GetEntityID().hash)
    end)
    if not identityOk or type(vehicleId) ~= "string" or vehicleId == "" then
      reportOnce("vehicle-id", "VEHICLE_STATE could not resolve native entity identity")
      return
    end

    payload.vehicle_id = vehicleId
    payload.record_id = nativeVehicleRecordId(vehicle)
    payload.vehicle_type = nativeVehicleType(vehicle)

    local driverOk, isDriver = pcall(function()
      return vehicle:IsPlayerDriver()
    end)
    if driverOk and isDriver == true then
      payload.role = "driver"
    elseif not driverOk or type(isDriver) ~= "boolean" then
      reportOnce("vehicle-role", "VEHICLE_STATE could not resolve native driver role")
    end
  end

  if nativeCandidate25 then
    local ok = pcall(function() nativeCandidate25:vehicle(vehicle) end)
    if not ok then reportOnce("candidate25-vehicle", "CP2.5 candidate vehicle source unavailable") end
  end
  local signature = stableJson(payload)
  local changed = signature ~= nil and lastValues["VEHICLE_STATE"] ~= signature
  local sent = sendObservation(
    "VEHICLE_STATE",
    payload,
    "Game.GetMountedVehicle;vehicleBaseObject:GetEntityID/GetRecordID/GetVehicleType/IsPlayerDriver",
    nil, signature
  )
  if sent and changed then
    log(
      "vehicle state sent: mounted=" .. tostring(payload.mounted)
        .. " bytes=" .. tostring(#(signature or ""))
        .. " elapsed_ms=" .. string.format("%.3f", (os.clock() - startedAt) * 1000.0)
    )
  end
end

local function nativeDistrictId(value)
  local ok, districtId = pcall(function()
    return TDBID.ToStringDEBUG(value)
  end)
  if not ok or type(districtId) ~= "string" or districtId == "" then
    return nil
  end
  return districtId
end

local function nativeDistrictName(record)
  local ok, localizedName = pcall(function()
    return Game.GetLocalizedText(record:LocalizedName())
  end)
  if not ok or type(localizedName) ~= "string" or localizedName == "" then
    return nil
  end
  return localizedName
end

local function readCurrentDistrict()
  local ok, result = pcall(function()
    local systems = Game.GetScriptableSystemsContainer()
    local prevention = systems:Get("PreventionSystem")
    if prevention == nil then
      return nil
    end

    local district = prevention:GetCurrentDistrict()
    if district == nil then
      return nil
    end

    local currentId = nativeDistrictId(district:GetDistrictID())
    local record = district:GetDistrictRecord()
    if currentId == nil or record == nil then
      return nil
    end

    local leafToRoot = {}
    local seen = {}
    local depth = 0
    while record ~= nil do
      depth = depth + 1
      if depth > DISTRICT_MAX_HIERARCHY_LEVELS then
        error("native district hierarchy exceeded safe depth")
      end

      local recordId = nativeDistrictId(record:GetID())
      if recordId == nil or seen[recordId] then
        error("native district hierarchy contained an invalid or repeated record")
      end
      seen[recordId] = true

      local level = { district_id = recordId }
      local localizedName = nativeDistrictName(record)
      if localizedName ~= nil then
        level.localized_name = localizedName
      end
      table.insert(leafToRoot, level)
      record = record:ParentDistrict()
    end

    if #leafToRoot == 0 or leafToRoot[1].district_id ~= currentId then
      error("current district ID did not match its native district record")
    end

    local hierarchy = {}
    for index = #leafToRoot, 1, -1 do
      table.insert(hierarchy, leafToRoot[index])
    end

    local payload = {
      current_district_id = currentId,
      native_hierarchy = hierarchy
    }
    if leafToRoot[1].localized_name ~= nil then
      payload.current_localized_name = leafToRoot[1].localized_name
    end
    return payload
  end)
  if not ok then
    reportOnce("district-read", "CURRENT_DISTRICT native read failed: " .. tostring(result))
    return nil
  end
  if result == nil then
    reportOnce("district-unavailable", "CURRENT_DISTRICT is not available in the current lifecycle state")
    return nil
  end
  reportedErrors["district-read"] = nil
  reportedErrors["district-unavailable"] = nil
  return result
end

local function observeDistrict()
  if not gameSessionReady then
    return
  end

  local startedAt = os.clock()
  local payload = readCurrentDistrict()
  if payload == nil then
    return
  end

  local signature = stableJson(payload)
  local changed = signature ~= nil and lastValues["CURRENT_DISTRICT"] ~= signature
  local sent = sendObservation(
    "CURRENT_DISTRICT",
    payload,
    "PreventionSystem:GetCurrentDistrict;District:GetDistrictID/GetDistrictRecord;gamedataDistrict_Record:GetID/LocalizedName/ParentDistrict;Game.GetLocalizedText",
    nil, signature
  )
  if sent and changed then
    log(
      "district state sent: current=" .. tostring(payload.current_district_id)
        .. " levels=" .. tostring(#payload.native_hierarchy)
        .. " bytes=" .. tostring(#(signature or ""))
        .. " elapsed_ms=" .. string.format("%.3f", (os.clock() - startedAt) * 1000.0)
    )
  end
end

local function targetPosition(entity)
  local ok, position = pcall(function()
    return entity:GetWorldPosition()
  end)
  if not ok or position == nil then
    return nil
  end
  local coordinates = {}
  for _, axis in ipairs({ "x", "y", "z" }) do
    local valueOk, value = pcall(function() return position[axis] end)
    if not valueOk or type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
      return nil
    end
    coordinates[axis] = tonumber(string.format("%.3f", value))
  end
  return coordinates
end

local function targetOptional(entity, method)
  local ok, value = pcall(function() return entity[method](entity) end)
  if not ok or value == nil then
    return nil
  end
  if method == "GetRecordID" then
    ok, value = pcall(function() return TDBID.ToStringDEBUG(value) end)
    if not ok or value == nil then return nil end
  end
  local text = tostring(value)
  if text == "" then return nil end
  return text
end

local function observeTargetedEntity(player)
  if not gameSessionReady then
    return
  end
  local systemOk, targetingSystem = pcall(function() return Game.GetTargetingSystem() end)
  if not systemOk or targetingSystem == nil then
    reportOnce("target-system", "TARGETED_ENTITY TargetingSystem unavailable: " .. tostring(targetingSystem))
    return
  end
  local ok, target = pcall(function()
    return targetingSystem:GetLookAtObject(player, true, false)
  end)
  if not ok then
    reportOnce("target-read", "TARGETED_ENTITY native read failed: " .. tostring(target))
    return
  end
  reportedErrors["target-system"] = nil
  reportedErrors["target-read"] = nil
  local payload = { present = target ~= nil }
  if target ~= nil then
    local idOk, entityId = pcall(function() return target:GetEntityID().hash end)
    if not idOk or entityId == nil then
      reportOnce("target-id", "TARGETED_ENTITY native identity unavailable")
      return
    end
    payload.entity_id = tostring(entityId)
    if payload.entity_id == "" or payload.entity_id == "0" or payload.entity_id == "0ULL" then
      reportOnce("target-id", "TARGETED_ENTITY native identity unavailable")
      return
    end
    reportedErrors["target-id"] = nil
    payload.class_name = targetOptional(target, "GetClassName")
    payload.record_id = targetOptional(target, "GetRecordID")
    payload.world_position = targetPosition(target)
    if payload.world_position ~= nil then
      local playerPosition = targetPosition(player)
      if playerPosition ~= nil then
        local dx = payload.world_position.x - playerPosition.x
        local dy = payload.world_position.y - playerPosition.y
        local dz = payload.world_position.z - playerPosition.z
        payload.distance_m = tonumber(string.format("%.3f", math.sqrt(dx * dx + dy * dy + dz * dz)))
      end
    end
  end
  local targetKey = payload.present and ("entity:" .. payload.entity_id) or "no_target"
  local liveTarget = config.target_live_contract_0_1 == true
  local renew = liveTarget and targetRenewElapsed >= config.target_renewal_seconds
  local materialize = lastValues["TARGETED_ENTITY"] ~= targetKey or renew or targetBaselinePending
  local sent = sendObservation(
    "TARGETED_ENTITY",
    payload,
    "Game.GetTargetingSystem;TargetingSystem:GetLookAtObject(player,true,false);entEntity:GetEntityID/GetClassName/GetRecordID/GetWorldPosition;player:GetWorldPosition",
    not (renew or (liveTarget and targetBaselinePending)),
    targetKey
  )
  if liveTarget and sent and materialize then targetRenewElapsed = 0.0 end
end

local function pollTelemetry(candidateDelta)
  local playerOk, player = pcall(function() return Game.GetPlayer() end)
  local isMenu = readMenuState()
  local worldReady = playerOk and readAttachedWorld(player)
  reconcileLoading(isMenu, worldReady)
  local worldVerified = gameSessionReady and worldReady and isMenu ~= nil
    and not menuContext.is_loading and not loadingProgressUnknown
  if not worldVerified then
    local knownLoading = menuContext.is_loading and not loadingProgressUnknown and isMenu ~= nil
    local loadingOffered = knownLoading and observeMenuState(isMenu, worldReady) == true
    suspendNativeCandidate25((not playerOk or player == nil) and "PLAYER_UNAVAILABLE" or "NOT_READY")
    revokeWorldContext(knownLoading and "loading" or "read_error", knownLoading, not loadingOffered)
    -- Menus independently observed and transport heartbeats remain useful.
    if not knownLoading then observeMenuState(isMenu, worldReady) end
    if not playerOk then reportOnce("player", "Game.GetPlayer unavailable") end
    return
  end
  observeMenuState(isMenu, worldReady)
  if not connected then return end
  worldContextOffered = true
  if nativeCandidate25 then
    if isMenu == false or nativeCandidate25.active then
      -- Opening a generation requires gameplay, not a menu. Existing active
      -- generations can still observe ordinary in-game menus; Core gates advice.
      local ok = pcall(function()
        nativeCandidate25:resume()
        nativeCandidate25:tick(candidateDelta, player)
      end)
      if not ok then
        suspendNativeCandidate25("CANDIDATE_ERROR")
        reportOnce("candidate25-poll", "CP2.5 candidate poll failed")
      end
    else suspendNativeCandidate25("NOT_READY") end
  end
  observePosition(player)
  observeJournal(player, worldReady)
  observeCombat(player)
  observeWeapon(player)
  observeLife(player)
  observeVehicle(player)
  observeDistrict()
  observeTargetedEntity(player)
  local snapshotSent = observeInventorySnapshot(player)
  if not snapshotSent and inventoryDeltaElapsed >= (config.inventory_delta_poll_seconds or 2.0) then
    inventoryDeltaElapsed = 0.0
    observeInventoryDelta(player)
  end
end

-- RedSocket may throw while its native peer is being torn down. A failed
-- status read is unknown, never proof that it is safe to reconnect.
local function socketConnected()
  if socket == nil then return false end
  local ok, status = pcall(function() return socket:IsConnected() end)
  if not ok or type(status) ~= "boolean" then
    reportOnce("socket-status", "socket status unavailable")
    return nil
  end
  reportedErrors["socket-status"] = nil
  return status
end

requestSocketReset = function()
  connected = false
  clearPendingAcks()
  inventorySnapshotPending = true
  inventoryDeltaBaseline = nil
  heartbeatElapsed = 0.0
  suspendNativeCandidate25("DISCONNECTED")
  if not socketResetPending then
    reconnectElapsed = config.reconnect_interval_seconds or 5.0
    socketResetPending = true
  end
end

local function releaseOwnedSocket()
  local owned = socket
  socket = nil -- revoke callback admission before releasing the wrapper
  connected = false
  socketResetPending = false
  clearPendingAcks()
  inventorySnapshotPending = true
  inventoryDeltaBaseline = nil
  inventoryDeltaElapsed = 0.0
  loadingRecoverySamples = 0
  heartbeatElapsed = 0.0
  if owned ~= nil then
    local ok, released = pcall(redSocketApi.destroySocket, owned)
    -- The RC3 wrapper revokes ownership before native destruction. Never
    -- retry ambiguous destruction, or touch another consumer's wrapper.
    if not ok or released ~= true then
      reportOnce("release-owned", "socket release not confirmed")
    else
      reportedErrors["release-owned"] = nil
    end
  end
end

local function disconnectOwnedSocket()
  initialized = false
  releaseOwnedSocket()
  if nativeCandidate25 then pcall(function() nativeCandidate25:shutdown() end) end
  nativeCandidate25 = nil
  redSocketApi = nil
end

local function receiveResponse(command)
  -- Responses are untrusted even on loopback. Never copy receiver text/IDs
  -- into the CET log; a rejection requires a new producer session and baseline.
  if type(command) ~= "string" or #command > 4096 then
    reportOnce("receiver-invalid", "receiver response invalid")
    requestSocketReset()
    return
  end
  local ok, response = pcall(json.decode, command)
  if not ok or type(response) ~= "table" then
    reportOnce("receiver-invalid", "receiver response invalid")
    requestSocketReset()
    return
  end
  if response.status == "rejected" then
    reportOnce("receiver-rejected", "receiver rejected an observation; resynchronizing")
    requestSocketReset()
  elseif response.status == "accepted" and type(response.message_id) == "string"
      and pendingAcks[response.message_id] ~= nil then
    -- Exact membership in the current epoch, not merely a UUID-shaped string.
    -- This retires an offered frame; it does not establish peer identity.
    local id = response.message_id
    pendingAcks[id] = nil
    pendingAckCount = pendingAckCount - 1
    if pendingInventoryAck == id then pendingInventoryAck = nil end
    reportedErrors["receiver-invalid"] = nil
    reportedErrors["receiver-ack-timeout"] = nil
    reportedErrors["receiver-ack-budget"] = nil
  elseif response.status == "heartbeat" and response.session_id == sessionId then
    reportedErrors["receiver-invalid"] = nil
  else
    reportOnce("receiver-invalid", "receiver response invalid")
    requestSocketReset()
  end
end

local function bindSocket()
  if socket ~= nil then return true end
  local ok, owned = pcall(redSocketApi.createSocket)
  if not ok or owned == nil then
    reportOnce("socket-create", "RedSocket socket unavailable; will retry")
    return false
  end
  socket = owned
  local registeredOK, registered = pcall(function()
    return owned:RegisterListener(
      function(command)
        if socket == owned and initialized and connected and not socketResetPending then receiveResponse(command) end
      end,
      function(status)
        if socket ~= owned or not initialized or socketResetPending then return end
        local wasConnected = connected
        connected = socketConnected() == true
        if connected then
          if not wasConnected then
            suspendNativeCandidate25("RECONNECT")
            beginProducerSession()
          end
          -- A new TCP connection needs a complete current snapshot even when
          -- game state did not change while the receiver was unavailable.
          lastValues = {}
          targetBaselinePending = true
          targetRenewElapsed = 0.0
          inventorySnapshotPending = true
          inventoryDeltaBaseline = nil
          inventoryDeltaElapsed = 0.0
          heartbeatElapsed = 0.0
          reportedErrors["connect"] = nil
          log("connected to " .. config.host .. ":" .. tostring(config.port))
        else
          log("connection not ready")
        end
      end,
      function()
        if socket ~= owned or not initialized then return end
        connected = false
        clearPendingAcks()
        suspendNativeCandidate25("DISCONNECTED")
        heartbeatElapsed = 0.0
        log("disconnected; reconnection will be attempted")
      end,
      function()
        if socket ~= owned or not initialized then return end
        reportOnce("send-error", "RedSocket send error; resetting socket")
        requestSocketReset()
      end
    )
  end)
  if not registeredOK or registered ~= true then
    releaseOwnedSocket()
    reportOnce("socket-listener", "RedSocket listener refused; will retry")
    return false
  end
  reportedErrors["socket-create"] = nil
  reportedErrors["socket-listener"] = nil
  return true
end

local function connect()
  if socket == nil or socketConnected() ~= false then
    return
  end
  local ok, offered = pcall(function()
    return socket:Connect(config.host, config.port)
  end)
  if not ok or offered == false then
    reportOnce("connect", "connection attempt failed")
  end
end

registerForEvent("onInit", function()
  if initialized or socket ~= nil then return end
  local seed = os.time() + math.floor(os.clock() * 1000000)
  math.randomseed(seed)

  local ok, initError = pcall(function()
    config = loadConfig()
    -- Generated lab candidate is inert unless explicitly enabled for CP2.5.
    if config.native_candidate_25 ~= true then return end
    if config.game_version ~= "2.5" or config.schema_version ~= "0.03" then error("CP25_CANDIDATE_PROFILE_INVALID") end
    if config.native_candidate_profile ~= nil and config.native_candidate_profile ~= "baseline" and config.native_candidate_profile ~= "expanded" then error("CP25_CANDIDATE_PROFILE_INVALID") end
    sessionId = newUuid()
    redSocketApi = GetMod("RedSocket")
    if redSocketApi == nil or redSocketApi.version ~= "0.5.2-rc.3"
        or type(redSocketApi.createSocket) ~= "function"
        or type(redSocketApi.destroySocket) ~= "function" then
      error("DeepBide-RedSocket 0.5.2-rc.3 CET API required")
    end

    registerMenuObservers()
    registerInventoryLifecycleObservers()
    initializeNativeCandidate25()
    if nativeCandidate25 then
      local stashOK, stashModule = pcall(require,"native_stash_25")
      nativeCandidate25:set_stash_reader(function()
        if not stashOK then return nil,"STASH_SOURCE_UNAVAILABLE" end
        local stash,reason=stashModule.resolve()
        if not stash then return nil,reason end
        local state=readInventoryState(stash,true)
        if not state then return nil,"STASH_LIST_UNAVAILABLE" end
        return state
      end,compareInventoryStates)
    end
    initialized = true
    if bindSocket() then connect() end
  end)

  if not ok then
    disconnectOwnedSocket()
    log("initialization failed; check config and compatible RedSocket dependency")
  end
end)

registerForEvent("onUpdate", function(delta)
  if not initialized then
    return
  end

  local nativeConnected = socketConnected()
  if socket ~= nil and nativeConnected == false then
    local ok, retired = pcall(function() return socket:IsRetired() end)
    if ok and retired == true then
      releaseOwnedSocket()
      suspendNativeCandidate25("DISCONNECTED")
      reconnectElapsed = 0.0
    end
  end
  if socket == nil then
    -- A native Running session may not exist at CET onInit, or may end
    -- while this consumer is still alive. Rebind at the existing bounded
    -- retry interval, without re-registering the game observers.
    reconnectElapsed = reconnectElapsed + delta
    if reconnectElapsed >= (config.reconnect_interval_seconds or 5.0) then
      reconnectElapsed = 0.0
      if bindSocket() then connect() end
    end
    return
  end
  if nativeConnected == nil and not socketResetPending then requestSocketReset() end
  if socketResetPending then
    connected = false
    suspendNativeCandidate25("DISCONNECTED")
    if nativeConnected == false then
      socketResetPending = false
      reconnectElapsed = 0.0
    else
      reconnectElapsed = reconnectElapsed + delta
      if reconnectElapsed >= (config.reconnect_interval_seconds or 5.0) then
        reconnectElapsed = 0.0
        local ok = pcall(function() socket:Disconnect() end)
        if not ok then reportOnce("disconnect", "socket reset failed") end
      end
    end
    return -- no sends until disconnect is witnessed and a fresh callback arrives
  end

  if nativeConnected == false then
    if connected then clearPendingAcks() end
    connected = false
    loadingRecoverySamples = 0
    suspendNativeCandidate25("DISCONNECTED")
    reconnectElapsed = reconnectElapsed + delta
    if reconnectElapsed >= (config.reconnect_interval_seconds or 5.0) then
      reconnectElapsed = 0.0
      connect()
    end
    return
  end
  if not connected then
    -- A native connected socket without a confirmed Lua epoch is ambiguous.
    -- Allow the connection callback its normal interval, then reset rather
    -- than waiting forever or inventing a producer session.
    reconnectElapsed = reconnectElapsed + delta
    if reconnectElapsed >= (config.reconnect_interval_seconds or 5.0) then
      requestSocketReset()
    end
    return
  end

  reconnectElapsed = 0.0
  if not checkPendingAcks(delta) then return end
  heartbeatElapsed = heartbeatElapsed + delta
  if heartbeatElapsed >= (config.heartbeat_interval_seconds or 2.0) then
    heartbeatElapsed = 0.0
    sendHeartbeat()
  end
  if not connected then return end
  pollElapsed = pollElapsed + delta
  if config.journal_verification_0_1 == true then journalElapsed = journalElapsed + delta end
  if config.target_live_contract_0_1 == true then targetRenewElapsed = targetRenewElapsed + delta end
  inventoryDeltaElapsed = inventoryDeltaElapsed + delta
  if pollElapsed >= (config.poll_interval_seconds or 0.5) then
    local candidateDelta = pollElapsed
    pollElapsed = 0.0
    pollTelemetry(candidateDelta)
  end
end)

registerForEvent("onShutdown", function()
  disconnectOwnedSocket()
  inventorySnapshotPending = true
  inventoryDeltaBaseline = nil
  inventoryDeltaElapsed = 0.0
end)
