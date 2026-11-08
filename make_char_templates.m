function [templates, labels] = make_char_templates(tsize, fontName)
    if nargin < 1 || isempty(tsize),    tsize = [32 24]; end
    if nargin < 2,                      fontName = [];   end

    labels    = ['A':'Z', '0':'9'];
    templates = zeros(tsize(1), tsize(2), numel(labels));

    for k = 1:numel(labels)
        img = render_char_image(labels(k), 72, fontName);
        templates(:, :, k) = normalize_char_patch(img, tsize);
    end
end
