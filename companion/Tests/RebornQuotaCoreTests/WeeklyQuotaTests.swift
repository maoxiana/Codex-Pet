import Foundation
import XCTest
@testable import RebornQuotaCore

final class WeeklyQuotaTests: XCTestCase {
    func testSelectsSecondary10080MinuteWindowAndConvertsUsedToRemaining() throws {
        let response = try loadFixture("rate-limits-secondary-weekly")

        let extraction = WeeklyQuotaExtractor.extract(from: response)

        XCTAssertEqual(
            extraction,
            WeeklyQuotaExtraction(
                quota: WeeklyQuota(
                    remainingPercent: 75,
                    resetsAt: Date(timeIntervalSince1970: 1_735_689_600),
                    fingerprint: "limitId=value:5:codex|secondary|used=25|reset=1735689600"
                ),
                warnings: []
            )
        )
    }

    func testFallsBackToPrimaryWhenOnlyPrimaryIsWeekly() throws {
        let response = try loadFixture("rate-limits-primary-weekly")

        let extraction = WeeklyQuotaExtractor.extract(from: response)

        XCTAssertEqual(extraction.quota?.remainingPercent, 60)
        XCTAssertEqual(extraction.quota?.resetsAt, Date(timeIntervalSince1970: 1_736_294_400))
        XCTAssertEqual(
            extraction.quota?.fingerprint,
            "limitId=value:10:fallback-a|primary|used=40|reset=1736294400"
        )
        XCTAssertEqual(extraction.warnings, [])
    }

