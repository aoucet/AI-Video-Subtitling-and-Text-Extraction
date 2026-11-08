function boxes = detectTextRegions(frame)

% Preprocessing
if size(frame, 3) == 3
    gray = rgb2gray(frame);
else
    gray = frame;
end

enhanced = imadjust(gray);
smoothed = imgaussfilt(enhanced, 0.7);

% Detect MSER regions
[~, cc] = detectMSERFeatures(smoothed);
stats = regionprops(cc, 'BoundingBox');

if isempty(stats)
    boxes = zeros(0,4);
    return;
end

boxes = vertcat(stats.BoundingBox);

% Filter unwanted regions
H = size(frame, 1);
W = size(frame, 2);

ratio = boxes(:,3) ./ boxes(:,4);

keep = (ratio <= 3) & ...
    (boxes(:,4) >= 0.01 * H) & ...
    (boxes(:,4) <= 0.12 * H);

boxes = boxes(keep, :);

if isempty(boxes)
    boxes = zeros(0,4);
    return;
end

% Expand boxes
padX = 0.35 * boxes(:,4);
padY = 0.15 * boxes(:,4);

x1 = max(1, boxes(:,1) - padX);
y1 = max(1, boxes(:,2) - padY);
x2 = min(W, boxes(:,1) + boxes(:,3) + padX);
y2 = min(H, boxes(:,2) + boxes(:,4) + padY);

expanded = [x1, y1, x2-x1, y2-y1];

% Group overlapping boxes
overlap = bboxOverlapRatio(expanded, expanded);
n = size(overlap, 1);
overlap(1:n+1:end) = 0;

groups = conncomp(graph(overlap > 0))';

% Merge groups
xmin = accumarray(groups, boxes(:,1), [], @min);
ymin = accumarray(groups, boxes(:,2), [], @min);
xmax = accumarray(groups, boxes(:,1)+boxes(:,3), [], @max);
ymax = accumarray(groups, boxes(:,2)+boxes(:,4), [], @max);

merged = [xmin, ymin, xmax-xmin, ymax-ymin];

% Keep likely horizontal text
counts = accumarray(groups, 1);
groupRatio = merged(:,3) ./ merged(:,4);

boxes = merged((counts >= 2) & (groupRatio >= 2), :);

end