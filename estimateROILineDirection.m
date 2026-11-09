function [lineAngle, diagnostics] = estimateROILineDirection(roi, options)
%ESTIMATEROLINEDIRECTION Robust direction of a word/straight text line.
% [angle, d] = estimateROILineDirection(roi)
% angle is ORIGINAL skew: degrees, visually positive counterclockwise.
% Apply -angle using imrotate to straighten ORIGINAL image pixels.
% Rejection returns NaN with d.accepted=false and an explicit reason.
%
% Dark/bright adaptive and global masks -> whole-word broad-angle
% differential projection, with an independent component-consensus cue when
% separate glyphs exist. Connected writing does not require three blobs.
% Projection uses pixel coordinates and linear bin splatting, avoiding
% repeated image resampling. Image y increases downward: the correction
% angle is atan2d(dy,dx), and the visually CCW original skew its negative.
%
% options: scalar struct; see defaults() for supported tuning values.
% An optional OriginalSkewHint is validated against image evidence.
% Quality measures are heuristics, NOT calibrated probabilities.
% Requires Image Processing Toolbox, no OCR or Statistics Toolbox.
% References: MathWorks ransac/adaptthresh and official Leptonica skew.c.
% Single rotation does not rectify perspective or curved baselines. Angles
% are AXIAL: no pixel-line geometry can distinguish upright from upside down.

if nargin < 2, options = struct(); end
options = settings(options);
diagnostics = emptyDiagnostics();
lineAngle = NaN;
validateattributes(roi, {'numeric','logical'}, ...
    {'real','finite','nonsparse','nonempty'}, mfilename,'roi');
if ndims(roi) > 3 || ~ismember(size(roi,3),[1 3])
    error('estimateROILineDirection:Image','Use a grayscale or RGB crop.');
end
gray = im2single(im2gray(roi));
if any(gray(:) < 0 | gray(:) > 1)
    error('estimateROILineDirection:Range', ...
        'Floating-point input images must have intensities in [0,1].');
end
if min(size(gray)) < 12
    diagnostics.reason = 'ROI is too small for a supported line estimate.';
    return;
end
if max(gray(:))-min(gray(:)) < 0.02
    diagnostics.reason = 'Insufficient image contrast.';
    return;
end
scale = min(1, options.MaxDimension / max(size(gray)));
originalSize = size(gray);
if scale < 1
    gray = imresize(gray,ceil(originalSize*scale),'bicubic');
    gray = max(0,min(1,gray)); % Bicubic interpolation may overshoot [0,1].
end
scaleXY = [size(gray,2)/originalSize(2),size(gray,1)/originalSize(1)];
diagnostics.estimationScale = scale;
diagnostics.estimationScaleXY = scaleXY;
limits = stretchlim(gray,[0.01 0.99]);
if limits(2) > limits(1), gray = imadjust(gray,limits,[]); end
[height,width] = size(gray);
neighborhood = max(3,2*floor(min(height,width)/4)+1);
darkThreshold = adaptthresh(gray,0.45,'ForegroundPolarity','dark', ...
    'NeighborhoodSize',[neighborhood neighborhood],'Statistic','gaussian');
brightThreshold = adaptthresh(gray,0.45,'ForegroundPolarity','bright', ...
    'NeighborhoodSize',[neighborhood neighborhood],'Statistic','gaussian');
globalThreshold = graythresh(gray);
% ForegroundPolarity changes thresholds, not the logical polarity itself.
masks = {gray < darkThreshold, gray > brightThreshold, ...
         gray < globalThreshold, gray > globalThreshold};
