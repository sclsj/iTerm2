//
//  iTermTextExtractor.h
//  iTerm
//
//  Created by George Nachman on 2/17/14.
//
//

#import <Foundation/Foundation.h>
#import "iTermLocatedString.h"
#import "ScreenChar.h"
#import "SmartMatch.h"
#import "PTYTextViewDataSource.h"

typedef NS_ENUM(NSInteger, iTermTextExtractorClass) {
    // Any kind of white space.
    kTextExtractorClassWhitespace,

    // Characters that belong to a word.
    kTextExtractorClassWord,

    // Unset character
    kTextExtractorClassNull,

    // DWC_RIGHT or DWC_SKIP
    kTextExtractorClassDoubleWidthPlaceholder,

    // Non-alphanumeric, non-whitespace, non-word, not double-width filler.
    // Miscellaneous symbols, etc.
    kTextExtractorClassOther
};

typedef NS_ENUM(NSInteger, iTermTextExtractorNullPolicy) {
    kiTermTextExtractorNullPolicyFromStartToFirst,  // Ignore content prior to last null
    kiTermTextExtractorNullPolicyFromLastToEnd,  // Ignore content after last null
    kiTermTextExtractorNullPolicyTreatAsSpace,  // Treat midline nulls as spaces and a range of terminal nulls as a single space
    kiTermTextExtractorNullPolicyMidlineAsSpaceIgnoreTerminal,  // Treat midline nulls as space and strip terminal nulls
};

// Suggested word lengths for rangeForWordAt:maximumLength:
extern const NSInteger kReasonableMaximumWordLength;
extern const NSInteger kLongMaximumWordLength;

@interface iTermTextExtractor : NSObject

@property(nonatomic, assign) VT100GridRange logicalWindow;
@property(nonatomic, readonly) BOOL hasLogicalWindow;
@property(nonatomic, weak, readonly) id<iTermTextDataSource> dataSource;

// Characters that divide words.
+ (NSCharacterSet *)wordSeparatorCharacterSet;

+ (instancetype)textExtractorWithDataSource:(id<iTermTextDataSource>)dataSource;
- (instancetype)initWithDataSource:(id<iTermTextDataSource>)dataSource;
- (void)restrictToLogicalWindowIncludingCoord:(VT100GridCoord)coord;

// Returns the range of a word (string of characters belonging to the same class) at a location. If
// there is a paren or paren-like character at location, it tries to return the range of the
// parenthetical, even if there are mixed classes. Returns (-1, -1, -1, -1) if location is out of
// bounds. The maximum length is only approximate. See the suggested constants above.
- (VT100GridWindowedRange)rangeForWordAt:(VT100GridCoord)location
                           maximumLength:(NSInteger)maximumLength;
- (VT100GridAbsWindowedRange)rangeForWordAtAbsCoord:(VT100GridAbsCoord)absLocation
                                      maximumLength:(NSInteger)maximumLength;

// A big word is delimited by whitespace.
- (VT100GridWindowedRange)rangeForBigWordAt:(VT100GridCoord)location
                              maximumLength:(NSInteger)maximumLength;
- (VT100GridAbsWindowedRange)rangeForBigWordAtAbsCoord:(VT100GridAbsCoord)location
                                         maximumLength:(NSInteger)maximumLength;

// Returns the string for the character at a screen location.
- (NSString *)stringForCharacterAt:(VT100GridCoord)location;
- (NSString *)stringForCharacter:(screen_char_t)theChar;

// Uses the provided smart selection |rules| to perform a smart selection at |location|. If
// |actionRequired| is set then rules without an action are ignored. If a rule is matched, it is
// returned and |range| is set to the range of matching characters. The returned match will be
// populated and the matching text will be in smartMatch.components[0].
- (SmartMatch *)smartSelectionAt:(VT100GridCoord)location
                       withRules:(NSArray *)rules
                  actionRequired:(BOOL)actionRequired
                           range:(VT100GridWindowedRange *)range
                ignoringNewlines:(BOOL)ignoringNewlines;

// Returns the range of the whole wrapped line including |coord|.
- (VT100GridWindowedRange)rangeForWrappedLineEncompassing:(VT100GridCoord)coord
                                     respectContinuations:(BOOL)respectContinuations
                                                 maxChars:(int)maxChars;

// Returns the class for a character.
- (iTermTextExtractorClass)classForCharacter:(screen_char_t)theCharacter;

