"""Static guard for the CLT 27 SwiftUI State macro/property-wrapper collision."""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
AMBIGUOUS_STATE = re.compile(r'@\s*(?:SwiftUI\s*\.\s*)?State\b')
ALIAS = re.compile(r'typealias VellaState<Value> = SwiftUI\.State<Value>')


class StateCompatibilityTests(unittest.TestCase):
    def test_app_avoids_ambiguous_state_attributes(self):
        for path in sorted((ROOT / 'Sources/Vella').glob('*.swift')):
            # Comments may explain the broken spelling; they are not attributes.
            code = re.sub(r'/\*.*?\*/|//[^\n]*', '', path.read_text(), flags=re.S)
            with self.subTest(source=path.name):
                self.assertIsNone(AMBIGUOUS_STATE.search(code),
                                  'Use @VellaState, not the SDK 27 State macro')

    def test_guard_rejects_qualified_and_generic_spellings(self):
        for spelling in ('@State', '@State<Bool>', '@SwiftUI.State',
                         '@SwiftUI.State<Bool>'):
            self.assertIsNotNone(AMBIGUOUS_STATE.search(spelling))
        for spelling in ('@VellaState', '@StateObject', '@ObservedObject'):
            self.assertIsNone(AMBIGUOUS_STATE.search(spelling))

    def test_standalone_fixture_matches_production_alias(self):
        for relative in ('Sources/Vella/StateCompatibility.swift',
                         'Tests/StateCompatibilityFixture.swift'):
            with self.subTest(source=relative):
                self.assertEqual(len(ALIAS.findall((ROOT / relative).read_text())), 1)


if __name__ == '__main__':
    unittest.main()
