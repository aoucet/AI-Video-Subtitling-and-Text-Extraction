function report = run(projectRoot, options)
% Score the production pipeline on labeled YVT and ICDAR 2013 clips.
if isempty(options), options = struct(); end
validateattributes(options, {'struct'}, {'scalar'});
datasetNames = upper(string(option(options, 'Datasets', ["YVT", "ICDAR2013TRAIN"])));
framesPerClip = option(options, 'FramesPerClip', 5);
validateattributes(framesPerClip, {'numeric'}, {'scalar', 'real', 'positive'});
assert(isinf(framesPerClip) || framesPerClip == fix(framesPerClip), ...
    'FramesPerClip must be a positive integer or Inf.');
threshold = option(options, 'IoUThreshold', 0.5);
validateattributes(threshold, {'numeric'}, {'scalar', 'real', '>', 0, '<=', 1});
assert(~isempty(datasetNames) && all(ismember(datasetNames, ...
    ["YVT", "ICDAR2013", "ICDAR2013TRAIN"]), 'all'), ...
    'Datasets must name YVT, ICDAR2013 (test), or ICDAR2013TRAIN.');
output = string(option(options, 'OutputFolder', fullfile(projectRoot, 'benchmarks', 'results')));
dataRoot = option(options, 'DataFolder', fullfile(projectRoot, 'benchmarks', 'data'));
retryErrors = option(options, 'RetryErrors', false);
validateattributes(retryErrors, {'logical'}, {'scalar'});
if ~isfolder(output), mkdir(output); end