// If the character at |location| is a paren, brace, or bracket, and there is a matching
// open/close paren/brace/bracket, the range from the opening to closing paren/brace/bracket is
// returned. If that is not the case, then (-1, -1, -1, -1) is returned.
- (VT100GridWindowedRange)rangeOfParentheticalSubstringAtLocation:(VT100GridCoord)location;

// Returns next/previous coordinate. Returns first/last legal coord if none exists.
- (VT100GridCoord)successorOfCoord:(VT100GridCoord)coord;
// Won't go past the end of the line while skipping nulls.
- (VT100GridCoord)successorOfCoordSkippingContiguousNulls:(VT100GridCoord)coord;
- (VT100GridAbsCoord)successorOfAbsCoordSkippingContiguousNulls:(VT100GridAbsCoord)coord;

- (VT100GridCoord)predecessorOfCoord:(VT100GridCoord)coord;
// Won't go past the start of the line while skipping nulls.
- (VT100GridCoord)predecessorOfCoordSkippingContiguousNulls:(VT100GridCoord)coord;
- (VT100GridAbsCoord)predecessorOfAbsCoordSkippingContiguousNulls:(VT100GridAbsCoord)coord;

// Advances coord by a positive or negative delta, staying within the column window, if any. Any
// indices in |coordsToSkip| will not count against delta.
// Forward disambiguates the direction to skip over |coordsToSkip| if delta is zero.
- (VT100GridCoord)coord:(VT100GridCoord)coord
                   plus:(int)delta
         skippingCoords:(NSIndexSet *)coordsToSkip
                forward:(BOOL)forward;

// block should return YES to stop searching and use the coordinate it was passed as the result.
- (VT100GridCoord)searchFrom:(VT100GridCoord)start
                     forward:(BOOL)forward
      forCharacterMatchingFilter:(BOOL (^)(screen_char_t, VT100GridCoord))block;

- (BOOL)haveNonWhitespaceInFirstLineOfRange:(VT100GridWindowedRange)windowedRange;

- (NSAttributedString *)attributedStringForSnippetForRange:(VT100GridAbsCoordRange)range
                                         regularAttributes:(NSDictionary *)regularAttributes
                                           matchAttributes:(NSDictionary *)matchAttributes
                                       maximumPrefixLength:(NSUInteger)maximumPrefixLength
                                       maximumSuffixLength:(NSUInteger)maximumSuffixLength;

// Returns content in the specified range, ignoring hard newlines. If |forward| is set then content
// is captured up to the first null; otherwise, content after the last null in the range is returned.
// If |continuationChars| is non-nil and a character that should be ignored is found, its location
// will be added to |continuationChars|. Currently the only skippable character is a \ in the
// rightmost column when there is a software-drawn divider (see issue 3067).
//
// Returns an NSString* if |attributeProvider| is nil. Returns an NSAttributedString* otherwise.
//
// If |coords| is non-nil it will be filled with NSValue*s in 1:1 correspondence with characters in
// the return value, giving VT100GridCoord's with their provenance.
//
// if |maxBytes| is positive then the result will not exceed that size. |truncateTail| determines
// whether the tail or head of the string is shortened to fit.
- (id)contentInRange:(VT100GridWindowedRange)range
   attributeProvider:(NSDictionary *(^)(screen_char_t, iTermExternalAttribute *))attributeProvider
          nullPolicy:(iTermTextExtractorNullPolicy)nullPolicy
                 pad:(BOOL)pad
  includeLastNewline:(BOOL)includeLastNewline
    trimTrailingWhitespace:(BOOL)trimSelectionTrailingSpaces
              cappedAtSize:(int)maxBytes
        truncateTail:(BOOL)truncateTail
         continuationChars:(NSMutableIndexSet *)continuationChars
              coords:(NSMutableArray *)coords;

// Returns an iTermLocated[Attributed]String
- (id)locatedStringInRange:(VT100GridWindowedRange)range
         attributeProvider:(NSDictionary *(^)(screen_char_t, iTermExternalAttribute *))attributeProvider
                nullPolicy:(iTermTextExtractorNullPolicy)nullPolicy
                       pad:(BOOL)pad
        includeLastNewline:(BOOL)includeLastNewline
    trimTrailingWhitespace:(BOOL)trimSelectionTrailingSpaces
              cappedAtSize:(int)maxBytes
              truncateTail:(BOOL)truncateTail
         continuationChars:(NSMutableIndexSet *)continuationChars;

- (NSIndexSet *)indexesOnLine:(int)line containingCharacter:(unichar)c inRange:(NSRange)range;

