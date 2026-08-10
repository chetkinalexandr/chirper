"""Замер точности: сравнение float32 и float16 на одних и тех же записях.

Не входит в приложение — вспомогательный инструмент для разовых проверок.

    .venv/bin/python замер_точности.py запись          # записать голос
    .venv/bin/python замер_точности.py сравнить        # прогнать обе версии

Записи и эталоны кладутся в ~/VoiceNotes-замеры, вне репозитория: голос
личный, ему в git не место.
"""

from __future__ import annotations

import re
import sys
import time
import wave
from pathlib import Path

import numpy as np

ЧАСТОТА = 16000
ПАПКА = Path.home() / "VoiceNotes-замеры"


def нормализовать(текст: str) -> list[str]:
    """Привести к списку слов: регистр и пунктуация на WER влиять не должны."""
    текст = текст.lower().replace("ё", "е")
    return re.findall(r"[a-zа-я0-9]+", текст)


def wer(эталон: str, гипотеза: str) -> tuple[float, int, int, int]:
    """Word Error Rate по расстоянию Левенштейна на словах.

    Возвращает (WER, замен, пропусков, вставок).
    """
    э, г = нормализовать(эталон), нормализовать(гипотеза)
    # d[i][j] — правки, чтобы привести первые i слов эталона к первым j гипотезы.
    d = [[(0, 0, 0, 0)] * (len(г) + 1) for _ in range(len(э) + 1)]
    for i in range(1, len(э) + 1):
        d[i][0] = (i, 0, i, 0)
    for j in range(1, len(г) + 1):
        d[0][j] = (j, 0, 0, j)
    for i in range(1, len(э) + 1):
        for j in range(1, len(г) + 1):
            if э[i - 1] == г[j - 1]:
                d[i][j] = d[i - 1][j - 1]
                continue
            # Порядок вариантов влияет только на разбивку по типам ошибок,
            # общее число правок от него не зависит.
            зам = d[i - 1][j - 1]
            про = d[i - 1][j]
            вст = d[i][j - 1]
            лучший = min(зам, про, вст, key=lambda т: т[0])
            if лучший is зам:
                d[i][j] = (зам[0] + 1, зам[1] + 1, зам[2], зам[3])
            elif лучший is про:
                d[i][j] = (про[0] + 1, про[1], про[2] + 1, про[3])
            else:
                d[i][j] = (вст[0] + 1, вст[1], вст[2], вст[3] + 1)
    всего, зам, про, вст = d[len(э)][len(г)]
    return (всего / len(э) if э else 0.0), зам, про, вст


def записать() -> None:
    """Записать голос с микрофона; остановка — клавишей Enter.

    Приём звука идёт в колбэке на потоке PortAudio, а главный поток просто
    ждёт Enter: блокирующее чтение аудио в главном потоке глотало Ctrl+C.
    """
    try:
        import sounddevice as sd
    except ImportError:
        sys.exit(
            "нужен sounddevice: .venv/bin/pip install sounddevice\n"
            "или запишите wav любым способом: 16 кГц, моно, PCM16"
        )

    ПАПКА.mkdir(exist_ok=True)
    номер = input("номер текста (1, 2 или 3): ").strip()
    путь = ПАПКА / f"замер{номер}.wav"
    if путь.exists() and input(f"{путь.name} уже есть, перезаписать? [y/N] ").lower() != "y":
        return

    куски: list[np.ndarray] = []

    def приём(данные, кадров, время, статус):
        куски.append(данные.copy())

    print("\nзапись пошла — читайте текст. Enter — закончить\n")
    with sd.InputStream(samplerate=ЧАСТОТА, channels=1, dtype="int16", callback=приём):
        try:
            input()
        except (KeyboardInterrupt, EOFError):
            pass

    звук = np.concatenate(куски) if куски else np.zeros((0, 1), dtype=np.int16)
    with wave.open(str(путь), "wb") as файл:
        файл.setnchannels(1)
        файл.setsampwidth(2)
        файл.setframerate(ЧАСТОТА)
        файл.writeframes(звук.tobytes())
    print(f"\nсохранено: {путь}  ({len(звук)/ЧАСТОТА:.0f} с)")
    print(f"теперь положите эталонный текст в {ПАПКА}/замер{номер}.txt")


def загрузить_wav(путь: Path) -> np.ndarray:
    with wave.open(str(путь), "rb") as файл:
        каналы = файл.getnchannels()
        данные = файл.readframes(файл.getnframes())
    звук = np.frombuffer(данные, dtype="<i2").astype(np.float32) / 32768.0
    if каналы == 2:
        звук = звук.reshape(-1, 2).mean(axis=1, dtype=np.float32)
    return звук


def прогнать(движок, звук: np.ndarray) -> tuple[str, float]:
    начало = time.monotonic()
    текст = движок.распознать(звук)
    return текст, time.monotonic() - начало


def сравнить() -> None:
    """Прогнать записи через текущий движок и посчитать WER против эталонов.

    Контроль качества при смене движка или модели: цифры сравниваются с
    зафиксированными в ЗАДАЧИ.md (на переходе к ONNX int8 среднее было 21,3%).
    """
    sys.path.insert(0, str(Path(__file__).parent))
    from asr import GigaAM

    записи = sorted(ПАПКА.glob("замер*.wav"))
    if not записи:
        sys.exit(f"нет записей в {ПАПКА} — сначала: замер_точности.py запись")

    print("загружаю модель…")
    движок = GigaAM()
    движок.прогреть()

    итоги: list[float] = []
    времена: list[float] = []
    for wav in записи:
        эталон_файл = wav.with_suffix(".txt")
        if not эталон_файл.exists():
            print(f"{wav.name}: нет эталона {эталон_файл.name}, пропускаю")
            continue
        эталон = эталон_файл.read_text(encoding="utf-8")
        звук = загрузить_wav(wav)
        текст, секунды = прогнать(движок, звук)
        доля, зам, про, вст = wer(эталон, текст)
        итоги.append(доля)
        времена.append(секунды)
        print(
            f"{wav.name} ({len(звук)/ЧАСТОТА:.0f} с, {len(нормализовать(эталон))} слов): "
            f"WER {доля:.1%}  ({зам} замен, {про} проп., {вст} вставок)  {секунды:.1f} с"
        )
        (ПАПКА / f"{wav.stem}.распознано.txt").write_text(текст, encoding="utf-8")

    if итоги:
        print(f"\nсредний WER {np.mean(итоги):.1%}, среднее время {np.mean(времена):.1f} с")
        print(f"расшифровки сохранены в {ПАПКА}")


if __name__ == "__main__":
    команда = sys.argv[1] if len(sys.argv) > 1 else ""
    if команда == "запись":
        записать()
    elif команда == "сравнить":
        сравнить()
    else:
        sys.exit(__doc__)
