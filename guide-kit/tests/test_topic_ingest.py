"""Tests for structurer/topic_ingest.py — приёмник topic.yaml (Ф6-Ф8)."""

import os
import sys
import tempfile
import pytest

# structurer/ не является пакетом; добавляем путь для импорта
_STRUCTURER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "structurer")
if _STRUCTURER_DIR not in sys.path:
    sys.path.insert(0, _STRUCTURER_DIR)

from topic_ingest import ingest_topic_yaml


class TestIngestTopicYaml:
    """Базовые сценарии приёма topic.yaml."""

    def test_missing_file_returns_none(self):
        """Отсутствующий topic.yaml → None."""
        with tempfile.TemporaryDirectory() as tmp:
            assert ingest_topic_yaml(tmp) is None

    def test_empty_base_path_returns_none(self):
        """Пустой base_path → None."""
        assert ingest_topic_yaml("") is None
        assert ingest_topic_yaml(None) is None

    def test_valid_learn_mode_b(self):
        """Корректный scenario=learn + mode=B → dict."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: learn\nmode: B\ntopic_name: Test\nsections: []\n")

            result = ingest_topic_yaml(tmp)
            assert result is not None
            assert result["scenario"] == "learn"
            assert result["mode"] == "B"
            assert result["topic_name"] == "Test"

    def test_valid_learn_mode_v(self):
        """Корректный scenario=learn + mode=V → dict."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: learn\nmode: V\ntopic_name: Search\nsearch_criteria: {}\n")

            result = ingest_topic_yaml(tmp)
            assert result is not None
            assert result["mode"] == "V"

    def test_learn_missing_mode_returns_none(self):
        """scenario=learn без mode → None (mode обязателен для learn)."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: learn\ntopic_name: No Mode\n")

            assert ingest_topic_yaml(tmp) is None

    def test_learn_invalid_mode_returns_none(self):
        """scenario=learn с mode=X → None."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: learn\nmode: X\ntopic_name: Bad Mode\n")

            assert ingest_topic_yaml(tmp) is None

    def test_research_without_mode_is_ok(self):
        """scenario=research без mode → dict (mode не требуется)."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: research\ntopic_name: Frontier\n")

            result = ingest_topic_yaml(tmp)
            assert result is not None
            assert result["scenario"] == "research"

    def test_formalize_without_mode_is_ok(self):
        """scenario=formalize без mode → dict."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: formalize\ntopic_name: Draft\n")

            result = ingest_topic_yaml(tmp)
            assert result is not None
            assert result["scenario"] == "formalize"

    def test_unknown_scenario_returns_none(self):
        """Неизвестный scenario → None."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: unknown\ntopic_name: Bad\n")

            assert ingest_topic_yaml(tmp) is None

    def test_missing_scenario_returns_none(self):
        """Отсутствие scenario → None."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("topic_name: No Scenario\n")

            assert ingest_topic_yaml(tmp) is None

    def test_missing_topic_name_returns_none(self):
        """Отсутствие topic_name → None."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: learn\nmode: B\n")

            assert ingest_topic_yaml(tmp) is None

    def test_malformed_yaml_returns_none(self):
        """Битый YAML → None (честная деградация)."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("scenario: learn\n  bad indent: [unclosed\n")

            assert ingest_topic_yaml(tmp) is None

    def test_non_mapping_yaml_returns_none(self):
        """YAML не mapping (список/строка) → None."""
        with tempfile.TemporaryDirectory() as tmp:
            topic_path = os.path.join(tmp, "topic.yaml")
            with open(topic_path, "w", encoding="utf-8") as fh:
                fh.write("- item1\n- item2\n")

            assert ingest_topic_yaml(tmp) is None
