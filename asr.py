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
    """GigaAM v3 e2e_rnnt через transformers + trust_remote_code.

    ⚠️ transformers строго 4.x: на 5.x модель не поднимается вообще
    («Tensor on device cpu is not on the expected device meta!»).

    Ветка e2e_rnnt выбрана для диктовки: она сама расставляет
    пунктуацию и нормализует числа. Точная ревизия закреплена,
    так как репозиторий модели выполняет удалённый Python-код.
    """

    МОДЕЛЬ = "ai-sage/GigaAM-v3"
    РЕВИЗИЯ = "7655ad717f8122257385bb4b2f373db3697e8680"

    def __init__(self):
        self._модель = None
        self._внутренняя = None

    def загрузить(self) -> None:
        from transformers import AutoModel

        self._модель = AutoModel.from_pretrained(
            self.МОДЕЛЬ, revision=self.РЕВИЗИЯ, trust_remote_code=True
        )
        self._модель.eval()
        self._внутренняя = self._модель.model

    def прогреть(self) -> None:
        """Прогнать пустышку, чтобы первый настоящий вызов не был медленным.

        Инвариант проекта: греем при старте демона, а не по первому хоткею —
        иначе первая же диктовка ощущается тормозом.
        """
        if self._модель is None:
            self.загрузить()
        self.распознать(np.zeros(ЧАСТОТА, dtype=np.float32))

    def распознать(self, звук: np.ndarray) -> str:
        # Вход проверяем до импорта torch: тогда ошибка вызова видна сразу и
        # не зависит от того, установлены ли тяжёлые зависимости.
        # float32 строго: на int16 движок молча возвращает пустую строку.
        if звук.dtype != np.float32:
            raise ValueError(f"нужен float32, получен {звук.dtype}")
        if звук.ndim > 1:
            звук = звук.mean(axis=1)

        import torch

        if self._модель is None:
            self.загрузить()

        устройство = next(self._внутренняя.parameters()).device
        тип = next(self._внутренняя.parameters()).dtype

        части = []
        for кусок in нарезать(звук):
            тензор = torch.from_numpy(кусок).to(устройство).to(тип).unsqueeze(0)
            длина = torch.full([1], тензор.shape[-1], device=устройство)
            with torch.inference_mode():
                закодировано, длина_кода = self._внутренняя.forward(тензор, длина)
                результат = self._внутренняя.decoding.decode(
                    self._внутренняя.head, закодировано, длина_кода
                )[0]
            # CTC-варианты отдают (текст, токены), RNNT — просто строку.
            текст = результат[0] if isinstance(результат, tuple) else результат
            if текст.strip():
                части.append(текст.strip())

        return " ".join(части)
