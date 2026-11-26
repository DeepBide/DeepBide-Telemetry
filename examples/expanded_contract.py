# MIT: Copyright (c) 2026 DeepBide.
# Extracted from the original native contract/replay and host.
# External cache, product projection and recommendation code excluded.
from __future__ import annotations

from collections import OrderedDict
import json
import math
import re
import uuid

CONTRACT = "cp25-native-candidate/0.3"
STATUSES = {"OBSERVED", "UNKNOWN", "UNAVAILABLE", "ABSENT"}
TOKEN = re.compile(r"[A-Za-z0-9_.:-]{1,180}\Z")
DECIMAL = re.compile(r"(?:0|[1-9][0-9]{0,19})\Z")
REF = re.compile(r"TDBID:[0-9A-F]{8}:[0-9A-F]{2}\Z")
MAX_ID = 2**64-1
MAX_BYTES = 32768
MAX_DEPTH = 12
MAX_NODES = 4096
SCANNER = "gameuiScannerGameController."
QUICK = "QuickhacksListGameController."
BD = "BraindanceGameController."
MAP = "gameuiWorldMapMenuGameController.OnSelectedMappinChanged"
COMPLETE = "ScriptableDeviceAction.CompleteAction"
SOURCES = {
    "SESSION": {"Producer.lifecycle"},
    "SCANNED_TARGET": {SCANNER+"OnScannedObjectChanged"},
    "SCANNER_STATE": {SCANNER+"OnStateChanged"},
    "SCANNED_TYPE": {"scannerDetailsGameController.OnScannedObjectTypeChanged"},
    "QUICKHACK_OPTIONS": {QUICK+"OnQuickhackStarted"},
    "QUICKHACK_SELECTED": {QUICK+"OnItemSelected"},
    "QUICKHACK_REQUEST": {QUICK+"ApplyQuickhackSelection"},
    "DEVICE_COMPLETION": {COMPLETE}, "DEVICE_READBACK": {COMPLETE},
    "DIALOGUE_ATTEMPT": {"PreventionSystem.OnPlayerChoice"},
    "INTERACTION_CONTEXT": {"InteractionUIBase.OnInteractionData"},
    "INTERACTION_WITNESS": {"InteractiveDevice.OnInteractionUsed","ScriptedPuppet.OnInteraction",
                             "gameLootContainerBase.OnInteraction","PlayerPuppet.OnInteraction"},
    "JOURNAL_WITNESS": {"gameJournalManager.ChangeEntryStateByHash"},
    "SELECTED_MAPPIN": {MAP},
    "MANUAL_MAPPIN": {"gamemappinsMappinSystem.GetManuallyTrackedMappinID"},
    "SHARD_STATE": {"ShardCaseContainer.OnShardCaseAnimationEnded"},
    "RELIC_DEVICE_WITNESS": {"RelicPerkSystem.OnSetPerkDeviceAsUsedRequest"},
    "RELIC_PROGRESS": {"RelicPerkSystem.registeredPerkDevices"},
    "TAROT_WITNESS": {"TarotMainGameController.OnJournalReady"},
    "TAROT_COLLECTION": {"gameJournalManager.GetTarots"},
    "PLAYER_DEATH": {"PlayerPuppet.OnDeath"}, "PLAYER_RESURRECT": {"PlayerPuppet.OnResurrected"},
    "STATUS_EFFECT_WITNESS": {"PlayerPuppet.OnStatusEffectApplied","PlayerPuppet.OnStatusEffectRemoved"},
    "STATUS_EFFECTS": {"gameStatusEffectSystem.GetAppliedEffects"},
    "FAST_TRAVEL_REQUEST": {"FastTravelSystem.OnPerformFastTravelRequest"},
    "FAST_TRAVEL_LOAD": {"FastTravelSystem.OnLoadingScreenFinished"},
    "BRAINDANCE_ACTIVE": {BD+"OnIsActiveUpdated"}, "BRAINDANCE_LAYER": {BD+"OnVisionModeUpdated"},
    "BRAINDANCE_DIRECTION": {BD+"OnPlaybackDirectionUpdated"}, "BRAINDANCE_SPEED": {BD+"OnPlaybackSpeedUpdated"},
    "BRAINDANCE_FPP": {BD+"OnIsFPPUpdated"}, "BRAINDANCE_END": {BD+"OnUnInitialize"},
    "EQUIPMENT_AREA": {"EquipmentSystem.GetEquipArea"}, "EQUIPMENT_ITEM": {"TransactionSystem.GetItemData"},
    "POLICE_PHASE": {"PreventionSystem"}, "PROXIMITY": {"gametargetingTargetingSystem.GetTargetParts"},
    "PROGRESSION": {"PlayerDevelopmentSystem.GetDevelopmentData"},
    "VEHICLE_NATIVE": {"vehicleBaseObject.GetCurrentSpeed"},
    "STATIC_RECORD_REFERENCES": {"TransactionSystem.GetItemList"},
    "STASH_SNAPSHOT": {"TransactionSystem.GetItemList"},
    "STASH_SNAPSHOT_CHUNK": {"TransactionSystem.GetItemList"},
    "DIALOGUE_HUBS":{"InteractionUIBase.OnDialogsData"},
    "DIALOGUE_SELECTED_INDEX":{"InteractionUIBase.OnDialogsSelectIndex"},
    "BRAINDANCE_PROGRESS_RAW":{BD+"OnProgressUpdated"},
    "BRAINDANCE_TIME_RAW":{BD+"OnSectionTimeUpdated"},
    "BRAINDANCE_CLUES":{BD+"OnClueDataUpdated"},
    "SHARD_POPUP":{"ShardCollectedInventoryCallback.OpenShardPopup","gameuiPopupsManager.OnShardRead"},
    "JOURNAL_VISIT":{"gameJournalManager.SetEntryVisited"},
    "TRACKED_ROOT_STATE":{"gameJournalManager.GetTrackedEntry"},
    "ROOT_JOURNAL_READBACK":{"gameJournalManager.GetEntryState"},
}
SOURCES["SOURCE_GAP"] = set().union(*SOURCES.values(), {"Producer.budget","Producer.scheduler"})

