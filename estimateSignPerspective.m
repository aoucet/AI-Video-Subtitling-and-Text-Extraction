function [geometry, diagnostics] = estimateSignPerspective(frame, textBox, lineAngle, options)
%ESTIMATESIGNPERSPECTIVE Seek a supported planar sign around detected text.
% [g,d] = estimateSignPerspective(frame,[x y width height],lineAngle,opts)
% lineAngle is the visually CCW text-axis angle, as returned by
% estimateROILineDirection (image y increases downward). No pixels are warped.
% g.transform maps ORIGINAL frame XY to the full rectified sign. g.corners
% are TL,TR,BR,BL relative to the automatic axis (or supplied physical TL
% anchor). Automatic geometry does NOT establish semantic upright orientation.
%
% Automatic mode uses Canny edges and Hough line SEGMENTS in a context crop.
% Proposals are refit by robust orthogonal regression to nearby real Canny
% pixels within their observed extent before intersecting the boundary lines.
% Four independently supported enclosing boundary sides must be visible.
% A text box, MSER cloud, or rotated bounding rectangle is never substituted
% for a sign boundary. Missing/clipped/ambiguous geometry returns accepted=false.
% Even a strong quadrilateral is geometric evidence, not proof of a sign or
% of physical planarity. A single homography cannot flatten curved surfaces.
%
% opts.Corners: optional trusted 4-by-2 ORIGINAL XY vertices, starting at
% the physical TL corner and following the perimeter: TL,TR,BR,BL (or the
% reverse winding TL,BL,BR,TR). The first physical-width edge is therefore
% defined even if lineAngle is unknown; supplied corners are not reoriented
% to an uncertain text-axis prior. Bypasses automatic edge detection, but
% geometry, containment, frame bounds, and transformation checks still apply.
% opts.TextSupport: optional N-by-2 ORIGINAL XY foreground-text points
% (12..25000). Prefer accepted detector/angle-estimator foreground support.
% Containment, area gates, and text suppression then use actual foreground,
% avoiding the inflated empty corners of a rotated axis-aligned word box.
% Without TextSupport the box-based checks are deliberately conservative and
% may reject a valid narrow tilted sign. Points must belong to this text ROI.
% opts.AspectRatio: optional known target W/H. Without this, the target aspect
% is estimated from observed side lengths; it is NOT metrically recovered.
% With lineAngle=NaN, automatic search uses a documented horizontal-axis
% prior limited by MaxLineAngleDeviation, not a measured text direction.
% ContextScale grows each side by (ContextScale-1)*longestTextSide/2;
% this isotropic context preserves sign boundaries around slender word ROIs.
% See defaultOptions for all strict, case-sensitive option names.
% Requires Image Processing Toolbox; compatible with MATLAB R2026a.
% References: MathWorks hough/houghlines/fitgeotform2d documentation.

if nargin < 4, options = struct(); end
o = parseOptions(options);
geometry = emptyGeometry();
diagnostics = emptyDiagnostics();
validateattributes(frame,{'numeric','logical'}, ...
    {'real','finite','nonsparse','nonempty'},mfilename,'frame');
if ndims(frame)>3 || ~ismember(size(frame,3),[1 3])
    error('estimateSignPerspective:Image','frame must be grayscale or RGB.');
end
validateattributes(textBox,{'numeric'}, ...
    {'real','finite','nonsparse','vector','numel',4},mfilename,'textBox');
