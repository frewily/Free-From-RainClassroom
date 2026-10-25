import os
from pathlib import Path
import runpy
import unittest
from unittest import mock


CONFIG = Path(__file__).resolve().parents[1] / "config.py"


class ConfigTests(unittest.TestCase):
    def test_environment_mode_does_not_open_local_config(self):
        with mock.patch.dict(os.environ, {
            "SESSION": "test-session", "AI_KEY": "test-ai", "ENNCY_KEY": "test-enncy",
        }, clear=True), mock.patch("util.file.read", side_effect=FileNotFoundError("config.ini")) as read:
            config = runpy.run_path(str(CONFIG))
        read.assert_not_called()
        self.assertEqual("test-session", config["sessionId"])
        self.assertEqual("test-ai", config["ai_key"])
        self.assertEqual("test-enncy", config["enncy_key"])
        self.assertEqual({"Cookie": "sessionid=test-session"}, config["headers"])

    def test_local_mode_still_uses_file_values(self):
        # Exercise the documented source switch without changing any project file.
        source = CONFIG.read_text().replace("isLocal = False", "isLocal = True", 1)
        config = {}
        lines = ['SESSION="local-session"', 'AI_KEY="local-ai"', 'ENNCY_KEY="local-enncy"']
        with mock.patch.dict(os.environ, {"SESSION": "unused-env-session"}, clear=True), \
                mock.patch("util.file.read", return_value=lines) as read:
            exec(compile(source, str(CONFIG), "exec"), config)
        read.assert_called_once_with("config.ini")
        self.assertEqual("local-session", config["sessionId"])
        self.assertEqual("local-ai", config["ai_key"])
        self.assertEqual("local-enncy", config["enncy_key"])


if __name__ == "__main__":
    unittest.main()
