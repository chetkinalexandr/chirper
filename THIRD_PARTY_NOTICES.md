# Third-party notices

VoiceNotes uses the following third-party software. These components are not
covered by the VoiceNotes MIT license and remain subject to their own terms.

| Component | Purpose | License |
| --- | --- | --- |
| [GigaAM v3](https://huggingface.co/ai-sage/GigaAM-v3) | Speech recognition model and remote model code | MIT |
| [PyTorch](https://github.com/pytorch/pytorch) and [TorchAudio](https://github.com/pytorch/audio) | Neural-network inference and audio transforms | BSD-style |
| [Transformers](https://github.com/huggingface/transformers) and [huggingface_hub](https://github.com/huggingface/huggingface_hub) | Loading the pinned model revision | Apache-2.0 |
| [Hydra](https://github.com/facebookresearch/hydra), [OmegaConf](https://github.com/omry/omegaconf) | Model configuration | MIT / BSD-3-Clause |
| [SentencePiece](https://github.com/google/sentencepiece) | Tokenization | Apache-2.0 |
| [NumPy](https://github.com/numpy/numpy) | Audio arrays | BSD-3-Clause |
| [PyInstaller](https://github.com/pyinstaller/pyinstaller) | Standalone worker packaging | GPL-2.0-or-later with the PyInstaller exception |
| [Python](https://www.python.org/) | Embedded runtime | PSF License Agreement |

The dependency versions used for a build are pinned in `requirements.txt`.
The GigaAM `e2e_rnnt` model is pinned to commit
`7655ad717f8122257385bb4b2f373db3697e8680`; its files are downloaded from
Hugging Face on first launch and are not stored in this repository or DMG.

Redistributors should review the complete license texts shipped by the
upstream projects. A locally built app also contains this notice and the
VoiceNotes license in `Contents/Resources`.
