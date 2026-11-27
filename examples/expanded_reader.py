"""Independent read-only expanded stream API and bounded reports.

Feed rows chronologically from one capture or follow future CET rows with
verified rotation (neither attests a live game process). No network, game access, DB, file writes or interpretation of advice.
Only aggregate counts are printed by the CLI. The API returns validated rows
to the caller; callers decide retention and privacy.
"""
from __future__ import annotations
import argparse
from collections import Counter
import json
from pathlib import Path
import sys
import stat
import time

from expanded_contract import NativeStreamHost, MAX_BYTES, CONTRACT, validate_candidate
from cet_follow import CETFollowError, CETLogCursor

MARKER = b"[DeepBideTelemetry] CANDIDATE_JSON="
MAX_LINE = 65536
MAX_FILE = 128*1024*1024
MAX_ROWS = 200000


def unique(pairs):
    out = {}
    for k,v in pairs:
        if k in out:
            raise ValueError("DUPLICATE_JSON_KEY")
        out[k]=v
    return out


def reject_constant(_):
    raise ValueError("NONFINITE_JSON")


def decode_row(raw):
    if not isinstance(raw,bytes) or not 0<len(raw)<=MAX_BYTES:
        raise ValueError("BYTE_BUDGET")
    return json.loads(raw.decode("utf-8"),object_pairs_hook=unique,parse_constant=reject_constant)


class ExpandedReader:
    """One capture; use a new instance for an independent capture."""
    def __init__(self):
        self.host=NativeStreamHost()
        self.kinds=Counter()
        self.availability=Counter()
        self.reasons=Counter()
        self.openings=self.closings=self.rejections=self.dropped=self.static_lost=0
        self.interrupted_stash=self.complete_stash=0
        self.perk_max=self.perk_complete=0
        self.perk_source_max=0
        self.close_reasons=Counter()

    def reject(self):
        self.rejections+=1
        self.host.replay.invalidate()
        self.host.stash.invalidate()

    def accept(self,row):
        if isinstance(row,dict) and row.get("kind")=="SOURCE_GAP" and not isinstance(row.get("reason"),str):
            self.reject()
            raise ValueError("SOURCE_GAP_REASON_REQUIRED")
        if sum(self.kinds.values()) >= MAX_ROWS:
            self.reject()
            raise ValueError("ROW_BUDGET")
        pending=self.host.stash.pending is not None
        serial=self.host.stash.serial
        try:
            row=self.host.accept(row)
        except (ValueError,TypeError,KeyError,AttributeError,OverflowError,RecursionError):
            self.reject()
            raise ValueError("INVALID_EXPANDED_ROW") from None
        k,d=row["kind"],row["data"]
        self.kinds[k]+=1
        self.availability[row["availability"]]+=1
        if k=="SOURCE_GAP":
            reason=row["reason"]
            self.reasons[reason]+=1
            if reason=="EVENTS_DROPPED":self.dropped+=d["count"]
            if reason=="INVENTORY_REFERENCE_GAP":self.static_lost+=d["count"]
        if k=="SESSION":
            if d["ready"]:self.openings+=1
            else:
                self.closings+=1
                self.dropped+=d.get("dropped_events",0)
                # Reason values are bounded strings by the inherited contract;
                # do not print arbitrary producer-supplied strings.
                reason=d.get("reason")
                self.close_reasons[reason if reason in ("SHUTDOWN","DISCONNECTED","GAMEPLAY_END","NOT_READY","PLAYER_UNAVAILABLE","LOADING") else "OTHER"]+=1
        if k=="PROGRESSION":
            count=d.get("source_count")
            if type(count) is int:self.perk_source_max=max(self.perk_source_max,count)
            if row["availability"]=="OBSERVED" and d.get("complete") is True:
                self.perk_complete+=1
                self.perk_max=max(self.perk_max,len(d["perks"]))
        if pending and k=="STASH_SNAPSHOT_CHUNK" and d.get("final") is True:
            if self.host.stash.scope=="ENUMERATED":self.complete_stash+=1
        elif pending and (self.host.stash.pending is None or self.host.stash.serial!=serial):
            self.interrupted_stash+=1
        return row

    def accept_json(self,raw):
        try:
            obj=decode_row(raw)
        except (ValueError,UnicodeError,RecursionError,OverflowError):
            self.reject()
            raise ValueError("INVALID_EXPANDED_JSON") from None
        return self.accept(obj)

    def summary(self):
        replay=self.host.replay
        active=bool(replay.ready)
        integrity=(self.openings>0 and self.openings==self.closings and not active
                   and not self.rejections and not self.dropped and not self.static_lost
                   and not replay.superseded_unclosed_generations and not self.host.static_overflow)
        return {
            "contract":"cp25-native-candidate/0.3",
            "capture_integrity":"CLOSED_NO_RECORDED_LOSS" if integrity else "INCOMPLETE",
            "accepted_rows":sum(self.kinds.values()),"kinds":dict(self.kinds),
            "availability":dict(self.availability),"source_gap_reasons":dict(self.reasons),
            "openings":self.openings,"closings":self.closings,"ready":active,
            "close_reasons":dict(self.close_reasons),
            "rejections":self.rejections,"reported_event_loss_indicators":self.dropped,
            "unoffered_reference_count":self.static_lost,
            "superseded_unclosed_generations":replay.superseded_unclosed_generations,
            "distinct_reference_offers":len(self.host.references),
            "reference_overflow":self.host.static_overflow,
            "reference_resolution":"NOT_PERFORMED",
            "complete_stash_snapshots":self.complete_stash,
            "interrupted_stash_snapshots":self.interrupted_stash,
            "stash_in_progress":self.host.stash.pending is not None,
            "complete_perk_reads":self.perk_complete,
            "max_complete_perks":self.perk_max,"max_perk_source_count":self.perk_source_max,
            "scope":"OFFLINE_CAPTURE_NOT_LIVE_IDENTITY_OR_SEMANTIC_COMPLETENESS",
        }


