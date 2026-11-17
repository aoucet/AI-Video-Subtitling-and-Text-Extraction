function report = test_full_pipeline(videoFile, expectedVideoText)
%TEST_FULL_PIPELINE Run geometry, NCC, and end-to-end pipeline checks.
%   test_full_pipeline()                     Synthetic cases and V15
%   test_full_pipeline("all")                Every dataset image and clip
%   test_full_pipeline(videoPath, "PHRASE")  Synthetic cases and one clip
%   test_full_pipeline("benchmark", opts)   Labeled YVT and ICDAR 2013 evaluation

root = fileparts(mfilename('fullpath'));
savedPath = path;
if nargin > 0 && isscalar(string(videoFile)) && strcmpi(string(videoFile), "benchmark")
    restore = onCleanup(@() path(savedPath));
    addpath(fullfile(root, 'benchmarks'));
    if nargin < 2, expectedVideoText = struct(); end
    report = videobench.run(root, expectedVideoText);
    return;
end
savedRng = rng;
restore = onCleanup(@() restoreEnvironment(savedPath, savedRng));
addpath(fullfile(root, 'tests'));
rng(480, 'twister');

repo = fullfile(root, 'AI-Video-Subtitling-and-Text-Extraction');
mediaRoots = {fullfile(root, 'dataset'), root, fullfile(repo, 'dataset'), repo};
if nargin < 1, videoFile = ""; end
if nargin < 2, expectedVideoText = ""; end
if isempty(videoFile), videoFile = ""; end
if isempty(expectedVideoText), expectedVideoText = ""; end
videoFile = string(videoFile);
expectedVideoText = string(expectedVideoText);
assert(isscalar(videoFile) && ~ismissing(videoFile) && ...
    isscalar(expectedVideoText) && ~ismissing(expectedVideoText), ...
    'Supply one video path or "all", and at most one expected phrase.');
checkPrerequisites();

datasetMode = videoFile == "" || strcmpi(videoFile, "all");
images = strings(0, 1);
videos = videoFile;
if datasetMode
    images = findMedia(mediaRoots, '02_Labeled_Screenshots', [".jpg" ".jpeg" ".png" ".bmp" ".tif" ".tiff"]);
    videos = findMedia(mediaRoots, '01_Original_Videos', [".mov" ".mp4" ".avi" ".m4v" ".mpg" ".mpeg" ".wmv"]);
    assert(any(strcmpi(fileNames(images), "V15_F02.jpg")), ...
        'test_full_pipeline:ScreenshotMissing', 'V15_F02.jpg is missing from 02_Labeled_Screenshots.');
    assert(any(strcmpi(fileNames(videos), "V15.MOV")), ...
        'test_full_pipeline:VideoMissing', 'V15.MOV is missing from 01_Original_Videos.');
    if videoFile == ""
        images = images(strcmpi(fileNames(images), "V15_F02.jpg"));
        videos = videos(strcmpi(fileNames(videos), "V15.MOV"));
    end
else
    assert(isfile(videoFile), 'test_full_pipeline:VideoMissing', ...
        'Video missing: %s', videoFile);
end

fprintf('MATLAB %s | %d screenshot fixtures, %d video fixtures\n', version, numel(images), numel(videos));
[templates, labels] = make_char_templates();
results = runChecks("NCC", @() pipelinechecks.ncc(templates, labels));
results = [results; runChecks("Detection", @pipelinechecks.detection)];
results = [results; runChecks("Geometry", @pipelinechecks.geometry)];
fprintf('Running the blank and tilted PARKING fixtures.\n');
results(end+1, 1) = processFrame(repmat(uint8(237), [300 700]), ...
    "Blank image", NaN, templates, labels);
results(end) = expect(results(end), results(end).Boxes == 0, "Expected zero detections.");

ink = render_char_image('PARKING', 76);
synthetic = repmat(uint8(255), [380 800]);
top = floor((size(synthetic, 1)-size(ink, 1))/2)+1;
left = floor((size(synthetic, 2)-size(ink, 2))/2)+1;
synthetic(top:top+size(ink, 1)-1, left:left+size(ink, 2)-1) = ink;
synthetic = imcomplement(imrotate(imcomplement(synthetic), 9, 'bilinear', 'loose'));
results(end+1, 1) = processFrame(synthetic, "Synthetic PARKING (+9 deg)", NaN, templates, labels);
results(end) = expect(results(end), hasText(results(end), "PARKING") && ...
    results(end).Deskewed + results(end).Rectified > 0 && results(end).NCCCharacters > 0, ...
    "Expected PARKING, an applied geometric correction, and OCR characters scored by NCC.");

