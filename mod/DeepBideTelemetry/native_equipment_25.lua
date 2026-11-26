local function number(v, lo, hi)
  local n = type(v) == "number" and v or nil
  if n == nil or n ~= n or n < lo or n > hi then return nil end
  return n
end
local function integer(v, lo, hi)
  local n = number(v,lo,hi)
  if n == nil or n ~= math.floor(n) then return nil end
  return n
end
local function boolean(v) if type(v) == "boolean" then return v end end
local function safely(fn)
  local ok, a, b = pcall(fn)
  if ok then return a,b end
  return nil,nil
end
-- CET Enum.value is the symbolic name; EnumInt returns a Uint64 as
-- LuaJIT cdata (official CET patch notes: 2ULL). Normalize only numeric
-- cdata and retain the existing integer/range guard. Never parse names,
-- strings, booleans, pointers or arbitrary display representations.
local function enumInteger(v,lo,hi)
  if type(v)=="cdata" then
    v=safely(function() return tonumber(v) end)
  end
  return integer(v,lo,hi)
end
local function rawEnum(v, lo, hi)
  local n=enumInteger(v,lo,hi)
  if n ~= nil then return n end
  n=safely(function() return enumInteger(v.value,lo,hi) end)
  if n ~= nil then return n end
  return safely(function() return enumInteger(EnumInt(v),lo,hi) end)
end
-- CP2077 2.5 native reader library for the supported producer.
-- Candidate integration source only. No callbacks, timers, transport, writes,
-- private cache access or product admission. Host controls lifecycle and budget.
local M={}
-- One ordered allowlist shared by the reader and the scheduler.
local areaNames={"Weapon","Head","Face","InnerChest","OuterChest","Legs","Feet","Outfit",
 "ArmsCW","CardiovascularSystemCW","EyesCW","FrontalCortexCW","HandsCW","IntegumentarySystemCW",
 "LegsCW","MusculoskeletalSystemCW","NervousSystemCW","SystemReplacementCW","ImmuneSystemCW","FaceCW"}
local areas={}
for _,name in ipairs(areaNames) do areas[name]=true end
function M.area_names()
 local copy={}
 for i,name in ipairs(areaNames) do copy[i]=name end
 return copy
end
local defaults={"Quality","PartArmor","ItemArmor","Armor","ArmorMultBonus","MeleeResistance","CarryCapacity"}
local unpackArgs=table.unpack or unpack
local function compactRef(id)
 local h=safely(function() return enumInteger(id.hash,0,4294967295) end)
 local l=safely(function() return enumInteger(id.length,1,255) end)
 if h and l then return string.format("TDBID:%08X:%02X",h,l) end
end
local function nameOf(id)
 return safely(function()
  local s=TDBID.ToStringDEBUG(id)
  if type(s)=="string" and #s<=180 and s:match("^[%w_%.]+$") then return s end
 end)
end
local function nativeId(id)
 return safely(function() return id.tdbid end) or safely(function() return ItemID.GetTDBID(id) end)
end
local function decimalId(v)
 local s=safely(function() return tostring(v) end)
 if type(s)~="string" then return nil end
 s=s:gsub("ULL$",""):gsub("UL$","")
 if not s:match("^%d+$") or #s>20 or (#s==20 and s>"18446744073709551615") or s=="0" then return nil end
 if #s>1 and s:sub(1,1)=="0" then return nil end
 return s
end
local function identity(id)
 if id==nil then return {} end
 local t=nativeId(id)
 local valid=safely(function() return ItemID.IsValid(id) end)
 local h
 if valid==true then h=safely(function() return decimalId(ItemID.GetCombinedHash(id)) end) end
 return {record_id=nameOf(t),record_ref=compactRef(t),item_id=h}
end
local function same(a,b)
 if type(a)~="table" or type(b)~="table" or not a.item_id or a.item_id~=b.item_id then return false end
 if a.record_ref and b.record_ref and a.record_ref~=b.record_ref then return false end
 if a.record_id and b.record_id and a.record_id~=b.record_id then return false end
 return (a.record_ref~=nil and a.record_ref==b.record_ref) or (a.record_id~=nil and a.record_id==b.record_id)
end
local function readInner(obj,method,...)
 local args={...}
 local v=safely(function() return obj[method](obj,unpackArgs(args)) end)
 if v~=nil then return v end
 return safely(function() return gameInnerItemData[method](obj,unpackArgs(args)) end)
