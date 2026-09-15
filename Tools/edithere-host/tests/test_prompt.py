"""Golden tests for the host-owned canonical prompt."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from edithere_host.prompt import batch_prompt, execution_prompt  # noqa: E402

FIXTURE = Path(__file__).resolve().parents[3] / "Fixtures" / "gate1" / "package" / "manifest.json"


class PromptBuilderTests(unittest.TestCase):
    def test_gate1_fixture_matches_current_swift_rules(self) -> None:
        package = json.loads(FIXTURE.read_text(encoding="utf-8"))
        text = batch_prompt(package)
        self.assertIn("App: EditHere Sample", text)
        self.assertIn("Page 1 · sample-home — marks 1, 2, 3, 4, 5", text)
        self.assertIn("Rename the title to \"Recently used\"", text)
        self.assertIn("Remove the marked element from the product.", text)
        self.assertIn("On screen: Promo card", text)
        self.assertIn("This mark is a numbered point", text)
        self.assertNotIn("Prompt template", text)
        self.assertNotIn("cssSelector", text)
        self.assertNotIn("localhost", text)
        envelope = execution_prompt(package)
        self.assertTrue(envelope.startswith("Page 1: page-1.png\n\n"))
        self.assertIn(text, envelope)

    def test_web_hints_are_stored_not_printed(self) -> None:
        package = {
            "app": {"displayName": "Local app"},
            "overallInstruction": "",
            "captures": [
                {
                    "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "screenID": "/settings",
                }
            ],
            "annotations": [
                {
                    "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                    "captureID": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "selectionKind": "bounds",
                    "action": "customRequest",
                    "requestText": "Make the save button green",
                    "targetHint": {
                        "visibleText": "Save",
                        "className": "BUTTON",
                        "cssSelector": "form > button.save",
                        "pageURL": "http://127.0.0.1:3000/settings",
                        "sourceFile": "src/SaveBar.tsx",
                        "sourceLine": 42,
                    },
                }
            ],
        }
        text = batch_prompt(package)
        self.assertIn("On screen: Save", text)
        self.assertIn("Make the save button green", text)
        self.assertNotIn("form > button.save", text)
        self.assertNotIn("SaveBar.tsx", text)
        self.assertNotIn("127.0.0.1", text)
        self.assertNotIn("Control: button", text)

    def test_html_tag_control_kind_when_no_visible_text(self) -> None:
        package = {
            "app": {"displayName": "App"},
            "captures": [{"id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "screenID": "home"}],
            "annotations": [
                {
                    "captureID": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                    "selectionKind": "bounds",
                    "action": "removeElement",
                    "requestText": "",
                    "targetHint": {"className": "button"},
                }
            ],
        }
        text = batch_prompt(package)
        self.assertIn("Control: button", text)
        self.assertIn("Remove the marked element from the product.", text)


if __name__ == "__main__":
    unittest.main()
