function [correctedROIs, info] = GeometricCorrection(frame, boxes, options)
%GEOMETRICCORRECTION Deskew and rectify text crops before OCR.

if nargin < 3, options = struct(); end
validateattributes(frame, {'numeric','logical'}, ...
    {'real','nonsparse','nonempty','finite'}, mfilename,'frame');
if ndims(frame) > 3 || ~ismember(size(frame,3),[1 3])
    error('GeometricCorrection:Image','Use a grayscale or RGB image.');
end
if isfloat(frame) && any(frame(:) < 0 | frame(:) > 1)
    error('GeometricCorrection:Range','Floating-point images must be in [0,1].');
end
validateattributes(boxes,{'numeric'},{'real','2d','nonsparse'},mfilename,'boxes');
if ~ismember(size(boxes,2),[4 5]) && ~isempty(boxes)
    error('GeometricCorrection:Boxes','Boxes must have 4 or 5 columns.');
end
if size(boxes,2) == 5 && any(isinf(boxes(:,5)))
    error('GeometricCorrection:Angle','An angle hint must be finite or NaN.');
end
[padding, angleOptions, perspectiveOptions, enabled, maxOutput, resolveOrientation] = settings(options);
if isfield(perspectiveOptions,'Corners') && iscell(perspectiveOptions.Corners) && ...
        numel(perspectiveOptions.Corners) ~= size(boxes,1)
    error('GeometricCorrection:Corners','Supply one corners cell per text box.');
end
correctedROIs = cell(size(boxes,1),1);
info = repmat(emptyInfo(),size(boxes,1),1);

for index = 1:size(boxes,1)
    box = double(boxes(index,1:4));
    info(index).sourceBox = box;
    if any(~isfinite(box)) || any(box(3:4) <= 0)
        correctedROIs{index} = frame([],[],:);
        info(index).status = 'invalid-box';
        info(index).reason = 'Box has nonfinite coordinates or nonpositive dimensions.';
        continue;
    end
    [roi,origin,cropBox] = cropOriginal(frame,box,padding);
    if isempty(roi)
        correctedROIs{index} = roi;
        info(index).status = 'invalid-box';
        info(index).reason = 'Box does not overlap the image.';
        continue;
    end
    correctedROIs{index} = roi;
    info(index).cropOriginXY = origin;
    info(index).cropBox = cropBox;
    info(index).sourcePolygon = boxCorners(box);
    info(index).outputSizeHW = [size(roi,1) size(roi,2)];
    info(index).outputReference = imref2d(info(index).outputSizeHW);
    info(index).transform = projtform2d(translation(1-origin(1),1-origin(2)));
    info(index).outputTextPolygon = transformPointsForward( ...
        info(index).transform,info(index).sourcePolygon);

    % Estimate text direction.
    localAngleOptions = angleOptions;
    if size(boxes,2) == 5
        localAngleOptions.OriginalSkewHint = double(boxes(index,5));
    end
    [lineAngle, angleDiagnostics] = estimateROILineDirection(roi,localAngleOptions);
    info(index).diagnostics = angleDiagnostics;
    info(index).reason = angleDiagnostics.reason;
    info(index).lineAngle = lineAngle;
    if angleDiagnostics.accepted, info(index).correctionAngle = -lineAngle; end

    % Find sign edges in the original frame.
    geometry = struct('accepted',false);
    if enabled
        localPerspective = perspectiveOptions;
        if isfield(localPerspective,'Corners') && iscell(localPerspective.Corners)
            localPerspective.Corners = localPerspective.Corners{index};
        end
        if angleDiagnostics.accepted && ~isempty(angleDiagnostics.supportPoints)
            localPerspective.TextSupport = angleDiagnostics.supportPoints+origin-1;
        end
        [geometry,perspectiveDiagnostics] = estimateSignPerspective( ...
            frame,box,lineAngle,localPerspective);
        info(index).perspectiveDiagnostics = perspectiveDiagnostics;
    else
        info(index).perspectiveDiagnostics = struct('accepted',false, ...
            'reason','Perspective correction is disabled.');
    end

    % Apply one warp to the original pixels.
    if geometry.accepted
        outputSupport = info(index).sourcePolygon;
        if angleDiagnostics.accepted && ~isempty(angleDiagnostics.supportPoints)
            outputSupport = angleDiagnostics.supportPoints+origin-1;
        end
        [transform,outputSize,valid] = perspectiveOutput( ...
            geometry,outputSupport,padding,maxOutput);
        if valid
            bounds = [min(geometry.corners,[],1) max(geometry.corners,[],1)];
            signBox = [bounds(1:2)-2 bounds(3:4)-bounds(1:2)+4];
            [source,sourceOrigin] = cropOriginal(frame,signBox,0);
            corrected = warpOriginal( ...
                source,sourceOrigin,transform,outputSize,roi);
            [correctedROIs{index},info(index)] = finalizeOutput(corrected, ...
                info(index),transform,outputSize,resolveOrientation,geometry.orientationAnchored);
            info(index).accepted = true;
            info(index).perspectiveAccepted = true;
            info(index).signCorners = geometry.corners;
            info(index).aspectRatioSource = geometry.aspectRatioSource;
            info(index).status = 'perspective-rectified';
            info(index).reason = 'Supported sign boundary; homography includes rotation.';
            info(index).resamplingPasses = 1;
            continue;
        end
        info(index).perspectiveDiagnostics.accepted = false;
        info(index).perspectiveDiagnostics.reason = ...
            'Rectified text crop is empty, nonfinite, or exceeds output limits.';
    end
    if ~angleDiagnostics.accepted
        info(index).reason = [angleDiagnostics.reason ' Perspective: ' ...
            info(index).perspectiveDiagnostics.reason];
        continue;
    end
    info(index).accepted = true;
    if abs(lineAngle) < 0.025
        info(index).status = 'already-aligned';
        continue;
    end
    [transform,outputSize] = rotationOutput(cropBox,-lineAngle);
    if any(outputSize > maxOutput)
        info(index).accepted = false;
        info(index).reason = 'Rotation output exceeds the configured size limit.';
        continue;
    end
    corrected = warpOriginal(roi,origin,transform,outputSize,roi);
    [correctedROIs{index},info(index)] = finalizeOutput(corrected, ...
        info(index),transform,outputSize,resolveOrientation,false);
    info(index).status = 'deskewed';
    info(index).resamplingPasses = 1;
