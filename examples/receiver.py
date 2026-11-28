"""Minimal independent CP2077 2.5 TCP consumer example; Python 3.11+.

No game API, dependencies, persistent data, recommendations or peer attestation.
Run locally only, with an explicitly reviewed compatible producer.
"""
from __future__ import annotations

import argparse
from collections import Counter, deque
from datetime import datetime
import json
import math
import socket
import time
import uuid

MAX_FRAME = 1024 * 1024
MAX_ENTRIES = 1024
MAX_NUMBER = 2**53 - 1
KINDS = frozenset({
    "MENU_STATE", "PLAYER_POSITION", "COMBAT_STATE", "PLAYER_LIFE_STATE",
    "ACTIVE_QUEST", "ACTIVE_OBJECTIVE", "JOURNAL_UNAVAILABLE",
    "CURRENT_WEAPON", "VEHICLE_STATE", "CURRENT_DISTRICT", "TARGETED_ENTITY",
    "INVENTORY_SNAPSHOT", "INVENTORY_DELTA", "WORLD_TIME",
})


class ProtocolError(ValueError):
    pass


def require(ok):
    if not ok:
        raise ProtocolError("INVALID_FRAME")


def integer(v, lo=0, hi=MAX_NUMBER):
    return type(v) is int and lo <= v <= hi


def number(v):
    return type(v) in (int, float) and abs(v) <= MAX_NUMBER and math.isfinite(v)


def text(v):
    return isinstance(v, str) and 0 < len(v) <= 16384 and bool(v.strip())


def identity(v):
    try:
        return isinstance(v, str) and str(uuid.UUID(v)) == v
    except (ValueError, AttributeError):
        return False


def timestamp(v):
    try:
        return isinstance(v, str) and len(v) == 20 and datetime.strptime(
            v, "%Y-%m-%dT%H:%M:%SZ").strftime("%Y-%m-%dT%H:%M:%SZ") == v
    except ValueError:
        return False


def point(p):
    return isinstance(p, dict) and all(number(p.get(k)) for k in ("x", "y", "z"))


def item_key(row):
    require(isinstance(row, dict) and text(row.get("item_id")))
    for k in ("record_id", "item_type"):
        require(row.get(k) is None or text(row[k]))
    return (row["item_id"], row.get("record_id") or "", row.get("item_type") or "")


def snapshot(p):
    require(p.get("scope") == "player_transaction_inventory" and p.get("sync_kind") == "STATE_SYNC")
    entries = p.get("entries")
    n = p.get("entry_count")
    if entries == {} and n == 0:
        entries = []  # an empty Lua table can encode as an object
    excluded, total, cap = (p.get(k) for k in ("excluded_entry_count", "source_entry_count", "max_entries"))
    require(integer(n, 0, MAX_ENTRIES) and isinstance(entries, list) and len(entries) == n
            and integer(excluded) and integer(total) and total == n + excluded
            and integer(cap, 1, MAX_ENTRIES) and n <= cap
            and type(p.get("truncated")) is bool)
    result = Counter()
    for row in entries:
        key = item_key(row)
        q = row.get("quantity")
        require(integer(q, 1))
        result[key + (q,)] += 1
    return result if not p["truncated"] and excluded == 0 else None


def delta(p, baseline):
    require(p.get("scope") == "player_transaction_inventory" and p.get("sync_kind") == "STATE_CHANGE")
    changes = p.get("changes")
    require(isinstance(changes, list) and 1 <= len(changes) <= MAX_ENTRIES * 2
            and integer(p.get("change_count"), 1, MAX_ENTRIES * 2)
            and len(changes) == p["change_count"])
    removed, added = Counter(), Counter()
    affected = 0
    for row in changes:
        key = item_key(row)
        before, after, n = (row.get(k) for k in ("before_quantity", "after_quantity", "occurrences"))
        require(integer(before) and integer(after) and integer(n, 1, MAX_ENTRIES)
                and integer(row.get("quantity_delta"), -MAX_NUMBER, MAX_NUMBER)
                and row["quantity_delta"] == after - before
                and type(row.get("identity_ambiguous")) is bool)
        kind = row.get("change_type")
        require((kind == "added" and before == 0 < after)
                or (kind == "removed" and after == 0 < before)
                or (kind == "quantity_changed" and before > 0 and after > 0 and before != after
                    and n == 1 and not row["identity_ambiguous"]))
        if before:
            removed[key + (before,)] += n
        if after:
            added[key + (after,)] += n
        affected += n
    require(integer(p.get("affected_entry_count"), 1, MAX_ENTRIES * 2)
            and affected == p["affected_entry_count"])
    if baseline is None:
        return None  # a delta cannot restore an expired/partial baseline
    require(all(baseline[k] >= n for k, n in removed.items()))
    result = baseline.copy()
    result.subtract(removed)
    result = +result + added
    require(sum(result.values()) <= MAX_ENTRIES)
    return result