ENTITY_KEYS = {"present","entity_id","record","class_name","is_device","is_npc","is_vehicle","classification",
               "record_availability","semantic_status","device_state","device_state_availability"}
ACTION_KEYS = {"action_record","action_name","choice_record","native_completed","quickhack","consequence"}
MARKER_KEYS = {"mappin_id","present","entity_id","active","visible","visited","quest","quest_entity","quest_npc",
               "phase_raw","variant_raw","entry_hash","entry_class","quest_root_hash","is_npc",
               "relation_scope","relation_availability"}
RAW_KEYS = {"raw","semantic_status"}
DATA_KEYS = {
    "SESSION":{"ready","reason","dropped_events"},
    "SCANNED_TARGET":ENTITY_KEYS,
    "DEVICE_READBACK":ENTITY_KEYS|{"completion_sequence","consequence","previous_scan_state"},
    "DEVICE_COMPLETION":ACTION_KEYS|{"entity_id"},
    "QUICKHACK_REQUEST":ACTION_KEYS|{"target_id"},
    "QUICKHACK_OPTIONS":{"target_id","source_count","complete","options"},
    "DIALOGUE_ATTEMPT":{"visualizer_type","index","native_success","choice_record","consequence"},
    "INTERACTION_CONTEXT":{"interactions_open","dialogs_open","looting_open"},
    "INTERACTION_WITNESS":{"entity_id","action_type","choice_record","choice_flags","actor_is_player","consequence"},
    "JOURNAL_WITNESS":{"entry_hash","requested","actual","consequence"},
    "SELECTED_MAPPIN":MARKER_KEYS,"MANUAL_MAPPIN":MARKER_KEYS,
    "SHARD_STATE":{"entity_id","record","visited","consequence"},
    "RELIC_DEVICE_WITNESS":{"entity_id","used","consequence"},
    "RELIC_PROGRESS":{"source_count","read_count","used_count","complete"},
    "TAROT_WITNESS":{"entry_hash","change_type","consequence"},
    "TAROT_COLLECTION":{"entries","complete","source_count"},
    "PLAYER_DEATH":{"is_dead","consequence"},"PLAYER_RESURRECT":{"is_dead","consequence"},
    "STATUS_EFFECT_WITNESS":{"type_raw","record","stack_count","applied"},
    "STATUS_EFFECTS":{"effects","complete","source_count"},
    "FAST_TRAVEL_REQUEST":{"point_record","consequence"},
    "EQUIPMENT_AREA":{"area","status","complete","slots","source_count"},
    "EQUIPMENT_ITEM":{"area","index","readback"},
    "POLICE_PHASE":{"heat","star_state","chasing"},
    "PROXIMITY":{"radius_m","tested_set","complete_world","complete","entities","source_count"},
    "PROGRESSION":{"attributes","points","skills","perks","complete","attribute_count","source_count",
                   "attributes_complete","attribute_source_count","perks_complete"},
    "VEHICLE_NATIVE":{"mounted","entity_id","speed_native","driver"},
    "SOURCE_GAP":{"count","step"},
    "STATIC_RECORD_REFERENCES":{"records"},
    "STASH_SNAPSHOT":{"snapshot_id","scope","complete","entry_count","source_count","excluded_count","truncated","change_count"},
    "STASH_SNAPSHOT_CHUNK":{"snapshot_id","start","rows","final"},
    "DIALOGUE_HUBS":{"source_count","complete","hubs"},
    "BRAINDANCE_CLUES":{"source_count","read_count","complete","counts"},
    "SHARD_POPUP":{"entry_hash","entry_class","item_id","record","encrypted","consequence"},
    "JOURNAL_VISIT":{"entry_hash","entry_class","requested","actual","consequence"},
    "TRACKED_ROOT_STATE":{"present","entry_hash","entry_class","parent_hash","native_state","native_state_name","prior_active","consequence"},
    "ROOT_JOURNAL_READBACK":{"present","entry_hash","entry_class","parent_hash","native_state","native_state_name","prior_active","consequence"},
}
for kind in SOURCES:
    DATA_KEYS.setdefault(kind, RAW_KEYS)

