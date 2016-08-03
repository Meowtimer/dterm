import Foundation
import Cocoa
import ScriptingBridge

private var DTPreferencesContext = 0

@objc public class DTTermWindowController : NSWindowController, NSWindowDelegate {

	@IBOutlet var actionButton: NSPopUpButton!
	@IBOutlet var actionMenu: NSMenu!
	@IBOutlet var placeholderForResultsView: NSView!
	@IBOutlet var resultsView: DTResultsView!
	@IBOutlet var resultsTextView: DTResultsTextView!
	@IBOutlet var commandField: NSTextField!
	
	var commandFieldEditor: DTCommandFieldEditor!

	var workingDirectory: String!
	var selectedURLs: [URL]!
	var runs: [DTRunManager] = []
	var runsController: NSArrayController!
	
	override public func windowDidLoad() {
		
		self.command = ""
		let sdc = NSUserDefaultsController.shared()
		["values.DTTextColor", "values.DTFontName", "values.DTFontSize"].forEach {
			sdc.addObserver(self,
				forKeyPath: $0,
				options: NSKeyValueObservingOptions(rawValue: UInt(0)),
				context: &DTPreferencesContext
			)
		}
		
		if let panel = self.window as? NSPanel {
			panel.hidesOnDeactivate = false
		}
		actionButton.bezelStyle = .smallSquare
		
		resultsTextView.bind(
			#keyPath(DTResultsTextView.resultsStorage),
			to: runsController,
			withKeyPath: #keyPath(NSArrayController.selection.resultsStorage),
			options: nil
		)
		
		resultsView.frame = placeholderForResultsView.frame
		placeholderForResultsView.removeFromSuperview()
		window?.contentView?.addSubview(resultsView)
		
		/*
		let psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: kCurrentProcess)
		let processInfo = Processinformation
		*/
	}
	
	public func windowWillReturnFieldEditor(_ window: NSWindow, to:AnyObject?) -> AnyObject? {
		if window !== self.window {
			return nil
		}
		if to !== commandField {
			return nil
		}
		if commandFieldEditor === nil {
			commandFieldEditor = DTCommandFieldEditor.init(controller: self)
		}
		
		return commandFieldEditor
	}
	
	public var command: String! {
		didSet {
			if let firstResponder = window?.firstResponder as? DTCommandFieldEditor, let textStorage = firstResponder.textStorage {
				// We may be editing.  Make sure the field editor reflects the change too.
				textStorage.replaceCharacters(in: NSMakeRange(0, textStorage.length), with: command)
			}
		}
	}
	
	func activateWithWorkingDirectory(_ wdPath: String, selection: [URL], windowFrame frame: NSRect) {
		var frame = frame
		self.workingDirectory = wdPath
		self.selectedURLs = selection
		
		// Hide window
		guard let window = self.window else { return }
		window.alphaValue = 0.0
		
		// resize text view
		let _ = resultsTextView.minSize // ?
		// select all of the command field
		if let string = commandFieldEditor.string {
			commandFieldEditor.setSelectedRange(NSMakeRange(0, string.characters.count))
			window.makeFirstResponder(commandField)
		}
		
		// if no parent window; use main screen
		if NSEqualRects(frame, NSZeroRect), let mainScreen = NSScreen.main() {
			frame = mainScreen.visibleFrame
		}
		
		// set frame according to parent window location
		let desiredWidth = fmin(frame.size.width - 20.0, 640.0)
		var newFrame = NSInsetRect(frame, (frame.size.width - desiredWidth) / 2.0, 0.0)
		newFrame.size.height = window.frame.size.height + resultsTextView.desiredHeightChange()
		newFrame.origin.y = frame.origin.y + frame.size.height - newFrame.size.height
		window.setFrame(newFrame, display: true)
		window.makeKeyAndOrderFront(self)
		
		NSAnimationContext.beginGrouping()
		NSAnimationContext.current().duration = 0.1
		window.animator().alphaValue = 1.0
		NSAnimationContext.endGrouping()
	}
	
	func deactivate() {
		let numRunsToKeep = clamp(min: 0, value: UserDefaults.standard.integer(forKey: DTResultsToKeepKey), max: 100)
		if runs.count > numRunsToKeep {
			self.runs = Array(self.runs[0..<numRunsToKeep])
		}
		NSAnimationContext.beginGrouping()
		NSAnimationContext.current().duration = 0.1
		window?.animator().alphaValue = 0.0
		NSAnimationContext.endGrouping()
		
		DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.11) {
			self.window?.orderOut(self)
		}
		
