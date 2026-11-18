function [boxes, keep] = mapWordBoxes(boxes, mapping, quad, imageSize)
% Undo OCR padding, resizing, optional half-turn and the affine crop.
if isempty(boxes)
    keep = false(0,1);
    return;
end
low = boxes(:,1:2);
high = low + boxes(:,3:4);
x = [low(:,1), high(:,1), high(:,1), low(:,1)];
y = [low(:,2), low(:,2), high(:,2), high(:,2)];
points = [x(:), y(:)] - mapping.border;
% imresize maps pixel centres, so its inverse includes the half-pixel shift.
points = (points - 0.5) ./ mapping.resizeScale([2 1]) + 0.5;
wh = mapping.cropSize([2 1]);
if mapping.halfTurn, points = wh + 1 - points; end
cropCorners = [1 1; wh(1) 1; wh; 1 wh(2)];
transform = fitgeotform2d(cropCorners, quad, 'affine');
points = transformPointsForward(transform, points);
x = reshape(points(:,1), [], 4);
y = reshape(points(:,2), [], 4);
low = max([min(x,[],2), min(y,[],2)], [1 1]);
high = min([max(x,[],2), max(y,[],2)], imageSize([2 1]));
boxes = [low, high-low];
keep = all(isfinite(boxes),2) & all(boxes(:,3:4)>0,2);
boxes = boxes(keep,:);
end
