function [result, prepared, confidence, mapping] = readTextLine(crop, tryHalfTurn)
% Read a grayscale and a thresholded version of the same text crop.
if nargin < 2, tryHalfTurn = false; end
confidence = -1;
for halfTurn = 0:double(tryHalfTurn)
    g = imadjust(im2uint8(im2gray(crop)));
    if halfTurn, g = rot90(g,2); end
    border = [g(1,:) g(end,:) g(:,1)' g(:,end)'];
    if median(border) < 128, g = 255-g; end
    originalSize = size(g);
    g = imresize(g,min(3,48/size(g,1)),'bicubic');
    scale = size(g) ./ originalSize;
    bw = imbinarize(g,'adaptive','ForegroundPolarity','dark','Sensitivity',0.45);
    border = [bw(1,:) bw(end,:) bw(:,1)' bw(:,end)'];
    if median(border) < 0.5, bw = ~bw; end
    images = {g,im2uint8(bw)};
    for k = 1:2
        image = padarray(images{k},[10 10],255);
        reading = ocr(image,'LayoutAnalysis','line');
        counts = cellfun(@(word) numel(regexprep(word,'[^A-Za-z0-9]','')),reading.Words);
        valid = isfinite(reading.WordConfidences);
        score = sum(counts(valid).*reading.WordConfidences(valid)) / max(1,sum(counts(valid)));
        if score > confidence
            result = reading;
            prepared = image;
            confidence = score;
            mapping = struct('halfTurn',logical(halfTurn),'resizeScale',scale, ...
                'cropSize',originalSize,'binary',k==2,'border',10);
        end
    end
end
end
