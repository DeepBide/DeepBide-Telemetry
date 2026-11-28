"""Public clock protocol regression tests; no game or private data."""
import unittest
from receiver import Window, ProtocolError
from test_receiver import obs, menu, heartbeat

def reading(n, seconds=42*86400+17*3600+35*60, **overrides):
    p={"contract_version":"0.1","sample_seq":n,"availability":"OBSERVED",
       "day":seconds//86400,"hour":seconds//3600%24,"minute":seconds//60%60,
       "minute_of_day":seconds//60%1440,"second":seconds%60,"world_seconds":seconds,
       "precision":"SECOND","continuity":"INITIAL","clock_change":"NO_COMPARISON",
       "skip_finish_callback_seen":False}
    p.update(overrides)
    return p

class ClockConsumer(unittest.TestCase):
    def setUp(self):
        self.now=0
        self.w=Window(ttl=10,clock=lambda:self.now)
        self.w.accept(menu(1))

    def offer(self,p,n=2):
        return self.w.accept(obs("WORLD_TIME",p,n))

    def test_clock_and_heartbeat_do_not_extend_ttl(self):
        self.offer(reading(1))
        self.assertEqual(self.w.facts["WORLD_TIME"][1]["minute_of_day"],1055)
        self.now=1.9
        self.w.accept(heartbeat())
        self.assertIn("WORLD_TIME",self.w.summary()["current_fact_types"])
        self.now=2
        self.assertNotIn("WORLD_TIME",self.w.summary()["current_fact_types"])

    def test_menu_revocation_and_new_sample(self):
        self.offer(reading(1))
        self.w.accept(obs("MENU_STATE",{"is_menu":True,"is_loading":False,
                                       "normalized_category":"pause"},3))
        self.assertNotIn("WORLD_TIME",self.w.summary()["current_fact_types"])
        self.offer({"contract_version":"0.1","sample_seq":2,"availability":"UNAVAILABLE","reason":"menu"},4)
        self.w.accept(menu(5))
        self.offer(reading(3,continuity="AFTER_MENU",delta_world_seconds=0,clock_change="UNCHANGED"),6)
        self.assertIn("WORLD_TIME",self.w.summary()["current_fact_types"])

    def test_loading_and_boundary(self):
        self.offer(reading(1))
        self.w.accept(menu(3,True))
        self.offer({"contract_version":"0.1","sample_seq":2,"availability":"UNAVAILABLE","reason":"loading"},4)
        self.w.accept(menu(5))
        self.offer(reading(3,3600,continuity="AFTER_WORLD_BOUNDARY"),6)
        self.assertEqual(self.w.facts["WORLD_TIME"][1]["day"],0)
        self.w.close()
        self.assertNotIn("WORLD_TIME",self.w.summary()["current_fact_types"])

    def test_minute_only_and_unknown_day(self):
        p=reading(1)
        for k in ("day","second","world_seconds"):del p[k]
        p["precision"]="MINUTE"
        self.offer(p)
        self.assertNotIn("day",self.w.facts["WORLD_TIME"][1])

    def test_failed_read_revokes_only_clock(self):
        self.offer(reading(1))
        self.offer({"contract_version":"0.1","sample_seq":2,"availability":"UNAVAILABLE","reason":"read_error"},3)
        self.assertEqual(self.w.summary()["current_fact_types"],["MENU_STATE"])

    def test_malformed_and_bad_order_fail_closed(self):
        for patch in ({"minute":60},{"hour":True},{"day":-1},{"world_seconds":0},
                      {"sample_seq":2},{"clock_change":"SLEEP"},{"playthrough_seconds":float("nan")},
                      {"delta_world_seconds":3600},{"skip_finish_callback_seen":1},{"cause":"SLEEP"}):
            w=Window();w.accept(menu(1))
            with self.assertRaises(ProtocolError,msg=str(patch)):
                w.accept(obs("WORLD_TIME",reading(1,**patch),2))
            self.assertEqual(w.summary()["current_fact_types"],[])

    def test_observed_in_menu_rejected(self):
        self.w.accept(obs("MENU_STATE",{"is_menu":True,"is_loading":False,"normalized_category":"map"},3))
        with self.assertRaises(ProtocolError):self.offer(reading(1),4)

    def test_sequence_and_raw_jump(self):
        self.offer(reading(1))
        self.offer(reading(2,seconds=42*86400+18*3600+35*60,continuity="AFTER_MENU",delta_world_seconds=3600,clock_change="LARGE_FORWARD",
                           skip_finish_callback_seen=True),3)
        with self.assertRaises(ProtocolError):self.offer(reading(2),4)

if __name__=="__main__":unittest.main()
