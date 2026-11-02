function R = recognize_text_region(roi, templates, labels, opts)
    if nargin < 4, opts = struct(); end
    nccThresh   = getOpt(opts, 'nccThresh',   0.60);
    fixOcrConf  = getOpt(opts, 'fixOcrConf',  0.50);
    fixNccScore = getOpt(opts, 'fixNccScore', 0.80);
    margin      = getOpt(opts, 'margin',      2);

    if size(roi, 3) == 3
        roi = rgb2gray(roi);
    end

    res = ocr(roi, 'CharacterSet', ['A':'Z', '0':'9'], 'LayoutAnalysis', 'line');

    chars = res.Characters(:)';
    boxes = res.CharacterBoundingBoxes;
    confs = res.CharacterConfidences(:)';

    keep  = ~isspace(chars) & all(boxes(:, 3:4) > 0, 2)' & ~any(isnan(boxes), 2)';
    chars = chars(keep);
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

    R.text          = strtrim(res.Text);
    R.correctedText = rebuildText(R.text, chars, corrected);
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
end

function v = getOpt(s, name, default)
    if isfield(s, name), v = s.(name); else, v = default; end
end

function out = rebuildText(txt, orig, fixed)
    out = txt;
    j = 1;
    for k = 1:numel(out)
        if j > numel(orig), break; end
        if ~isspace(out(k)) && out(k) == orig(j)
            out(k) = fixed(j);
            j = j + 1;
        end
    end
end