PRIVATE_KEYS = {"text","title","caption","name_localized","description","dialogue_text","journal_text",
                "user_id","run_id","save_id","save","path","file","world_position","position","coordinates"}
ID_KEYS = {"entity_id","target_id","item_id","mappin_id","requester_id"}
REASONS = {
    "IDENTITY_UNRESOLVED","ENTITY_NOT_RESOLVED","IDENTITY_MISMATCH","DEVICE_STATE_UNRESOLVED",
    "ENTITY_TYPE_UNRESOLVED","CLASSIFICATION_UNRESOLVED","RECORD_UNRESOLVED","OPTIONS_UNAVAILABLE","OPTIONS_PARTIAL",
    "REQUEST_IDENTITY_UNRESOLVED","EXECUTOR_UNRESOLVED","COMPLETION_PARTIAL","READBACK_SUPERSEDED",
    "NATIVE_VALUE_UNRESOLVED","VISUALIZER_UNRESOLVED","CHOICE_PARTIAL","PROMPT_UNAVAILABLE",
    "JOURNAL_READBACK_UNRESOLVED","MAPPIN_IDENTITY_UNRESOLVED","NPC_QUEST_LINK_UNRESOLVED",
    "INTERACTION_PARTIAL","SHARD_READBACK_PARTIAL","RELIC_DEVICE_UNRESOLVED","LIFE_READBACK_UNRESOLVED",
    "EFFECT_TYPE_UNRESOLVED","TRAVEL_POINT_UNRESOLVED","TAROT_READBACK_PARTIAL","READER_UNAVAILABLE",
    "ITEM_READ_PARTIAL","AREA_READ_PARTIAL","EFFECT_SOURCE_UNAVAILABLE","EFFECT_READ_PARTIAL",
    "POLICE_SOURCE_UNAVAILABLE","MAPPIN_SOURCE_UNAVAILABLE","MAPPIN_NOT_RESOLVED",
    "PROXIMITY_SOURCE_UNAVAILABLE","PROXIMITY_BUDGET_STOP","PROXIMITY_PARTIAL",
    "MODERN_PERK_SOURCE_UNAVAILABLE","PERKS_PARTIAL","COLLECTION_SOURCE_UNAVAILABLE",
    "COLLECTION_PARTIAL","VEHICLE_READBACK_PARTIAL","CALLBACK_READ_ERROR","HOOK_UNAVAILABLE",
    "POLL_READ_ERROR","EVENTS_DROPPED","READBACK_EXPIRED","SESSION_BOUNDARY",
    "INVENTORY_REFERENCE_GAP","STASH_ROW_UNRESOLVED","STASH_SOURCE_UNAVAILABLE",
    "STASH_ENTITY_UNAVAILABLE","STASH_IDENTITY_MISMATCH","STASH_LIST_UNAVAILABLE",
    "STASH_EMPTY_UNVERIFIED","STASH_PARTIAL","DIALOGUE_OPTIONS_UNAVAILABLE","DIALOGUE_OPTIONS_PARTIAL","CLUES_UNAVAILABLE","CLUES_PARTIAL","SHARD_POPUP_PARTIAL","JOURNAL_VISIT_PARTIAL",
    "TRACKED_JOURNAL_UNAVAILABLE","JOURNAL_ROOT_UNRESOLVED","JOURNAL_ROOT_STATE_UNRESOLVED","JOURNAL_ROOT_READBACK_UNRESOLVED",
}


def _require(condition, reason):
    if not condition:
        raise ValueError("CP25_CANDIDATE_"+reason)


def _integer(value, lower=0, upper=2**53-1):
    return type(value) is int and lower <= value <= upper


def _id(value):
    return isinstance(value,str) and bool(DECIMAL.fullmatch(value)) and int(value)<=MAX_ID


