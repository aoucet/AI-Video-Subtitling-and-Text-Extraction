function [correctedROIs, info] = GeometricCorrection(frame, boxes, options)
%GEOMETRICCORRECTION Deskew and rectify planar sign text before OCR/NCC.
% [patches, info] = GeometricCorrection(originalFrame, boxes, options)
% boxes: N-by-4 [x y width height], ORIGINAL frame coordinates. Each box
% contains one word or one straight line, already grouped by detection.
% Optional column 5: original skew (degrees, visually positive CCW).
%
% Estimate direction from character and whole-word evidence, then seek a
% supported sign boundary in the original frame. The sign homography already
% includes rotation: do NOT add the measured skew a second time. Sample
% original pixels at most ONCE. Uncertain perspective -> supported rotation;
% uncertain angle AND perspective -> unchanged crop, accepted=false.
%
% options.PaddingFraction: margin, default 0.06.
% options.Angle: estimateROILineDirection settings (old flat settings work).
% options.Perspective.Enabled: true by default; false for deskew only.
% options.Perspective.Corners: optional true [TL;TR;BR;BL] ORIGINAL XY, as
% 4-by-2 shared-sign corners or an N-cell array ([] means automatic search).
% options.Perspective.AspectRatio: optional known physical sign width/height.
% Other Perspective settings pass through to estimateSignPerspective.
% options.MaxOutputDimension: resource limit, default 4096 pixels per side.
%
% Outputs retain input order/class. info.transform maps ORIGINAL frame XY
% to output pixel XY; transformPointsInverse maps OCR locations back.
% info.lineAngle is a measurement, NOT an extra rotation after homography.
% It can be NaN when perspective is valid but angle estimation is uncertain.
% Requires MATLAB R2022b+ and Image Processing Toolbox. No OCR is performed.

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
[padding, angleOptions, perspectiveOptions, enabled, maxOutput] = settings(options);
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

    % 1- Deskew: estimate direction; defer rotation until the final warp.
    localAngleOptions = angleOptions;
    if size(boxes,2) == 5
        localAngleOptions.OriginalSkewHint = double(boxes(index,5));
    end
    [lineAngle, angleDiagnostics] = estimateROILineDirection(roi,localAngleOptions);
    info(index).diagnostics = angleDiagnostics;
    info(index).reason = angleDiagnostics.reason;
    info(index).lineAngle = lineAngle;
    if angleDiagnostics.accepted, info(index).correctionAngle = -lineAngle; end

    % 2- Perspective: actual sign edges in the ORIGINAL frame + context.
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

    % 3- Choose ONE mapping and sample original pixels ONCE.
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
            correctedROIs{index} = warpOriginal( ...
                source,sourceOrigin,transform,outputSize,roi);
            info(index) = setMapping(info(index),transform,outputSize);
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
    correctedROIs{index} = warpOriginal(roi,origin,transform,outputSize,roi);
    info(index) = setMapping(info(index),transform,outputSize);
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
% Rotate image coordinates (y down); bound transformed pixel CELL edges.
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
% Indexing a crop is not resampling. Map its local XY into original XY.
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

function value = setMapping(value,transform,outputSize)
value.transform = transform;
value.outputReference = imref2d(outputSize);
value.outputSizeHW = outputSize;
value.outputTextPolygon = transformPointsForward(transform,value.sourcePolygon);
end

function corners = boxCorners(box)
corners = [box(1) box(2); box(1)+box(3) box(2); ...
    box(1)+box(3) box(2)+box(4); box(1) box(2)+box(4)];
end

function matrix = translation(x,y)
matrix = [1 0 x; 0 1 y; 0 0 1];
end

function [padding,angle,perspective,enabled,maxOutput] = settings(input)
if ~isstruct(input) || ~isscalar(input)
    error('GeometricCorrection:Options','options must be a scalar struct.');
end
padding = 0.06;
maxOutput = 4096;
angle = struct();
perspective = struct();
if isfield(input,'PaddingFraction'), padding = input.PaddingFraction; input = rmfield(input,'PaddingFraction'); end
if isfield(input,'MaxOutputDimension'), maxOutput = input.MaxOutputDimension; input = rmfield(input,'MaxOutputDimension'); end
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
end

function value = emptyInfo()
value = struct('sourceBox',[],'cropBox',[],'cropOriginXY',[], ...
    'accepted',false,'lineAngle',NaN,'correctionAngle',NaN, ...
    'status','unchanged','reason','','outputSizeHW',[], ...
    'diagnostics',struct(),'perspectiveAccepted',false, ...
    'perspectiveDiagnostics',struct(),'signCorners',[], ...
    'aspectRatioSource','','transform',[],'outputReference',[], ...
    'sourcePolygon',[],'outputTextPolygon',[],'resamplingPasses',0);
end
