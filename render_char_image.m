function image = render_char_image(text, fontSize, fontName)
%RENDER_CHAR_IMAGE Render dark text on a white grayscale image for NCC.
% The off-screen Java canvas works without opening a MATLAB figure.

    if nargin < 2 || isempty(fontSize), fontSize = 72; end
    if nargin < 3 || isempty(fontName), fontName = 'SansSerif'; end
    text = convertStringsToChars(text);
    fontName = convertStringsToChars(fontName);
    validateattributes(text, {'char'}, {'row','nonempty'}, mfilename, 'text');
    validateattributes(fontSize, {'numeric'}, {'real','scalar','integer','positive','finite'}, ...
        mfilename, 'fontSize');
    validateattributes(fontName, {'char'}, {'row','nonempty'}, mfilename, 'fontName');
    if ~usejava('jvm')
        error('render_char_image:JavaUnavailable', 'Text rendering requires the MATLAB JVM.');
    end

    font = javaObject('java.awt.Font', fontName, java.awt.Font.PLAIN, int32(fontSize));
    rgbType = java.awt.image.BufferedImage.TYPE_INT_RGB;
    preview = javaObject('java.awt.image.BufferedImage', int32(1), int32(1), rgbType);
    previewGraphics = preview.createGraphics();
    metrics = previewGraphics.getFontMetrics(font);
    padding = int32(ceil(double(fontSize)/4));
    width = int32(metrics.stringWidth(text)) + 2*padding;
    height = int32(metrics.getHeight()) + 2*padding;
    baseline = int32(metrics.getAscent()) + padding;
    previewGraphics.dispose();

    canvas = javaObject('java.awt.image.BufferedImage', width, height, rgbType);
    graphics = canvas.createGraphics();
    cleanup = onCleanup(@() graphics.dispose());
    graphics.setColor(java.awt.Color.WHITE);
    graphics.fillRect(int32(0), int32(0), width, height);
    graphics.setColor(java.awt.Color.BLACK);
    graphics.setFont(font);
    graphics.setRenderingHint(java.awt.RenderingHints.KEY_TEXT_ANTIALIASING, ...
        java.awt.RenderingHints.VALUE_TEXT_ANTIALIAS_ON);
    graphics.drawString(text, padding, baseline);

    % Java returns row-major packed RGB. The red, green and blue bytes match.
    pixels = zeros(1, double(width)*double(height), 'int32');
    pixels = canvas.getRGB(int32(0), int32(0), width, height, pixels, int32(0), width);
    gray = uint8(bitand(pixels, int32(255)));
    image = reshape(gray, double(width), double(height)).';
end
