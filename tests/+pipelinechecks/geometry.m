function report = geometry()
% Check deskew and projective correction against known synthetic geometry.
    rows = cell(0, 3);
    corners = [100 90; 730 135; 680 435; 55 400];
    fixture = makePlanarFixture(corners);
    perspectiveOptions = struct('Corners', corners, 'AspectRatio', fixture.aspect);

    [geometry, diagnostics] = estimateSignPerspective(fixture.frame, ...
        fixture.textBox, fixture.lineAngle, perspectiveOptions);
    assert(geometry.accepted && diagnostics.accepted, ...
        'testGeometryPipeline:SuppliedCorners', ...
        'Exact supplied planar corners were rejected: %s', diagnostics.reason);
    assert(isa(geometry.transform, 'projtform2d') ...
        && isequal(size(geometry.corners), [4 2]) ...
        && max(vecnorm(geometry.corners - corners, 2, 2)) < 1e-6, ...
        'testGeometryPipeline:CornerOrder', 'Supplied TL/TR/BR/BL correspondence changed.');
    rectificationError = independentRectificationError(geometry.transform, fixture.H);
    roundTripError = checkRoundTrip(geometry.transform, fixture.H);
    assert(rectificationError < 0.2 && roundTripError < 1e-6, ...
        'testGeometryPipeline:HelperTransform', 'Supplied-corner rectification geometry is wrong.');
    assert(contains(string(geometry.aspectRatioSource), 'supplied'), ...
        'testGeometryPipeline:AspectSource', 'Known aspect-ratio provenance must be explicit.');
    rows(end+1, :) = {'supplied-corner helper', true, ...
        sprintf('Rectified axis error %.4f px. %s', rectificationError, diagnostics.reason)};
    [withoutAngle, noAngleDiagnostics] = estimateSignPerspective(fixture.frame, ...
        fixture.textBox, NaN, perspectiveOptions);
    assert(withoutAngle.accepted, 'testGeometryPipeline:CornersWithoutAngle', ...
        'Trusted corners must be usable without a supported text angle: %s', noAngleDiagnostics.reason);
    verticalCorners = [480 50; 450 465; 290 440; 315 35];
    verticalSign = makePlanarFixture(verticalCorners);
    [verticalGeometry, verticalDiagnostics] = estimateSignPerspective(verticalSign.frame, ...
        verticalSign.textBox, NaN, struct('Corners', verticalCorners, 'AspectRatio', verticalSign.aspect));
    assert(verticalGeometry.accepted ...
        && independentRectificationError(verticalGeometry.transform, verticalSign.H) < 0.2, ...
        'testGeometryPipeline:VerticalCornerAnchor', ...
        'Near-vertical sign lost its supplied physical TL corner anchor: %s', verticalDiagnostics.reason);
    rows(end+1, :) = {'near-vertical sign, corners without angle', true, ...
        'Supplied physical TL/TR/BR/BL correspondence survives near-vertical presentation.'};
    along = 520 * [cosd(45) sind(45)];
    normal = 140 * [-sind(45) cosd(45)];
    centre = [410 260];
    narrowCorners = [centre-along/2-normal/2; centre+along/2-normal/2; ...
        centre+along/2+normal/2; centre-along/2+normal/2];
    narrow = makePlanarFixture(narrowCorners, 170);
    narrowOptions = struct('Corners', narrowCorners, 'AspectRatio', narrow.aspect);
    [inflatedBoxResult, ~] = estimateSignPerspective(narrow.frame, narrow.textBox, ...
        narrow.lineAngle, narrowOptions);
    narrowOptions.TextSupport = projectedInkSupport(narrow);
    [supportedNarrow, narrowDiagnostics] = estimateSignPerspective(narrow.frame, ...
        narrow.textBox, narrow.lineAngle, narrowOptions);
    assert(~inflatedBoxResult.accepted && supportedNarrow.accepted ...
        && independentRectificationError(supportedNarrow.transform, narrow.H) < 0.2, ...
        'testGeometryPipeline:RotatedTextSupport', ...
        'A rotated narrow sign must use actual ink support instead of its inflated AABB: %s', ...
        narrowDiagnostics.reason);
    rows(end+1, :) = {'45-degree narrow sign, actual text support', true, ...
        'Projected foreground points establish containment that the inflated text AABB cannot.'};

    sourceImages = {fixture.frame, im2uint16(fixture.frame), im2single(fixture.frame)};

    for index = 1:numel(sourceImages)
        frame = sourceImages{index};
        originalFrame = frame;
        options = struct('PaddingFraction', 0.04, 'Perspective', ...
            struct('Enabled', true, 'Corners', corners, 'AspectRatio', fixture.aspect));
        [corrected, info] = GeometricCorrection(frame, fixture.textBox, options);
        checkOutputContract(corrected, info, 1, class(frame));
        assert(info.perspectiveAccepted && info.accepted ...
            && info.resamplingPasses == 1 && strcmp(info.status, 'perspective-rectified'), ...
            'testGeometryPipeline:PerspectivePipeline', 'Perspective correction did not use the single-warp path.');
        assert(isequaln(frame, originalFrame), ...
            'testGeometryPipeline:Mutation', 'Input frame was changed.');
        axisError = independentRectificationError(info.transform, fixture.H);
        assert(axisError < 0.2 && checkRoundTrip(info.transform, fixture.H) < 1e-6, ...
            'testGeometryPipeline:ComposedTransform', 'Original-frame to output composition is wrong.');
        agreement = independentPixelAgreement(fixture, info.transform, corrected{1});
        assert(agreement > 0.90, 'testGeometryPipeline:ImageRectification', ...
            'Output pixels disagree with known planar ink/background samples (%.3f).', agreement);
        rows(end+1, :) = {['single-warp ' class(frame)], true, ...
            sprintf('Planar pixel agreement %.3f, rectified axis error %.4f px.', agreement, axisError)}; %#ok<AGROW>
    end

    % A cell of corners preserves the per-box association and output order.
    cellOptions = struct('Perspective', struct('Enabled', true, ...
        'Corners', {{corners; corners}}, 'AspectRatio', fixture.aspect));
    [twoOutputs, twoInfo] = GeometricCorrection(fixture.frame, ...
        [fixture.textBox; fixture.textBox], cellOptions);
    checkOutputContract(twoOutputs, twoInfo, 2, 'uint8');
    assert(all([twoInfo.perspectiveAccepted]) && isequal(twoOutputs{1}, twoOutputs{2}), ...
        'testGeometryPipeline:PerBoxCorners', 'Per-box corner cells lost association or determinism.');
    rows(end+1, :) = {'per-box corner cells', true, 'Two matching boxes give matching corrected crops.'};

    % Automatic boundary search gets a deliberately easy, complete sign.
    easyCorners = [90 70; 730 70; 730 310; 90 310];
    easy = makePlanarFixture(easyCorners);
    automaticOptions = struct('ContextScale', 6, 'AspectRatio', easy.aspect);
    [automatic, autoDiagnostics] = estimateSignPerspective(easy.frame, easy.textBox, 0, automaticOptions);
    assert(automatic.accepted, 'testGeometryPipeline:EasyBoundary', ...
        'Easy complete border was not found: %s', autoDiagnostics.reason);
    cornerError = max(vecnorm(automatic.corners - easyCorners, 2, 2));
    assert(cornerError < 12, 'testGeometryPipeline:AutomaticCorners', ...
        'Automatic corners are too far from the visible sign border (%.2f pixels).', cornerError);
    rows(end+1, :) = {'easy automatic four-edge boundary', true, ...
        sprintf('Maximum corner error %.2f px. %s', cornerError, autoDiagnostics.reason)};
    checkIncompleteAndCompetingBoundaries(easy);
    rows(end+1, :) = {'clipped, missing, and competing boundaries', true, ...
        'Incomplete or rival enclosing frames must not produce a trusted homography.'};

    [plain, plainBox] = makePlainText();
    [missing, missingDiagnostics] = estimateSignPerspective(plain, plainBox, 0, struct('ContextScale', 6));
    assert(~missing.accepted && ~missingDiagnostics.accepted, ...
        'testGeometryPipeline:InventedBoundary', 'Text alone must not become a physical sign boundary.');
    rows(end+1, :) = {'no enclosing sign boundary', true, missingDiagnostics.reason};
    checkSkewOnlyFallback(plain);
    rows(end+1, :) = {'skew-only fallback without boundary', true, 'Known 17-degree text is deskewed.'};

    connected = makeConnectedWord();
    for angle = [-27, 24, 87, -86]
        image = rotateWhite(connected, angle);
        [estimate, angleDiagnostics] = estimateROILineDirection(image);
        angleError = axialError(estimate, angle);
        assert(angleDiagnostics.accepted && angleDiagnostics.wholeWordAccepted && angleError < 1, ...
            'testGeometryPipeline:WholeWordAngle', ...
            'Connected word %.1f deg: accepted=%d, estimate=%.3f, reason=%s', ...
            angle, angleDiagnostics.accepted, estimate, angleDiagnostics.reason);
        rows(end+1, :) = {sprintf('connected word %+g deg', angle), true, ...
            sprintf('Angle error %.3f deg, %s.', angleError, angleDiagnostics.method)}; %#ok<AGROW>
    end
    checkLowEvidenceAndAPI();
    rows(end+1, :) = {'low evidence and API contracts', true, 'Blank/round/cross, empty/malformed boxes, bounds, unchanged pixels.'};
    report = cell2table(rows, 'VariableNames', {'Case', 'Passed', 'Detail'});
