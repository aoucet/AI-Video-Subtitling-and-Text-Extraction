function R = recognize_text_region(roi, templates, labels, opts)
%RECOGNIZE_TEXT_REGION Read a text line and verify supported glyphs with NCC.
    if nargin < 4, opts = struct(); end
    nccThresh   = getOpt(opts, 'nccThresh',   0.60);
    fixOcrConf  = getOpt(opts, 'fixOcrConf',  0.50);
    fixNccScore = getOpt(opts, 'fixNccScore', 0.80);
    margin      = getOpt(opts, 'margin',      2);

    if size(roi, 3) == 3
        roi = rgb2gray(roi);
    end

    res = ocr(roi, 'LayoutAnalysis', 'line');

    % Text, character boxes and confidences share their original positions.
    rawText = res.Text(:).';
    boxes = res.CharacterBoundingBoxes;
    confs = res.CharacterConfidences(:).';

    validBoxes = all(isfinite(boxes), 2) & all(boxes(:, 3:4) > 0, 2);
    keep = ismember(rawText, labels) & validBoxes.' & isfinite(confs);
    chars = rawText(keep);
    boxes = boxes(keep, :);
    confs = confs(keep);

    N = numel(chars);
    nccLabel  = repmat(' ', 1, N);
    nccScore  = zeros(1, N);
    verified  = false(1, N);
    corrected = chars;

    for i = 1:N
        patch = imcrop(roi, boxes(i, :));
        [nccLabel(i), nccScore(i)] = verify_char(patch, templates, labels, margin);

        verified(i) = (nccLabel(i) == chars(i)) && (nccScore(i) >= nccThresh);

        if ~verified(i) && confs(i) < fixOcrConf && nccScore(i) >= fixNccScore
            corrected(i) = nccLabel(i);
        end
    end

    correctedText = rawText;
    correctedText(keep) = corrected;
    R.text          = strtrim(rawText);
    R.correctedText = strtrim(correctedText);
    R.chars         = chars;
    R.charBoxes     = boxes;
    R.ocrConf       = confs;
    R.nccLabel      = nccLabel;
    R.nccScore      = nccScore;
    R.verified      = verified;
    if N > 0
        R.verifiedRatio = mean(verified);
    else
        R.verifiedRatio = 0;
    end
    if getOpt(opts, 'returnWords', false)
        [R.wordBoxes, R.words, R.correctedWords] = ...
            wordLocations(rawText, correctedText, res.CharacterBoundingBoxes);
    end
end

function [boxes, words, corrected] = wordLocations(rawText, correctedText, charBoxes)
    [first, last] = regexp(rawText, '\S+', 'start', 'end');
    boxes = zeros(numel(first), 4);
    words = strings(numel(first), 1);
    corrected = words;
    for index = 1:numel(first)
        span = first(index):last(index);
        positions = charBoxes(span, :);
        positions = positions(all(isfinite(positions), 2) & all(positions(:,3:4) > 0, 2), :);
        if isempty(positions), continue; end
        low = min(positions(:,1:2), [], 1);
        high = max(positions(:,1:2) + positions(:,3:4), [], 1);
        boxes(index, :) = [low, high-low];
        words(index) = string(rawText(span));
        corrected(index) = string(correctedText(span));
    end
    keep = all(boxes(:,3:4) > 0, 2);
    boxes = boxes(keep, :);
    words = words(keep);
    corrected = corrected(keep);
end

function v = getOpt(s, name, default)
    if isfield(s, name), v = s.(name); else, v = default; end
end
