function report = test_full_pipeline(videoFile, expectedVideoText)
%TEST_FULL_PIPELINE Exercise video decoding, MSER, geometry, OCR, and NCC.
% From the project folder in MATLAB or its VS Code terminal:
%   report = test_full_pipeline();
% Or choose another clip and specify visible text for its sampled frames:
%   report = test_full_pipeline(videoPath, "EXPECTED WORDS");
% Media folders can be under dataset/ or beside this file (MATLAB Drive).
% Tests three sampled frames, not an entire video or the App Designer UI.

root = fileparts(mfilename('fullpath'));
repo = fullfile(root, 'AI-Video-Subtitling-and-Text-Extraction');
mediaRoots = {fullfile(root, 'dataset'), root, fullfile(repo, 'dataset'), repo};
if nargin < 1 || isempty(videoFile)
    videoFile = findFixture(mediaRoots, '01_Original_Videos', 'V15.MOV');
    if nargin < 2, expectedVideoText = "FIRST AID"; end
elseif nargin < 2
    expectedVideoText = "";
end
fixtureFile = findFixture(mediaRoots, '02_Labeled_Screenshots', 'V15_F02.jpg');
expectedVideoText = string(expectedVideoText);
assert(isscalar(expectedVideoText), 'Supply one expected phrase.');

fprintf('MATLAB %s\n', version);
checkPrerequisites(videoFile, fixtureFile);
fprintf('Video: %s\nScreenshot: %s\n', char(videoFile), char(fixtureFile));
try
    [templates, labels] = make_char_templates();
catch err
    failStage('startup', 'NCC template generation', err);
end

results = repmat(newResult("", NaN), 0, 1);
checks = strings(0, 1);

blank = repmat(uint8(237), [300 700]);
results(end+1, 1) = processFrame(blank, "Blank image", NaN, templates, labels);
if results(end).Stage == "OK" && results(end).Boxes ~= 0
    checks(end+1, 1) = "Blank image: expected zero detections.";
end

% A known tilted phrase supplies a repeatable recognition target.
ink = render_char_image('PARKING', 76);
synthetic = repmat(uint8(255), [380 800]);
top = floor((size(synthetic, 1)-size(ink, 1))/2)+1;
left = floor((size(synthetic, 2)-size(ink, 2))/2)+1;
synthetic(top:top+size(ink, 1)-1, left:left+size(ink, 2)-1) = ink;
synthetic = imcomplement(imrotate(imcomplement(synthetic), 9, 'bilinear', 'loose'));
results(end+1, 1) = processFrame(synthetic, "Synthetic PARKING (+9 deg)", NaN, templates, labels);
if results(end).Stage == "OK"
    if ~hasText(results(end), "PARKING")
        checks(end+1, 1) = "Synthetic image: expected PARKING after OCR + NCC.";
    end
    if results(end).Deskewed + results(end).Rectified == 0
        checks(end+1, 1) = "Synthetic image: expected at least one applied geometric correction.";
    end
    if results(end).NCCCharacters == 0
        checks(end+1, 1) = "Synthetic image: expected OCR characters to reach the NCC verifier.";
    end
end

try
    frame = imread(fixtureFile);
    results(end+1, 1) = processFrame(frame, "V15_F02.jpg", NaN, templates, labels);
    if results(end).Stage == "OK" && ~hasText(results(end), "FIRST AID")
        checks(end+1, 1) = "Real screenshot: expected FIRST AID after OCR + NCC.";
    end
catch err
    results(end+1, 1) = failedResult("V15_F02.jpg", NaN, "Image read", err);
end

firstVideoRow = numel(results)+1;
try
    reader = VideoReader(videoFile);
    for fraction = [0.2 0.5 0.8]
        t = fraction * reader.Duration;
        try
            reader.CurrentTime = t;
            frame = readFrame(reader);
        catch err
            results(end+1, 1) = failedResult(string(reader.Name), t, "Video decode", err); %#ok<AGROW>
            continue;
        end
        results(end+1, 1) = processFrame(frame, string(reader.Name), t, templates, labels); %#ok<AGROW>
    end
catch err
    results(end+1, 1) = failedResult(string(videoFile), NaN, "Video open", err);
end
videoResults = results(firstVideoRow:end);
videoResults = videoResults([videoResults.Stage] == "OK");
if ~isempty(videoResults) && strlength(expectedVideoText) > 0 && ...
        ~any(arrayfun(@(r) hasText(r, expectedVideoText), videoResults))
    checks(end+1, 1) = "Sampled video: none of the frames recovered " + expectedVideoText + ".";
end
if ~isempty(videoResults) && ~any([videoResults.NCCCharacters] > 0)
    checks(end+1, 1) = "Sampled video: no recognized characters reached the NCC verifier.";
end

report = struct2table(results);
disp(report);
for k = 1:numel(results)
    row = results(k);
    fprintf('%s', char(row.Source));
    if isfinite(row.Time_s), fprintf(' at %.2f s', row.Time_s); end
    fprintf(' | %s | %d boxes, %d deskewed, %d rectified, %d NCC chars, %d verified | %.1f ms\n', ...
        char(row.Stage), row.Boxes, row.Deskewed, row.Rectified, row.NCCCharacters, row.NCCVerified, row.Pipeline_ms);
    if row.Stage == "OK"
        fprintf('  OCR: %s\n  OCR + NCC: %s\n', char(row.RawOCR), char(row.FinalText));
    else
        fprintf('  %s\n', char(row.Detail));
    end
