import io
import json
import unittest
from expanded_reader import ExpandedReader, scan
from expanded_contract import CONTRACT, tid, tid_label

SID="12345678-1234-4234-8234-123456789abc"

def row(seq,kind,source,data,availability="OBSERVED",reason=None,generation=1):
    r={"contract":CONTRACT,"producer_session":SID,"generation":generation,
       "sequence":seq,"elapsed_ms":seq-1,"kind":kind,"source":source,
       "availability":availability,"data":data}
    if reason:r["reason"]=reason
    return r

def session(seq,ready,generation=1):
    return row(seq,"SESSION","Producer.lifecycle",{"ready":ready},generation=generation)

def progression(seq,n):
    return row(seq,"PROGRESSION","PlayerDevelopmentSystem.GetDevelopmentData",
               {"complete":True,"perks_complete":True,"source_count":n,
                "perks":[{"attribute_type":i%6,"perk_type":i,"level":1} for i in range(n)]})

class ExpandedTests(unittest.TestCase):
    def test_194_and_93(self):
        r=ExpandedReader()
        r.accept(session(1,True))
        r.accept(progression(2,93));r.accept(progression(3,194))
        r.accept(session(4,False))
        s=r.summary()
        self.assertEqual((s["complete_perk_reads"],s["max_complete_perks"]),(2,194))
        self.assertEqual(s["capture_integrity"],"CLOSED_NO_RECORDED_LOSS")

    def test_over_bound_rejected_and_revoked(self):
        r=ExpandedReader();r.accept(session(1,True))
        with self.assertRaises(ValueError):r.accept(progression(2,195))
        self.assertFalse(r.host.replay.ready)
        self.assertEqual(r.summary()["capture_integrity"],"INCOMPLETE")

    def test_missing_close_not_erased_by_rearm(self):
        r=ExpandedReader();r.accept(session(1,True));r.accept(session(1,True,2));r.accept(session(2,False,2))
        s=r.summary()
        self.assertEqual(s["superseded_unclosed_generations"],1)
        self.assertEqual(s["capture_integrity"],"INCOMPLETE")

    def test_explicit_reference_loss(self):
        from expanded_contract import SOURCES
        r=ExpandedReader();r.accept(session(1,True))
        r.accept(row(2,"SOURCE_GAP",sorted(SOURCES["SOURCE_GAP"])[0],{"count":7},"UNKNOWN","INVENTORY_REFERENCE_GAP"))
        r.accept(session(3,False))
        self.assertEqual(r.summary()["unoffered_reference_count"],7)
        self.assertEqual(r.summary()["capture_integrity"],"INCOMPLETE")

    def test_missing_gap_reason_rejected(self):
        from expanded_contract import SOURCES
        r=ExpandedReader();r.accept(session(1,True))
        with self.assertRaises(ValueError):
            r.accept(row(2,"SOURCE_GAP",sorted(SOURCES["SOURCE_GAP"])[0],{"count":7}))
        self.assertEqual(r.summary()["rejections"],1)
        self.assertFalse(r.host.replay.ready)

    def test_reference_pending_not_lost(self):
        from expanded_contract import SOURCES
        r=ExpandedReader();r.accept(session(1,True))
        ref={"record_id":"Items.SyntheticExample","record_ref":tid_label(tid("Items.SyntheticExample"))}
        r.accept(row(2,"STATIC_RECORD_REFERENCES",sorted(SOURCES["STATIC_RECORD_REFERENCES"])[0],{"records":[ref]}))
        r.accept(session(3,False))
        self.assertEqual(r.summary()["distinct_reference_offers"],1)
        self.assertEqual(r.summary()["capture_integrity"],"CLOSED_NO_RECORDED_LOSS")

    def test_order_and_duplicate_key(self):
        r=ExpandedReader();r.accept(session(1,True))
        with self.assertRaises(ValueError):r.accept(session(3,False))
        with self.assertRaises(ValueError):r.accept_json(b'{"kind":"a","kind":"b"}')
        self.assertEqual(r.summary()["rejections"],2)

    def test_log_only_and_partial_tail(self):
        prefix=b"[DeepBideTelemetry] CANDIDATE_JSON="
        def line(r):return prefix+json.dumps(r).encode()+b"\n"
        x=ExpandedReader()
        self.assertEqual(scan(io.BytesIO(b"other module\n"+line(session(1,True))+line(session(2,False))),x,"cet")["capture_integrity"],"CLOSED_NO_RECORDED_LOSS")
        x=ExpandedReader()
        with self.assertRaises(ValueError):scan(io.BytesIO(line(session(1,True))[:-1]),x,"cet")
        self.assertEqual(x.summary()["rejections"],1)

    def test_closed_capture_is_not_live_fact(self):
        r=ExpandedReader();r.accept(session(1,True));r.accept(session(2,False))
        self.assertFalse(r.summary()["ready"])
        self.assertEqual(r.summary()["scope"],"OFFLINE_CAPTURE_NOT_LIVE_IDENTITY_OR_SEMANTIC_COMPLETENESS")

if __name__=="__main__":unittest.main()
