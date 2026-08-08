"""Постоянный фоновый ASR-процесс для нативного macOS-приложения.

Протокол — JSON Lines через stdin/stdout. Диагностика всегда идёт в stderr,
чтобы сообщения библиотек не ломали канал ответов.
"""

from __future__ import annotations

import contextlib
import json
import sys
import wave
from pathlib import Path

import numpy as np

from asr import ЧАСТОТА, GigaAM

# Простаивающий воркер держит ~1 ГБ, который macOS вытесняет в swap: замер
# показал 0,36 с на первом проходе против 0,19 с на горячей модели. Поэтому
# греем в начале записи — пока человек говорит.
#
# Порога «греть, только если давно не трогали» здесь намеренно нет: греть
# нечего экономить (проход стоит 0,19 с), а вытеснение идёт быстро — воркер
# проседал до 62 МБ за 15 минут простоя. Любой порог скорее пропустит нужный
# прогрев, чем сбережёт заметное время.


def загрузить_wav(путь: Path) -> np.ndarray:
    """Прочитать mono/stereo PCM16 WAV, который создаёт нативный рекордер."""
    if not путь.is_file():
        raise FileNotFoundError(f"аудиофайл не найден: {путь}")
    with wave.open(str(путь), "rb") as файл:
        каналы = файл.getnchannels()
        частота = файл.getframerate()
        разрядность = файл.getsampwidth()
        данные = файл.readframes(файл.getnframes())

    if частота != ЧАСТОТА:
        raise ValueError(f"ожидалось {ЧАСТОТА} Гц, получено {частота}")
    if каналы not in (1, 2) or разрядность != 2:
        raise ValueError("ожидался PCM16 WAV с одним или двумя каналами")
    звук = np.frombuffer(данные, dtype="<i2").astype(np.float32) / 32768.0
    if каналы == 2:
        звук = звук.reshape(-1, 2).mean(axis=1, dtype=np.float32)
    if звук.size == 0:
        raise ValueError("аудиофайл пуст")
    return звук


def ответить(**данные) -> None:
    print(json.dumps(данные, ensure_ascii=False), flush=True)


def main() -> int:
    try:
        with contextlib.redirect_stdout(sys.stderr):
            движок = GigaAM()
            движок.прогреть()
    except Exception as ошибка:
        ответить(event="failed", error=str(ошибка))
        return 1

    ответить(event="ready", variant="e2e_rnnt")
    for строка in sys.stdin:
        запрос = None
        try:
            запрос = json.loads(строка)
            команда = запрос.get("command")
            if команда == "shutdown":
                return 0

            if команда == "warmup":
                # Ответа нет намеренно: приложение шлёт прогрев и забывает о нём,
                # иначе пришлось бы учить разбор событий лишнему случаю.
                with contextlib.redirect_stdout(sys.stderr):
                    движок.распознать(np.zeros(ЧАСТОТА, dtype=np.float32))
                continue

            if команда != "transcribe":
                raise ValueError("неизвестная команда")

            идентификатор = запрос.get("id")
            путь = Path(запрос["audio_path"])
            with contextlib.redirect_stdout(sys.stderr):
                текст = движок.распознать(загрузить_wav(путь))
            ответить(event="result", id=идентификатор, text=текст)
        except Exception as ошибка:
            ответить(
                event="error",
                id=запрос.get("id") if isinstance(запрос, dict) else None,
                error=str(ошибка),
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
