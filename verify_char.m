function [bestLabel, bestScore, scores] = verify_char(patch, templates, labels, margin)
    if nargin < 4, margin = 2; end

    tsize = [size(templates, 1), size(templates, 2)];
    P = normalize_char_patch(patch, tsize);
    P = padarray(P, [margin margin], 1, 'both');

    scores = zeros(1, numel(labels));
    for k = 1:numel(labels)
        G = ncc_matrix(P, templates(:, :, k));
        scores(k) = max(G(:));
    end

    [bestScore, idx] = max(scores);
    bestLabel = labels(idx);
end
