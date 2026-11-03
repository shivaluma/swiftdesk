import AppKit
import CoreGraphics
import Testing
@testable import InputCore

@Suite struct ModifierKeysTests {
    @Test(arguments: [
        (UInt16(56), ModifierKeys.shiftFlag), (UInt16(60), ModifierKeys.shiftFlag),
        (UInt16(59), ModifierKeys.controlFlag), (UInt16(62), ModifierKeys.controlFlag),
        (UInt16(58), ModifierKeys.optionFlag), (UInt16(61), ModifierKeys.optionFlag),
        (UInt16(55), ModifierKeys.commandFlag), (UInt16(54), ModifierKeys.commandFlag),
        (UInt16(63), ModifierKeys.functionFlag), (UInt16(57), ModifierKeys.alphaShiftFlag),
    ] as [(UInt16, UInt64)])
    func modifierKeyCodesMapToFlags(keyCode: UInt16, flag: UInt64) {
        #expect(ModifierKeys.flag(forKeyCode: keyCode) == flag)
        #expect(ModifierKeys.isModifier(keyCode))
    }

    @Test(arguments: [UInt16(0), 1, 36, 49, 53, 123, 126, 179])
    func nonModifiersHaveNoFlag(keyCode: UInt16) {
        #expect(ModifierKeys.flag(forKeyCode: keyCode) == nil)
        #expect(!ModifierKeys.isModifier(keyCode))
    }

    @Test func flagValuesMatchCoreGraphics() {
        #expect(ModifierKeys.shiftFlag == 0x2_0000)
        #expect(ModifierKeys.controlFlag == 0x4_0000)
        #expect(ModifierKeys.optionFlag == 0x8_0000)
        #expect(ModifierKeys.commandFlag == 0x10_0000)
        #expect(ModifierKeys.alphaShiftFlag == 0x1_0000)
        #expect(ModifierKeys.functionFlag == 0x80_0000)
    }

    @Test func appKitFlagsShareBitPositionsWithCGEventFlags() {
        let pairs: [(NSEvent.ModifierFlags, CGEventFlags)] = [
            (.capsLock, .maskAlphaShift), (.shift, .maskShift), (.control, .maskControl), (.option, .maskAlternate),
            (.command, .maskCommand), (.numericPad, .maskNumericPad), (.help, .maskHelp), (.function, .maskSecondaryFn),
        ]
        for (ns, cg) in pairs {
            #expect(ModifierKeys.cgFlags(fromAppKitRawValue: ns.rawValue) == cg.rawValue)
        }
    }

    @Test func conversionDropsNonKeyStateBits() {
        let raw = UInt(ModifierKeys.shiftFlag | ModifierKeys.deviceLeftShiftFlag | 0x100 | 0x2000_0000)
        #expect(ModifierKeys.cgFlags(fromAppKitRawValue: raw) == ModifierKeys.shiftFlag | ModifierKeys.deviceLeftShiftFlag)
    }

    @Test func deviceFlagsDistinguishSides() {
        #expect(ModifierKeys.deviceFlag(forKeyCode: 56) == ModifierKeys.deviceLeftShiftFlag)
        #expect(ModifierKeys.deviceFlag(forKeyCode: 60) == ModifierKeys.deviceRightShiftFlag)
        #expect(ModifierKeys.deviceFlag(forKeyCode: 62) == ModifierKeys.deviceRightControlFlag)
        #expect(ModifierKeys.siblingDeviceFlag(forKeyCode: 55) == ModifierKeys.deviceRightCommandFlag)
        #expect(ModifierKeys.deviceFlag(forKeyCode: 63) == nil)
        #expect(ModifierKeys.deviceFlag(forKeyCode: 57) == nil)
    }

    /// Device flags match what CoreGraphics itself stamps on modifier keyboard events.
    @Test func deviceFlagsMatchCoreGraphicsKeyboardEvents() throws {
        for keyCode: UInt16 in [56, 60, 59, 62, 58, 61, 55, 54] {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
            let device = try #require(ModifierKeys.deviceFlag(forKeyCode: keyCode))
            let flag = try #require(ModifierKeys.flag(forKeyCode: keyCode))
            #expect(event.flags.rawValue & device != 0)
            #expect(event.flags.rawValue & flag != 0)
            #expect(event.type == .flagsChanged)
        }
    }

    @Test func releasingOneSideKeepsFlagWhileSiblingHeld() {
        let both = ModifierKeys.shiftFlag | ModifierKeys.deviceLeftShiftFlag | ModifierKeys.deviceRightShiftFlag
        let afterLeft = ModifierKeys.flags(both, releasing: 56)
        #expect(afterLeft == ModifierKeys.shiftFlag | ModifierKeys.deviceRightShiftFlag)
        #expect(ModifierKeys.flags(afterLeft, releasing: 60) == 0)
        #expect(ModifierKeys.flags(ModifierKeys.commandFlag, releasing: 55) == 0)
        #expect(ModifierKeys.flags(ModifierKeys.alphaShiftFlag, releasing: 57) == ModifierKeys.alphaShiftFlag)
        #expect(ModifierKeys.flags(ModifierKeys.shiftFlag, releasing: 0) == ModifierKeys.shiftFlag)
    }
}
