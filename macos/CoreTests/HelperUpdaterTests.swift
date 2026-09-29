import XCTest

final class HelperUpdaterTests: XCTestCase {
    private func setup() -> (HelperUpdater, FakeBridge, FakeClock) {
        let bridge = FakeBridge(), clock = FakeClock()
        return (HelperUpdater(bridge: bridge, clock: clock), bridge, clock)
    }
    private func session(_ status: SessionStatus) -> Session {
        Session(profileId: "profile-not-in-app", sessionId: "s1", status: status)
    }

    func testMatchingHelperAndUnbundledDevDoNotRestart() throws {
        let (u, f, _) = setup()
        for _ in 0..<3 { XCTAssertEqual(try u.refresh().helper.status, "enabled") }
        XCTAssertEqual(f.replacements, 0)
        XCTAssertEqual(f.calls.filter { $0 == "identity:identity" }.count, 1)
        let (dev, fake, _) = setup(); fake.bundled = nil; fake.running = "older"
        XCTAssertEqual(try dev.refresh().helper.status, "enabled")
        XCTAssertEqual(fake.replacements, 0)
    }

    func testReplacesOldOrLegacyHelperOnceThenVerifiesIdentity() throws {
        for running: String? in ["older", nil] {
            let (u, f, _) = setup(); f.running = running
            for _ in 0..<4 { XCTAssertEqual(try u.refresh().helper.status, "updating") }
            XCTAssertEqual(f.replacements, 1)
            f.status = "enabled"; f.running = "current"
            XCTAssertTrue(try u.refresh().updated)
            XCTAssertFalse(try u.refresh().updated)
            XCTAssertEqual(f.replacements, 1)
        }
    }

    func testWaitsForEveryActiveSessionAndDoesNotReplaceDuringQuit() throws {
        for status in SessionStatus.allCases where status.active {
            let (u, f, _) = setup(); f.running = nil; f.sessions = [session(status)]
            let pending = try u.refresh()
            XCTAssertEqual(pending.helper.status, "update_pending")
            XCTAssertTrue(try XCTUnwrap(pending.sessions).first!.active)
            XCTAssertEqual(f.replacements, 0)
            f.sessions[0].status = .disconnected
            XCTAssertEqual(try u.refresh(allowUpdate: false).helper.status, "update_pending")
            XCTAssertEqual(f.replacements, 0)
            XCTAssertEqual(try u.refresh().helper.status, "updating")
            XCTAssertEqual(f.replacements, 1)
        }
    }

    func testDisabledOrUnapprovedHelperNeverAutomaticallyRegisters() throws {
        for status in ["not_registered", "requires_approval"] {
            let (u, f, _) = setup(); f.status = status
            XCTAssertEqual(try u.refresh().helper.status, status)
            XCTAssertEqual(f.calls, ["service:status"])
        }
    }

    func testNotFoundOnLaunchRepairsWithoutStoppingHelper() throws {
        let (u, f, _) = setup(); f.status = "not_found"
        XCTAssertEqual(try u.refresh().helper.status, "updating")
        XCTAssertEqual(f.registrations, 1); XCTAssertEqual(f.replacements, 0)
        XCTAssertTrue(try u.refresh().updated)
        _ = try u.refresh(); XCTAssertEqual(f.registrations, 1)
    }

    func testMissingRegistrationAfterStopRetriesThenVerifies() throws {
        for missing in ["registration_pending", "not_found", "not_registered"] {
            let (u, f, clock) = setup(); f.running = nil
            _ = try u.refresh(); f.status = missing; f.registrationStatus = "not_found"
            XCTAssertEqual(try u.refresh().helper.status, "updating")
            XCTAssertEqual(f.registrations, 1)
            clock.monotonic = 1; XCTAssertEqual(try u.refresh().helper.status, "updating")
            XCTAssertEqual(f.registrations, 1)
            f.registrationStatus = "enabled"; clock.monotonic = 2
            XCTAssertEqual(try u.refresh().helper.status, "updating")
            f.running = "current"; clock.monotonic = 3
            XCTAssertTrue(try u.refresh().updated)
            XCTAssertEqual(f.registrations, 2); XCTAssertEqual(f.replacements, 1)
            XCTAssertFalse(f.calls.contains("service:register")); XCTAssertFalse(f.calls.contains("service:reset_update"))
        }
    }

    func testExplicitRetryCompletesLostRegistration() throws {
        let (u, f, _) = setup(); f.running = nil; _ = try u.refresh(); f.status = "update_failed"
        XCTAssertEqual(try u.refresh().helper.status, "update_failed")
        f.status = "not_registered"; try u.retry()
        XCTAssertEqual(try u.refresh().helper.status, "updating")
        f.running = "current"; XCTAssertTrue(try u.refresh().updated)
        XCTAssertEqual(f.registrations, 1); XCTAssertEqual(f.replacements, 1)
    }

