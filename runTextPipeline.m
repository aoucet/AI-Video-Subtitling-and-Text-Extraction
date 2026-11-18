function [boxes, texts, details] = runTextPipeline(frame, useGeometry, templates, labels)
% Detect and read text in an image. Returned boxes use input image pixels.
if nargin < 2, useGeometry = true; end
if nargin < 3, templates = []; labels = []; end
[boxes,angles,letters] = detectTextRegions(frame);
detectionBoxes = boxes;
texts = cell(1,size(boxes,1));
details = struct([]);
for k = 1:size(boxes,1)
    if useGeometry
        [crop,quad] = cropTextLine(frame,letters{k},angles(k),false);
    else
        crop = imcrop(frame,boxes(k,:));
        b = boxes(k,:);
        quad = [b(1:2);b(1)+b(3) b(2);b(1:2)+b(3:4);b(1) b(2)+b(4)];
    end
    [reading,prepared,score,mapping] = readTextLine(crop,useGeometry && abs(angles(k))>45);
    extended = false;
    if useGeometry
        [wide,wideQuad] = cropTextLine(frame,letters{k},angles(k),true);
        [alternative,image,otherScore,otherMapping] = readTextLine(wide,abs(angles(k))>45);
        % A short crop can read the start of a word with high confidence.
        % Keep a longer reading if it preserves that start and adds no words.
        firstText = upper(regexprep(char(reading.Text),'[^A-Za-z0-9]',''));
        longerText = upper(regexprep(char(alternative.Text),'[^A-Za-z0-9]',''));
        completesEnding = numel(firstText)>=3 && numel(longerText)>numel(firstText) ...
            && startsWith(longerText,firstText) && otherScore>=0.5 ...
            && numel(reading.Words)==numel(alternative.Words);
        if otherScore > score || completesEnding
            reading = alternative; prepared = image; score = otherScore;
            mapping = otherMapping; quad = wideQuad; extended = true;
        end
    end
    verification = struct([]);
    if ~isempty(templates)
        % Keep verification separate from recognition until replacements show
        % a measured benefit. Both GUI modes use the same text acceptance rule.
        options = struct('ocrResult',reading,'fixNccScore',Inf,'checkConfBelow',0.9,'returnWords',true);
        verification = recognize_text_region(prepared,templates,labels,options);
    end
    texts{k} = '';
    text = char(strtrim(regexprep(string(reading.Text),'\s+',' ')));
    text = strtrim(regexprep(text,"[^A-Za-z0-9 \-.:/']",''));
    characters = regexprep(text,'[^A-Za-z0-9]','');
    number = ~isempty(characters) && all(isstrprop(characters,'digit'));
    % Very short alphabetic fragments are often background. This also means
    % standalone one- or two-letter words are a limitation of this prototype.
    if score >= 0.5 && (numel(characters) >= 3 || number)
        texts{k} = text;
    end
    low = max([1 1],floor(min(quad,[],1)));
    high = min(size(frame,[2 1]),ceil(max(quad,[],1)));
    boxes(k,:) = [low,max(0,high-low)];
    value = struct('detectionBox',detectionBoxes(k,:),'angle',angles(k),'quad',quad, ...
        'extended',extended,'confidence',score,'mapping',mapping, ...
        'ocr',reading,'verification',verification);
    if nargout > 2, value.preparedImage = prepared; end
    if isempty(details),details=value;else,details(k)=value;end
end
[~,order] = sortrows([round(detectionBoxes(:,2)/20),detectionBoxes(:,1)]);
boxes = boxes(order,:); texts = texts(order); details = details(order);
end
