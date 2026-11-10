//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct RedactorTests {
    @Test func knownValueGetsOneAliasIgnoringCase() throws {
        var redactor = Redactor()
        redactor.add("6812A417-3B91-576A-A4EB-F81FED731A58", as: .coredevice)
        let text = redactor.redact("6812A417-3B91-576A-A4EB-F81FED731A58 and 6812a417-3b91-576a-a4eb-f81fed731a58")
        let alias = try #require(text.firstMatch(of: /coredevice-[0-9a-f]{4}/)).0
        #expect(text == "\(alias) and \(alias)")
        #expect(redactor.counts[.coredevice] == 2)
    }

    @Test func homePathIsReplacedBeforeTheUserNameInsideIt() {
        var redactor = Redactor()
        redactor.add("jappleseed", as: .user)
        redactor.add("/Users/jappleseed", as: .home)
        #expect(redactor.redact("/Users/jappleseed/Library/Caches/deviceloop") == "~/Library/Caches/deviceloop")
    }

    @Test func bearerAndBase64TokensBecomeTokenAliases() {
        let token = Data((0 ..< 32).map { UInt8($0 * 7) }).base64EncodedString()
        var redactor = Redactor()
        let text = redactor.redact("Authorization: Bearer abc.def-123\ntoken \(token)")
        #expect(text.wholeMatch(of: /Authorization: Bearer token-[0-9a-f]{4}\ntoken token-[0-9a-f]{4}/) != nil)
        #expect(redactor.counts[.token] == 2)
    }

    @Test func uniqueLocalIPv6AddressBecomesTunnelAlias() {
        var redactor = Redactor()
        #expect(redactor.redact("bind [fd85:efc2:a0aa::1]:59479").wholeMatch(of: /bind \[tunnel-[0-9a-f]{4}\]:59479/) != nil)
    }

    @Test func appleDevelopmentIdentityBecomesIdentityAlias() {
        var redactor = Redactor()
        let text = redactor.redact(#"Signing Identity: "Apple Development: John Appleseed (QX7K2M9P4L)""#)
        #expect(text.wholeMatch(of: #/Signing Identity: "identity-[0-9a-f]{4}"/#) != nil)
    }

    @Test func typedTextInXCTestActivityIsHidden() {
        var redactor = Redactor()
        let line = #"    t =     5.12s Type 'hunter2' into "fixture.text.input" TextField"#
        #expect(redactor.redact(line) == #"    t =     5.12s Type '[hidden]' into "fixture.text.input" TextField"#)
    }

    @Test func typedTextAcrossLinesIsHidden() {
        var redactor = Redactor()
        let log = "    t =    13.84s Type 'it's\ntwo lines' into \"fixture.text.input\" TextField\n    t =    13.84s     Synthesize event"
        let expected = "    t =    13.84s Type '[hidden]' into \"fixture.text.input\" TextField\n    t =    13.84s     Synthesize event"
        #expect(redactor.redact(log) == expected)
    }

    @Test func typedTextCutAtTheStartOfATailIsHidden() {
        var redactor = Redactor()
        let tail = "two lines' into \"fixture.text.input\" TextField\n    t =    14.10s Type 'next' into \"fixture.text.input\" TextField"
        let expected =
            "Type '[hidden]' into \"fixture.text.input\" TextField\n    t =    14.10s Type '[hidden]' into \"fixture.text.input\" TextField"
        #expect(redactor.redact(tail) == expected)
    }

    @Test func siriPhraseIsHidden() {
        var redactor = Redactor()
        let log = "t = 345.92s Activate Siri with voice recognition text: call Mom\nt = 346.10s Wait for com.apple.siri to idle"
        let expected = "t = 345.92s Activate Siri with voice recognition text: [hidden]\nt = 346.10s Wait for com.apple.siri to idle"
        #expect(redactor.redact(log) == expected)
    }

    @Test func xcodebuildDestinationNameBecomesDeviceAlias() {
        var redactor = Redactor()
        let text = redactor.redact("{ platform:iOS, arch:arm64e, id:00008130-0001, name:Johnny's iPhone }")
        #expect(text.wholeMatch(of: /\{ platform:iOS, arch:arm64e, id:00008130-0001, name:device-[0-9a-f]{4} \}/) != nil)
    }

    @Test func jsonKeysAndStringsAreRedacted() throws {
        var redactor = Redactor()
        redactor.add("Johnny's iPhone", as: .device)
        let json = redactor.redact(["Johnny's iPhone": ["name": "Johnny's iPhone", "paired": true]] as JSONValue)
        let alias = try #require(json.object?.keys.first)
        #expect(alias.hasPrefix("device-"))
        #expect(json[alias] == ["name": .string(alias), "paired": true])
    }
}
