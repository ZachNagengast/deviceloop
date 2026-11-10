//  For licensing see accompanying LICENSE file.
//  Copyright 2026 Argmax, Inc. All rights reserved.

import Foundation
import Testing

@testable import DeviceLoopKit

@Suite struct DoctorSigningTests {
    let defaultsOutput = """
        {
            "dev@example.com" =     (
                        {
                    isFreeProvisioningTeam = 1;
                    teamID = FREE000001;
                    teamName = "Jane Doe (Personal Team)";
                    teamType = Individual;
                },
                        {
                    isFreeProvisioningTeam = 0;
                    teamID = ABCDE12345;
                    teamName = "Example, Inc.";
                    teamType = Company;
                }
            );
        }
        """

    let findIdentityOutput = """
          1) 1111111111111111111111111111111111111111 "Apple Development: Jane Doe (PERSON0001)"
          2) 2222222222222222222222222222222222222222 "Apple Distribution: Example, Inc. (ABCDE12345)"
          3) 1111111111111111111111111111111111111111 "Apple Development: Jane Doe (PERSON0001)"
             3 valid identities found
        """

    var teams: [SigningTeam] { SigningState.parseTeams(defaultsOutput) }

    @Test func parsesTeamsFromDefaultsOutput() {
        #expect(teams.map(\.id) == ["FREE000001", "ABCDE12345"])
        #expect(teams[0].isFree)
        #expect(teams[1].label == "ABCDE12345 (Example, Inc., Company)")
    }

    @Test func parsesEachIdentityOnce() {
        let identities = SigningState.parseIdentities(findIdentityOutput)
        #expect(identities.map(\.kind) == ["Apple Development", "Apple Distribution"])
        #expect(identities[0].isDevelopment)
    }

    @Test func picksRequestedTeamOverStoredTeam() throws {
        let choice = try TeamChoice.pick(team: "abcde12345", stored: "FREE000001", signing: SigningState(teams: teams, identities: []))
        #expect(choice.team == "ABCDE12345")
        #expect(choice.source == "--team")
    }

    @Test func malformedTeamIsRejected() {
        #expect(throws: DeviceLoopError.self) {
            try TeamChoice.pick(team: "Example", stored: nil, signing: SigningState(teams: [], identities: []))
        }
    }

    @Test func picksStoredTeamBeforeXcodeTeams() throws {
        let choice = try TeamChoice.pick(team: nil, stored: "FREE000001", signing: SigningState(teams: teams, identities: []))
        #expect(choice.team == "FREE000001")
        #expect(choice.source == "config.json")
    }

    @Test func prefersTeamWithDevelopmentIdentity() throws {
        let identity = SigningIdentity(
            sha1: String(repeating: "1", count: 40),
            name: "Apple Development: Jane Doe (PERSON0001)",
            team: "FREE000001"
        )
        let choice = try TeamChoice.pick(team: nil, stored: nil, signing: SigningState(teams: teams, identities: [identity]))
        #expect(choice.team == "FREE000001")
    }

    @Test func prefersPaidTeamWithoutIdentities() throws {
        let choice = try TeamChoice.pick(team: nil, stored: nil, signing: SigningState(teams: teams, identities: []))
        #expect(choice.team == "ABCDE12345")
        #expect(choice.line.contains("Other teams: FREE000001"))
    }

    @Test func noTeamsLeavesTeamUnset() throws {
        let choice = try TeamChoice.pick(team: nil, stored: nil, signing: SigningState(teams: [], identities: []))
        #expect(choice.team == nil)
    }

    @Test func storedTeamUnknownToXcodeWarns() throws {
        let checks = DoctorReport.signingChecks(SigningState(teams: teams, identities: []), stored: "ZZZZZ99999")
        let check = try #require(checks.first { $0.name == "deviceloop team" })
        #expect(check.status == .warn)
        #expect(check.fix == "deviceloop setup --team ABCDE12345")
    }

    @Test func missingDevelopmentIdentityWarns() throws {
        let checks = DoctorReport.signingChecks(SigningState(teams: teams, identities: []), stored: "ABCDE12345")
        let check = try #require(checks.first { $0.name == "identities" })
        #expect(check.status == .warn)
    }
}
