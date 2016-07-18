import Foundation
import Cocoa

let DTUserDefault_ShellPath = "ShellPath"
let DTResultsToKeepKey = "DTResultsToKeep"
let DTHotkeyAlsoDeactivatesKey = "DTHotkeyAlsoDeactivates"
let DTShowDockIconKey = "DTShowDockIcon"
let DTTextColorKey = "DTTextColor"
let DTFontNameKey = "DTFontName"
let DTFontSizeKey = "DTFontSize"
let DTDisableAntialiasingKey = "DTDisableAntialiasing"

let ASCII_BS  = Character(UnicodeScalar(0x08))
let ASCII_CR  = Character(UnicodeScalar(0x0D))
let ASCII_ESC = Character(UnicodeScalar(0x1B))

private var shellPath: String?;

@objc public class DTRunManager : NSObject {

    public var workingDirectory: String!
    public var selectedURLStrings: [AnyObject]!
	
	public private(set) var command: String!
	
    public private(set) var resultsStorage: NSTextStorage!
	private var cursorLoc: Int
	
	private var resultString: NSString { return resultsStorage.string as NSString }

    public func setDisplayFont(_ font: NSFont) {
		resultsStorage.beginEditing()
		defer { resultsStorage.endEditing() }
		resultsStorage.addAttribute(NSFontAttributeName, value: font, range: NSMakeRange(0, resultsStorage.length))
		currentAttributes[NSFontAttributeName] = font
	}

    public func setDisplayColor(_ color: NSColor) {
		resultsStorage.beginEditing()
		defer { resultsStorage.endEditing() }
		resultsStorage.addAttribute(NSForegroundColorAttributeName, value: color, range: NSMakeRange(0, resultsStorage.length))
		currentAttributes[NSForegroundColorAttributeName] = color
	}
    
    public static let shellPath: String! = {
		var sharedPath = UserDefaults.standard().string(forKey: DTUserDefault_ShellPath)
		if sharedPath == nil || !sharedPath!.hasPrefix("/") {
			let env = ProcessInfo.processInfo().environment
			sharedPath = env["SHELL"]
		}
		if sharedPath == nil {
			sharedPath = "/bin/bash"
		}
		return sharedPath
	}()

    public class func arguments(toRunCommand command: String) -> [String] {
		let shell = URL(string: shellPath)?.lastPathComponent
		let tail = ["-i", "-c", command]
		return (
			shell == "bash" || shell == "sh" ? ["-l"] + tail :
			tail
		)
	}
	
	private var currentAttributes: [String:AnyObject]
	private var trailingWhitespace: AttributedString?

    public init!(withWorkingDirectory: String, selection: [String], command: String) {
	
		let userDefaults = UserDefaults.standard()
	
		self.resultsStorage = NSTextStorage()
		self.cursorLoc = 0
		self.currentAttributes = [
			NSFontAttributeName: NSFont(
				name: userDefaults.string(forKey: DTFontNameKey)!,
				size: CGFloat(userDefaults.double(forKey: DTFontSizeKey))
			)!,
			NSForegroundColorAttributeName: NSKeyedUnarchiver.unarchiveObject(
				with: userDefaults.data(forKey: DTTextColorKey)!
			)!
		]
		self.workingDirectory = withWorkingDirectory
		self.selectedURLStrings = selection
		self.command = command
		
		let selectedFilesEnvString = selection
			.map { URL(string:$0) }
			.filter { $0?.isFileURL ?? false }
			.map { $0!.path! }
			.joined(separator: " ")
		
		let environmentKey = "DTERM_SELECTED_FILES"
		if selectedFilesEnvString.characters.count > 0 {
			setenv(environmentKey, selectedFilesEnvString, 1)
		} else {
			unsetenv(environmentKey)
		}
		
		self.unprocessedResultsData = []
		
		super.init()
		
		launch()
	}
	
	var task: Task!
	var stdOut: FileHandle!
	var stdErr: FileHandle!
	var unprocessedResultsData: [Character]
	
	func launch() {
		task = Task()
		task.currentDirectoryPath = self.workingDirectory
		task.launchPath = DTRunManager.shellPath
		task.arguments = DTRunManager.arguments(toRunCommand: command)
		
		stdOut = Pipe().fileHandleForReading
		task.standardOutput = stdOut
		
		stdErr = Pipe().fileHandleForReading
		task.standardError = stdErr
		
		let savedEGID = getegid()
		setegid(getgid())
		task.launch()
		setegid(savedEGID)
		
		NotificationCenter.default().addObserver(
			self,
			selector: #selector(readData(notification:)),
			name: FileHandle.readCompletionNotification,
			object: stdOut
		)
		
		NotificationCenter.default().addObserver(
			self,
			selector: #selector(readData(notification:)),
			name: FileHandle.readCompletionNotification,
			object: stdErr
		)
		
		stdOut.readInBackgroundAndNotify()
		stdErr.readInBackgroundAndNotify()
	}
	
