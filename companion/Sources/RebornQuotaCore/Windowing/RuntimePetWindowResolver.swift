import Foundation

public struct RuntimePetLocation: Equatable, Sendable {
    public let petFrame: RectValue
    public let screenVisibleFrame: RectValue
    public let screenID: UInt32
    public let petLayer: Int

    public init(
        petFrame: RectValue,
        screenVisibleFrame: RectValue,
        screenID: UInt32,
        petLayer: Int
    ) {
        self.petFrame = petFrame
        self.screenVisibleFrame = screenVisibleFrame
        self.screenID = screenID
        self.petLayer = petLayer
    }
}

public enum RuntimePetWindowResolution: Equatable, Sendable {
    case visible(RuntimePetLocation)
    case hidden
}

/// Resolves the visible pet/card region inside Codex's larger transparent pet
/// window. The outer window also hosts transient status UI and blank layout
/// space, so using its center makes a companion bubble look detached from the
/// character. Codex exposes the movable pet region as one AXApplicationGroup.
public enum PetVisualAnchorResolver {
    public static func resolveCGBounds(
        in document: AXSnapshotDocument,
        correlatedWindowBounds: RectValue,
        tolerance: Double = 2
    ) -> RectValue? {
        guard document.trustedForAccessibility,
              document.coordinateSpace == .cgGlobalTopLeft,
              tolerance.isFinite,
              tolerance >= 0 else { return nil }

        let codexProcesses = document.processes.filter {
            $0.bundleID == "com.openai.codex"
        }
        guard codexProcesses.count == 1,
              let process = codexProcesses.first,
              process.windowsReadSucceeded,
              let root = process.tree,
              root.childrenReadSucceeded,
              root.childCount == root.children.count else { return nil }

        let windows = root.children.filter {
            AXWindowStructuralPredicate.rebornObserved.matches($0)
                && approximatelyEqual($0.bounds, correlatedWindowBounds, tolerance: tolerance)
        }
        guard windows.count == 1, let window = windows.first else { return nil }

        var candidates: [RectValue] = []
        collectApplicationGroups(in: window, into: &candidates)
        let contained = candidates.filter {
            isValidAnchor($0, inside: correlatedWindowBounds, tolerance: tolerance)
        }
        guard contained.count == 1 else { return nil }
        return contained[0]
    }

    private static func collectApplicationGroups(
        in node: AXNodeSnapshot,
        into result: inout [RectValue]
    ) {
        if node.subrole == "AXApplicationGroup", let bounds = node.bounds {
            result.append(bounds)
        }
        for child in node.children {
            collectApplicationGroups(in: child, into: &result)
        }
    }

    private static func isValidAnchor(
        _ anchor: RectValue,
        inside window: RectValue,
        tolerance: Double
    ) -> Bool {
        guard valid(anchor), valid(window), anchor.area < window.area else { return false }
        return anchor.minX >= window.minX - tolerance
            && anchor.minY >= window.minY - tolerance
            && anchor.maxX <= window.maxX + tolerance
            && anchor.maxY <= window.maxY + tolerance
    }

    private static func approximatelyEqual(
        _ lhs: RectValue?,
        _ rhs: RectValue,
        tolerance: Double
    ) -> Bool {
        guard let lhs else { return false }
        return abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func valid(_ rect: RectValue) -> Bool {
        rect.x.isFinite
            && rect.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }
}

public struct RuntimePetWindowResolver: Sendable {
    private let discriminator: PetWindowDiscriminator

    public init(gate: PetWindowGateConfiguration) {
        discriminator = PetWindowDiscriminator(gate: gate)
    }

    public func resolve(
        document: WindowSnapshotDocument,
        axDocument: AXSnapshotDocument?,
        accessibilityTrustedFallback: Bool = false
    ) -> RuntimePetWindowResolution {
        let axCandidate = discriminator.selectRuntimeCandidate(
            in: document,
            axDocument: axDocument
        )
        let candidate: WindowSnapshot
        let visualBounds: RectValue
        if let axCandidate {
            candidate = axCandidate
            visualBounds = axDocument.flatMap {
                PetVisualAnchorResolver.resolveCGBounds(
                    in: $0,
                    correlatedWindowBounds: axCandidate.bounds
                )
            } ?? axCandidate.bounds
        } else {
            guard accessibilityTrustedFallback,
                  let fallback = trustedExactCGFallback(in: document) else {
                return .hidden
            }
            candidate = fallback.candidate
            visualBounds = fallback.visualBounds
        }
        guard let converted = try? CoordinateConverter.convert(
            cgWindowBounds: visualBounds,
            screens: document.screens
        ), let screen = document.screens.first(where: { $0.id == converted.screenID }) else {
            return .hidden
        }
        return .visible(RuntimePetLocation(
            petFrame: converted.appKitBounds,
            screenVisibleFrame: screen.appKitVisibleFrame,
            screenID: screen.id,
            petLayer: candidate.layer
        ))
    }

    /// A deliberately narrow recovery path for Codex builds whose AX subtree is
    /// temporarily unreadable even though TCC reports the companion as trusted.
    /// It accepts only one on-screen window whose layer and exact dimensions match
    /// the recorded pet window, then applies the live-measured Reborn card offset.
    private func trustedExactCGFallback(
        in document: WindowSnapshotDocument,
        tolerance: Double = 2
    ) -> (candidate: WindowSnapshot, visualBounds: RectValue)? {
        guard (try? PersistedArtifactValidator.validateSnapshot(document)) != nil else {
            return nil
        }
        let observed = discriminator.gate.discriminator.evidence.visibleCandidateBounds
        let candidates = document.windows.filter {
            discriminator.gate.discriminator.matchesAXEnvelope($0)
                && abs($0.bounds.width - observed.width) <= tolerance
                && abs($0.bounds.height - observed.height) <= tolerance
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }

        // Measured from a successful AX-correlated live frame on the current
        // 356×320 Codex pet layout. Only the center and top edge affect an
        // above-pet bubble, but a contained card rectangle keeps conversion safe.
        let visualBounds = RectValue(
            x: candidate.bounds.x + 190,
            y: candidate.bounds.y + 179,
            width: 154,
            height: 130
        )
        guard visualBounds.minX >= candidate.bounds.minX,
              visualBounds.minY >= candidate.bounds.minY,
              visualBounds.maxX <= candidate.bounds.maxX + tolerance,
              visualBounds.maxY <= candidate.bounds.maxY + tolerance else {
            return nil
        }
        return (candidate, visualBounds)
    }
}