		(NSApp.delegate as! DTAppController).saveStats()
	}
	
	public func windowDidResignKey(_ notification: Notification) {
		guard notification.object === self.window else { return }
		
		self.deactivate()
	}
	
	func getURLFilePaths(fullPaths: Bool) -> [String] {
		return selectedURLs
			.filter { $0.isFileURL }
			.map {
				var result = $0.path
				if (!fullPaths) {
					if result.hasPrefix(workingDirectory) {
						result = result.substring(from: result.index(result.startIndex, offsetBy: workingDirectory.characters.count))
					}
					if result.hasPrefix("/") {
						result = result.substring(from: result.index(result.startIndex, offsetBy: 1))
					}
				}
				return result
			}
			.map { escapedPath($0)! }
	}
	
	@IBAction public func insertSelection(_ sender: AnyObject) {
		commandFieldEditor.insertFiles(getURLFilePaths(fullPaths: false))
	}
	
	@IBAction public func insertSelectionFullPaths(_ sender: AnyObject) {
		commandFieldEditor.insertFiles(getURLFilePaths(fullPaths: true))
	}
	
	@IBAction public func pullCommandFromResults(_ sender: AnyObject) {
		let selection = runsController.selection
		if let resultsCommand = selection["command"] as? String, let string = commandFieldEditor.string {
			commandFieldEditor.insertText(resultsCommand, replacementRange: NSMakeRange(0, string.characters.count))
		}
	}
	
	@IBAction public func executeCommand(_ sender: AnyObject) {
		guard let window = self.window, window.makeFirstResponder(window) else { return }
		guard self.command.characters.count > 0 else { return }
		
		let appController = NSApp.delegate as! DTAppController
		appController.numCommandsExecuted += 1
		let runManager = DTRunManager(
			withWorkingDirectory: self.workingDirectory,
			selection: self.selectedURLs,
			command: self.command
		)
		runsController.addObject(runManager)
	}
	
	@IBAction public func executeCommandInTerminal(_ sender: AnyObject) {
		// commit editing first
		guard let window = self.window, window.makeFirstResponder(window) else { return }
		
		let appController = NSApp.delegate as! DTAppController
		let cdCommandString = "cd \(escapedPath(self.workingDirectory)!)"
		appController.numCommandsExecuted += 1
		runCommand(cdCommandString, self.command)
	}
	
	override public func cancelOperation(_ sender: AnyObject?) {
		self.deactivate()
	}
	
	@IBAction public func copyResultsToClipboard(_ sender: AnyObject) {
		let selection = runsController.selection
		guard let resultsStorage = selection.value(forKey: "resultsStorage") as? NSTextStorage else { return }
		
		let pb = NSPasteboard.general()
		pb.declareTypes([NSStringPboardType], owner: self)
		pb.setString(resultsStorage.string, forType: NSStringPboardType)
		
		self.deactivate()
	}
	
	@IBAction public func cancelCurrentCommand(_ sender: AnyObject) {
		if let selection = runsController.selectedObjects as? [DTRunManager] {
			selection.forEach { $0.cancel(sender: sender) }
		}
	}
	
	func requestWindowHeightChange(_ dHeight: CGFloat) {
		guard let window = self.window else { return }
		
		var windowFrame = window.frame
		windowFrame.size.height += dHeight
		windowFrame.origin.y -= dHeight
		
		// adjust bottom edge so it's on the screen
		guard let screen = window.screen else { return }
		let screenRect = screen.visibleFrame
		let dHeight = windowFrame.origin.y - screenRect.origin.y
		if dHeight < 0.0 {
			windowFrame.size.height += dHeight
			windowFrame.origin.y -= dHeight
		}
		
		window.setFrame(windowFrame, display: true, animate: true)
	}
	
	public func completionsForPartialWord(_ partialWord: String, isCommand: Bool, indexOfSelectedItem: Int) -> [String]? {
		let allowFiles = (
			!isCommand ||
			partialWord.hasPrefix("/") ||
			partialWord.hasPrefix(".") ||
			partialWord.hasPrefix("../")
		)
		let task = Task()
		task.currentDirectoryPath = self.workingDirectory
		task.launchPath = "/bin/bash"
		let flags = [
			URL(string: DTRunManager.shellPath!)?.lastPathComponent == "bash" ? "a" : "",
			isCommand ? "bc" : "",
			allowFiles ? "df" : ""
		].joined(separator: "")
		task.arguments = DTRunManager.arguments(
			toRunCommand: "compgen -\(flags) \(partialWord)"
		)
		
		let newPipe = Pipe()
		let stdOut = newPipe.fileHandleForReading
		task.standardOutput = newPipe
		
		let savedEGID = getegid()
		setegid(getgid())
		task.launch()
		setegid(savedEGID)
		
		let resultsData = stdOut.readDataToEndOfFile()
		let results = String(data: resultsData, encoding:.utf8)!
		
		var completionsSet = Set(results.components(separatedBy: .newlines))
		completionsSet.remove("")
		
		let fileManager = FileManager.default
		let completions: [String] = completionsSet.map {
			completion in
			let actualPath = completion.hasPrefix("/") ? completion : (workingDirectory as NSString).appendingPathComponent(completion)
			var isDirectory: ObjCBool = false
			return fileManager.fileExists(atPath: actualPath, isDirectory: &isDirectory)
				? completion.appending("/")
				: completion
		}
		guard completions.count > 0 else { return nil }
		return completions.sorted {
			if $0.characters.count > $1.characters.count {
				return true
			} else if $0.characters.count < $1.characters.count {
				return false
			}
			switch $0.lowercased().compare($1.lowercased()) {
				case .orderedSame:
					return false
				case .orderedDescending:
					return false
				case .orderedAscending:
					return true
			}
		}
	}
	
	override public func observeValue(
		forKeyPath keyPath: String?,
		of object: AnyObject?,
		change: [NSKeyValueChangeKey : AnyObject]?,
		context: UnsafeMutablePointer<Void>?
	) {
		guard context == &DTPreferencesContext else {
			super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
			return
		}
		
		let defaults = UserDefaults.standard
		if keyPath == "values.DTFontName" || keyPath == "values.DTFontSize" {
			if let newFont = NSFont(
				name: defaults.object(forKey: DTFontNameKey) as! String,
				size: CGFloat(defaults.double(forKey:DTFontSizeKey))
			) {
				for run in runs {
					run.setDisplayFont(newFont)
				}
			}
		}
		window?.contentView?.needsDisplay = true
	}
	
	func resultsCommandFontSize() -> CGFloat {
		return 10.0
	}
	

}

func clamp<T : Comparable>(min: T, value: T, max: T) -> T {
	return value < min ? min : value > max ? max : value
}