names = {'adaptive-dark','adaptive-bright','global-dark','global-bright'};
candidates = repmat(emptyCandidate(),0,1);
failureReasons = cell(1,numel(masks));
for maskIndex = 1:numel(masks)
    [candidate, reason] = analyzeMask(masks{maskIndex},options);
    failureReasons{maskIndex} = reason;
    if ~candidate.accepted, continue; end
    candidate.maskName = names{maskIndex};
    % Explicit output-size resizing can round X/Y scales differently. Return
    % directions in original ROI coordinates, not the resized pixel grid.
    candidate.correctionAngle = originalAngle(candidate.correctionAngle,scaleXY);
    candidate.coarseAngle = originalAngle(candidate.coarseAngle,scaleXY);
    candidate.componentCueAngle = originalAngle(candidate.componentCueAngle,scaleXY);
    candidate.majorAxisAngle = originalAngle(candidate.majorAxisAngle,scaleXY);
    candidate.profileAngles = originalAngle(candidate.profileAngles,scaleXY);
    candidate.peakBounds = originalAngle(candidate.peakBounds,scaleXY);
    if numel(candidate.peakBounds) == 2
        candidate.peakWidth = abs(diff(candidate.peakBounds));
    end
    candidates(end+1,1) = candidate; %#ok<AGROW>
end
diagnostics.maskFailureReasons = failureReasons;
if isempty(candidates)
    diagnostics.reason = ['No mask produced a reliable text-line estimate. ' ...
        strjoin(unique(failureReasons),' | ')];
    return;
end

% Comparable-quality masks that disagree mean ambiguity, not a vote to guess.
[~,order] = sort([candidates.quality],'descend');
best = candidates(order(1));
competitive = candidates([candidates.quality] >= 0.65*best.quality);
angles = [competitive.correctionAngle];
if numel(angles) > 1 && max(axialDistance(angles,best.correctionAngle)) > ...
        options.MaxMaskDisagreement
    diagnostics.reason = 'Comparable foreground masks disagree on direction.';
    diagnostics.maskAngles = -[candidates.correctionAngle];
    return;
end
if isfinite(options.OriginalSkewHint) && ...
        axialDistance(best.correctionAngle,-options.OriginalSkewHint) > ...
        options.MaxHintDisagreement
    diagnostics.reason = 'Provided angle hint disagrees with the image estimate.';
    diagnostics.maskAngles = -[candidates.correctionAngle];
    return;
end
lineAngle = -best.correctionAngle;
diagnostics.accepted = true;
diagnostics.reason = best.reason;
diagnostics.method = best.method;
diagnostics.maskName = best.maskName;
diagnostics.lineAngle = lineAngle;
diagnostics.correctionAngle = best.correctionAngle;
diagnostics.coarseCorrectionAngle = best.coarseAngle;
diagnostics.componentCount = best.componentCount;
diagnostics.inlierCount = best.inlierCount;
diagnostics.inlierFraction = best.inlierFraction;
diagnostics.alignmentResidualFraction = best.residualFraction;
diagnostics.profilePeakRatio = best.peakRatio;
diagnostics.profilePeakWidthDeg = best.peakWidth;
diagnostics.profileAngles = best.profileAngles;
diagnostics.profileScores = best.profileScores;
diagnostics.maskAngles = -[candidates.correctionAngle];
% Bounding-box origins, like pixel centres, carry a half-pixel offset.
diagnostics.supportBoxes = best.supportBoxes;
diagnostics.supportBoxes(:,1:2) = (best.supportBoxes(:,1:2)-0.5)./scaleXY+0.5;
diagnostics.supportBoxes(:,3:4) = best.supportBoxes(:,3:4)./scaleXY;
diagnostics.supportCenters = (best.supportCenters-0.5)./scaleXY+0.5;
diagnostics.supportPoints = (best.supportPoints-0.5)./scaleXY+0.5;
diagnostics.quality = best.quality;
diagnostics.wholeWordAccepted = best.wholeWordAccepted;
diagnostics.componentCueAccepted = best.componentCueAccepted;
diagnostics.componentCueAngle = -best.componentCueAngle;
diagnostics.foregroundFraction = best.foregroundFraction;
diagnostics.elongation = best.elongation;
diagnostics.peakCompetitionRatio = best.competitionRatio;
diagnostics.majorAxisCorrectionAngle = best.majorAxisAngle;
diagnostics.orientationAmbiguous = true;
end