def _walk(value, key, depth, counter):
    counter[0]+=1
    _require(counter[0]<=MAX_NODES and depth<=MAX_DEPTH,"PAYLOAD_BUDGET")
    if key in ID_KEYS:
        _require(_id(value),"NATIVE_ID")
    if key in {"record_ref","slot_ref"}:
        _require(isinstance(value,str) and REF.fullmatch(value) is not None,"TDBID_REF")
    if key=="consequence":
        _require(value=="UNKNOWN","CONSEQUENCE_INFERRED")
    if isinstance(value,dict):
        _require(len(value)<=128,"MAPPING_BOUND")
        if "availability" in value:
            status=value["availability"]
            _require(isinstance(status,str) and status in STATUSES,"FIELD_STATUS")
            _require(("value" in value)==(status=="OBSERVED"),"FIELD_VALUE")
            _require(set(value)==({"availability","value"} if status=="OBSERVED" else {"availability"}),"FIELD_KEYS")
        for k,v in value.items():
            _require(isinstance(k,str) and bool(TOKEN.fullmatch(k)) and k.lower() not in PRIVATE_KEYS,"DATA_KEY")
            _walk(v,k,depth+1,counter)
    elif isinstance(value,list):
        # Only the top-level PROGRESSION perks list may exceed the generic cap.
        # Preserve all other list, byte, depth and node bounds.
        limit=194 if key=="perks" and depth==1 else 128
        _require(len(value)<=limit,"LIST_BOUND")
        for v in value:
            _walk(v,None,depth+1,counter)
    elif type(value) is bool:
        pass
    elif type(value) in (int,float):
        _require(abs(value)<=2**53-1 and math.isfinite(value),"NUMBER")
    elif isinstance(value,str):
        _require(bool(TOKEN.fullmatch(value)),"DATA_TOKEN")
    else:
        _require(False,"DATA_TYPE")


RECORD_NAME = re.compile(r"[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+\Z")


def _static_ref(ref):
    _require(isinstance(ref,dict) and bool(ref) and set(ref)<={"record_id","record_ref"},"STATIC_REF_KEYS")
    if "record_id" in ref:
        name=ref["record_id"]
        _require(isinstance(name,str) and len(name)<=180 and RECORD_NAME.fullmatch(name) is not None,"STATIC_RECORD_NAME")
    if "record_ref" in ref:
        v=ref["record_ref"]
        _require(isinstance(v,str) and REF.fullmatch(v) is not None and int(v[-2:],16)>0,"STATIC_RECORD_REF")
    if "record_id" in ref and "record_ref" in ref:
        v=ref["record_ref"]
        _require(tid(ref["record_id"])==(int(v[-2:],16)<<32|int(v[6:14],16)),"STATIC_REF_MISMATCH")


def _inventory_payload(kind,status,d):
    if kind=="STATIC_RECORD_REFERENCES":
        _require(status=="OBSERVED" and set(d)=={"records"} and isinstance(d["records"],list) and 1<=len(d["records"])<=32,"STATIC_BATCH")
        for ref in d["records"]:_static_ref(ref)
    elif kind=="STASH_SNAPSHOT":
        _require({"snapshot_id","scope","complete","entry_count","source_count","excluded_count"}<=set(d),"STASH_HEADER_KEYS")
        _require(d["scope"]=="stash" and _integer(d["snapshot_id"],1) and type(d["complete"]) is bool,"STASH_HEADER")
        _require(_integer(d["entry_count"],0,4096) and _integer(d["source_count"],0,1000000) and _integer(d["excluded_count"],0,1000000),"STASH_COUNTS")
        _require(d["entry_count"]+d["excluded_count"]==d["source_count"],"STASH_COUNT_MISMATCH")
        _require(type(d.get("truncated",False)) is bool and ("change_count" not in d or _integer(d["change_count"],0,8192)),"STASH_FLAGS")
        _require(d["complete"]==(status=="OBSERVED"),"STASH_COMPLETE_STATUS")
        if d["complete"]:
            _require(d["entry_count"]>0 and d["excluded_count"]==0 and not d.get("truncated",False),"STASH_COMPLETE_EMPTY_OR_PARTIAL")
        if status=="UNAVAILABLE":
            _require(d["entry_count"]==d["source_count"]==d["excluded_count"]==0,"STASH_UNAVAILABLE_COUNTS")
        _require(status in {"OBSERVED","UNKNOWN","UNAVAILABLE"},"STASH_STATUS")
    elif kind=="STASH_SNAPSHOT_CHUNK":
        _require(status=="OBSERVED" and set(d)=={"snapshot_id","start","rows","final"} and _integer(d["snapshot_id"],1) and _integer(d["start"],0,4095) and type(d["final"]) is bool,"STASH_CHUNK")
        rows=d["rows"]
        _require(isinstance(rows,list) and 1<=len(rows)<=48 and d["start"]+len(rows)<=4096,"STASH_CHUNK_BOUND")
        for row in rows:
            _require(isinstance(row,dict) and {"item_id","quantity","record_availability"}<=set(row)<={"item_id","quantity","record_availability","record_id","record_ref"},"STASH_ROW")
            _require(_id(row["item_id"]) and row["item_id"]!="0" and _integer(row["quantity"],1),"STASH_ROW_ID_QUANTITY")
            ref={k:row[k] for k in ("record_id","record_ref") if k in row}
            _require(row["record_availability"]==("OBSERVED" if ref else "UNKNOWN"),"STASH_RECORD_AVAILABILITY")
            if ref:_static_ref(ref)


