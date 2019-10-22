#import "SVGTextElement.h"

#import <CoreText/CoreText.h>
#import "CALayerWithChildHitTest.h"
#import "SVGElement_ForParser.h" // to resolve Xcode circular dependencies; in long term, parsing SHOULD NOT HAPPEN inside any class whose name starts "SVG" (because those are reserved classes for the SVG Spec)
#import "SVGGradientLayer.h"
#import "SVGTSpanElement.h"
#import "SVGHelperUtilities.h"
#import "SVGUtils.h"
#import "SVGTextLayer.h"

@implementation SVGTextElement
{
    CGPoint _currentTextPosition;
    CTFontRef _baseFont;
    CGFloat _baseFontAscent;
    CGFloat _baseFontDescent;
    CGFloat _baseFontLeading;
    CGFloat _baseFontLineHeight;
    BOOL _didAddTrailingSpace;
}

@synthesize transform; // each SVGElement subclass that conforms to protocol "SVGTransformable" has to re-synthesize this to work around bugs in Apple's Objective-C 2.0 design that don't allow @properties to be extended by categories / protocols


- (CALayer *) newLayer
{
	/**
	 BY DESIGN: we work out the positions of all text in ABSOLUTE space, and then construct the Apple CALayers and CATextLayers around
	 them, as required.
	 
	 And: SVGKit works by pre-baking everything into position (its faster, and avoids Apple's broken CALayer.transform property)
	 */
    
    // Set up the text elements base font
    _baseFont = [self newFontFromElement:self];
    _baseFontAscent = CTFontGetAscent(_baseFont);
    _baseFontDescent = CTFontGetDescent(_baseFont);
    _baseFontLeading = CTFontGetLeading(_baseFont);
    _baseFontLineHeight = _baseFontAscent + _baseFontDescent + _baseFontLeading;

    // Set up the main layer to put text in to
    CALayer *layer = [CALayer layer];
    [SVGHelperUtilities configureCALayer:layer usingElement:self];
    // Don't care about the size - the sublayers containing text will be positioned relative to the baseline of _baseFont
    layer.bounds = CGRectMake(0, 0, 0, _baseFontAscent+_baseFontDescent);
    // Position the anchor point at the base font's baseline so that the text elements transform are applied properly
    layer.anchorPoint = CGPointMake(0, _baseFontAscent/(_baseFontAscent+_baseFontDescent));
    layer.position = CGPointMake(0, 0);
      // Transform according to
    layer.affineTransform = [SVGHelperUtilities transformAbsoluteIncludingViewportForTransformableOrViewportEstablishingElement:self];;

    // Add sublayers for the text elements
    _didAddTrailingSpace = NO;
    [self addLayersForElement:self toLayer:layer];
    
    CFRelease(_baseFont);

    return layer;
}

- (void)layoutLayer:(CALayer *)layer
{
}


#pragma mark -

/**
* Handling x, y, dx, and dy according to http://www.w3.org/TR/SVG/text.html
*/
- (void)updateCurrentTextPositionBasedOnElement:(SVGTextPositioningElement *)element font:(CTFontRef)font
{
    if (element.x.unitType!=SVG_LENGTHTYPE_UNKNOWN) {
        _currentTextPosition.x = [self pixelValueForLength:element.x withFont:font];
    } else if ([element isKindOfClass:[SVGTextElement class]]) {
        _currentTextPosition.x = 0;
    }
    if (element.y.unitType!=SVG_LENGTHTYPE_UNKNOWN) {
        _currentTextPosition.y = [self pixelValueForLength:element.y withFont:font];
    } else if ([element isKindOfClass:[SVGTextElement class]]) {
        _currentTextPosition.y = 0;
    }
    if (element.dx.unitType!=SVG_LENGTHTYPE_UNKNOWN) {
        _currentTextPosition.x += [self pixelValueForLength:element.dx withFont:font];
    }
    if (element.dy.unitType!=SVG_LENGTHTYPE_UNKNOWN) {
        _currentTextPosition.y += [self pixelValueForLength:element.dy withFont:font];
    }
}


