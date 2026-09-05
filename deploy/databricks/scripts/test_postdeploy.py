import json
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

postdeploy = runpy.run_path(str(Path(__file__).with_name("postdeploy.py")))["postdeploy"]


class PostdeployTests(unittest.TestCase):
    def test_registers_model_with_rest_body(self):
        source = {"config": {"routing": {"destinations": [{
            "destination_type": "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL",
            "pay_per_token_config": {"model": "models/system.ai.gpt-5-6-luna"},
        }]}}}
        with patch("subprocess.run", side_effect=[
            subprocess.CompletedProcess([], 0, "{}", ""),
            subprocess.CompletedProcess([], 0, json.dumps(source), ""),
            subprocess.CompletedProcess([], 0, "{}", ""),
        ]) as cli:
            postdeploy("test", "test", "db-test")
        calls = [call.args[0] for call in cli.call_args_list]
        self.assertEqual(calls[0][2:4], ["post", "/api/2.0/postgres/projects/db-test/search-extensions"])
        self.assertEqual(calls[1][2:4], ["get", "/api/2.1/unity-catalog/model-services/system.ai.gpt-5-6-luna"])
        self.assertEqual(calls[2][2], "post")
        self.assertEqual(parse_qs(urlsplit(calls[2][3]).query), {
            "parent": ["schemas/test.ai"], "model_service_id": ["gpt-5-6-luna"],
        })
        self.assertEqual(calls[2][4:8], ["--profile", "test", "--output", "json"])
        # REST takes the ModelService itself, not the SDK request envelope.
        self.assertEqual(json.loads(calls[2][9]), {"config": {"routing": {"destinations": [{
            "name": "primary",
            "destination_type": "DESTINATION_TYPE_PAY_PER_TOKEN_FOUNDATION_MODEL",
            "pay_per_token_config": {"model": "models/system.ai.gpt-5-6-luna"},
            "traffic_percentage": 100,
        }]}}})

    def test_stops_on_cli_error_without_exposing_diagnostics(self):
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 1, "", "private details")) as cli:
            with self.assertRaisesRegex(RuntimeError, "Databricks post failed") as caught:
                postdeploy("test", "test", "db-test")
        self.assertNotIn("private", str(caught.exception))
        cli.assert_called_once()


if __name__ == "__main__":
    unittest.main()
