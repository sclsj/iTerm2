/*
 **  ScreenChar.m
 **
 **  Copyright (c) 2011
 **
 **  Author: George Nachman
 **
 **  Project: iTerm2
 **
 **  Description: Code related to screen_char_t. Most of this has to do with
 **    storing multiple code points together in one cell by using a "color
 **    palette" approach where the code point can be used as an index into a
 **    string table, and the strings can have surrogate pairs and combining
 **    marks.
 **
 **  This program is free software; you can redistribute it and/or modify
 **  it under the terms of the GNU General Public License as published by
 **  the Free Software Foundation; either version 2 of the License, or
 **  (at your option) any later version.
 **
 **  This program is distributed in the hope that it will be useful,
 **  but WITHOUT ANY WARRANTY; without even the implied warranty of
 **  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 **  GNU General Public License for more details.
 **
 **  You should have received a copy of the GNU General Public License
 **  along with this program; if not, write to the Free Software
 **  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#import "ScreenChar.h"

#import "DebugLogging.h"
#import "charmaps.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermImageInfo.h"
#import "iTermMalloc.h"
#import "NSArray+iTerm.h"
#import "NSCharacterSet+iTerm.h"
#import "NSDictionary+iTerm.h"
#import "ScreenChar.h"

static NSString *const kScreenCharComplexCharMapKey = @"Complex Char Map";
static NSString *const kScreenCharSpacingCombiningMarksKey = @"Spacing Combining Marks";
static NSString *const kScreenCharInverseComplexCharMapKey = @"Inverse Complex Char Map";
static NSString *const kScreenCharImageMapKey = @"Image Map";
static NSString *const kScreenCharCCMNextKeyKey = @"Next Key";
static NSString *const kScreenCharHasWrappedKey = @"Has Wrapped";

static NSInteger gScreenCharGeneration;

// Maps codes to strings
static NSMutableDictionary* complexCharMap;
static NSMutableSet<NSNumber *> *spacingCombiningMarkCodeNumbers;
// Maps strings to codes.
static NSMutableDictionary* inverseComplexCharMap;
// Image info. Maps a NSNumber with the image's code to an ImageInfo object.
static NSMutableDictionary<NSNumber *, iTermImageInfo *> *gImages;
static NSMutableDictionary* gEncodableImageMap;
// Next available code.
static int ccmNextKey = 1;
// If ccmNextKey has wrapped then this is set to true and we have to delete old
// strings before creating a new one with a recycled code.
static BOOL hasWrapped = NO;

typedef NS_ENUM(int, iTermTriState) {
    iTermTriStateFalse,
    iTermTriStateTrue,
    iTermTriStateOther
};

iTermTriState iTermTriStateFromBool(BOOL b) {
    return b ? iTermTriStateTrue : iTermTriStateFalse;
}

@interface iTermStringLine()
@property(nonatomic, strong) NSString *stringValue;
@end

@implementation iTermStringLine {
    unichar *_backingStore;
    int *_deltas;
    int _length;
}

+ (iTermStringLine *)stringLineWithString:(NSString *)string {
    screen_char_t screenChars[string.length];
    memset(screenChars, 0, string.length * sizeof(screen_char_t));
    for (int i = 0; i < string.length; i++) {
        screenChars[i].code = [string characterAtIndex:i];
        screenChars[i].complexChar = NO;
    }
    return [[self alloc] initWithScreenChars:screenChars length:string.length];
}

- (instancetype)initWithScreenChars:(screen_char_t *)screenChars
                             length:(NSInteger)length {
    self = [super init];
    if (self) {
        _length = length;
        _stringValue = ScreenCharArrayToString(screenChars,
                                               0,
                                               length,
                                               &_backingStore,
                                               &_deltas);
    }
    return self;
}

- (void)dealloc {
    if (_backingStore) {
        free(_backingStore);
    }
    if (_deltas) {
        free(_deltas);
    }
}

- (NSRange)rangeOfScreenCharsForRangeInString:(NSRange)rangeInString {
    if (_length == 0) {
        return NSMakeRange(NSNotFound, 0);
    }

    // Convert to signed types because subtraction is used later on.
    const NSInteger location = rangeInString.location;
    const NSInteger length = rangeInString.length;
    NSInteger indexInScreenCharsOfFirstCharInRange = location + _deltas[MIN(_length - 1, location)];
    if (length == 0) {
        return NSMakeRange(indexInScreenCharsOfFirstCharInRange, 0);
    }

    const NSInteger indexInStringOfLastCharInRange = location + length - 1;
    const NSInteger indexInScreenCharsOfLastCharInRange =
        indexInStringOfLastCharInRange + _deltas[MIN(_length - 1, indexInStringOfLastCharInRange)];
    const NSInteger numberOfScreenChars =
        indexInScreenCharsOfLastCharInRange - indexInScreenCharsOfFirstCharInRange + 1;
    return NSMakeRange(indexInScreenCharsOfFirstCharInRange, numberOfScreenChars);
}

@end

static void CreateComplexCharMapIfNeeded() {
    if (!complexCharMap) {
        complexCharMap = [[NSMutableDictionary alloc] initWithCapacity:1000];
        spacingCombiningMarkCodeNumbers = [[NSMutableSet alloc] initWithCapacity:1000];
        inverseComplexCharMap = [[NSMutableDictionary alloc] initWithCapacity:1000];
        gScreenCharGeneration++;
    }
}

NSString *ComplexCharToStr(int key) {
    if (key == UNICODE_REPLACEMENT_CHAR) {
        return ReplacementString();
    }

    CreateComplexCharMapIfNeeded();
    return [complexCharMap objectForKey:[NSNumber numberWithInt:key]];
}

BOOL ComplexCharCodeIsSpacingCombiningMark(unichar code) {
    return [spacingCombiningMarkCodeNumbers containsObject:@(code)];
}

NSString *ScreenCharToStr(const screen_char_t *const sct) {
    return CharToStr(sct->code, sct->complexChar);
}

NSString *CharToStr(unichar code, BOOL isComplex) {
    if (code == UNICODE_REPLACEMENT_CHAR) {
        return ReplacementString();
    }

    if (isComplex) {
        return ComplexCharToStr(code);
    } else {
        return [NSString stringWithCharacters:&code length:1];
    }
}

int ExpandScreenChar(screen_char_t* sct, unichar* dest) {
    NSString* value = nil;
    if (sct->code == UNICODE_REPLACEMENT_CHAR) {
        value = ReplacementString();
    } else if (sct->complexChar) {
        value = ComplexCharToStr(sct->code);
    } else {
        *dest = sct->code;
        return 1;
    }
    if (!value) {
        // This can happen if state restoration goes awry.
        return 0;
    }
    [value getCharacters:dest];
    return (int)[value length];
}

UTF32Char CharToLongChar(unichar code, BOOL isComplex)
{
    NSString* aString = CharToStr(code, isComplex);
    unichar firstChar = [aString characterAtIndex:0];
    if (IsHighSurrogate(firstChar) && [aString length] >= 2) {
        unichar secondChar = [aString characterAtIndex:0];
        return DecodeSurrogatePair(firstChar, secondChar);
    } else {
        return firstChar;
    }
}

static BOOL ComplexCharKeyIsReserved(int k) {
    return k >= iTermBoxDrawingCodeMin && k <= iTermBoxDrawingCodeMax;
}

static void AllocateImageMapsIfNeeded(void) {
    if (!gImages) {
        gImages = [[NSMutableDictionary alloc] init];
        gEncodableImageMap = [[NSMutableDictionary alloc] init];
        gScreenCharGeneration++;
    }
}

screen_char_t ImageCharForNewImage(NSString *name,
                                   int width,
                                   int height,
                                   BOOL preserveAspectRatio,
                                   NSEdgeInsets inset) {
    AllocateImageMapsIfNeeded();
    int newKey;
    do {
        newKey = ccmNextKey++;
    } while (ComplexCharKeyIsReserved(newKey));

    screen_char_t c;
    memset(&c, 0, sizeof(c));
    c.image = 1;
    c.code = newKey;

    iTermImageInfo *imageInfo = [[iTermImageInfo alloc] initWithCode:c.code];
    imageInfo.filename = name;
    imageInfo.preserveAspectRatio = preserveAspectRatio;
    imageInfo.size = NSMakeSize(width, height);
    imageInfo.inset = inset;
    gImages[@(c.code)] = imageInfo;
    gScreenCharGeneration++;
    DLog(@"Assign %@ to image code %@", imageInfo, @(c.code));

    return c;
}

void SetPositionInImageChar(screen_char_t *charPtr, int x, int y)
{
    charPtr->foregroundColor = x;
    charPtr->backgroundColor = y;
}

void SetDecodedImage(unichar code, iTermImage *image, NSData *data) {
    iTermImageInfo *imageInfo = gImages[@(code)];
    [imageInfo setImageFromImage:image data:data];
    gEncodableImageMap[@(code)] = [imageInfo dictionary];
    gScreenCharGeneration++;
    if ([iTermAdvancedSettingsModel restoreWindowContents]) {
        [NSApp invalidateRestorableState];
    }
    DLog(@"set decoded image in %@", imageInfo);
}

void ReleaseImage(unichar code) {
    DLog(@"ReleaseImage(%@)", @(code));
    [gImages removeObjectForKey:@(code)];
    [gEncodableImageMap removeObjectForKey:@(code)];
    gScreenCharGeneration++;
}

iTermImageInfo *GetImageInfo(unichar code) {
    return gImages[@(code)];
}

VT100GridCoord GetPositionOfImageInChar(screen_char_t c) {
    return VT100GridCoordMake(c.foregroundColor,
                              c.backgroundColor);
}

int GetOrSetComplexChar(NSString *str,
                        iTermTriState isSpacingCombiningMark) {
    CreateComplexCharMapIfNeeded();
    NSNumber *number = inverseComplexCharMap[str];
    if (number) {
        return [number intValue];
    }

    gScreenCharGeneration++;
    int newKey;
    do {
        newKey = ccmNextKey++;
    } while (ComplexCharKeyIsReserved(newKey));

    number = @(newKey);
    if (hasWrapped) {
        NSString* oldStr = complexCharMap[number];
        if (oldStr) {
            [inverseComplexCharMap removeObjectForKey:oldStr];
            [spacingCombiningMarkCodeNumbers removeObject:number];
        }
    }
    switch (isSpacingCombiningMark) {
        case iTermTriStateTrue:
            [spacingCombiningMarkCodeNumbers addObject:number];
            break;
        case iTermTriStateFalse:
            break;
        case iTermTriStateOther: {
            NSCharacterSet *scmSet = [NSCharacterSet spacingCombiningMarksForUnicodeVersion:12];
            if ([str rangeOfCharacterFromSet:scmSet].location != NSNotFound) {
                [spacingCombiningMarkCodeNumbers addObject:number];
            }
        }
    }
    complexCharMap[number] = str;
    inverseComplexCharMap[str] = number;
    if ([iTermAdvancedSettingsModel restoreWindowContents]) {
        [NSApp invalidateRestorableState];
    }
    if (ccmNextKey == 0xf000) {
        ccmNextKey = 1;
        hasWrapped = YES;
    }
    return newKey;
}

int AppendToComplexChar(int key, unichar codePoint) {
    if (key == UNICODE_REPLACEMENT_CHAR) {
        return UNICODE_REPLACEMENT_CHAR;
    }

    NSString* str = [complexCharMap objectForKey:[NSNumber numberWithInt:key]];
    if ([str length] == kMaxParts) {
        NSLog(@"Warning: char <<%@>> with key %d reached max length %d", str,
              key, kMaxParts);
        return key;
    }
    assert(str);
    NSMutableString* temp = [NSMutableString stringWithString:str];
    [temp appendString:[NSString stringWithCharacters:&codePoint length:1]];

    return GetOrSetComplexChar(temp, iTermTriStateOther);
}

NSString *StringByNormalizingString(NSString *theString, iTermUnicodeNormalization normalization) {
    NSString *normalizedString;
    switch (normalization) {
        case iTermUnicodeNormalizationNFC:
            normalizedString = [theString precomposedStringWithCanonicalMapping];
            break;
        case iTermUnicodeNormalizationNFD:
            normalizedString = [theString decomposedStringWithCanonicalMapping];
            break;
        case iTermUnicodeNormalizationNone:
            normalizedString = theString;
            break;
        case iTermUnicodeNormalizationHFSPlus:
            normalizedString = [theString precomposedStringWithHFSPlusMapping];
            break;
    }
    return normalizedString;
}

void SetComplexCharInScreenChar(screen_char_t *screenChar,
                                NSString *theString,
                                iTermUnicodeNormalization normalization,
                                BOOL isSpacingCombiningMark) {
    NSString *normalizedString = StringByNormalizingString(theString, normalization);
    [theString precomposedStringWithCanonicalMapping];
    if (normalizedString.length == 1 && !isSpacingCombiningMark) {
        screenChar->code = [normalizedString characterAtIndex:0];
    } else {
        screenChar->code = GetOrSetComplexChar(theString, iTermTriStateFromBool(isSpacingCombiningMark));
        screenChar->complexChar = YES;
    }
}

void AppendToChar(screen_char_t *dest, unichar c) {
    if (dest->complexChar) {
        dest->code = AppendToComplexChar(dest->code, c);
    } else {
        unichar chars[2] = { dest->code, c };
        NSString *combined = [[NSString alloc] initWithCharacters:chars length:sizeof(chars) / sizeof(*chars)];
        SetComplexCharInScreenChar(dest,
                                   combined,
                                   iTermUnicodeNormalizationNone, NO);
    }
}

BOOL StringContainsCombiningMark(NSString *s) {
    if (s.length < 2) {
        return NO;
    }
    __block BOOL result = NO;
    [s enumerateComposedCharacters:^(NSRange range, unichar simple, NSString *complexString, BOOL *stop) {
        if (range.length == 1) {
            // Definitely no combining mark here.
            return;
        } else if (range.length == 2) {
            // Could be a surrogate pair or a BMP base character plus combining mark.
            unichar c = [s characterAtIndex:range.location + 1];
            result = !IsLowSurrogate(c);
            *stop = result;
        } else if (range.length > 2) {
            // Must have a combining mark
            result = YES;
            *stop = YES;
        }
    }];
    return result;
}

/*
 * TODO: Use the standard functions for these things:
 *
 * CFStringIsSurrogateHighCharacter
 * CFStringIsSurrogateLowCharacter
 * CFStringGetLongCharacterForSurrogatePair
 * CFStringGetSurrogatePairForLongCharacter
 */

