clear; clc; close all;

I = rand(60, 80);
T = I(21:40, 31:50);
G = ncc_matrix(I, T);
C = normxcorr2(T, I);
Cvalid = C(size(T,1):end-size(T,1)+1, size(T,2):end-size(T,2)+1);
fprintf('Max |ours - normxcorr2| = %.2e  (should be ~1e-12)\n', max(abs(G(:) - Cvalid(:))));
[~, idx] = max(G(:)); [r, c] = ind2sub(size(G), idx);
fprintf('Peak at (row %d, col %d) -> expected (21, 31)\n\n', r, c);

dark   = 0.4 * I + 0.05;
bright = 0.6 * I + 0.40;
for frame = {I, dark, bright}
    f = frame{1};
    Gf = ncc_matrix(f, T);
    sad = sum(abs(f(21:40, 31:50) - T), 'all') / numel(T);
    fprintf('NCC peak = %.4f | mean abs diff at true location = %.4f\n', max(Gf(:)), sad);
end
fprintf('-> NCC stays 1.0, pixel difference grows when lighting changes.\n\n');

[templates, labels] = make_char_templates([32 24]);
figure('Name', 'Templates'); montage(reshape(templates, 32, 24, 1, []), 'Size', [4 9]);

correct = 0;
for k = 1:numel(labels)
    img = render_char_image(labels(k), 40);
    img = uint8(0.5 * double(img) + 60);
    img = imnoise(img, 'gaussian', 0, 0.002);
    lab = verify_char(img, templates, labels);
    correct = correct + (lab == labels(k));
    if lab ~= labels(k)
        fprintf('  %s was read as %s\n', labels(k), lab);
    end
end
fprintf('Self-test accuracy: %d / %d\n\n', correct, numel(labels));

sign = render_char_image('EXIT 24', 60);
sign = uint8(0.6 * double(sign) + 30);

bw = ~imbinarize(sign);
stats = regionprops(bw, 'BoundingBox', 'Area');
stats = stats([stats.Area] > 20);
boxes = reshape([stats.BoundingBox], 4, []).';
[~, order] = sort(boxes(:, 1));
boxes = boxes(order, :);

tic;
txt = '';
figure('Name', 'NCC-only'); imshow(sign); hold on;
for i = 1:size(boxes, 1)
    patch = imcrop(sign, boxes(i, :));
    [lab, s] = verify_char(patch, templates, labels);
    txt(end+1) = lab;
    rectangle('Position', boxes(i, :), 'EdgeColor', 'g', 'LineWidth', 2);
    text(boxes(i,1), boxes(i,2) - 8, sprintf('%s %.2f', lab, s), 'Color', 'r');
end
fprintf('NCC-only reading: %s   (expected EXIT24, spaces not detected)\n', txt);
fprintf('Time: %.3f s\n\n', toc);

if ~exist('ocr', 'file')
    fprintf('Skipping section 5: ocr not available (no Computer Vision Toolbox).\n');
else
    tic;
    R = recognize_text_region(sign, templates, labels);
    t = toc;
    fprintf('OCR text      : %s\n', R.text);
    fprintf('Corrected text: %s\n', R.correctedText);
    fprintf('Verified      : %d / %d chars (%.0f%%)\n', sum(R.verified), numel(R.verified), 100*R.verifiedRatio);
    disp(table(R.chars', R.ocrConf', R.nccLabel', R.nccScore', R.verified', ...
        'VariableNames', {'OCR', 'OCRconf', 'NCC', 'NCCscore', 'Verified'}));
    fprintf('Time: %.3f s\n', t);
end