end
end

function [roi,origin,box] = cropOriginal(frame,sourceBox,padding)
pad = padding*min(sourceBox(3:4));
x1 = max(1,ceil(sourceBox(1)-pad));
y1 = max(1,ceil(sourceBox(2)-pad));
x2 = min(size(frame,2),floor(sourceBox(1)+sourceBox(3)+pad));
y2 = min(size(frame,1),floor(sourceBox(2)+sourceBox(4)+pad));
origin = [x1 y1];
box = [x1 y1 max(0,x2-x1+1) max(0,y2-y1+1)];
if x2 < x1 || y2 < y1, roi = frame([],[],:); return; end
roi = frame(y1:y2,x1:x2,:);
end

function [transform,outputSize] = rotationOutput(cropBox,angle)
% Bound the rotated pixel edges.
rotation = [cosd(angle) sind(angle) 0; -sind(angle) cosd(angle) 0; 0 0 1];
mapped = transformPointsForward(projtform2d(rotation), ...
    boxCorners([cropBox(1:2)-0.5 cropBox(3:4)]));
low = min(mapped,[],1);
extent = max(mapped,[],1)-low;
outputSize = max(1,ceil(fliplr(extent)-1e-9));
transform = projtform2d(translation(0.5-low(1),0.5-low(2))*rotation);
end

function [transform,outputSize,valid] = perspectiveOutput(geometry,polygon,padding,maxOutput)
transform = [];
outputSize = [];
valid = false;
denominator = [polygon ones(size(polygon,1),1)]*geometry.transform.A(3,:).';
if ~(all(denominator > 0) || all(denominator < 0)) || ...
        min(abs(denominator)) < 1e-5*max(abs(denominator)), return; end
mapped = transformPointsForward(geometry.transform,polygon);
if any(~isfinite(mapped(:))), return; end
pad = padding*min(max(mapped,[],1)-min(mapped,[],1));
low = max([1 1],floor(min(mapped,[],1)-pad));
high = min(fliplr(geometry.outputSizeHW),ceil(max(mapped,[],1)+pad));
outputSize = fliplr(high-low+1);
if any(outputSize < 2) || any(outputSize > maxOutput), return; end
transform = projtform2d(translation(1-low(1),1-low(2))*geometry.transform.A);
valid = true;
end

function corrected = warpOriginal(source,origin,transform,outputSize,backgroundROI)
% Map crop coordinates to the original frame.
localTransform = projtform2d(transform.A*translation(origin(1)-1,origin(2)-1));
background = borderBackground(backgroundROI);
workImage = double(source)-background;
if islogical(source), interpolation = 'nearest'; else, interpolation = 'cubic'; end
warped = imwarp(workImage,localTransform,interpolation, ...
    'OutputView',imref2d(outputSize),'FillValues',0)+background;
if isinteger(source)
    warped = max(double(intmin(class(source))),min(double(intmax(class(source))),warped));
    corrected = cast(warped,class(source));
elseif islogical(source)
    corrected = warped >= 0.5;
else
    corrected = cast(max(0,min(1,warped)),class(source));
end
end

function background = borderBackground(roi)
border = false(size(roi,1),size(roi,2));
border([1 end],:) = true;
border(:,[1 end]) = true;
background = zeros(1,1,size(roi,3));
for channel = 1:size(roi,3)
    plane = double(roi(:,:,channel));
    background(1,1,channel) = median(plane(border));
end
end

function [corrected,value] = finalizeOutput(corrected,value,transform,outputSize,resolveOrientation,anchored)
if anchored
    value.orientationStatus = 'supplied-corners';