UTF32Char DecodeSurrogatePair(unichar high, unichar low) {
    return 0x10000 + (high - 0xd800) * 0x400 + (low - 0xdc00);
}

BOOL IsLowSurrogate(unichar c) {
    // http://en.wikipedia.org/wiki/Mapping_of_Unicode_characters#Surrogates
    return c >= 0xdc00 && c <= 0xdfff;
}

BOOL IsHighSurrogate(unichar c)
{
    // http://en.wikipedia.org/wiki/Mapping_of_Unicode_characters#Surrogates
    return c >= 0xd800 && c <= 0xdbff;
}

NSString* ScreenCharArrayToString(screen_char_t* screenChars,
                                  int start,
                                  int end,
                                  unichar** backingStorePtr,
                                  int** deltasPtr) {
    const int lineLength = end - start;
    unichar* charHaystack = iTermMalloc(sizeof(unichar) * lineLength * kMaxParts + 1);
    *backingStorePtr = charHaystack;
    int* deltas = iTermMalloc(sizeof(int) * (lineLength * kMaxParts + 1));
    *deltasPtr = deltas;
    // The 'deltas' array gives the difference in position between the screenChars
    // and the charHaystack. The formula to convert an index in the charHaystack
    // 'i' into an index in the screenChars 'r' is:
    //     r = i + deltas[i]
    //
    // Array of screen_char_t with some double-width characters, where DWC_RIGHT is
    // shown as '-', and d & f have combining marks/surrogate pairs (not shown here):
    // 0123456789
    // ab-c-de-fg
    //
    // charHaystack, with combining marks/low surrogates shown as '*':
    // 0123456789A
    // abcd**ef**g
    //
    // Mapping:
    // charHaystack index i -> screenChars index  deltas[i]
    // 0 -> 0   (a@0->a@0)                        0
    // 1 -> 1   (b@1->b-@1)                       0
    // 2 -> 3   (c@2->c-@3)                       1
    // 3 -> 5   (d@3->d@5)                        2
    // 4 -> 5   (*@4->d@5)                        1
    // 5 -> 5   (*@5->d@5)                        0
    // 6 -> 6   (e@6->e-@6)                       0
    // 7 -> 8   (f@7->f@8)                        1
    // 8 -> 8   (*@8->f@8)                        0
    // 9 -> 8   (*@9->f@8)                       -1
    // A -> 9   (g@A->g@9)                       -1
    //
    // Note that delta is just the difference of the indices.
    //
    // screen_char_t[i + deltas[i]] begins its run at charHaystack[i]
    // CharHaystackIndexToScreenCharTIndex(i) : i + deltas[i]
    int delta = 0;
    int o = 0;
    for (int i = start; i < end; ++i) {
        unichar c = screenChars[i].code;
        if (c >= ITERM2_PRIVATE_BEGIN && c <= ITERM2_PRIVATE_END) {
            // Skip private-use characters which signify things like double-width characters and
            // tab fillers.
            ++delta;
        } else {
            const int len = ExpandScreenChar(&screenChars[i], charHaystack + o);
            ++delta;
            for (int j = o; j < o + len; ++j) {
                deltas[j] = --delta;
            }
            o += len;
        }
    }
    deltas[o] = delta;

    return CharArrayToString(charHaystack, o);
}