def scan(stream,reader,format="jsonl"):
    total=0
    while True:
        line=stream.readline(MAX_LINE+1)
        if not line:break
        total+=len(line)
        if len(line)>MAX_LINE or total>MAX_FILE:
            reader.reject();raise ValueError("CAPTURE_BUDGET")
        if format=="cet":
            if MARKER not in line:continue
            raw=line.split(MARKER,1)[1]
        else:raw=line
        if not line.endswith(b"\n"):
            reader.reject();raise ValueError("PARTIAL_CAPTURE_LINE")
        raw=raw.rstrip(b"\r\n")
        if raw:reader.accept_json(raw)
    return reader.summary()


def follow_cet(source, reader=None, *, max_seconds=900, poll_seconds=0.5,
               stop_requested=None, on_row=None):
    """Follow future DeepBide rows across witnessed CET rotations.

    The caller can receive each validated row through on_row(row). This
    function makes no writes or network calls and does not attest the game
    process or establish product-level facts. Stop with a callback, Ctrl+C
    or a deadline; max_seconds=None is explicit supervised until-stop mode.
    Size/row/line budgets still apply. Start before a fresh SESSION opening.
    """
    source = Path(source)
    if source.name.lower() != "scripting.log":
        raise ValueError("FOLLOW_EXPECTS_SCRIPTING_LOG")
    if (max_seconds is not None and
            (type(max_seconds) is not int or not 1 <= max_seconds <= 3600)):
        raise ValueError("FOLLOW_TIME_LIMIT")
    if type(poll_seconds) not in (int, float) or not 0.05 <= poll_seconds <= 2.0:
        raise ValueError("FOLLOW_POLL_LIMIT")
    if any(x is not None and not callable(x) for x in (stop_requested, on_row)):
        raise ValueError("FOLLOW_CALLBACK_REQUIRED")
    if reader is None:
        reader = ExpandedReader()
    if reader.kinds or reader.rejections or reader.host.replay.session is not None:
        raise ValueError("FOLLOW_READER_MUST_BE_FRESH")

    cursor = CETLogCursor(source)
    started = time.monotonic()
    pending = b""
    discard_initial_fragment = False
    registration_seen = False
    require_registration = False
    opened = False
    rotation_pending = False
    rotations = verified_rotations = recovered_rows = rebases = scanned_bytes = 0
    error = None
    missing_since = None
    stop_reason = "TIME_LIMIT"
    ready_prefix = b"[DeepBideTelemetry] READY_CANDIDATE_CONTRACT="
    ready_line = ready_prefix + CONTRACT.encode("ascii")

    def consume(chunk, *, archive=False):
        nonlocal pending, scanned_bytes, discard_initial_fragment
        nonlocal registration_seen, opened, rotation_pending, verified_rotations, recovered_rows
        scanned_bytes += len(chunk)
        if scanned_bytes > MAX_FILE:
            raise CETFollowError("FOLLOW_INPUT_BYTE_BUDGET")
        segments = (pending + chunk).split(b"\n")
        pending = segments.pop()
        if len(pending) > MAX_LINE:
            raise CETFollowError("FOLLOW_LINE_BUDGET")
        if archive and pending:
            raise CETFollowError("FOLLOW_NATIVE_ROTATION_PARTIAL_ARCHIVE_LINE")
        for raw in segments:
            if discard_initial_fragment:
                discard_initial_fragment = False
                continue
            if len(raw) > MAX_LINE:
                raise CETFollowError("FOLLOW_LINE_BUDGET")
            line = raw.rstrip(b"\r")
            if ready_prefix in line:
                if not line.endswith(ready_line):
                    raise CETFollowError("FOLLOW_REGISTRATION_CONTRACT_MISMATCH")
                if opened or registration_seen:
                    raise CETFollowError("FOLLOW_MULTIPLE_REGISTRATIONS")
                registration_seen = True
                continue
            if MARKER not in line or (not opened and require_registration and not registration_seen):
                continue
            try:
                obj = decode_row(line.split(MARKER, 1)[1])
            except (ValueError, UnicodeError, RecursionError, OverflowError):
                raise CETFollowError("FOLLOW_INVALID_JSON") from None
            successor = rotation_pending and not archive
            if not opened:
                try:
                    row = validate_candidate(obj)
                except (ValueError, TypeError, KeyError, AttributeError, OverflowError, RecursionError):
                    raise CETFollowError("FOLLOW_INVALID_INITIAL_ROW") from None
                if row["kind"] != "SESSION" or not row["data"]["ready"]:
                    continue
            elif successor:
                try:
                    row = validate_candidate(obj)
                except (ValueError, TypeError, KeyError, AttributeError, OverflowError, RecursionError):
                    raise CETFollowError("FOLLOW_NATIVE_ROTATION_ORDER_UNVERIFIED") from None
                replay = reader.host.replay
                same_session = row["producer_session"] == replay.session
                same_generation = same_session and row["generation"] == replay.generation
                if not same_generation and (replay.ready or
                        (same_session and row["generation"] != replay.generation + 1)):
                    raise CETFollowError("FOLLOW_NATIVE_ROTATION_GENERATION_GAP")
            try:
                row = reader.accept(obj)
            except ValueError:
                raise CETFollowError("FOLLOW_NATIVE_ROTATION_ORDER_UNVERIFIED" if archive or successor
                                     else "FOLLOW_INVALID_EXPANDED_ROW") from None
            opened = True
            if successor:
                rotation_pending = False
                verified_rotations += 1
            if archive:
                recovered_rows += 1
            if on_row is not None:
                try:
                    on_row(row)
                except Exception:
                    raise CETFollowError("FOLLOW_CONSUMER_CALLBACK_FAILED") from None

    try:
        parent = source.parent.lstat()
        if (not stat.S_ISDIR(parent.st_mode) or
                getattr(parent, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
            raise CETFollowError("FOLLOW_SOURCE_DIRECTORY_UNVERIFIED")
        try:
            cursor.rebase()
        except FileNotFoundError:
            pass
        discard_initial_fragment = bool(cursor.tail and not cursor.tail.endswith(b"\n"))
        while max_seconds is None or time.monotonic() - started < max_seconds:
            if stop_requested is not None:
                try:
                    should_stop = stop_requested()
                except Exception:
                    raise CETFollowError("FOLLOW_STOP_CALLBACK_FAILED") from None
                if should_stop:
                    stop_reason = "USER_STOP"
                    break
            status, chunk, more = cursor.read()
            if status == "missing":
                if opened:
                    now = time.monotonic()
                    if missing_since is None:
                        missing_since = now
                    elif now - missing_since >= max(1.0, 3 * poll_seconds):
                        raise CETFollowError("FOLLOW_NATIVE_SOURCE_MISSING")
                time.sleep(poll_seconds)
                continue
            missing_since = None
            if status == "changed":
                if cursor.identity is not None:
                    rotations += 1
                if opened:
                    if rotation_pending:
                        raise CETFollowError("FOLLOW_NATIVE_ROTATION_PREVIOUS_BOUNDARY_UNVERIFIED")
                    suffix = cursor.rotate()
                    consume(suffix, archive=True)
                    rotation_pending = True
                    continue
                # Existing bytes after an unverified pre-opening replacement
                # do not prove a fresh session; rebase and await new registration.
                try:
                    cursor.rebase()
                except FileNotFoundError:
                    time.sleep(poll_seconds)
                    continue
                rebases += 1
                pending = b""
                discard_initial_fragment = bool(cursor.tail and not cursor.tail.endswith(b"\n"))
                require_registration = True
                registration_seen = False
                continue
            if chunk:
                consume(chunk)
            if more:
                continue
            time.sleep(poll_seconds)
    except KeyboardInterrupt:
        stop_reason = "USER_STOP"
    except (CETFollowError, OSError) as exc:
        error = str(exc) if isinstance(exc, CETFollowError) else "FOLLOW_SOURCE_IO_ERROR"
        stop_reason = "SOURCE_ERROR"
    if opened and error is None:
        if rotation_pending:
            error = "FOLLOW_NATIVE_ROTATION_SUCCESSOR_UNWITNESSED"
        elif missing_since is not None:
            error = "FOLLOW_NATIVE_SOURCE_MISSING_AT_STOP"
        elif pending:
            error = "FOLLOW_NATIVE_PARTIAL_LINE_AT_STOP"
    if error is not None:
        # Revoke current context even when the already accepted prefix closed
        # normally. A later opening cannot erase an unverified boundary.
        if not reader.rejections:
            reader.reject()
    result = reader.summary()
    if error or not opened:
        result["capture_integrity"] = "INCOMPLETE"
    result.update({
        "scope": "LOCAL_LOG_FOLLOW_NOT_LIVE_IDENTITY_OR_SEMANTIC_COMPLETENESS",
        "current_producer_attested": False,
        "source_continuity": ("LOST_AFTER_OPEN" if opened else "UNVERIFIED_BEFORE_OPEN") if error else
            ("ROTATION_VERIFIED_SCOPE" if verified_rotations else "APPEND_SCOPE") if opened else
            "WAITING_FOR_FRESH_OPEN",
        "source_continuity_error": error,
        "source_rotations_observed": rotations,
        "source_rotations_verified": verified_rotations,
        "source_rotation_recovered_rows": recovered_rows,
        "source_eof_rebases": rebases,
        "native_session_open_seen": opened,
        "registration_marker_seen": registration_seen,
        "source_bytes_scanned": scanned_bytes,
        "stop_reason": stop_reason,
    })
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("capture",type=Path,help="explicit local capture or scripting.log; never upload it")
    p.add_argument("--format",choices=("jsonl","cet"))
    p.add_argument("--follow",action="store_true",help="follow future CET rows with verified rotation")
    timebox=p.add_mutually_exclusive_group()
    timebox.add_argument("--max-seconds",type=int,help="follow duration, 1..3600 (default 900)")
    timebox.add_argument("--until-stop",action="store_true",help="supervised follow until Ctrl+C; data caps remain")
    p.add_argument("--poll-seconds",type=float,help="follow polling interval, 0.05..2 (default 0.5)")
    a=p.parse_args()
    r=ExpandedReader()
    if a.follow:
        if a.format=="jsonl":
            p.error("--follow requires CET scripting.log, not JSONL")
        try:
            result=follow_cet(a.capture,r,max_seconds=None if a.until_stop else
                              a.max_seconds if a.max_seconds is not None else 900,
                              poll_seconds=a.poll_seconds if a.poll_seconds is not None else 0.5)
        except ValueError:
            # Do not print user paths or raw exception/producer content.
            r.reject()
            result={**r.summary(),"source_continuity":"UNVERIFIED_BEFORE_OPEN",
                    "source_continuity_error":"FOLLOW_ARGUMENT_REJECTED",
                    "current_producer_attested":False}
    else:
        if a.max_seconds is not None or a.until_stop or a.poll_seconds is not None:
            p.error("follow options require --follow")
        try:
            with a.capture.open("rb") as stream:result=scan(stream,r,a.format or "jsonl")
        except (OSError,ValueError):
            # Do not print paths, raw rows, exception content or identifiers.
            print(json.dumps(r.summary(),sort_keys=True));return 2
    print(json.dumps(result,sort_keys=True))
    return 0 if result["capture_integrity"]=="CLOSED_NO_RECORDED_LOSS" else 2


if __name__=="__main__":sys.exit(main())
