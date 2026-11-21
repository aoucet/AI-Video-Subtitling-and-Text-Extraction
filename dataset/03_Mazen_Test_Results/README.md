# Task 4 results

These results cover the full text detection and recognition system.

- **Task 4 Report Results.docx**: test method, results, examples and limitations for the report.
- **Task 4 Results.xlsx**: results for 72 team images, 140 public sample frames, lighting and angle groups, and three complete video checks.
- **Group 7 - Corrected References.xlsx**: reference text checked against the images.
- **figures**: example detections, app screenshots and the V15 reference image.
- **data**: the measurements behind the tables, saved as CSV files.
- **subtitles**: original SRT exports from the three full video tests.

The earlier processing version is 57e8d93. The updated processing version is 0d2cb98. The tested app is cf17585, which uses the same updated processing code. Public frame tests ran on 17 November 2026, team image tests on 18 November, and app video checks on 19 November.

For our 72 images, exact transcripts increased from 9 to 21. Character error fell from 51.0% to 38.6%. These images were used during development, so they are not an unseen test set.

The app finished V03, V04 and V15 and exported subtitles, but playback was below real time. The exports still have small timing errors. Camera capture was not tested. These limitations are included in the report and workbook.

The public comparison uses the same runs as `benchmarks/comparison-2026-11-17/Video Text Benchmark Comparison.xlsx`. It does not use the older `Video Text Benchmark -1.xlsx` timings. Public and team-image error rates use different scoring rules, so keep their tables separate.