NSString* CharArrayToString(unichar* charHaystack, int o)
{
    // I have no idea why NSUnicodeStringEncoding doesn't work, but it has
    // the wrong endianness on x86. Perhaps it's a relic of PPC days? Anyway,
    // LittleEndian seems to work on my x86, and BigEndian works under Rosetta
    // with a ppc-only binary. Oddly, testing for defined(LITTLE_ENDIAN) does
    // not produce the correct results under ppc+Rosetta.
    int encoding;
#if defined(__ppc__) || defined(__ppc64__)
    encoding = NSUTF16BigEndianStringEncoding;
#else
    encoding = NSUTF16LittleEndianStringEncoding;
#endif
    return [[NSString alloc] initWithBytesNoCopy:charHaystack
                                          length:o * sizeof(unichar)
                                        encoding:encoding
                                    freeWhenDone:NO];
}

void DumpScreenCharArray(screen_char_t* screenChars, int lineLength) {
    NSLog(@"%@", ScreenCharArrayToStringDebug(screenChars, lineLength));
}

NSString* ScreenCharArrayToStringDebug(screen_char_t* screenChars,
                                       int lineLength) {
    while (lineLength > 0 && screenChars[lineLength - 1].code == 0) {
        --lineLength;
    }
    NSMutableString* result = [NSMutableString stringWithCapacity:lineLength];
    for (int i = 0; i < lineLength; ++i) {
        unichar c = screenChars[i].code;
        if (c != 0 && c != DWC_RIGHT) {
            [result appendString:ScreenCharToStr(&screenChars[i]) ?: @"😮"];
        }
    }
    return result;
}

