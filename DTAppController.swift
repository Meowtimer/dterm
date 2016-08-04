import Foundation
import Cocoa
import ApplicationServices

import CoreServices
import CoreFoundation
import Carbon

private func DTHotKeyHandler(nextHandler: EventHandlerCallRef?, theEvent: EventRef?, userData: UnsafeMutablePointer<Void>?) -> OSStatus {
	(NSApp.delegate as! DTAppController).hotkeyPressed()
	return noErr
}

class DTAppController : NSObject, NSApplicationDelegate {

	public override init() { }

	public var numCommandsExecuted: Int = 0

	public var termWindowController: DTTermWindowController! = nil
	
	public func applicationWillFinishLaunching(_ notification: Notification) {
		signal(SIGPIPE, SIG_IGN);
		
		setenv("TERM_PROGRAM", "DTerm", 1)
		if let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
			setenv("TERM_PROGRAM_VERSION", bundleVersion.cString(using: String.Encoding.ascii), 1)
		}
		
		let defaultsDict: [String:AnyObject] = [
			DTResultsToKeepKey: "5",
			DTHotkeyAlsoDeactivatesKey: NSNumber(booleanLiteral: false),
			DTShowDockIconKey: NSNumber(booleanLiteral: true),
			DTTextColorKey: NSKeyedArchiver.archivedData(withRootObject: NSColor.white.withAlphaComponent(0.9)),
			DTFontNameKey: "Monaco",
			DTFontSizeKey: NSNumber(floatLiteral: 10.0),
			DTDisableAntialiasingKey: NSNumber(booleanLiteral: false)
		]
		
		UserDefaults.standard.register(defaults: defaultsDict)
		
		loadStats()
		
		NSAppleEventManager.shared().setEventHandler(
			self,
			andSelector: #selector(DTAppController.getURL(_:withReplyEvent:)),
			forEventClass: AEEventClass(kInternetEventClass),
			andEventID: AEEventID(kAEGetURL)
		)
		
