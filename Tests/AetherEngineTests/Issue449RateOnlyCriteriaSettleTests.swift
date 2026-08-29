import Testing
@testable import AetherEngine

// AE#449: with the #447 holdback down to 6 s the first live manifest arrives ~1.2 s into a native join, and
// the term deciding press-to-motion became the display-criteria gate rather than the manifest. On the
// reporter's panel a `rate=50.000` write to a display already running 50.002 Hz still posts a mode-switch
// start, never posts an end, and holds `isDisplayModeSwitchInProgress` for the whole 2 s cap: eight of nine
// gates in an 18 minute session spent it in full, with the first frame visibly frozen on screen for 0.89 s.
//
// The gate now reads the panel's own cadence instead of waiting out a notification that is not coming. These
// are the pure halves of that decision.
@Suite("AE#449 rate-only criteria satisfied by the panel's measured cadence")
struct Issue449RateOnlyCriteriaSettleTests {

    // MARK: - Relating the measured cadence to the requested rate

    @Test("A panel reading slightly off nominal is still running the requested rate")
    func offNominalPanelIsAnExactMatch() {
        // The reporter's numbers: requested 50.000, panel 50.002.
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: 50.002)
                == .exact(panelRate: 50.002))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 59.94, panelNominalRate: 59.9401)
                == .exact(panelRate: 59.9401))
    }

    @Test("23.976 and 24.000 stay different modes: the pair the tolerance is sized against")
    func filmRatesDoNotCollapse() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 23.976, panelNominalRate: 24.0)
                == .different(panelRate: 24.0))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 24.0, panelNominalRate: 23.976)
                == .different(panelRate: 23.976))
    }

    @Test("29.97 against a 60.000 panel is not a multiple: 2x29.97 is 59.94, a different mode")
    func ntscPairIsNotAMultipleOfTheIntegerRate() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 29.97, panelNominalRate: 60.0)
                == .different(panelRate: 60.0))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 29.97, panelNominalRate: 59.94)
                == .multiple(panelRate: 59.94, factor: 2))
    }

    @Test("A 50 Hz panel is an exact double of a 25.000 request, which tvOS itself leaves alone")
    func halfRateContentIsAMultiple() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 25.0, panelNominalRate: 50.002)
                == .multiple(panelRate: 50.002, factor: 2))
    }

    @Test("A panel running the old mode is neither, so the gate keeps waiting")
    func realSwitchInFlightReadsAsDifferent() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: 60.0)
                == .different(panelRate: 60.0))
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 23.976, panelNominalRate: 60.0)
                == .different(panelRate: 60.0))
    }

    @Test("No fresh tick and no requested rate both read as unmeasured")
    func missingInputsAreUnmeasured() {
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: nil)
                == .unmeasured)
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: nil, panelNominalRate: 50.002)
                == .unmeasured)
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 0, panelNominalRate: 50.002)
                == .unmeasured)
        #expect(DisplayCriteriaController.panelRateRelation(requestedRate: 50.0, panelNominalRate: 0)
                == .unmeasured)
    }

    // MARK: - What may end the settle wait

    @Test("An exact match ends the wait for the engine's own rate-only write")
    func exactMatchSettlesRateOnly() {
        #expect(DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .exact(panelRate: 50.002)))
    }

    @Test("A multiple does not: both cadences satisfy the request, so a switch to the requested rate could still be in flight")
    func multipleDoesNotSettle() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .multiple(panelRate: 50.002, factor: 2)))
    }

    @Test("A panel in another mode, or one not presenting at all, does not settle anything")
    func differentAndUnmeasuredDoNotSettle() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .different(panelRate: 60.0)))
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineRateOnly, relation: .unmeasured))
    }

    @Test("A matching rate says nothing about a dynamic-range handshake, so an HDR write is never settled by it")
    func hdrWriteIsNeverSettledByRate() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .engineHDR, relation: .exact(panelRate: 50.002)))
    }

    @Test("A switch the engine did not initiate has no requested rate to be compared against")
    func hostDrivenWriteIsNeverSettledByRate() {
        #expect(!DisplayCriteriaController.rateOnlySwitchIsSettled(
            attribution: .hostDriven, relation: .exact(panelRate: 50.002)))
    }

    // MARK: - Log vocabulary

    @Test("Each relation names the panel rate it was read from, so a retest can separate the cases")
    func logDescriptionsCarryTheMeasurement() {
        #expect(DisplayCriteriaController.PanelRateRelation.exact(panelRate: 50.002)
            .logDescription.contains("50.002"))
        #expect(DisplayCriteriaController.PanelRateRelation.multiple(panelRate: 50.002, factor: 2)
            .logDescription.contains("x2"))
        #expect(DisplayCriteriaController.PanelRateRelation.different(panelRate: 60.0)
            .logDescription.contains("60.000"))
        #expect(DisplayCriteriaController.PanelRateRelation.unmeasured
            .logDescription.contains("unmeasured"))
    }
}