- (void)addLayersForElement:(SVGTextPositioningElement *)element toLayer:(CALayer *)layer
{
    CTFontRef font = [self newFontFromElement:element];
    [self updateCurrentTextPositionBasedOnElement:element font:font];

    for (Node *node in element.childNodes) {
        BOOL hasPreviousNode = (node!=element.firstChild);
        BOOL hasNextNode = (node!=element.lastChild);

        NSLog(@"currentTextPosition : %@", NSStringFromCGPoint(_currentTextPosition));
        NSLog(@"node.nextSibling : %@", node.nextSibling);
        switch (node.nodeType) {
            case DOMNodeType_TEXT_NODE: {
                BOOL hadLeadingSpace;
                BOOL hadTrailingSpace;
                NSString *text = [self stripText:node.textContent hadLeadingSpace:&hadLeadingSpace hadTrailingSpace:&hadTrailingSpace];
                if (hasPreviousNode && hadLeadingSpace && !_didAddTrailingSpace) {
                    text = [@" " stringByAppendingString:text];
                }
                if (hasNextNode && hadTrailingSpace) {
                    text = [text stringByAppendingString:@" "];
                    _didAddTrailingSpace = YES;
                } else {
                    _didAddTrailingSpace = NO;
                }
                if (text.length>0) {
                    CAShapeLayer *label = [self layerWithText:text font:font];
                    [SVGHelperUtilities configureCALayer:label usingElement:element];
                    [SVGHelperUtilities applyStyleToShapeLayer:label withElement:element];
                    [layer addSublayer:label];
                }
                break;
            }

            case DOMNodeType_ELEMENT_NODE: {
                if ([node isKindOfClass:[SVGTSpanElement class]]) {
                    SVGTSpanElement *tspanElement = (SVGTSpanElement *)node;
                    [self addLayersForElement:tspanElement toLayer:layer];
                }
                break;
            }
                
            default:
                break;
        }
    }

    CFRelease(font);

	/** VERY USEFUL when trying to debug text issues:
	label.backgroundColor = [UIColor colorWithRed:0.5 green:0 blue:0 alpha:0.5].CGColor;
	label.borderColor = [UIColor redColor].CGColor;
	//DEBUG: SVGKitLogVerbose(@"font size %2.1f at %@ ... final frame of layer = %@", effectiveFontSize, NSStringFromCGPoint(transformedOrigin), NSStringFromCGRect(label.frame));
	*/
}

