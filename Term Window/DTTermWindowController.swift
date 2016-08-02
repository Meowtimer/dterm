import Foundation
import Cocoa

private var DTPreferencesContext = 0

public class DTTermWindowController : NSWindowController {

	@IBOutlet var actionButton: NSPopUpButton!
	@IBOutlet var actionMenu: NSMenu!
	@IBOutlet var placeholderForResultsView: NSView!
	@IBOutlet var resultsView: DTResultsView!
	@IBOutlet var resultsTextView: DTResultsTextView!
	@IBOutlet var commandField: NSTextField!
	
	var commandFieldEditor: DTCommandFieldEditor!

	var workingDirectory: String!
	var selectedURLs: [URL]!
	var runs: [DTRunManager]
	var runsController: NSArrayController!
	
	required public init?(coder: NSCoder) {
		self.command = ""
		self.runs = []
		super.init(coder: coder)
		
		let sdc = NSUserDefaultsController.shared()
		["values.DTTextColor", "values.DTFontName", "values.DTFontSize"].forEach {
			sdc.addObserver(self,
				forKeyPath: $0,
				options: NSKeyValueObservingOptions(rawValue: UInt(0)),
				context: &DTPreferencesContext
			)
		}
	}
	
	func activateWithWorkingDirectory(
		_ wdPath: String,
		selection: [String],
		windowFrame: NSRect
	) {
		guard let panel = self.window as? NSPanel else { return }
		panel.hidesOnDeactivate = false
		actionButton.bezelStyle = .smallSquare
		
		resultsTextView.bind(
			"DTResultsTextView.resultsStorage",
			to: runsController,
			withKeyPath: "selection.resultsStorage",
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
	
	func windowWillReturnFieldEditor(window: NSWindow, toObject:AnyObject) -> AnyObject? {
		if window !== self.window {
			return nil
		}
		if toObject !== commandField {
			return nil
		}
		if commandFieldEditor === nil {
			commandFieldEditor = DTCommandFieldEditor.init(controller: self)
		}
		
		return commandFieldEditor
	}
	
	public var command: String {
		didSet {
			if let firstResponder = window?.firstResponder as? DTCommandFieldEditor, let textStorage = firstResponder.textStorage {
				// We may be editing.  Make sure the field editor reflects the change too.
				textStorage.replaceCharacters(in: Range(0, textStorage.length), with: newValue)
			}
		}
	}
	
	func activateWithWorkingDirectory(_ wdPath: String, selection: [URL], windowFrame frame: NSRect) {
		self.workingDirectory = wdPath
		self.selectedURLs = selection
		
		// Hide window
		let window = self.window
		window?.alphaValue = 0.0
		
		// resize text view
		let _ = resultsTextView.minSize // ?
		// select all of the command field
		commandFieldEditor.setSelectedRange(Range(0, commandFieldEditor.string.characters.count))
	}
	
	func deactivate() {
	}
	
	func requestWindowHeightChange(_ dHeight: CGFloat) {
	}
	
	@IBAction public func insertSelection(sender: AnyObject) {
	}
	
	@IBAction public func insertSelectionFullPaths(sender: AnyObject) {
	}
	
	@IBAction public func pullCommandFromResults(sender: AnyObject) {
	}
	
	@IBAction func executeCommand(sender: AnyObject) {
	}
	
	@IBAction public func executeCommandInTerminal(sender: AnyObject) {
	}
	
	@IBAction public func copyResultsToClipboard(sender: AnyObject) {
	}
	
	@IBAction func cancelCurrentCommand(sender: AnyObject) {
	}
	
	func completionsForPartialWorld(_ partialWord: String, isCommand: Bool, indexOfSelectedItem: Int) -> [String] {
	}
	

}
