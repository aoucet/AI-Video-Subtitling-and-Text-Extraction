function sequences = loadIcdar(root, split)
% Load word annotations for an original ICDAR 2013 video split.
arguments
    root (1,1) string
    split (1,1) string {mustBeMember(split, ["test", "train"])} = "test"
end

% Table IX of the ICDAR 2013 Robust Reading Competition paper.
if split == "train"
    splitIds = [7 8 13 19 26 36 37 40 41 42 51 52 54];
else
    splitIds = [1 5 6 11 17 20 23 24 32 35 39 44 48 49 53];
end
if ~isfolder(root)
    error('videobench:IcdarMissing', 'ICDAR 2013 files are missing from %s.', root);
end
entries = dir(fullfile(root, "**", "*"));
entries = entries(~[entries.isdir]);
paths = fullfile(string({entries.folder}), string({entries.name}));
[folders, stems, extensions] = fileparts(paths);
extensions = lower(extensions);
fileIds = parseVideoIds(stems);
imageIds = parseVideoIds(lastFolderNames(folders));
imageNumbers = str2double(stems);
isImage = ismember(extensions, [".jpg", ".jpeg", ".png", ".bmp"]) & ...
    ~cellfun('isempty', regexp(cellstr(stems), '^[0-9]+$', 'once'));
isVideo = ismember(extensions, [".mp4", ".avi", ".mov", ".m4v"]);
isAnnotation = extensions == ".xml";
missingLabels = splitIds(~ismember(splitIds, fileIds(isAnnotation)));
missingMedia = splitIds(~ismember(splitIds, [fileIds(isVideo), imageIds(isImage)]));
if ~isempty(missingLabels) || ~isempty(missingMedia)
    error('videobench:IcdarMissing', ...
        'ICDAR 2013 requires all %d original %s sequences. Missing XML IDs %s. Missing media IDs %s under %s.', ...
        numel(splitIds), split, mat2str(missingLabels), mat2str(missingMedia), root);
end

sequences = repmat(struct('Name', "", 'VideoPath', "", 'Frames', []), numel(splitIds), 1);
for k = 1:numel(splitIds)
    id = splitIds(k);
    label = paths(isAnnotation & fileIds == id);
    video = paths(isVideo & fileIds == id);
    if numel(label) ~= 1 || numel(video) > 1
        error('videobench:IcdarDuplicates', 'Ambiguous annotation or video files for ICDAR clip %d.', id);
    end
    frames = readLabels(label);
    if isempty(video)
        images = isImage & imageIds == id;
        frames = linkImages(frames, imageNumbers(images), paths(images), id);
    else
        sequences(k).VideoPath = video;
    end
    sequences(k).Name = "Video_" + id;
    sequences(k).Frames = frames;
end
end

function ids = parseVideoIds(names)
tokens = regexp(cellstr(names), '(?i)^(?:gt_)?video_(\d+)(?:_|$)', 'tokens', 'once');
ids = NaN(size(names));
for k = find(~cellfun('isempty', tokens))
    ids(k) = str2double(tokens{k}{1});
end
end

function names = lastFolderNames(folders)
[~, stem, suffix] = fileparts(folders);
names = stem + suffix;
end

function frames = readLabels(path)
doc = xmlread(path, 'AllowDoctype', false);
root = doc.getDocumentElement();
if ~strcmpi(char(root.getTagName()), 'frames')
    error('videobench:IcdarLabels', 'Expected a frames root element in %s.', path);
end
children = root.getChildNodes();
emptyFrame = struct('Index', NaN, 'ImagePath', "", 'Boxes', zeros(0, 4), ...
    'Texts', strings(0, 1), 'IgnoredBoxes', zeros(0, 4), ...
    'TrackIDs', strings(0, 1), 'Polygons', zeros(0, 8), 'IgnoredPolygons', zeros(0, 8));