def unique_object(pairs):
    obj = {}
    for k, v in pairs:
        require(k not in obj)
        obj[k] = v
    return obj


def reject_constant(_):
    raise ProtocolError("INVALID_NUMBER")


def world_time(p, previous_seq):
    """Validate the opt-in clock extension without inferring a gameplay cause."""
    require(p.get("contract_version") == "0.1"
            and integer(p.get("sample_seq"), 1, 2147483647)
            and p["sample_seq"] == previous_seq + 1)
    base = {"contract_version", "sample_seq", "availability"}
    if p.get("availability") == "UNAVAILABLE":
        require(set(p) == base | {"reason"} and p.get("reason") in
                {"menu", "loading", "session_boundary", "read_error"})
        return False
    mandatory = base | {"hour", "minute", "minute_of_day", "precision",
                        "continuity", "clock_change", "skip_finish_callback_seen"}
    optional = {"day", "second", "world_seconds", "playthrough_seconds", "delta_world_seconds"}
    require(p.get("availability") == "OBSERVED" and mandatory <= set(p) <= mandatory | optional
            and integer(p["hour"], 0, 23) and integer(p["minute"], 0, 59)
            and integer(p["minute_of_day"], 0, 1439)
            and p["minute_of_day"] == p["hour"]*60+p["minute"]
            and type(p["skip_finish_callback_seen"]) is bool
            and p["continuity"] in {"INITIAL", "ADJACENT", "AFTER_MENU", "AFTER_WORLD_BOUNDARY",
                                   "AFTER_READ_GAP", "AFTER_POLL_GAP"})
    if "day" in p:
        require(integer(p["day"], 0, 2147483647))
    if p["precision"] == "SECOND":
        require(integer(p.get("world_seconds"), 0, 2147483647)
                and integer(p.get("second"), 0, 59) and "day" in p
                and p["world_seconds"] == p["day"]*86400+p["minute_of_day"]*60+p["second"])
    else:
        require(p["precision"] == "MINUTE" and "world_seconds" not in p and "second" not in p)
    if "playthrough_seconds" in p:
        require(number(p["playthrough_seconds"]) and 0 <= p["playthrough_seconds"] <= 2147483647)
    if "delta_world_seconds" in p:
        d=p["delta_world_seconds"]
        require("world_seconds" in p and integer(d, -2147483647, 2147483647)
                and p["continuity"] in {"ADJACENT", "AFTER_MENU", "AFTER_POLL_GAP"}
                and p["clock_change"] == ("BACKWARD" if d<0 else "UNCHANGED" if d==0
                                           else "LARGE_FORWARD" if d>=300 else "FORWARD"))
    else:
        require(p["clock_change"] == "NO_COMPARISON")
    return True