imageNames = fileNames(images);
for k = 1:numel(images)
    if mod(k-1, 8) == 0
        fprintf('Testing dataset screenshots %d-%d of %d.\n', k, min(k+7, numel(images)), numel(images));
    end
    row = readImage(images(k), imageNames(k), templates, labels);
    if strcmpi(imageNames(k), "V15_F02.jpg")
        row = expect(row, hasText(row, "FIRST AID"), "Expected FIRST AID after OCR + NCC.");
    end
    results(end+1, 1) = row; %#ok<AGROW>
end

videoNames = fileNames(videos);
for k = 1:numel(videos)
    fprintf('Testing clip %d/%d, %s.\n', k, numel(videos), videoNames(k));
    frames = readVideo(videos(k), videoNames(k), templates, labels);
    results = [results; frames]; %#ok<AGROW>
    expected = expectedVideoText;
    if datasetMode
        expected = "";
        if strcmpi(videoNames(k), "V15.MOV")
            expected = expectedVideoText;
            if expected == "", expected = "FIRST AID"; end
        end
    end
    if expected ~= ""
        summary = newResult(videoNames(k) + " (sampled text)", NaN);
        if any([frames.Stage] == "OK")
            summary = expect(summary, any(arrayfun(@(row) hasText(row, expected), frames)) && ...
                any([frames.NCCCharacters] > 0), ...
                "Expected " + expected + " in a sampled frame and OCR characters scored by NCC.");
            results(end+1, 1) = summary; %#ok<AGROW>
        end
    end
end

report = struct2table(results);
failed = report.Stage ~= "OK";
fprintf('%d results passed, %d failed.\n', nnz(~failed), nnz(failed));
if any(failed)
    disp(report(failed, {'Source', 'Time_s', 'Stage', 'FinalText', 'Detail'}));
    error('test_full_pipeline:Failed', 'One or more full pipeline checks failed.');
end
fprintf('FULL_PIPELINE_TEST_PASSED\n');
end

function results = runChecks(suite, check)
fprintf('Running %s checks.\n', suite);
try
    checks = check();
    results = repmat(newResult("", NaN), height(checks), 1);
    for k = 1:height(checks)
        results(k).Source = suite + " | " + string(checks.Case(k));
        results(k).Detail = string(checks.Detail(k));
        results(k) = expect(results(k), checks.Passed(k), results(k).Detail);
    end
catch err
    results = failedResult(suite, NaN, "Component check", err);
end
end

function row = readImage(file, name, templates, labels)
try
    frame = imread(file);
catch err
    row = failedResult(name, NaN, "Image read", err);
    return;
end
row = processFrame(frame, name, NaN, templates, labels);
end

function results = readVideo(file, name, templates, labels)
try
    reader = VideoReader(file);
catch err
    results = failedResult(name, NaN, "Video open", err);
    return;
end
times = reader.Duration * [0.2 0.5 0.8];
results = repmat(newResult(name, NaN), numel(times), 1);
for k = 1:numel(times)
    try
        reader.CurrentTime = times(k);
        frame = readFrame(reader);
    catch err
        results(k) = failedResult(name, times(k), "Video decode", err);
        continue;
    end
    results(k) = processFrame(frame, name, times(k), templates, labels);
end
end

function files = findMedia(roots, subfolder, extensions)
files = strings(0, 1);
for k = 1:numel(roots)
    folder = fullfile(roots{k}, subfolder);
    if ~isfolder(folder), continue; end
    entries = dir(folder);
    names = string({entries(~[entries.isdir]).name}).';
    [~, ~, suffixes] = fileparts(names);
    names = names(ismember(lower(suffixes), extensions));
    if ~isempty(names)
        files = [files; fullfile(string(folder), names)]; %#ok<AGROW>
    end
end
[~, first] = unique(lower(fileNames(files)), 'sorted');
files = files(first);
end

function names = fileNames(files)
[~, stem, extension] = fileparts(files);
names = stem + extension;
end

function checkPrerequisites()
required = {'detectMSERFeatures', 'selectStrongestBbox', 'ocr', 'insertText', 'imwarp', 'normxcorr2'};
missing = cellfun(@(name) isempty(which(name)), required);
assert(~any(missing), 'test_full_pipeline:Prerequisites', ...
    'Install or enable Computer Vision Toolbox and Image Processing Toolbox. Missing: %s', ...
    strjoin(required(missing), ', '));
end

function restoreEnvironment(savedPath, savedRng)
path(savedPath);
rng(savedRng);
end

function result = expect(result, passed, detail)
if result.Stage == "OK" && ~passed
    result.Stage = "Expectation";
    result.Detail = detail;
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
