function checks = ncc(templates, labels)
% Check the NCC map, illumination invariance, and template matching.
image = rand(60, 80);
template = image(21:40, 31:50);
actual = ncc_matrix(image, template);
reference = normxcorr2(template, image);
[templateHeight, templateWidth] = size(template);
reference = reference(templateHeight:size(image, 1), templateWidth:size(image, 2));
difference = max(abs(actual - reference), [], 'all');
[peak, row, column] = peakLocation(actual);
tolerance = 1e-10;
rows = {
    "reference correlation map", difference < tolerance, ...
    sprintf('Maximum difference from normxcorr2: %.3g.', difference);
    "template peak location", row == 21 && column == 31 && abs(peak - 1) < tolerance, ...
    sprintf('Expected (21, 31) and score 1. Observed (%d, %d) and %.12g.', row, column, peak)
};

adjusted = {0.4 * image + 0.05, 0.6 * image + 0.40};
names = ["darker image"; "brighter image"];
for k = 1:numel(adjusted)
    [peak, row, column] = peakLocation(ncc_matrix(adjusted{k}, template));
    rows(end+1, :) = {names(k), row == 21 && column == 31 && abs(peak - 1) < tolerance, ...
        sprintf('Expected (21, 31) and score 1. Observed (%d, %d) and %.12g.', row, column, peak)}; %#ok<AGROW>
end

clean = repmat(' ', size(labels));
noisy = clean;
validScores = true;
for k = 1:numel(labels)
    clean(k) = verify_char(render_char_image(labels(k), 72), templates, labels);
    img = render_char_image(labels(k), 40);
    img = uint8(0.5 * double(img) + 60);
    img = imnoise(img, 'gaussian', 0, 0.002);
    [noisy(k), score] = verify_char(img, templates, labels);
    validScores = validScores && isfinite(score) && abs(score) <= 1+1e-8;
end
rows(end+1, :) = {"A-Z and 0-9 templates", isequal(clean, labels) && validScores, ...
    sprintf('Correct clean glyphs %d/%d; noisy glyphs %d/%d; bounded noisy scores %d.', ...
    nnz(clean == labels), numel(labels), nnz(noisy == labels), numel(labels), validScores)};

sign = render_char_image('EXIT 24', 60);
sign = uint8(0.6 * double(sign) + 30);
stats = regionprops(~imbinarize(sign), 'BoundingBox', 'Area');
stats = stats([stats.Area] > 20);
boxes = reshape([stats.BoundingBox], 4, []).';
boxes = sortrows(boxes, 1);
recognized = repmat(' ', 1, size(boxes, 1));
for k = 1:size(boxes, 1)
    recognized(k) = verify_char(imcrop(sign, boxes(k, :)), templates, labels);
end
rows(end+1, :) = {"NCC-only EXIT 24", strcmp(recognized, 'EXIT24'), ...
    sprintf('Expected EXIT24. Observed %s.', recognized)};

checks = cell2table(rows, 'VariableNames', {'Case', 'Passed', 'Detail'});
end

function [peak, row, column] = peakLocation(scores)
[peak, index] = max(scores(:));
[row, column] = ind2sub(size(scores), index);
end
