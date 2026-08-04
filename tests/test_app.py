"""Автоматические проверки продуктовой логики без микрофона и загрузки модели."""

import plistlib
import re
import sys
import wave
from pathlib import Path

import numpy as np
import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(КОРЕНЬ))

from asr import ЧАСТОТА, GigaAM, нарезать  # noqa: E402
from asr_worker import загрузить_wav  # noqa: E402


def test_проект_готов_к_публикации():
    assert sys.version_info >= (3, 10)
    for имя in (
        "README.md",
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "native/VoiceNotes.swift",
        "native/Info.plist",
        "native/VoiceNotes.icns",
        "asr_worker.py",
        "pyannote/__init__.py",
    ):
        assert (КОРЕНЬ / имя).is_file(), f"нет {имя}"
    игнор = (КОРЕНЬ / ".gitignore").read_text(encoding="utf-8")
    # Записи с микрофона и сборка не должны попасть в публичный репозиторий.
    for правило in (".env", "*.wav", "build/", "dist/"):
        assert правило in игнор

    with (КОРЕНЬ / "native/Info.plist").open("rb") as файл:
        plist = plistlib.load(файл)
    assert plist["CFBundleExecutable"] == "VoiceNotes"
    assert plist["LSUIElement"] is True
    assert "VoiceNotesProjectPath" not in plist
    pyproject = (КОРЕНЬ / "pyproject.toml").read_text(encoding="utf-8")
    version = re.search(r'^version = "([^"]+)"', pyproject, re.MULTILINE)
    assert version and version.group(1) == plist["CFBundleShortVersionString"]
    assert re.fullmatch(r"[0-9a-f]{40}", GigaAM.РЕВИЗИЯ)


def test_нарезка_аудио_не_теряет_данные():
    короткий = np.zeros(ЧАСТОТА * 5, dtype=np.float32)
    assert нарезать(короткий) == [короткий]

    длинный = np.random.default_rng(1).normal(0, 0.1, ЧАСТОТА * 55).astype(np.float32)
    куски = нарезать(длинный)
    assert all(len(кусок) / ЧАСТОТА <= 25 for кусок in куски)
    np.testing.assert_array_equal(np.concatenate(куски), длинный)


def test_нарезка_ищет_паузу():
    речь = np.ones(ЧАСТОТА * 19, dtype=np.float32)
    пауза = np.zeros(ЧАСТОТА * 2, dtype=np.float32)
    граница = len(нарезать(np.concatenate([речь, пауза, речь]))[0]) / ЧАСТОТА
    assert 19 <= граница <= 21


def test_нарезка_с_коротким_пределом_не_использует_отрицательный_срез():
    звук = np.arange(ЧАСТОТА * 3, dtype=np.float32)
    куски = нарезать(звук, предел_секунд=1)
    assert all(0 < len(кусок) <= ЧАСТОТА for кусок in куски)
    np.testing.assert_array_equal(np.concatenate(куски), звук)


def test_движок_отвергает_int16_до_загрузки_модели():
    движок = GigaAM()
    with pytest.raises(ValueError, match="float32"):
        движок.распознать(np.zeros(ЧАСТОТА, dtype=np.int16))
    assert движок._модель is None


def test_worker_читает_pcm16_wav(tmp_path):
    путь = tmp_path / "recording.wav"
    исходный = np.array([-32768, -8192, 0, 8192, 32767], dtype="<i2")
    with wave.open(str(путь), "wb") as файл:
        файл.setnchannels(1)
        файл.setsampwidth(2)
        файл.setframerate(ЧАСТОТА)
        файл.writeframes(исходный.tobytes())

    звук = загрузить_wav(путь)
    assert звук.dtype == np.float32
    np.testing.assert_allclose(звук, исходный.astype(np.float32) / 32768.0)