textBox = double(textBox(:).');
if any(textBox(3:4)<=0)
    error('estimateSignPerspective:Box','textBox width and height must be positive.');
end
validateattributes(lineAngle,{'numeric'}, ...
    {'real','scalar','nonsparse'},mfilename,'lineAngle');
if isinf(lineAngle)
    error('estimateSignPerspective:Angle','lineAngle must be finite or NaN.');
end
gray = im2single(im2gray(frame));
if any(gray(:)<0 | gray(:)>1)
    error('estimateSignPerspective:Range','Floating-point images must be in [0,1].');
end
[fh,fw] = size(gray);
sourceSupport=double(o.TextSupport);
if isempty(sourceSupport), sourceSupport=zeros(0,2); end
if ~isempty(sourceSupport)
    if any(sourceSupport(:,1)<0.5 | sourceSupport(:,1)>fw+0.5 | ...
            sourceSupport(:,2)<0.5 | sourceSupport(:,2)>fh+0.5)
        error('estimateSignPerspective:TextSupport','TextSupport points must be within the original frame.');
    end
    supportPad=max(2,0.25*min(textBox(3:4)));
    if any(sourceSupport(:,1)<textBox(1)-supportPad | ...
            sourceSupport(:,1)>textBox(1)+textBox(3)+supportPad | ...
            sourceSupport(:,2)<textBox(2)-supportPad | ...
            sourceSupport(:,2)>textBox(2)+textBox(4)+supportPad)
        error('estimateSignPerspective:TextSupport','TextSupport must belong to the supplied text ROI.');
    end
    diagnostics.textSupportSource='provided-foreground-original-XY';
    diagnostics.textSupportCount=size(sourceSupport,1);
else
    diagnostics.textSupportSource='axis-aligned-box-conservative-fallback';
end
if textBox(1)+textBox(3)<1 || textBox(2)+textBox(4)<1 || ...
        textBox(1)>fw || textBox(2)>fh
    diagnostics.reason = 'Text box does not overlap the frame.';
    return;
end
if isnan(lineAngle)
    u = [1 0];
    diagnostics.hasAngleGuide = false;
    diagnostics.guideSource = 'horizontal-axis-prior-not-measured';
else
    a = mod(double(lineAngle)+90,180)-90;
    u = [cosd(a) -sind(a)];
    diagnostics.hasAngleGuide = true;
    diagnostics.guideSource = 'measured-text-axis';
end
n = [-u(2) u(1)];

if ~isempty(o.Corners)
    diagnostics.method = 'supplied-planar-corners';
    q = double(o.Corners);
    [valid,reason] = validQuad(q,[fh fw],0,o);
    if ~valid, diagnostics.reason=reason; return; end
    q = orientSuppliedQuad(q);
    diagnostics.candidateCorners=q;
    diagnostics.textCoverage = textCoverage(q,textBox,sourceSupport);
    if diagnostics.textCoverage < o.MinTextCoverage
        diagnostics.reason = 'Supplied sign corners do not enclose enough of the text box.';
        return;
    end
    [geometry,fitInfo] = fitGeometry(q,o);
    diagnostics = recordFit(diagnostics,fitInfo);
    if geometry.accepted
        diagnostics.accepted = true;
        diagnostics.reason = 'Validated supplied corners; pixel edge support was not required.';
    end
    return;
end

diagnostics.method = 'context-canny-hough-boundary-consensus';
cx = textBox(1)+textBox(3)/2;
cy = textBox(2)+textBox(4)/2;
contextPad=(o.ContextScale-1)*max(textBox(3:4))/2;
x1 = max(1,floor(textBox(1)-contextPad));
x2 = min(fw,ceil(textBox(1)+textBox(3)+contextPad));
y1 = max(1,floor(textBox(2)-contextPad));
y2 = min(fh,ceil(textBox(2)+textBox(4)+contextPad));
if x2-x1<20 || y2-y1<20
    diagnostics.reason = 'Insufficient context for four sign boundaries.'; return;
end
crop = gray(y1:y2,x1:x2);
analysisScale = min(1,o.MaxAnalysisDimension/max(size(crop)));
if analysisScale<1
    crop=imresize(crop,max(1,ceil(size(crop)*analysisScale)),'bilinear');
end
% Explicit centre-coordinate mapping avoids half-pixel resize offsets.
scaleXY = [size(crop,2)/(x2-x1+1),size(crop,1)/(y2-y1+1)];
% Explicit target dimensions can give slightly different x/y scale factors.
% Transform BOTH original guide directions into the analysis image.
analysisU=u.*scaleXY; analysisU=analysisU/norm(analysisU);
analysisN=n.*scaleXY; analysisN=analysisN/norm(analysisN);
origin = [x1 y1];
toLocal = @(p) (p-origin+0.5).*scaleXY+0.5;
toFrame = @(p) (p-0.5)./scaleXY+origin-0.5;
boxLocal = [toLocal(textBox(1:2)),textBox(3:4).*scaleXY];
supportLocal=toLocal(sourceSupport);
centre = toLocal([cx cy]);
[textSpans,textArea]=supportGeometry(supportLocal,analysisU,analysisN,boxLocal);
diagnostics.contextBox = [x1 y1 x2-x1+1 y2-y1+1];
diagnostics.analysisSizeHW = size(crop);
diagnostics.analysisScaleXY = scaleXY;
diagnostics.analysisGuideAxes=[analysisU;analysisN];
if max(crop(:))-min(crop(:))<0.025
    diagnostics.reason = 'Context has insufficient contrast.'; return;
end
edges = edge(crop,'Canny',[],1.2);
if nnz(edges)<40
    diagnostics.reason = 'Too few boundary edge pixels.'; return;
end
% Suppress text only while proposing lines. Verification uses all real edges.
proposalEdges = edges;
if ~isempty(supportLocal)
    points=round(supportLocal);
    inside=points(:,1)>=1 & points(:,1)<=size(crop,2) & ...
        points(:,2)>=1 & points(:,2)<=size(crop,1);
    points=points(inside,:);
    textMask=false(size(crop));
    textMask(sub2ind(size(crop),points(:,2),points(:,1)))=true;
    textMask=imdilate(textMask,strel('disk',2,0));
    proposalEdges(textMask)=false;
else
    tx1=max(1,ceil(boxLocal(1))); tx2=min(size(crop,2),floor(boxLocal(1)+boxLocal(3)));
    ty1=max(1,ceil(boxLocal(2))); ty2=min(size(crop,1),floor(boxLocal(2)+boxLocal(4)));
    if tx1<=tx2 && ty1<=ty2, proposalEdges(ty1:ty2,tx1:tx2)=false; end
end
[H,T,R] = hough(proposalEdges,'Theta',-90:0.5:89.5);
if max(H(:))<10
    diagnostics.reason = 'No sufficiently long boundary line evidence.'; return;
end
% A long thin word can create a large isotropic context. Its sign's short
% sides must not be discarded by a context-only minimum-length threshold.
minimumProposalLength=max(o.MinSideLength,min(0.10*min(size(crop)), ...
    0.60*max(1,min(textSpans))));
% Likewise, a peak threshold proportional only to the longest boundary
% would suppress the short sides of a high-aspect-ratio rectangular sign.
peakThreshold=max(10,ceil(min(0.20*max(H(:)),0.80*minimumProposalLength)));
peaks = houghpeaks(H,o.MaxHoughPeaks,'Threshold',peakThreshold);
proposals = houghlines(proposalEdges,T,R,peaks, ...
    'FillGap',max(3,round(0.025*min(size(crop)))), ...
    'MinLength',ceil(minimumProposalLength));
diagnostics.proposedLineSegmentCount=numel(proposals);
segments=refineBoundarySegments(proposals,edges,analysisU,analysisN,o);
diagnostics.lineSegmentCount = numel(segments);
diagnostics.lineRefinement='nearby-real-canny-robust-orthogonal-fit';
if isempty(segments)
    diagnostics.reason='No boundary proposal survived fitting to real Canny edge pixels.'; return;
end
groups = boundaryGroups(segments,centre,analysisU,analysisN,textSpans,o);
diagnostics.sideCandidateCounts = cellfun(@numel,groups);
if any(cellfun(@isempty,groups))
    diagnostics.reason = 'Four enclosing boundary directions were not supported.'; return;
end
D = bwdist(edges);
candidates = repmat(struct('q',[],'score',0,'support',[], ...
    'endpointCoverage',[],'textCoverage',0),0,1);
trials = 0;
% groups are top,right,bottom,left in the plane-axis coordinate system.
for it=1:numel(groups{1})
 for ir=1:numel(groups{2})
  for ib=1:numel(groups{3})
   for il=1:numel(groups{4})
    trials=trials+1;
    if trials>o.MaxQuadTrials, break; end
    ls={groups{1}(it),groups{2}(ir),groups{3}(ib),groups{4}(il)};
    q=[intersectLines(ls{4}.abc,ls{1}.abc);intersectLines(ls{1}.abc,ls{2}.abc); ...
       intersectLines(ls{2}.abc,ls{3}.abc);intersectLines(ls{3}.abc,ls{4}.abc)];
    [ok,~]=validQuad(q,size(crop),o.BoundaryMargin,o);
    if ~ok, continue; end
    area=polyarea(q(:,1),q(:,2));
    if area<o.MinAreaToTextRatio*textArea || ...
            area>o.MaxAreaToTextRatio*textArea, continue; end
    coverage=textCoverage(q,boxLocal,supportLocal);
    if coverage<o.MinTextCoverage, continue; end
    support=zeros(1,4); endpointCoverage=zeros(1,4); good=true;
    for side=1:4
        next=mod(side,4)+1;
        [support(side),endpointCoverage(side),sideOK]= ...
            edgeEvidence(q(side,:),q(next,:),ls{side},D,o);
        if ~sideOK, good=false; break; end
    end
    if ~good, continue; end
    c=struct('q',q,'score',mean(support)+0.12*mean(endpointCoverage), ...
        'support',support,'endpointCoverage',endpointCoverage,'textCoverage',coverage);
    candidates(end+1,1)=c; %#ok<AGROW>
   end
   if trials>o.MaxQuadTrials, break; end
  end
  if trials>o.MaxQuadTrials, break; end
 end
 if trials>o.MaxQuadTrials, break; end
end
diagnostics.quadTrials = min(trials,o.MaxQuadTrials);
diagnostics.supportedQuadCount = numel(candidates);
if isempty(candidates)
    diagnostics.reason = 'No convex containing quadrilateral had four continuous supported sides.';
    return;
end
[~,rank]=sort([candidates.score],'descend');
best=candidates(rank(1));
diagnostics.edgeSupport=best.support;
diagnostics.endpointCoverage=best.endpointCoverage;
diagnostics.textCoverage=best.textCoverage;
diagnostics.bestScore=best.score;
diagnostics.candidateCorners=toFrame(best.q);
% Near-identical inner/outer edge responses count as one geometric solution.
for k=2:numel(rank)
    rival=candidates(rank(k));
    if quadDifference(best.q,rival.q)>o.DuplicateQuadTolerance
        diagnostics.runnerUpScore=rival.score;
        if rival.score>=o.AmbiguityRatio*best.score
            diagnostics.reason='Competitive supported sign quadrilaterals are geometrically ambiguous.';
            return;
        end
        break;
    end
end
if trials>o.MaxQuadTrials
    diagnostics.reason='Boundary search reached its candidate limit; uniqueness was not established.';
    return;
end
q=toFrame(best.q);
[ok,reason]=validQuad(q,[fh fw],o.BoundaryMargin./max(scaleXY),o);
if ~ok, diagnostics.reason=reason; return; end
[geometry,fitInfo]=fitGeometry(q,o);
diagnostics=recordFit(diagnostics,fitInfo);
if geometry.accepted
    diagnostics.accepted=true;
    diagnostics.reason='Four visible boundary sides support an unambiguous planar-sign candidate.';
end
end

function segments=refineBoundarySegments(proposals,edges,u,n,o)
% Enumerate a narrow integer-pixel strip, rather than scanning the whole
% image for every proposal. At most 9*longestImageSide candidate pixels are
% inspected per segment; at most 2500 deterministic samples enter each SVD.
segments=repmat(struct('point1',[],'point2',[],'abc',[], ...
    'supportCount',0,'medianResidual',NaN),0,1);
for k=1:numel(proposals)
    a=double(proposals(k).point1); b=double(proposals(k).point2);
    direction=b-a; observedLength=norm(direction);
    if observedLength<o.MinSideLength, continue; end
    direction=direction/observedLength;
    if acosd(min(1,abs(dot(direction,u))))>o.MaxLineAngleDeviation && ...
            acosd(min(1,abs(dot(direction,n))))>o.MaxLineAngleDeviation
        continue;
    end
    normal=[-direction(2) direction(1)];
    if abs(direction(1))>=abs(direction(2))
        x=(ceil(min(a(1),b(1))-0.5):floor(max(a(1),b(1))+0.5)).';
        y=a(2)+(x-a(1))*direction(2)/direction(1);
        ys=floor(y)+(-4:4); xs=repmat(x,1,9);
    else
        y=(ceil(min(a(2),b(2))-0.5):floor(max(a(2),b(2))+0.5)).';
        x=a(1)+(y-a(2))*direction(1)/direction(2);
        xs=floor(x)+(-4:4); ys=repmat(y,1,9);
    end
    p=[xs(:) ys(:)];
    inside=p(:,1)>=1 & p(:,1)<=size(edges,2) & p(:,2)>=1 & p(:,2)<=size(edges,1);
    p=p(inside,:);
    along=(p-a)*direction.'; across=abs((p-a)*normal.');
    p=p(along>=-0.5 & along<=observedLength+0.5 & across<=2.25,:);
    p=p(edges(sub2ind(size(edges),p(:,2),p(:,1))),:);
    if size(p,1)<12, continue; end
    [~,order]=sort((p-a)*direction.');
    if numel(order)>2500, order=order(round(linspace(1,numel(order),2500))); end
    p=p(order,:);
    originalDirection=direction;
    valid=true;
    for iteration=1:4
        centre=mean(p,1);
        [~,S,V]=svd(p-centre,0);
        if S(1,1)<1e-6 || S(1,1)<4*max(S(2,2),eps)
            valid=false; break;
        end
        direction=V(:,1).';
        if dot(direction,originalDirection)<0, direction=-direction; end
        if acosd(min(1,dot(direction,originalDirection)))>3
            valid=false; break;
        end
        normal=[-direction(2) direction(1)];
        residual=abs((p-centre)*normal.');
        middle=median(residual);
        threshold=max(0.65,min(1.8,middle+2.5*1.4826*median(abs(residual-middle))));
        keep=residual<=threshold;
        if nnz(keep)<12, valid=false; break; end
        if all(keep), break; end
        p=p(keep,:);
    end
    if ~valid, continue; end
    % Refit once after trimming; endpoints are projections of OBSERVED
    % support extrema, not intersections or invented line extensions.
    centre=mean(p,1); [~,S,V]=svd(p-centre,0);
    direction=V(:,1).';
    if dot(direction,originalDirection)<0, direction=-direction; end
    normal=[-direction(2) direction(1)];
    residual=abs((p-centre)*normal.');
    extent=(p-centre)*direction.';
    supportedLength=max(extent)-min(extent);
    if S(1,1)<4*max(S(2,2),eps) || ...
            acosd(min(1,dot(direction,originalDirection)))>3 || ...
            median(residual)>1.1 || supportedLength<max(o.MinSideLength,0.60*observedLength)
        continue;
    end
    first=centre+min(extent)*direction; last=centre+max(extent)*direction;
    entry=struct('point1',first,'point2',last,'abc',[normal -dot(normal,centre)], ...
        'supportCount',size(p,1),'medianResidual',median(residual));
    segments(end+1,1)=entry; %#ok<AGROW>
end
end

function groups=boundaryGroups(segments,centre,u,n,textSpans,o)
groups={[],[],[],[]};
spanU=textSpans(1); spanN=textSpans(2);
for k=1:numel(segments)
    p=double([segments(k).point1;segments(k).point2]);
    e=p(2,:)-p(1,:); len=norm(e);
    if len<o.MinSideLength, continue; end
    e=e/len;
    du=acosd(min(1,abs(dot(e,u))));
    dn=acosd(min(1,abs(dot(e,n))));
    if du<=o.MaxLineAngleDeviation
        axisNormal=n; minDistance=0.30*spanN; pair=[1 3];
    elseif dn<=o.MaxLineAngleDeviation
        axisNormal=u; minDistance=0.30*spanU; pair=[4 2];
    else, continue;
    end
    abc=segments(k).abc;
    if dot(abc(1:2),axisNormal)<0, abc=-abc; end
    normal=abc(1:2);
    displacement=-(dot(normal,centre)+abc(3))/dot(normal,axisNormal);
    if abs(displacement)<minDistance, continue; end
    side=pair(1+(displacement>0));
    entry=struct('abc',abc,'points',p,'length',len,'displacement',displacement);
    if isempty(groups{side}), groups{side}=entry;
    else, groups{side}(end+1)=entry;
    end
end
for side=1:4
    if isempty(groups{side}), continue; end
    [~,idx]=sort([groups{side}.length],'descend');
    keep=[];
    for k=idx
        duplicate=false;
        for j=keep
            a=groups{side}(k).abc; b=groups{side}(j).abc;
            if acosd(min(1,abs(dot(a(1:2),b(1:2)))))<1.5 && ...
                    abs(groups{side}(k).displacement-groups{side}(j).displacement)<2
                duplicate=true; break;
            end
        end
        if ~duplicate, keep(end+1)=k; end %#ok<AGROW>
        if numel(keep)>=o.MaxLinesPerSide, break; end
    end
    groups{side}=groups{side}(keep);
end
end

function p=intersectLines(a,b)
v=cross(a,b);
if abs(v(3))<0.12, p=[NaN NaN]; else, p=v(1:2)/v(3); end
end

function [fraction,segmentCoverage,ok]=edgeEvidence(a,b,line,D,o)
lengthSide=norm(b-a); direction=(b-a)/lengthSide;
t=linspace(0,1,max(16,ceil(lengthSide)+1)).';
p=a+t.*(b-a);
distance=interp2(D,p(:,1),p(:,2),'linear',Inf);
supported=distance<=o.EdgeTolerance;
fraction=mean(supported);
zeroRun=diff([0;find(supported);numel(supported)+1])-1;
maxGap=max(zeroRun)/numel(supported);
s=(line.points-a)*direction.';
segmentCoverage=max(0,min(lengthSide,max(s))-max(0,min(s)))/lengthSide;
extrapolation=max([0,-min(s),max(s)-lengthSide]);
% Also constrain inferred corners that lie far outside the observed segment.
missingEnd=max([max(0,min(s)),max(0,lengthSide-max(s))])/lengthSide;
ok=fraction>=o.MinEdgeSupport && maxGap<=o.MaxUnsupportedFraction && ...
    segmentCoverage>=o.MinSegmentCoverage && missingEnd<=o.MaxEndpointExtension && ...
    extrapolation<=0.60*lengthSide && ...
    max(distance([1 end]))<=1.5*o.EdgeTolerance;
end

function [ok,reason]=validQuad(q,imageHW,margin,o)
ok=false; reason='Invalid or degenerate sign quadrilateral.';
if ~isequal(size(q),[4 2]) || any(~isfinite(q(:))), return; end
edges=q([2 3 4 1],:)-q;
lengths=sqrt(sum(edges.^2,2));
crosses=edges(:,1).*edges([2 3 4 1],2)-edges(:,2).*edges([2 3 4 1],1);
if min(lengths)<o.MinSideLength || ~(all(crosses>1e-6)||all(crosses<-1e-6)), return; end
% Supplied vertices may lie on image pixel-cell boundaries. Automatic
% candidates require an actual positive margin and must not touch the crop.
if margin==0
    outside=any(q(:,1)<0.5 | q(:,1)>imageHW(2)+0.5 | ...
        q(:,2)<0.5 | q(:,2)>imageHW(1)+0.5);
else
    outside=any(q(:,1)<=1+margin | q(:,1)>=imageHW(2)-margin | ...
        q(:,2)<=1+margin | q(:,2)>=imageHW(1)-margin);
end
if outside
    reason='Sign boundary is outside or too close to a clipped image/context edge.'; return;
end
angles=zeros(4,1);
for k=1:4
    a=q(mod(k-2,4)+1,:)-q(k,:); b=q(mod(k,4)+1,:)-q(k,:);
    angles(k)=acosd(max(-1,min(1,dot(a,b)/(norm(a)*norm(b)))));
end
if min(angles)<o.MinCornerAngle || max(angles)>180-o.MinCornerAngle, return; end
if max(lengths([1 3]))/min(lengths([1 3]))>o.MaxOppositeSideRatio || ...
        max(lengths([2 4]))/min(lengths([2 4]))>o.MaxOppositeSideRatio
    reason='Opposite sign sides imply excessive or unstable foreshortening.'; return;
end
ok=true; reason='';
end

function q=orientSuppliedQuad(q)
% Preserve the supplied physical TL anchor; normalize winding only.
signedArea=sum(q(:,1).*q([2 3 4 1],2)-q([2 3 4 1],1).*q(:,2));
if signedArea<0, q=q([1 4 3 2],:); end
end

function fraction=textCoverage(q,box,support)
if ~isempty(support)
    fraction=mean(inpolygon(support(:,1),support(:,2),q(:,1),q(:,2)));
    return;
end
[x,y]=meshgrid(linspace(box(1),box(1)+box(3),7), ...
    linspace(box(2),box(2)+box(4),7));
fraction=mean(inpolygon(x(:),y(:),q(:,1),q(:,2)));
end

function [spans,area]=supportGeometry(support,u,n,box)
if isempty(support)
    spans=[abs(u(1))*box(3)+abs(u(2))*box(4), ...
        abs(n(1))*box(3)+abs(n(2))*box(4)];
    area=prod(box(3:4));
else
    projected=support*[u;n].';
    spans=max(projected,[],1)-min(projected,[],1);
    % The footprint of supplied text evidence is rotation invariant. A
    % convex hull includes the spaces between glyphs, unlike raw ink area.
    if rank(support-mean(support,1))>=2
        hull=convhull(support(:,1),support(:,2));
        area=polyarea(support(hull,1),support(hull,2));
    else
        area=prod(spans);
    end
    area=max(1,area);
end
end

function value=quadDifference(a,b)
lengths=sqrt(sum((a([2 3 4 1],:)-a).^2,2));
value=max(sqrt(sum((a-b).^2,2)))/max(1,median(lengths));
end

function [g,info]=fitGeometry(q,o)
g=emptyGeometry();
info=struct('reason','','reprojectionError',NaN,'normalizedCondition',NaN, ...
    'aspectRatio',NaN,'aspectRatioSource','','outputScale',NaN);
lengths=sqrt(sum((q([2 3 4 1],:)-q).^2,2));
if isempty(o.AspectRatio)
    ratio=mean(lengths([1 3]))/mean(lengths([2 4]));
    aspectSource='estimated-from-observed-side-lengths-not-metric';
else
    ratio=o.AspectRatio; aspectSource='supplied-target-width-over-height';
end
area=polyarea(q(:,1),q(:,2));
height=sqrt(area/ratio); width=ratio*height;
outputScale=min([1,o.MaxOutputDimension/max(height,width),sqrt(o.MaxOutputPixels/(height*width))]);
hw=max(2,round([height width]*outputScale));
if min(hw)<o.MinOutputDimension
    info.reason='Rectified sign would have an unusably small output dimension.'; return;
end
dst=[1 1;hw(2) 1;hw(2) hw(1);1 hw(1)];
% Check conditioning in centred/scaled coordinates, not raw pixel positions.
Ts=normalizer(q); Td=normalizer(dst);
qn=applyMatrix(Ts,q); dn=applyMatrix(Td,dst);
A=zeros(8,9);
for k=1:4
    x=qn(k,1); y=qn(k,2); X=dn(k,1); Y=dn(k,2);
    A(2*k-1,:)=[-x -y -1 0 0 0 X*x X*y X];
    A(2*k,:)=[0 0 0 -x -y -1 Y*x Y*y Y];
end
s=svd(A); info.normalizedCondition=s(1)/s(end);
if ~isfinite(info.normalizedCondition) || info.normalizedCondition>o.MaxNormalizedCondition
    info.reason='Projective corner configuration is ill-conditioned.'; return;
end
try
    tform=fitgeotform2d(q,dst,'projective');
    matrix=tform.A;
    Hn=Td*matrix/Ts;
    if rcond(Hn)<1/o.MaxNormalizedCondition
        info.reason='Normalized homography is numerically unstable.'; return;
    end
    den=[q ones(4,1)]*matrix(3,:).';
    invMatrix=inv(matrix);
    invDen=[dst ones(4,1)]*invMatrix(3,:).';
    if ~sameSafeSign(den) || ~sameSafeSign(invDen)
        info.reason='Projective horizon intersects or approaches the sign.'; return;
    end
    mapped=transformPointsForward(tform,q);
    info.reprojectionError=max(sqrt(sum((mapped-dst).^2,2)));
    if ~isfinite(info.reprojectionError) || info.reprojectionError>1e-3
        info.reason='Projective corner reprojection failed validation.'; return;
    end
catch exception
    info.reason=['Projective fitting failed: ' exception.identifier]; return;
end
g.accepted=true; g.corners=q; g.transform=tform; g.outputSizeHW=hw;
g.aspectRatioSource=aspectSource;
info.aspectRatio=ratio; info.aspectRatioSource=aspectSource; info.outputScale=outputScale;
end

function T=normalizer(p)
centre=mean(p,1); scale=sqrt(2)/sqrt(mean(sum((p-centre).^2,2)));
T=[scale 0 -scale*centre(1);0 scale -scale*centre(2);0 0 1];
end

function p=applyMatrix(H,p)
v=[p ones(size(p,1),1)]*H.'; p=v(:,1:2)./v(:,3);
end

function ok=sameSafeSign(v)
ok=all(isfinite(v)) && (all(v>0)||all(v<0)) && min(abs(v))>1e-4*max(abs(v));
end

function d=recordFit(d,f)
d.reprojectionError=f.reprojectionError; d.normalizedCondition=f.normalizedCondition;
d.aspectRatio=f.aspectRatio; d.aspectRatioSource=f.aspectRatioSource; d.outputScale=f.outputScale;
if ~isempty(f.reason), d.reason=f.reason; end
end

function g=emptyGeometry()
g=struct('accepted',false,'corners',zeros(0,2),'transform',[], ...
    'outputSizeHW',[],'aspectRatioSource','');
end

function d=emptyDiagnostics()
d=struct('accepted',false,'reason','','method','','hasAngleGuide',false,'guideSource','', ...
    'textSupportSource','','textSupportCount',0, ...
    'contextBox',[],'analysisSizeHW',[],'analysisScaleXY',[],'analysisGuideAxes',[], ...
    'proposedLineSegmentCount',0,'lineSegmentCount',0,'lineRefinement','', ...
    'sideCandidateCounts',zeros(1,4),'quadTrials',0, ...
    'supportedQuadCount',0,'candidateCorners',zeros(0,2),'edgeSupport',[], ...
    'endpointCoverage',[],'textCoverage',NaN,'bestScore',NaN,'runnerUpScore',NaN, ...
    'reprojectionError',NaN,'normalizedCondition',NaN,'aspectRatio',NaN, ...
    'aspectRatioSource','','outputScale',NaN);
end

function o=defaultOptions()
o=struct('Corners',[],'TextSupport',zeros(0,2),'AspectRatio',[],'ContextScale',3, ...
    'MaxAnalysisDimension',1000,'MaxHoughPeaks',48,'MaxLinesPerSide',6, ...
    'MaxQuadTrials',5000,'MaxLineAngleDeviation',30,'MinSideLength',18, ...
    'BoundaryMargin',2,'MinCornerAngle',25,'MaxOppositeSideRatio',4, ...
    'MinTextCoverage',0.98,'MinAreaToTextRatio',1.25,'MaxAreaToTextRatio',80, ...
    'EdgeTolerance',2.5,'MinEdgeSupport',0.72,'MaxUnsupportedFraction',0.20, ...
    'MinSegmentCoverage',0.55,'MaxEndpointExtension',0.30, ...
    'DuplicateQuadTolerance',0.035,'AmbiguityRatio',0.96, ...
    'MaxOutputDimension',2400,'MaxOutputPixels',4000000, ...
    'MinOutputDimension',12,'MaxNormalizedCondition',1000000);
end

function o=parseOptions(input)
if ~isstruct(input)||~isscalar(input)
    error('estimateSignPerspective:Options','options must be a scalar struct.');
end
o=defaultOptions(); fields=fieldnames(input);
for k=1:numel(fields)
    name=fields{k};
    if ~isfield(o,name), error('estimateSignPerspective:Option','Unknown option: %s.',name); end
    o.(name)=input.(name);
end
if ~isempty(o.Corners)
    validateattributes(o.Corners,{'numeric'},{'real','finite','nonsparse','size',[4 2]},mfilename,'Corners');
end
if ~isempty(o.TextSupport)
    validateattributes(o.TextSupport,{'numeric'}, ...
        {'real','finite','nonsparse','2d','ncols',2},mfilename,'TextSupport');
    if size(o.TextSupport,1)<12 || size(o.TextSupport,1)>25000
        error('estimateSignPerspective:TextSupport','TextSupport requires 12..25000 foreground points.');
    end
end
if ~isempty(o.AspectRatio)
    validateattributes(o.AspectRatio,{'numeric'},{'real','finite','scalar','>=',0.05,'<=',20},mfilename,'AspectRatio');
end
validateattributes(o.ContextScale,{'numeric'},{'real','finite','scalar','>=',1.2,'<=',12});
integerNames={'MaxAnalysisDimension','MaxHoughPeaks','MaxLinesPerSide','MaxQuadTrials', ...
    'MaxOutputDimension','MaxOutputPixels','MinOutputDimension'};
for k=1:numel(integerNames)
    validateattributes(o.(integerNames{k}),{'numeric'},{'real','finite','scalar','integer','positive'});
end
if o.MaxAnalysisDimension<64 || o.MaxAnalysisDimension>3000 || ...
        o.MaxHoughPeaks>200 || o.MaxLinesPerSide>12 || o.MaxQuadTrials>30000 || ...
        o.MaxOutputDimension>10000 || o.MaxOutputPixels>25000000 || ...
        o.MinOutputDimension>o.MaxOutputDimension
    error('estimateSignPerspective:OptionRange','Invalid analysis/search/output resource bounds.');
end
positive={'MinSideLength','EdgeTolerance','MaxNormalizedCondition'};
for k=1:numel(positive)
    validateattributes(o.(positive{k}),{'numeric'},{'real','finite','scalar','positive'});
end
validateattributes(o.BoundaryMargin,{'numeric'},{'real','finite','scalar','>=',0.5});
validateattributes(o.MaxLineAngleDeviation,{'numeric'},{'real','finite','scalar','>',0,'<',45});
validateattributes(o.MinCornerAngle,{'numeric'},{'real','finite','scalar','>',0,'<',90});
validateattributes(o.MaxOppositeSideRatio,{'numeric'},{'real','finite','scalar','>=',1,'<=',10});
fractions={'MinTextCoverage','MinEdgeSupport','MaxUnsupportedFraction', ...
    'MinSegmentCoverage','MaxEndpointExtension','DuplicateQuadTolerance','AmbiguityRatio'};
for k=1:numel(fractions)
    validateattributes(o.(fractions{k}),{'numeric'},{'real','finite','scalar','>',0,'<=',1});
end
validateattributes(o.MinAreaToTextRatio,{'numeric'},{'real','finite','scalar','>=',1});
validateattributes(o.MaxAreaToTextRatio,{'numeric'},{'real','finite','scalar','>=',o.MinAreaToTextRatio});
end
