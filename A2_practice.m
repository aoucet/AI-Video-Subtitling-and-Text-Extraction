clear;
close all;
clc;

% Images to test
folder = fullfile(fileparts(mfilename('fullpath')), 'dataset', '02_Labeled_Screenshots');
files = {'V03_F01.jpg', 'V03_F02.jpg', 'V03_F03.jpg'};

for i = 1:length(files)

    frame = imread(fullfile(folder, files{i}));

    boxes = detectTextRegions(frame);

    result = insertShape(frame, 'Rectangle', boxes, ...
        'ShapeColor', 'green', 'LineWidth', 3);

    figure;
    imshow(result);
    title(files{i});

    fprintf('%s: %d detected regions\n', ...
        files{i}, size(boxes,1));

end