class Window:
    """One transport connection, one producer UUID, independently expiring facts."""

    def __init__(self, ttl=10.0, clock=time.monotonic):
        require(number(ttl) and 0 < ttl <= 300)
        self.ttl, self.clock = ttl, clock
        self.session = None
        self.ids = None
        self.facts = {}
        self.inventory = None
        self.inventory_at = None
        self.loading = None  # no world context before the first valid menu witness
        self.menu_gameplay = False
        self.world_time_seq = 0
        self.world_time_previous = None
        self.closed = False
        self.recent, self.recent_set = deque(), set()
        self.accepted = 0

    def revoke_world(self):
        self.facts = {k: v for k, v in self.facts.items() if k == "MENU_STATE"}
        self.inventory = self.inventory_at = None

    def close(self):
        self.facts.clear()
        self.inventory = self.inventory_at = None
        self.loading = True
        self.closed = True
        self.menu_gameplay = False
        self.world_time_previous = None

    def expire(self):
        now = self.clock()
        self.facts = {k: v for k, v in self.facts.items() if now - v[0] < (min(self.ttl, 2.0) if k == "WORLD_TIME" else self.ttl)}
        if self.inventory_at is not None and now - self.inventory_at >= self.ttl:
            self.inventory = self.inventory_at = None

    def accept(self, frame):
        self.expire()
        try:
            return self._accept(frame)
        except (ValueError, TypeError, KeyError, OverflowError, RecursionError):
            self.close()
            raise ProtocolError("INVALID_FRAME") from None

    def _accept(self, f):
        require(not self.closed and isinstance(f, dict) and f.get("schema_version") == "0.03"
                and identity(f.get("session_id")) and timestamp(f.get("timestamp")))
        sid = f["session_id"]
        require(self.session is None or sid == self.session)
        if "control_type" in f:
            require(f["control_type"] == "heartbeat" and set(f) == {
                "control_type", "schema_version", "session_id", "timestamp"})
            self.session = sid
            return {"status": "heartbeat", "session_id": sid}
        require(f.get("game_id") == "cyberpunk-2077" and f.get("game_version") == "2.5"
                and f.get("source") == "chumpilot.cet"
                and all(identity(f.get(k)) for k in ("user_id", "run_id", "message_id"))
                and number(f.get("confidence")) and 0 <= f["confidence"] <= 1)
        ids = (f["user_id"], f["run_id"])
        require(self.ids is None or ids == self.ids)
        mid, kind = f["message_id"], f.get("observation_type")
        require(mid not in self.recent_set and isinstance(kind, str) and kind in KINDS)
        prov, p = f.get("provenance"), f.get("payload")
        require(isinstance(prov, dict) and prov.get("sensor") == "cyberpunk_runtime"
                and prov.get("adapter") == "chumpilot_cet" and text(prov.get("method"))
                and isinstance(p, dict))
        now = self.clock()
        if kind == "MENU_STATE":
            require(type(p.get("is_menu")) is bool and type(p.get("is_loading")) is bool
                    and p.get("normalized_category") in {
                        "loading", "gameplay", "map", "inventory", "journal", "character",
                        "stats", "cyberware", "crafting", "vendor", "pause", "unknown", "other"}
                    and (p["normalized_category"] == "loading") == p["is_loading"])
            self.loading = p["is_loading"]
            self.menu_gameplay = not p["is_menu"] and not p["is_loading"] and p["normalized_category"] == "gameplay"
            if not self.menu_gameplay: self.facts.pop("WORLD_TIME", None)
            if self.loading:
                self.world_time_previous = None
                self.revoke_world()
        elif kind == "WORLD_TIME":
            observed = world_time(p,self.world_time_seq)
            if observed:
                require(self.menu_gameplay and self.loading is False)
                old = self.world_time_previous
                total = p.get("world_seconds")
                if p["continuity"] in {"ADJACENT","AFTER_MENU","AFTER_POLL_GAP"} and old is not None and total is not None:
                    require(p.get("delta_world_seconds") == total-old)
                else:
                    require("delta_world_seconds" not in p)
                self.world_time_previous = total
                self.facts[kind] = (now,p)
            else:
                if p["reason"] != "menu": self.world_time_previous = None
                self.facts.pop(kind,None)
            self.world_time_seq = p["sample_seq"]
        elif kind == "JOURNAL_UNAVAILABLE":
            require(p.get("reason") in {"loading", "read_error", "session_boundary"}
                    and integer(p.get("generation")) and type(p.get("terminal")) is bool)
            self.facts.pop("ACTIVE_QUEST", None)
            self.facts.pop("ACTIVE_OBJECTIVE", None)
        else:
            require(self.loading is False)
            if kind == "PLAYER_POSITION":
                require(point(p))
            elif kind == "COMBAT_STATE":
                require(type(p.get("in_combat")) is bool)
            elif kind in {"ACTIVE_QUEST", "ACTIVE_OBJECTIVE"}:
                prefix = "quest" if kind == "ACTIVE_QUEST" else "objective"
                title = "quest_title" if kind == "ACTIVE_QUEST" else "objective_text"
                require(type(p.get("active")) is bool)
                if p["active"]:
                    require(text(p.get(prefix + "_hash")) and text(p.get(title)))
                else:
                    require(p.get(prefix + "_hash") is None and p.get(title) is None)
            elif kind == "PLAYER_LIFE_STATE":
                require(number(p.get("health_current")) and number(p.get("health_max"))
                        and p["health_max"] > 0 and p.get("life_state") in {"alive", "dead"})
            elif kind == "CURRENT_WEAPON":
                require(type(p.get("equipped")) is bool
                        and (text(p.get("item_id")) if p["equipped"] else p.get("item_id") is None))
            elif kind == "VEHICLE_STATE":
                require(type(p.get("mounted")) is bool and p.get("role") in {"driver", "unknown"}
                        and (text(p.get("vehicle_id")) if p["mounted"] else p.get("vehicle_id") is None))
            elif kind == "CURRENT_DISTRICT":
                h = p.get("native_hierarchy")
                require(text(p.get("current_district_id")) and isinstance(h, list) and 1 <= len(h) <= 8
                        and all(isinstance(x, dict) and text(x.get("district_id")) for x in h)
                        and len({x["district_id"] for x in h}) == len(h)
                        and h[-1]["district_id"] == p["current_district_id"])
            elif kind == "TARGETED_ENTITY":
                require(type(p.get("present")) is bool
                        and (text(p.get("entity_id")) if p["present"] else p.get("entity_id") is None)
                        and (p.get("world_position") is None or point(p["world_position"]))
                        and (p.get("distance_m") is None or (number(p["distance_m"]) and p["distance_m"] >= 0)))
            elif kind == "INVENTORY_SNAPSHOT":
                self.inventory = snapshot(p)
                self.inventory_at = now if self.inventory is not None else None
            elif kind == "INVENTORY_DELTA":
                self.inventory = delta(p, self.inventory)
                self.inventory_at = now if self.inventory is not None else None
        # Never turn an invalidation or a partial inventory into a positive fact.
        if kind not in {"JOURNAL_UNAVAILABLE", "INVENTORY_SNAPSHOT", "INVENTORY_DELTA", "WORLD_TIME"}:
            self.facts[kind] = (now, p)
        if len(self.recent) >= 4096:
            self.recent_set.remove(self.recent.popleft())
        self.recent.append(mid)
        self.recent_set.add(mid)
        self.session, self.ids = sid, ids
        self.accepted += 1
        return {"status": "accepted", "message_id": mid}

    def summary(self):
        self.expire()
        return {"accepted": self.accepted, "current_fact_types": sorted(self.facts),
                "inventory_entries": None if self.inventory is None else sum(self.inventory.values())}


