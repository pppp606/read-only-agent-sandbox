import importlib.util
import unittest
spec = importlib.util.spec_from_file_location("gates", "host/check_gates.py")
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)

class GateTests(unittest.TestCase):
    def test_missing_fails(self):
        self.assertFalse(gates.evaluate({})[0])

    def test_all_pass_with_evidence(self):
        data = {k: {"status": "pass", "evidence": "manual log ref"} for k in gates.REQUIRED}
        self.assertTrue(gates.evaluate(data)[0])

    def test_empty_evidence_fails(self):
        data = {k: {"status": "pass", "evidence": "manual log ref"} for k in gates.REQUIRED}
        data["G2_egress_guest_root"]["evidence"] = ""
        self.assertFalse(gates.evaluate(data)[0])

    def test_unexpected_gate_fails(self):
        data = {k: {"status": "pass", "evidence": "x"} for k in gates.REQUIRED}
        data["extra"] = {"status": "pass", "evidence": "x"}
        self.assertFalse(gates.evaluate(data)[0])

if __name__ == "__main__":
    unittest.main()
