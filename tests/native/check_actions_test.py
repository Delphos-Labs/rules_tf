"""The graph check must reject required compilers, not unrelated packaging."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from check_actions import native_actions


class NativeActionClosureTest(unittest.TestCase):
    def graph(self, required):
        return {
            "actions": [
                {"mnemonic": "TestRunner", "inputDepSetIds": ["1"]},
                {"mnemonic": "FileWrite", "outputIds": ["script"]},
                {"mnemonic": "CppCompile", "outputIds": ["compiled"]},
            ],
            "depSetOfFiles": [
                {"id": "1", "directArtifactIds": ["script"], "transitiveDepSetIds": ["2"]},
                {"id": "2", "directArtifactIds": required},
            ],
        }

    def test_unrelated_packaging_compilation_is_not_in_execution_closure(self):
        self.assertEqual({a["mnemonic"] for a in native_actions(self.graph([]))}, {"TestRunner", "FileWrite"})

    def test_transitive_compilation_is_in_execution_closure(self):
        self.assertIn("CppCompile", {a["mnemonic"] for a in native_actions(self.graph(["compiled"]))})

    def test_empty_graph_cannot_establish_native_execution(self):
        with self.assertRaisesRegex(ValueError, "no native TestRunner"):
            list(native_actions({"actions": []}))

    def test_command_rejects_required_compilation_and_linking(self):
        checker = Path(__file__).with_name("check_actions.py")
        with tempfile.TemporaryDirectory() as directory:
            graph_path = Path(directory) / "actions.json"
            for mnemonic in ["CppCompile", "CppLink"]:
                with self.subTest(mnemonic=mnemonic):
                    graph = self.graph(["compiled"])
                    graph["actions"][2]["mnemonic"] = mnemonic
                    graph_path.write_text(json.dumps(graph))
                    result = subprocess.run(
                        [sys.executable, "-B", str(checker), str(graph_path)],
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("compiles or links", result.stderr)
                    self.assertIn(mnemonic, result.stdout)


if __name__ == "__main__":
    unittest.main()
