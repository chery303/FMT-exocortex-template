"""Tests for adapter.py's markdown-fence tolerance in LLM JSON parsing.

prompt.md explicitly forbids markdown fences around the JSON response, but a
live run against a real model (2026-08-12, OpenRouter/claude-sonnet-4.5) wrapped
its otherwise-correct output in ```json ... ``` anyway — json.loads(llm_result.text)
failed on it. The 68 tests written for Ф6-Ф10 never caught this: every one of
them mocks llm_generate with a hand-written literal that is always bare JSON,
so none could exercise a model actually disobeying the fence instruction.
"""

from unittest.mock import patch

from adapter import _strip_json_fences, generate_daily_plan
from llm_backends import GenerationResult


class TestStripJsonFences:
    def test_bare_json_is_unchanged(self):
        text = '{"narrative": "x", "plan_day": []}'
        assert _strip_json_fences(text) == text

    def test_json_fence_is_stripped(self):
        text = '```json\n{"narrative": "x", "plan_day": []}\n```'
        assert _strip_json_fences(text) == '{"narrative": "x", "plan_day": []}'

    def test_bare_fence_without_json_label_is_stripped(self):
        text = '```\n{"narrative": "x", "plan_day": []}\n```'
        assert _strip_json_fences(text) == '{"narrative": "x", "plan_day": []}'

    def test_surrounding_whitespace_is_tolerated(self):
        text = '\n  ```json\n{"narrative": "x", "plan_day": []}\n```  \n'
        assert _strip_json_fences(text) == '{"narrative": "x", "plan_day": []}'

    def test_genuinely_malformed_json_is_left_alone_not_masked(self):
        """A fence-shaped wrapper around actually-broken JSON must still surface
        as a parse error upstream — stripping fences must not turn a real bug
        into a silently-accepted partial match."""
        text = '```json\n{"narrative": "x", "plan_day": [\n```'
        assert _strip_json_fences(text) == '{"narrative": "x", "plan_day": ['


class TestGenerateDailyPlanToleratesJsonFences:
    def _fake_llm_fenced_json(self, *_args, **_kwargs):
        return GenerationResult(
            text=(
                '```json\n'
                '{"narrative": "текст", '
                '"plan_day": [{"label": "задание", "tomatoes": 1}]}\n'
                '```'
            ),
            backend_id="fake",
            model="fake",
        )

    def _fake_llm_genuinely_broken_json(self, *_args, **_kwargs):
        return GenerationResult(
            text='{"narrative": "текст", "plan_day": [',
            backend_id="fake",
            model="fake",
        )

    def test_fenced_response_still_produces_a_plan(self, tmp_path):
        profile_path = tmp_path / "profile.yaml"
        profile_path.write_text("{}", encoding="utf-8")
        with patch("adapter.llm_generate", side_effect=self._fake_llm_fenced_json):
            result = generate_daily_plan(str(profile_path))
        assert result.ok
        assert "задание" in result.markdown

    def test_broken_json_still_fails_honestly(self, tmp_path):
        """The fence tolerance must not swallow a real LLM malfunction —
        genuinely invalid JSON has to keep returning ok=False with a
        diagnostic, exactly as before this fix."""
        profile_path = tmp_path / "profile.yaml"
        profile_path.write_text("{}", encoding="utf-8")
        with patch("adapter.llm_generate", side_effect=self._fake_llm_genuinely_broken_json):
            result = generate_daily_plan(str(profile_path))
        assert not result.ok
        assert "невалидный JSON" in result.diagnostic["reason"]