	func readData(notification: Notification) {
		let fileHandle = notification.object as! FileHandle
		if fileHandle == stdOut || fileHandle == stdErr, let userInfo = notification.userInfo as? [String:AnyObject] {
			if let data = userInfo[NSFileHandleNotificationDataItem] as? Data where data.count > 0 {
				unprocessedResultsData = unprocessedResultsData + data
				processResultsData()
				fileHandle.readInBackgroundAndNotify()
			} else {
				if fileHandle == stdOut {
					stdOut = nil
				}
				if fileHandle == stdErr {
					stdErr = nil
				}
				if stdOut == nil && stdErr == nil {
					task = nil
					if let termWindowController = (NSApp.delegate as! DTAppController).termWindowController
						where !(
							termWindowController.window?.isVisible ?? false &&
							termWindowController.runsController.selectedObjects.contains { $0 as? NSObject == self ?? false }
						) {
						let lines = self.resultString.components(separatedBy: .newlines)
						var lastLine = lines.last
						if lastLine == nil || lastLine?.characters.count == 0 {
							lastLine = NSLocalizedString("<no results>", comment: "Notification Description")
						}
						let userNotification = NSUserNotification()
						userNotification.title = String(format: NSLocalizedString("Command finished", comment: "Notification Title"), self.command)
						userNotification.informativeText = lastLine
						
						NSUserNotificationCenter.default().deliver(userNotification)
						
						/*
						
						[GrowlApplicationBridge notifyWithTitle:[NSString stringWithFormat:NSLocalizedString(@"Command finished: %@", @"Growl notification title"), self.command]
												description:lastLine 
										   notificationName:@"DTCommandCompleted"
												   iconData:nil 
												   priority:0 
												   isSticky:NO 
											   clickContext:nil];
						
						*/
					}
				}
			}
		}
	}
	
