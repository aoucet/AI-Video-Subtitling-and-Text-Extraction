function [lineBoxes, lineTexts, members] = gtLines(wordBoxes, wordTexts)
%GTLINES Group compatible word annotations among mostly horizontal rows.
% Grouping uses only annotation geometry. Original word indices are retained.
% An AABB alone cannot establish reading order for vertical or steeply tilted text.

wordTexts = string(wordTexts);
wordTexts = wordTexts(:);
count = size(wordBoxes, 1);
if isempty(wordBoxes)
    assert(isempty(wordTexts), 'videobench:TextCount', 'Supply one transcript per word box.');
    lineBoxes = zeros(0, 4);
    lineTexts = strings(0, 1);
    members = cell(0, 1);
    return;
end
validateattributes(wordBoxes, {'numeric'}, {'real','finite','2d','nonsparse'});
assert(size(wordBoxes, 2) == 4 && all(wordBoxes(:, 3:4) > 0, 'all'), ...
    'videobench:InvalidBoxes', 'Use finite [x y width height] rows with positive width and height.');
assert(numel(wordTexts) == count && ~any(ismissing(wordTexts)) && all(strlength(strtrim(wordTexts)) > 0), ...
    'videobench:TextCount', 'Supply one nonempty transcript per word box.');
wordBoxes = double(wordBoxes);

x = wordBoxes(:, 1);
y = wordBoxes(:, 2);
width = wordBoxes(:, 3);
height = wordBoxes(:, 4);
right = x + width;
bottom = y + height;
centerX = x + width / 2;
centerY = y + height / 2;

shorter = min(height, height.');
taller = max(height, height.');
gap = x.' - right;
verticalOverlap = min(bottom, bottom.') - max(y, y.');
centerOffset = abs(centerY - centerY.');
baselineOffset = abs(bottom - bottom.');
eligible = centerX.' > centerX & ...
    shorter >= 0.55 * taller & verticalOverlap >= 0.55 * shorter & ...
    centerOffset <= 0.45 * taller & baselineOffset <= 0.48 * taller & ...
    gap >= -0.25 * min(width, width.') & gap <= 1.35 * taller;

% Each word can link to one neighbor on either side.
edgeCost = (abs(gap) + 2 * centerOffset + baselineOffset) ./ taller;
[leftWord, rightWord] = find(eligible);
cost = edgeCost(eligible);
edges = sortrows([cost(:), leftWord(:), rightWord(:)], [1 2 3]);
previous = zeros(count, 1);
following = zeros(count, 1);
for k = 1:size(edges, 1)
    a = edges(k, 2);
    b = edges(k, 3);
    if following(a) == 0 && previous(b) == 0
        following(a) = b;
        previous(b) = a;
    end
end

starts = find(previous == 0);
lineBoxes = zeros(numel(starts), 4);
lineTexts = strings(numel(starts), 1);
members = cell(numel(starts), 1);
for k = 1:numel(starts)
    list = starts(k);
    while following(list(end)) ~= 0
        list(end+1) = following(list(end)); %#ok<AGROW>
    end
    left = min(x(list));
    top = min(y(list));
    lineBoxes(k, :) = [left, top, max(right(list)) - left, max(bottom(list)) - top];
    lineTexts(k) = strjoin(strtrim(wordTexts(list)), " ");
    members{k} = list;
end
[lineBoxes, order] = sortrows(lineBoxes, [2 1]);
lineTexts = lineTexts(order);
members = members(order);
end