    func testPrefersSecondaryAndEmitsWarningWhenBothAreWeekly() throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "primary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 100 },
                "secondary": { "usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 200 }
              }
            }
            """
        )

        let extraction = WeeklyQuotaExtractor.extract(from: response)

        XCTAssertEqual(extraction.quota?.remainingPercent, 80)
        XCTAssertEqual(extraction.quota?.resetsAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(
            extraction.quota?.fingerprint,
            "limitId=nil|secondary|used=20|reset=200"
        )
        XCTAssertEqual(
            extraction.warnings,
            ["Both primary and secondary rate-limit windows are weekly; selected secondary."]
        )
    }

    func testRejectsNullDurationAndNonWeeklyDurations() throws {
        let fixtureResponse = try loadFixture("rate-limits-no-weekly")
        let zeroDurationResponse = try decode(
            """
            {
              "rateLimits": {
                "primary": { "usedPercent": 10, "windowDurationMins": 0, "resetsAt": 100 },
                "secondary": { "usedPercent": 20, "windowDurationMins": 10081, "resetsAt": 200 }
              }
            }
            """
        )

        XCTAssertEqual(
            WeeklyQuotaExtractor.extract(from: fixtureResponse),
            WeeklyQuotaExtraction(quota: nil, warnings: [])
        )
        XCTAssertEqual(
            WeeklyQuotaExtractor.extract(from: zeroDurationResponse),
            WeeklyQuotaExtraction(quota: nil, warnings: [])
        )
    }

    func testClampsRemainingPercentToZeroThroughOneHundred() throws {
        let overused = try decode(weeklyResponse(usedPercent: 140))
        let negativeUsed = try decode(weeklyResponse(usedPercent: -20))

        XCTAssertEqual(WeeklyQuotaExtractor.extract(from: overused).quota?.remainingPercent, 0)
        XCTAssertEqual(WeeklyQuotaExtractor.extract(from: negativeUsed).quota?.remainingPercent, 100)
    }

    func testClampsInt32BoundariesWithoutOverflow() throws {
        let maximumUsed = try decode(weeklyResponse(usedPercent: .max))
        let minimumUsed = try decode(weeklyResponse(usedPercent: .min))

        XCTAssertEqual(WeeklyQuotaExtractor.extract(from: maximumUsed).quota?.remainingPercent, 0)
        XCTAssertEqual(WeeklyQuotaExtractor.extract(from: minimumUsed).quota?.remainingPercent, 100)
    }

    func testAllowsMissingResetTime() throws {
        let response = try decode(weeklyResponse(usedPercent: 33, resetsAt: "null"))

        let extraction = WeeklyQuotaExtractor.extract(from: response)

        XCTAssertEqual(extraction.quota?.remainingPercent, 67)
        XCTAssertNil(extraction.quota?.resetsAt)
        XCTAssertEqual(extraction.quota?.fingerprint, "limitId=nil|primary|used=33|reset=null")
        XCTAssertEqual(extraction.warnings, [])
    }

    func testPrefersRateLimitsByCodexIdOverCompatibilitySnapshot() throws {
        let response = try loadFixture("rate-limits-secondary-weekly")

        let extraction = WeeklyQuotaExtractor.extract(from: response)

        XCTAssertEqual(extraction.quota?.remainingPercent, 75)
        XCTAssertEqual(
            extraction.quota?.fingerprint,
            "limitId=value:5:codex|secondary|used=25|reset=1735689600"
        )
    }

    func testDecodesUsedPercentAsRequiredInt32() throws {
        let response = try loadFixture("rate-limits-secondary-weekly")

        let usedPercent: Int32 = try XCTUnwrap(
            response.rateLimitsByLimitId?["codex"]?.secondary
        ).usedPercent

        XCTAssertEqual(usedPercent, 25)
    }

    func testKeyedCodexAndCompatibilityCodexHaveEquivalentFingerprint() throws {
        let keyed = try decode(
            """
            {
              "rateLimits": {},
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "ignored-by-key",
                  "primary": { "usedPercent": 25, "windowDurationMins": 10080, "resetsAt": 100 }
                }
              }
            }
            """
        )
        let compatibility = try decode(weeklyResponse(usedPercent: 25, limitId: "codex"))

        let keyedFingerprint = WeeklyQuotaExtractor.extract(from: keyed).quota?.fingerprint
        let compatibilityFingerprint = WeeklyQuotaExtractor.extract(from: compatibility).quota?.fingerprint

        XCTAssertEqual(
            keyedFingerprint,
            "limitId=value:5:codex|primary|used=25|reset=100"
        )
        XCTAssertEqual(keyedFingerprint, compatibilityFingerprint)
    }

    func testDifferentCompatibilityLimitIdsDoNotCollide() throws {
        let first = try decode(weeklyResponse(usedPercent: 25, limitId: "alpha"))
        let second = try decode(weeklyResponse(usedPercent: 25, limitId: "beta"))

        let firstFingerprint = WeeklyQuotaExtractor.extract(from: first).quota?.fingerprint
        let secondFingerprint = WeeklyQuotaExtractor.extract(from: second).quota?.fingerprint

        XCTAssertEqual(firstFingerprint, "limitId=value:5:alpha|primary|used=25|reset=100")
        XCTAssertEqual(secondFingerprint, "limitId=value:4:beta|primary|used=25|reset=100")
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
    }

    func testDoesNotFallBackWhenKeyedCodexHasNoWeeklyWindow() throws {
        let response = try decode(
            """
            {
              "rateLimits": {
                "limitId": "codex",
                "primary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 100 }
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "primary": { "usedPercent": 20, "windowDurationMins": 300, "resetsAt": 200 }
                }
              }
            }
            """
        )

        XCTAssertEqual(
            WeeklyQuotaExtractor.extract(from: response),
            WeeklyQuotaExtraction(quota: nil, warnings: [])
        )
    }

    private func loadFixture(_ name: String) throws -> GetAccountRateLimitsResponse {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        return try JSONDecoder().decode(
            GetAccountRateLimitsResponse.self,
            from: Data(contentsOf: try XCTUnwrap(url))
        )
    }

    private func decode(_ json: String) throws -> GetAccountRateLimitsResponse {
        try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: Data(json.utf8))
    }

    private func weeklyResponse(
        usedPercent: Int32,
        resetsAt: String = "100",
        limitId: String? = nil
    ) -> String {
        let limitIdField = limitId.map { "\"limitId\": \"\($0)\"," } ?? ""
        return """
        {
          "rateLimits": {
            \(limitIdField)
            "primary": {
              "usedPercent": \(usedPercent),
              "windowDurationMins": 10080,
              "resetsAt": \(resetsAt)
            }
          }
        }
        """
    }
}
