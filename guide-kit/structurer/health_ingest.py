"""
health_ingest.py — приёмник health_status.json для пилотского контура (Ф10/WP-470).

Библиотечная функция Разметчика: читает health_status.json из базовой
директории пользователя. Не знает о генераторе или адаптере — просто приём
и минимальная валидация. Используется generator-ом как библиотечный вызов
(не прямой доступ к файлам).
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, Optional

logger = logging.getLogger(__name__)


def ingest_health_status(base_path: str) -> Optional[dict[str, Any]]:
    """
    Читает health_status.json из base_path.

    Args:
        base_path: путь к директории, где может лежать health_status.json

    Returns:
        Загруженный dict или None если файла нет или он не прошёл валидацию.
    """
    if not base_path:
        return None

    health_path = os.path.join(base_path, "health_status.json")
    if not os.path.isfile(health_path):
        return None

    try:
        with open(health_path, encoding="utf-8") as fh:
            health = json.load(fh)
    except json.JSONDecodeError as e:
        logger.warning("health_ingest: malformed JSON at %r: %s", health_path, e)
        return None
    except OSError as e:
        logger.warning("health_ingest: cannot read %r: %s", health_path, e)
        return None

    if not isinstance(health, dict):
        logger.warning("health_ingest: %r is not a mapping, ignoring", health_path)
        return None

    logger.info(
        "health_ingest: loaded health_status.json: sleep=%.1fh, stress=%s",
        health.get("sleep", {}).get("total_hours", 0),
        health.get("cardiovascular", {}).get("stress_indicator", False),
    )
    return health
