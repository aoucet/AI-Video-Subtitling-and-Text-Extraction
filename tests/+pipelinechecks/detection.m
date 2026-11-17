function checks = detection()
% Check the short-group fallback on clean and ambiguous candidate layouts.
pair = [20 20 10 24; 34 21 11 24];
intensity = [30; 36];
stroke = [3.5; 3.6];
free = false(2,1);
noLines = zeros(0,4);
cases = ["Two adjacent glyphs"; "Widely spaced glyphs"; "Vertical stack"; ...
    "Reserved glyph"; "Existing line overlap"; "Ambiguous neighbor"; ...
    "Thin and thick digit strokes"; "Inconsistent stroke sizes"; "Wide background regions"; ...
    "Overlapping pair proposals"];

wide = pair;
wide(2,1) = 55;
vertical = [20 20 10 24; 22 51 11 24];
ambiguous = [pair; 49 22 10 24];
background = [20 20 32 14; 54 21 32 14];
overlapping = [pair; pair + [1 1 0 0]];
found = [
    size(shortTextPairs(pair, intensity, stroke, free, noLines), 1)
    size(shortTextPairs(wide, intensity, stroke, free, noLines), 1)
    size(shortTextPairs(vertical, intensity, stroke, free, noLines), 1)
    size(shortTextPairs(pair, intensity, stroke, [true; false], noLines), 1)
    size(shortTextPairs(pair, intensity, stroke, free, [15 16 40 34]), 1)
    size(shortTextPairs(ambiguous, [intensity; 31], [stroke; 3.5], false(3,1), noLines), 1)
    size(shortTextPairs(pair, [45; 78], [2; 4.5], free, noLines), 1)
    size(shortTextPairs(pair, intensity, [2; 8], free, noLines), 1)
    size(shortTextPairs(background, intensity, stroke, free, noLines), 1)
    size(shortTextPairs(overlapping, [intensity; 190; 192], [stroke; stroke], false(4,1), noLines), 1)
];
expected = [1; 0; 0; 0; 0; 0; 1; 0; 0; 1];
checks = table(cases, found == expected, ...
    "Expected " + expected + " short lines. Found " + found + ".", ...
    'VariableNames', {'Case','Passed','Detail'});
end