elseif resolveOrientation && abs(value.lineAngle) >= 45
    [corrected,value.orientationRotation,value.orientationScores,value.orientationStatus] = ...
        chooseOrientation(corrected);
    if value.orientationRotation == 180
        halfTurn = [-1 0 outputSize(2)+1; 0 -1 outputSize(1)+1; 0 0 1];
        transform = projtform2d(halfTurn*transform.A);
    end
end
value.transform = transform;
value.outputReference = imref2d(outputSize);
value.outputSizeHW = outputSize;
value.outputTextPolygon = transformPointsForward(transform,value.sourcePolygon);
end

function [corrected,rotation,scores,status] = chooseOrientation(corrected)
rotation = 0;
scores = [NaN NaN];
status = 'ocr-unavailable';
if isempty(which('ocr')), return; end

ocrImage = im2uint8(im2gray(corrected));
try
    base = ocr(ocrImage,'LayoutAnalysis','line');
    reversed = ocr(ocrImage(end:-1:1,end:-1:1),'LayoutAnalysis','line');
catch
    % Keep the crop if OCR is unavailable.
    return;
end
confidence = {textConfidence(base),textConfidence(reversed)};
characterCounts = cellfun(@numel,confidence);
targetCount = max(3,0.75*max(characterCounts));
scores = [0 0];
for index = 1:2
    values = confidence{index};
    count = characterCounts(index);
    if count == 0, continue; end
    % Penalize weak or short reads.
    lowerTail = mean(mink(values,ceil(count/4)));
    scores(index) = (0.5*mean(values)+0.5*lowerTail)*min(1,count/targetCount);
end
[~,best] = max(scores);
status = 'ambiguous';
if nnz(confidence{best} >= 0.55) < 2 || abs(diff(scores)) < 0.025
    return;
end
status = 'ocr-selected';
if best == 2
    corrected = corrected(end:-1:1,end:-1:1,:);
    rotation = 180;
end
end

function confidence = textConfidence(result)
confidence = double(result.CharacterConfidences(:));
keep = isstrprop(result.Text(:),'alphanum') & isfinite(confidence);
confidence = confidence(keep);
end

function corners = boxCorners(box)
corners = [box(1) box(2); box(1)+box(3) box(2); ...
    box(1)+box(3) box(2)+box(4); box(1) box(2)+box(4)];
end

function matrix = translation(x,y)
matrix = [1 0 x; 0 1 y; 0 0 1];
end

function [padding,angle,perspective,enabled,maxOutput,resolveOrientation] = settings(input)
if ~isstruct(input) || ~isscalar(input)
    error('GeometricCorrection:Options','options must be a scalar struct.');
end
padding = 0.06;
maxOutput = 4096;
resolveOrientation = true;
angle = struct();
perspective = struct();
if isfield(input,'PaddingFraction'), padding = input.PaddingFraction; input = rmfield(input,'PaddingFraction'); end
if isfield(input,'MaxOutputDimension'), maxOutput = input.MaxOutputDimension; input = rmfield(input,'MaxOutputDimension'); end
if isfield(input,'ResolveVerticalOrientation')
    resolveOrientation = input.ResolveVerticalOrientation;
    input = rmfield(input,'ResolveVerticalOrientation');
end
if isfield(input,'Angle'), angle = input.Angle; input = rmfield(input,'Angle'); end
if isfield(input,'Perspective'), perspective = input.Perspective; input = rmfield(input,'Perspective'); end
if ~isstruct(angle) || ~isscalar(angle) || ~isstruct(perspective) || ~isscalar(perspective)
    error('GeometricCorrection:Options','Angle and Perspective must be scalar structs.');
end
names = fieldnames(input);
for index = 1:numel(names)
    if isfield(angle,names{index})
        error('GeometricCorrection:Option','Duplicate angle option: %s.',names{index});
    end
    angle.(names{index}) = input.(names{index});
end
enabled = true;
if isfield(perspective,'Enabled')
    enabled = perspective.Enabled;
    perspective = rmfield(perspective,'Enabled');
end
validateattributes(padding,{'numeric'},{'real','finite','scalar','>=',0,'<=',0.5});
validateattributes(maxOutput,{'numeric'},{'real','finite','scalar','integer','>=',32,'<=',8192});
validateattributes(enabled,{'logical'},{'scalar'});
validateattributes(resolveOrientation,{'logical'},{'scalar'});
end

function value = emptyInfo()
value = struct('sourceBox',[],'cropBox',[],'cropOriginXY',[], ...
    'accepted',false,'lineAngle',NaN,'correctionAngle',NaN, ...
    'orientationRotation',0,'orientationScores',[NaN NaN],'orientationStatus','not-checked', ...
    'status','unchanged','reason','','outputSizeHW',[], ...
    'diagnostics',struct(),'perspectiveAccepted',false, ...
    'perspectiveDiagnostics',struct(),'signCorners',[], ...
    'aspectRatioSource','','transform',[],'outputReference',[], ...
    'sourcePolygon',[],'outputTextPolygon',[],'resamplingPasses',0);
end
