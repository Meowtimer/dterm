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
    
    public var numCommandsExecuted: UInt

    public var termWindowController: DTTermWindowController!
	
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
			forEventClass: kInternetEventClass,
			andEventID: kAEGetURL
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
	
	private var _prefsWindowController: DTPrefsWindowController?
	public var prefsWindowController: DTPrefsWindowController {
		get {
			if let p = _prefsWindowController {
				return p
			} else {
				let p = DTPrefsWindowController()
				_prefsWindowController = p
				return p
			}
		}
	}
	
	private var _hotKey: KeyCombo
	private var hotKeyRef: EventHotKeyRef?
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
				let hotKeyID = EventHotKeyID(signature: OSType("htk1")!, id: 1)
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
	
	func windowFrameOfAXWindow(axWindow: CFTypeRef) -> NSRect {
		let axWindow = axWindow as! AXUIElement
		var axErr = AXError.success
		
		// get AXPosition of the main window
		var axPosition: CFTypeRef? = nil
		axErr = AXUIElementCopyAttributeValue(axWindow , kAXPositionAttribute, &axPosition)
		if axErr != .success || axPosition == nil {
			print ("Couln't get AXPosition: \(axErr)")
			return NSZeroRect
		}
		
		// convert to CGPoint
		var realAXPosition: CGPoint
		if !AXValueGetValue(axPosition as! AXValue, AXValueType(rawValue: kAXValueCGPointType)!, &realAXPosition) {
			print("Couldn't extract CGPoint from AXPosition")
			return NSZeroRect
		}
		
		// get AXSize
		var axSize: CFTypeRef? = nil
		axErr = AXUIElementCopyAttributeValue(axWindow , kAXSizeAttribute, &axSize)
		if axErr != .success || axSize == nil {
			print ("Couldn't get AXSize: \(axErr)")
			return NSZeroRect
		}
		
		// convert to CGSize
		var realAXSize: CGSize
		if !AXValueGetValue(axSize as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &realAXSize) {
			print ("Couldn't extract CGSize from AXSize")
			return NSZeroRect
		}
		
		return NSRect(
			origin: CGPoint(x: realAXPosition.x, y: realAXPosition.y + 20.0),
			size: CGSize(width: realAXSize.width, height: realAXSize.height - 20)
		)
	}
	
	func fileAXURLStringOfAXUIElement(uiElement: AXUIElement) -> String? {
		var axURL: CFTypeRef? = nil
		
		let axErr = AXUIElementCopyAttributeValue(uiElement, kAXURLAttribute, &axURL)
		if axErr != .success || axURL == nil {
			return nil
		}
		
		// OK, we have some kind of AXURL attribute, but that could either be a string or a URL
		
		if CFGetTypeID(axURL) == CFStringGetTypeID(), let axURL = axURL as? NSString, axURL.hasPrefix("file:///") {
			return axURL as String
		}
		
		if CFGetTypeID(axURL) == CFURLGetTypeID(), let axURL = axURL as? URL, axURL.isFileURL {
			return axURL.absoluteString
		}
		
		// unknown type...
		return nil
	}
	
	struct WindowAttributes {
		var url: URL?
		var selectionURLs: [URL]
		var frame: NSRect
	}
	
	func findWindowAttributesOf(application: AXUIElement) -> WindowAttributes? {
		
		// Mechanism 1: Find front window AXDocument (a CFURL), and use that window
		
		let mechanism1: () -> WindowAttributes? = {
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
				frame: self.windowFrameOfAXWindow(axWindow: mainWindow!)
			)
		}
		
		let mechanism2: () -> WindowAttributes? = {
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
						return self.fileAXURLStringOfAXUIElement(uiElement: selectedChild as! AXUIElement)
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
								frame: self.windowFrameOfAXWindow(axWindow: focusWindow!)
							)
						}
					}
				}
			}
			
			if let focusedUIElementURLString = self.fileAXURLStringOfAXUIElement(uiElement: focusedUIElement as! AXUIElement), let url = URL(string: focusedUIElementURLString) {
				var focusWindow: CFTypeRef? = nil
				axErr = AXUIElementCopyAttributeValue(focusedUIElement as! AXUIElement, kAXWindowAttribute, &focusWindow)
				if axErr == .success, let focusWindow = focusWindow {
					// We're good with this! Return the values.
					return WindowAttributes(
						url: nil,
						selectionURLs: [url],
						frame: self.windowFrameOfAXWindow(axWindow: focusWindow)
					)
				}
			}
			
			return nil
		}
		
		return mechanism1() ?? mechanism2()
		
	}
	
	public func hotkeyPressed() {
	
		// See if it's already visible
		if termWindowController.window?.isVisible ?? false {
			// Yep, it's visible...does the user want us to deactivate?
			if UserDefaults.standard.bool(forKey: DTHotkeyAlsoDeactivatesKey) {
				termWindowController.deactivate()
			}
			return
		}
		
		
	
	}

    @IBAction public func showAcknowledgments(_ sender: AnyObject!) {
	}

    @IBAction public func showLicense(_ sender: AnyObject!) {
	}
    
    public func loadStats() {
	}

    public func saveStats() {
	}

}