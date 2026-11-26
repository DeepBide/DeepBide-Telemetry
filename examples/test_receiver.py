"""Standalone synthetic tests. Run: python examples/test_receiver.py."""
import json
import socket
import threading
import unittest

from receiver import Window, ProtocolError, serve_connection

SID = "12345678-1234-4234-8234-123456789abc"
USER = "abcdefab-1234-4234-8234-abcdefabcdef"
RUN = "00000000-0000-4000-8000-000000000004"
TIME = "2026-11-25T00:00:00Z"


def obs(kind, payload, n, session=SID):
    return {"schema_version": "0.03", "message_id": f"00000000-0000-4000-8000-{n:012x}",
            "session_id": session, "user_id": USER, "run_id": RUN,
            "source": "chumpilot.cet", "game_id": "cyberpunk-2077", "game_version": "2.5",
            "observation_type": kind, "timestamp": TIME, "confidence": 1.0, "payload": payload,
            "provenance": {"sensor": "cyberpunk_runtime", "adapter": "chumpilot_cet",
                           "method": "synthetic"}}


def menu(n, loading=False):
    return obs("MENU_STATE", {"is_menu": loading, "is_loading": loading,
                              "normalized_category": "loading" if loading else "gameplay"}, n)


def heartbeat():
    return {"schema_version": "0.03", "session_id": SID, "control_type": "heartbeat", "timestamp": TIME}


def inv(n, quantities, excluded=0):
    return obs("INVENTORY_SNAPSHOT", {"scope": "player_transaction_inventory", "sync_kind": "STATE_SYNC",
            "entries": [{"item_id": "3ULL", "record_id": "Items.Example", "quantity": q} for q in quantities],
            "entry_count": len(quantities), "excluded_entry_count": excluded,
            "source_entry_count": len(quantities) + excluded, "max_entries": 1024, "truncated": False}, n)


def change(n, before, after, occurrences=1, ambiguous=True):
    return obs("INVENTORY_DELTA", {"scope": "player_transaction_inventory", "sync_kind": "STATE_CHANGE",
            "changes": [{"item_id": "3ULL", "record_id": "Items.Example", "before_quantity": before,
                         "after_quantity": after, "quantity_delta": after-before,
                         "change_type": "added" if before == 0 else "removed" if after == 0 else "quantity_changed",
                         "occurrences": occurrences, "identity_ambiguous": ambiguous}],
            "change_count": 1, "affected_entry_count": occurrences}, n)


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        self.now = 0
        self.w = Window(ttl=5, clock=lambda: self.now)
        self.w.accept(menu(1))

    def test_receive_expiry_not_heartbeat(self):
        self.w.accept(obs("COMBAT_STATE", {"in_combat": False}, 2))
        self.now = 4
        self.assertEqual(self.w.accept(heartbeat())["status"], "heartbeat")
        self.assertIn("COMBAT_STATE", self.w.summary()["current_fact_types"])
        self.now = 5
        self.assertEqual(self.w.summary()["current_fact_types"], [])
        self.w.accept(obs("COMBAT_STATE", {"in_combat": True}, 3))
        self.assertEqual(self.w.summary()["current_fact_types"], ["COMBAT_STATE"])

    def test_loading_revokes_and_recovery_needs_fresh_facts(self):
        self.w.accept(inv(2, [1, 1, 2]))
        self.w.accept(obs("COMBAT_STATE", {"in_combat": True}, 3))
        self.w.accept(menu(4, True))
        self.assertEqual(self.w.summary()["current_fact_types"], ["MENU_STATE"])
        self.assertIsNone(self.w.inventory)
        self.w.accept(menu(5))
        self.w.accept(change(6, 0, 3))
        self.assertIsNone(self.w.inventory)
        self.w.accept(inv(7, [1, 2]))
        self.assertEqual(self.w.summary()["inventory_entries"], 2)

    def test_unknown_menu_boundary_and_disconnect_clear(self):
        self.w.accept(inv(2, [1]))
        self.w.close()
        self.assertIsNone(self.w.inventory)
        self.assertEqual(self.w.summary()["current_fact_types"], [])
        with self.assertRaises(ProtocolError):
            self.w.accept(menu(3))

    def test_journal_invalidation_not_absence(self):
        self.w.accept(obs("ACTIVE_QUEST", {"active": True, "quest_hash": "123", "quest_title": "example"}, 2))
        self.w.accept(obs("ACTIVE_OBJECTIVE", {"active": False}, 3))
        self.w.accept(obs("JOURNAL_UNAVAILABLE", {"reason": "read_error", "generation": 1, "terminal": False}, 4))
        self.assertEqual(self.w.summary()["current_fact_types"], ["MENU_STATE"])

    def test_inventory_multiset_no_pairing_and_expiry(self):
        self.w.accept(inv(2, [1, 1, 3]))
        self.w.accept(change(3, 1, 0, 2))
        self.w.accept(change(4, 0, 4, 2))
        self.assertEqual(sorted((key[-1], count) for key, count in self.w.inventory.items()), [(3, 1), (4, 2)])
        self.now = 6
        self.w.accept(change(5, 0, 2))
        self.assertIsNone(self.w.inventory)
        self.w.accept(inv(6, [9], excluded=1))
        self.assertIsNone(self.w.inventory)
        self.w.accept(inv(7, []))
        self.assertEqual(self.w.summary()["inventory_entries"], 0)

    def test_bad_delta_revokes_atomically(self):
        self.w.accept(inv(2, [1]))
        with self.assertRaises(ProtocolError):
            self.w.accept(change(3, 1, 0, 2))
        self.assertIsNone(self.w.inventory)
        self.assertEqual(self.w.summary()["current_fact_types"], [])

    def test_bad_identity_duplicate_and_invalid_number(self):
        for bad in (menu(1), obs("COMBAT_STATE", {"in_combat": True}, 2, session=USER),
                    obs("PLAYER_POSITION", {"x": 10**400, "y": 0, "z": 0}, 2),
                    obs("NOT_SUPPORTED", {}, 2)):
            w = Window()
            w.accept(menu(1))
            with self.assertRaises(ProtocolError):
                w.accept(bad)
            self.assertEqual(w.summary()["current_fact_types"], [])

    def test_fragmented_loopback_and_malformed_frame(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            w = Window()
            def serve():
                conn, _ = listener.accept()
                with conn:
                    serve_connection(conn, w, idle_timeout=2)
            thread = threading.Thread(target=serve)
            thread.start()
            try:
                with socket.create_connection(listener.getsockname(), timeout=2) as conn:
                    def encoded(row):
                        return json.dumps(row).encode() + b"\n"
                    packet = encoded(menu(1))
                    conn.sendall(packet[:17])
                    conn.sendall(packet[17:] + encoded(heartbeat()))
                    with conn.makefile("rb") as stream:
                        self.assertEqual(json.loads(stream.readline()), {"status": "accepted", "message_id": menu(1)["message_id"]})
                        self.assertEqual(json.loads(stream.readline()), {"status": "heartbeat", "session_id": SID})
                        conn.sendall(b'{"bad":1,"bad":2}\n')
                        self.assertEqual(json.loads(stream.readline()), {"status": "rejected", "error": "invalid_frame"})
                        self.assertEqual(stream.readline(), b"")
            finally:
                thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(w.summary()["current_fact_types"], [])


if __name__ == "__main__":
    unittest.main()
