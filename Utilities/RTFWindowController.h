//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.


@interface RTFWindowController : NSWindowController {
}

@property (assign) NSString* rtfPath;
@property (assign) NSString* windowTitle;

- (id)initWithRTFFile:(NSString*)_rtfPath;

@end