end

function fixture = makePlanarFixture(corners, height)
    if nargin < 2, height = 240; end
    width = 640;
    plane = repmat(uint8(242), [height, width, 3]);
    plane = insertText(plane, [96 72], 'PARKING 2026', 'Font', 'Arial', ...
        'FontSize', 60, 'TextColor', [18 18 18], 'BoxOpacity', 0, 'AnchorPoint', 'LeftTop');
    textMask = im2gray(plane) < 100;
    [textY, textX] = find(textMask);
    assert(~isempty(textX) && max(textX) < width-12, ...
        'testGeometryPipeline:Fixture', 'Rendered fixture text was clipped.');
    plane([1:6 end-5:end], :, :) = 12;
    plane(:, [1:6 end-5:end], :) = 12;
    sourceCorners = [1 1; width 1; width height; 1 height];
    H = independentHomography(sourceCorners, corners);
    [cameraX, cameraY] = meshgrid(1:820, 1:520);
    sourceHomogeneous = H \ [cameraX(:), cameraY(:), ones(numel(cameraX),1)].';
    source = (sourceHomogeneous(1:2,:) ./ sourceHomogeneous(3,:)).';
    inside = source(:,1) >= 1 & source(:,1) <= width ...
        & source(:,2) >= 1 & source(:,2) <= height;
    frame = repmat(uint8(76), [520 820 3]);
    for channel = 1:3
        values = repmat(76, size(source,1), 1);
        values(inside) = interp2(double(plane(:,:,channel)), ...
            source(inside,1), source(inside,2), 'linear');
        frame(:,:,channel) = reshape(uint8(values), 520, 820);
    end
    wordCorners = [min(textX) min(textY); max(textX) min(textY); ...
        max(textX) max(textY); min(textX) max(textY)];
    projected = applyMatrix(H, wordCorners);
    lower = min(projected, [], 1)-3; upper = max(projected, [], 1)+3;
    baseline = applyMatrix(H, [100 mean(textY); 540 mean(textY)]);
    delta = baseline(2,:) - baseline(1,:);
    fixture = struct('frame', frame, 'plane', plane, 'textMask', textMask, ...
        'H', H, 'textBox', [lower upper-lower], 'aspect', width/height, ...
        'lineAngle', -atan2d(delta(2), delta(1)));
