# Text detection

`detectTextRegions.m` finds likely text regions in an RGB or grayscale image.
It returns `[x y width height]` boxes in the original image coordinates.
Keep `groupTextCandidates.m` in the same folder or on the MATLAB path.
The function needs Image Processing Toolbox and Computer Vision Toolbox.

## What it does

1. Convert the image to grayscale, resize large images, adjust contrast and
   apply a small Gaussian blur.
2. Use MSER to find possible characters. Remove regions with unlikely sizes
   or shapes.
3. Check stroke thickness and remove overlapping copies of the same candidate.
4. Compare Sobel edges before and after extra blur. This helps remove fine
   background patterns that look like letters.
5. Group nearby candidates with similar sizes and brightness. Try lines
   through nearby pairs, collect candidates close to each line and improve
   the line using least squares.
6. Check each group's spacing and height consistency, then add a small margin
   around the accepted group. Scale the boxes back to the original image.

The grouping allows tilted and vertical text. It checks nearby pairs directly;
it does not randomly sample pairs as RANSAC would. The output can cover a word,
part of a word or a whole text line. It is not guaranteed to give one box per
word, which the correction and OCR stages need to account for.

## Checks and remaining problems

- Ran on all 72 team photos: four frames from each of 18 scenes.
- Ran 37 generated test images, including four images without text.
- Checked empty results, image boundaries and RGB/grayscale input.
- MATLAB's code analyzer reports no warnings for either function.
- After the comment, naming and formatting cleanup, every box matched the
  saved results on all 109 images exactly.

The paragraph in scene 12 is much more complete than in the previous course
version. Some short words and word endings are still missed. INNOVATE, the fire
cabinet, Arabic text, connected logos, small text and heavily blurred images
remain difficult. Reflections and repeated background patterns can still
produce false detections.

These images were used during development, so they are not an independent
accuracy test. Median detection time was about 0.87 seconds per photo on the
development Mac. Real-time streaming and the full correction/OCR pipeline
have not been verified.

## Course concepts and references

Gaussian filtering and Sobel gradients come from the image-processing slides.
The scale comparison uses ideas from `FeatureExtraction_Part2.pdf`. Grouping
uses projections and distances from the linear-algebra and 2D-geometry slides,
plus least squares and the idea of finding supporting points from the image
alignment slides. The exact grouping procedure and numerical thresholds were
chosen through experiments; they are not a complete algorithm from a lecture.

MSER is the instructor-approved addition. The specific shape measurements,
stroke-width check and overlapping-box suppression are supplementary methods.

- [MathWorks: Automatically Detect and Recognize Text in Natural Images](https://www.mathworks.com/help/vision/ug/automatically-detect-and-recognize-text-in-natural-images.html)
  describes MSER shape filtering and measuring stroke consistency with a
  distance transform and thinning.
- [MathWorks: detectMSERFeatures](https://www.mathworks.com/help/vision/ref/detectmserfeatures.html)
  documents the candidate detector and its settings.
- [MathWorks: selectStrongestBbox](https://www.mathworks.com/help/vision/ref/selectstrongestbbox.html)
  documents the overlapping-box suppression.

AI assistance was used for code changes, experiments and these notes. The team
is responsible for understanding and choosing its pipeline and following the
course's AI-use rules.