frames = repmat(emptyFrame, children.getLength(), 1);
count = 0;
for k = 0:children.getLength()-1
    node = children.item(k);
    if ~strcmpi(char(node.getNodeName()), 'frame'), continue; end
    index = str2double(attribute(node, 'ID'));
    if ~isfinite(index) || index < 1 || index ~= fix(index)
        error('videobench:IcdarLabels', 'Invalid 1-based frame ID in %s.', path);
    end
    count = count + 1;
    frames(count).Index = index;
    frames(count) = readFrameObjects(node, frames(count), path);
end
frames = frames(1:count);
if isempty(frames) || numel(unique([frames.Index])) ~= count
    error('videobench:IcdarLabels', 'Missing or duplicate frame IDs in %s.', path);
end
[~, order] = sort([frames.Index]);
frames = frames(order);
end

function frame = readFrameObjects(node, frame, path)
children = node.getChildNodes();
for k = 0:children.getLength()-1
    object = children.item(k);
    if ~strcmpi(char(object.getNodeName()), 'object'), continue; end
    transcript = strtrim(attribute(object, 'Transcription'));
    ignoredText = ["", "###", "##DONT#CARE##"];
    ignore = strcmpi(strtrim(attribute(object, 'Quality')), "low") || ...
        any(strcmpi(transcript, ignoredText));
    corners = readCorners(object);
    if ~isequal(size(corners), [4 2]) || any(~isfinite(corners), 'all')
        error('videobench:IcdarLabels', 'Expected four valid points in %s at frame %d.', path, frame.Index);
    end
    % The official XML can list opposite corners consecutively.
    corners = orderCorners(corners + 1);
    topLeft = min(corners, [], 1);
    dimensions = max(corners, [], 1) - topLeft;
    if polyarea(corners(:,1), corners(:,2)) <= 0
        if ignore, continue; end
        error('videobench:IcdarLabels', 'Empty word polygon in %s at frame %d.', path, frame.Index);
    end
    bbox = [topLeft, dimensions];
    polygon = reshape(corners.', 1, []);
    if ignore
        frame.IgnoredBoxes(end+1, :) = bbox;
        frame.IgnoredPolygons(end+1, :) = polygon;
    else
        frame.Boxes(end+1, :) = bbox;
        frame.Polygons(end+1, :) = polygon;
        frame.Texts(end+1, 1) = transcript;
        frame.TrackIDs(end+1, 1) = attribute(object, 'ID');
    end
end
end

function corners = orderCorners(corners)
offset = corners - mean(corners, 1);
[~, order] = sort(atan2(offset(:, 2), offset(:, 1)));
corners = corners(order, :);
end

function corners = readCorners(object)
points = object.getChildNodes();
corners = zeros(0, 2);
for k = 0:points.getLength()-1
    node = points.item(k);
    if strcmpi(char(node.getNodeName()), 'point')
        corners(end+1, :) = [str2double(attribute(node, 'x')), str2double(attribute(node, 'y'))]; %#ok<AGROW>
    end
end
end

function value = attribute(node, name)
value = string(char(node.getAttribute(name)));
if value ~= "" || node.hasAttribute(name), return; end
attrs = node.getAttributes();
for k = 0:attrs.getLength()-1
    item = attrs.item(k);
    if strcmpi(char(item.getNodeName()), name)
        value = string(char(item.getNodeValue()));
        return;
    end
end
end

function frames = linkImages(frames, numbers, paths, id)
if numel(unique(numbers)) ~= numel(numbers)
    error('videobench:IcdarDuplicates', 'Duplicate image frame numbers for ICDAR clip %d.', id);
end
[exists, position] = ismember([frames.Index], numbers);
if any(~exists)
    missing = [frames(~exists).Index];
    error('videobench:IcdarMissing', 'Missing image for ICDAR clip %d, frame %d.', id, missing(1));
end
for k = 1:numel(frames)
    frames(k).ImagePath = paths(position(k));
end
end
