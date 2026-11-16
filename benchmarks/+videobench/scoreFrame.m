function result = scoreFrame(gtBoxes, gtTexts, predBoxes, predTexts, ignoredBoxes, iouThreshold)
%SCOREFRAME Match detections and text in a single annotated frame.
% Inputs share an original-frame [x y width height] coordinate system.
% Match columns are [ground truth index, original prediction index, IoU].

if nargin < 5, ignoredBoxes = zeros(0, 4); end
if nargin < 6, iouThreshold = 0.5; end
validateattributes(iouThreshold, {'numeric'}, {'real','finite','scalar','>',0,'<=',1});
gtBoxes = validateBoxes(gtBoxes);
predBoxes = validateBoxes(predBoxes);
ignoredBoxes = validateBoxes(ignoredBoxes);
gtTexts = normalizeTexts(gtTexts, size(gtBoxes, 1), false);
predTexts = normalizeTexts(predTexts, size(predBoxes, 1), true);

gtArea = prod(gtBoxes(:, 3:4), 2);
predArea = prod(predBoxes(:, 3:4), 2);
intersection = intersections(gtBoxes, predBoxes);
iou = intersection ./ (gtArea + predArea.' - intersection);
eligible = iou >= iouThreshold;

% Ignore a detection covered by an ignored region when it has no scored match.
ignoredOverlap = intersections(ignoredBoxes, predBoxes) ./ predArea.';
ignoredPrediction = (any(ignoredOverlap >= 0.5, 1) & ~any(eligible, 1)).';
detection = matchBoxes(iou, eligible);
sameText = gtTexts == predTexts.';
spotting = matchBoxes(iou, eligible & sameText);

gtTokens = regexp(cellstr(gtTexts), '\S+', 'match');
predTokens = regexp(cellstr(predTexts), '\S+', 'match');
gtWordCounts = cellfun(@numel, gtTokens);
predWordCounts = cellfun(@numel, predTokens);
gtChars = strlength(gtTexts);
predChars = strlength(predTexts);

numMatches = size(detection, 1);
matchedGT = false(size(gtBoxes, 1), 1);
matchedPred = false(size(predBoxes, 1), 1);
matchedGT(detection(:, 1)) = true;
matchedPred(detection(:, 2)) = true;
correctText = 0;
characterEdits = 0;
wordEdits = 0;
for k = 1:numMatches
    i = detection(k, 1);
    j = detection(k, 2);
    correctText = correctText + sameText(i, j);
    characterEdits = characterEdits + editCount(char(gtTexts(i)), char(predTexts(j)));
    wordEdits = wordEdits + editCount(string(gtTokens{i}), string(predTokens{j}));
end

eligiblePredCount = nnz(~ignoredPrediction);
unmatchedPred = ~matchedPred & ~ignoredPrediction;
referenceCount = size(gtBoxes, 1);
numSpotted = size(spotting, 1);
result = struct( ...
    'GT', referenceCount, ...
    'Predictions', eligiblePredCount, ...
    'IgnoredPredictions', nnz(ignoredPrediction), ...
    'DetectionTP', numMatches, ...
    'DetectionFP', eligiblePredCount - numMatches, ...
    'DetectionFN', referenceCount - numMatches, ...
    'SpottingTP', numSpotted, ...
    'SpottingFP', eligiblePredCount - numSpotted, ...
    'SpottingFN', referenceCount - numSpotted, ...
    'MatchedIoUSum', sum(detection(:, 3)), ...
    'OCRCorrect', correctText, ...
    'OCRCompared', numMatches, ...
    'CharacterEdits', characterEdits, ...
    'ReferenceCharacters', sum(gtChars(matchedGT)), ...
    'WordEdits', wordEdits, ...
    'ReferenceWords', sum(gtWordCounts(matchedGT)), ...
    'EndToEndCharacterEdits', characterEdits + sum(gtChars(~matchedGT)) + sum(predChars(unmatchedPred)), ...
    'EndToEndReferenceCharacters', sum(gtChars), ...
    'EndToEndWordEdits', wordEdits + sum(gtWordCounts(~matchedGT)) + sum(predWordCounts(unmatchedPred)), ...
    'EndToEndReferenceWords', sum(gtWordCounts), ...
    'DetectionMatches', detection, ...
    'SpottingMatches', spotting, ...
    'IgnoredPredictionIndices', find(ignoredPrediction));
end

function boxes = validateBoxes(boxes)
if isempty(boxes), boxes = zeros(0, 4); end
validateattributes(boxes, {'numeric'}, {'real','finite','2d','nonsparse'});
assert(size(boxes, 2) == 4 && all(boxes(:, 3:4) > 0, 'all'), ...
    'videobench:InvalidBoxes', 'Use finite [x y width height] rows with positive width and height.');
boxes = double(boxes);
end

function texts = normalizeTexts(values, count, allowEmpty)
if isempty(values) && allowEmpty
    values = strings(count, 1);
end
texts = string(values);
texts = texts(:);
assert(numel(texts) == count, 'videobench:TextCount', 'Supply one transcript per box.');
texts(ismissing(texts)) = "";
texts = lower(strtrim(regexprep(texts, '\s+', ' ')));
assert(allowEmpty || all(strlength(texts) > 0), ...
    'videobench:MissingGroundTruth', 'Pass untranscribed regions in ignoredBoxes.');
end

function areas = intersections(a, b)
highA = a(:, 1:2) + a(:, 3:4);
highB = b(:, 1:2) + b(:, 3:4);
width = max(0, min(highA(:, 1), highB(:, 1).') - max(a(:, 1), b(:, 1).'));
height = max(0, min(highA(:, 2), highB(:, 2).') - max(a(:, 2), b(:, 2).'));
areas = width .* height;
end

function matches = matchBoxes(iou, eligible)
matches = zeros(0, 3);
if ~any(eligible, 'all'), return; end

% A new valid pair outranks any change in the sum of overlaps.
pairBonus = min(size(iou)) + 1;
weights = -ones(size(iou));
weights(eligible) = pairBonus + iou(eligible);
assignments = matchpairs(weights, 0, 'max');
scores = iou(sub2ind(size(iou), assignments(:, 1), assignments(:, 2)));
matches = [assignments, scores];
end

function distance = editCount(reference, prediction)
if isequal(reference, prediction)
    distance = 0;
    return;
end
cost = 0:numel(reference);
for i = 1:numel(prediction)
    diagonal = cost(1);
    cost(1) = i;
    for j = 1:numel(reference)
        previous = cost(j+1);
        substitute = diagonal + (reference(j) ~= prediction(i));
        cost(j+1) = min([previous + 1, cost(j) + 1, substitute]);
        diagonal = previous;
    end
end
distance = cost(end);
end