end

function H = independentHomography(source, target)
    % Direct eight-unknown linear solve, independent of production fitting.
    A = zeros(8); b = zeros(8,1);
    for index = 1:4
        u = source(index,1); v = source(index,2);
        x = target(index,1); y = target(index,2);
        A(2*index-1,:) = [u v 1 0 0 0 -x*u -x*v];
        A(2*index,:) = [0 0 0 u v 1 -y*u -y*v];
        b(2*index-1:2*index) = [x; y];
    end
    h = A \ b;
    H = [h(1:3).'; h(4:6).'; h(7:8).' 1];
end

function points = projectedInkSupport(fixture)
    [y,x] = find(fixture.textMask);
    selected = unique(round(linspace(1, numel(x), min(2500, numel(x)))));
    points = applyMatrix(fixture.H, [x(selected) y(selected)]);
end

function checkIncompleteAndCompetingBoundaries(easy)
    options = struct('ContextScale', 6);
    missingRight = easy.frame;
    % Continue the paper to the image edge, removing the physical right-side
    % contrast as well as its painted border; erasing paint alone is not
    % enough because the bright paper edge would still be real evidence.
    missingRight(70:310, 720:end, :) = 242;
    [missing, missingDiagnostics] = estimateSignPerspective(missingRight, easy.textBox, 0, options);
    assert(~missing.accepted, 'testGeometryPipeline:MissingSide', ...
        'Three visible sides must not invent the missing right side: %s', missingDiagnostics.reason);
    clipped = makePlanarFixture([-20 70; 640 70; 640 310; -20 310]);
    [clippedResult, clippedDiagnostics] = estimateSignPerspective(clipped.frame, clipped.textBox, 0, options);
    assert(~clippedResult.accepted, 'testGeometryPipeline:ClippedBoundary', ...
        'A sign extending beyond the image must be declined: %s', clippedDiagnostics.reason);
    nested = easy.frame;
    nested(100:103, 130:690, :) = 12;
    nested(287:290, 130:690, :) = 12;
    nested(100:290, 130:133, :) = 12;
    nested(100:290, 687:690, :) = 12;
    [competing, competingDiagnostics] = estimateSignPerspective(nested, easy.textBox, 0, options);
    assert(~competing.accepted, 'testGeometryPipeline:CompetingFrames', ...
        'Two strongly supported enclosing frames need rejection: %s', competingDiagnostics.reason);
end

function points = applyMatrix(H, points)
    homogeneous = [points ones(size(points,1),1)] * H.';
    points = homogeneous(:,1:2) ./ homogeneous(:,3);
end

function error = independentRectificationError(transform, knownH)
    [x,y] = meshgrid([100 320 540], [50 120 190]);
    planePoints = [x(:) y(:)];
    cameraPoints = applyMatrix(knownH, planePoints);
    outputPoints = transformPointsForward(transform, cameraPoints);
    affineFit = [planePoints ones(size(planePoints,1),1)] \ outputPoints;
    residual = vecnorm(outputPoints - [planePoints ones(size(planePoints,1),1)]*affineFit, 2, 2);
    scaleX = norm(affineFit(1,:)); scaleY = norm(affineFit(2,:));
    assert(abs(scaleX/scaleY-1) < 0.025 ...
        && abs(affineFit(1,2))/scaleX < 0.01 ...
        && abs(affineFit(2,1))/scaleY < 0.01, ...
        'testGeometryPipeline:PlaneAxes', 'Known rectangular plane is not axis-aligned at the supplied aspect ratio.');
    error = max(residual);
end

function error = checkRoundTrip(transform, knownH)
    points = applyMatrix(knownH, [120 60; 320 120; 520 180]);
    forward = transformPointsForward(transform, points);
    inverse = transformPointsInverse(transform, forward);
    error = max(vecnorm(inverse-points, 2, 2));
end

function agreement = independentPixelAgreement(fixture, transform, output)
    ink = imerode(fixture.textMask, ones(3));
    [rows, columns] = find(fixture.textMask);
    region = false(size(ink));
    region(min(rows):max(rows), min(columns):max(columns)) = true;
    paper = imerode(im2gray(fixture.plane) > 220, ones(5)) & region;
    labels = []; points = [];
    masks = {ink, paper};
    for index = 1:2
        [y,x] = find(masks{index});
        selected = unique(round(linspace(1, numel(x), min(250, numel(x)))));
        points = [points; x(selected) y(selected)]; %#ok<AGROW>
        labels = [labels; repmat(index == 1, numel(selected), 1)]; %#ok<AGROW>
    end
    samples = transformPointsForward(transform, applyMatrix(fixture.H, points));
    observed = interp2(im2double(im2gray(output)), samples(:,1), samples(:,2), 'linear', NaN);
    valid = isfinite(observed);
    assert(mean(valid) > 0.90, 'testGeometryPipeline:OutputCoverage', 'Corrected crop lost known word samples.');
    agreement = mean((observed(valid) < 0.5) == labels(valid));
end

function [image, box] = makePlainText()
    image = repmat(uint8(255), [140 660 3]);
    image = insertText(image, [28 28], 'PARKING 2026', 'Font', 'Arial', ...
        'FontSize', 54, 'TextColor', [15 15 15], 'BoxOpacity', 0, 'AnchorPoint', 'LeftTop');
    [y,x] = find(im2gray(image) < 100);
    box = [min(x)-8 min(y)-8 max(x)-min(x)+16 max(y)-min(y)+16];
end

function image = makeConnectedWord()
    [image, ~] = makePlainText();
    mask = im2gray(image) < 128;
    [y,x] = find(mask);
    bridgeY = round((min(y)+max(y))/2);
    % Thin inter-letter bridges make one component without dilating the
    % entire word into a nearly solid bar and erasing its useful structure.
    joined = mask;
    joined(bridgeY-1:bridgeY+1, min(x):max(x)) = true;
    components = bwconncomp(joined);
    assert(components.NumObjects == 1, 'testGeometryPipeline:ConnectedFixture', ...
        'The touching-word fixture must really be one foreground component.');
    [y,x] = find(joined);
    joined = joined(max(1,min(y)-24):min(size(joined,1),max(y)+24), ...
        max(1,min(x)-24):min(size(joined,2),max(x)+24));
    image = uint8(255 * ~joined);
end

function rotated = rotateWhite(image, angle)
    rotated = imcomplement(imrotate(imcomplement(image), angle, 'bilinear', 'loose'));
end

function error = axialError(estimate, truth)
    error = abs(mod(estimate-truth+90, 180)-90);
end

function checkSkewOnlyFallback(plain)
    image = rotateWhite(plain, 17);
    [y,x] = find(im2gray(image) < 100);
    box = [min(x)-8 min(y)-8 max(x)-min(x)+16 max(y)-min(y)+16];
    [corrected, info] = GeometricCorrection(image, box);
    checkOutputContract(corrected, info, 1, class(image));
    assert(info.accepted && ~info.perspectiveAccepted && info.resamplingPasses == 1 ...
        && axialError(info.lineAngle, 17) < 1 && strcmp(info.status, 'deskewed'), ...
        'testGeometryPipeline:SkewFallback', 'No-boundary text should receive supported skew-only correction.');
    width = size(plain,2); height = size(plain,1);
    points = [100 height/2; 520 height/2] - [(width+1)/2 (height+1)/2];
    rotation = [cosd(17) sind(17); -sind(17) cosd(17)];
    points = points * rotation.' + [(size(image,2)+1)/2 (size(image,1)+1)/2];
    mapped = transformPointsForward(info.transform, points);
    delta = mapped(2,:) - mapped(1,:);
    assert(abs(atan2d(delta(2), delta(1))) < 1, ...
        'testGeometryPipeline:SkewTransform', 'Composed skew-only transform does not straighten the known baseline.');
end

function checkLowEvidenceAndAPI()
    blank = repmat(uint8(240), [140 400]);
    [x,y] = meshgrid(1:160, 1:160);
    disk = uint8(255 * ~((x-80).^2 + (y-80).^2 < 30^2));
    cross = repmat(uint8(255), [160 160]);
    cross(30:130,73:87) = 0; cross(73:87,30:130) = 0;
    negatives = {blank, disk, cross};
    for index = 1:numel(negatives)
        [~, diagnostics] = estimateROILineDirection(negatives{index});
        assert(~diagnostics.accepted, 'testGeometryPipeline:AmbiguousAccepted', ...
            'Blank or non-directional symmetric fixture %d was accepted.', index);
    end
    box = [10 15 120 80];
    [corrected, info] = GeometricCorrection(blank, box, struct('PaddingFraction', 0));
    checkOutputContract(corrected, info, 1, 'uint8');
    crop = info.cropBox;
    expected = blank(crop(2):crop(2)+crop(4)-1, crop(1):crop(1)+crop(3)-1);
    assert(~info.accepted && ~info.perspectiveAccepted && info.resamplingPasses == 0 ...
        && isequal(corrected{1}, expected), ...
        'testGeometryPipeline:Unchanged', 'Low evidence must preserve the crop without resampling.');
    sample = [crop(1) crop(2); crop(1)+crop(3)-1 crop(2)+crop(4)-1];
    translated = transformPointsForward(info.transform, sample);
    assert(max(abs(translated(:) - [1; crop(3); 1; crop(4)])) < 1e-9, ...
        'testGeometryPipeline:CropTransform', 'Unchanged-crop translation is wrong.');
    [empty, emptyInfo] = GeometricCorrection(blank, zeros(0,4));
    assert(iscell(empty) && isequal(size(empty), [0 1]) && isempty(emptyInfo), ...
        'testGeometryPipeline:Empty', 'Empty boxes must preserve the empty output contract.');
    invalid = [500 1 30 20; 1 1 0 20; NaN 1 30 20];
    [invalidOutputs, invalidInfo] = GeometricCorrection(blank, invalid);
    checkOutputContract(invalidOutputs, invalidInfo, 3, 'uint8');
    assert(all(~[invalidInfo.accepted]) && all(cellfun(@isempty, invalidOutputs)), ...
        'testGeometryPipeline:InvalidBox', 'Invalid rows should be rejected with typed empty crops.');
    didThrow = false;
    try
        GeometricCorrection(blank, [1 1 20]);
    catch
        didThrow = true;
    end
    assert(didThrow, 'testGeometryPipeline:MalformedBox', 'A three-column box matrix must raise an error.');
end

function checkOutputContract(corrected, info, count, sourceClass)
    assert(iscell(corrected) && isequal(size(corrected), [count 1]) ...
        && isstruct(info) && numel(info) == count, ...
        'testGeometryPipeline:Shape', 'Expected N-by-1 crops and one info struct per box.');
    required = {'accepted','perspectiveAccepted','transform','outputReference', ...
        'resamplingPasses','lineAngle','status','reason','cropBox'};
    assert(all(isfield(info, required)), 'testGeometryPipeline:Metadata', 'Pipeline metadata is missing.');
    for index = 1:count
        assert(isa(corrected{index}, sourceClass) && islogical(info(index).accepted) ...
            && islogical(info(index).perspectiveAccepted), ...
            'testGeometryPipeline:Class', 'Class and logical acceptance flags must be preserved.');
        if ~isempty(corrected{index})
            assert(isa(info(index).transform, 'projtform2d') ...
                && isa(info(index).outputReference, 'imref2d') ...
                && isequal(info(index).outputReference.ImageSize, size(corrected{index}, [1 2])) ...
                && ismember(info(index).resamplingPasses, [0 1]), ...
                'testGeometryPipeline:OutputMapping', 'Output reference or single-warp metadata is inconsistent.');
        end
    end
end
