import Foundation

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
	var realAXPosition: CGPoint = CGPoint(x: 0, y: 0)
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
	var realAXSize: CGSize = CGSize(width: 0, height: 0)
	if !AXValueGetValue(axSize as! AXValue, AXValueType(rawValue: kAXValueCGSizeType)!, &realAXSize) {
		print ("Couldn't extract CGSize from AXSize")
		return NSZeroRect
	}
	
	return NSRect(
		origin: CGPoint(x: realAXPosition.x, y: realAXPosition.y + 20.0),
		size: CGSize(width: realAXSize.width, height: realAXSize.height - 20)
	)
}
