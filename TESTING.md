# Testing the MATLAB pipeline

Open the project folder in MATLAB. The suite requires Computer Vision Toolbox and Image Processing Toolbox.

| Command | What it runs |
| --- | --- |
| `report = test_full_pipeline();` | Geometry and NCC checks, blank and tilted PARKING images, the V15 screenshot, and three frames from V15. |
| `report = test_full_pipeline("all");` | The same synthetic checks, every dataset screenshot, and three frames from every dataset clip. Allow more time for OCR across the dataset. |
| `report = test_full_pipeline("path/to/clip.mov", "EXPECTED WORDS");` | The synthetic checks and three frames from the selected clip. The phrase must appear in at least one frame. |

The runner samples each clip at 20%, 50%, and 80% of its duration. For the known V15 screenshot and clip, it checks for `FIRST AID`. Other dataset items exercise image and video decoding, MSER detection, geometry, OCR, and NCC, and report the recognized text. Omit the expected phrase in custom-clip mode to exercise the clip and see its results.

The `report` table includes the stage, detection and correction counts, recognition text before and after NCC, and per-frame pipeline time. Component checks include numerical NCC agreement, lighting changes, all 36 character templates, and deskewing and perspective cases with known synthetic geometry. A failed check prints its stage and reason before raising an error.

Keep the `tests` folder with the project when copying it to MATLAB Drive. The media folders can sit under `dataset/` or alongside `test_full_pipeline.m`.

## Public video datasets

```matlab
results = test_full_pipeline("benchmark");
```

The benchmark evaluates the same detection, geometry, OCR, and NCC functions on five evenly spaced annotated frames per clip. The default uses the 15 YVT test clips and the 13 labeled ICDAR 2013 training clips. Select one split with `struct('Datasets',"YVT")`, `struct('Datasets',"ICDAR2013TRAIN")`, or `struct('Datasets',"ICDAR2013")` for ICDAR test. Set `FramesPerClip` to a different positive integer or `Inf` for every annotated frame.

- **YVT.** Extract the original YVT package under `benchmarks/data/YVT`. The loader uses the supplied VATIC JPEGs for exact frame alignment and scales the 1280 × 720 reference boxes to the JPEG resolution of 720 × 405. The original archive can sit in `benchmarks/data/archives`.
- **ICDAR 2013.** Extract the labeled Challenge 3 training package under `benchmarks/data/ICDAR2013/train`. The loader selects the original 13 training clips in Table IX of the competition paper. For a future test run, put the 15 original test videos and their frame-level XML labels under `benchmarks/data/ICDAR2013/test`. The official test video ZIP contains lexicons. The scorer requires a separate frame-level XML reference. [Official downloads](https://rrc.cvc.uab.es/?ch=3&com=downloads)

The runner writes a summary, per-clip scores, and per-frame counts to `benchmarks/results`. It records frames with processing errors separately. A dataset with missing inputs gets an unavailable status. Set `RetryErrors` to `true` for a finished partial run to reprocess failed frames using the same dataset, sampling, and IoU threshold.

Line detection uses independently grouped reference words and matches them to the detector's original line boxes. Word spotting uses OCR word boxes mapped back through the geometric correction and matches both position and text. Both use one-to-one box matching at an intersection-over-union threshold of 0.50 by default. Text comparison ignores case and normalizes whitespace. End-to-end character and word error rates include misses and extra predictions. Matched word accuracy uses only predictions paired with a reference word by location.

The summary pools counts across the sampled frames. The papers under `benchmarks/papers` report track-level protocols using continuous video sequences. Report the MATLAB results as a sampled frame-level evaluation.

