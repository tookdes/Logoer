//
//  InfoButton.swift
//  InfoButton
//
//  Created by Kauntey Suryawanshi on 25/06/15.
//  Modified by lihaoyun6 on 2024/06/04
//  Copyright (c) 2015 Kauntey Suryawanshi. All rights reserved.
//

import Foundation
import Cocoa
import AppKit
import SwiftUI

@IBDesignable
open class InfoButton: NSControl, NSPopoverDelegate {
    var mainSize: CGFloat!

    @IBInspectable var showOnHover: Bool = false
    @IBInspectable var fillMode: Bool = true
    @IBInspectable var animatePopover: Bool = false
    @IBInspectable var content: String = ""
    @IBInspectable var primaryColor: NSColor = NSColor.systemGray
    @IBInspectable var preferredEdge: NSRectEdge = NSRectEdge.maxX
    var secondaryColor: NSColor = NSColor.white

    var mouseInside = false {
        didSet {
            self.needsDisplay = true
            if showOnHover {
                if popover == nil {
                    popover = NSPopover(content: self.content, doesAnimate: self.animatePopover)
                }
                if mouseInside {
                    if let parent = self.superview {
                        popover?.show(relativeTo: self.frame, of: parent, preferredEdge: self.preferredEdge)
                    }
                } else {
                    popover?.close()
                }
            }
        }
    }

    var trackingArea: NSTrackingArea!
    override open func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingArea != nil {
            self.removeTrackingArea(trackingArea)
        }
        trackingArea = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        self.addTrackingArea(trackingArea)
    }

    fileprivate var stringAttributeDict = [NSAttributedString.Key: Any]()
    fileprivate var circlePath: NSBezierPath!

    var popover: NSPopover?

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        self.setup()
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.setup()
    }

    private func setup() {
        self.wantsLayer = true
    }

    override open func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        self.mainSize = min(self.bounds.size.width, self.bounds.size.height)
        stringAttributeDict[.font] = NSFont.systemFont(ofSize: mainSize * 0.6)

        let inSet: CGFloat = 2
        let rect = NSMakeRect(inSet, inSet, mainSize - inSet * 2, mainSize - inSet * 2)
        circlePath = NSBezierPath(ovalIn: rect)

        let activeColor = primaryColor.withAlphaComponent(0.35)

        if fillMode {
            activeColor.setFill()
            circlePath.fill()
            stringAttributeDict[.foregroundColor] = secondaryColor
        } else {
            activeColor.setStroke()
            circlePath.stroke()
            stringAttributeDict[.foregroundColor] = (mouseInside ? primaryColor : primaryColor.withAlphaComponent(0.35))
        }

        let attributedString = NSAttributedString(string: "?", attributes: stringAttributeDict)
        let stringLocation = NSMakePoint(self.bounds.size.width / 2 - attributedString.size().width / 2, self.bounds.size.height / 2 - attributedString.size().height / 2)
        attributedString.draw(at: stringLocation)
    }

    override open func mouseDown(with theEvent: NSEvent) {
        if popover == nil {
            popover = NSPopover(content: self.content, doesAnimate: self.animatePopover)
        }
        guard let popover else { return }
        if popover.isShown {
            popover.close()
        } else {
            if let parent = self.superview {
                popover.show(relativeTo: self.frame, of: parent, preferredEdge: self.preferredEdge)
            }
        }
    }

    override open func mouseEntered(with theEvent: NSEvent) { mouseInside = true }
    override open func mouseExited(with theEvent: NSEvent) { mouseInside = false }
}

// Extension for creating a popover from a string
extension NSPopover {
    convenience init(content: String, doesAnimate: Bool) {
        self.init()
        self.behavior = .transient
        self.animates = doesAnimate
        self.contentViewController = NSViewController()
        self.contentViewController!.view = NSView(frame: .zero)

        let popoverMargin = CGFloat(20)
        let textField: NSTextField = {
            let textField = NSTextField(frame: .zero)
            textField.isEditable = false
            textField.stringValue = content
            textField.isBordered = false
            textField.drawsBackground = false
            textField.sizeToFit()
            textField.frame.origin = NSMakePoint(popoverMargin, popoverMargin)
            return textField
        }()

        self.contentViewController!.view.addSubview(textField)
        var viewSize = textField.frame.size
        viewSize.width += popoverMargin * 2
        viewSize.height += popoverMargin * 2
        self.contentSize = viewSize
    }
}

struct SWInfoButton: NSViewRepresentable {
    var showOnHover: Bool
    var fillMode: Bool
    var animatePopover: Bool
    var content: String
    var primaryColor: NSColor
    var preferredEdge: NSRectEdge = .maxX

    func makeNSView(context: Context) -> InfoButton {
        let infoButton = InfoButton(frame: .zero)
        infoButton.showOnHover = showOnHover
        infoButton.fillMode = fillMode
        infoButton.animatePopover = animatePopover
        infoButton.content = content
        infoButton.primaryColor = primaryColor
        infoButton.preferredEdge = preferredEdge
        return infoButton
    }

    func updateNSView(_ nsView: InfoButton, context: Context) {
        if nsView.content != content {
            nsView.popover = nil
            nsView.content = content
        }
        nsView.showOnHover = showOnHover
        nsView.fillMode = fillMode
        nsView.animatePopover = animatePopover
        nsView.primaryColor = primaryColor
        nsView.preferredEdge = preferredEdge
    }
}
