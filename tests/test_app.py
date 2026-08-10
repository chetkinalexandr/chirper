"""Автоматические проверки продуктовой логики без микрофона и загрузки модели."""

import io
import json
import plistlib
import re
import sys
import wave
from pathlib import Path

import numpy as np
import pytest

КОРЕНЬ = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(КОРЕНЬ))

import asr_worker  # noqa: E402
from asr import ЧАСТОТА, GigaAM, нарезать  # noqa: E402
from asr_worker import загрузить_wav  # noqa: E402


class ДвижокЗаглушка:
    """Считает вызовы вместо настоящего распознавания."""

    def __init__(self, текст="привет"):
        self.текст = текст
        self.вызовы = 0

    def прогреть(self):
        pass

    def распознать(self, звук):
        self.вызовы += 1
        return self.текст


def прогнать_воркер(monkeypatch, capsys, команды, движок):
    """Прогнать цикл main() на списке команд, вернуть разобранные ответы."""
    monkeypatch.setattr(asr_worker, "GigaAM", lambda: движок)
    monkeypatch.setattr("sys.stdin", io.StringIO("".join(json.dumps(к) + "\n" for к in команды)))
    asr_worker.main()
    вывод = capsys.readouterr().out
    return [json.loads(с) for с in вывод.splitlines() if с.strip()]


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


def test_прогрев_молчит_и_будит_модель(monkeypatch, capsys):
    """Прогрев трогает модель, но не отвечает: приложение его ответа не ждёт."""
    движок = ДвижокЗаглушка()
    ответы = прогнать_воркер(monkeypatch, capsys, [{"command": "warmup"}], движок)
    assert движок.вызовы == 1
    assert [о["event"] for о in ответы] == ["ready"]


def test_прогрев_идёт_каждый_раз(monkeypatch, capsys):
    """Порога намеренно нет: проход стоит 0,19 с, а вытеснение идёт быстро."""
    движок = ДвижокЗаглушка()
    ответы = прогнать_воркер(
        monkeypatch, capsys, [{"command": "warmup"}] * 3, движок
    )
    assert движок.вызовы == 3
    assert [о["event"] for о in ответы] == ["ready"]


def test_прогрев_не_ломает_распознавание(monkeypatch, capsys, tmp_path):
    """После прогрева transcribe отвечает как обычно — id и текст на месте."""
    путь = tmp_path / "recording.wav"
    with wave.open(str(путь), "wb") as файл:
        файл.setnchannels(1)
        файл.setsampwidth(2)
        файл.setframerate(ЧАСТОТА)
        файл.writeframes(np.zeros(ЧАСТОТА, dtype="<i2").tobytes())

    движок = ДвижокЗаглушка("готово")
    ответы = прогнать_воркер(
        monkeypatch,
        capsys,
        [
            {"command": "warmup"},
            {"command": "transcribe", "id": "abc", "audio_path": str(путь)},
        ],
        движок,
    )
    результат = [о for о in ответы if о["event"] == "result"]
    assert результат == [{"event": "result", "id": "abc", "text": "готово"}]


def test_неизвестная_команда_остаётся_ошибкой(monkeypatch, capsys):
    """Опечатка в команде не должна молча проглатываться как прогрев."""
    ответы = прогнать_воркер(
        monkeypatch, capsys, [{"command": "warmupp"}], ДвижокЗаглушка()
    )
    assert [о["event"] for о in ответы] == ["ready", "error"]
