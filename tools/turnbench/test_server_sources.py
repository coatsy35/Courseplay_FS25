"""Regression for the live server losing bench modules after a branch switch."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import server


class SourceValidationTests(unittest.TestCase):
    def test_current_bench_checkout_has_all_model_sources(self):
        server.validate_model_sources()

    def test_missing_module_returns_actionable_error_without_running_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = root / 'alignment.py'
            module.write_text('# model')
            with patch.object(server, 'ROOT', root), patch.object(server, 'SOURCES', ['alignment.py']):
                server.validate_model_sources()
                module.unlink()
                handler = object.__new__(server.Handler)
                handler.path = '/api/simulate'
                handler.headers = {'Content-Length': '2', 'Content-Type': 'application/json'}
                handler.rfile = io.BytesIO(b'{}')
                handler.local_request = lambda: True
                responses = []
                handler.send = lambda status, body: responses.append((status, json.loads(body)))
                with patch.object(server, 'compare') as compare:
                    handler.do_POST()
                    compare.assert_not_called()
                self.assertEqual(responses[0][0], 409)
                self.assertIn('alignment.py', responses[0][1]['error'])
                self.assertIn('codex/turnbench', responses[0][1]['error'])


if __name__ == '__main__':
    unittest.main()