[templates, labels] = make_char_templates();
report = struct('Datasets', table(), 'Clips', table(), 'Frames', table());
for dataset = unique(datasetNames(:).', 'stable')
    clipRows = repmat(emptySummary(), 0, 1);
    frameRows = repmat(emptyFrame(), 0, 1);
    try
        sequences = loadSequences(dataset, dataRoot);
    catch err
        row = summarize(frameRows, dataset, "", 0, threshold);
        row.Status = "Unavailable";
        row.Detail = failureDetail(err);
        writeCsv(struct2table(row), fullfile(output, dataset + "_summary.csv"));
        report.Datasets = [report.Datasets; struct2table(row)];
        fprintf(2, '%s unavailable: %s\n', dataset, row.Detail);
        continue;
    end
    fprintf('%s | %d clips in the selected split | at most %g frames per clip\n', ...
        dataset, numel(sequences), framesPerClip);
    previous = loadRetryRows(output, dataset, numel(sequences), threshold, retryErrors);
    for k = 1:numel(sequences)
        clip = sequences(k);
        rows = scoreClip(clip, dataset, framesPerClip, threshold, templates, labels, previous);
        frameRows = [frameRows; rows]; %#ok<AGROW>
        clipRows(end+1, 1) = summarize(rows, dataset, clip.Name, 1, threshold); %#ok<AGROW>
        fprintf('%s %d/%d %s | %d scored, %d errors | %.2f s mean pipeline time\n', ...
            dataset, k, numel(sequences), clip.Name, clipRows(end).FramesScored, ...
            clipRows(end).FrameErrors, clipRows(end).MeanPipelineMs / 1000);
        if retryErrors && k < numel(sequences), continue; end
        writeCsv(struct2table(frameRows), fullfile(output, dataset + "_frames.csv"));
        writeCsv(struct2table(clipRows), fullfile(output, dataset + "_clips.csv"));
        row = summarize(frameRows, dataset, "", k, threshold);
        if k < numel(sequences)
            row.Status = "In progress";
            row.Detail = string(k) + " of " + string(numel(sequences)) + " clips visited.";
        end
        writeCsv(struct2table(row), fullfile(output, dataset + "_summary.csv"));
    end
    report.Frames = [report.Frames; struct2table(frameRows)];
    report.Clips = [report.Clips; struct2table(clipRows)];
    report.Datasets = [report.Datasets; struct2table(row)];
end
disp(report.Datasets(:, {'Dataset', 'Status', 'FramesScored', 'FramesAttempted', ...
    'LineDetectionF1', 'WordSpottingF1', 'MatchedWordAccuracy', 'MeanPipelineMs'}));
end

function sequences = loadSequences(dataset, root)
folder = fullfile(root, dataset);
switch dataset
    case "YVT"
        sequences = videobench.loadYvt(folder);
    case "ICDAR2013"
        sequences = videobench.loadIcdar(fullfile(folder, "test"));
    case "ICDAR2013TRAIN"
        sequences = videobench.loadIcdar(fullfile(root, "ICDAR2013", "train"), "train");
end
end

function previous = loadRetryRows(output, dataset, clipCount, threshold, retryErrors)
previous = repmat(emptyFrame(), 0, 1);
if ~retryErrors, return; end
summary = readtable(fullfile(output, dataset + "_summary.csv"), 'TextType', 'string');
assert(height(summary) == 1 && summary.Status == "Partial" && summary.Clips == clipCount ...
    && summary.IoUThreshold == threshold, ...
    'videobench:RetrySettings', 'RetryErrors requires the same settings as a finished partial run.');
frames = readtable(fullfile(output, dataset + "_frames.csv"), 'TextType', 'string');
assert(all(string(frames.Dataset) == dataset) && height(frames) == summary.FramesAttempted && ...
    isequal(frames.Properties.VariableNames, fieldnames(emptyFrame()).'), ...
    'videobench:RetrySettings', 'The saved frame table does not match this benchmark.');
previous = table2struct(frames);
for k = 1:numel(previous)
    if ismissing(previous(k).Detail), previous(k).Detail = ""; end
end
end

function rows = scoreClip(clip, dataset, framesPerClip, threshold, templates, labels, previous)
assert(~isempty(clip.Frames), 'Test clip %s has no annotated frames.', clip.Name);
indices = sampleIndices([clip.Frames.Index], framesPerClip);
rows = repmat(emptyFrame(), numel(indices), 1);
pending = true(numel(indices), 1);
if ~isempty(previous)
    saved = previous([previous.Clip] == clip.Name);
    assert(isequal([saved.Frame], [clip.Frames(indices).Index]), ...
        'videobench:RetrySettings', 'Saved results use different frame indices for %s.', clip.Name);
    success = [saved.Status] == "OK";
    rows(success) = saved(success);
    pending = ~success(:);
end
reader = [];
videoFailure = "";
if any(strlength(string({clip.Frames(indices(pending)).ImagePath})) == 0)
    try
        reader = VideoReader(clip.VideoPath);
    catch err
        videoFailure = failureDetail(err);
    end
end

for k = reshape(find(pending), 1, [])
    annotation = clip.Frames(indices(k));
    row = rows(k);
    row.Dataset = dataset;
    row.Clip = clip.Name;
    row.Frame = annotation.Index;
    row.ReferenceWords = size(annotation.Boxes, 1);
    try
        if strlength(annotation.ImagePath) > 0
            frame = imread(annotation.ImagePath);
        else
            assert(videoFailure == "", '%s', videoFailure);
            frame = read(reader, annotation.Index);
        end
        checkAnnotationBounds(frame, annotation);
        started = tic;
        prediction = videobench.predictFrame(frame, templates, labels);
        row.PipelineMs = toc(started) * 1000;
        [lineBoxes, lineTexts] = videobench.gtLines(annotation.Boxes, annotation.Texts);
        line = videobench.scoreFrame(lineBoxes, lineTexts, prediction.LineBoxes, ...
            strings(size(prediction.LineBoxes, 1), 1), annotation.IgnoredBoxes, threshold);
        word = videobench.scoreFrame(annotation.Boxes, annotation.Texts, ...
            prediction.WordBoxes, prediction.Words, annotation.IgnoredBoxes, threshold);
        raw = videobench.scoreFrame(annotation.Boxes, annotation.Texts, ...
            prediction.WordBoxes, prediction.RawWords, annotation.IgnoredBoxes, threshold);

        row.ReferenceLines = line.GT;
        row.PredictedLines = line.Predictions;
        row.LineTP = line.DetectionTP;
        row.IgnoredLines = line.IgnoredPredictions;
        row.PredictedWords = word.Predictions;
        row.IgnoredWords = word.IgnoredPredictions;
        row.WordLocalizationTP = word.DetectionTP;
        row.WordSpottingTP = word.SpottingTP;
        row.RawSpottingTP = raw.SpottingTP;
        row.MatchedOCRCorrect = word.OCRCorrect;
        row.MatchedOCRCompared = word.OCRCompared;
        row.MatchedCharacterEdits = word.CharacterEdits;
        row.MatchedReferenceCharacters = word.ReferenceCharacters;
        row.EndToEndCharacterEdits = word.EndToEndCharacterEdits;
        row.EndToEndReferenceCharacters = word.EndToEndReferenceCharacters;
        row.EndToEndWordEdits = word.EndToEndWordEdits;
        row.EndToEndReferenceWords = word.EndToEndReferenceWords;
        row.Deskewed = prediction.Deskewed;
        row.Rectified = prediction.Rectified;
        row.Status = "OK";
    catch err
        row.Status = "Error";
        row.Detail = failureDetail(err);
        if nnz([rows.Status] == "Error") < 2
            fprintf(2, '%s %s frame %d: %s\n', dataset, clip.Name, annotation.Index, row.Detail);
        end
    end
    rows(k) = row;
end
end

function checkAnnotationBounds(frame, annotation)
boxes = [annotation.Boxes; annotation.IgnoredBoxes];
dimensions = [size(frame, 2), size(frame, 1)];
if any(boxes(:, 1:2) > dimensions | ...
        boxes(:, 1:2) + boxes(:, 3:4) < 1, 'all')
    error('videobench:AnnotationCoordinates', ...
        'A reference box does not intersect the %d-by-%d frame.', dimensions(1), dimensions(2));
end
end

function indices = sampleIndices(frames, limit)
[frames, order] = sort(frames);
assert(numel(unique(frames)) == numel(frames), 'Duplicate annotated frame indices.');
count = min(numel(frames), limit);
if count == numel(frames)
    indices = order;
    return;
end
edges = linspace(frames(1), frames(end) + 1, count + 1);
targets = (edges(1:end-1) + edges(2:end)) / 2;
chosen = false(size(frames));
indices = zeros(1, count);
for k = 1:count
    distances = abs(frames - targets(k));
    distances(chosen) = Inf;
    [~, nearest] = min(distances);
    chosen(nearest) = true;
    indices(k) = nearest;
end
indices = order(sort(indices));
end

function row = summarize(rows, dataset, clip, clipsVisited, threshold)
row = emptySummary();
row.Dataset = dataset;
row.Clip = clip;
row.Clips = clipsVisited;
row.IoUThreshold = threshold;
row.FramesAttempted = numel(rows);
usable = [rows.Status] == "OK";
row.FramesScored = nnz(usable);
row.FrameErrors = numel(rows) - row.FramesScored;
if row.FramesScored == 0
    row.Status = "No scored frames";
    if ~isempty(rows), row.Detail = rows(1).Detail; end
    return;
end
row.Status = "Complete";
if row.FrameErrors > 0
    row.Status = "Partial";
    failures = rows(~usable);
    row.Detail = failures(1).Detail;
end
scored = rows(usable);
row.ReferenceLines = sum([scored.ReferenceLines]);
row.PredictedLines = sum([scored.PredictedLines]);
row.LineTP = sum([scored.LineTP]);
row.LineFP = row.PredictedLines - row.LineTP;
row.LineFN = row.ReferenceLines - row.LineTP;
row.ReferenceWords = sum([scored.ReferenceWords]);
row.PredictedWords = sum([scored.PredictedWords]);
row.WordSpottingTP = sum([scored.WordSpottingTP]);
row.WordSpottingFP = row.PredictedWords - row.WordSpottingTP;
row.WordSpottingFN = row.ReferenceWords - row.WordSpottingTP;
[row.LineDetectionPrecision, row.LineDetectionRecall, row.LineDetectionF1] = ...
    prf(row.LineTP, row.PredictedLines, row.ReferenceLines);
[row.WordLocalizationPrecision, row.WordLocalizationRecall, row.WordLocalizationF1] = ...
    prf(sum([scored.WordLocalizationTP]), row.PredictedWords, row.ReferenceWords);
[row.WordSpottingPrecision, row.WordSpottingRecall, row.WordSpottingF1] = ...
    prf(row.WordSpottingTP, row.PredictedWords, row.ReferenceWords);
[~, ~, row.RawWordSpottingF1] = prf(sum([scored.RawSpottingTP]), ...
    row.PredictedWords, row.ReferenceWords);
row.MatchedWords = sum([scored.MatchedOCRCompared]);
row.MatchedWordAccuracy = ratio(sum([scored.MatchedOCRCorrect]), row.MatchedWords);
row.MatchedCER = ratio(sum([scored.MatchedCharacterEdits]), sum([scored.MatchedReferenceCharacters]));
row.EndToEndCER = ratio(sum([scored.EndToEndCharacterEdits]), sum([scored.EndToEndReferenceCharacters]));
row.EndToEndWER = ratio(sum([scored.EndToEndWordEdits]), sum([scored.EndToEndReferenceWords]));
row.Deskewed = sum([scored.Deskewed]);
row.Rectified = sum([scored.Rectified]);
row.MeanPipelineMs = mean([scored.PipelineMs]);
row.MedianPipelineMs = median([scored.PipelineMs]);
row.PipelineFPS = 1000 / row.MeanPipelineMs;
end

function [precision, recall, f1] = prf(matches, predictions, references)
precision = ratio(matches, predictions);
recall = ratio(matches, references);
f1 = ratio(2 * matches, predictions + references);
end

function value = ratio(numerator, denominator)
value = NaN;
if denominator > 0, value = numerator / denominator; end
end

function row = emptyFrame()
row = struct('Dataset', "", 'Clip', "", 'Frame', NaN, 'Status', "", 'Detail', "", ...
    'ReferenceLines', NaN, 'PredictedLines', NaN, 'LineTP', NaN, 'IgnoredLines', NaN, ...
    'ReferenceWords', NaN, 'PredictedWords', NaN, 'IgnoredWords', NaN, ...
    'WordLocalizationTP', NaN, 'WordSpottingTP', NaN, 'RawSpottingTP', NaN, ...
    'MatchedOCRCorrect', NaN, 'MatchedOCRCompared', NaN, 'MatchedCharacterEdits', NaN, ...
    'MatchedReferenceCharacters', NaN, 'EndToEndCharacterEdits', NaN, ...
    'EndToEndReferenceCharacters', NaN, 'EndToEndWordEdits', NaN, ...
    'EndToEndReferenceWords', NaN, 'Deskewed', NaN, 'Rectified', NaN, 'PipelineMs', NaN);
end

function row = emptySummary()
row = struct('Dataset', "", 'Clip', "", 'Status', "", 'Detail', "", 'Clips', 0, ...
    'FramesAttempted', 0, 'FramesScored', 0, 'FrameErrors', 0, 'IoUThreshold', NaN, ...
    'ReferenceLines', NaN, 'PredictedLines', NaN, 'LineTP', NaN, 'LineFP', NaN, 'LineFN', NaN, ...
    'ReferenceWords', NaN, 'PredictedWords', NaN, ...
    'WordSpottingTP', NaN, 'WordSpottingFP', NaN, 'WordSpottingFN', NaN, ...
    'LineDetectionPrecision', NaN, 'LineDetectionRecall', NaN, 'LineDetectionF1', NaN, ...
    'WordLocalizationPrecision', NaN, 'WordLocalizationRecall', NaN, 'WordLocalizationF1', NaN, ...
    'WordSpottingPrecision', NaN, 'WordSpottingRecall', NaN, 'WordSpottingF1', NaN, ...
    'RawWordSpottingF1', NaN, 'MatchedWords', NaN, 'MatchedWordAccuracy', NaN, ...
    'MatchedCER', NaN, 'EndToEndCER', NaN, 'EndToEndWER', NaN, 'Deskewed', NaN, 'Rectified', NaN, ...
    'MeanPipelineMs', NaN, 'MedianPipelineMs', NaN, 'PipelineFPS', NaN);
end

function value = option(options, name, fallback)
value = fallback;
if isfield(options, name), value = options.(name); end
end

function detail = failureDetail(err)
detail = string(err.identifier) + ": " + regexprep(strtrim(string(err.message)), '\s+', ' ');
if ~isempty(err.stack)
    detail = detail + " [" + string(err.stack(1).name) + ":" + err.stack(1).line + "]";
end
end

function writeCsv(rows, destination)
temporary = string(tempname(fileparts(destination))) + ".csv";
writetable(rows, temporary, 'Encoding', 'UTF-8');
movefile(temporary, destination, 'f');
end

