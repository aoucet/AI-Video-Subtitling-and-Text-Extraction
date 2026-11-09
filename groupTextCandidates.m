function groups = groupTextCandidates(boxes, sizes, meanGray)
% Group nearby character candidates into text lines.
if nargin < 3
    meanGray = zeros(size(sizes));
end
centers = boxes(:, 1:2) + boxes(:, 3:4) / 2;
proposals = {};
scores = [];

for seed = 1:numel(sizes)
    offsets = centers - centers(seed, :);
    distances = sqrt(sum(offsets.^2, 2));
    similar = sizes > 0.5 * sizes(seed) & sizes < 2 * sizes(seed) & ...
        abs(meanGray - meanGray(seed)) < 40;
    neighbors = find(similar & distances > 0.3 * sizes(seed) & ...
        distances < 3 * sizes(seed));
    [~, order] = sort(distances(neighbors));
    neighbors = neighbors(order(1:min(10, numel(order))));

    for neighbor = neighbors'
        direction = offsets(neighbor, :) / distances(neighbor);
        origin = centers(seed, :);
        for pass = 1:2
            normal = [-direction(2), direction(1)];
            along = (centers - origin) * direction';
            across = (centers - origin) * normal';
            heights = boxes(:, 3:4) * abs(normal');
            sameHeight = heights > 0.5 * heights(seed) & heights < 2 * heights(seed);
            members = find(sameHeight & abs(meanGray - meanGray(seed)) < 40 & ...
                abs(across) < 0.4 * heights(seed));
            [positions, order] = sort(along(members));
            members = members(order);
            gaps = diff(positions);
            limit = 4 * min(heights(members(1:end-1)), heights(members(2:end)));
            breaks = [0; find(gaps > limit); numel(members)];
            lineMembers = [];

            for part = 1:numel(breaks)-1
                segment = members(breaks(part)+1:breaks(part+1));
                if any(segment == seed)
                    lineMembers = segment;
                    break;
                end
            end
            if numel(lineMembers) < 3 || ...
                    (max(along(lineMembers)) - min(along(lineMembers))) < 0.5 * sizes(seed)
                lineMembers = [];
                break;
            end

            % Fit the line again using all the letters in this group.
            lineFit = [along(lineMembers), ones(numel(lineMembers), 1)] \ across(lineMembers);
            origin = origin + lineFit(2) * normal;
            direction = direction + lineFit(1) * normal;
            direction = direction / norm(direction);
        end

        if numel(lineMembers) >= 3 && ...
                median(diff(along(lineMembers))) > 0.3 * median(heights(lineMembers))
            proposals{end+1, 1} = lineMembers; %#ok<AGROW>
            % Give higher scores to groups that follow a straight line closely.
            residual = abs(across(lineMembers) - ...
                [along(lineMembers), ones(numel(lineMembers), 1)] * lineFit);
            scores(end+1, 1) = sum(max(0, 1 - residual ./ (0.4 * heights(lineMembers)))); %#ok<AGROW>
        end
    end
end

[~, order] = sort(scores, 'descend');
groups = proposals(order);
end