	func processResultsData() {
		guard unprocessedResultsData.count == 0 else { return }
		
		var data = unprocessedResultsData
		let count = data.count
		var index = 0
		var remaining: Int { return count - index }
		
		func at(relativeIndex: Int) -> Character {
			return data[index + relativeIndex]
		}
		
		resultsStorage.beginEditing()
		defer {
			resultsStorage.endEditing()
			if remaining > 0 && remaining != unprocessedResultsData.count {
				unprocessedResultsData = Array(
					unprocessedResultsData[index ..< unprocessedResultsData.endIndex]
				)
			}
		}
		
		// Add our trailing whitespace back on
		if trailingWhitespace?.length > 0 {
			resultsStorage.append(trailingWhitespace!)
		}
		trailingWhitespace = nil
		
		// Process the data
		while index < count {
			let char = data[index]
			switch char {
				// Handle escape sequences
				case ASCII_ESC:
					// If we don't have enough chars for ESC[x (a minimal escape sequence), wait for more data
					guard remaining >= 3 else { break }
					guard at(relativeIndex: 1) == "[" else {
						// Hmmm...malformed ESC sequence without the [...
						// Just pass it through as normal characters, I guess...
						index += 1
						break
					}
				
					// Pull off the ESC[
					index += 2
					
					// Grab ##;###;### sequence
					var lengthOfEscapeString = 0
					func relevant(_ c: Character) -> Bool { return (c >= "0" && c <= "9") || c == ";" }
					while (lengthOfEscapeString < remaining && relevant(at(relativeIndex: lengthOfEscapeString))) {
						lengthOfEscapeString += 1
					}
				
					// If we ate up all of the rest of the string without a terminating char, wait for more data
					if lengthOfEscapeString == remaining {
						index -= 2
						break
					}
				
					let escapeString = String(data[index..<index+lengthOfEscapeString])
					handleEscapeSequenceWithType(type: at(relativeIndex: lengthOfEscapeString), params: escapeString.components(separatedBy: ";"))
				
					index += lengthOfEscapeString + 1
				
				case ASCII_BS:
					cursorLoc += 1
					index += 1
				
				case ASCII_CR:
					index += 1
					// Go back until we find a newline
					while cursorLoc > 0 && resultString.character(at: cursorLoc - 1) == UInt16("\n") {
						cursorLoc -= 1
					}
				
				default:
					// Handle cursor not at end of string
					if cursorLoc != resultString.length {
						let oldChar = Character(UnicodeScalar(resultString.character(at: cursorLoc)))
						let newChar = at(relativeIndex: 0)
						let oneCharacterRange = NSRange(location: cursorLoc, length: 1)
						switch ((oldChar, newChar)) {
							// bold it if they're identical
							case (let x, let y) where x == y:
								resultsStorage.applyFontTraits(
									NSFontTraitMask.boldFontMask,
									range: oneCharacterRange
								)
							// If one is an underscore, underline the other char
							case (let oldChar, let newChar) where oldChar == "_" || newChar == "_":
								if oldChar == "_" {
									// Need to replace the old underscore with the new real char
									resultsStorage.replaceCharacters(
										in: oneCharacterRange,
										with: String(newChar)
									)
								}
								resultsStorage.addAttributes([
									NSUnderlineStyleAttributeName:
										NSUnderlineStyle.styleSingle.rawValue +
										NSUnderlineStyle.patternSolid.rawValue
								], range: oneCharacterRange)
							case (_, "\n"):
								// For newlines, seek forward to the next newline
								while cursorLoc < resultsStorage.length && Character(UnicodeScalar(resultString.character(at: cursorLoc))) != "\n" {
									cursorLoc += 1
								}
								// If we're at the end, we didn't find one, so append one
								if cursorLoc == resultsStorage.length {
									resultsStorage.append(
										AttributedString(string: "\n", attributes: currentAttributes)
									)
								}
							default:
								resultsStorage.replaceCharacters(in: oneCharacterRange, with: String(newChar))
						}
						cursorLoc += 1
						index += 1
					} else {
						var lengthOfNormalString = 0
						func isSpecialCharacter(_ c: Character) -> Bool {
							return c == ASCII_BS || c == ASCII_CR || c == ASCII_ESC
						}
						while lengthOfNormalString < remaining && !isSpecialCharacter(at(relativeIndex: lengthOfNormalString)) {
							lengthOfNormalString += 1
						}
						guard lengthOfNormalString > 0 else { break }
						
						var plainString: String? = nil
						while plainString == nil && lengthOfNormalString > 0 {
							plainString = String(data[index..<index + lengthOfNormalString])
							// bla
						}
						
						if plainString == nil {
							plainString = "?"
							lengthOfNormalString = 1
						}
						resultsStorage.append(AttributedString(
							string: plainString!,
							attributes: currentAttributes
						))
						index += lengthOfNormalString
						cursorLoc += plainString!.characters.count
					}
				
			}
		}
		
		
		let wsChars = CharacterSet.whitespacesAndNewlines
		var wsStart = resultsStorage.length
		while wsStart > 0 && wsChars.contains(UnicodeScalar(resultString.character(at: wsStart - 1))) {
			wsStart -= 1
		}
		if wsStart < resultsStorage.length {
			let wsRange = NSRange(location: wsStart, length: resultsStorage.length - wsStart)
			trailingWhitespace = resultsStorage.attributedSubstring(from: wsRange)
			resultsStorage.deleteCharacters(in: wsRange)
		}
		
	}
	
	func cancel(sender: AnyObject) {
		if task.isRunning {
			kill(task.processIdentifier, SIGHUP)
		}
		self.task = nil
		stdOut = nil
		stdErr = nil
	}
	