function [candidate, reason] = analyzeMask(mask, options)
% The whole-word branch never uses MinCharacters. Connected letters remain
% intact; only specks, clear border frames and filled background slabs leave.
[mask, geometry, reason] = cleanForeground(mask,options);
candidate = emptyCandidate();
if ~isempty(reason), return; end
[whole, wholeReason] = analyzeWholeWord(mask,geometry,options);
[component, componentReason] = analyzeComponentMask(mask,options);
if whole.accepted && component.componentCueAccepted && ...
        axialDistance(whole.correctionAngle,component.coarseAngle) > ...
        options.MaxCueDisagreement
    reason = 'Whole-word projection conflicts with robust component alignment.';
    return;
end
if whole.accepted
    candidate = whole;
    if component.componentCueAccepted
        candidate.method = 'component-consensus-plus-whole-word-projection';
        candidate.reason = 'Whole-word projection and component alignment agree.';
        candidate.componentCueAccepted = true;
        candidate.componentCueAngle = component.coarseAngle;
        candidate.inlierCount = component.inlierCount;
        candidate.inlierFraction = component.inlierFraction;
        candidate.residualFraction = component.residualFraction;
        candidate.quality = candidate.quality * ...
            (1+0.04*min(candidate.inlierCount,10));
    end
    reason = '';
elseif component.accepted && ~whole.ambiguous
    % Retain the established component path when a whole-mask estimate is
    % unsupported (for example modest clutter), but never override a strong
    % contradictory/ambiguous whole-word direction.
    candidate = component;
    candidate.foregroundFraction = geometry.fraction;
    candidate.elongation = geometry.elongation;
    candidate.majorAxisAngle = geometry.angle;
    candidate.method = 'component-consensus-plus-differential-projection';
    candidate.reason = 'Supported component alignment and local projection agree.';
    candidate.quality = sqrt(min(component.spanInHeights,12)) * ...
        component.inlierFraction * min(component.peakRatio,4) / ...
        (1+4*component.residualFraction);
    reason = '';
else
    reason = [wholeReason ' | ' componentReason];
end
end

function [mask, geometry, reason] = cleanForeground(mask,options)
geometry = struct('fraction',0,'elongation',0,'angle',NaN, ...
    'boxes',zeros(0,4),'centers',zeros(0,2),'count',0);
reason = '';
[height,width] = size(mask);
mask = bwareaopen(mask,max(4,round(numel(mask)*0.00004)),8);
cc = bwconncomp(mask,8);
props = regionprops(cc,'Area','BoundingBox');
for k = 1:cc.NumObjects
    pixels = cc.PixelIdxList{k};
    [row,column] = ind2sub(size(mask),pixels);
    sides = any(row==1)+any(row==height)+any(column==1)+any(column==width);
    borderFraction = nnz(row==1 | row==height | column==1 | column==width) / numel(row);
    areaFraction = props(k).Area/numel(mask);
    box = props(k).BoundingBox;
    extent = props(k).Area/(box(3)*box(4));
    slab = areaFraction > 0.70 || ...
        (sides >= 3 && areaFraction > 0.35 && extent > 0.80);
    borderFrame = sides >= 3 && borderFraction > 0.60;
    if slab || borderFrame, mask(pixels) = false; end
end
[rows,columns] = find(mask);
geometry.fraction = numel(rows)/numel(mask);
if numel(rows) < 30 || geometry.fraction < options.MinForegroundFraction || ...
        geometry.fraction > options.MaxForegroundFraction
    reason = 'Whole mask has too little ink or excessive foreground/background fill.';
    return;