end
-- Retain explicit absence and failure. A returned zero is an observed zero.
local function stats(obj,keys,inner)
 local out,seen={},{}
 keys=keys or defaults
 if type(keys)~="table" or #keys>16 then return nil end
 for _,name in ipairs(keys) do
  if type(name)~="string" or #name>80 or not name:match("^[%w_]+$") or seen[name] then return nil end
  seen[name]=true
  local t=safely(function() return gamedataStatType[name] end)
  local n=rawEnum(t,0,10000)
  local row={name=name,status="UNAVAILABLE"}
  if n~=nil then
   row.stat_type=n
   local has
   if inner then has=readInner(obj,"HasStatData",t) else has=safely(function() return obj:HasStatData(t) end) end
   if has==false then row.status="ABSENT"
   elseif has==true then
    local v
    if inner then v=number(readInner(obj,"GetStatValueByType",t),-10000000,10000000)
    else v=safely(function() return number(obj:GetStatValueByType(t),-10000000,10000000) end) end
    if v~=nil then row.value=v;row.status="OBSERVED" end
   end
  end
  out[#out+1]=row
 end
 return out
end
local function sourceSlots(player,area)
 if not player or not areas[area] then return nil end
 return safely(function()
  local sys=Game.GetScriptableSystemsContainer():Get("EquipmentSystem")
  return sys:GetPlayerData(player):GetEquipArea(gamedataEquipmentArea[area]).equipSlots
 end)
end
local function partData(part,index,keys)
 local pid=readInner(part,"GetItemID")
 local id=identity(pid)
 if not id.record_ref and not id.record_id then
  local r=readInner(part,"GetStaticData")
  local t=safely(function() return r:GetID() end)
  id.record_ref=compactRef(t);id.record_id=nameOf(t)
 end
 local slot=readInner(part,"GetSlotID")
 local row={index=index,identity=id,slot_ref=compactRef(slot),slot_name=nameOf(slot),status="PARTIAL"}
 if (id.record_id or id.record_ref) and (row.slot_name or row.slot_ref) then
  row.stats=stats(part,keys,true)
  if row.stats then
   row.status="OBSERVED"
   for _,s in ipairs(row.stats) do if s.status=="UNAVAILABLE" then row.status="PARTIAL" end end
  end
 end
 return row
end
function M.identity(id) return identity(id) end
function M.read_area(player,area)
 local result={area=area,status="UNAVAILABLE",complete=false,slots={}}
 local native=sourceSlots(player,area)
 if type(native)~="table" then return result end
 result.source_count=#native
 result.complete=#native<=12
 for i=1,math.min(#native,12) do
  local row={index=i-1,status="UNAVAILABLE"}
  local id=safely(function() return native[i].itemID end)
  local valid=safely(function() return ItemID.IsValid(id) end)
  if valid==false then row.occupied=false;row.status="OBSERVED"
  elseif valid==true then
   row.occupied=true;row.identity=identity(id)
   row.status=(row.identity.item_id and (row.identity.record_ref or row.identity.record_id)) and "OBSERVED" or "PARTIAL"
  end
  if row.status~="OBSERVED" then result.complete=false end
  result.slots[#result.slots+1]=row
 end
 result.status=result.complete and "OBSERVED" or "PARTIAL"
 return result
end
function M.read_item_data(live,expected,keys)
 local out={status="UNAVAILABLE",identity_consistent=false,parts={status="UNAVAILABLE",complete=false,rows={}}}
 if not live then return out end
 local actual=identity(safely(function() return live:GetID() end))
 if not same(actual,expected) then out.status="IDENTITY_MISMATCH";return out end
 out.identity=actual;out.identity_consistent=true
 out.item_type=safely(function() return rawEnum(live:GetItemType(),0,10000) end)
 out.stats=stats(live,keys,false)
 if not out.stats then out.status="PARTIAL";return out end
 out.status=out.item_type~=nil and "OBSERVED" or "PARTIAL"
 for _,s in ipairs(out.stats) do if s.status=="UNAVAILABLE" then out.status="PARTIAL" end end
 local a,b=safely(function() return live:GetItemParts() end)
 local parts=type(a)=="table" and a or (a~=false and type(b)=="table" and b or nil)
 if not parts then return out end
 local p=out.parts
 p.source_count=#parts;p.complete=#parts<=12
 for i=1,math.min(#parts,12) do
  local row=partData(parts[i],i-1,keys or {"Quality","PartArmor","ItemArmor"})
  p.rows[#p.rows+1]=row
  if row.status~="OBSERVED" then p.complete=false end
 end
 p.status=p.complete and "OBSERVED" or "PARTIAL"
 return out
end
function M.read_equipped_item(player,area,index,expected,keys)
 if not integer(index,0,11) or not expected then return {status="UNAVAILABLE",identity_consistent=false} end
 local native=sourceSlots(player,area)
 local id=type(native)=="table" and safely(function() return native[index+1].itemID end) or nil
 if not same(identity(id),expected) then return {status="IDENTITY_MISMATCH",identity_consistent=false} end
 local live=safely(function() return Game.GetTransactionSystem():GetItemData(player,id) end)
 return M.read_item_data(live,expected,keys)
end
return M