int EffectiveLineLength(screen_char_t* theLine, int totalLength) {
    for (int i = totalLength - 1; i >= 0; i--) {
        if (theLine[i].complexChar || theLine[i].code) {
            return i + 1;
        }
    }
    return 0;
}

NSString *DebugStringForScreenChar(screen_char_t c) {
    NSArray *modes = @[ @"default", @"selected", @"altsem", @"altsem-reversed" ];
    return [NSString stringWithFormat:@"code=%x (%@) foregroundColor=%@ fgGreen=%@ fgBlue=%@ backgroundColor=%@ bgGreen=%@ bgBlue=%@ foregroundColorMode=%@ backgroundColorMode=%@ complexChar=%@ bold=%@ faint=%@ italic=%@ blink=%@ underline=%@ underlineStyle=%@ strikethrough=%@ image=%@ invisible=%@ inverse=%@ guarded=%@ unused=%@",
            (int)c.code,
            ScreenCharToStr(&c),
            @(c.foregroundColor),
            @(c.fgGreen),
            @(c.fgBlue),
            @(c.backgroundColor),
            @(c.bgGreen),
            @(c.bgBlue),
            modes[c.foregroundColorMode],
            modes[c.backgroundColorMode],
            @(c.complexChar),
            @(c.bold),
            @(c.faint),
            @(c.italic),
            @(c.blink),
            @(c.underline),
            @(c.underlineStyle),
            @(c.strikethrough),
            @(c.image),
            @(c.invisible),
            @(c.inverse),
            @(c.guarded),
            @(c.unused)];
}

