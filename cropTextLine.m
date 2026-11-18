function [crop, quad] = cropTextLine(frame, letters, angle, extendEnds)
% Crop along the detected line. Optionally look for missing end letters.
% A shear levels an oblique baseline while keeping upright letter stems.
% Steep text uses rotation. This is an affine approximation, not a full
% perspective correction; curved surfaces and strong foreshortening remain.
if nargin < 4, extendEnds = false; end
extra = 0.12;
if extendEnds, extra = 2.5; end

corners = [letters(:,1:2); letters(:,1:2)+[letters(:,3) zeros(size(letters,1),1)]; ...
    letters(:,1:2)+letters(:,3:4); letters(:,1:2)+[zeros(size(letters,1),1) letters(:,4)]];
if abs(angle) <= 45
    m = tand(angle);
    coordinates = [corners(:,1), corners(:,2)-m*corners(:,1)];
    basis = [1 m; 0 1];
    height = median(letters(:,4));
else
    direction = [cosd(angle) sind(angle)];
    normal = [-direction(2) direction(1)];
    coordinates = corners * [direction' normal'];
    basis = [direction; normal];
    height = median(letters(:,3:4) * abs(normal'));
end
low = min(coordinates,[],1) - [extra 0.12]*height;
high = max(coordinates,[],1) + [extra 0.12]*height;
quad = [low; high(1) low(2); high; low(1) high(2)] * basis;
wh = max(2,ceil(high-low));
destination = [1 1; wh(1) 1; wh; 1 wh(2)];
transform = fitgeotform2d(quad,destination,'affine');
gray = im2uint8(im2gray(frame));
x = max(1,min(size(gray,2),round(quad(:,1))));
y = max(1,min(size(gray,1),round(quad(:,2))));
background = median(gray(sub2ind(size(gray),y,x)));
crop = imwarp(gray,transform,'OutputView',imref2d(fliplr(wh)),'FillValues',background);
if ~extendEnds, return; end

% Search only near an established line, using component size and spacing.
g = imadjust(crop);
border = [g(1,:) g(end,:) g(:,1)' g(:,end)'];
if median(border) < 128, g = 255-g; end
stats = regionprops(~imbinarize(g),'BoundingBox','Area');
if isempty(stats)
    [crop,quad] = cropTextLine(frame,letters,angle,false);
    return;
end
b = vertcat(stats.BoundingBox);
keep = b(:,4) > 0.4*height & b(:,4) < 1.6*height & [stats.Area]' > 0.04*height^2;
b = b(keep,:);
left = 2.5*height+1;
right = size(crop,2)-2.5*height;
for k = 1:size(b,1)
    previous = [left right];
    nearby = b(:,1) < right+0.7*height & b(:,1)+b(:,3) > left-0.7*height;
    left = min([left; b(nearby,1)]);
    right = max([right; b(nearby,1)+b(nearby,3)]);
    if isequal(previous,[left right]), break; end
end
left = max(1,floor(left-0.12*height));
right = min(size(crop,2),ceil(right+0.12*height));
quad = transformPointsInverse(transform,[left 1;right 1;right size(crop,1);left size(crop,1)]);
crop = crop(:,left:right);
end