- (int)lengthOfLine:(int)line;
- (int)lengthOfAbsLine:(long long)absLine;

- (void)enumerateCharsInRange:(VT100GridWindowedRange)range
                    charBlock:(BOOL (^NS_NOESCAPE)(screen_char_t *currentLine, screen_char_t theChar, iTermExternalAttribute *, VT100GridCoord coord))charBlock
                     eolBlock:(BOOL (^NS_NOESCAPE)(unichar code, int numPreceedingNulls, int line))eolBlock;

- (void)enumerateWrappedLinesIntersectingRange:(VT100GridRange)range
                                         block:(void (^)(iTermStringLine *, VT100GridWindowedRange, BOOL *))block;

// Finds text before or at+after |coord|. If |respectHardNewlines|, then the whole wrapped line is
// returned up to/from |coord|. If not, then 10 lines are returned.
// If |continuationChars| is not empty, then it can specify a set of characters (such as \) which
// may occur before the right edge when there is a software-drawn boundary which should be ignored.
// See comment at -contentInRange:nullPolicy:pad:includeLastNewline:trimTrailingWhitespace:cappedAtSize:continuationChars:coords:
// If |convertNullToSpace| is YES then the string does not stop at a NULL character.
//
// If |coords| is non-nil it will be filled with NSValue*s in 1:1 correspondence with characters in
// the return value, giving VT100GridCoord's with their provenance.
- (iTermLocatedString *)wrappedLocatedStringAt:(VT100GridCoord)coord
                                       forward:(BOOL)forward
                           respectHardNewlines:(BOOL)respectHardNewlines
                                      maxChars:(int)maxChars
                             continuationChars:(NSMutableIndexSet *)continuationChars
                           convertNullsToSpace:(BOOL)convertNullsToSpace;

- (ScreenCharArray *)combinedLinesInRange:(NSRange)range;

- (screen_char_t)characterAt:(VT100GridCoord)coord;
- (screen_char_t)characterAtAbsCoord:(VT100GridAbsCoord)coord;

- (iTermExternalAttribute *)externalAttributesAt:(VT100GridCoord)coord;

// Returns a subset of `range` by removing leading and trailing whitespace.
- (VT100GridAbsCoordRange)rangeByTrimmingWhitespaceFromRange:(VT100GridAbsCoordRange)range;

typedef NS_ENUM(NSUInteger, iTermTextExtractorTrimTrailingWhitespace) {
    // Do not trim any trailing whitespace.
    iTermTextExtractorTrimTrailingWhitespaceNone,

    // Trim all trailing whitespace.
    iTermTextExtractorTrimTrailingWhitespaceAll,

    // Trim only the trailing newline and whitespace just before it on the last line.
    iTermTextExtractorTrimTrailingWhitespaceOneLine
};
- (VT100GridAbsCoordRange)rangeByTrimmingWhitespaceFromRange:(VT100GridAbsCoordRange)range
                                                     leading:(BOOL)leading
                                                    trailing:(iTermTextExtractorTrimTrailingWhitespace)trailing;

// Checks if two coordinates are equal. Either they are the same coordinate or they are adjacent
// on the same DWC.
- (BOOL)coord:(VT100GridCoord)coord1 isEqualToCoord:(VT100GridCoord)coord2;

// Gets the word at a location. Doesn't sweat fancy word segmentation, and won't return anything
// terribly long. Also uses a stricter definition of what characters can be in a word, excluding
// all punctuation except -.
- (NSString *)fastWordAt:(VT100GridCoord)location;

- (NSURL *)urlOfHypertextLinkAt:(VT100GridCoord)coord urlId:(out NSString **)urlId;

// Searches before and after `coord` until a coordinate is found that does not pass the test.
// Returns the resulting range.
- (VT100GridWindowedRange)rangeOfCoordinatesAround:(VT100GridCoord)coord
                                   maximumDistance:(int)maximumDistance
                                       passingTest:(BOOL(^)(screen_char_t *c,
                                                            iTermExternalAttribute *ea,
                                                            VT100GridCoord coord))block;

- (int)startOfIndentationOnLine:(int)line;
- (int)startOfIndentationOnAbsLine:(long long)absLine;

#pragma mark - For tests

- (NSInteger)indexInSortedArray:(NSArray<NSNumber *> *)indexes
     withValueLessThanOrEqualTo:(NSInteger)maximumValue
          searchingBackwardFrom:(NSInteger)start;

@end
