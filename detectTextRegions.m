function boxes = detectTextRegions(frame)
% Find likely text regions for the deskewing and OCR stages.
% Input: RGB or grayscale image. Output: [x y width height] in original pixels.
boxes = zeros(0, 4);

% 1. Convert to grayscale, resize, adjust contrast and smooth the image.
originalSize = [size(frame, 1), size(frame, 2)];
gray = im2uint8(im2gray(frame));
gray = imresize(gray, min(1, 1920 / max(originalSize)));
scale = [size(gray, 2) / originalSize(2), size(gray, 1) / originalSize(1)];
gray = imgaussfilt(imadjust(gray), 0.7);

% 2. Find MSER regions and remove shapes that are unlikely to be letters.
areaRange = [max(8, round(numel(gray) * 0.000008)), round(numel(gray) * 0.04)];
[~, regions] = detectMSERFeatures(gray, 'RegionAreaRange', areaRange, ...
    'ThresholdDelta', 3);
stats = regionprops(regions, gray, 'BoundingBox', 'MajorAxisLength', ...
    'MinorAxisLength', 'Solidity', 'Extent', 'EulerNumber', 'Image', 'MeanIntensity');
sizes = [stats.MajorAxisLength]';
axisRatio = [stats.MinorAxisLength]' ./ sizes;
solidity = [stats.Solidity]';
filledRegions = solidity > 0.92 & axisRatio > 0.45 & [stats.EulerNumber]' > 0;
keep = sizes >= 12 & sizes <= 0.45 * min(size(gray)) & axisRatio >= 0.1 & ...
    solidity >= 0.25 & [stats.Extent]' >= 0.2 & [stats.EulerNumber]' >= -2 & ~filledRegions;
stats = stats(keep);
sizes = sizes(keep);
axisRatio = axisRatio(keep);

% 3. Keep regions whose strokes have fairly consistent thickness.
strokes = zeros(numel(stats), 1);
variation = inf(numel(stats), 1);
for k = 1:numel(stats)
    mask = padarray(stats(k).Image, [1 1], false);
    distance = bwdist(~mask);
    skeleton = bwmorph(mask, 'thin', Inf);
    widths = 2 * double(distance(skeleton));
    strokes(k) = median(widths);
    variation(k) = std(widths) / max(mean(widths), eps);
end
keep = variation <= 0.4 & strokes ./ sizes <= 0.35;
candidates = vertcat(stats.BoundingBox);
candidates = candidates(keep, :);
sizes = sizes(keep);
axisRatio = axisRatio(keep);
variation = variation(keep);
meanGray = [stats.MeanIntensity]';
meanGray = meanGray(keep);
if isempty(candidates)
    return;
end

% 4. Remove overlapping detections of the same character.
[~, ~, selected] = selectStrongestBbox(candidates, 1 - variation, ...
    'OverlapThreshold', 0.3, 'RatioType', 'Union', 'NumStrongest', 3000);
candidates = candidates(selected, :);
sizes = sizes(selected);
axisRatio = axisRatio(selected);
meanGray = meanGray(selected);

% 5. Compare edges before and after extra blur to remove fine background texture.
[gx, gy] = imgradientxy(single(gray), 'Sobel');
fineEnergy = gx.^2 + gy.^2;
[gx, gy] = imgradientxy(imgaussfilt(single(gray), 1.4), 'Sobel');
coarseEnergy = gx.^2 + gy.^2;
survives = false(size(sizes));
for j = 1:numel(sizes)
    fineEdgesCrop = imcrop(fineEnergy, candidates(j, :));
    blurredEdgesCrop = imcrop(coarseEnergy, candidates(j, :));
    survives(j) = sum(blurredEdgesCrop(:)) >= 0.16 * sum(fineEdgesCrop(:));
end
candidates = candidates(survives, :);
sizes = sizes(survives);
axisRatio = axisRatio(survives);
meanGray = meanGray(survives);

% 6. Group nearby letters into text lines and check each group.
groups = groupTextCandidates(candidates, sizes, meanGray);
used = false(size(sizes));
for k = 1:numel(groups)
    members = groups{k};
    if any(used(members))
        continue;
    end
    if median(sizes(members)) < 18 && numel(members) < 6
        continue;
    end
    narrow = axisRatio(members);
    % Rows of very narrow shapes may come from a grille or fence.
    if median(narrow) < 0.25
        continue;
    end
    groupBoxes = candidates(members, :);
    centers = groupBoxes(:, 1:2) + groupBoxes(:, 3:4) / 2;
    direction = centers(end, :) - centers(1, :);
    direction = direction / norm(direction);
    normal = [-direction(2), direction(1)];
    heights = groupBoxes(:, 3:4) * abs(normal');
    gaps = sqrt(sum(diff(centers).^2, 2));
    if std(heights) / mean(heights) > 0.3
        continue;
    end
    if numel(members) < 6 && median(gaps) > 1.3 * median(heights)
        continue;
    end

    % Add some space around the box so letter edges are not cut off.
    padding = 0.12 * median(heights);
    low = min(groupBoxes(:, 1:2), [], 1) - padding;
    high = max(groupBoxes(:, 1:2) + groupBoxes(:, 3:4), [], 1) + padding;
    boxes(end+1, :) = [low, high - low]; %#ok<AGROW>
    % Only mark letters as used after accepting the group.
    used(members) = true;
end

% Scale the boxes back to the original image and keep them inside its edges.
low = max([1 1], floor(boxes(:, 1:2) ./ scale));
high = min(fliplr(originalSize), ceil((boxes(:, 1:2) + boxes(:, 3:4)) ./ scale));
boxes = [low, high - low];
end
