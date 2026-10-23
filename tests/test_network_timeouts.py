import contextlib
import importlib.util
import io
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

import requests


ROOT = Path(__file__).resolve().parents[1]


def load_isolated_module(name, dependencies):
    """Exercise HTTP handling without credentials, OCR models or real services."""
    spec = importlib.util.spec_from_file_location(name, ROOT / (name.replace(".", "/") + ".py"))
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, dependencies):
        spec.loader.exec_module(module)
    return module


class NetworkTimeoutTests(unittest.TestCase):
    def assert_bounded_request(self, call):
        self.assertEqual((5, 15), call.kwargs.get("timeout"),
                         "HTTP requests need explicit connection and read timeouts")

    def test_query_timeout_aborts_without_retrying(self):
        module = load_isolated_module("util.enncy", {
            "config": types.SimpleNamespace(enncy_key="test-key"),
            "util.ocr": types.SimpleNamespace(ocr_form_url_image=mock.Mock()),
        })
        for error_type in (requests.ConnectTimeout, requests.ReadTimeout):
            with self.subTest(error=error_type.__name__), \
                    mock.patch.object(requests, "get", side_effect=error_type("private-token")) as get:
                with self.assertRaises(error_type):
                    module.search("test question")
                get.assert_called_once()
                self.assert_bounded_request(get.call_args)

    def test_image_timeout_aborts_before_decoding_or_ocr(self):
        decoder = mock.Mock()
        model = mock.Mock()
        module = load_isolated_module("util.ocr", {
            "paddleocr": types.SimpleNamespace(PaddleOCR=mock.Mock(return_value=model)),
            "cv2": decoder,
            "numpy": mock.Mock(),
        })
        for error_type in (requests.ConnectTimeout, requests.ReadTimeout):
            output = io.StringIO()
            with self.subTest(error=error_type.__name__), \
                    contextlib.redirect_stdout(output), \
                    mock.patch.object(requests, "get", side_effect=error_type("private-token")) as get:
                with self.assertRaises(error_type):
                    module.ocr_form_url_image("https://example.invalid/image")
                get.assert_called_once()
                self.assert_bounded_request(get.call_args)
                decoder.imdecode.assert_not_called()
                model.ocr.assert_not_called()
                self.assertNotIn("private-token", output.getvalue())


if __name__ == "__main__":
    unittest.main()