// Convert a string into an array of screen characters, dealing with surrogate
// pairs, combining marks, nonspacing marks, and double-width characters.
void StringToScreenChars(NSString *s,
                         screen_char_t *buf,
                         screen_char_t fg,
                         screen_char_t bg,
                         int *len,
                         BOOL ambiguousIsDoubleWidth,
                         int* cursorIndex,
                         BOOL *foundDwc,
                         iTermUnicodeNormalization normalization,
                         NSInteger unicodeVersion) {
    __block NSInteger j = 0;
    __block BOOL foundCursor = NO;
    NSCharacterSet *ignorableCharacters = [NSCharacterSet ignorableCharactersForUnicodeVersion:unicodeVersion];
    NSCharacterSet *spacingCombiningMarks = [NSCharacterSet spacingCombiningMarksForUnicodeVersion:12];

    [s enumerateComposedCharacters:^(NSRange range,
                                     unichar baseBmpChar,
                                     NSString *composedOrNonBmpChar,
                                     BOOL *stop) {
        if (cursorIndex && !foundCursor && NSLocationInRange(*cursorIndex, range)) {
            foundCursor = YES;
            *cursorIndex = j;
        }

        BOOL isDoubleWidth = NO;
        BOOL spacingCombiningMark = NO;
        InitializeScreenChar(buf + j, fg, bg);

        // Set the code and the complex flag. Also return early if no cell should be used by this
        // grapheme cluster. Set the isDoubleWidth flag.
        if (!composedOrNonBmpChar) {
            if (baseBmpChar == 0x200c && j > 0) {
                // Zero-width non-joiner. Although this is default ignorable we don't want to ignore it becuse
                // otherwise a ligature could be formed at drawing time.
                AppendToChar(&buf[j - 1], baseBmpChar);
                return;
            }
            if ([ignorableCharacters characterIsMember:baseBmpChar]) {
                return;
            } else if ([spacingCombiningMarks characterIsMember:baseBmpChar]) {
                composedOrNonBmpChar = [NSString stringWithLongCharacter:baseBmpChar];
                baseBmpChar = 0;
                spacingCombiningMark = YES;
            } else if (baseBmpChar >= ITERM2_PRIVATE_BEGIN && baseBmpChar <= ITERM2_PRIVATE_END) {
                // Convert private range characters into the replacement character.
                baseBmpChar = UNICODE_REPLACEMENT_CHAR;
            } else if (IsLowSurrogate(baseBmpChar)) {
                // Low surrogate without high surrogate.
                baseBmpChar = UNICODE_REPLACEMENT_CHAR;
            } else if (IsHighSurrogate(baseBmpChar) && NSMaxRange(range) != s.length) {
                // High surrogate not followed by low surrogate.
                baseBmpChar = UNICODE_REPLACEMENT_CHAR;
            }
            if (!composedOrNonBmpChar) {
                buf[j].code = baseBmpChar;
                buf[j].complexChar = NO;

                isDoubleWidth = [NSString isDoubleWidthCharacter:baseBmpChar
                                          ambiguousIsDoubleWidth:ambiguousIsDoubleWidth
                                                  unicodeVersion:unicodeVersion];
            }
        }
        if (composedOrNonBmpChar) {
            const NSUInteger composedLength = composedOrNonBmpChar.length;
            // Ensure the string is not longer than what we support.
            if (composedLength > kMaxParts) {
                composedOrNonBmpChar = [composedOrNonBmpChar substringToIndex:kMaxParts];

                // Ensure a high surrogate isn't left dangling at the end.
                if (CFStringIsSurrogateHighCharacter([composedOrNonBmpChar characterAtIndex:kMaxParts - 1])) {
                    composedOrNonBmpChar = [composedOrNonBmpChar substringToIndex:kMaxParts - 1];
                }
            }
            SetComplexCharInScreenChar(buf + j, composedOrNonBmpChar, normalization, spacingCombiningMark);
            NSInteger next = 1;
            UTF32Char baseChar = [composedOrNonBmpChar characterAtIndex:0];
            if (IsHighSurrogate(baseChar) && composedLength > 1) {
                baseChar = DecodeSurrogatePair(baseChar, [composedOrNonBmpChar characterAtIndex:1]);
                next += 1;
                if (composedLength == 2 && [ignorableCharacters longCharacterIsMember:baseChar]) {
                    return;
                }
            }
            isDoubleWidth = [NSString isDoubleWidthCharacter:baseChar
                                      ambiguousIsDoubleWidth:ambiguousIsDoubleWidth
                                              unicodeVersion:unicodeVersion];
            if (!isDoubleWidth && composedLength > next) {
                const unichar peek = [composedOrNonBmpChar characterAtIndex:next];
                if (peek == 0xfe0f) {
                    // VS16
                    if ([[NSCharacterSet emojiAcceptingVS16] characterIsMember:baseChar] &&
                        [iTermAdvancedSettingsModel vs16Supported]) {
                        isDoubleWidth = YES;
                    }
                }
            }
        }

        // Append a DWC_RIGHT if the base character is double-width.
        if (isDoubleWidth) {
            j++;
            buf[j] = buf[j - 1];
            buf[j].code = DWC_RIGHT;
            buf[j].complexChar = NO;
            if (foundDwc) {
                *foundDwc = YES;
            }
        }

        j++;
    }];
    *len = j;
    if (cursorIndex && !foundCursor && *cursorIndex >= s.length) {
        // We were asked for the position of the cursor to the right
        // of the last character.
        *cursorIndex = j;
    }
}

