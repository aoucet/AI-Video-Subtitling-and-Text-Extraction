function result = predictFrame(frame, templates, labels)
% Run the proposed still-frame pipeline and return words in input pixels.
[~, texts, details] = runTextPipeline(frame, true, templates, labels);
result = struct('LineBoxes', zeros(0,4), 'WordBoxes', zeros(0,4), ...
    'Words', strings(0,1), 'RawWords', strings(0,1), ...
    'Deskewed', 0, 'Rectified', 0);
if isempty(details), return; end
% Line detection is measured before recognition rejects any crops.
result.LineBoxes = vertcat(details.detectionBox);
result.Deskewed = nnz(abs([details.angle]) > 1e-6);
for k = 1:numel(details)
    if isempty(texts{k}), continue; end
    reading = details(k).verification;
    [boxes, keep] = videobench.mapWordBoxes(reading.wordBoxes, ...
        details(k).mapping, details(k).quad, size(frame));
    words = reading.correctedWords(keep);
    raw = reading.words(keep);
    % Use the same character policy as runTextPipeline, with no label lookup.
    words = regexprep(words, "[^A-Za-z0-9 \-.:/']", '');
    raw = regexprep(raw, "[^A-Za-z0-9 \-.:/']", '');
    valid = strlength(words) > 0;
    result.WordBoxes = [result.WordBoxes; boxes(valid,:)];
    result.Words = [result.Words; words(valid)];
    result.RawWords = [result.RawWords; raw(valid)];
end
end