	func handleEscapeSequenceWithType(type: Character, params: [String]) {
		switch type {
		case "m":
			var fgColor = currentAttributes[NSForegroundColorAttributeName] as? NSColor
			var bgColor = currentAttributes[NSBackgroundColorAttributeName] as? NSColor
			
			for paramString in params {
				switch Int(paramString)! {
					case 0:		// turn off all attributes
						fgColor = nil
						bgColor = nil
						currentAttributes.removeValue(forKey: NSUnderlineStyleAttributeName)
						currentAttributes[NSFontAttributeName] = NSFontManager.shared().convert(
							currentAttributes[NSFontAttributeName] as! NSFont, toNotHaveTrait:NSFontTraitMask.boldFontMask
						)
					case 1:		// bold
						currentAttributes[NSFontAttributeName] = NSFontManager.shared().convert(
							currentAttributes[NSFontAttributeName] as! NSFont, toHaveTrait: NSFontTraitMask.boldFontMask
						)
					case 4:		// underline single
						currentAttributes[NSUnderlineStyleAttributeName] = NSNumber(value: NSUnderlineStyle.styleSingle.rawValue)
					case 5:		// blink
						break
						// not supported
					case 7:		// FG black on BG white
						fgColor = NSColor.black()
						bgColor = NSColor.white()
					case 8:		// "hidden"
						fgColor = bgColor
					case 21:	// underline double
						currentAttributes[NSUnderlineStyleAttributeName] = NSNumber(value: NSUnderlineStyle.styleDouble.rawValue)
					case 22:	// stop bold
						currentAttributes[NSFontAttributeName] = NSFontManager.shared().convert(currentAttributes[NSFontAttributeName] as! NSFont, toNotHaveTrait:NSFontTraitMask.boldFontMask)
					case 24:	// underline none
						currentAttributes[NSUnderlineStyleAttributeName] = NSNumber(value: NSUnderlineStyle.styleNone.rawValue)
					case 30:	// FG black
						fgColor = NSColor.black()
					case 31:	// FG red
						fgColor = NSColor.red()
					case 32:	// FG green
						fgColor = NSColor.green()
					case 33:	// FG yellow
						fgColor = NSColor.yellow()
					case 34:	// FG blue
						fgColor = NSColor.blue()
					case 35:	// FG magenta
						fgColor = NSColor.magenta()
					case 36:	// FG cyan
						fgColor = NSColor.cyan()
					case 37:	// FG white
						fgColor = NSColor.white()
					case 39:	// FG reset
						fgColor = nil
					case 40:	// BG black
						bgColor = NSColor.black()
					case 41:	// BG red
						bgColor = NSColor.red()
					case 42:	// BG green
						bgColor = NSColor.green()
					case 43:	// BG yellow
						bgColor = NSColor.yellow()
					case 44:	// BG blue
						bgColor = NSColor.blue()
					case 45:	// BG magenta
						bgColor = NSColor.magenta()
					case 46:	// BG cyan
						bgColor = NSColor.cyan()
					case 47:	// BG white
						bgColor = NSColor.white()
					case 49:	// BG reset
						bgColor = nil
					case 90:	// FG bright black
						fgColor = NSColor.black()
					case 91:	// FG bright red
						fgColor = NSColor.red()
					case 92:	// FG bright green
						fgColor = NSColor.green()
					case 93:	// FG bright yellow
						fgColor = NSColor.yellow()
					case 94:	// FG bright blue
						fgColor = NSColor.blue()
					case 95:	// FG bright magenta
						fgColor = NSColor.magenta()
					case 96:	// FG bright cyan
						fgColor = NSColor.cyan()
					case 97:	// FG bright white
						fgColor = NSColor.white()
					case 100:	// BG bright black
						bgColor = NSColor.black()
					case 101:	// BG bright red
						bgColor = NSColor.red()
					case 102:	// BG bright green
						bgColor = NSColor.green()
					case 103:	// BG bright yellow
						bgColor = NSColor.yellow()
					case 104:	// BG bright blue
						bgColor = NSColor.blue()
					case 105:	// BG bright magenta
						bgColor = NSColor.magenta()
					case 106:	// BG bright cyan
						bgColor = NSColor.cyan()
					case 107:	// BG bright white
						bgColor = NSColor.white()
					default:
						break
				}
			}
			
			let standardFGColor = NSKeyedUnarchiver.unarchiveObject(with: UserDefaults.standard().object(forKey: DTTextColorKey) as! Data) as! NSColor
			fgColor = fgColor != nil ? fgColor!.withAlphaComponent(standardFGColor.alphaComponent) : standardFGColor
			bgColor = bgColor!.withAlphaComponent(standardFGColor.alphaComponent)
			
			currentAttributes[NSForegroundColorAttributeName] = fgColor
			if let bgColor = bgColor {
				currentAttributes[NSBackgroundColorAttributeName] = bgColor
			} else {
				currentAttributes.removeValue(forKey: NSBackgroundColorAttributeName)
			}
			
		default:
			// If we don't handle it, just ignore it
			break
#if DEVBUILD
			print("Got \(type) escape sequence with: \(params)")
#endif
		}
	}

    @IBAction public func cancel(_ sender: AnyObject!) {
		if task?.isRunning ?? false {
			kill(task!.processIdentifier, SIGHUP)
		}
		self.task = nil
		stdOut = nil
		stdErr = nil
	}

}

func +(array: [Character], data: Data) -> [Character] {
	return array + String(data).characters
}