void InitializeScreenChar(screen_char_t *s, screen_char_t fg, screen_char_t bg) {
    s->code = 0;
    s->complexChar = NO;

    s->foregroundColor = fg.foregroundColor;
    s->fgGreen = fg.fgGreen;
    s->fgBlue = fg.fgBlue;

    s->backgroundColor = bg.backgroundColor;
    s->bgGreen = bg.bgGreen;
    s->bgBlue = bg.bgBlue;

    s->foregroundColorMode = fg.foregroundColorMode;
    s->backgroundColorMode = bg.backgroundColorMode;

    s->bold = fg.bold;
    s->faint = fg.faint;
    s->italic = fg.italic;
    s->blink = fg.blink;
    s->invisible = fg.invisible;
    s->underline = fg.underline;
    s->strikethrough = fg.strikethrough;
    s->underlineStyle = fg.underlineStyle;
    s->image = NO;
    s->inverse = fg.inverse;
    s->guarded = fg.guarded;
    s->unused = 0;
}

void ConvertCharsToGraphicsCharset(screen_char_t *s, int len)
{
    int i;

    for (i = 0; i < len; i++) {
        assert(!s[i].complexChar);
        s[i].complexChar = NO;
        s[i].code = charmap[(int)(s[i].code)];
    }
}

