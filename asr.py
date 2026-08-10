"""Локальное распознавание речи через GigaAM."""

from __future__ import annotations

import numpy as np

ЧАСТОТА = 16000
# Модель падает на записях длиннее 25 с (LONGFORM_THRESHOLD внутри неё),
# а штатный longform-путь тянет pyannote и токен HuggingFace. Режем сами.
ПРЕДЕЛ_КУСКА = 20.0


class Движок:
    """Контракт распознавания для независимости остального приложения от модели."""

    def прогреть(self) -> None:
        raise NotImplementedError

    def распознать(self, звук: np.ndarray) -> str:
        raise NotImplementedError


def нарезать(звук: np.ndarray, предел_секунд: float = ПРЕДЕЛ_КУСКА) -> list[np.ndarray]:
    """Порезать длинное аудио по паузам, чтобы разрыв не попал внутрь слова."""
    предел = int(предел_секунд * ЧАСТОТА)
    if len(звук) <= предел:
        return [звук]

    куски = []
    начало = 0
    окно = int(0.5 * ЧАСТОТА)

    while начало < len(звук):
        конец = начало + предел
        if конец >= len(звук):
            куски.append(звук[начало:])
            break

        начало_зоны = max(начало, конец - окно * 4)
        зона = звук[начало_зоны:конец]
        if len(зона) > окно:
            шаг = max(окно // 8, 1)
            ширина = max(окно // 4, 1)
            блоки = [
                (i, float(np.abs(зона[i : i + ширина]).mean()))
                for i in range(0, len(зона) - ширина, шаг)
            ]
            if блоки:
                кандидат = начало_зоны + min(блоки, key=lambda п: п[1])[0]
                if кандидат > начало:
                    конец = кандидат

        куски.append(звук[начало:конец])
        начало = конец

    return куски


class GigaAM(Движок):
    """GigaAM v3 e2e_rnnt (int8) через ONNX Runtime + onnx-asr.

    Переход с PyTorch (замер 2026-08-10, ЗАДАЧИ.md): качество на живом
    голосе идентично до десятой доли процента WER, память вдвое меньше,
    загрузка 0,4 с против 4,1 с. Пути ужатия внутри PyTorch закрыты: на
    CPU Apple Silicon у fp16/int8 нет дороги в Accelerate.

    Ревизия закреплена ради воспроизводимости: качество int8-экспорта
    нигде не опубликовано, мы проверяли конкретный снапшот.

    ⚠️ CoreMLExecutionProvider на этой модели падает — только CPU.
    ⚠️ Нарезка по 20 с обязана остаться: int8-квант соседней модели
    (Parakeet, onnx-asr#126) деградирует на кусках длиннее.
    """

    МОДЕЛЬ = "istupakov/gigaam-v3-onnx"
    РЕВИЗИЯ = "322c3b29492673eb7d0b434bfa9dfb8653e34d02"
    ФАЙЛЫ = ("config.json", "v3_e2e_rnnt_*.int8.onnx", "v3_e2e_rnnt_vocab.txt")

    def __init__(self):
        self._модель = None

    def загрузить(self) -> None:
        import onnx_asr
        from huggingface_hub import snapshot_download

        путь = snapshot_download(
            self.МОДЕЛЬ, revision=self.РЕВИЗИЯ, allow_patterns=list(self.ФАЙЛЫ)
        )
        self._модель = onnx_asr.load_model(
            "gigaam-v3-e2e-rnnt",
            путь,
            quantization="int8",
            providers=["CPUExecutionProvider"],
        )

    def прогреть(self) -> None:
        """Прогнать пустышку, чтобы первый настоящий вызов не был медленным.

        Инвариант проекта: греем при старте демона, а не по первому хоткею —
        иначе первая же диктовка ощущается тормозом.
        """
        if self._модель is None:
            self.загрузить()
        self.распознать(np.zeros(ЧАСТОТА, dtype=np.float32))

    def распознать(self, звук: np.ndarray) -> str:
        # Вход проверяем до загрузки модели: тогда ошибка вызова видна сразу
        # и не зависит от того, установлены ли тяжёлые зависимости.
        # float32 строго: на int16 движок молча возвращает пустую строку.
        if звук.dtype != np.float32:
            raise ValueError(f"нужен float32, получен {звук.dtype}")
        if звук.ndim > 1:
            звук = звук.mean(axis=1)

        if self._модель is None:
            self.загрузить()

        части = []
        for кусок in нарезать(звук):
            текст = self._модель.recognize(кусок, sample_rate=ЧАСТОТА)
            if текст.strip():
                части.append(текст.strip())

        return " ".join(части)
