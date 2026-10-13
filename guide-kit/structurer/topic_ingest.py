"""
topic_ingest.py — приёмник topic.yaml для прикладных тем (Ф6-Ф8).

Библиотечная функция Разметчика: читает и валидирует topic.yaml из базовой
директории пользователя. Не знает о декомпозиторе, подборщике или генераторе —
просто приём и минимальная валидация контракта. Используется generator-ом
как библиотечный вызов (не прямой доступ к файлам).

Формат topic.yaml: см. FORMAT-topic.yaml.md.
"""

from __future__ import annotations

import logging
import os
from typing import Any, Optional

import yaml

logger = logging.getLogger(__name__)


def ingest_topic_yaml(base_path: str) -> Optional[dict[str, Any]]:
    """
    Читает topic.yaml из base_path и валидирует минимальный контракт.

    Args:
        base_path: путь к директории, где может лежать topic.yaml

    Returns:
        Загруженный и слегка нормализованный dict, или None если файла нет
        или он не прошёл валидацию.

    Валидация:
        - всегда: scenario, topic_name
        - scenario == "learn": mode обязателен и должен быть "B" или "V"
        - scenario == "research" / "formalize": mode не требуется
    """
    if not base_path:
        return None

    topic_path = os.path.join(base_path, "topic.yaml")
    if not os.path.isfile(topic_path):
        return None

    try:
        with open(topic_path, encoding="utf-8") as fh:
            topic = yaml.safe_load(fh) or {}
    except yaml.YAMLError as e:
        logger.warning("topic_ingest: malformed YAML at %r: %s", topic_path, e)
        return None
    except OSError as e:
        logger.warning("topic_ingest: cannot read %r: %s", topic_path, e)
        return None

    if not isinstance(topic, dict):
        logger.warning("topic_ingest: %r is not a mapping, ignoring", topic_path)
        return None

    # Обязательные поля для всех сценариев
    if "scenario" not in topic:
        logger.warning("topic_ingest: missing 'scenario' in %r", topic_path)
        return None
    if "topic_name" not in topic:
        logger.warning("topic_ingest: missing 'topic_name' in %r", topic_path)
        return None

    scenario = topic.get("scenario")
    mode = topic.get("mode")

    # Сценарная валидация mode
    if scenario == "learn":
        if mode not in ("B", "V"):
            logger.warning(
                "topic_ingest: scenario=learn requires mode 'B' or 'V', got %r in %r",
                mode,
                topic_path,
            )
            return None
    elif scenario in ("research", "formalize"):
        # mode не требуется, но если присутствует — оставляем как есть
        pass
    else:
        logger.warning("topic_ingest: unknown scenario %r in %r", scenario, topic_path)
        return None

    logger.info(
        "topic_ingest: loaded topic.yaml: scenario=%s, mode=%s, topic=%r",
        scenario,
        mode,
        topic.get("topic_name"),
    )
    return topic