NSInteger ScreenCharGeneration(void) {
    return gScreenCharGeneration;
}

NSDictionary *ScreenCharEncodedRestorableState(void) {
    return @{ kScreenCharComplexCharMapKey: complexCharMap ?: @{},
              kScreenCharSpacingCombiningMarksKey: spacingCombiningMarkCodeNumbers.allObjects ?: @[],
              kScreenCharInverseComplexCharMapKey: inverseComplexCharMap ?: @{},
              kScreenCharImageMapKey: gEncodableImageMap ?: @{},
              kScreenCharCCMNextKeyKey: @(ccmNextKey),
              kScreenCharHasWrappedKey: @(hasWrapped) };
}

void ScreenCharGarbageCollectImages(void) {
    NSArray<NSNumber *> *provisionalKeys = [gImages.allKeys filteredArrayUsingBlock:^BOOL(NSNumber *key) {
        return gImages[key].provisional;
    }];
    DLog(@"Garbage collect: %@", provisionalKeys);
    [gImages removeObjectsForKeys:provisionalKeys];
}

void ScreenCharClearProvisionalFlagForImageWithCode(int code) {
    DLog(@"Clear provisional for %@", @(code));
    gImages[@(code)].provisional = NO;
}

void ScreenCharDecodeRestorableState(NSDictionary *state) {
    NSDictionary *stateComplexCharMap = state[kScreenCharComplexCharMapKey];
    CreateComplexCharMapIfNeeded();
    for (id key in stateComplexCharMap) {
        if (!complexCharMap[key]) {
            complexCharMap[key] = stateComplexCharMap[key];
        }
    }
    NSArray<NSString *> *spacingCombiningMarksArray = state[kScreenCharSpacingCombiningMarksKey];
    for (NSNumber *number in spacingCombiningMarksArray) {
        [spacingCombiningMarkCodeNumbers addObject:number];
    }

    NSDictionary *stateInverseMap = state[kScreenCharInverseComplexCharMapKey];
    for (id key in stateInverseMap) {
        if (!inverseComplexCharMap[key]) {
            inverseComplexCharMap[key] = stateInverseMap[key];
        }
    }
    NSDictionary *imageMap = state[kScreenCharImageMapKey];
    AllocateImageMapsIfNeeded();
    for (id key in imageMap) {
        gEncodableImageMap[key] = imageMap[key];
        iTermImageInfo *info = [[iTermImageInfo alloc] initWithDictionary:imageMap[key]];
        if (info) {
            info.provisional = YES;
            gImages[key] = info;
            DLog(@"Decoded restorable state for image %@: %@", key, info);
        }
    }
    ccmNextKey = [state[kScreenCharCCMNextKeyKey] intValue];
    hasWrapped = [state[kScreenCharHasWrappedKey] boolValue];
}

