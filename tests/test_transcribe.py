from __future__ import annotations

import base64
import json
import tempfile
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

from codex_asr.config import Config
from codex_asr.transcribe import (
    _account_id_from_jwt,
    _multipart,
    CodexAuth,
    load_codex_auth,
    transcribe,
)


def _jwt(claims: dict[str, object]) -> str:
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return f"header.{payload}.signature"


class AuthTests(unittest.TestCase):
    def test_loads_chatgpt_token(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "auth.json"
            path.write_text(
                json.dumps(
                    {
                        "auth_mode": "chatgpt",
                        "tokens": {
                            "access_token": "secret-token",
                            "account_id": "acct_test",
                        },
                    }
                )
            )
            auth = load_codex_auth(path)
        self.assertEqual(auth.access_token, "secret-token")
        self.assertEqual(auth.account_id, "acct_test")

    def test_rejects_api_key_auth(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "auth.json"
            path.write_text(json.dumps({"auth_mode": "apikey"}))
            with self.assertRaisesRegex(RuntimeError, "not ChatGPT login"):
                load_codex_auth(path)

    def test_decodes_account_id_from_jwt(self) -> None:
        token = _jwt(
            {"https://api.openai.com/auth": {"chatgpt_account_id": "acct_nested"}}
        )
        self.assertEqual(_account_id_from_jwt(token), "acct_nested")


class MultipartTests(unittest.TestCase):
    def test_request_contains_audio_and_language_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            audio = Path(directory) / "speech.wav"
            audio.write_bytes(b"RIFF-audio")
            body, boundary = _multipart(audio, "en")
        self.assertIn(f"--{boundary}".encode(), body)
        self.assertIn(b'name="language"', body)
        self.assertIn(b'name="file"; filename="speech.wav"', body)
        self.assertIn(b"RIFF-audio", body)
        self.assertNotIn(b"model", body)

    def test_transcribe_uses_codex_headers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            auth_path = root / "auth.json"
            auth_path.write_text(
                json.dumps(
                    {
                        "auth_mode": "chatgpt",
                        "tokens": {
                            "access_token": "secret-token",
                            "account_id": "acct_test",
                        },
                    }
                )
            )
            audio = root / "speech.wav"
            audio.write_bytes(b"RIFF-audio")
            response = BytesIO(b'{"text":"hello"}')
            response.__enter__ = lambda: response
            response.__exit__ = lambda *_args: None
            with patch("codex_asr.transcribe.urlopen", return_value=response) as call:
                text = transcribe(audio, Config(auth_file=auth_path))

        request = call.call_args.args[0]
        self.assertEqual(text, "hello")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret-token")
        self.assertEqual(request.get_header("Chatgpt-account-id"), "acct_test")
        self.assertEqual(request.get_header("Originator"), "Codex Desktop")


class ServerErrorTests(unittest.TestCase):
    def test_recovers_from_server_error_with_same_audio(self) -> None:
        for status in (500, 502, 503, 504):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                audio = Path(directory) / "speech.wav"
                audio.write_bytes(b"test-audio")
                auth = CodexAuth("test-token", "test-account", Path(directory) / "auth.json")
                error = HTTPError("https://example.invalid", status, "Server error", {}, BytesIO(b"failed"))
                with patch("codex_asr.transcribe.load_codex_auth", return_value=auth), \
                     patch("codex_asr.transcribe.urlopen", side_effect=[error, BytesIO(b'{"text":"hello"}')]) as request, \
                     patch("codex_asr.transcribe.time.sleep") as sleep:
                    self.assertEqual(transcribe(audio, Config()), "hello")
                self.assertEqual(request.call_count, 2)
                self.assertIs(request.call_args_list[0].args[0], request.call_args_list[1].args[0])
                self.assertIn(b"test-audio", request.call_args.args[0].data)
                sleep.assert_called_once_with(1)

    def test_stops_after_three_server_failures_and_does_not_retry_client_errors(self) -> None:
        for status, attempts in ((500, 3), (401, 1), (400, 1), (429, 1)):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                audio = Path(directory) / "speech.wav"
                audio.write_bytes(b"test-audio")
                auth = CodexAuth("test-token", None, Path(directory) / "auth.json")
                errors = [HTTPError("https://example.invalid", status, "Error", {}, BytesIO(b"failed")) for _ in range(attempts)]
                with patch("codex_asr.transcribe.load_codex_auth", return_value=auth), \
                     patch("codex_asr.transcribe.urlopen", side_effect=errors) as request, \
                     patch("codex_asr.transcribe.time.sleep") as sleep:
                    with self.assertRaisesRegex(RuntimeError, f"HTTP {status}"):
                        transcribe(audio, Config())
                self.assertEqual(request.call_count, attempts)
                self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 2] if attempts == 3 else [])


if __name__ == "__main__":
    unittest.main()