    func testPersistentNotFoundHasBoundedRegistrationRetries() throws {
        let (u, f, clock) = setup(); f.status = "not_found"; f.registrationStatus = "registration_pending"
        for second in [0, 2, 4, 6, 8, 10, 44] {
            clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "updating")
        }
        for second in [46, 60] {
            clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "update_failed")
        }
        XCTAssertEqual(f.registrations, 3); XCTAssertEqual(f.replacements, 0)
        try u.retry(); f.registrationStatus = "enabled"; clock.monotonic = 62
        _ = try u.refresh(); clock.monotonic = 63; XCTAssertTrue(try u.refresh().updated)
    }

    func testApprovalAndPermanentRegistrationErrorsDoNotRetry() throws {
        let (u, f, _) = setup(); f.status = "not_found"; f.registrationStatus = "requires_approval"
        for _ in 0..<4 { XCTAssertEqual(try u.refresh().helper.status, "requires_approval") }
        XCTAssertEqual(f.registrations, 1); f.status = "enabled"; XCTAssertTrue(try u.refresh().updated)
        let (v, g, _) = setup(); g.status = "not_found"; g.registrationError = true
        for _ in 0..<3 { XCTAssertEqual(try v.refresh().helper.status, "update_failed") }
        XCTAssertEqual(g.registrations, 1)
    }

    func testNotFoundNeverInstallsInvalidBundleDevOrDuringQuit() throws {
        let (u, f, _) = setup(); f.status = "not_found"
        XCTAssertEqual(try u.refresh(allowUpdate: false).helper.status, "not_found")
        XCTAssertEqual(f.registrations, 0); f.identityError = true
        XCTAssertEqual(try u.refresh().helper.status, "update_failed"); XCTAssertEqual(f.registrations, 0)
        let (v, g, _) = setup(); g.status = "not_found"; g.bundled = nil
        XCTAssertEqual(try v.refresh().helper.status, "not_found"); XCTAssertEqual(g.registrations, 0)
    }

    func testRecoveredRegistrationDefersActiveOldHelperReplacement() throws {
        let (u, f, _) = setup(); f.status = "not_found"; f.running = nil; f.sessions = [session(.connected)]
        _ = try u.refresh(); XCTAssertEqual(try u.refresh().helper.status, "update_pending")
        XCTAssertEqual(f.replacements, 0); f.sessions = []
        XCTAssertEqual(try u.refresh().helper.status, "updating"); XCTAssertEqual(f.replacements, 1)
    }

    func testApprovalAfterReplacementHasNoDeadline() throws {
        let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh(); f.status = "requires_approval"
        clock.monotonic = 300; XCTAssertEqual(try u.refresh().helper.status, "requires_approval")
        f.status = "enabled"; f.running = "current"; clock.monotonic = 600
        XCTAssertTrue(try u.refresh().updated); XCTAssertEqual(f.replacements, 1)
    }

    func testReplacementFailureLatchesAndRetryIsExplicit() throws {
        let (u, f, _) = setup(); f.running = nil; f.replaceError = true
        for _ in 0..<4 { XCTAssertEqual(try u.refresh().helper.status, "update_failed") }
        XCTAssertEqual(f.replacements, 1); f.replaceError = false; try u.retry()
        XCTAssertEqual(try u.refresh().helper.status, "updating"); XCTAssertEqual(f.replacements, 2)
        XCTAssertThrowsError(try u.retry()) { XCTAssertEqual(($0 as? AppError)?.code, "helper_updating") }
    }

    func testAsyncFailureAndWrongIdentityNeverReportSuccess() throws {
        for status in ["update_failed", "enabled"] {
            let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh(); f.status = status
            clock.monotonic = 1
            XCTAssertEqual(try u.refresh().helper.status, status == "enabled" ? "updating" : "update_failed")
            clock.monotonic = 46; XCTAssertEqual(try u.refresh().helper.status, "update_failed")
            XCTAssertEqual(f.replacements, 1)
        }
    }

    func testWaitAndXPCFailureHaveBoundedVerification() throws {
        for status in ["updating", "enabled"] {
            let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh(); f.status = status; f.snapshotError = true
            clock.monotonic = 1; XCTAssertEqual(try u.refresh().helper.status, "updating")
            clock.monotonic = 46; XCTAssertEqual(try u.refresh().helper.status, "update_failed")
            XCTAssertEqual(f.replacements, 1)
        }
    }

    func testBadSignatureAndCleanupFailureDoNotRestart() throws {
        let (u, f, _) = setup(); f.identityError = true; f.sessions = [session(.connected)]
        for _ in 0..<2 {
            let failed = try u.refresh(); XCTAssertEqual(failed.helper.status, "update_failed")
            XCTAssertTrue(try XCTUnwrap(failed.sessions).first!.active)
        }
        XCTAssertEqual(f.replacements, 0)
        let (v, g, _) = setup(); g.running = nil; var failed = session(.error); failed.errorCode = "cleanup_failed"; g.sessions = [failed]
        XCTAssertEqual(try v.refresh().helper.status, "update_failed"); XCTAssertEqual(g.replacements, 0)
    }

    func testTransientXPCFailureRecoversWithoutReplacement() throws {
        let (u, f, _) = setup(); _ = try u.refresh(); f.snapshotError = true
        let recovering = try u.refresh(); XCTAssertEqual(recovering.helper.status, "recovering"); XCTAssertNil(recovering.sessions)
        f.snapshotError = false; XCTAssertEqual(try u.refresh().helper.status, "enabled"); XCTAssertEqual(f.replacements, 0)
    }

    func testUnresponsiveApprovedHelperRecoversOnlyOnce() throws {
        let (u, f, clock) = setup(); _ = try u.refresh(); f.snapshotError = true
        for second in [0, 2, 4] {
            clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "recovering")
        }
        XCTAssertEqual(f.replacements, 0); clock.monotonic = 6
        XCTAssertEqual(try u.refresh().helper.status, "updating"); XCTAssertEqual(f.replacements, 1)
        f.status = "registration_pending"; clock.monotonic = 7; _ = try u.refresh()
        f.snapshotError = false; clock.monotonic = 8; XCTAssertEqual(try u.refresh().helper.status, "enabled")
        f.snapshotError = true
        for second in [10, 12, 16, 30, 60] { clock.monotonic = Double(second); _ = try u.refresh() }
        clock.monotonic = 62; XCTAssertEqual(try u.refresh().helper.status, "update_failed")
        XCTAssertEqual(f.replacements, 1)
    }

    func testRepairRestartsUnavailableButNotUnapprovedHelper() throws {
        let (u, f, _) = setup(); f.snapshotError = true
        XCTAssertEqual(try u.refresh().helper.status, "updating"); try u.retry()
        XCTAssertEqual(try u.refresh().helper.status, "updating"); XCTAssertEqual(f.replacements, 1)
        let (v, g, _) = setup(); _ = try v.refresh(); g.status = "requires_approval"; g.snapshotError = true
        XCTAssertEqual(try v.refresh().helper.status, "requires_approval")
        XCTAssertEqual(g.replacements, 0); XCTAssertEqual(g.registrations, 0)
    }

    func testRecoveryNeverReplacesDuringQuitOrFromInvalidBundle() throws {
        let (u, f, clock) = setup(); _ = try u.refresh(); f.snapshotError = true
        for second in [0, 2, 8, 30] { clock.monotonic = Double(second); _ = try u.refresh(allowUpdate: false) }
        XCTAssertEqual(f.replacements, 0)
        let (v, g, _) = setup(); g.snapshotError = true; g.identityError = true; try v.retry()
        XCTAssertEqual(try v.refresh().helper.status, "update_failed"); XCTAssertEqual(g.replacements, 0)
    }

    func testFirstLaunchRecoversWithoutManualRetry() throws {
        let (u, f, clock) = setup(); f.snapshotError = true
        for second in [0, 2, 6] { clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "updating") }
        XCTAssertEqual(f.replacements, 1); f.status = "registration_pending"; clock.monotonic = 7
        XCTAssertEqual(try u.refresh().helper.status, "updating"); f.snapshotError = false; clock.monotonic = 8
        XCTAssertTrue(try u.refresh().updated)
        XCTAssertEqual(f.registrations, 1); XCTAssertEqual(f.replacements, 1)
        XCTAssertFalse(f.calls.contains("service:reset_update")); XCTAssertFalse(f.calls.contains("service:register"))
        for second in [10, 20, 60] { clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "enabled") }
        XCTAssertEqual(f.replacements, 1)
    }

    func testStartupDelayDoesNotRestartMatchingHelper() throws {
        let (u, f, clock) = setup(); f.snapshotError = true
        XCTAssertEqual(try u.refresh().helper.status, "updating"); XCTAssertEqual(f.replacements, 0)
        f.snapshotError = false; clock.monotonic = 2
        XCTAssertEqual(try u.refresh().helper.status, "enabled"); XCTAssertEqual(f.replacements, 0)
    }

    func testOldProcessReplyReopensChannelOnce() throws {
        let (u, f, clock) = setup(); f.running = "older"; _ = try u.refresh(); f.status = "enabled"
        for second in [1, 2, 10, 20] {
            clock.monotonic = Double(second); let result = try u.refresh()
            XCTAssertEqual(result.helper.status, "updating"); XCTAssertFalse(result.updated)
        }
        XCTAssertEqual(f.calls.filter { $0 == "service:reconnect" }.count, 1)
        XCTAssertEqual(f.replacements, 1); f.running = "current"; clock.monotonic = 21
        XCTAssertTrue(try u.refresh().updated); XCTAssertEqual(f.replacements, 1)
    }

    func testLateVerifiedStartupClearsFailure() throws {
        for status in ["enabled", "update_failed"] {
            let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh(); f.status = "enabled"; f.snapshotError = true
            clock.monotonic = 1; XCTAssertEqual(try u.refresh().helper.status, "updating")
            clock.monotonic = 46; XCTAssertEqual(try u.refresh().helper.status, "update_failed")
            f.status = status; f.snapshotError = false; f.running = "current"; clock.monotonic = 47
            XCTAssertTrue(try u.refresh().updated)
            XCTAssertEqual(f.replacements, 1); XCTAssertEqual(f.registrations, 0)
            clock.monotonic = 48; XCTAssertFalse(try u.refresh().updated)
        }
    }

    func testDelayedRegistrationFinishesAfterLastBoundedCall() throws {
        let (u, f, clock) = setup(); f.status = "not_found"; f.registrationStatus = "registration_pending"
        for second in [0, 2, 4, 6, 12] { clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "updating") }
        XCTAssertEqual(f.registrations, 3); f.status = "enabled"; clock.monotonic = 13
        XCTAssertTrue(try u.refresh().updated); XCTAssertEqual(f.registrations, 3)
    }

    func testUnregisterRegistrationVerificationHaveSeparateDeadlines() throws {
        let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh()
        f.status = "registration_pending"; f.registrationStatus = "registration_pending"
        for second in [40, 42, 44, 60] { clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "updating") }
        f.status = "enabled"; f.snapshotError = true
        for second in [70, 90] { clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "updating") }
        f.running = "current"; f.snapshotError = false; clock.monotonic = 100
        XCTAssertTrue(try u.refresh().updated); XCTAssertEqual(f.replacements, 1); XCTAssertEqual(f.registrations, 3)
    }

    func testTemporaryUnregisterFailuresHaveFixedRetryLimit() throws {
        let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh()
        for second in [1, 4] {
            f.status = "update_retry_pending"; let before = f.replacements
            for offset in [0, 1] {
                clock.monotonic = Double(second + offset); XCTAssertEqual(try u.refresh().helper.status, "updating")
                XCTAssertEqual(f.replacements, before)
            }
            clock.monotonic = Double(second + 2); XCTAssertEqual(try u.refresh().helper.status, "updating")
            XCTAssertEqual(f.replacements, before + 1)
        }
        f.status = "update_retry_pending"
        for second in [7, 30, 90] { clock.monotonic = Double(second); XCTAssertEqual(try u.refresh().helper.status, "update_failed") }
        XCTAssertEqual(f.replacements, 3)
    }

    func testStartupRecoveryRequiresValidBundle() throws {
        for bundled: String? in [nil, "current"] {
            let (u, f, clock) = setup(); f.bundled = bundled; f.identityError = bundled != nil; f.snapshotError = true
            for second in [0, 3, 10, 60] {
                clock.monotonic = Double(second)
                XCTAssertEqual(try u.refresh().helper.status, bundled == nil ? "unavailable" : "update_failed")
            }
            XCTAssertEqual(f.replacements, 0); XCTAssertEqual(f.registrations, 0)
        }
    }

    func testLateUnregisterCompletionFinishesWithoutSecondRestart() throws {
        let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh()
        clock.monotonic = 46; XCTAssertEqual(try u.refresh().helper.status, "update_failed")
        f.status = "registration_pending"; clock.monotonic = 47; _ = try u.refresh(allowUpdate: false)
        XCTAssertEqual(f.registrations, 0); clock.monotonic = 48
        XCTAssertEqual(try u.refresh().helper.status, "updating"); XCTAssertEqual(f.registrations, 1)
        f.running = "current"; clock.monotonic = 49; XCTAssertTrue(try u.refresh().updated)
        XCTAssertEqual(f.replacements, 1)
    }

    func testTemporaryUnregisterErrorRecoversAutomatically() throws {
        let (u, f, clock) = setup(); f.running = nil; _ = try u.refresh(); f.status = "update_retry_pending"
        clock.monotonic = 1; _ = try u.refresh(); clock.monotonic = 3; _ = try u.refresh()
        f.status = "registration_pending"; clock.monotonic = 4; _ = try u.refresh()
        f.running = "current"; clock.monotonic = 5; XCTAssertTrue(try u.refresh().updated)
        XCTAssertEqual(f.replacements, 2); XCTAssertEqual(f.registrations, 1)
    }
}
