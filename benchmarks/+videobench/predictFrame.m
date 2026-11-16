function result = predictFrame(frame, templates, labels)
% Read detected lines and map OCR word boxes back into the input frame.
lineBoxes = detectTextRegions(frame);
[crops, info] = GeometricCorrection(frame, lineBoxes);
result = struct('LineBoxes', lineBoxes, 'WordBoxes', zeros(0, 4), ...
    'Words', strings(0, 1), 'RawWords', strings(0, 1), ...
    'Deskewed', nnz(strcmp({info.status}, 'deskewed')), ...
    'Rectified', nnz(strcmp({info.status}, 'perspective-rectified')));
margin = 20;
for k = 1:numel(crops)
    if isempty(crops{k}), continue; end
    padded = padarray(crops{k}, [margin margin], 'replicate');
    read = recognize_text_region(padded, templates, labels, struct('returnWords', true));
    [boxes, keep] = originalBoxes(read.wordBoxes, info(k).transform, margin, size(frame));
    result.WordBoxes = [result.WordBoxes; boxes];
    result.Words = [result.Words; read.correctedWords(keep)];
    result.RawWords = [result.RawWords; read.words(keep)];
end
end

function [boxes, keep] = originalBoxes(boxes, transform, margin, imageSize)
if isempty(boxes)
    keep = false(0, 1);
    return;
end
low = boxes(:, 1:2) - margin;
high = low + boxes(:, 3:4);
x = [low(:,1), high(:,1), high(:,1), low(:,1)];
y = [low(:,2), low(:,2), high(:,2), high(:,2)];
[x, y] = transformPointsInverse(transform, x(:), y(:));
x = reshape(x, [], 4);
y = reshape(y, [], 4);
leftTop = max([min(x, [], 2), min(y, [], 2)], [1 1]);
rightBottom = min([max(x, [], 2), max(y, [], 2)], imageSize([2 1]));
boxes = [leftTop, rightBottom - leftTop];
keep = all(isfinite(boxes), 2) & all(boxes(:,3:4) > 0, 2);
boxes = boxes(keep, :);
end

