"""CPU-only production Session benchmark contract tests; never loads weights."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Resources'))
import streaming_benchmark_worker as b


class Fake:
    def __init__(self, silent=False):
        self.silent = silent
        self.resets = 0
        self.blocks = []
        self.reset()

    def reset(self):
        self.resets += 1
        self.text = ''

    def push(self, samples, final=False):
        self.blocks.append((len(samples), final))
        if samples and not self.silent:
            self.text = 'Hello world.'

    def drain(self, final=False):
        if final:
            text, self.text = self.text, ''
            return text
        return ''


class BenchmarkTests(unittest.TestCase):
    def test_exact_packets_short_tail_and_finish(self):
        native = Fake()
        packets = b.requests([.1] * 3207)
        self.assertEqual([x[0] for x in packets], [1600, 1600, 7])
        result = b.replay(native, packets)
        self.assertEqual(result['frames'], 3207)
        self.assertEqual(result['transcript'], 'Hello world.')
        self.assertTrue(result['prefixAppendOnly'])
        self.assertEqual(native.blocks[-2:], [(7, False), (0, True)])
        self.assertEqual(sum(n for n, _ in native.blocks), 3207)
        self.assertTrue(result['events'][-1]['done'])

    def test_reset_weights_reused(self):
        native = Fake()
        packets = b.requests([.1] * 1600)
        first = b.replay(native, packets)
        second = b.replay(native, packets)
        self.assertEqual(first['transcript'], second['transcript'])
        self.assertEqual(first['frames'], second['frames'])
        self.assertEqual(native.resets, 5)  # initial + clip start + endpoint per pass

    def test_empty_model_output_is_complete_and_scored(self):
        result = b.replay(Fake(silent=True), b.requests([.1] * 3200))
        self.assertFalse(result['incomplete'])
        self.assertEqual(result['transcript'], '')
        self.assertGreater(b.errors('Hello world', result['transcript'])[0], 0)
        self.assertGreater(b.formatting.score('Hello world', result['transcript'])['characterErrors'], 0)

    def test_endpoint_and_preroll_are_production(self):
        native = Fake()
        samples = [0.] * 6400 + [.1] * 3200 + [0.] * 12800 + [.1] * 1600
        result = b.replay(native, b.requests(samples))
        self.assertEqual(result['transcript'], 'Hello world. Hello world.')
        self.assertTrue(result['prefixAppendOnly'])
        self.assertEqual(sum(final for _, final in native.blocks), 2)

    def test_prefix_revision_retained_but_disqualified(self):
        text = b.Transcript()
        text.accept(dict(frames=10, partial='hello'), 10)
        text.accept(dict(frames=20, partial='hullo'), 20)
        self.assertFalse(text.prefix_ok)
        self.assertEqual(text.text, 'hullo')
        self.assertFalse(text.events[-1]['prefixAppendOnly'])

    def test_actual_join_no_postprocessing(self):
        text = b.Transcript()
        text.accept(dict(frames=0, committed='  Hello!  ', partial=' world '), 0)
        self.assertEqual(text.text, 'Hello!  world ')
        with self.assertRaises(ValueError):
            text.accept(dict(frames=1), 0)

    def test_busy_guard_fails_closed(self):
        root = Path(__file__).resolve().parents[1] / '.build/qa/streaming-benchmark'
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as folder:
            path = Path(folder) / 'status.json'
            for phase in ('preparing', 'recording', 'transcribing', 'unknown'):
                path.write_text(json.dumps(dict(phase=phase)))
                with self.assertRaises(RuntimeError):
                    b.idle(path)
            path.write_text('{"phase":"idle"}')
            b.idle(path)
            path.unlink()
            with self.assertRaises(FileNotFoundError):
                b.idle(path)

    def test_frozen_complete_corpus(self):
        manifest, policy = b.frozen_suite(b.ROOT / 'Benchmarks/english-formatted-20m-v1')
        self.assertEqual(len(manifest['clips']), 144)
        self.assertEqual(policy['scorerSHA256'], b.formatting.SCORER_SHA256)

    def test_memory_attachment_preserves_timing_and_checks_identity(self):
        timing = {key: 'same' for key in (
            'recognitionMode', 'streamingQualified', 'modelID', 'modelFingerprint',
            'suiteID', 'suiteHash', 'audioHashes', 'machine', 'machineMemoryBytes',
            'os', 'mlxAudioVersion', 'mlxVersion', 'parameters',
            'streamingWorkerSHA256', 'driverSHA256', 'benchmarkWorkerSHA256')}
        timing.update(measurementKind='timing', complete=True, repeats=2,
                      transcriptionSeconds=42, clips=['untouched'], runtimePeakMLXBytes=9)
        memory = dict(timing, measurementKind='memory', repeats=1,
                      measuredAt='today', runtimePeakMLXBytes=10, memoryProtocol=b.MEMORY_PROTOCOL,
                      peakMLXBytes=12, peakProcessBytes=20)
        result = b.attach_memory(timing, memory)
        self.assertEqual(result['transcriptionSeconds'], 42)
        self.assertEqual(result['clips'], ['untouched'])
        self.assertEqual(result['repeats'], 2)
        self.assertEqual(result['runtimePeakMLXBytes'], 10)
        self.assertEqual(timing['runtimePeakMLXBytes'], 9)
        memory['modelFingerprint'] = 'different'
        with self.assertRaisesRegex(ValueError, 'modelFingerprint'):
            b.attach_memory(timing, memory)


if __name__ == '__main__':
    unittest.main()