def serve_connection(conn, window, idle_timeout=10.0):
    """Bounded JSONL framing; no raw input/output logging or filesystem writes."""
    buf = bytearray()
    conn.settimeout(0.5)
    last = time.monotonic()
    try:
        while time.monotonic() - last < idle_timeout:
            window.expire()
            try:
                data = conn.recv(65536)
            except socket.timeout:
                continue
            if not data:
                break
            buf.extend(data)
            while b"\n" in buf:
                end = buf.index(b"\n")
                require(0 < end <= MAX_FRAME)
                raw = bytes(buf[:end]).rstrip(b"\r")
                del buf[:end+1]
                frame = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object,
                                   parse_constant=reject_constant)
                reply = window.accept(frame)
                conn.sendall(json.dumps(reply, separators=(",", ":")).encode() + b"\n")
                last = time.monotonic()  # only a completed valid frame resets idle time
            require(len(buf) <= MAX_FRAME)
    except (ValueError, TypeError, OverflowError, RecursionError):
        try:
            conn.sendall(b'{"status":"rejected","error":"invalid_frame"}\n')
        except OSError:
            pass
    except OSError:
        pass
    finally:
        window.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=20770)
    parser.add_argument("--ttl", type=float, default=10.0, help="example receive-age expiry, seconds")
    parser.add_argument("--idle-timeout", type=float, default=10.0,
                        help="disconnect idle peer; choose above the configured heartbeat interval")
    args = parser.parse_args()
    if not 1 <= args.port <= 65535 or not 0 < args.ttl <= 300 or not 0 < args.idle_timeout <= 600:
        parser.error("invalid bounds")
    # One connection at a time; every new connection has a fresh window.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", args.port))
        listener.listen(1)
        print("Listening on loopback; example only. Ctrl+C to stop.", flush=True)
        try:
            while True:
                conn, _ = listener.accept()
                with conn:
                    window = Window(args.ttl)
                    serve_connection(conn, window, args.idle_timeout)
                    print("Connection ended; accepted observations:", window.accepted, flush=True)
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
