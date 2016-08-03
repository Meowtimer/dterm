//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.


@interface DTResultsTextView : NSTextView {
	BOOL validResultsStorage;
	NSTimer* sizeToFitTimer;
	
	BOOL disableAntialiasing;
}

@property BOOL disableAntialiasing;
@property NSTextStorage* resultsStorage;

- (NSSize)minSizeForContent;
- (CGFloat)desiredHeightChange;
- (void)dtSizeToFit;

@end