-(CALayer *) newCALayerForTextLayer:(CATextLayer *)label transformAbsolute:(CGAffineTransform)transformAbsolute
{
    CALayer *fillLayer = label;
    NSString* actualFill = [self cascadedValueForStylableProperty:@"fill"];

    if ( [actualFill hasPrefix:@"url"] )
    {
        NSArray *fillArgs = [actualFill componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *fillIdArg = fillArgs.firstObject;
        NSRange idKeyRange = NSMakeRange(5, fillIdArg.length - 6);
        NSString* fillId = [fillIdArg substringWithRange:idKeyRange];

        /** Replace the return layer with a special layer using the URL fill */
        /** fetch the fill layer by URL using the DOM */
        SVGGradientLayer *gradientLayer = [SVGHelperUtilities getGradientLayerWithId:fillId forElement:self withRect:label.frame transform:transformAbsolute];
        if (gradientLayer) {
            gradientLayer.mask = label;
            fillLayer = gradientLayer;
        } else {
            // no gradient, fallback
        }
    }

    NSString* actualOpacity = [self cascadedValueForStylableProperty:@"opacity" inherit:NO];
    fillLayer.opacity = actualOpacity.length > 0 ? [actualOpacity floatValue] : 1; // unusually, the "opacity" attribute defaults to 1, not 0

    return fillLayer;
}

/**
 Return the best matched font with all posible CSS font property (like `font-family`, `font-size`, etc)

 @param svgElement svgElement
 @return The matched font, or fallback to system font, non-nil
 */
+ (UIFont *)matchedFontWithElement:(SVGElement *)svgElement {
    // Using top-level API to walkthough all availble font-family
    NSString *actualSize = [svgElement cascadedValueForStylableProperty:@"font-size"];
    NSString *actualFamily = [svgElement cascadedValueForStylableProperty:@"font-family"];
    // TODO- Using font descriptor to match best font consider `font-style`, `font-weight`
    NSString *actualFontStyle = [svgElement cascadedValueForStylableProperty:@"font-style"];
    NSString *actualFontWeight = [svgElement cascadedValueForStylableProperty:@"font-weight"];
    NSString *actualFontStretch = [svgElement cascadedValueForStylableProperty:@"font-stretch"];
    
    CGFloat effectiveFontSize = (actualSize.length > 0) ? [actualSize floatValue] : 12; // I chose 12. I couldn't find an official "default" value in the SVG spec.
    
    NSArray<NSString *> *actualFontFamilies = [SVGTextElement fontFamiliesWithCSSValue:actualFamily];
    NSString *matchedFontFamily;
    if (actualFontFamilies) {
        // walkthrough all available font-families to find the best matched one
        NSSet<NSString *> *availableFontFamilies;
#if SVGKIT_MAC
        availableFontFamilies = [NSSet setWithArray:NSFontManager.sharedFontManager.availableFontFamilies];
#else
        availableFontFamilies = [NSSet setWithArray:UIFont.familyNames];
#endif
        for (NSString *fontFamily in actualFontFamilies) {
            if ([availableFontFamilies containsObject:fontFamily]) {
                matchedFontFamily = fontFamily;
                break;
            }
        }
    }
    
    // we provide enough hint information, let Core Text using their algorithm to detect which fontName should be used
    // if `matchedFontFamily` is nil, use the system default font family instead (allows `font-weight` these information works)
    NSDictionary *attributes = [self fontAttributesWithFontFamily:matchedFontFamily fontStyle:actualFontStyle fontWeight:actualFontWeight fontStretch:actualFontStretch];
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    CTFontRef fontRef = CTFontCreateWithFontDescriptor(descriptor, effectiveFontSize, NULL);
    UIFont *font = (__bridge_transfer UIFont *)fontRef;
    CFRelease(descriptor);
    
    return font;
}

/**
 Convert CSS font detailed information into Core Text descriptor attributes (determine the best matched font).

 @param fontFamily fontFamily
 @param fontStyle fontStyle
 @param fontWeight fontWeight
 @param fontStretch fontStretch
 @return Core Text descriptor attributes
 */
+ (NSDictionary *)fontAttributesWithFontFamily:(NSString *)fontFamily fontStyle:(NSString *)fontStyle fontWeight:(NSString *)fontWeight fontStretch:(NSString *)fontStretch {
    // Default value
    if (!fontFamily.length) fontFamily = [self systemDefaultFontFamily];
    if (!fontStyle.length) fontStyle = @"normal";
    if (!fontWeight.length) fontWeight = @"normal";
    if (!fontStretch.length) fontStretch = @"normal";
    
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[(__bridge NSString *)kCTFontFamilyNameAttribute] = fontFamily;
    // font-weight is in the sub-dictionary
    NSMutableDictionary *traits = [NSMutableDictionary dictionary];
    // CSS font weight is from 0-1000
    CGFloat weight;
    if ([fontWeight isEqualToString:@"normal"]) {
        weight = 400;
    } else if ([fontWeight isEqualToString:@"bold"]) {
        weight = 700;
    } else if ([fontWeight isEqualToString:@"bolder"]) {
        weight = 900;
    } else if ([fontWeight isEqualToString:@"lighter"]) {
        weight = 100;
    } else {
        CGFloat value = [fontWeight doubleValue];
        weight = MIN(MAX(value, 1), 1000);
    }
    // map from CSS [1, 1000] to Core Text [-1.0, 1.0], 400 represent 0.0
    CGFloat coreTextFontWeight;
    if (weight < 400) {
        coreTextFontWeight = (weight - 400) / 1000 * (1 / 0.4);
    } else {
        coreTextFontWeight = (weight - 400) / 1000 * (1 / 0.6);
    }
    
    // CSS font style
    CTFontSymbolicTraits style = 0;
    if ([fontStyle isEqualToString:@"normal"]) {
        style |= 0;
    } else if ([fontStyle isEqualToString:@"italic"] || [fontStyle rangeOfString:@"oblique"].location != NSNotFound) {
        // Actually we can control the detailed slant degree via `kCTFontSlantTrait`, but it's rare usage so treat them the same, TODO in the future
        style |= kCTFontItalicTrait;
    }
    
    // CSS font stretch
    if ([fontStretch rangeOfString:@"condensed"].location != NSNotFound) {
        // Actually we can control the detailed percent via `kCTFontWidthTrait`, but it's rare usage so treat them the same, TODO in the future
        style |= kCTFontTraitCondensed;
    } else if ([fontStretch rangeOfString:@"expanded"].location != NSNotFound) {
        style |= kCTFontTraitExpanded;
    }
    
    traits[(__bridge NSString *)kCTFontSymbolicTrait] = @(style);
    traits[(__bridge NSString *)kCTFontWeightTrait] = @(coreTextFontWeight);
    attributes[(__bridge NSString *)kCTFontTraitsAttribute] = [traits copy];
    
    return [attributes copy];
}

/**
 Parse the `font-family` CSS value into array of font-family name

 @param value value
 @return array of font-family name
 */
+ (NSArray<NSString *> *)fontFamiliesWithCSSValue:(NSString *)value {
    if (value.length == 0) {
        return nil;
    }
    NSArray<NSString *> *args = [value componentsSeparatedByString:@","];
    if (args.count == 0) {
        return nil;
    }
    NSMutableArray<NSString *> *fontFamilies = [NSMutableArray arrayWithCapacity:args.count];
    for (NSString *arg in args) {
        // parse: font-family: "Goudy Bookletter 1911", sans-serif;
        // delete ""
        NSString *fontFamily = [arg stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        // trim white space
        [fontFamily stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        [fontFamilies addObject:fontFamily];
    }
    
    return [fontFamilies copy];
}

+ (NSString *)systemDefaultFontFamily {
    static dispatch_once_t onceToken;
    static NSString *fontFamily;
    dispatch_once(&onceToken, ^{
        UIFont *font = [UIFont systemFontOfSize:12.f];
        fontFamily = font.familyName;
    });
    return fontFamily;
}

- (CGFloat)pixelValueForLength:(SVGLength *)length withFont:(CTFontRef)font
{
    if (length.unitType==SVG_LENGTHTYPE_EMS) {
        return length.value*CTFontGetSize(font);
    } else {
        return length.pixelsValue;
    }
}

- (NSString *)stripText:(NSString *)text hadLeadingSpace:(BOOL *)hadLeadingSpace hadTrailingSpace:(BOOL *)hadTrailingSpace
{
    // Remove all newline characters
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    // Convert tabs into spaces
    text = [text stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    // Consolidate all contiguous space characters
    while ([text rangeOfString:@"  "].location != NSNotFound) {
        text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (hadLeadingSpace) {
        *hadLeadingSpace = (text.length==0 ? NO : [[text substringWithRange:NSMakeRange(0, 1)] isEqualToString:@" "]);
    }
    if (hadTrailingSpace) {
        *hadTrailingSpace = (text.length==0 ? NO : [[text substringFromIndex:text.length-1] isEqualToString:@" "]);
    }
    // Remove leading and trailing spaces
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return text;
}

- (CTFontRef)newFontFromElement:(SVGElement<SVGStylable> *)element
{
    NSString *fontSize = [element cascadedValueForStylableProperty:@"font-size"];
    NSString *fontFamily = [element cascadedValueForStylableProperty:@"font-family"];
    NSString *fontWeight = [element cascadedValueForStylableProperty:@"font-weight"];
    
    CGFloat effectiveFontSize = (fontSize.length > 0) ? [fontSize floatValue] : 12; // I chose 12. I couldn't find an official "default" value in the SVG spec.

    CTFontRef fontRef = NULL;
    if (fontFamily) {
        fontRef = CTFontCreateWithName((CFStringRef)fontFamily, effectiveFontSize, NULL);
    }
    if (!fontRef) {
        fontRef = CTFontCreateUIFontForLanguage(kCTFontUserFontType, effectiveFontSize, NULL);
    }
    if (fontWeight) {
        BOOL bold = [fontWeight isEqualToString:@"bold"];
        if (bold) {
            CTFontRef boldFontRef = CTFontCreateCopyWithSymbolicTraits(fontRef, effectiveFontSize, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
            if (boldFontRef) {
                CFRelease(fontRef);
                fontRef = boldFontRef;
            }
        }
    }
    return fontRef;
}

#pragma mark -

- (CAShapeLayer *)layerWithText:(NSString *)text font:(CTFontRef)font
{
    CAShapeLayer *label = [CAShapeLayer layer];
    label.anchorPoint = CGPointZero;
    label.position = _currentTextPosition;
    // Create path from the text
    CGFloat xStart = _currentTextPosition.x;
    UIBezierPath *textPath = [self bezierPathWithString:text font:font];
    // Bounding and alignment with _baseFont baseline
    CGFloat fontAscent = CTFontGetAscent(font);
    CGFloat fontDescent = CTFontGetDescent(font);
    label.path = textPath.CGPath;
    CGPoint position = label.position;
    position.y += -(fontAscent-_baseFontAscent);
    label.position = position;
    label.bounds = CGRectMake(0, -fontAscent, _currentTextPosition.x-xStart, fontAscent+fontDescent);
    return label;
}

/**
 * Create a UIBezierPath rendering string in font.
 * textPath: Have a look at http://iphonedevsdk.com/forum/iphone-sdk-development/101053-cgpath-help.html
 */
- (UIBezierPath*)bezierPathWithString:(NSString*)string font:(CTFontRef)fontRef
{
    UIBezierPath *combinedGlyphsPath = nil;
    CGMutablePathRef combinedGlyphsPathRef = CGPathCreateMutable();
    if (combinedGlyphsPathRef)
    {
        CGRect rect = CGRectMake(0, 0, FLT_MAX, FLT_MAX);
        UIBezierPath *frameShape = [UIBezierPath bezierPathWithRect:rect];

        CGPoint basePoint = CGPointMake(_currentTextPosition.x, CTFontGetAscent(fontRef));
        CFStringRef keys[] = { kCTFontAttributeName };
        CFTypeRef values[] = { fontRef };
        CFDictionaryRef attributesRef = CFDictionaryCreate(NULL, (const void **)&keys, (const void **)&values,
                                                           sizeof(keys) / sizeof(keys[0]), &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        
        if (attributesRef)
        {
            CFAttributedStringRef attributedStringRef = CFAttributedStringCreate(NULL, (CFStringRef) string, attributesRef);

            if (attributedStringRef)
            {
                CTFramesetterRef frameSetterRef = CTFramesetterCreateWithAttributedString(attributedStringRef);

                if (frameSetterRef)
                {
                    CTFrameRef frameRef = CTFramesetterCreateFrame(frameSetterRef, CFRangeMake(0,0), [frameShape CGPath], NULL);

                    if (frameRef)
                    {
                        CFArrayRef lines = CTFrameGetLines(frameRef);
                        if (CFArrayGetCount(lines)==1) {
                            CGPoint lineOrigin;
                            CTFrameGetLineOrigins(frameRef, CFRangeMake(0, 1), &lineOrigin);
                            CTLineRef lineRef = CFArrayGetValueAtIndex(lines, 0);

                            CFArrayRef runs = CTLineGetGlyphRuns(lineRef);

                            CFIndex runCount = CFArrayGetCount(runs);
                            for (CFIndex runIndex = 0; runIndex<runCount; runIndex++)
                            {
                                CTRunRef runRef = CFArrayGetValueAtIndex(runs, runIndex);

                                CFIndex glyphCount = CTRunGetGlyphCount(runRef);
                                CGGlyph glyphs[glyphCount];
                                CGSize glyphAdvances[glyphCount];
                                CGPoint glyphPositions[glyphCount];

                                CFRange runRange = CFRangeMake(0, glyphCount);
                                CTRunGetGlyphs(runRef, CFRangeMake(0, glyphCount), glyphs);
                                CTRunGetPositions(runRef, runRange, glyphPositions);

                                CTFontGetAdvancesForGlyphs(fontRef, kCTFontDefaultOrientation, glyphs, glyphAdvances, glyphCount);

                                for (CFIndex glyphIndex = 0; glyphIndex<glyphCount; glyphIndex++)
                                {
                                    CGGlyph glyph = glyphs[glyphIndex];

                                    // For regular UIBezierPath drawing, we need to invert around the y axis.
                                    CGAffineTransform glyphTransform = CGAffineTransformMakeTranslation(lineOrigin.x+glyphPositions[glyphIndex].x, rect.size.height-lineOrigin.y-glyphPositions[glyphIndex].y);
                                    glyphTransform = CGAffineTransformScale(glyphTransform, 1, -1);
                                    // TODO[pdr] Idea for handling rotate: glyphTransform = CGAffineTransformRotate(glyphTransform, M_PI/8);

                                    CGPathRef glyphPathRef = CTFontCreatePathForGlyph(fontRef, glyph, &glyphTransform);
                                    if (glyphPathRef)
                                    {
                                        // Finally carry out the appending.
                                        CGPathAddPath(combinedGlyphsPathRef, NULL, glyphPathRef);
                                        CFRelease(glyphPathRef);
                                    }
                                    basePoint.x += glyphAdvances[glyphIndex].width;
                                    basePoint.y += glyphAdvances[glyphIndex].height;
                                    //NSLog(@"'%@' => %@", [string substringWithRange:NSMakeRange(glyphIndex, 1)], NSStringFromCGPoint(basePoint));
                                }
                              _currentTextPosition.x = basePoint.x; // TODO[pdr]
                            }
                        }
                        CFRelease(frameRef);
                    }
                    CFRelease(frameSetterRef);
                }
                CFRelease(attributedStringRef);
            }
            CFRelease(attributesRef);
        }

        // Casting a CGMutablePathRef to a CGPathRef seems to be the only way to convert what was just built into a UIBezierPath.
        combinedGlyphsPath = [UIBezierPath bezierPathWithCGPath:(CGPathRef) combinedGlyphsPathRef];

        CGPathRelease(combinedGlyphsPathRef);
    }
    return combinedGlyphsPath;
}

@end
