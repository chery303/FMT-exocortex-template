"""
Integration layer for Ф6-Ф10 (applied topics, health adaptation).

Добавляется в adapter.py:
1. route_scenario() если есть topic.yaml
2. health_adaptation если есть health_status.json
"""

import os
import sys
import json
import logging
from typing import Optional, Dict, Any, Tuple

# structurer/ не является пакетом; добавляем путь для библиотечного вызова
_STRUCTURER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "structurer")
if _STRUCTURER_DIR not in sys.path:
    sys.path.insert(0, _STRUCTURER_DIR)

from scenario_router import route_and_serialize
from health_adapter import adapt_profile_with_health
from topic_ingest import ingest_topic_yaml
from health_ingest import ingest_health_status

logger = logging.getLogger(__name__)


def load_topic_yaml(base_path: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Загружает topic.yaml через библиотечный приёмник Разметчика.

    Args:
        base_path: путь к директории (где лежит profile.yaml и topic.yaml)

    Returns:
        Загруженный и валидированный topic.yaml или None
    """
    return ingest_topic_yaml(base_path or "")


def load_health_status(base_path: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Загружает health_status.json через библиотечный приёмник Разметчика.

    Args:
        base_path: путь к директории

    Returns:
        Загруженный health_status.json или None
    """
    return ingest_health_status(base_path or "")


def _sanitize_applied_topic_for_llm(applied_topic: Dict[str, Any]) -> Dict[str, Any]:
    """
    Оставляет в applied_topic только безопасные для передачи внешнему LLM поля.

    Убирает source_url, source_location, learning_objectives, source_anchor —
    они могут содержать PII или чувствительные ссылки. Оставляет метаданные
    (scenario, mode, topic_name) и статистику (sections_count), достаточные
    для текстового упоминания прикладной темы без деталей содержания.
    """
    result = applied_topic.get("result", {})
    sections = result.get("sections", []) if isinstance(result, dict) else []
    return {
        "scenario": applied_topic.get("scenario"),
        "mode": applied_topic.get("mode"),
        "topic_name": applied_topic.get("topic_name"),
        "sections_count": len(sections),
    }


def apply_applied_topics(planner_result: Dict[str, Any], topic_data: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Применяет маршрутизацию сценария Ф6-Ф8 к результату планировщика.

    Если topic.yaml присутствует:
    - scenario=learn + mode=B → Decomposer (Ф6)
    - scenario=learn + mode=V → SourceFinder (Ф7)
    - scenario=research → ResearchGenerator (Ф8)
    - scenario=formalize → FormalizationAssistant (Ф8)

    Args:
        planner_result: результат plan_horizon()
        topic_data: загруженный topic.yaml

    Returns:
        Модифицированный planner_result с applied_topic_data
    """
    if not topic_data or not topic_data.get("scenario"):
        # Дефолт: наша фундаментальная тема (Ф1)
        return planner_result

    try:
        scenario_result = route_and_serialize(topic_data)

        # Добавляем результат маршрутизации в planner_result
        result = dict(planner_result)
        result["applied_topic"] = {
            "scenario": topic_data.get("scenario"),
            "mode": topic_data.get("mode", "A"),
            "topic_name": topic_data.get("topic_name"),
            "result": scenario_result,
        }

        logger.info("Applied topic scenario=%s: got %d items",
                   topic_data.get("scenario"),
                   len(scenario_result.get("sections", [])) or len(scenario_result.get("candidates", [])))

        return result
    except Exception as e:
        logger.error("Failed to apply applied topics: %s", e)
        # Честная деградация: вернуть исходный результат без applied_topic
        return planner_result


def apply_health_adaptation(profile: Dict[str, Any], health_status: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """
    Применяет адаптацию по health-метрикам (Ф10).

    Если health_status.json присутствует:
    - Плохой сон → лёгкие практики
    - Стресс → медитация на первое место
    - Хорошая физ.подготовка → сложнее задачи

    Args:
        profile: исходный profile.yaml
        health_status: загруженный health_status.json

    Returns:
        Адаптированный profile с health-параметрами
    """
    if not health_status:
        return profile

    try:
        adapted = adapt_profile_with_health(profile, health_status)
        logger.info("Applied health adaptation: difficulty=%.2fx, intensity=%s",
                   adapted.get("_health_adaptation", {}).get("difficulty_modifier", 1.0),
                   adapted.get("_health_adaptation", {}).get("intensity_level", "normal"))
        return adapted
    except Exception as e:
        logger.warning("Failed to apply health adaptation: %s", e)
        # Честная деградация: вернуть исходный профиль
        return profile


def integrate_f6f10_into_generation(
    profile: Dict[str, Any],
    config: Dict[str, Any],
    base_path: Optional[str] = None
) -> Tuple[Dict[str, Any], Dict[str, Any], Optional[Dict[str, Any]]]:
    """
    Единая функция интеграции Ф6-Ф10 в pipeline generate_daily_plan.

    Returns:
        (adapted_profile, config_with_topic, planner_modifications)
    """

    # 1. Загружаем topic.yaml (Ф6-Ф8)
    topic_data = load_topic_yaml(base_path)

    # 2. Загружаем health_status.json (Ф10)
    health_status = load_health_status(base_path)

    # 3. Применяем health-адаптацию к профилю
    adapted_profile = apply_health_adaptation(profile, health_status)

    # 4. Передаём topic_data в config для позднейшей маршрутизации
    config_with_topic = dict(config)
    if topic_data:
        config_with_topic["_applied_topic_data"] = topic_data

    return adapted_profile, config_with_topic, topic_data


# Export functions for use in adapter.py
__all__ = [
    "load_topic_yaml",
    "load_health_status",
    "apply_applied_topics",
    "apply_health_adaptation",
    "integrate_f6f10_into_generation",
    "sanitize_applied_topic_for_llm",
]


def sanitize_applied_topic_for_llm(applied_topic: Dict[str, Any]) -> Dict[str, Any]:
    """Публичная обёртка для _sanitize_applied_topic_for_llm."""
    return _sanitize_applied_topic_for_llm(applied_topic)
