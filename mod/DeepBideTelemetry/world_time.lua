-- Original DeepBide read-only world clock. No setters, save access or new transport.
-- The engine APIs are candidates until verified against the actual CP2.5 runtime.
local M = {}
local MAX = 2147483647
local INTERVAL = 1.0
local LARGE_STEP = 300

local function number(v, limit, integral)
  if type(v) == "cdata" then v = tonumber(v) end
  if type(v) ~= "number" or v ~= v or v < 0 or v > limit then return nil end
  if integral and v ~= math.floor(v) then return nil end
  return v
end

local function getter(fn, limit)
  local ok, value = pcall(fn)
  if not ok or value == nil then return nil, false end
  return number(value, limit, true), true
end

function M.read()
  local ok, stamp = pcall(function() return Game.GetTimeSystem():GetGameTime() end)
  if not ok or stamp == nil then return nil end
  -- All world fields derive from this ONE native value, not multiple clock reads.
  local total, totalReturned = getter(function() return GameTime.GetSeconds(stamp) end, MAX)
  local hour, hourReturned = getter(function() return GameTime.Hours(stamp) end, 23)
  local minute, minuteReturned = getter(function() return GameTime.Minutes(stamp) end, 59)
  local day, dayReturned = getter(function() return GameTime.Days(stamp) end, MAX)
  if (totalReturned and total == nil) or (hourReturned and hour == nil)
      or (minuteReturned and minute == nil) or (dayReturned and day == nil) then return nil end
  local second
  if total ~= nil then
    local h, m, d = math.floor(total / 3600) % 24, math.floor(total / 60) % 60, math.floor(total / 86400)
    -- Refuse inconsistent API semantics rather than silently "fixing" a clock.
    if (hour ~= nil and hour ~= h) or (minute ~= nil and minute ~= m)
        or (day ~= nil and day ~= d) then return nil end
    hour, minute, day, second = h, m, d, total % 60
  elseif hour == nil or minute == nil then
    return nil
  end
  local p = {hour=hour, minute=minute, minute_of_day=hour*60+minute,
             day=day, second=second, world_seconds=total,
             precision=total ~= nil and "SECOND" or "MINUTE"}
  -- A separate engine counter, never inferred from the story clock or UTC.
  local playOK, play = pcall(function()
    return EngineTime.ToFloat(Game.GetPlaythroughTime())
  end)
  if playOK then
    play = number(play, MAX, false)
    if play ~= nil then p.playthrough_seconds = math.floor(play * 1000) / 1000 end
  end
  return p
end

function M.new(offer, read, sourceClock)
  local self = {}
  read = read or M.read
  local seq, elapsed, previous, reason, unavailable, skipAge
  function self:reset()
    seq, elapsed, previous, reason, unavailable, skipAge = 0, INTERVAL, nil, "INITIAL", nil, nil
  end
  self:reset()

  local function send(p, observedAt)
    if seq >= MAX then return false end -- no wrap or re-use
    seq = seq + 1
    p.contract_version, p.sample_seq = "0.1", seq
    return offer(p, observedAt) == true
  end

  function self:invalidate(why)
    if why == "loading" or why == "session_boundary" then
      previous, reason, skipAge = nil, "AFTER_WORLD_BOUNDARY", nil
    elseif why == "read_error" then
      previous, skipAge = nil, nil
      if reason ~= "AFTER_WORLD_BOUNDARY" then reason = "AFTER_READ_GAP" end
    elseif reason ~= "AFTER_WORLD_BOUNDARY" and reason ~= "AFTER_READ_GAP" then
      reason = "AFTER_MENU"
    end
    if unavailable == why then return end
    unavailable = why
    elapsed = INTERVAL
    -- Negative observations retain distinct loading/session/read/menu witnesses.
    -- They revoke only the clock, not the entire BASE set.
    send({availability="UNAVAILABLE",reason=why})
  end

  function self:note_skip_finish()
    -- A callback is a witness of its occurrence, not proof of the jump cause.
    if previous ~= nil then skipAge = 0 end
  end

  function self:tick(dt, gameplay)
    if type(dt) ~= "number" or dt ~= dt or dt < 0 or dt > MAX then
      self:invalidate("read_error")
      return
    end
    if skipAge ~= nil then
      skipAge = skipAge + dt
      if skipAge > 10 then skipAge = nil end
    end
    if not gameplay then
      self:invalidate("menu")
      return
    end
    elapsed = elapsed + dt
    if elapsed < INTERVAL then return end
    local interval = elapsed
    elapsed = 0
    local observedAt = sourceClock and sourceClock() or nil
    local ok, p = pcall(read)
    if not ok or type(p) ~= "table" then
      self:invalidate("read_error")
      -- Retry at the same bounded cadence, including first-time failures.
      elapsed = 0
      return
    end
    p.availability = "OBSERVED"
    p.continuity = reason or (interval > 2.5 and "AFTER_POLL_GAP" or "ADJACENT")
    p.clock_change = "NO_COMPARISON"
    p.skip_finish_callback_seen = skipAge ~= nil
    -- Across a menu/poll gap the raw difference is still useful, but the
    -- continuity label explicitly denies a continuous-play inference.
    if previous ~= nil and previous.world_seconds ~= nil and p.world_seconds ~= nil then
      local delta = p.world_seconds - previous.world_seconds
      p.delta_world_seconds = delta
      p.clock_change = delta < 0 and "BACKWARD" or delta == 0 and "UNCHANGED"
        or delta >= LARGE_STEP and "LARGE_FORWARD" or "FORWARD"
    end
    if send(p, observedAt) then
      previous, reason, unavailable, skipAge = p, nil, nil, nil
    else
      previous, reason, skipAge = nil, "AFTER_READ_GAP", nil
    end
  end
  return self
end

return M