def validate_candidate(row: dict) -> dict:
    _require(isinstance(row,dict),"ROW_TYPE")
    required={"contract","kind","source","generation","sequence","elapsed_ms","availability","data","producer_session"}
    _require(required<=set(row)<=required|{"reason"},"ENVELOPE_KEYS")
    _require(row["contract"]==CONTRACT,"CONTRACT")
    kind,source=row["kind"],row["source"]
    _require(isinstance(kind,str) and kind in SOURCES and isinstance(source,str) and source in SOURCES[kind],"SOURCE_KIND")
    for name,min_value in (("generation",1),("sequence",1),("elapsed_ms",0)):
        _require(_integer(row[name],min_value),"ORDER")
    try:
        _require(str(uuid.UUID(row["producer_session"]))==row["producer_session"],"PRODUCER_SESSION")
    except (ValueError,TypeError,AttributeError):
        raise ValueError("CP25_CANDIDATE_PRODUCER_SESSION") from None
    status=row["availability"]
    _require(isinstance(status,str) and status in STATUSES,"AVAILABILITY")
    reason=row.get("reason")
    _require((status in {"UNKNOWN","UNAVAILABLE"} and isinstance(reason,str) and reason in REASONS)
             or (status in {"OBSERVED","ABSENT"} and reason is None),"REASON")
    d=row["data"]
    # CET may encode an empty Lua table as []; normalize empty diagnostic payloads only.
    if d==[]:
        d={}
        row={**row,"data":d}
    _require(isinstance(d,dict) and set(d)<=DATA_KEYS[kind],"PAYLOAD_KEYS")
    if kind=="SESSION":
        _require(status=="OBSERVED" and type(d.get("ready")) is bool,"SESSION_SHAPE")
        _require("dropped_events" not in d or _integer(d["dropped_events"]),"SESSION_DROPPED_COUNT")
        if d["ready"]:
            _require("reason" not in d and d.get("dropped_events",0)==0,"SESSION_OPEN_SHAPE")
    elif kind=="SOURCE_GAP" and reason=="EVENTS_DROPPED":
        _require(status=="UNKNOWN" and _integer(d.get("count"),1),"GAP_DROPPED_COUNT")
    elif kind=="SOURCE_GAP" and reason=="INVENTORY_REFERENCE_GAP":
        _require(status=="UNKNOWN" and _integer(d.get("count"),1),"GAP_STATIC_REFERENCE_COUNT")
    elif DATA_KEYS[kind]==RAW_KEYS and status=="OBSERVED":
        raw=d.get("raw")
        if kind in {"BRAINDANCE_PROGRESS_RAW","BRAINDANCE_TIME_RAW"}:
            valid=type(raw) in (int,float) and abs(raw)<=2**53-1 and math.isfinite(raw)
        elif kind in {"FAST_TRAVEL_LOAD","BRAINDANCE_ACTIVE","BRAINDANCE_FPP","BRAINDANCE_END"}:
            valid=type(raw) is bool
        else:
            valid=_integer(raw,-2147483648,2147483647)
        _require(valid,"RAW_WITNESS")
        _require("semantic_status" not in d or d["semantic_status"]=="UNKNOWN","RAW_SEMANTICS")
    elif kind=="PROGRESSION":
        # In v0.3 the legacy complete bit covers perks, not the whole character.
        if "perks_complete" in d:
            _require(type(d["perks_complete"]) is bool and d["perks_complete"]==d.get("complete"),
                     "PERKS_COMPLETE_FLAG")
        if "attributes_complete" in d:
            _require(type(d["attributes_complete"]) is bool,"ATTRIBUTES_COMPLETE_FLAG")
            if d["attributes_complete"]:
                rows=d.get("attributes")
                _require(isinstance(rows,list) and _integer(d.get("attribute_source_count"),1,16)
                         and len(rows)==d["attribute_source_count"],"ATTRIBUTES_COMPLETE_COUNT")
                _require(all(isinstance(r,dict) and all(isinstance(r.get(k),dict)
                         and r[k].get("availability")=="OBSERVED" for k in ("type_raw","value"))
                         and _integer(r["type_raw"].get("value"),-2147483648,2147483647)
                         and _integer(r["value"].get("value"),0,1000)
                         for r in rows),"ATTRIBUTES_COMPLETE_WITNESS")
        if status=="OBSERVED":
            _require(d.get("complete") is True and _integer(d.get("source_count"),0,194),"PERKS_COMPLETE_COUNT")
            perks=d.get("perks")
            if perks=={} and d["source_count"]==0:perks=[]
            _require(isinstance(perks,list) and len(perks)==d["source_count"],"PERKS_COMPLETE_COUNT")
            seen=set()
            for perk in perks:
                _require(isinstance(perk,dict) and set(perk)=={"attribute_type","perk_type","level"}
                         and _integer(perk["attribute_type"],-2147483648,2147483647)
                         and _integer(perk["perk_type"],-2147483648,2147483647)
                         and _integer(perk["level"],0,100),"PERK_WITNESS")
                _require(perk["perk_type"] not in seen,"PERK_DUPLICATE")
                seen.add(perk["perk_type"])
    if kind in {"DEVICE_COMPLETION","DEVICE_READBACK","QUICKHACK_REQUEST"} and status=="OBSERVED":
        _require(d.get("consequence")=="UNKNOWN","CONSEQUENCE_REQUIRED")
    if kind=="SCANNED_TARGET" and status=="OBSERVED":
        _require(_id(d.get("entity_id")) and d["entity_id"]!="0","SCANNED_ID")
    if kind=="DEVICE_READBACK":
        _require(_id(d.get("entity_id")) and d["entity_id"]!="0" and _integer(d.get("completion_sequence"),1),"READBACK_LINK")
    _inventory_payload(kind,status,d)
    if kind in {"TRACKED_ROOT_STATE","ROOT_JOURNAL_READBACK"}:
        for name in ("entry_hash","parent_hash"):
            if name in d:_require(_integer(d[name],1,4294967295),"ROOT_HASH")
        if "prior_active" in d:_require(type(d["prior_active"]) is bool,"ROOT_PRIOR_ACTIVE")
        if "native_state_name" in d:_require(isinstance(d["native_state_name"],str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,179}",d["native_state_name"]) is not None,"ROOT_STATE_NAME")
        if status=="ABSENT":
            _require(kind=="TRACKED_ROOT_STATE" and d=={"present":False},"ROOT_ABSENCE")
        elif status=="OBSERVED":
            _require(d.get("present") is True and d.get("entry_class")=="gameJournalQuest"
                     and "entry_hash" in d and isinstance(d.get("native_state"),dict)
                     and d["native_state"].get("availability")=="OBSERVED"
                     and _integer(d["native_state"].get("value"),-2147483648,2147483647)
                     and d.get("consequence")=="UNKNOWN","ROOT_WITNESS")
            if kind=="ROOT_JOURNAL_READBACK":_require(d.get("prior_active") is True,"ROOT_READBACK_BASELINE")
    if "native_completed" in d:
        _require(isinstance(d["native_completed"],dict),"COMPLETION_FIELD_SHAPE")
        completed=d["native_completed"]
        if completed.get("availability")=="OBSERVED":
            _require(type(completed.get("value")) is bool,"COMPLETION_FIELD_TYPE")
    _walk(d,None,0,[0])
    _require(len(json.dumps(row,ensure_ascii=True,separators=(",",":")).encode())<=MAX_BYTES,"BYTE_BUDGET")
    return row




class CandidateReplay:
    """One chronological offline stream. A gap revokes context until a fresh SESSION."""
    def __init__(self):
        self.session=None
        self.generation=0
        self.sequence=0
        self.elapsed=0
        self.ready=False
        self.completions=OrderedDict()
        self.seen_sessions=set()
        self.superseded_unclosed_generations=0
        self.active_root=None

    def invalidate(self):
        """Revoke state on every rejected row, including invalid session starts."""
        self.ready=False
        self.completions.clear()
        self.active_root=None

    def accept(self, row):
        try:
            return self._accept(row)
        except (ValueError, TypeError, KeyError, AttributeError):
            self.invalidate()
            raise

    def _accept(self, row):
        row=validate_candidate(row)
        d=row["data"]
        opening=row["kind"]=="SESSION" and d["ready"]
        new=row["producer_session"]!=self.session or row["generation"]!=self.generation
        if new:
            if row["producer_session"]!=self.session:
                _require(row["producer_session"] not in self.seen_sessions and len(self.seen_sessions)<64,"SESSION_REPLAY_OR_BUDGET")
            _require(opening and row["sequence"]==1 and row["elapsed_ms"]==0 and
                     (row["producer_session"]!=self.session or row["generation"]>self.generation),"FRESH_SESSION_REQUIRED")
            # Keep the integrity failure even when a fresh generation can rearm.
            if self.ready:self.superseded_unclosed_generations+=1
            self.session=row["producer_session"];self.seen_sessions.add(self.session);self.generation=row["generation"]
            self.sequence=0;self.elapsed=0;self.ready=True;self.completions.clear();self.active_root=None
        if not self.ready or row["sequence"]!=self.sequence+1 or row["elapsed_ms"]<self.elapsed:
            self.ready=False;self.completions.clear();self.active_root=None
            raise ValueError("CP25_CANDIDATE_ORDER_GAP")
        _require(not opening or self.sequence==0,"DUPLICATE_SESSION_START")
        self.sequence=row["sequence"];self.elapsed=row["elapsed_ms"]
        if row["kind"]=="DEVICE_COMPLETION" and d.get("native_completed",{}).get("value") is True and _id(d.get("entity_id")):
            self.completions[self.sequence]=(d["entity_id"],self.elapsed)
            while len(self.completions)>64:self.completions.popitem(last=False)
        if row["kind"]=="DEVICE_READBACK":
            prior=self.completions.get(d["completion_sequence"])
            if prior is None or prior[0]!=d["entity_id"] or (row["availability"]=="OBSERVED" and self.elapsed-prior[1]>2000):
                self.ready=False;self.completions.clear();self.active_root=None
                raise ValueError("CP25_CANDIDATE_READBACK_STALE_OR_MISMATCH")
        if row["kind"]=="ROOT_JOURNAL_READBACK":
            if self.active_root is None or d.get("entry_hash")!=self.active_root:
                self.ready=False;self.completions.clear();self.active_root=None
                raise ValueError("CP25_CANDIDATE_ROOT_BASELINE_MISMATCH")
            self.active_root=None
        elif row["kind"]=="TRACKED_ROOT_STATE":
            if d.get("prior_active") is True and (self.active_root is None or d.get("entry_hash")!=self.active_root):
                self.ready=False;self.completions.clear();self.active_root=None
                raise ValueError("CP25_CANDIDATE_ROOT_BASELINE_MISMATCH")
            self.active_root=d.get("entry_hash") if row["availability"]=="OBSERVED" and d["native_state"].get("value")==2 else None
        if row["kind"]=="SESSION" and not d["ready"]:
            self.ready=False;self.completions.clear();self.active_root=None
        if row["kind"]=="SOURCE_GAP" and row.get("reason")=="EVENTS_DROPPED":
            self.completions.clear();self.active_root=None
        return row


class GapSummary:
    """Bounded counts for local feedback; never sends or persists data."""
    def __init__(self):
        self.groups=OrderedDict()
        self.overflow=0

    def observe(self,row):
        row=validate_candidate(row)
        if row["availability"] not in {"UNKNOWN","UNAVAILABLE"}:
            return
        key=(row["kind"],row["source"],row["reason"])
        if key not in self.groups and len(self.groups)>=64:
            self.overflow+=1;return
        item=self.groups.setdefault(key,{"kind":key[0],"source":key[1],"reason":key[2],"count":0,"examples":[]})
        item["count"]+=1
        # Only native static identifiers/class names, no entity instance IDs.
        d=row["data"];r=d.get("record") or d.get("action_record") or d.get("choice_record") or {}
        if not isinstance(r,dict):r={}
        example={k:r[k] for k in ("record_id","record_ref") if k in r}
        if "class_name" in d:example["class_name"]=d["class_name"]
        if example and example not in item["examples"] and len(item["examples"])<3:item["examples"].append(example)

    def report(self):
        return {"scope":"CANDIDATE_GAPS_ONLY","groups":list(self.groups.values()),"overflow":self.overflow}

from copy import deepcopy
import zlib
MURMUR_MASK = (1 << 32) - 1

class TweakDBOfflineError(ValueError):
    pass

def tid(name: str) -> int:
    if not isinstance(name, str):
        raise TweakDBOfflineError("TDBID_NAME_NOT_TEXT")
    raw = name.encode("utf8")
    if not (0 < len(raw) <= 255):
        raise TweakDBOfflineError("TDBID_LENGTH_OUT_OF_RANGE")
    return (zlib.crc32(raw) & MURMUR_MASK) | (len(raw) << 32)

def tid_label(value: int | None) -> str | None:
    if value is None or value == 0:
        return None
    if value >> 40:
        raise TweakDBOfflineError("NONCOMPACT_TDBID_UNEXPECTED")
    return f"TDBID:{value & MURMUR_MASK:08X}:{(value >> 32) & 255:02X}"

def record_key(value):
    if isinstance(value,str):
        if re.fullmatch(r"Items\.[A-Za-z0-9_.]{1,170}",value):
            return tid(value)
        m=re.fullmatch(r"TDBID:([0-9A-F]{8}):([0-9A-F]{2})",value)
        if m and int(m[2],16):
            return int(m[2],16)<<32 | int(m[1],16)
    raise ValueError("INVALID_ITEM_RECORD_REFERENCE")

class StashReplay:
    """A header starts a new snapshot; only an exact contiguous final chunk commits it."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.pending=None
        self.rows=[]
        self.header=None
        self.serial=0
        self.scope="UNKNOWN"
        self.observed_at=None

    def invalidate(self):
        self.pending=None
        self.rows=[]
        self.header=None
        self.scope="UNKNOWN"
        self.observed_at=None

    def accept(self,row):
        kind,d=row["kind"],row["data"]
        if kind=="SESSION":
            self.reset()
        elif kind=="SOURCE_GAP" and row.get("reason") in {
            "EVENTS_DROPPED","STASH_ROW_UNRESOLVED","POLL_READ_ERROR"}:
            self.invalidate()
        elif kind=="STASH_SNAPSHOT":
            self.invalidate()
            if d["snapshot_id"]<=self.serial:
                raise ValueError("STASH_SNAPSHOT_REPLAY")
            self.serial=d["snapshot_id"]
            self.header=dict(d)
            if row["availability"]=="UNAVAILABLE":
                self.scope="LIST_UNAVAILABLE" if row.get("reason")=="STASH_LIST_UNAVAILABLE" else "ENTITY_UNAVAILABLE"
                self.observed_at=row["elapsed_ms"]
                return
            if d["entry_count"]==0:
                self.scope="EMPTY_UNVERIFIED" if d["source_count"]==0 else "TRUNCATED" if d.get("truncated") else "PARTIAL"
                self.observed_at=row["elapsed_ms"]
                return
            self.pending={"header":dict(d),"rows":[],"elapsed":row["elapsed_ms"]}
        elif kind=="STASH_SNAPSHOT_CHUNK":
            p=self.pending
            if p is None or d["snapshot_id"]!=p["header"]["snapshot_id"] or d["start"]!=len(p["rows"]):
                self.invalidate()
                raise ValueError("STASH_CHUNK_ORDER")
            n=len(p["rows"])+len(d["rows"]);total=p["header"]["entry_count"]
            if n>total or d["final"]!=(n==total) or row["elapsed_ms"]-p["elapsed"]>120000:
                self.invalidate()
                raise ValueError("STASH_CHUNK_COUNT_OR_AGE")
            p["rows"].extend(deepcopy(d["rows"]))
            if d["final"]:
                self.rows=p["rows"]
                self.scope="ENUMERATED" if p["header"]["complete"] else "TRUNCATED" if p["header"].get("truncated") else "PARTIAL"
                self.observed_at=p["elapsed"]
                self.pending=None

    def stock(self,elapsed):
        if self.observed_at is None or elapsed-self.observed_at>120000:
            return [],"UNKNOWN"
        # A compact-only/unknown record must not become a known name. Positives
        # are still useful; alias reconciliation remains explicitly partial.
        known=[{"record_id":r["record_id"],"quantity":r["quantity"]} for r in self.rows if "record_id" in r]
        scope=self.scope
        if len(known)!=len(self.rows) and scope=="ENUMERATED":
            scope="PARTIAL"
        return known,scope

class NativeStreamHost:
    def __init__(self):
        self.replay=CandidateReplay()
        self.stash=StashReplay()
        self.gaps=GapSummary()
        self.references=OrderedDict()
        self.resolved=OrderedDict()
        self.static_overflow=0
        self.shard_refs=set()

    @staticmethod
    def _key(ref):
        _static_ref(ref)
        return tid(ref["record_id"]) if "record_id" in ref else record_key(ref["record_ref"])

    def _offer(self,ref):
        key=self._key(ref)
        prior=self.references.get(key) or self.resolved.get(key,{}).get("reference")
        if prior and "record_id" in prior and "record_id" in ref and prior["record_id"]!=ref["record_id"]:
            raise ValueError("STATIC_REFERENCE_COLLISION")
        if key in self.resolved and (not ref.get("record_id") or self.resolved[key]["reference"].get("record_id")==ref["record_id"]):
            return
        if key not in self.references and len(self.references)+len(self.resolved)>=4096:
            self.static_overflow+=1
            return
        self.references[key]={**(prior or {}),**ref,"record_ref":tid_label(key)}

    def accept(self,row):
        try:
            validated=self.replay.accept(row)
            self.stash.accept(validated)
            self.gaps.observe(validated)
            d=validated["data"]
            if validated["kind"]=="STATIC_RECORD_REFERENCES":
                for ref in d["records"]:self._offer(ref)
            elif validated["kind"]=="STASH_SNAPSHOT_CHUNK":
                for item in d["rows"]:
                    ref={k:item[k] for k in ("record_id","record_ref") if k in item}
                    if ref:self._offer(ref)
            elif validated["kind"] in {"SHARD_STATE","SHARD_POPUP"} and isinstance(d.get("record"),dict):
                self._offer(d["record"])
                if len(self.shard_refs)<4096:self.shard_refs.add(self._key(d["record"]))
            return validated
        except (ValueError,TypeError,KeyError):
            self.stash.invalidate()
            self.replay.invalidate()
            raise
