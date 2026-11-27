"""Synthetic filesystem and public API tests; no game or external dependencies."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from cet_follow import CETLogCursor
from expanded_reader import ExpandedReader, MARKER, follow_cet
from expanded_contract import CONTRACT, SOURCES
from test_expanded_reader import session, progression, row

READY = b"[DeepBideTelemetry] READY_CANDIDATE_CONTRACT=" + CONTRACT.encode("ascii") + b"\n"


def lines(rows):
    return b"".join(b"[synthetic] " + MARKER + json.dumps(r).encode("ascii") + b"\n" for r in rows)


def sample_rows():
    return [session(1, True), progression(2, 3), progression(3, 4), session(4, False)]


class CETFollowTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.source = self.root / "scripting.log"
        self.archive = self.root / "scripting.1.log"

    def rename(self, tail):
        self.source.replace(self.archive)
        self.source.write_bytes(tail)

    def append(self, raw):
        with self.source.open("ab") as f:
            f.write(raw)

    def run_steps(self, steps, expected, *, initial=b"historical unrelated log\n",
                  error=None, rotations=0, verified=0, recovered=0,
                  stop_after_expected=True, callback=None, timeout=4):
        """Synchronize the writer at real poll boundaries, not simulated I/O."""
        if initial is not None:
            self.source.write_bytes(initial)
        captured, receipts, errors = [], [], []
        stop = threading.Event()
        paused = [threading.Event() for _ in steps]
        resume = [threading.Event() for _ in steps]
        next_step = 0
        reader = ExpandedReader()
        read = CETLogCursor.read

        def on_row(value):
            captured.append(value)
            if callback is not None:
                callback(value)

        def gated(cursor):
            nonlocal next_step
            if next_step < len(steps) and len(captured) == steps[next_step][0]:
                i = next_step
                next_step += 1
                paused[i].set()
                if not resume[i].wait(6):
                    raise RuntimeError("TEST_WRITER_TIMEOUT")
            return read(cursor)

        def run():
            try:
                receipts.append(follow_cet(
                    self.source, reader, max_seconds=timeout, poll_seconds=.05,
                    stop_requested=stop.is_set, on_row=on_row))
            except Exception as exc:
                errors.append(exc)

        with patch.object(CETLogCursor, "read", gated):
            thread = threading.Thread(target=run, daemon=True)
            thread.start()
            try:
                for i, (_, action) in enumerate(steps):
                    self.assertTrue(paused[i].wait(6), f"WRITER_STEP_{i}_NOT_REACHED")
                    action()
                    resume[i].set()
                end = time.monotonic() + timeout + 2
                while thread.is_alive() and time.monotonic() < end:
                    if stop_after_expected and error is None and len(captured) >= len(expected):
                        stop.set()
                    time.sleep(.01)
            finally:
                for signal in resume:
                    signal.set()
                stop.set()
                thread.join(7)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors, str(errors))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(captured, expected)
        receipt = receipts[0]
        self.assertEqual(receipt["accepted_rows"], len(expected))
        self.assertEqual(receipt["source_continuity_error"], error)
        self.assertEqual(receipt["source_rotations_observed"], rotations)
        self.assertEqual(receipt["source_rotations_verified"], verified)
        self.assertEqual(receipt["source_rotation_recovered_rows"], recovered)
        self.assertFalse(receipt["current_producer_attested"])
        self.assertNotIn("synthetic]", json.dumps(receipt))
        if error:
            self.assertEqual(receipt["capture_integrity"], "INCOMPLETE")
            self.assertFalse(reader.host.replay.ready)
        return receipt

    def test_future_open_without_registration_and_old_rows_ignored(self):
        rows = sample_rows()
        prior = [session(1, True), session(2, False)]
        receipt = self.run_steps([(0, lambda: self.append(lines(rows)))],
                                 rows, initial=READY+lines(prior))
        self.assertEqual(receipt["source_continuity"], "APPEND_SCOPE")
        self.assertFalse(receipt["registration_marker_seen"])
        self.assertEqual(receipt["capture_integrity"], "CLOSED_NO_RECORDED_LOSS")

    def test_rebase_ignores_copied_history_until_fresh_registration(self):
        rows = sample_rows()
        old = READY+lines(rows)
        def replace():
            replacement = self.root / "replacement.tmp"
            replacement.write_bytes(b"replacement\n"+old)
            replacement.replace(self.source)
        receipt = self.run_steps([
            (0, replace), (0, lambda: self.append(READY+lines(rows)))
        ], rows, initial=old, rotations=1)
        self.assertEqual(receipt["source_eof_rebases"], 1)
        self.assertTrue(receipt["registration_marker_seen"])
        self.assertEqual(receipt["capture_integrity"], "CLOSED_NO_RECORDED_LOSS")

    def test_normal_rotation_recovers_unread_row_and_partial_same_file(self):
        rows = sample_rows()
        prefix, middle, successor = lines(rows[:2]), lines(rows[2:3]), lines(rows[3:])
        def rotate():
            self.append(middle[17:])
            self.rename(b"other module\n"+successor)
        receipt = self.run_steps([
            (0, lambda: self.append(READY+prefix+middle[:17])),
            (2, rotate)
        ], rows, rotations=1, verified=1, recovered=1)
        self.assertEqual(receipt["source_continuity"], "ROTATION_VERIFIED_SCOPE")
        self.assertEqual(receipt["capture_integrity"], "CLOSED_NO_RECORDED_LOSS")

    def test_two_verified_rotations(self):
        rows = sample_rows()
        def first():
            self.rename(lines(rows[1:2]))
        def second():
            self.append(lines(rows[2:3]))
            self.rename(lines(rows[3:]))
        receipt = self.run_steps([
            (0, lambda: self.append(READY+lines(rows[:1]))),
            (1, first), (2, second)
        ], rows, rotations=2, verified=2, recovered=1)
        self.assertEqual(receipt["capture_integrity"], "CLOSED_NO_RECORDED_LOSS")

    def fail_rotation(self, action, error, *, prefix_count=2, rotations=1, expected=None):
        rows = sample_rows()
        prefix = rows[:prefix_count]
        return self.run_steps([
            (0, lambda: self.append(READY+lines(prefix))),
            (prefix_count, lambda: action(rows))
        ], prefix if expected is None else expected, error=error, rotations=rotations)

    def test_copy_archive_with_exact_bytes_is_not_identity(self):
        def action(rows):
            self.archive.write_bytes(self.source.read_bytes())
            replacement = self.root / "replacement.tmp"
            replacement.write_bytes(lines(rows[2:]))
            replacement.replace(self.source)
        self.fail_rotation(action, "FOLLOW_NATIVE_ROTATION_ARCHIVE_IDENTITY")

    def test_missing_archive(self):
        def action(rows):
            replacement = self.root / "replacement.tmp"
            replacement.write_bytes(lines(rows[2:]))
            replacement.replace(self.source)
        self.fail_rotation(action, "FOLLOW_NATIVE_ROTATION_ARCHIVE_MISSING")

    def test_rotated_prefix_overwrite_with_retained_tail(self):
        def action(rows):
            original = self.source.read_bytes()
            with self.source.open("r+b") as f:
                f.write(b"X")
            self.assertEqual(self.source.read_bytes()[-128:], original[-128:])
            self.rename(lines(rows[2:]))
        self.fail_rotation(action, "FOLLOW_NATIVE_ROTATION_PREFIX_MISMATCH")

    def test_same_inode_truncate_refill_with_retained_tail(self):
        def action(rows):
            original = self.source.read_bytes()
            self.source.write_bytes(b"X"+original[1:]+lines(rows[2:]))
            self.assertEqual(self.source.read_bytes()[len(original)-128:len(original)],original[-128:])
        self.fail_rotation(action, "FOLLOW_NATIVE_ROTATION_NOT_RENAME")

    def test_same_size_rewrite_with_retained_tail(self):
        def action(rows):
            raw = self.source.read_bytes()
            mtime = self.source.stat().st_mtime_ns
            self.source.write_bytes(b"X"+raw[1:])
            os.utime(self.source, ns=(self.source.stat().st_atime_ns,mtime+2_000_000_000))
            self.assertEqual(self.source.stat().st_size,len(raw))
            self.assertEqual(self.source.read_bytes()[-128:],raw[-128:])
        self.fail_rotation(action, "FOLLOW_NATIVE_ROTATION_NOT_RENAME")

    def test_split_line_cannot_cross_file_boundary(self):
        def action(rows):
            tail=lines(rows[2:])
            self.append(tail[:17])
            self.rename(tail[17:])
        self.fail_rotation(action, "FOLLOW_NATIVE_ROTATION_PARTIAL_ARCHIVE_LINE")

    def test_missing_successor_sequence(self):
        self.fail_rotation(lambda rows:self.rename(lines(rows[3:])),
                           "FOLLOW_NATIVE_ROTATION_ORDER_UNVERIFIED")

    def test_duplicate_successor_sequence(self):
        self.fail_rotation(lambda rows:self.rename(lines(rows[1:])),
                           "FOLLOW_NATIVE_ROTATION_ORDER_UNVERIFIED")

    def test_fresh_generation_cannot_hide_unclosed_prior(self):
        self.fail_rotation(lambda rows:self.rename(lines([session(1,True,2),session(2,False,2)])),
                           "FOLLOW_NATIVE_ROTATION_GENERATION_GAP")

    def test_closed_generation_can_open_exact_next(self):
        rows=sample_rows()
        next_rows=[session(1,True,2),session(2,False,2)]
        receipt=self.run_steps([
            (0,lambda:self.append(READY+lines(rows))),
            (len(rows),lambda:self.rename(lines(next_rows)))
        ],rows+next_rows,rotations=1,verified=1)
        self.assertEqual(receipt["capture_integrity"],"CLOSED_NO_RECORDED_LOSS")

    def test_skipped_generations_after_close_not_certified(self):
        self.fail_rotation(lambda rows:self.rename(lines([session(1,True,3),session(2,False,3)])),
                           "FOLLOW_NATIVE_ROTATION_GENERATION_GAP",prefix_count=4)

    def test_missing_successor_cannot_claim_complete_closed_prefix(self):
        rows=sample_rows()
        receipt=self.run_steps([
            (0,lambda:self.append(READY+lines(rows))),
            (len(rows),lambda:self.rename(b"unrelated new file\n"))
        ],rows,error="FOLLOW_NATIVE_ROTATION_SUCCESSOR_UNWITNESSED",rotations=1,timeout=1)
        self.assertEqual(receipt["source_continuity"],"LOST_AFTER_OPEN")

    def test_multiple_unseen_rotations_not_guessed(self):
        def action(rows):
            self.source.replace(self.root/"scripting.2.log")
            self.source.write_bytes(b"intermediate file\n")
            self.rename(lines(rows[2:]))
        self.fail_rotation(action,"FOLLOW_NATIVE_ROTATION_ARCHIVE_IDENTITY")

    def test_explicit_loss_stays_incomplete_after_verified_rotation(self):
        gap=row(2,"SOURCE_GAP",sorted(SOURCES["SOURCE_GAP"])[0],
                {"count":7},"UNKNOWN","INVENTORY_REFERENCE_GAP")
        rows=[session(1,True),gap,session(3,False)]
        receipt=self.run_steps([
            (0,lambda:self.append(READY+lines(rows[:1]))),
            (1,lambda:self.rename(lines(rows[1:])))
        ],rows,rotations=1,verified=1)
        self.assertEqual(receipt["source_continuity"],"ROTATION_VERIFIED_SCOPE")
        self.assertEqual(receipt["capture_integrity"],"INCOMPLETE")
        self.assertEqual(receipt["unoffered_reference_count"],7)
        self.assertEqual(receipt["availability"]["UNKNOWN"],1)

    def test_missing_source_after_open_is_bounded(self):
        self.fail_rotation(lambda rows:self.source.unlink(),
                           "FOLLOW_NATIVE_SOURCE_MISSING",rotations=0)

    def test_malformed_duplicate_keys_rejected_without_raw_content(self):
        rows=sample_rows()
        receipt=self.run_steps([
            (0,lambda:self.append(READY+lines(rows[:1]))),
            (1,lambda:self.append(MARKER+b'{"kind":"private content","kind":"duplicate"}\n'))
        ],rows[:1],error="FOLLOW_INVALID_JSON")
        self.assertNotIn("private content",json.dumps(receipt))

    def test_callback_failure_revokes_without_echoing_exception(self):
        rows=sample_rows()
        def callback(_):
            raise RuntimeError("private callback content")
        receipt=self.run_steps([(0,lambda:self.append(READY+lines(rows)))],rows[:1],
                               error="FOLLOW_CONSUMER_CALLBACK_FAILED",callback=callback)
        self.assertNotIn("private callback content",json.dumps(receipt))

    def test_bounded_until_stop_and_validation(self):
        self.source.write_bytes(b"old file\n")
        receipt=follow_cet(self.source,max_seconds=None,stop_requested=lambda:True)
        self.assertEqual(receipt["source_continuity"],"WAITING_FOR_FRESH_OPEN")
        self.assertEqual(receipt["stop_reason"],"USER_STOP")
        self.assertEqual(receipt["capture_integrity"],"INCOMPLETE")
        with self.assertRaisesRegex(ValueError,"FOLLOW_TIME_LIMIT"):
            follow_cet(self.source,max_seconds=3601)
        with self.assertRaisesRegex(ValueError,"FOLLOW_POLL_LIMIT"):
            follow_cet(self.source,poll_seconds=0)
        used=ExpandedReader();used.accept(session(1,True))
        with self.assertRaisesRegex(ValueError,"FOLLOW_READER_MUST_BE_FRESH"):
            follow_cet(self.source,used)

    def test_input_budget_fails_closed(self):
        rows=sample_rows()
        with patch("expanded_reader.MAX_FILE",len(READY)+len(lines(rows[:1]))):
            self.run_steps([
                (0,lambda:self.append(READY+lines(rows[:1]))),
                (1,lambda:self.append(lines(rows[1:])))
            ],rows[:1],error="FOLLOW_INPUT_BYTE_BUDGET")

    def test_file_link_refused(self):
        self.archive.write_bytes(b"unrelated\n")
        try:
            self.source.symlink_to(self.archive)
        except (OSError,NotImplementedError):
            self.skipTest("symlink creation not available")
        receipt=follow_cet(self.source,max_seconds=1)
        self.assertEqual(receipt["source_continuity"],"UNVERIFIED_BEFORE_OPEN")
        self.assertEqual(receipt["capture_integrity"],"INCOMPLETE")

    def test_cli_offline_and_follow_opt_in_aggregate_only(self):
        script=Path(__file__).with_name("expanded_reader.py")
        self.source.write_bytes(READY+lines(sample_rows()))
        offline=subprocess.run([sys.executable,"-B",str(script),str(self.source),"--format","cet"],
                               capture_output=True,text=True,timeout=8)
        self.assertEqual(offline.returncode,0,offline.stderr)
        self.assertEqual(json.loads(offline.stdout)["accepted_rows"],4)
        follow=subprocess.run([sys.executable,"-B",str(script),str(self.source),"--follow","--max-seconds","1"],
                              capture_output=True,text=True,timeout=8)
        self.assertEqual(follow.returncode,2,follow.stderr)
        self.assertEqual(json.loads(follow.stdout)["accepted_rows"],0)
        self.assertEqual(json.loads(follow.stdout)["source_continuity"],"WAITING_FOR_FRESH_OPEN")
        self.assertNotIn(str(self.source),follow.stdout)


if __name__=="__main__":
    unittest.main()