end
if any(report.Stage ~= "OK") || ~isempty(checks)
    fprintf(2, 'Full pipeline checks did not pass. See stage and text results above.\n');
    for k = 1:numel(checks), fprintf(2, '  %s\n', char(checks(k))); end
    error('test_full_pipeline:Failed', 'One or more full pipeline checks failed.');
end
fprintf('FULL_PIPELINE_TEST_PASSED\n');
end

function path = findFixture(roots, subfolder, filename)
% Keep the original default path for the error if no layout matches.
path = fullfile(roots{1}, subfolder, filename);
for k = 1:numel(roots)
    folder = fullfile(roots{k}, subfolder);
    candidate = fullfile(folder, filename);
    if isfile(candidate)
        path = candidate;
        return;
    end
    if ~isfolder(folder), continue; end
    entries = dir(folder);
    matches = find(~[entries.isdir] & strcmpi({entries.name}, filename));
    if isscalar(matches)
        path = fullfile(folder, entries(matches).name);
        return;
    end
end
end

function checkPrerequisites(videoFile, fixtureFile)
checks = strings(0, 1);
visionFunctions = {'detectMSERFeatures', 'selectStrongestBbox', 'ocr'};
missing = cellfun(@(name) isempty(which(name)), visionFunctions);
if any(missing)
    checks(end+1, 1) = "Computer Vision Toolbox functions unavailable: " + ...
        strjoin(visionFunctions(missing), ', ') + ". MATLAB Online Basic does not include this toolbox.";
end
if isempty(which('imwarp'))
    checks(end+1, 1) = "Image Processing Toolbox function unavailable: imwarp.";
end
if ~isfile(videoFile)
    checks(end+1, 1) = "Video missing: " + string(videoFile) + ...
        ". Put the original video folder under dataset/ or beside the test, or pass a video path.";
end
if ~isfile(fixtureFile)
    checks(end+1, 1) = "Screenshot missing: " + string(fixtureFile) + ...
        ". Put 02_Labeled_Screenshots under dataset/ or beside the test.";
end
if ~isempty(checks)
    error('test_full_pipeline:Prerequisites', 'Cannot start the full pipeline:\n  %s', ...
        char(join(checks, sprintf('\n  '))));
end
end

function result = processFrame(frame, source, time, templates, labels)
result = newResult(source, time);
started = tic;
stage = "MSER detection";
try
    % Match the app's working image size and its recognition crop margin.
    scale = 1920 / max(size(frame, 1:2));
    if scale < 1, frame = imresize(frame, scale); end
    boxes = detectTextRegions(frame);
    assert(size(boxes, 2) == 4 && all(isfinite(boxes), 'all') && ...
        all(boxes(:, 3:4) > 0, 'all'), 'Expected finite N-by-4 text boxes with positive dimensions.');
    result.Boxes = size(boxes, 1);
    stage = "Geometric correction";
    [rois, info] = GeometricCorrection(frame, boxes);
    assert(numel(rois) == result.Boxes && numel(info) == result.Boxes, ...
        'Expected one crop and geometry record per detection.');
    assert(~any(cellfun(@isempty, rois)), 'A detected text box produced no crop.');
    statuses = string({info.status});
    result.Deskewed = nnz(statuses == "deskewed");
    result.Rectified = nnz(statuses == "perspective-rectified");
    stage = "OCR + NCC";
    raw = strings(result.Boxes, 1);
    verified = raw;
    for k = 1:result.Boxes
        roi = padarray(rois{k}, [20 20], 'replicate');
        recognized = recognize_text_region(roi, templates, labels);
        score = recognized.nccScore;
        assert(numel(score) == numel(recognized.verified) && ...
            all(isfinite(score)) && all(abs(score) <= 1+1e-8), 'Invalid NCC output.');
        result.NCCCharacters = result.NCCCharacters + numel(score);
        result.NCCVerified = result.NCCVerified + nnz(recognized.verified);
        raw(k) = oneLine(recognized.text);
        verified(k) = oneLine(recognized.correctedText);
    end
    [~, order] = sortrows([round(boxes(:, 2)/20), boxes(:, 1)]);
    result.RawOCR = joinText(raw(order));
    result.FinalText = joinText(verified(order));
catch err
    result.Stage = stage;
    result.Detail = string(err.identifier) + ": " + oneLine(err.message);
end
result.Pipeline_ms = toc(started)*1000;
end

function ok = hasText(result, expected)
normalized = @(s) regexprep(upper(s), '[^A-Z0-9]', '');
ok = result.Stage == "OK" && contains(normalized(result.FinalText), normalized(expected));
end

function text = oneLine(input)
text = strtrim(regexprep(string(input), '\s+', ' '));
end

function text = joinText(items)
items = items(strlength(items) > 0);
text = "";
if ~isempty(items), text = join(items, " | "); end
end

function result = newResult(source, time)
result = struct('Source', source, 'Time_s', time, 'Stage', "OK", 'Boxes', 0, ...
    'Deskewed', 0, 'Rectified', 0, 'NCCCharacters', 0, 'NCCVerified', 0, ...
    'Pipeline_ms', NaN, 'RawOCR', "", 'FinalText', "", 'Detail', "");
end

function result = failedResult(source, time, stage, err)
result = newResult(source, time);
result.Stage = stage;
result.Detail = string(err.identifier) + ": " + oneLine(err.message);
end

function failStage(source, stage, err)
exception = MException('test_full_pipeline:Stage', '%s — %s failed.', source, stage);
throwAsCaller(addCause(exception, err));
end
