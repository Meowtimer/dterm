//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

#import "DTResultsTextView.h"
#import "DTerm-Swift.h"

@implementation DTResultsTextView

@synthesize disableAntialiasing;

+ (void)initialize {
	[DTResultsTextView exposeBinding:@"resultsStorage"];
	[DTResultsTextView exposeBinding:@"disableAntialiasing"];
}

- (void)awakeFromNib {
	[[self layoutManager] replaceTextStorage:[[NSTextStorage alloc] init]];
	
	[self bind:@"disableAntialiasing"
	  toObject:[NSUserDefaultsController sharedUserDefaultsController]
   withKeyPath:@"values.DTDisableAntialiasing"
	   options:[NSDictionary dictionaryWithObjectsAndKeys:
				[NSNumber numberWithBool:NO], NSNullPlaceholderBindingOption,
				nil]];
}

- (void)setDisableAntialiasing:(BOOL)b {
	disableAntialiasing = b;
	[self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)aRect {
    NSGraphicsContext *currentContext = [NSGraphicsContext currentContext];
	
	if(disableAntialiasing) {
		[currentContext saveGraphicsState];
		[currentContext setShouldAntialias:NO];
	}
	
    [super drawRect:aRect];
	
	if(disableAntialiasing)
		[currentContext restoreGraphicsState];
}

- (NSTextStorage*)resultsStorage {
	if(validResultsStorage)
		return [[self layoutManager] textStorage];
	else
		return nil;
}

- (void)setResultsStorage:(NSTextStorage*)newResults {
//	NSLog(@"setResultsStorage: %@", newResults);
	if(validResultsStorage)
		[[NSNotificationCenter defaultCenter] removeObserver:self name:NSTextStorageDidProcessEditingNotification object:[self resultsStorage]];
	
	
	validResultsStorage = (newResults != nil);
	if(newResults) {
		[[self layoutManager] replaceTextStorage:newResults];
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(dtTextChanged:)
													 name:NSTextStorageDidProcessEditingNotification
												   object:newResults];
	} else {
		[[self layoutManager] replaceTextStorage:[[NSTextStorage alloc] init]];
	}
	
	[self dtSizeToFit];
}

- (void)dtTextChanged:(NSNotification*)ntf {
//	NSLog(@"dtTextChanged called: %@, %@", ntf, [self string]);

//	-- Commenting this stuff out because we don't have a good way to tell here if 
//	-- we were already scrolled at the bottom, and we don't want to force scroll
//	-- to the bottom otherwise
//	NSPoint newScrollOrigin;
//	
//	NSScrollView* scrollview = [self enclosingScrollView];
//	if ([[scrollview documentView] isFlipped]) {
//		newScrollOrigin=NSMakePoint(0.0,NSMaxY([[scrollview documentView] frame])
//									-NSHeight([[scrollview contentView] bounds]));
//	} else {
//		newScrollOrigin=NSMakePoint(0.0,0.0);
//	}
//	[[scrollview documentView] scrollPoint:newScrollOrigin];
	
	// There's a bunch of spurious empty string sets done by bindings :-/
	// We don't want to shrink-grow-shrink-grow during a continual grow
	// Smooth things out by only resizing when things have been unchanged for 1/10s
	
	if(![sizeToFitTimer isValid]) {
		sizeToFitTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
														  target:self
														selector:@selector(dtSizeToFit)
														userInfo:nil
														 repeats:NO];
	}
}

// From http://www.cocoadev.com/index.pl?NSTextViewSizeToFit
- (NSSize)minSizeForContent {
	NSLayoutManager *layoutManager = [self layoutManager];
	NSTextContainer *textContainer = [self textContainer];
	
	[layoutManager boundingRectForGlyphRange:NSMakeRange(0, [layoutManager numberOfGlyphs]) inTextContainer:textContainer]; // dummy call to force layout
	NSRect usedRect = [layoutManager usedRectForTextContainer:textContainer];
	NSSize inset = [self textContainerInset];
	
	return NSInsetRect(usedRect, -inset.width * 2, -inset.height * 2).size;
}

- (CGFloat)desiredHeightChange {
	NSSize currentSize = [[self enclosingScrollView] contentSize];
	NSSize newSize = NSMakeSize(currentSize.width, [self minSizeForContent].height);
	
	return newSize.height - currentSize.height;
}

- (void)dtSizeToFit {
	CGFloat dHeight = [self desiredHeightChange];
	if(dHeight != 0.0)
		[(DTTermWindowController*)[[self window] windowController] requestWindowHeightChange:dHeight];
}

- (void)viewDidMoveToWindow {
	[self dtSizeToFit];
}


@end
