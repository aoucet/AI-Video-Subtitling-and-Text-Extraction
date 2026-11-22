# AI Video Subtitling and Text Extraction

**CMAI 480 Computer Vision · Group 7 · Qatar University · Fall 2026**

A MATLAB system that finds English text in video frames (signs, labels, screens), straightens it, reads it, and shows it as live subtitles. It works on a video file or a webcam stream and can export the result as an `.srt` subtitle file.

## Team

| Member | Student ID | Responsibility |
| --- | --- | --- |
| Majid Marzouq | 202309136 | GUI (`SubtitleApp`) and system integration |
| Mazen Assayed | 202310571 | MSER text detection, testing and benchmark |
| Huzayfa Khamis | 202309109 | Geometric correction |
| Mohamed Ayari | 202304380 | OCR and NCC verification |
| Anas Rustom | 202306240 | Dataset and ground truth |

## How it works

Each processed frame goes through `runTextPipeline`:

1. **Detect.** MSER regions are filtered by shape, stroke width and edge energy to keep character-like regions (`detectTextRegions.m`).
2. **Group.** Characters are grouped into text lines, and each line gets a fitted angle (`groupTextCandidates.m`).
3. **Straighten.** Each line is cropped along its angle. A shear levels tilted lines, and steep lines are rotated (`cropTextLine.m`).
4. **Read.** MATLAB OCR reads a grayscale and a binarized version of each crop, and the more confident reading is kept (`readTextLine.m`).
5. **Verify.** A **from-scratch normalized cross-correlation (NCC)** checks uncertain characters against A–Z and 0–9 templates (`ncc_matrix.m`, `verify_char.m`, `recognize_text_region.m`).
6. **Subtitle.** The app shows the boxes and a subtitle band, logs the text with timestamps, and exports `.srt` (`SubtitleApp.mlapp`).

`ncc_matrix.m` computes NCC directly from its formula, using no built-in correlation function. Its output matches MATLAB's `normxcorr2` to within about 1e-14.

## Requirements

- MATLAB R2026b (tested)
- Computer Vision Toolbox
- Image Processing Toolbox
- *Camera mode only:* MATLAB Support Package for USB Webcams (install it from Add-Ons)

## Running the app

Open the project folder in MATLAB, then run:

```matlab
SubtitleApp
```

- **Open Video** loads a `.mov`, `.mp4` or `.avi` file. **Play** and **Stop** control playback.
- **Open Camera** uses the first real (non-virtual) webcam.
- The check boxes turn MSER detection, geometric correction, NCC verification and box display on or off.
- **Every N frames** sets how often the pipeline runs. The default is 5. Results are reused between runs.
- **Export .srt** saves the timestamped subtitles.

Sample clips are in `dataset/01_Original_Videos/` (V01–V18).

## Running the tests

```matlab
report = test_full_pipeline();             % NCC + geometry checks, synthetic images, V15 screenshot and clip
report = test_full_pipeline("all");        % every dataset screenshot and clip (slow)
results = test_full_pipeline("benchmark"); % YVT and ICDAR 2013 evaluation
```

See [TESTING.md](TESTING.md) for full details, including how to set up the public datasets for the benchmark.

## Results (summary)

| Measure | Baseline → Final |
| --- | --- |
| Word-spotting F1, YVT (75 frames) | 0.29 → 0.49 |
| Word-spotting F1, ICDAR 2013 (65 frames) | 0.12 → 0.26 |
| Exact transcripts, our 72 frames | 9 → 21 |
| Character error rate, our 72 frames | 51.0% → 38.6% |

The full results are in `benchmarks/comparison-2026-11-17/` and `dataset/03_Mazen_Test_Results/`.

## Repository structure

| Path | Contents |
| --- | --- |
| `runTextPipeline.m` | Main pipeline: detect, crop, read, verify |
| `detectTextRegions.m`, `groupTextCandidates.m` | MSER detection and line grouping |
| `cropTextLine.m` | Affine line straightening used by the final pipeline |
| `GeometricCorrection.m`, `estimateROILineDirection.m`, `estimateSignPerspective.m` | Separate RANSAC skew and homography module (tested, not used by the final pipeline) |
| `readTextLine.m`, `recognize_text_region.m` | OCR and NCC verification |
| `ncc_matrix.m`, `verify_char.m`, `normalize_char_patch.m`, `make_char_templates.m`, `render_char_image.m` | From-scratch NCC and character templates |
| `SubtitleApp.mlapp` | App Designer GUI |
| `test_full_pipeline.m`, `tests/` | Test suite |
| `benchmarks/` | Benchmark code (`+videobench`), results and reference papers |
| `dataset/` | Recorded clips, labeled frames, ground-truth tracker and test results |

## Limitations

- English letters and digits only. Arabic text is out of scope.
- Not real time: the pipeline alone runs at about 1–2 frames per second, so the app processes every N-th frame.
- The main weakness is finding the text (detection recall); text that is found is usually read correctly.
- Each frame is processed independently. Text is not tracked across frames.
