function sequences = loadYvt(root)
%LOADYVT Read the official YVT test split and its original VATIC frames.
arguments
    root (1, 1) string
end

if ~isfolder(fullfile(root, "annotations", "test"))
    root = fullfile(root, "YVT");
end
annotationRoot = fullfile(root, "annotations", "test");
frameRoot = fullfile(root, "frames", "test");
videoRoot = fullfile(root, "videos", "test");
assert(isfolder(annotationRoot) && isfolder(frameRoot) && isfolder(videoRoot), ...
    "videobench:MissingYvt", ...
    "Expected extracted YVT annotations/test, frames/test and videos/test under %s.", root);

videos = dir(fullfile(videoRoot, "*.mp4"));
assert(numel(videos) == 15, "videobench:IncompleteYvt", ...
    "The official YVT test split contains 15 videos, but %d were found.", numel(videos));
[~, order] = sort(lower(string({videos.name})));
videos = videos(order);

frameTemplate = struct("Index", 0, "ImagePath", "", ...
    "Boxes", zeros(0, 4), "Texts", strings(0, 1), ...
    "IgnoredBoxes", zeros(0, 4), "TrackIDs", strings(0, 1));
sequenceTemplate = struct("Name", "", "VideoPath", "", "Frames", ...
    repmat(frameTemplate, 0, 1));
sequences = repmat(sequenceTemplate, numel(videos), 1);
for k = 1:numel(videos)
    clip = string(videos(k).name);
    annotationPath = fullfile(annotationRoot, clip + ".txt");
    [sourceFrames, imagePaths] = readImagePaths(fullfile(frameRoot, clip));
    % Annotations use the 1280-by-720 source grid. The packaged JPGs are smaller.
    % Use the exact VATIC frames since some MP4s have fewer samples.
    imageInfo = imfinfo(imagePaths(1));
    scale = [imageInfo.Width, imageInfo.Height] ./ [1280, 720];
    [frameNumbers, boxes, words, trackIDs, scored, ignored] = readAnnotations(annotationPath, scale);
    assert(all(ismember(frameNumbers, sourceFrames)), ...
        "videobench:MissingYvtFrames", "Missing annotated YVT frames for %s.", clip);

    frames = repmat(frameTemplate, numel(sourceFrames), 1);
    for j = 1:numel(sourceFrames)
        % VATIC stores zero-based frame IDs. The original JPGs avoid timestamp rounding.
        selected = frameNumbers == sourceFrames(j);
        gt = selected & scored;
        frames(j).Index = sourceFrames(j) + 1;
        frames(j).ImagePath = imagePaths(j);
        frames(j).Boxes = boxes(gt, :);
        frames(j).Texts = words(gt);
        frames(j).IgnoredBoxes = boxes(selected & ignored, :);
        frames(j).TrackIDs = trackIDs(gt);
    end
    sequences(k).Name = string(erase(clip, ".mp4"));
    sequences(k).Frames = frames;
end
end

function [frameNumbers, boxes, words, trackIDs, scored, ignored] = readAnnotations(path, scale)
assert(isfile(path), "videobench:MissingYvtAnnotation", "Missing YVT annotation: %s.", path);
lines = strip(readlines(path));
lines(lines == "") = [];

% VATIC columns are track, xmin, ymin, xmax, ymax, frame, lost, occluded, generated, text.
integer = "(-?[0-9]+)\s+";
pattern = "^" + join(repmat(integer, 1, 9), "") + '(".*")$';
tokens = regexp(cellstr(lines), char(pattern), "tokens", "once");
assert(~isempty(tokens) && all(~cellfun(@isempty, tokens)), ...
    "videobench:MalformedYvtAnnotation", "Malformed or empty YVT annotation: %s.", path);
tokens = vertcat(tokens{:});
values = str2double(string(tokens(:, 1:9)));
assert(all(values(:, 1) >= 0 & values(:, 6) >= 0) && ...
    all(ismember(values(:, 7:9), [0 1]), "all"), ...
    "videobench:MalformedYvtAnnotation", "Invalid YVT metadata: %s.", path);

trackIDs = string(values(:, 1));
frameNumbers = values(:, 6);
words = strip(regexprep(string(tokens(:, 10)), '^"+|"+$', ""));
xy = values(:, 2:3);
boxes = [xy .* scale + 1, (values(:, 4:5) - xy) .* scale];
valid = all(boxes(:, 3:4) > 0, 2);
visible = values(:, 7) == 0 & valid;
unreadable = values(:, 8) ~= 0 | words == "" | strcmpi(words, "Text");
scored = visible & ~unreadable;
ignored = visible & unreadable;
end

function [frameNumbers, imagePaths] = readImagePaths(folder)
images = dir(fullfile(folder, "0", "**", "*.jpg"));
assert(~isempty(images), "videobench:MissingYvtFrames", "No YVT JPEG frames in %s.", folder);

frameNumbers = str2double(erase(string({images.name}).', ".jpg"));
[frameNumbers, order] = sort(frameNumbers);
assert(isequal(frameNumbers, (0:numel(images) - 1).'), ...
    "videobench:MalformedYvtFrames", "YVT frame filenames are incomplete or duplicated in %s.", folder);
images = images(order);
imagePaths = fullfile(string({images.folder}).', string({images.name}).');
end