static NSString *ScreenCharColorDescription(unsigned int red,
                                            unsigned int green,
                                            unsigned int blue,
                                            ColorMode mode,
                                            BOOL fg) {
    switch (mode) {
        case ColorModeAlternate:
            switch (red) {
                case ALTSEM_DEFAULT:
                    return fg ? @"Default fg" : @"Default bg";
                case ALTSEM_SELECTED:
                    return @"Selected";
                case ALTSEM_CURSOR:
                    return @"Cursor";
                case ALTSEM_REVERSED_DEFAULT:
                    return fg ? @"Default bg" : @"Default fg";
                case ALTSEM_SYSTEM_MESSAGE:
                    return @"System";
            }
            return @"Invalid";

        case ColorModeNormal:
            if (red < 16) {
                NSString *color = @"";
                NSArray<NSString *> *names = @[ @"Black", @"Red", @"Green", @"Yellow", @"Blue",
                                                @"Magenta", @"Cyan", @"White" ];
                if (red > 7) {
                    color = [color stringByAppendingString:@"ANSI Bright "];
                }
                color = [color stringByAppendingString:names[red & 7]];
                return color;
            }
            if (red < 232) {
                const int r = (red - 16) / 36;
                const int g = ((red - 16) - r*36) / 6;
                const int b = ((red - 16) - r*36 - g*6);
                return [NSString stringWithFormat:@"8bit(%@/5,%@/5,%@/5)", @(r), @(g), @(b)];
            }
            const int gray = red-232;
            return [NSString stringWithFormat:@"gray%@/22", @(gray)];
        case ColorMode24bit:
            return [NSString stringWithFormat:@"24bit(%@,%@,%@)", @(red), @(green), @(blue)];
        case ColorModeInvalid:
            return @"Invalid";
    }
    return @"Invalid";
}

NSString *VT100TerminalColorValueDescription(VT100TerminalColorValue value, BOOL fg) {
    return ScreenCharColorDescription(value.red, value.green, value.blue, value.mode, fg);
}

NSString *ScreenCharDescription(screen_char_t c) {
    if (c.image) {
        return nil;
    }
    NSMutableArray<NSString *> *attrs = [NSMutableArray array];
    if (c.bold) {
        [attrs addObject:@"Bold"];
    }
    if (c.faint) {
        [attrs addObject:@"Faint"];
    }
    if (c.italic) {
        [attrs addObject:@"Italic"];
    }
    if (c.blink) {
        [attrs addObject:@"Blink"];
    }
    if (c.invisible) {
        [attrs addObject:@"Invisible"];
    }
    if (c.guarded) {
        [attrs addObject:@"Guarded"];
    }
    if (c.underline) {
        switch (c.underlineStyle) {
            case VT100UnderlineStyleSingle:
                [attrs addObject:@"Underline"];
                break;
            case VT100UnderlineStyleCurly:
                [attrs addObject:@"Curly-Underline"];
                break;
            case VT100UnderlineStyleDouble:
                [attrs addObject:@"Double-Underline"];
                break;
        }
    }
    if (c.strikethrough) {
        [attrs addObject:@"Strike"];
    }
    if (c.inverse) {
        [attrs addObject:@"Inverse"];
    }
    NSString *style = [attrs componentsJoinedByString:@" "];
    if (style.length) {
        style = [@"; " stringByAppendingString:style];
    }
    return [NSString stringWithFormat:@"fg=%@ bg=%@%@",
            ScreenCharColorDescription(c.foregroundColor,
                                       c.fgGreen,
                                       c.fgBlue,
                                       c.foregroundColorMode,
                                       YES),
            ScreenCharColorDescription(c.backgroundColor,
                                       c.bgGreen,
                                       c.bgBlue,
                                       c.backgroundColorMode,
                                       NO),
            style];
}

void ScreenCharInvert(screen_char_t *c) {
    const screen_char_t saved = *c;

    c->foregroundColorMode = saved.backgroundColorMode;
    if (saved.backgroundColorMode == ColorModeAlternate &&
        saved.backgroundColor == ALTSEM_DEFAULT) {
        c->foregroundColor = ALTSEM_REVERSED_DEFAULT;
    } else if (saved.backgroundColorMode == ColorModeAlternate &&
               saved.backgroundColor == ALTSEM_REVERSED_DEFAULT) {
        c->foregroundColor = ALTSEM_DEFAULT;
    } else {
        c->foregroundColor = saved.backgroundColor;
    }
    c->fgGreen = saved.bgGreen;
    c->fgBlue = saved.bgBlue;

    c->backgroundColorMode = saved.foregroundColorMode;
    if (saved.foregroundColorMode == ColorModeAlternate &&
        saved.foregroundColor == ALTSEM_REVERSED_DEFAULT) {
        c->backgroundColor = ALTSEM_DEFAULT;
    } else if (saved.foregroundColorMode == ColorModeAlternate &&
               saved.foregroundColor == ALTSEM_DEFAULT) {
        c->backgroundColor = ALTSEM_REVERSED_DEFAULT;
    } else {
        c->backgroundColor = saved.foregroundColor;
    }
    c->bgGreen = saved.fgGreen;
    c->bgBlue = saved.fgBlue;
    
    c->inverse = !c->inverse;
}
