//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation

/// A simulator or physical device that DeviceLoop can drive.
public struct Target: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case device
        case simulator
    }

    /// UDID. Stable across reboots and accepted by simctl, devicectl and xcodebuild.
    public var udid: String
    /// CoreDevice identifier from `devicectl list devices`.
    public var identifier: String
    public var name: String
    public var kind: Kind
    /// `iPhone`, `iPad`, `appleWatch` and so on, from `properties.hardware.deviceType`.
    public var deviceType: String
    /// `iOS`, `watchOS`, `tvOS`, `xrOS`.
    public var platform: String
    public var model: String
    public var productType: String
    public var osVersion: String
    /// Build such as `24A434`, from `properties.software.osBuildVersions.buildVersion.name`.
    public var osBuild: String?
    /// `properties.connection.state`: `connected`, `disconnected` or `unavailable`.
    public var connectionState: String
    /// `properties.state.bootState`, for example `booted` or `shutdown`.
    public var bootState: String?
    /// `wired`, `localNetwork` or `sameMachine`.
    public var transport: String?
    public var paired: Bool
    public var developerModeEnabled: Bool?
    /// Device side of the CoreDevice tunnel, for example `fd85:efc2:a0aa::1`.
    public var tunnelAddress: String?
    /// Opens the Device Hub live screen for this target.
    public var screenViewingURL: String?
    public var hasActionButton: Bool
    /// CoreDevice feature identifiers, for example `com.apple.coredevice.feature.capturescreenshot`.
    public var capabilities: Set<String>

    public init(
        udid: String,
        identifier: String,
        name: String,
        kind: Kind,
        deviceType: String,
        platform: String,
        model: String,
        productType: String,
        osVersion: String,
        osBuild: String? = nil,
        connectionState: String,
        bootState: String? = nil,
        transport: String? = nil,
        paired: Bool = true,
        developerModeEnabled: Bool? = nil,
        tunnelAddress: String? = nil,
        screenViewingURL: String? = nil,
        hasActionButton: Bool = false,
        capabilities: Set<String> = []
    ) {
        self.udid = udid
        self.identifier = identifier
        self.name = name
        self.kind = kind
        self.deviceType = deviceType
        self.platform = platform
        self.model = model
        self.productType = productType
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.connectionState = connectionState
        self.bootState = bootState
        self.transport = transport
        self.paired = paired
        self.developerModeEnabled = developerModeEnabled
        self.tunnelAddress = tunnelAddress
        self.screenViewingURL = screenViewingURL
        self.hasActionButton = hasActionButton
        self.capabilities = capabilities
    }

    public var isSimulator: Bool { kind == .simulator }

    /// A booted simulator or a connected device: something commands can act on right now.
    public var isReady: Bool {
        switch kind {
            case .simulator: bootState == "booted"
            case .device: connectionState == "connected"
        }
    }

    /// Supported by the runner and the device commands: iPhone and iPad on iOS or iPadOS.
    public var isDrivable: Bool { platform == "iOS" }

    public func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    /// One line used as the header of every result, for example `iPhone 15 Pro Max (device, iOS 27.0)`.
    public var summary: String {
        "\(name) (\(kind.rawValue), iOS \(osVersion))"
    }
}

/// CoreDevice capability identifiers DeviceLoop routes on.
public enum Capability {
    public static let screenshot = "com.apple.coredevice.feature.capturescreenshot"
    public static let screenRecording = "com.apple.coredevice.feature.screenrecording"
    public static let simulateLocation = "com.apple.coredevice.feature.simulatelocation"
    public static let orientation = "com.apple.coredevice.feature.remote.devicecontrol.orientation"
    public static let lockState = "com.apple.coredevice.feature.getlockstate"
    public static let applicationControl = "com.apple.coredevice.feature.applicationcontrol"
    static let displayInfo = "com.apple.coredevice.feature.getdisplayinfo"
    static let uiStyle = "com.apple.coredevice.feature.customizeuistyle"
    static let appearanceSettings = "com.apple.coredevice.feature.customizeappearancesettings"
    static let voiceOver = "com.apple.coredevice.feature.voiceover"
    static let audioOutput = "com.apple.coredevice.feature.audiooutput"
    static let statusBar = "com.apple.coredevice.feature.simulateStatusBar"
    static let ddiMetadata = "com.apple.coredevice.feature.fetchddimetadata"
    static let pasteboard = "com.apple.coredevice.feature.pasteboard"
    static let installApp = "com.apple.coredevice.feature.installapp"
    static let uninstallApp = "com.apple.coredevice.feature.uninstallapp"
    static let processControl = "com.apple.coredevice.feature.processcontrol"
    static let listFiles = "com.apple.coredevice.feature.listFiles"
    static let transferFiles = "com.apple.coredevice.feature.transferFiles"
}
