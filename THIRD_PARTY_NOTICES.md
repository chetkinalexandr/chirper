# Third-party notices

VoiceNotes uses the following third-party software. These components are not
covered by the VoiceNotes MIT license and remain subject to their own terms.

| Component | Purpose | License |
| --- | --- | --- |
| [GigaAM v3](https://huggingface.co/ai-sage/GigaAM-v3) | Speech recognition model | MIT |
| [gigaam-v3-onnx](https://huggingface.co/istupakov/gigaam-v3-onnx) | ONNX export of the model (int8) | MIT |
| [onnx-asr](https://github.com/istupakov/onnx-asr) | Model loading and RNN-T decoding | MIT |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Neural-network inference | MIT |
| [huggingface_hub](https://github.com/huggingface/huggingface_hub) | Downloading the pinned model revision | Apache-2.0 |
| [NumPy](https://github.com/numpy/numpy) | Audio arrays | BSD-3-Clause |
| [PyInstaller](https://github.com/pyinstaller/pyinstaller) | Standalone worker packaging | GPL-2.0-or-later with the PyInstaller exception |
| [Python](https://www.python.org/) | Embedded runtime | PSF License Agreement |

The dependency versions used for a build are pinned in `requirements.txt`.
The `gigaam-v3-onnx` `e2e_rnnt` int8 export is pinned to commit
`322c3b29492673eb7d0b434bfa9dfb8653e34d02`; its files are downloaded from
Hugging Face on first launch and are not stored in this repository or DMG.

Redistributors should review the complete license texts shipped by the
upstream projects. A locally built app also contains this notice and the
VoiceNotes license in `Contents/Resources`.