end
points = [double(columns) double(rows)];
points = points-mean(points,1);
[basis,values] = eig((points'*points)/size(points,1));
[variance,order] = sort(diag(values),'descend');
direction = basis(:,order(1));
if direction(1) < 0, direction = -direction; end
geometry.angle = atan2d(direction(2),direction(1));
geometry.elongation = sqrt(variance(1)/max(variance(2),eps));
cc = bwconncomp(mask,8);
props = regionprops(cc,'BoundingBox','Centroid');
geometry.boxes = vertcat(props.BoundingBox);
geometry.centers = vertcat(props.Centroid);
geometry.count = cc.NumObjects;
end

function [candidate, reason] = analyzeWholeWord(mask,geometry,options)
candidate = emptyCandidate();
reason = '';
if geometry.elongation < options.MinElongation
    reason = 'Whole-word shape has no sufficiently elongated line direction.'; return;
end
[rows,columns] = find(mask);
allPoints = [double(columns) double(rows)];
allPoints = allPoints-mean(allPoints,1);
points = allPoints;
if size(points,1) > options.MaxProjectionPoints
    indices = round(linspace(1,size(points,1),options.MaxProjectionPoints));
    points = points(indices,:);
end
% Search the whole permitted axis range, not +/-8 degrees around letters.
coarseAngles = unique([-options.MaxSkew, ...
    ceil(-options.MaxSkew):floor(options.MaxSkew),0,options.MaxSkew]);
coarseScores = projectionScores(points,coarseAngles);
plausible = axialDistance(coarseAngles,geometry.angle) <= options.MaxAxisDisagreement;
if ~any(plausible)
    reason = 'Whole-word major axis lies outside the configured angle range.'; return;
end
searchScores = coarseScores;
searchScores(~plausible) = -Inf;
[peak,peakIndex] = max(searchScores);
if peakIndex == 1 || peakIndex == numel(coarseAngles)
    reason = 'Whole-word direction is unresolved at the configured angle limit.'; return;
end
lower = max(-options.MaxSkew,coarseAngles(peakIndex)-1.25);
upper = min(options.MaxSkew,coarseAngles(peakIndex)+1.25);
fineAngles = lower:options.FineStep:upper;
fineScores = projectionScores(points,fineAngles);
[finePeak,fineIndex] = max(fineScores);
if fineIndex == 1 || fineIndex == numel(fineAngles)
    reason = 'Whole-word fine optimum is unresolved at an interval endpoint.'; return;
end
angle = fineAngles(fineIndex);
away = plausible & axialDistance(coarseAngles,angle) >= options.PeakSeparation;
if ~any(away) || peak <= eps
    reason = 'Whole-word projection has insufficient angular alternatives.'; return;
end
peakRatio = finePeak/max(median(coarseScores(away)),eps);
competitionRatio = finePeak/max(max(coarseScores(away)),eps);
if peakRatio < options.MinPeakRatio || ...
        competitionRatio < options.MinCompetingPeakRatio
    candidate.ambiguous = true;
    reason = 'Whole-word projection has weak or competing angular peaks.'; return;
end
direction = [cosd(angle);sind(angle)];
along = allPoints*direction;
across = allPoints*[-direction(2);direction(1)];
lengthValue = max(along)-min(along)+1;
heightValue = max(across)-min(across)+1;
aspect = lengthValue/heightValue;
inkFill = size(allPoints,1)/(lengthValue*heightValue);
if aspect < options.MinElongation || lengthValue < 20 || ...
        inkFill < options.MinInkFill || inkFill > 0.85
    reason = 'Whole-word support is too short, sparse, thick, or slab-like.'; return;
end
% A solid bar/frame is not evidence of a text line. Require some variation
% along the ink pattern as well as a strong cross-line projection peak.
alongBins = floor(along-min(along))+1;
alongProfile = accumarray(alongBins,1);
trim = floor(0.05*numel(alongProfile));
interior = alongProfile(1+trim:end-trim);
if std(interior)/max(mean(interior),eps) < 0.06
    reason = 'Uniform line or frame has insufficient word-like ink variation.'; return;
end
candidate.accepted = true;
candidate.method = 'whole-word-differential-projection';
candidate.reason = 'Elongated whole-word foreground has a distinct projection direction.';
candidate.wholeWordAccepted = true;
candidate.coarseAngle = coarseAngles(peakIndex);
candidate.correctionAngle = angle;
candidate.componentCount = geometry.count;
candidate.inlierCount = 0;
candidate.inlierFraction = NaN;
candidate.residualFraction = NaN;
candidate.peakRatio = peakRatio;
candidate.competitionRatio = competitionRatio;
left = fineIndex;
right = fineIndex;
while left > 1 && fineScores(left-1) >= 0.90*finePeak, left = left-1; end
while right < numel(fineScores) && fineScores(right+1) >= 0.90*finePeak
    right = right+1;
end
candidate.peakWidth = fineAngles(right)-fineAngles(left);
candidate.peakBounds = fineAngles([left right]);
[candidate.profileAngles,indices] = unique([coarseAngles fineAngles]);
allScores = [coarseScores fineScores];
candidate.profileScores = allScores(indices);
candidate.supportBoxes = geometry.boxes;
candidate.supportCenters = geometry.centers;
candidate.supportPoints = diagnosticPoints([double(columns) double(rows)]);
candidate.foregroundFraction = geometry.fraction;
candidate.elongation = geometry.elongation;
candidate.majorAxisAngle = geometry.angle;
candidate.quality = sqrt(min(aspect,12))*min(peakRatio,4) / ...
    (1+axialDistance(angle,geometry.angle)/options.MaxAxisDisagreement);
end

function [candidate, reason] = analyzeComponentMask(mask, options)
candidate = emptyCandidate();
reason = '';
[height,width] = size(mask);
mask = bwareaopen(mask,max(4,round(numel(mask)*0.00004)),8);
cc = bwconncomp(mask,8);
props = regionprops(cc,'Area','BoundingBox','Centroid','Solidity','Extent');
if numel(props) < options.MinCharacters
    reason = 'Too few separate character candidates.'; return;
end
boxes = vertcat(props.BoundingBox);
areas = [props.Area]';
ratio = boxes(:,3)./boxes(:,4);
keep = areas >= max(5,numel(mask)*0.00006) & ...
    areas <= 0.30*numel(mask) & ...
    boxes(:,4) >= max(3,0.08*height) & ...
    boxes(:,4) <= 0.98*height & boxes(:,3) >= 2 & ...
    boxes(:,3) <= 0.65*width & ratio >= 0.06 & ratio <= 8 & ...
    [props.Solidity]' >= 0.08 & [props.Extent]' >= 0.04;
indices = find(keep);
if numel(indices) < options.MinCharacters
    reason = 'Too few plausible character components.'; return;
end
if numel(indices) > 120
    reason = 'Excessive component clutter.'; return;
end
centers = vertcat(props(indices).Centroid);
boxes = boxes(indices,:);
[fit, valid] = consensusLine(centers,boxes,options);
if ~valid
    reason = 'No sufficiently supported straight text alignment.'; return;
end
candidate.componentCueAccepted = true;
candidate.componentCueAngle = fit.angle;
candidate.coarseAngle = fit.angle;
candidate.inlierCount = nnz(fit.inliers);
candidate.inlierFraction = mean(fit.inliers);
candidate.residualFraction = fit.residualFraction;
candidate.spanInHeights = fit.spanInHeights;
textMask = false(size(mask));
support = indices(fit.inliers);
for index = support'
    textMask(cc.PixelIdxList{index}) = true;
end
[rows,columns] = find(textMask);
if numel(rows) < 20
    reason = 'Insufficient foreground pixels.'; return;
end
points = [double(columns) double(rows)];
candidate.supportPoints = diagnosticPoints(points);
points = points-mean(points,1);
lower = max(-options.MaxSkew,fit.angle-options.RefinementRadius);
upper = min(options.MaxSkew,fit.angle+options.RefinementRadius);
coarseAngles = lower:0.5:upper;
coarseScores = projectionScores(points,coarseAngles);
[peak,peakIndex] = max(coarseScores);
if peakIndex == 1 || peakIndex == numel(coarseAngles)
    reason = 'Projection optimum lies at the search boundary.'; return;
end
fineAngles = max(lower,coarseAngles(peakIndex)-0.6): ...
    options.FineStep:min(upper,coarseAngles(peakIndex)+0.6);
fineScores = projectionScores(points,fineAngles);
[finePeak,fineIndex] = max(fineScores);
if fineIndex == 1 || fineIndex == numel(fineAngles)
    reason = 'Fine projection optimum is unresolved at an interval endpoint.'; return;
end
refinedAngle = fineAngles(fineIndex);
away = abs(coarseAngles-refinedAngle) >= 1.5;
if ~any(away) || peak <= eps
    reason = 'No distinct projection peak.'; return;
end
peakRatio = finePeak/max(median(coarseScores(away)),eps);
if peakRatio < options.MinPeakRatio
    reason = 'Projection peak is too weak to trust.'; return;
end
if abs(refinedAngle-fit.angle) > options.RefinementRadius-0.5
    reason = 'Pixel direction is inconsistent with component alignment.'; return;
end
candidate.accepted = true;
candidate.coarseAngle = fit.angle;
candidate.correctionAngle = refinedAngle;
candidate.componentCount = size(centers,1);
candidate.inlierCount = nnz(fit.inliers);
candidate.inlierFraction = mean(fit.inliers);
candidate.residualFraction = fit.residualFraction;
candidate.peakRatio = peakRatio;
left = fineIndex;
right = fineIndex;
while left > 1 && fineScores(left-1) >= 0.90*finePeak, left = left-1; end
while right < numel(fineScores) && fineScores(right+1) >= 0.90*finePeak
    right = right+1;
end
candidate.peakWidth = fineAngles(right)-fineAngles(left);
candidate.peakBounds = fineAngles([left right]);
candidate.profileAngles = [coarseAngles fineAngles];
candidate.profileScores = [coarseScores fineScores];
candidate.supportBoxes = boxes(fit.inliers,:);
candidate.supportCenters = centers(fit.inliers,:);
candidate.quality = candidate.inlierCount * ...
    sqrt(min(fit.spanInHeights,10)) * candidate.inlierFraction * ...
    min(peakRatio,4)/(1+4*fit.residualFraction);
end

function [fit, valid] = consensusLine(centers,boxes,options)
% Deterministic exhaustive two-point hypotheses for small candidate sets.
count = size(centers,1);
heights = boxes(:,4);
typicalHeight = median(heights);
tolerance = max(1,0.23*sqrt(heights*typicalHeight));
bestScore = -Inf;
bestInliers = false(count,1);
fit = struct('angle',NaN,'inliers',bestInliers, ...
    'residualFraction',Inf,'spanInHeights',0);
valid = false;
for first = 1:count-1
    for second = first+1:count
        delta = centers(second,:)-centers(first,:);
        lengthValue = norm(delta);
        if lengthValue < 1.3*typicalHeight || ...
                max(heights([first second]))/min(heights([first second])) > 3
            continue;
        end
        direction = delta/lengthValue;
        if direction(1) < 0, direction = -direction; end
        angle = atan2d(direction(2),direction(1));
        if abs(angle) > options.MaxSkew, continue; end
        normal = [-direction(2); direction(1)];
        distances = abs((centers-centers(first,:))*normal);
        pairHeight = median(heights([first second]));
        inliers = distances <= tolerance & ...
            heights >= 0.4*pairHeight & heights <= 2.5*pairHeight;
        if nnz(inliers) < options.MinCharacters, continue; end
        along = centers(inliers,:)*direction';
        span = max(along)-min(along);
        score = nnz(inliers)*sqrt(max(span/typicalHeight,eps)) / ...
            (1+mean((distances(inliers)./tolerance(inliers)).^2));
        if score > bestScore
            bestScore = score;
            bestInliers = inliers;
        end
    end
end
if nnz(bestInliers) < options.MinCharacters, return; end
inliers = bestInliers;
for iteration = 1:3
    if nnz(inliers) < options.MinCharacters, return; end
    origin = mean(centers(inliers,:),1);
    [~,~,basis] = svd(centers(inliers,:)-origin,0);
    direction = basis(:,1);
    if direction(1) < 0, direction = -direction; end
    distances = abs((centers-origin)*[-direction(2);direction(1)]);
    inlierHeight = median(heights(inliers));
    newInliers = distances <= tolerance & heights >= 0.4*inlierHeight & ...
        heights <= 2.5*inlierHeight;
    if isequal(newInliers,inliers), break; end
    inliers = newInliers;
end
if nnz(inliers) < options.MinCharacters || ...
        mean(inliers) < options.MinInlierFraction
    return;
end
origin = mean(centers(inliers,:),1);
[~,~,basis] = svd(centers(inliers,:)-origin,0);
direction = basis(:,1);
if direction(1) < 0, direction = -direction; end
angle = atan2d(direction(2),direction(1));
distances = abs((centers(inliers,:)-origin)*[-direction(2);direction(1)]);
along = centers(inliers,:)*direction;
spanInHeights = (max(along)-min(along))/median(heights(inliers));
residualFraction = sqrt(mean(distances.^2))/median(heights(inliers));
if abs(angle) > options.MaxSkew || spanInHeights < 1.25 || ...
        residualFraction > 0.20
    return;
end
fit.angle = angle;
fit.inliers = inliers;
fit.residualFraction = residualFraction;
fit.spanInHeights = spanInHeights;
valid = true;
end

function scores = projectionScores(points,angles)
% Differential projection normalized by ink mass, not changing image height.
scores = zeros(size(angles));
for k = 1:numel(angles)
    normalCoordinate = -points(:,1)*sind(angles(k)) + ...
        points(:,2)*cosd(angles(k));
    normalCoordinate = normalCoordinate-min(normalCoordinate)+2;
    bins = floor(normalCoordinate);
    fraction = normalCoordinate-bins;
    profile = accumarray([bins;bins+1],[1-fraction;fraction]);
    profile = [0;profile;0]; %#ok<AGROW>
    scores(k) = sum(diff(profile).^2)/(size(points,1)^2);
end
end

function distance = axialDistance(first,second)
% Text-line direction repeats after 180 degrees; it is not reading order.
distance = abs(mod(first-second+90,180)-90);
end

function angle = originalAngle(angle,scaleXY)
angle = atan2d(sind(angle)/scaleXY(2),cosd(angle)/scaleXY(1));
end

function points = diagnosticPoints(points)
% Bounded deterministic sample of actual selected ink, never bbox corners.
if size(points,1) > 5000
    points = points(round(linspace(1,size(points,1),5000)),:);
end
end

function options = settings(input)
options = defaults();
if ~isstruct(input) || ~isscalar(input)
    error('estimateROILineDirection:Options','options must be a scalar struct.');
end
names = fieldnames(input);
for k = 1:numel(names)
    name = names{k};
    if ~isfield(options,name)
        error('estimateROILineDirection:Option','Unknown option: %s',name);
    end
    options.(name) = input.(name);
end
validateattributes(options.MaxSkew,{'numeric'},{'scalar','real','finite','>',0,'<',90});
validateattributes(options.MaxDimension,{'numeric'},{'scalar','integer','>=',64});
validateattributes(options.MinCharacters,{'numeric'},{'scalar','integer','>=',3});
validateattributes(options.MinInlierFraction,{'numeric'},{'scalar','>',0,'<=',1});
validateattributes(options.RefinementRadius,{'numeric'},{'scalar','>',1,'<=',20});
validateattributes(options.FineStep,{'numeric'},{'scalar','>',0,'<=',0.5});
validateattributes(options.MinPeakRatio,{'numeric'},{'scalar','>',1});
validateattributes(options.MaxMaskDisagreement,{'numeric'},{'scalar','>',0});
validateattributes(options.MaxHintDisagreement,{'numeric'},{'scalar','>',0});
validateattributes(options.OriginalSkewHint,{'numeric'},{'scalar','real'});
validateattributes(options.MinForegroundFraction,{'numeric'}, ...
    {'scalar','real','finite','>',0,'<',1});
validateattributes(options.MaxForegroundFraction,{'numeric'}, ...
    {'scalar','real','finite','>',options.MinForegroundFraction,'<',1});
validateattributes(options.MinElongation,{'numeric'},{'scalar','real','finite','>',1});
validateattributes(options.MinInkFill,{'numeric'}, ...
    {'scalar','real','finite','>',0,'<',0.85});
validateattributes(options.MaxAxisDisagreement,{'numeric'}, ...
    {'scalar','real','finite','>',0,'<',45});
validateattributes(options.MaxCueDisagreement,{'numeric'}, ...
    {'scalar','real','finite','>',0,'<',45});
validateattributes(options.PeakSeparation,{'numeric'}, ...
    {'scalar','real','finite','>',1,'<',45});
validateattributes(options.MinCompetingPeakRatio,{'numeric'}, ...
    {'scalar','real','finite','>',1});
validateattributes(options.MaxProjectionPoints,{'numeric'}, ...
    {'scalar','integer','finite','>=',1000});
if isinf(options.OriginalSkewHint)
    error('estimateROILineDirection:Hint','OriginalSkewHint must be finite or NaN.');
end
end

function value = defaults()
value = struct('MaxSkew',89.5,'MaxDimension',900,'MinCharacters',3, ...
    'MinInlierFraction',0.55,'RefinementRadius',8,'FineStep',0.05, ...
    'MinPeakRatio',1.12,'MaxMaskDisagreement',1.5, ...
    'OriginalSkewHint',NaN,'MaxHintDisagreement',5, ...
    'MinForegroundFraction',0.001,'MaxForegroundFraction',0.65, ...
    'MinElongation',1.8,'MinInkFill',0.04, ...
    'MaxAxisDisagreement',25,'MaxCueDisagreement',5, ...
    'PeakSeparation',8,'MinCompetingPeakRatio',1.04, ...
    'MaxProjectionPoints',25000);
end

function value = emptyCandidate()
value = struct('accepted',false,'quality',0,'maskName','', ...
    'coarseAngle',NaN,'correctionAngle',NaN,'componentCount',0, ...
    'inlierCount',0,'inlierFraction',0,'residualFraction',Inf, ...
    'peakRatio',0,'peakWidth',NaN,'peakBounds',[],'profileAngles',[], ...
    'profileScores',[],'supportBoxes',[],'supportCenters',[], ...
    'supportPoints',zeros(0,2), ...
    'method','','reason','','wholeWordAccepted',false, ...
    'componentCueAccepted',false,'componentCueAngle',NaN, ...
    'foregroundFraction',NaN,'elongation',NaN,'competitionRatio',NaN, ...
    'majorAxisAngle',NaN,'spanInHeights',NaN,'ambiguous',false);
end

function value = emptyDiagnostics()
value = struct('accepted',false,'reason','','method','', ...
    'estimationScale',1,'estimationScaleXY',[1 1],'maskName','','lineAngle',NaN, ...
    'correctionAngle',NaN,'coarseCorrectionAngle',NaN, ...
    'componentCount',0,'inlierCount',0,'inlierFraction',0, ...
    'alignmentResidualFraction',NaN,'profilePeakRatio',NaN, ...
    'profilePeakWidthDeg',NaN,'profileAngles',[],'profileScores',[], ...
    'maskAngles',[],'maskFailureReasons',{{}},'supportBoxes',[], ...
    'supportCenters',[],'supportPoints',zeros(0,2),'quality',0,'wholeWordAccepted',false, ...
    'componentCueAccepted',false,'componentCueAngle',NaN, ...
    'foregroundFraction',NaN,'elongation',NaN,'peakCompetitionRatio',NaN, ...
    'majorAxisCorrectionAngle',NaN,'orientationAmbiguous',true);
end
