"""Transient HTTP failures retry; pinned-content and protocol failures do not."""
import contextlib
import io
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from unittest.mock import Mock, patch

import requests

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fetchers'))
import common as C


def response(status=200, content=b'audio', headers=None):
    result = requests.Response()
    result.status_code = status
    result.url = 'https://example.test/audio'
    result._content = content
    result._content_consumed = True
    result.headers.update(headers or {})
    return result


class HttpRetryTest(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory())
        self.ctx = C.Context(Path(directory), 'fixture')
        self.session = Mock(spec=requests.Session)
        self.now = 0.0
        self.sleeps = []
        self.enterContext(patch.object(C.time, 'monotonic', side_effect=lambda: self.now))
        self.enterContext(patch.object(C.time, 'sleep', side_effect=self.sleep))
        self.enterContext(patch.object(C.random, 'uniform', return_value=1.5))
        self.output = self.enterContext(contextlib.redirect_stderr(io.StringIO()))

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def get(self, **kwargs):
        return self.ctx.http_request('https://example.test/audio?secret=hidden', session=self.session, **kwargs)

    def test_retry_then_succeed_for_each_transient_status(self):
        for status in sorted(C.HTTP_RETRY_STATUSES):
            with self.subTest(status=status):
                self.session.reset_mock()
                failed = response(status)
                failed.close = Mock()
                self.session.request.side_effect = [failed, response()]
                self.assertEqual(self.get().content, b'audio')
                self.assertEqual(self.session.request.call_count, 2)
                failed.close.assert_called_once()
        lines = self.output.getvalue().splitlines()
        self.assertEqual(len(lines), len(C.HTTP_RETRY_STATUSES))
        self.assertTrue(all('fetch retry 2/4:' in line for line in lines))
        self.assertNotIn('secret', self.output.getvalue())

    def test_connection_reset_and_timeout_retry_then_succeed(self):
        for error in [requests.ConnectionError('connection reset'), requests.Timeout('timed out')]:
            with self.subTest(error=type(error).__name__):
                self.session.reset_mock()
                self.session.request.side_effect = [error, response()]
                self.assertEqual(self.get().content, b'audio')
                self.assertEqual(self.session.request.call_count, 2)

    def test_give_up_after_four_attempts_with_exponential_backoff(self):
        self.session.request.side_effect = [response(502) for _ in range(4)]
        with self.assertRaises(requests.HTTPError):
            self.get()
        self.assertEqual(self.session.request.call_count, 4)
        self.assertEqual(self.sleeps, [1.5, 3.0, 6.0])
        self.assertEqual(len(self.output.getvalue().splitlines()), 3)

    def test_no_retry_on_404(self):
        self.session.request.return_value = response(404)
        with self.assertRaises(requests.HTTPError):
            self.get()
        self.assertEqual(self.session.request.call_count, 1)
        self.assertEqual(self.sleeps, [])

    def test_no_retry_on_tls_verification_error(self):
        self.session.request.side_effect = requests.exceptions.SSLError('certificate mismatch')
        with self.assertRaises(requests.exceptions.SSLError):
            self.get()
        self.assertEqual(self.session.request.call_count, 1)

    def test_retry_after_seconds(self):
        self.session.request.side_effect = [response(429, headers={'Retry-After': '7'}), response()]
        self.get()
        self.assertEqual(self.sleeps, [7.0])

    def test_retry_after_http_date(self):
        date = format_datetime(datetime.fromtimestamp(1007, timezone.utc), usegmt=True)
        self.session.request.side_effect = [response(503, headers={'Retry-After': date}), response()]
        with patch.object(C.time, 'time', return_value=1000):
            self.get()
        self.assertEqual(self.sleeps, [7.0])

    def test_invalid_retry_after_uses_backoff(self):
        self.session.request.side_effect = [response(503, headers={'Retry-After': 'invalid'}), response()]
        self.get()
        self.assertEqual(self.sleeps, [1.5])

    def test_retry_after_beyond_budget_gives_up_without_retrying_early(self):
        self.session.request.return_value = response(429, headers={'Retry-After': '61'})
        with self.assertRaises(requests.HTTPError):
            self.get()
        self.assertEqual(self.session.request.call_count, 1)
        self.assertEqual(self.sleeps, [])

    def test_elapsed_request_time_counts_against_budget(self):
        def slow_failure(*args, **kwargs):
            connect, read = kwargs['timeout']
            self.assertLessEqual(connect + read, 60 - self.now)
            self.now += 20
            raise requests.Timeout('timed out')
        self.session.request.side_effect = slow_failure
        with self.assertRaises(requests.Timeout):
            self.get()
        self.assertEqual(self.session.request.call_count, 3)
        self.assertEqual(self.sleeps, [1.5, 3.0])

    def test_no_retry_on_hash_mismatch_including_cached_file(self):
        self.session.request.return_value = response()
        with patch.object(requests, 'request', side_effect=self.session.request):
            for _ in range(2):
                with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                    self.ctx.http_file('https://example.test/audio', sha256='0' * 64)
        self.assertEqual(self.session.request.call_count, 1)
        self.assertEqual(self.sleeps, [])

    def test_interrupted_stream_restarts_file_without_partial_bytes(self):
        broken = response()
        def blocks(_):
            yield b'partial'
            raise requests.exceptions.ChunkedEncodingError('connection reset')
        broken.iter_content = blocks
        self.session.request.side_effect = [broken, response(content=b'complete')]
        with patch.object(requests, 'request', side_effect=self.session.request):
            path = self.ctx.http_file('https://example.test/audio', sha256=C.sha_bytes(b'complete'))
        self.assertEqual(path.read_bytes(), b'complete')
        self.assertFalse(path.with_suffix('.part').exists())
        self.assertEqual(self.session.request.call_count, 2)

    def test_failed_stream_leaves_no_file(self):
        broken = response()
        broken.iter_content = Mock(side_effect=requests.Timeout('timed out'))
        self.session.request.return_value = broken
        with patch.object(requests, 'request', side_effect=self.session.request):
            with self.assertRaises(requests.Timeout):
                self.ctx.http_file('https://example.test/audio')
        self.assertEqual(list((self.ctx.cache / 'http').iterdir()), [])

    def test_range_protocol_mismatch_is_not_retried(self):
        self.session.request.return_value = response(200)
        with patch.object(requests, 'request', side_effect=self.session.request):
            with self.assertRaisesRegex(ValueError, 'range request not honoured'):
                self.ctx.http_range('https://example.test/audio', 0, 4)
        self.assertEqual(self.session.request.call_count, 1)


if __name__ == '__main__':
    unittest.main()
