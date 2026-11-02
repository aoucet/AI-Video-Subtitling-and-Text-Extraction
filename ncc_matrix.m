function G = ncc_matrix(I, T)
    I = double(I);
    T = double(T);

    [h, w] = size(T);
    [H, W] = size(I);
    assert(H >= h && W >= w, 'Template must not be larger than the image.');

    n    = h * w;
    Tz   = T - mean(T(:));
    Tden = sqrt(sum(Tz(:).^2));

    G = zeros(H - h + 1, W - w + 1);

    for v = 1:size(G, 1)
        for u = 1:size(G, 2)
            win = I(v:v+h-1, u:u+w-1);
            Wz  = win - sum(win(:)) / n;
            den = sqrt(sum(Wz(:).^2)) * Tden;
            if den < eps
                G(v, u) = 0;
            else
                G(v, u) = sum(Wz(:) .* Tz(:)) / den;
            end
        end
    end
end