		if UserDefaults.standard.bool(forKey: DTShowDockIconKey) {
			var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
			let err = TransformProcessType(&psn, ProcessApplicationTransformState(kProcessTransformToForegroundApplication))
			if err != noErr {
				print ("Error making DTerm non-LSUIElement: \(err)")
			} else {
				var appleScriptError: NSDictionary?
				if let frontmostApp = DSAppleScriptUtilities.string(
					fromAppleScript: "tell application \"System Events\" to name of first process whose frontmost is true",
					error: &appleScriptError
				) {
					NSWorkspace.shared().launchApplication(frontmostApp)
				} else {
					print ("Couldn't get frontmost app from System Events: \(appleScriptError)")
				}
			}
		}
		
	}
	
	func applicationDidFinishLaunching(_ notification: Notification) {
		if !AXIsProcessTrustedWithOptions(nil) {
			self.prefsWindowController.showAccessibility(self)
		}
	}
	
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag {
			DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.0) {
				self.showPrefs(nil)
			}
		}
		return true
	}
	
	override func awakeFromNib() {
		termWindowController = DTTermWindowController(windowNibName: "TermWindow")
		
		let theTypeSpec = [
			EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		]
		InstallEventHandler(GetApplicationEventTarget(), DTHotKeyHandler, 1, theTypeSpec, nil, nil)
		loadHotKeyFromUserDefaults()
	}
	
	public lazy var prefsWindowController: DTPrefsWindowController = DTPrefsWindowController()
	
	private var _hotKey: KeyCombo = KeyCombo(flags: 0, code: 0)
	private var hotKeyRef: EventHotKeyRef? = nil
	public var hotKey: KeyCombo {
		get { return _hotKey }
		set {
			// Unregister old hotkey, if necessary
			if hotKeyRef != nil {
				UnregisterEventHotKey(hotKeyRef)
				hotKeyRef = nil
			}
			// Save hotkey for the future
			_hotKey = newValue
			saveHotKeyToUserDefaults()
			if _hotKey.code != -1 && _hotKey.flags != 0 {
				let hotKeyID = EventHotKeyID(signature: fourCharCodeFrom(string: "htk1"), id: 1)
				RegisterEventHotKey(
					UInt32(_hotKey.code),
					UInt32(SRCocoaToCarbonFlags(_hotKey.flags)),
					hotKeyID,
					GetApplicationEventTarget(),
					0, &hotKeyRef
				)
			}
		}
	}
	
	public func saveHotKeyToUserDefaults() {
		let myHotKey = self.hotKey
		let hotKeyDict = [
			"flags": NSNumber(value: myHotKey.flags),
			"code": NSNumber(value: myHotKey.code)
		]
		UserDefaults.standard.set(hotKeyDict, forKey: "DTHotKey")
	}
	
	public func loadHotKeyFromUserDefaults() {
		let flags: NSEventModifierFlags = [.command, .shift]
		var myHotKey: KeyCombo = KeyCombo(flags: flags.rawValue, code: 36 /* return */);
		guard let hotKeyDict = UserDefaults.standard.object(forKey: "DTHotKey") as? [String:NSNumber] else { return }
		if let newFlags = hotKeyDict["flags"] {
			myHotKey.flags = newFlags.uintValue
		}
		if let newCode = hotKeyDict["code"] {
			myHotKey.code = newCode.intValue
		}
		
		self.hotKey = myHotKey
	}
	
	@IBAction public func showPrefs(_ sender: AnyObject!) {
		prefsWindowController.showPrefs(sender)
	}
	
	struct WindowAttributes {
		var url: URL?
		var selectionURLs: [URL]
		var frame: NSRect
	}
	
	func findWindowAttributesOf(application: AXUIElement) -> WindowAttributes? {
		
		// Mechanism 1: Find front window AXDocument (a CFURL), and use that window
		func mechanism1() -> WindowAttributes? {
			var axErr: AXError = .success
			// follow to main window
			var mainWindow: CFTypeRef? = nil
			axErr = AXUIElementCopyAttributeValue(application , kAXMainWindowAttribute, &mainWindow)
			if axErr != .success || mainWindow == nil {
				print ("Couldn't get main window: \(axErr)")
				return nil
			}
			
			// get the window's AXDocument URL string
			var axDocumentURLString: CFTypeRef? = nil
			axErr = AXUIElementCopyAttributeValue(mainWindow as! AXUIElement, kAXDocumentAttribute, &axDocumentURLString)
			if axErr != .success || axDocumentURLString == nil {
				print ("Couldn't get AXDocument: \(axErr)")
				return nil
			}
			
			guard let url = URL(string: axDocumentURLString as! String) else { return nil }
			return WindowAttributes(
				url: url,
				selectionURLs: [url],
				frame: windowFrameOfAXWindow(axWindow: mainWindow!)
			)
		}
		
		// Mechanism 2: Find focused UI element and try to find a selection from it.
		func mechanism2() -> WindowAttributes? {
			var axErr: AXError = .success
			// Does the focused UI element have any selected children or selected rows? Great for file views.
			var focusedUIElement: CFTypeRef? = nil
			axErr = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute, &focusedUIElement)
			var foundUIElement = true
			if axErr != .success || focusedUIElement == nil {
				print ("Couldn't get AXFocusedUIElement")
				foundUIElement = false
			}
			
			if foundUIElement {
				var focusedSelectedChildren: CFTypeRef? = nil
				axErr = AXUIElementCopyAttributeValue(focusedUIElement as! AXUIElement, kAXSelectedChildrenAttribute, &focusedSelectedChildren)
				if axErr != .success || focusedSelectedChildren == nil || CFArrayGetCount(focusedSelectedChildren as! CFArray) == 0 {
					axErr = AXUIElementCopyAttributeValue(focusedUIElement as! AXUIElement, kAXSelectedRowsAttribute, &focusedSelectedChildren)
				}
				if axErr == .success {
					// If it *worked*, we see if we can extract URLs from these selected children
					let tmpSelectionURLS: [URL] = (0 ..< Int(CFArrayGetCount(focusedSelectedChildren as! CFArray))).map { (index: Int) in
						let selectedChild = CFArrayGetValueAtIndex(focusedSelectedChildren as! CFArray, index)
						return fileAXURLStringOfAXUIElement(uiElement: selectedChild as! AXUIElement)
					}.flatMap { $0 }.map { URL(string: $0) }.flatMap { $0 }
					
					// If we have selection URLs now, grab the window the focused UI element belongs to
					if tmpSelectionURLS.count > 0 {
						var focusWindow: CFTypeRef? = nil
						axErr = AXUIElementCopyAttributeValue(focusedUIElement as! AXUIElement, kAXWindowAttribute, &focusWindow)
						if axErr == .success && focusWindow != nil {
							// We're good with this! Return the values.
							return WindowAttributes(
								url: nil,
								selectionURLs: tmpSelectionURLS,
								frame: windowFrameOfAXWindow(axWindow: focusWindow!)
							)
						}
					}
				}
			}
			
			if let focusedUIElementURLString = fileAXURLStringOfAXUIElement(uiElement: focusedUIElement as! AXUIElement), let url = URL(string: focusedUIElementURLString) {
				var focusWindow: CFTypeRef? = nil
				axErr = AXUIElementCopyAttributeValue(focusedUIElement as! AXUIElement, kAXWindowAttribute, &focusWindow)
				if axErr == .success, let focusWindow = focusWindow {
					// We're good with this! Return the values.
					return WindowAttributes(
						url: nil,
						selectionURLs: [url],
						frame: windowFrameOfAXWindow(axWindow: focusWindow)
					)
				}
			}
			
			return nil
		}
		
		return mechanism1() ?? mechanism2()
		
	}
	
	private func getWindowAttributesFromFocusedApplication() -> WindowAttributes? {
		guard AXIsProcessTrustedWithOptions(nil) else { return nil }
		var axErr: AXError = .success
		let systemElement = AXUIElementCreateSystemWide()
		var focusedApplication: CFTypeRef? = nil
		axErr = AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute, &focusedApplication)
		guard axErr == .success && focusedApplication != nil else {
			print("Couldn't get focusedApplication: \(axErr)")
			return nil
		}
		return self.findWindowAttributesOf(application: focusedApplication as! AXUIElement)
	}
	
	public func hotkeyPressed() {
	
		// See if it's already visible
		if termWindowController.window?.isVisible ?? false {
			// Yep, it's visible...does the user want us to deactivate?
			if UserDefaults.standard.bool(forKey: DTHotkeyAlsoDeactivatesKey) {
				termWindowController.deactivate()
			}
		}
		
		var windowAttributes = getWindowAttributesFromFocusedApplication() ?? WindowAttributes(url: nil, selectionURLs: [], frame: NSZeroRect)
		if !NSEqualRects(windowAttributes.frame, NSZeroRect) {
			if let screenHeight = NSScreen.screens()?[0].frame.size.height {
				windowAttributes.frame.origin.y = screenHeight - windowAttributes.frame.origin.y - windowAttributes.frame.size.height
			}
		}
		
		guard let workingDirectory = (
			windowAttributes.url.map { (url: URL) -> String? in
				guard url.isFileURL else { return nil }
				guard let keys = try? url.resourceValues(forKeys: [URLResourceKey.isPackageKey, URLResourceKey.isDirectoryKey])
					else { return nil }
				return keys.isPackage ?? false || !(keys.isDirectory ?? false) ?
					url.deletingLastPathComponent().path :
					url.path
			} ??
			{ () -> String? in
				let selection = windowAttributes.selectionURLs
				guard selection.count > 0 else { return nil }
				let url = selection[0]
				return url.deletingLastPathComponent().path
			}() ??
			NSHomeDirectory()
		) else { return }
		
		termWindowController.activateWithWorkingDirectory(
			workingDirectory,
			selection: windowAttributes.selectionURLs,
			windowFrame: windowAttributes.frame
		)
		
	}
	
	func getURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
		guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
		guard let url = URL(string: urlString) else { return }
		guard url.scheme == "dterm" else { return }
		
		let service = url.host
		if service == "prefs" {
			let prefsName = url.path
			switch prefsName {
				case "/general":
					self.prefsWindowController.showGeneral(self)
				case "/accessibility":
					self.prefsWindowController.showAccessibility(self)
				default:
					break
			}
		}
	}
	
	private lazy var acknowledgmentsWindowController: RTFWindowController
		= RTFWindowController(rtfFile: Bundle.main.path(forResource: "Acknowledgements", ofType: "rtf"))
	private lazy var licenseWindowController: RTFWindowController
		= RTFWindowController(rtfFile: Bundle.main.path(forResource: "License", ofType: "rtf"))

	@IBAction public func showAcknowledgments(_ sender: AnyObject!) {
		acknowledgmentsWindowController.showWindow(self)
	}

	@IBAction public func showLicense(_ sender: AnyObject!) {
		licenseWindowController.showWindow(self)
	}

	public func loadStats() {
		let tmp = UserDefaults.standard.integer(forKey: DTNumCommandsRunKey)
		if tmp > numCommandsExecuted {
			numCommandsExecuted = tmp
		}
	}

	public func saveStats() {
	}
	
	public override func changeFont(_ sender: AnyObject?) {
		let fontManager = NSFontManager.shared()
		let selectedFont = fontManager.selectedFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize())
		let panelFont = selectedFont
		let fontSize = NSNumber(floatLiteral: Double(panelFont.pointSize))
		let currentPrefsValues = NSUserDefaultsController.shared().values
		currentPrefsValues.setValue(panelFont.fontName, forKey: DTFontNameKey)
		currentPrefsValues.setValue(fontSize, forKey: DTFontSizeKey)
	}

}

let DTNumCommandsRunKey = "DTNumCommandsRun"
let DTNumCommandsRunXattrName = "net.decimus.dterm.commands"

func fourCharCodeFrom(string : String) -> FourCharCode {
	assert(string.characters.count == 4, "String length must be 4")
	var result : FourCharCode = 0
	for char in string.utf16 {
		result = (result << 8) + FourCharCode(char)
	}
	return result
}
