//  Copyright (c) 2007-2010 Decimus Software, Inc. All rights reserved.

#import "DTShellUtilities.h"
#import "ScriptingBridge/ScriptingBridge.h"
#import "iTerm.h"
#import "Terminal.h"
#import "DTerm-Swift.h"

static NSCharacterSet* charactersToEscape() {
	static NSCharacterSet* charactersToEscape = nil;
	if(!charactersToEscape) {
		charactersToEscape = [NSCharacterSet characterSetWithCharactersInString:@" ()[]{}<>|!?$&~^*`';\\\t\"\x1b"];
	}
	return charactersToEscape;
}

NSString* escapedPath(NSString* path) {
	NSCharacterSet* charsToEscape = charactersToEscape();
	
	NSMutableString* escapedPath = [NSMutableString stringWithCapacity:[path length]];
	for(NSUInteger i=0; i<[path length]; i++) {
		unichar ch = [path characterAtIndex:i];
		
		if([charsToEscape characterIsMember:ch])
			[escapedPath appendString:@"\\"];
		[escapedPath appendFormat:@"%C", ch];
	}
	
	return escapedPath;
}

// If any characters that would need to be escaped aren't, we return nil
// They'll be processed by the shell anyway, so there's not much we can do with it
NSString* unescapedPath(NSString* path) {
//	NSLog(@"unescaping %@", path);
	NSCharacterSet* charsToEscape = charactersToEscape();
	
	BOOL lastCharWasBackslash = NO;
	
	NSMutableString* unescapedPath = [NSMutableString stringWithCapacity:[path length]];
	for(NSUInteger i=0; i<[path length]; i++) {
		unichar ch = [path characterAtIndex:i];
		
		if((ch != '\\') && [charsToEscape characterIsMember:ch] && !lastCharWasBackslash) {
//			NSLog(@"%C at %d was the offender, prev char %C", ch, i, [path characterAtIndex:i-1]);
			return nil;
		}
			

		if(lastCharWasBackslash) {
			[unescapedPath appendFormat:@"%C", ch];
			lastCharWasBackslash = NO;
		} else if(ch == '\\') {
			lastCharWasBackslash = YES;
		} else {
			[unescapedPath appendFormat:@"%C", ch];
		}
			
	}
	
	return unescapedPath;
}

NSRange lastShellWordBeforeIndex(NSString* command, NSUInteger index) {
	// Otherwise, we need to parse this for escapes and whatnot to find unescaped spaces
	NSRange completionRange = NSMakeRange(0, index);
	BOOL inSingleQuotedString = NO;
	BOOL inDoubleQuotedString = NO;
	BOOL lastCharWasBackslash = NO;
	
	for(NSUInteger i=0; i<index; i++) {
		unichar ch = [command characterAtIndex:i];	// The literal character in the string
		
		if(inSingleQuotedString) {
			// No escapes allowed
			if(ch == '\'') {
				// End the string on a ' character
				inSingleQuotedString = NO;
				// No logical thing to try and complete right after a quoted string
				completionRange.location = NSNotFound;
			}
			// Otherwise, it's not visible to the shell; don't do anything
		} else if(inDoubleQuotedString) {
			if((ch == '"') && !lastCharWasBackslash) {
				// End the string on a " character unless it was escaped
				inDoubleQuotedString = NO;
				// No logical thing to try and complete right after a quoted string
				completionRange.location = NSNotFound;
			}
			// Otherwise, it's not visible to the shell; don't do anything
		} else {
			// Escapes behave normally
			if(lastCharWasBackslash) {
				// If this character was escaped, it wasn't a character for the shell
				lastCharWasBackslash = NO;
			} else if(ch == '"') {
				// Start a double-quoted string
				inDoubleQuotedString = YES;
				// Opening quotes start a new word
				completionRange.location = i+1;
			} else if(ch == '\'') {
				// Start a single-quoted string
				inSingleQuotedString = YES;
				// Opening quotes start a new word
				completionRange.location = i+1;
			} else if(ch == ' ') {
				// This space is visible to the shell; start a new word
				completionRange.location = i+1;
			}
		}
		
		if(lastCharWasBackslash || inSingleQuotedString)
			lastCharWasBackslash = NO;
		else
			lastCharWasBackslash = (ch == '\\');
	}
	
	// If we ended waiting for an escape, don't try and complete
	if(lastCharWasBackslash && !inSingleQuotedString)
		completionRange.location = NSNotFound;
	
	if(completionRange.location == NSNotFound) {
		completionRange.length = 0;
	} else {
		completionRange.length = index - completionRange.location;
	}
	
	return completionRange;
}

void runCommand(NSString* cdCommandString, NSString* command) {
	id iTerm = [SBApplication applicationWithBundleIdentifier:@"net.sourceforge.iTerm"];
	if(!iTerm)
		iTerm = [SBApplication applicationWithBundleIdentifier:@"com.googlecode.iterm2"];
	if(iTerm) {
		id /*iTermTerminal*/ terminal = nil;
		id /*iTermSession*/ session = nil;
		
		if([iTerm isRunning]) {
			// set terminal to (make new terminal at the end of terminals)
			terminal = [[[iTerm classForScriptingClass:@"terminal"] alloc] init];
			[[iTerm terminals] addObject:terminal];
			
			// set session to (make new session at the end of sessions)
			session = [[[iTerm classForScriptingClass:@"session"] alloc] init];
			[[terminal sessions] addObject:session];
		} else {
			// It wasn't running yet, so just use the "current" terminal/session so we don't open more than one
			terminal = [iTerm currentTerminal];
			session = [terminal currentSession];
		}
		
		// set shell to system attribute "SHELL"
		// exec command shell
		[session execCommand:[DTRunManager shellPath]];
		
		// write text "cd ~/whatever"
		[session writeContentsOfFile:nil text:cdCommandString];
		
		// write text "thecommand"
		[session writeContentsOfFile:nil text:command];
		
		[iTerm activate];
	} else {
		TerminalApplication* terminal = [SBApplication applicationWithBundleIdentifier:@"com.apple.Terminal"];
		BOOL terminalAlreadyRunning = [terminal isRunning];
		
		TerminalWindow* frontWindow = [[terminal windows] objectAtIndex:0];
		if(![frontWindow exists])
			frontWindow = nil;
		else
			frontWindow = [frontWindow get];
		
		TerminalTab* tab = nil;
		if(frontWindow) {
			if(!terminalAlreadyRunning) {
				tab = [[frontWindow tabs] objectAtIndex:0];
			} else if(/*terminalUsesTabs*/false) {
				tab = [[[terminal classForScriptingClass:@"tab"] alloc] init];
				[[frontWindow tabs] addObject:tab];
			}
		}
		
		tab = [terminal doScript:cdCommandString in:tab];
		[terminal doScript:command in:tab];
		
		[terminal activate];
	}
}
