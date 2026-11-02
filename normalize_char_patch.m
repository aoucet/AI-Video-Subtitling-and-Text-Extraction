function P = normalize_char_patch(patch, tsize)
    if size(patch, 3) == 3
        patch = rgb2gray(patch);
    end
    g = im2double(patch);

    ink = imbinarize(g);
    if mean(ink(:)) > 0.5
        ink = ~ink;
    end

    P = ones(tsize);
    if ~any(ink(:))
        return;
    end

    if mean(g(ink)) > mean(g(~ink))
        g = 1 - g;
    end

    [r, c] = find(ink);
    g = g(min(r):max(r), min(c):max(c));

    scale   = min(tsize ./ size(g));
    newSize = min(max(1, round(size(g) * scale)), tsize);
    g = imresize(g, newSize);
    g = min(max(g, 0), 1);

    r0 = floor((tsize(1) - newSize(1)) / 2) + 1;
    c0 = floor((tsize(2) - newSize(2)) / 2) + 1;
    P(r0:r0+newSize(1)-1, c0:c0+newSize(2)-1) = g;
end
