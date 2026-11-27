-- CP2.5 candidate observations, not an admitted Core wire contract.
-- Reuses macro discovery witnesses; no standalone probe, private data, or socket.
local M = {}
local MAX_ID = "18446744073709551615"
local unpackArgs = table.unpack or unpack
local function call(f)
  local ok,a,b = pcall(f)
  if ok then return a,b end
end
local function int(v,lo,hi)
  if type(v)=="cdata" then v=call(function() return tonumber(v) end) end
  if type(v)=="number" and v==v and v>=lo and v<=hi and v==math.floor(v) then return v end
end
local function enum(v)
  return int(v,-2147483648,2147483647)
    or call(function() return int(v.value,-2147483648,2147483647) end)
    or call(function() return int(EnumInt(v),-2147483648,2147483647) end)
end
local function variant(v) return enum(call(function() return FromVariant(v) end)) or enum(v) end
local function boolean(v) if type(v)=="boolean" then return v end end
local function read(obj,method,...)
  local args={...}
  return call(function() return obj[method](obj,unpackArgs(args)) end)
end
local function rb(obj,method) return boolean(read(obj,method)) end
local function token(v)
  if type(v)=="string" and #v<=180 and #v>0 and v:match("^[%w_%.]+$") then return v end
end
local function decimal(v)
  if type(v)=="number" then
    if not int(v,0,9007199254740991) then return nil end
    v=string.format("%.0f",v)
  elseif type(v)=="cdata" then v=call(function() return tostring(v) end) end
  if type(v)~="string" then return nil end
  v=v:gsub("ULL$",""):gsub("UL$","")
  if not v:match("^%d+$") or #v>20 or (#v==20 and v>MAX_ID)
    or (#v>1 and v:sub(1,1)=="0") then return nil end
  return v
end
local function nativeId(id) return call(function() return decimal(id.hash) end) end
local function eid(obj) return nativeId(read(obj,"GetEntityID")) end
local function record(id)
  if id==nil then return nil end
  local name=call(function() return token(TDBID.ToStringDEBUG(id)) end)
  local h=call(function() return int(id.hash,0,4294967295) end)
  local l=call(function() return int(id.length,1,255) end)
  local ref=h and l and string.format("TDBID:%08X:%02X",h,l) or nil
  if name or ref then return {record_id=name,record_ref=ref} end
end
local function cname(v)
  return token(v) or call(function() return token(Game.NameToString(v)) end)
    or call(function() return token(NameToString(v)) end)
    or call(function() return token(v.value) end)
end
local function playerIs(actor)
  local p=call(function() return Game.GetPlayer() end)
  local id=eid(actor)
  local pid=eid(p)
  if not id or id=="0" or not pid or pid=="0" then return nil end
  return pid==id
end
local function field(v)
  if v==nil then return {availability="UNAVAILABLE"} end
  return {availability="OBSERVED",value=v}
end
-- Never treat a missing bool as false or a camera enum as a generic device enum.
function M.read_entity(native)
  local id=nativeId(native)
  if id=="0" then return "ABSENT",nil,{present=false} end
  if not id then return "UNKNOWN","IDENTITY_UNRESOLVED",{} end
  local obj=call(function() return Game.FindEntityByID(native) end)
  if not obj then return "UNAVAILABLE","ENTITY_NOT_RESOLVED",{entity_id=id} end
  if eid(obj)~=id then return "UNKNOWN","IDENTITY_MISMATCH",{entity_id=id} end
  local d={entity_id=id,record=record(read(obj,"GetRecordID")),class_name=cname(read(obj,"GetClassName")),
    is_device=field(rb(obj,"IsDevice")),is_npc=field(rb(obj,"IsNPC")),is_vehicle=field(rb(obj,"IsVehicle"))}
  d.classification=(d.record or d.class_name) and "OBSERVED" or "UNKNOWN"
  d.record_availability=d.record and "OBSERVED" or "UNKNOWN"
  d.semantic_status="UNKNOWN"
  if d.is_device.value==true then
    local ps=read(obj,"GetDevicePS")
    d.device_state={raw=field(enum(read(obj,"GetDeviceState"))),on=field(rb(ps,"IsON")),
      off=field(rb(ps,"IsOFF")),disabled=field(rb(ps,"IsDisabled")),
      open=field(rb(ps,"IsOpen")),locked=field(rb(ps,"IsLocked"))}
    local known=false
    for _,f in pairs(d.device_state) do if f.availability=="OBSERVED" then known=true end end
    d.device_state_availability=known and "OBSERVED" or "UNKNOWN"
    if not known then return "UNKNOWN","DEVICE_STATE_UNRESOLVED",d end
  elseif d.is_device.availability~="OBSERVED" then
    return "UNKNOWN","ENTITY_TYPE_UNRESOLVED",d
  end
  if d.classification=="UNKNOWN" then return "UNKNOWN","CLASSIFICATION_UNRESOLVED",d end
  if not d.record then return "UNKNOWN","RECORD_UNRESOLVED",d end
  return "OBSERVED",nil,d
end

local function actionRecord(a) return record(read(a,"GetObjectActionID")) end
local function actionData(a)
  return {action_record=actionRecord(a),action_name=cname(read(a,"GetActionName")),
    choice_record=record(read(a,"GetTweakDBChoiceID")),native_completed=field(rb(a,"IsCompleted")),
    quickhack=field(rb(a,"IsQuickHack")),consequence="UNKNOWN"}
end
local function signature(v)
  if type(v)~="table" then return type(v)..":"..tostring(v) end
  local keys={}; for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
  local out={"{"}
  for _,k in ipairs(keys) do out[#out+1]=signature(k).."="..signature(v[k])..";" end
  out[#out+1]="}";return table.concat(out)
end
-- Only the host supplies a sink. Disabled by default. No Core sendObservation.
function M.new(sink,equipment)
  assert(type(sink)=="function")
  local areas=equipment and equipment.area_names() or {}
  local self={active=false,generation=0,seq=0,elapsed=0,period=0,remaining=24,
    dropped=0,last={},pending=nil,scan=nil,area=1,slot=1,round=1,work=nil,acc=0,registered=false,terminal=false,registration_gaps={}}
  local function emit(kind,source,status,reason,data,key)
    if not self.active then return nil end
    -- After a loss, do not publish more correlated state ahead of the barrier.
    -- SESSION may close the generation even when there is an unresolved gap.
    if self.dropped>0 and kind~="SESSION" and not (kind=="SOURCE_GAP" and reason=="EVENTS_DROPPED") then
      self.dropped=self.dropped+1
      return nil
    end
    local row={contract="cp25-native-candidate/0.3",kind=kind,source=source,generation=self.generation,
      availability=status,reason=reason,data=data or {},elapsed_ms=math.floor(self.elapsed*1000)}
    local sig
    if key then
      sig=signature({status,reason or "",row.data})
      local prior=self.last[key]
      if prior and prior.signature==sig and self.elapsed-prior.time<10 then return nil end
    end
    if self.remaining<=0 then self.dropped=self.dropped+1;return nil end
    self.remaining=self.remaining-1
    self.seq=self.seq+1; row.sequence=self.seq
    local ok,result=pcall(sink,row)
    if not ok or result~=true then self.dropped=self.dropped+1;return nil end
    if key then self.last[key]={signature=sig,time=self.elapsed} end
    return row.sequence
  end
  local function unknown(kind,source,reason,data,key)
    return emit(kind,source,"UNKNOWN",reason,data,key)
  end
  local function dropPending(reason)
    local p=self.pending;self.pending=nil
    if p then unknown("DEVICE_READBACK","ScriptableDeviceAction.CompleteAction",reason,
      {entity_id=p.id,completion_sequence=p.seq,consequence="UNKNOWN"}) end
  end
  -- Static refs come from the existing inventory traversal, not a second GetItemList.
  -- Queue only a bounded number of unique references; loss is explicit.
  function self:offer_record(itemId,recordName)
    if not self.active then return nil end
    local name=token(recordName)
    local r
    if name and name:match("^[%w_]+%.[%w_.]+$") then r={record_id=name}
    else
      local id=call(function() return itemId.tdbid end) or call(function() return ItemID.GetTDBID(itemId) end)
      r=record(id)
    end
    if r and r.record_id and not r.record_id:match("^[%w_]+%.[%w_.]+$") then r.record_id=nil end
    if not r or (not r.record_id and not r.record_ref) then
      self.record_gaps=self.record_gaps+1
      return nil
    end
    local key=r.record_id or r.record_ref
    if r.record_id and r.record_ref then key=r.record_id..":"..r.record_ref end
    if not self.record_seen[key] then
      if self.record_count>=4096 then self.record_gaps=self.record_gaps+1
      else
        self.record_seen[key]=true;self.record_count=self.record_count+1
        self.record_tail=self.record_tail+1
        self.record_queue[self.record_tail]=r
      end
    end
    return r
  end
  function self:set_stash_reader(reader,compare)
    assert(type(reader)=="function" and type(compare)=="function")
    self.stash_reader=reader;self.stash_compare=compare
  end
  local function flushRefs()
    if self.record_gaps>0 then
      local count=self.record_gaps
      if unknown("SOURCE_GAP","TransactionSystem.GetItemList","INVENTORY_REFERENCE_GAP",{count=count}) then self.record_gaps=0 end
    end
    if self.record_head>self.record_tail then return end
    local rows={}
    for i=self.record_head,math.min(self.record_head+31,self.record_tail) do
      rows[#rows+1]=self.record_queue[i]
    end
    if emit("STATIC_RECORD_REFERENCES","TransactionSystem.GetItemList","OBSERVED",nil,{records=rows}) then
      -- Clear only the consumed cells. Avoid shifting the entire queue per row.
      for i=self.record_head,self.record_head+#rows-1 do self.record_queue[i]=nil end
      self.record_head=self.record_head+#rows
      if self.record_head>self.record_tail then
        self.record_queue={};self.record_head=1;self.record_tail=0
      end
    end
  end
  local function stashStep()
    if not self.stash_reader then return end
    local src="TransactionSystem.GetItemList"
    local w=self.stash_work
    if w then
      local start=w.next
      local rows={}
      for i=start,math.min(start+47,#w.entries) do
        local e=w.entries[i]
        local id=decimal(e.item_id)
        local r=e.record_id
        local named=type(r)=="string" and r:match("^[%w_]+%.[%w_.]+$") and r or nil
        local compact=type(r)=="string" and r:match("^TDBID:%x%x%x%x%x%x%x%x:%x%x$") and r or nil
        local entry={item_id=id,quantity=e.quantity,record_id=named,record_ref=compact,
          record_availability=(named or compact) and "OBSERVED" or "UNKNOWN"}
        if not id or id=="0" then
          self.stash_work=nil;self.stash_last=nil
          return unknown("SOURCE_GAP",src,"STASH_ROW_UNRESOLVED",{count=1})
        end
        rows[#rows+1]=entry
      end
      if #rows==0 then self.stash_work=nil;return end
      local last=start+#rows-1==#w.entries
      if emit("STASH_SNAPSHOT_CHUNK",src,"OBSERVED",nil,{snapshot_id=w.id,start=start-1,rows=rows,final=last}) then
        w.next=start+#rows
        if last then self.stash_last=w.complete and w.entries or nil;self.stash_work=nil;self.stash_due=self.elapsed+30 end
      else self.stash_last=nil;self.stash_work=nil end
      return
    end
    if self.elapsed<self.stash_due then return end
    self.stash_due=self.elapsed+30
    local ok,state,reason=pcall(self.stash_reader)
    if not ok or not state then
      self.stash_last=nil
      self.stash_serial=self.stash_serial+1
      return emit("STASH_SNAPSHOT",src,"UNAVAILABLE",
        ok and (reason or "STASH_LIST_UNAVAILABLE") or "STASH_LIST_UNAVAILABLE",
        {complete=false,entry_count=0,source_count=0,excluded_count=0,scope="stash",snapshot_id=self.stash_serial},"stash_unavailable")
    end
    -- Original multiset comparison is used, not a new item matching algorithm.
    local complete=not state.truncated and state.excluded_entry_count==0 and #state.entries>0
    local change_count
    if complete and self.stash_last then
      local changes=self.stash_compare(self.stash_last,state.entries)
      change_count=#changes
    end
    self.stash_serial=self.stash_serial+1
    local d={snapshot_id=self.stash_serial,scope="stash",complete=complete,entry_count=#state.entries,
      source_count=state.source_entry_count,excluded_count=state.excluded_entry_count,
      truncated=state.truncated,change_count=change_count}
    local reason=not complete and (not state.truncated and state.source_entry_count==0 and "STASH_EMPTY_UNVERIFIED" or "STASH_PARTIAL") or nil
    if emit("STASH_SNAPSHOT",src,complete and "OBSERVED" or "UNKNOWN",reason,d) then
      if #state.entries>0 then
        self.stash_work={id=self.stash_serial,entries=state.entries,next=1,complete=complete}
      else self.stash_last=nil end
    else self.stash_last=nil end
  end
  -- Only a successfully offered explicit budget barrier can establish a
  -- causal source fence. It is not a claim of complete native correlations.
  function self:budget_fence()
    if not self.active or self.terminal or self.dropped ~= 0 then return nil end
    local gen=int(self.generation,1,2147483647)
    local seq=int(self.last_budget_barrier_sequence,1,2147483647)
    if gen and seq then return gen,seq end
  end
  function self:resume()
    if self.active or self.terminal then return end
    self.active=true;self.generation=self.generation+1;self.seq=0;self.elapsed=0;self.period=0
    self.remaining=24;self.dropped=0;self.last_budget_barrier_sequence=nil;self.last={};self.pending=nil;self.scan=nil;self.work=nil
    self.area=1;self.slot=1;self.round=1;self.acc=0;self.equipTurn=true;self.proximityPaused=false
    self.record_seen={};self.record_count=0;self.record_queue={};self.record_gaps=0
    self.record_head=1;self.record_tail=0
    self.stash_work=nil;self.stash_last=nil;self.stash_due=5;self.stash_serial=0;self.tracked_active_root=nil
    emit("SESSION","Producer.lifecycle","OBSERVED",nil,{ready=true})
    for _,src in ipairs(self.registration_gaps) do unknown("SOURCE_GAP",src,"HOOK_UNAVAILABLE",{},"hook:"..src) end
  end
  function self:suspend(reason)
    if not self.active then return end
    dropPending("SESSION_BOUNDARY")
    -- Do not silently discard references still queued or unresolved at close.
    -- At most one additional bounded diagnostic, then the existing close.
    local unoffered=math.max(0,self.record_tail-self.record_head+1)+self.record_gaps
    if unoffered>0 then
      self.remaining=math.max(2,self.remaining)
      unknown("SOURCE_GAP","TransactionSystem.GetItemList","INVENTORY_REFERENCE_GAP",{count=unoffered})
    end
    local missed=self.dropped
    self.remaining=math.max(1,self.remaining)
    emit("SESSION","Producer.lifecycle","OBSERVED",nil,{ready=false,reason=reason,dropped_events=missed})
    self.active=false;self.last_budget_barrier_sequence=nil;self.last={};self.pending=nil;self.scan=nil;self.work=nil
    self.record_seen={};self.record_queue={};self.stash_work=nil;self.stash_last=nil;self.tracked_active_root=nil
  end
  function self:shutdown() self:suspend("SHUTDOWN");self.terminal=true end
  local function scanned(_,native)
    local status,reason,d=M.read_entity(native)
    self.scan=nil
    if status~="ABSENT" and d.entity_id and d.device_state then
      self.scan={id=d.entity_id,state=d.device_state,time=self.elapsed}
    end
    emit("SCANNED_TARGET","gameuiScannerGameController.OnScannedObjectChanged",status,reason,d,"scan")
  end
  local function options(_,v)
    local list=call(function() return v.commands end)
    local target=eid(call(function() return v.lookAtObject end))
    if type(list)~="table" then return emit("QUICKHACK_OPTIONS","QuickhacksListGameController.OnQuickhackStarted","UNAVAILABLE","OPTIONS_UNAVAILABLE",{target_id=target},"options") end
    local d={target_id=target,source_count=#list,complete=#list<=24,options={}}
    for i=1,math.min(#list,24) do
      local x=list[i];local a=call(function() return x.action end)
      local row={index=i-1,action_record=actionRecord(a),cost=field(call(function() return int(x.cost,0,10000) end)),
        locked=field(call(function() return boolean(x.isLocked) end)),action_type=field(call(function() return enum(x.type) end))}
      if not row.action_record then d.complete=false end
      d.options[#d.options+1]=row
    end
    emit("QUICKHACK_OPTIONS","QuickhacksListGameController.OnQuickhackStarted",d.complete and target and "OBSERVED" or "UNKNOWN",
      (not d.complete or not target) and "OPTIONS_PARTIAL" or nil,d,"options")
  end
  local function request(controller)
    local selected=call(function() return controller.selectedData end)
    local a=call(function() return selected.action end)
    local d=actionData(a)
    d.target_id=call(function() return nativeId(selected.actionOwner) end)
    local ok=d.target_id and d.target_id~="0" and d.action_record
    emit("QUICKHACK_REQUEST","QuickhacksListGameController.ApplyQuickhackSelection",ok and "OBSERVED" or "UNKNOWN",
      not ok and "REQUEST_IDENTITY_UNRESOLVED" or nil,d)
  end
  local function complete(a)
    local src="ScriptableDeviceAction.CompleteAction"
    local actor=playerIs(read(a,"GetExecutor"))
    if actor==false then return end
    if actor==nil then return unknown("DEVICE_COMPLETION",src,"EXECUTOR_UNRESOLVED",{},"completion_actor") end
    local d=actionData(a)
    local native=read(a,"GetRequesterID");local id=nativeId(native);d.entity_id=id
    local known=d.action_record and id and id~="0" and d.native_completed.availability=="OBSERVED"
    local seq=emit("DEVICE_COMPLETION",src,known and "OBSERVED" or "UNKNOWN",not known and "COMPLETION_PARTIAL" or nil,d)
    if d.native_completed.value~=true or not id or id=="0" or not seq then return end
    dropPending("READBACK_SUPERSEDED")
    local baseline=self.scan and self.scan.id==id and self.elapsed-self.scan.time<=10 and self.scan.state or nil
    self.pending={id=id,native=native,seq=seq,due=self.elapsed+0.25,deadline=self.elapsed+2,baseline=baseline}
  end
  local function observedValue(kind,source,v)
    emit(kind,source,v~=nil and "OBSERVED" or "UNKNOWN",v==nil and "NATIVE_VALUE_UNRESOLVED" or nil,
      v~=nil and {raw=v,semantic_status=type(v)=="number" and "UNKNOWN" or nil} or {},kind)
  end
  local function choice(_,v)
    local a=call(function() return FromVariant(v) end)
    local t=call(function() return enum(a.visualizerType) end)
    if t==nil then return unknown("DIALOGUE_ATTEMPT","PreventionSystem.OnPlayerChoice","VISUALIZER_UNRESOLVED",{},"dialogue_type") end
    if t~=1 then return end
    local d={visualizer_type=t,index=call(function() return int(a.choiceIdx,0,1024) end),
      native_success=field(call(function() return boolean(a.isSuccess) end)),
      choice_record=call(function() return record(a.choice.choiceMetaData.tweakDBID) end),consequence="UNKNOWN"}
    local ok=d.index~=nil and d.native_success.availability=="OBSERVED"
    emit("DIALOGUE_ATTEMPT","PreventionSystem.OnPlayerChoice",ok and "OBSERVED" or "UNKNOWN",not ok and "CHOICE_PARTIAL" or nil,d)
  end
  local function prompt(c)
    local d={interactions_open=field(call(function() return boolean(c.AreInteractionsOpen) end)),
      dialogs_open=field(call(function() return boolean(c.AreDialogsOpen) end)),
      looting_open=field(call(function() return boolean(c.IsLootingOpen) end))}
    local ok=false;for _,f in pairs(d) do if f.availability=="OBSERVED" then ok=true end end
    emit("INTERACTION_CONTEXT","InteractionUIBase.OnInteractionData",ok and "OBSERVED" or "UNAVAILABLE",
      not ok and "PROMPT_UNAVAILABLE" or nil,d,"prompt")
  end
  local function journal(j,h,want)
    local hash=int(h,0,4294967295)
    local entry=hash and read(j,"GetEntry",hash) or nil
    local actualHash=entry and int(read(j,"GetEntryHash",entry),-2147483648,4294967295)
    if actualHash and actualHash<0 then actualHash=actualHash+4294967296 end
    local actual=actualHash==hash and hash~=nil and enum(read(j,"GetEntryState",entry)) or nil
    local requested=enum(want)
    local ok=actual~=nil and requested~=nil
    emit("JOURNAL_WITNESS","gameJournalManager.ChangeEntryStateByHash",ok and "OBSERVED" or "UNKNOWN",
      not ok and "JOURNAL_READBACK_UNRESOLVED" or nil,{entry_hash=hash,requested=field(requested),actual=field(actual),consequence="UNKNOWN"})
  end
  local function journalHash(j,e)
    local n=int(read(j,"GetEntryHash",e),-2147483648,4294967295)
    if n and n<0 then return n+4294967296 end
    return n
  end
  local function journalClass(e)
    local n=cname(read(e,"GetClassName"))
    if n and n:match("^gameJournal[%w_]+$") then return n end
  end
  local function rootHash(j,e)
    local visited={}
    for i=1,8 do
      local h=journalHash(j,e); local c=journalClass(e)
      if not h or h==0 or visited[h] then return nil end
      if c=="gameJournalQuest" then return h,e end
      if c~="gameJournalQuestMapPin" and c~="gameJournalQuestObjective" and c~="gameJournalQuestPhase" then return nil end
      visited[h]=true;e=read(j,"GetParentEntry",e)
    end
  end
  local function rootData(j,entry,expected)
    local h=journalHash(j,entry)
    if not h or h==0 or (expected and h~=expected) or journalClass(entry)~="gameJournalQuest" then return nil end
    local ok,native=pcall(function() return j:GetEntryState(entry) end)
    local raw=ok and enum(native) or nil
    local name=ok and call(function() return token(native.value) end) or nil
    if name and not name:match("^[%a_][%w_]*$") then name=nil end
    local parent=journalHash(j,read(j,"GetParentEntry",entry))
    if parent==0 then parent=nil end
    return {present=true,entry_hash=h,entry_class="gameJournalQuest",parent_hash=parent,
      native_state=field(raw),native_state_name=name,consequence="UNKNOWN"}
  end
  function self:journal_unavailable()
    if not self.active then return end
    self.tracked_active_root=nil
    emit("TRACKED_ROOT_STATE","gameJournalManager.GetTrackedEntry","UNAVAILABLE","TRACKED_JOURNAL_UNAVAILABLE",{},"tracked_root")
  end
  function self:tracked_root(j,entry)
    if not self.active then return end
    local src="gameJournalManager.GetTrackedEntry"
    if self.dropped>0 then self.tracked_active_root=nil end
    local prior=self.tracked_active_root
    local _,root=rootHash(j,entry)
    local d=root and rootData(j,root) or nil
    if entry and not d then
      self.tracked_active_root=nil
      return unknown("TRACKED_ROOT_STATE",src,"JOURNAL_ROOT_UNRESOLVED",{present=true},"tracked_root")
    end
    if prior and (not d or d.entry_hash~=prior) then
      local old=rootData(j,read(j,"GetEntry",prior),prior)
      if old and old.native_state.availability=="OBSERVED" then
        old.prior_active=true
        emit("ROOT_JOURNAL_READBACK","gameJournalManager.GetEntryState","OBSERVED",nil,old)
      else
        unknown("ROOT_JOURNAL_READBACK","gameJournalManager.GetEntryState","JOURNAL_ROOT_READBACK_UNRESOLVED",
          {entry_hash=prior,prior_active=true,consequence="UNKNOWN"})
      end
    end
    self.tracked_active_root=nil
    if not entry then return emit("TRACKED_ROOT_STATE",src,"ABSENT",nil,{present=false},"tracked_root") end
    d.prior_active=prior==d.entry_hash
    if d.native_state.availability~="OBSERVED" then
      return unknown("TRACKED_ROOT_STATE",src,"JOURNAL_ROOT_STATE_UNRESOLVED",d,"tracked_root")
    end
    local seq=emit("TRACKED_ROOT_STATE",src,"OBSERVED",nil,d,"tracked_root")
    -- The active raw value was observed historically. Terminal semantics are
    -- intentionally left to the reviewed Core mapping. Keep a baseline only
    -- if the corresponding observation was emitted or previously established.
    if d.native_state.value==2 and (seq or prior==d.entry_hash) then self.tracked_active_root=d.entry_hash end
  end
  local function marker(m,id)
    return {mappin_id=id,present=true,entity_id=nativeId(read(m,"GetEntityID")),
      active=field(rb(m,"IsActive")),visible=field(rb(m,"IsVisible")),visited=field(rb(m,"IsVisited")),
      quest=field(rb(m,"IsQuestMappin")),quest_entity=field(rb(m,"IsQuestEntityMappin")),
      quest_npc=field(rb(m,"IsQuestNPCMappin")),phase_raw=field(enum(read(m,"GetPhase"))),
      variant_raw=field(enum(read(m,"GetVariant")))}
  end
  local function selectedMarker(controller,_,entryController)
    local src="gameuiWorldMapMenuGameController.OnSelectedMappinChanged"
    if not entryController then return emit("SELECTED_MAPPIN",src,"ABSENT",nil,{present=false},"selected_map") end
    local m=read(entryController,"GetMappin") or call(function() return entryController.mappin end)
    local id=call(function() return decimal(m:GetNewMappinID().value) end)
    if not id or id=="0" then return unknown("SELECTED_MAPPIN",src,"MAPPIN_IDENTITY_UNRESOLVED",{present=true},"selected_map") end
    local d=marker(m,id); local j=call(function() return Game.GetJournalManager() end)
    local entry=read(controller,"GetMappinJournalEntry",m)
    d.entry_hash=journalHash(j,entry);d.entry_class=journalClass(entry)
    if d.quest.value==true and (d.quest_entity.value==true or d.quest_npc.value==true) then
      local root=rootHash(j,entry)
      local native=read(m,"GetEntityID");local id2=nativeId(native)
      local e=call(function() return Game.FindEntityByID(native) end)
      local npc=e and eid(e)==id2 and rb(e,"IsNPC") or nil
      if e and eid(e)==id2 and rb(e,"IsNPC")==false then npc=false end
      d.quest_root_hash=root;d.is_npc=field(npc)
      local ok=root and id2 and id2~="0" and d.entry_hash and d.entry_hash~=0 and
        (d.quest_npc.value==true or npc==true) and (not e or (eid(e)==id2 and npc==true))
      d.relation_scope="NATIVE_NPC_MAPPIN_JOURNAL"
      d.relation_availability=ok and "OBSERVED" or "UNKNOWN"
      if not ok then return unknown("SELECTED_MAPPIN",src,"NPC_QUEST_LINK_UNRESOLVED",d,"selected_map") end
    end
    emit("SELECTED_MAPPIN",src,"OBSERVED",nil,d,"selected_map")
  end
  local function targetInteraction(obj,event,src,playerOnly)
    if playerOnly and playerIs(obj)~=true then return end
    local d={entity_id=eid(obj),action_type=field(call(function() return enum(event.actionType) end)),
      choice_record=call(function() return record(event.choice.choiceMetaData.tweakDBID) end),
      choice_flags=field(call(function() return int(event.choice.choiceMetaData.type.properties,0,4294967295) end)),
      actor_is_player=playerOnly and true or nil,consequence="UNKNOWN"}
    local ok=d.entity_id and d.entity_id~="0" and (d.action_type.availability=="OBSERVED" or d.choice_record or d.choice_flags.availability=="OBSERVED")
    emit("INTERACTION_WITNESS",src,ok and "OBSERVED" or "UNKNOWN",not ok and "INTERACTION_PARTIAL" or nil,d)
  end
  local function shard(obj)
    local src="ShardCaseContainer.OnShardCaseAnimationEnded"
    local d={entity_id=eid(obj),record=call(function() return record(obj.itemTDBID) end),
      visited=field(rb(obj,"IsShardRead")),consequence="UNKNOWN"}
    local ok=d.entity_id and d.entity_id~="0" and d.record and d.visited.availability=="OBSERVED"
    emit("SHARD_STATE",src,ok and "OBSERVED" or "UNKNOWN",not ok and "SHARD_READBACK_PARTIAL" or nil,d)
  end
  local function relic(sys,request)
    local src="RelicPerkSystem.OnSetPerkDeviceAsUsedRequest"
    local id=call(function() return nativeId(request.ownerID) end)
    local list=call(function() return sys.registeredPerkDevices end)
    local match
    if type(list)=="table" and id and id~="0" then
      for i=1,math.min(#list,128) do
        if nativeId(read(list[i],"GetOwnerID"))==id then match=list[i];break end
      end
    end
    local used=rb(match,"IsUsed")
    emit("RELIC_DEVICE_WITNESS",src,used~=nil and "OBSERVED" or "UNKNOWN",used==nil and "RELIC_DEVICE_UNRESOLVED" or nil,
      {entity_id=id,used=field(used),consequence="UNKNOWN"})
  end
  local function life(obj,kind,src)
    if playerIs(obj)~=true then return end
    local v=rb(obj,"IsDead")
    emit(kind,src,v~=nil and "OBSERVED" or "UNKNOWN",v==nil and "LIFE_READBACK_UNRESOLVED" or nil,{is_dead=field(v),consequence="UNKNOWN"})
  end
  local function effect(obj,event,applied,src)
    if playerIs(obj)~=true then return end
    local r=call(function() return event.staticData end)
    local t=read(r,"StatusEffectType") or read(r,"StatusEffectTypeHandle")
    local typ=enum(read(t,"Type"))
    local stack=call(function() return int(event.stackCount,0,1000000) end)
    emit("STATUS_EFFECT_WITNESS",src,typ~=nil and "OBSERVED" or "UNKNOWN",typ==nil and "EFFECT_TYPE_UNRESOLVED" or nil,
      {type_raw=field(typ),record=record(read(r,"GetID")),stack_count=field(stack),applied=applied})
  end
  local function fastTravel(_,request)
    local src="FastTravelSystem.OnPerformFastTravelRequest"
    if playerIs(call(function() return request.player end))~=true then return end
    local r=call(function() return record(request.pointData:GetPointRecord()) end)
    emit("FAST_TRAVEL_REQUEST",src,r and "OBSERVED" or "UNKNOWN",not r and "TRAVEL_POINT_UNRESOLVED" or nil,{point_record=r,consequence="UNKNOWN"})
  end
  local function dialogueHubs(_,v)
    local src="InteractionUIBase.OnDialogsData"
    local hubs=call(function() return FromVariant(v).choiceHubs end)
    if type(hubs)~="table" then hubs=call(function() return v.choiceHubs end) end
    if type(hubs)~="table" then return emit("DIALOGUE_HUBS",src,"UNAVAILABLE","DIALOGUE_OPTIONS_UNAVAILABLE",{},"dialogue_hubs") end
    local d={source_count=#hubs,complete=#hubs<=8,hubs={}}
    for i=1,math.min(#hubs,8) do
      local h=hubs[i];local id=call(function() return int(h.id,-2147483648,2147483647) end)
      local list=call(function() return h.choices end)
      if id==nil or type(list)~="table" then d.complete=false
      else
        local row={hub_id=id,source_count=#list,complete=#list<=16,options={}}
        for j=1,math.min(#list,16) do
          local flags=call(function() return int(list[j].type.properties,0,4294967295) end)
          row.options[#row.options+1]={index=j-1,choice_flags=field(flags)}
          if flags==nil then row.complete=false end
        end
        d.complete=d.complete and row.complete;d.hubs[#d.hubs+1]=row
      end
    end
    emit("DIALOGUE_HUBS",src,d.complete and "OBSERVED" or "UNKNOWN",not d.complete and "DIALOGUE_OPTIONS_PARTIAL" or nil,d,"dialogue_hubs")
  end
  local function clueData(controller)
    local src="BraindanceGameController.OnClueDataUpdated"
    local list=call(function() return controller.clueArray end)
    if type(list)~="table" then return emit("BRAINDANCE_CLUES",src,"UNAVAILABLE","CLUES_UNAVAILABLE",{},"clues") end
    local d={source_count=#list,read_count=0,complete=#list<=64,counts={}}
    for i=1,math.min(#list,64) do
      local n=enum(read(list[i],"GetBraindanceClueState")) or call(function() return enum(list[i].state) end)
      if n==nil then d.complete=false else
        d.read_count=d.read_count+1;local k=tostring(n);d.counts[k]=(d.counts[k] or 0)+1
      end
    end
    emit("BRAINDANCE_CLUES",src,d.complete and "OBSERVED" or "UNKNOWN",not d.complete and "CLUES_PARTIAL" or nil,d,"clues")
  end
  local function rawDecimal(v)
    if type(v)=="number" and v==v and v>=0 and v<=100000 then return math.floor(v*10)/10 end
  end
  local function popup(entry,itemId,encrypted,source)
    local j=call(function() return Game.GetJournalManager() end)
    local ident=equipment and equipment.identity(itemId) or {}
    local d={entry_hash=journalHash(j,entry),entry_class=journalClass(entry),
      item_id=ident.item_id,record=(ident.record_id or ident.record_ref) and {record_id=ident.record_id,record_ref=ident.record_ref} or nil,
      encrypted=field(boolean(encrypted)),consequence="UNKNOWN"}
    local ok=d.item_id and d.record and d.entry_hash~=nil
    emit("SHARD_POPUP",source,ok and "OBSERVED" or "UNKNOWN",not ok and "SHARD_POPUP_PARTIAL" or nil,d)
  end
  local function journalVisit(j,entry,v)
    local src="gameJournalManager.SetEntryVisited"
    local h=journalHash(j,entry);local req=boolean(v);local actual=boolean(read(j,"IsEntryVisited",entry))
    local ok=h~=nil and req~=nil and actual~=nil
    emit("JOURNAL_VISIT",src,ok and "OBSERVED" or "UNKNOWN",not ok and "JOURNAL_VISIT_PARTIAL" or nil,
      {entry_hash=h,entry_class=journalClass(entry),requested=field(req),actual=field(actual),consequence="UNKNOWN"})
  end
  function self:register()
    if self.registered or self.terminal then return end
    self.registered=true
    local function hook(c,m,f)
      local src=c.."."..m
      local ok=pcall(function() ObserveAfter(c,m,function(...)
        if not self.active then return end
        if self.remaining<=0 then self.dropped=self.dropped+1;return end
        if not pcall(f,...) then unknown("SOURCE_GAP",src,"CALLBACK_READ_ERROR",{},"gap:"..src) end
      end) end)
      if not ok then self.registration_gaps[#self.registration_gaps+1]=src end
    end
    hook("gameuiScannerGameController","OnScannedObjectChanged",scanned)
    hook("gameuiScannerGameController","OnStateChanged",function(_,v) observedValue("SCANNER_STATE","gameuiScannerGameController.OnStateChanged",variant(v)) end)
    hook("scannerDetailsGameController","OnScannedObjectTypeChanged",function(_,v) observedValue("SCANNED_TYPE","scannerDetailsGameController.OnScannedObjectTypeChanged",enum(v)) end)
    hook("QuickhacksListGameController","OnQuickhackStarted",options)
    hook("QuickhacksListGameController","OnItemSelected",function(_,v) observedValue("QUICKHACK_SELECTED","QuickhacksListGameController.OnItemSelected",int(v,-1,1024)) end)
    hook("QuickhacksListGameController","ApplyQuickhackSelection",request)
    hook("ScriptableDeviceAction","CompleteAction",complete)
    hook("PreventionSystem","OnPlayerChoice",choice)
    hook("InteractionUIBase","OnInteractionData",prompt)
    hook("InteractionUIBase","OnDialogsData",dialogueHubs)
    hook("InteractionUIBase","OnDialogsSelectIndex",function(_,v) observedValue("DIALOGUE_SELECTED_INDEX","InteractionUIBase.OnDialogsSelectIndex",int(v,-1,1024)) end)
    hook("BraindanceGameController","OnProgressUpdated",function(_,v) observedValue("BRAINDANCE_PROGRESS_RAW","BraindanceGameController.OnProgressUpdated",rawDecimal(v)) end)
    hook("BraindanceGameController","OnSectionTimeUpdated",function(_,v) observedValue("BRAINDANCE_TIME_RAW","BraindanceGameController.OnSectionTimeUpdated",rawDecimal(v)) end)
    hook("BraindanceGameController","OnClueDataUpdated",clueData)
    hook("ShardCollectedInventoryCallback","OpenShardPopup",function(_,entry,id,crypted) popup(entry,id,crypted,"ShardCollectedInventoryCallback.OpenShardPopup") end)
    hook("gameuiPopupsManager","OnShardRead",function(_,e) popup(call(function()return e.entry end),call(function()return e.itemID end),nil,"gameuiPopupsManager.OnShardRead") end)
    hook("gameJournalManager","SetEntryVisited",journalVisit)
    hook("gameJournalManager","ChangeEntryStateByHash",journal)
    hook("gameuiWorldMapMenuGameController","OnSelectedMappinChanged",selectedMarker)
    hook("InteractiveDevice","OnInteractionUsed",function(o,e) targetInteraction(o,e,"InteractiveDevice.OnInteractionUsed") end)
    hook("ScriptedPuppet","OnInteraction",function(o,e) targetInteraction(o,e,"ScriptedPuppet.OnInteraction") end)
    hook("gameLootContainerBase","OnInteraction",function(o,e) targetInteraction(o,e,"gameLootContainerBase.OnInteraction") end)
    hook("PlayerPuppet","OnInteraction",function(o,e) targetInteraction(o,e,"PlayerPuppet.OnInteraction",true) end)
    hook("ShardCaseContainer","OnShardCaseAnimationEnded",shard)
    hook("RelicPerkSystem","OnSetPerkDeviceAsUsedRequest",relic)
    hook("TarotMainGameController","OnJournalReady",function(_,h,_,_,change)
      local hash=int(h,0,4294967295);local c=enum(change)
      local ok=hash~=nil and c~=nil
      emit("TAROT_WITNESS","TarotMainGameController.OnJournalReady",ok and "OBSERVED" or "UNKNOWN",
        not ok and "TAROT_READBACK_PARTIAL" or nil,{entry_hash=hash,change_type=field(c),consequence="UNKNOWN"})
    end)
    hook("PlayerPuppet","OnDeath",function(o) life(o,"PLAYER_DEATH","PlayerPuppet.OnDeath") end)
    hook("PlayerPuppet","OnResurrected",function(o) life(o,"PLAYER_RESURRECT","PlayerPuppet.OnResurrected") end)
    hook("PlayerPuppet","OnStatusEffectApplied",function(o,e) effect(o,e,true,"PlayerPuppet.OnStatusEffectApplied") end)
    hook("PlayerPuppet","OnStatusEffectRemoved",function(o,e) effect(o,e,false,"PlayerPuppet.OnStatusEffectRemoved") end)
    hook("FastTravelSystem","OnPerformFastTravelRequest",fastTravel)
    hook("FastTravelSystem","OnLoadingScreenFinished",function(_,v) observedValue("FAST_TRAVEL_LOAD","FastTravelSystem.OnLoadingScreenFinished",boolean(v)) end)
    hook("BraindanceGameController","OnIsFPPUpdated",function(_,v) observedValue("BRAINDANCE_FPP","BraindanceGameController.OnIsFPPUpdated",boolean(v)) end)
    hook("BraindanceGameController","OnUnInitialize",function() observedValue("BRAINDANCE_END","BraindanceGameController.OnUnInitialize",true) end)

    for _,entry in ipairs({{"OnIsActiveUpdated","BRAINDANCE_ACTIVE",boolean},{"OnVisionModeUpdated","BRAINDANCE_LAYER",enum},
      {"OnPlaybackDirectionUpdated","BRAINDANCE_DIRECTION",variant},{"OnPlaybackSpeedUpdated","BRAINDANCE_SPEED",variant}}) do
      local method,kind,decode=entry[1],entry[2],entry[3]
      hook("BraindanceGameController",method,function(_,v) observedValue(kind,"BraindanceGameController."..method,decode(v)) end)
    end
  end
  local function equipmentPoll(player)
    if not equipment then return emit("EQUIPMENT_AREA","EquipmentSystem.GetEquipArea","UNAVAILABLE","READER_UNAVAILABLE",{},"equip_missing") end
    if self.work then
      local w=self.work;local row=w.slots[self.slot]
      if row then
        self.slot=self.slot+1
        if row.occupied==true and row.identity and row.status=="OBSERVED" then
          local d=equipment.read_equipped_item(player,w.area,row.index,row.identity)
          local status=d.status=="OBSERVED" and "OBSERVED" or (d.status=="UNAVAILABLE" and "UNAVAILABLE" or "UNKNOWN")
          emit("EQUIPMENT_ITEM","TransactionSystem.GetItemData",status,status~="OBSERVED" and "ITEM_READ_PARTIAL" or nil,
            {area=w.area,index=row.index,readback=d},"item:"..w.area..":"..row.index)
        end
        return
      end
      self.work=nil
    end
    local name=areas[self.area];self.area=self.area%#areas+1
    local a=equipment.read_area(player,name)
    local status=a.status=="OBSERVED" and "OBSERVED" or (a.status=="UNAVAILABLE" and "UNAVAILABLE" or "UNKNOWN")
    emit("EQUIPMENT_AREA","EquipmentSystem.GetEquipArea",status,status~="OBSERVED" and "AREA_READ_PARTIAL" or nil,a,"area:"..name)
    if a.complete and #a.slots>0 then self.work=a;self.slot=1 end
  end
  local function statusPoll(player)
    local sys=call(function() return Game.GetStatusEffectSystem() end)
    local a,b=read(sys,"GetAppliedEffects",read(player,"GetEntityID"))
    local list=type(a)=="table" and a or (a~=false and type(b)=="table" and b or nil)
    local d={effects={},complete=false}
    if not list then return emit("STATUS_EFFECTS","gameStatusEffectSystem.GetAppliedEffects","UNAVAILABLE","EFFECT_SOURCE_UNAVAILABLE",d,"effects") end
    d.source_count=#list;d.complete=#list<=32
    for i=1,math.min(#list,32) do
      local r=read(list[i],"GetRecord")
      local t=read(r,"StatusEffectType") or read(r,"StatusEffectTypeHandle")
      local typ=enum(read(t,"Type"))
      local id=record(read(r,"GetID"))
      if typ==nil or not id then d.complete=false end
      d.effects[#d.effects+1]={record=id,type_raw=field(typ)}
    end
    emit("STATUS_EFFECTS","gameStatusEffectSystem.GetAppliedEffects",d.complete and "OBSERVED" or "UNKNOWN",
      not d.complete and "EFFECT_READ_PARTIAL" or nil,d,"effects")
  end
  local function police()
    local sys=call(function() return Game.GetScriptableSystemsContainer():Get("PreventionSystem") end)
    local d={heat=field(int(read(sys,"GetHeatStageAsInt"),0,10000)),star_state=field(enum(read(sys,"GetStarState"))),
      chasing=field(rb(sys,"IsChasingPlayer"))}
    local ok=d.heat.availability=="OBSERVED" or d.star_state.availability=="OBSERVED" or d.chasing.availability=="OBSERVED"
    emit("POLICE_PHASE","PreventionSystem",ok and "OBSERVED" or "UNAVAILABLE",not ok and "POLICE_SOURCE_UNAVAILABLE" or nil,d,"police")
  end
  local function mapPoll()
    local src="gamemappinsMappinSystem.GetManuallyTrackedMappinID"
    local sys=call(function() return Game.GetMappinSystem() end)
    local native=read(sys,"GetManuallyTrackedMappinID")
    local id=call(function() return decimal(native.value) end)
    if not id then return emit("MANUAL_MAPPIN",src,"UNAVAILABLE","MAPPIN_SOURCE_UNAVAILABLE",{},"manual_map") end
    if id=="0" then return emit("MANUAL_MAPPIN",src,"ABSENT",nil,{present=false},"manual_map") end
    local m=read(sys,"GetMappin",native)
    if not m then return unknown("MANUAL_MAPPIN",src,"MAPPIN_NOT_RESOLVED",{present=true,mappin_id=id},"manual_map") end
    emit("MANUAL_MAPPIN",src,"OBSERVED",nil,marker(m,id),"manual_map")
  end
  local function proximityPoll(player)
    local src="gametargetingTargetingSystem.GetTargetParts"
    local started=os.clock()
    local a,b=call(function()
      local q=TSQ_ALL();q.testedSet=gameTargetingSet.Complete;q.maxDistance=10
      q.filterObjectByDistance=true;q.ignoreInstigator=true;q.includeSecondaryTargets=false
      if enum(q.testedSet)~=3 or q.maxDistance~=10 or q.filterObjectByDistance~=true or q.ignoreInstigator~=true then return nil end
      return Game.GetTargetingSystem():GetTargetParts(player,q)
    end)
    local parts=type(a)=="table" and a or (a~=false and type(b)=="table" and b or nil)
    local d={radius_m=10,tested_set=3,complete_world=false,complete=false,entities={}}
    if not parts then return emit("PROXIMITY",src,"UNAVAILABLE","PROXIMITY_SOURCE_UNAVAILABLE",d,"proximity") end
    d.source_count=#parts
    if #parts>128 or os.clock()-started>0.015 then
      self.proximityPaused=true
      return unknown("PROXIMITY",src,"PROXIMITY_BUDGET_STOP",d,"proximity")
    end
    local seen={};d.complete=#parts<=64
    for i=1,math.min(#parts,64) do
      if os.clock()-started>0.015 then d.complete=false;self.proximityPaused=true;break end
      local obj=read(read(parts[i],"GetComponent"),"GetEntity")
      local id=eid(obj)
      if not id or id=="0" then d.complete=false
      elseif not seen[id] then
        seen[id]=true
        if #d.entities>=16 then d.complete=false;break end
        local p1,p2=read(player,"GetWorldPosition"),read(obj,"GetWorldPosition")
        local dist=call(function()
          local dx,dy,dz=p1.x-p2.x,p1.y-p2.y,p1.z-p2.z
          local x=math.sqrt(dx*dx+dy*dy+dz*dz)
          if x==x and x>=0 and x<=10.5 then return math.floor(x*10)/10 end
        end)
        if dist then d.entities[#d.entities+1]={entity_id=id,distance_m=dist,
          record=record(read(obj,"GetRecordID")),class_name=cname(read(obj,"GetClassName")),
          is_device=field(rb(obj,"IsDevice")),is_npc=field(rb(obj,"IsNPC")),is_vehicle=field(rb(obj,"IsVehicle"))}
        else d.complete=false end
      end
    end
    table.sort(d.entities,function(x,y) return x.entity_id<y.entity_id end)
    emit("PROXIMITY",src,d.complete and "OBSERVED" or "UNKNOWN",not d.complete and "PROXIMITY_PARTIAL" or nil,d,"proximity")
  end
  local function progressionPoll(player)
    local src="PlayerDevelopmentSystem.GetDevelopmentData"
    local sys=call(function() return Game.GetScriptableSystemsContainer():Get("PlayerDevelopmentSystem") end)
    local attrs=call(function() return read(sys,"GetDevelopmentData",player).attributesData end)
    -- In v0.3 "complete" describes modern perks, not every progression field.
    -- Attribute coverage is independent; points/skills retain per-field status.
    local d={attributes={},points={},skills={},perks={},complete=false,
      perks_complete=false,attributes_complete=false}
    local raw=read(sys,"GetAttributes",player)
    if type(raw)=="table" then
      d.attribute_source_count=#raw
      d.attributes_complete=#raw>0 and #raw<=16
      for i=1,math.min(#raw,16) do
        local a=raw[i]
        local row={type_raw=field(call(function() return enum(a.attributeName) end)),
          value=field(call(function() return int(a.value,0,1000) end))}
        d.attributes[#d.attributes+1]=row
        if row.type_raw.availability~="OBSERVED" or row.value.availability~="OBSERVED" then
          d.attributes_complete=false
        end
      end
    end
    for _,n in ipairs({"Attribute","Espionage","Primary","Secondary"}) do
      d.points[n]=field(call(function() return int(sys:GetDevPoints(player,gamedataDevelopmentPointType[n]),0,10000) end))
    end
    for _,n in ipairs({"CoolSkill","IntelligenceSkill","ReflexesSkill","StrengthSkill","TechnicalAbilitySkill"}) do
      d.skills[n]=field(call(function() return int(sys:GetProficiencyLevel(player,gamedataProficiencyType[n]),0,1000) end))
    end
    if type(attrs)~="table" then return unknown("PROGRESSION",src,"MODERN_PERK_SOURCE_UNAVAILABLE",d,"progression") end
    d.attribute_count=#attrs;d.source_count=0;d.complete=#attrs>0 and #attrs<=8
    local seen={}
    for i=1,math.min(#attrs,8) do
      local a=attrs[i];local t=call(function() return enum(a.type) end)
      local list=call(function() return a.unlockedPerks end)
      if type(list)~="table" or t==nil then d.complete=false
      else
        d.source_count=d.source_count+#list
        for j=1,math.min(#list,194) do
          -- CP2.5 modern perk enum has a bounded 194-value surface in the macro reader.
          -- Keep the existing byte/node budgets and explicit UNKNOWN beyond capacity.
          if #d.perks>=194 then d.complete=false;break end
          local k=call(function() return enum(list[j].type) end)
          local v=call(function() return int(list[j].currLevel,0,100) end)
          if k==nil or v==nil or seen[k] then d.complete=false
          else seen[k]=true;d.perks[#d.perks+1]={attribute_type=t,perk_type=k,level=v} end
        end
      end
    end
    d.complete=d.complete and #d.perks==d.source_count
    d.perks_complete=d.complete
    table.sort(d.perks,function(a,b) return a.perk_type<b.perk_type end)
    emit("PROGRESSION",src,d.complete and "OBSERVED" or "UNKNOWN",not d.complete and "PERKS_PARTIAL" or nil,d,"progression")
  end
  local function collectionPoll()
    local src="gameJournalManager.GetTarots"
    local j=call(function() return Game.GetJournalManager() end)
    local a,b=call(function()
      local f=gameJournalRequestStateFilter.new({inactive=false,active=true,succeeded=true,failed=false})
      return j:GetTarots(gameJournalRequestContext.new({stateFilter=f}))
    end)
    local list=type(a)=="table" and a or (a~=false and type(b)=="table" and b or nil)
    local d={entries={},complete=false}
    if not list then return emit("TAROT_COLLECTION",src,"UNAVAILABLE","COLLECTION_SOURCE_UNAVAILABLE",d,"tarots") end
    d.source_count=#list;d.complete=#list<=64
    for i=1,math.min(#list,64) do
      local e=list[i];local h=journalHash(j,e);local s=enum(read(j,"GetEntryState",e))
      if h and s~=nil then d.entries[#d.entries+1]={entry_hash=h,state_raw=s,index=field(int(read(e,"GetIndex"),0,1024))}
      else d.complete=false end
    end
    table.sort(d.entries,function(x,y) return x.entry_hash<y.entry_hash end)
    emit("TAROT_COLLECTION",src,d.complete and "OBSERVED" or "UNKNOWN",not d.complete and "COLLECTION_PARTIAL" or nil,d,"tarots")
  end
  local function relicPoll()
    local src="RelicPerkSystem.registeredPerkDevices"
    local list=call(function() return Game.GetScriptableSystemsContainer():Get("RelicPerkSystem").registeredPerkDevices end)
    if type(list)~="table" then return emit("RELIC_PROGRESS",src,"UNAVAILABLE","COLLECTION_SOURCE_UNAVAILABLE",{},"relic") end
    local d={source_count=#list,read_count=0,used_count=0,complete=#list<=128}
    for i=1,math.min(#list,128) do
      local v=rb(list[i],"IsUsed")
      if v~=nil then d.read_count=d.read_count+1;if v then d.used_count=d.used_count+1 end else d.complete=false end
    end
    emit("RELIC_PROGRESS",src,d.complete and "OBSERVED" or "UNKNOWN",not d.complete and "COLLECTION_PARTIAL" or nil,d,"relic")
  end
  function self:vehicle(vehicle)
    if not self.active then return end
    local src="vehicleBaseObject.GetCurrentSpeed"
    if not vehicle then return emit("VEHICLE_NATIVE",src,"ABSENT",nil,{mounted=false},"vehicle") end
    local speed=read(vehicle,"GetCurrentSpeed")
    if type(speed)~="number" or speed~=speed or math.abs(speed)>10000 then speed=nil end
    local id=eid(vehicle)
    local d={mounted=true,entity_id=id,speed_native=field(speed and math.floor(speed*10)/10 or nil),driver=field(rb(vehicle,"IsPlayerDriver"))}
    local ok=id and id~="0" and speed~=nil
    emit("VEHICLE_NATIVE",src,ok and "OBSERVED" or "UNKNOWN",not ok and "VEHICLE_READBACK_PARTIAL" or nil,d,"vehicle")
  end
  function self:tick(dt,player)
    if not self.active or not player or type(dt)~="number" or dt~=dt or dt<=0 or dt==math.huge then return end
    if dt>60 then self:suspend("CLOCK_GAP");return end
    self.elapsed=self.elapsed+dt;self.acc=self.acc+dt
    if math.floor(self.elapsed)>self.period then
      self.period=math.floor(self.elapsed);self.remaining=24
      if self.dropped>0 then
        local n=self.dropped
        -- Replay revokes the same correlations on EVENTS_DROPPED. Never send
        -- an orphan readback or continue an invalidated stash snapshot.
        self.pending=nil;self.scan=nil;self.tracked_active_root=nil
        self.stash_work=nil;self.stash_last=nil;self.stash_due=self.elapsed+30
        self.last={};self.work=nil
        self.dropped=0
        local barrier=emit("SOURCE_GAP","Producer.budget","UNKNOWN","EVENTS_DROPPED",{count=n})
        if not barrier then
          self.dropped=self.dropped+n
          return
        end
        self.last_budget_barrier_sequence=barrier
      end
    end
    if self.pending and self.elapsed>=self.pending.due then
      local p=self.pending;self.pending=nil
      if self.elapsed>p.deadline then
        unknown("DEVICE_READBACK","ScriptableDeviceAction.CompleteAction","READBACK_EXPIRED",{entity_id=p.id,completion_sequence=p.seq,consequence="UNKNOWN"})
      else
        local s,r,d=M.read_entity(p.native)
        d.completion_sequence=p.seq;d.consequence="UNKNOWN"
        if d.entity_id~=p.id then s="UNKNOWN";r="IDENTITY_MISMATCH";d={entity_id=p.id,completion_sequence=p.seq,consequence="UNKNOWN"}
        elseif p.baseline and d.device_state then d.previous_scan_state=p.baseline end
        if s=="OBSERVED" and not d.device_state then s="UNKNOWN";r="DEVICE_STATE_UNRESOLVED" end
        emit("DEVICE_READBACK","ScriptableDeviceAction.CompleteAction",s,r,d)
      end
    end
    if self.acc<0.5 then return end
    self.acc=0
    if self.remaining<=0 then self.dropped=self.dropped+1;return end
    if not pcall(flushRefs) then unknown("SOURCE_GAP","TransactionSystem.GetItemList","INVENTORY_REFERENCE_GAP",{count=1}) end
    if not pcall(stashStep) then
      self.stash_work=nil;self.stash_last=nil;self.stash_due=self.elapsed+30
      unknown("SOURCE_GAP","TransactionSystem.GetItemList","STASH_ROW_UNRESOLVED",{count=1})
    end
    local step=self.round;local ok
    if self.equipTurn then ok=pcall(equipmentPoll,player);self.equipTurn=false
    else
      self.equipTurn=true;self.round=self.round%7+1
      local jobs={statusPoll,police,mapPoll,progressionPoll,collectionPoll,relicPoll,proximityPoll}
      if step==7 and self.proximityPaused then return end
      ok=pcall(jobs[step],player)
    end
    if not ok then unknown("SOURCE_GAP","Producer.scheduler","POLL_READ_ERROR",{step=step},"poll:"..step) end
  end
  return self
end
return M
