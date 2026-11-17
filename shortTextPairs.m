function pairs = shortTextPairs(boxes, intensities, strokes, used, lines)
% Recover unambiguous pairs of nearby glyphs after accepting longer lines.
pairs = zeros(0, 4);
available = find(~used & boxes(:,3) <= boxes(:,4));
boxes = boxes(available, :);
intensities = intensities(available);
relativeStroke = strokes(available) ./ boxes(:,4);
centers = boxes(:,1:2) + boxes(:,3:4) / 2;
neighborCount = zeros(size(boxes,1), 1);
partners = zeros(size(boxes,1), 1);
pairHeights = zeros(size(boxes,1), 1);

for left = 1:size(boxes, 1)
    offset = centers - centers(left,:);
    nearby = offset(:,1) > 0 & offset(:,1) <= 2 * boxes(left,4) & ...
        abs(offset(:,2)) <= tand(20) .* offset(:,1) & ...
        abs(intensities - intensities(left)) < 40 & ...
        abs(relativeStroke - relativeStroke(left)) <= 0.12;
    right = find(nearby);
    if isempty(right), continue; end

    delta = offset(right,:);
    distance = hypot(delta(:,1), delta(:,2));
    along = abs(delta ./ distance);
    across = along(:,[2 1]);
    leftSize = boxes(left,3:4);
    rightSize = boxes(right,3:4);
    leftHeight = sum(leftSize .* across, 2);
    rightHeight = sum(rightSize .* across, 2);
    height = (leftHeight + rightHeight) / 2;
    gap = distance - sum((leftSize + rightSize) .* along, 2) / 2;
    compatible = min(leftHeight, rightHeight) >= 0.72 * max(leftHeight, rightHeight) & ...
        min(leftSize(1), rightSize(:,1)) >= 0.35 * max(leftSize(1), rightSize(:,1)) & ...
        gap >= -0.10 .* height & gap <= 0.38 .* height;
    right = right(compatible);
    if isempty(right), continue; end
    neighborCount(left) = neighborCount(left) + numel(right);
    neighborCount(right) = neighborCount(right) + 1;
    partners(left) = right(1);
    compatibleHeights = height(compatible);
    pairHeights(left) = compatibleHeights(1);
end

for left = reshape(find(neighborCount == 1 & partners > 0), 1, [])
    right = partners(left);
    if neighborCount(right) ~= 1, continue; end
    glyphs = boxes([left right],:);
    padding = 0.12 * pairHeights(left);
    low = min(glyphs(:,1:2), [], 1) - padding;
    high = max(glyphs(:,1:2) + glyphs(:,3:4), [], 1) + padding;
    pair = [low, high - low];
    accepted = [lines; pairs];
    if ~isempty(accepted) && any(bboxOverlapRatio(pair, accepted, 'Min') > 0.30), continue; end
    pairs(end+1,:) = pair; %#ok<AGROW>
end
end
