import SwiftData
import SwiftUI

struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = OnboardingViewModel()

    var body: some View {
        NavigationStack(path: $viewModel.navigationPath) {
            // STARTING POINT
            DrawingEntryView(viewModel: viewModel)
                .navigationDestination(for: OnboardingStep.self) { step in
                    switch step {
                    case .drawingEntry:
                        // Should not happen via navigation, but handled for safety
                        DrawingEntryView(viewModel: viewModel)
                    case .valueProposition:
                        ValuePropView(viewModel: viewModel)
                    case .yearGridDemo:
                        InteractiveTutorialView(viewModel: viewModel)
                    case .handednessSetup:
                        HandednessSetupView(viewModel: viewModel)
                    case .featureIntroWidgets:
                        FeatureIntroWidgetsView(viewModel: viewModel)
                    case .icloudConfig:
                        iCloudConfigView(viewModel: viewModel)
                    case .dailyReminder:
                        DailyReminderConfigView(viewModel: viewModel)
                    case .proPaywall:
                        ProPaywallStepView(viewModel: viewModel)
                    case .onboardingCompletion:
                        OnboardingCompletionView(viewModel: viewModel)
                    }
                }
        }
        .tint(.primary) // Sets the back button color globally
        .onAppear {
            viewModel.modelContext = modelContext
        }
        .onChange(of: viewModel.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss {
                dismiss()
            }
        }
        .postHogScreenView("Onboarding")
    }
}

// MARK: - Pro Paywall Step

/// Onboarding step that shows the purchasable Joodle Pro paywall.
/// Buying advances as a Pro user; the muted "Skip" in the nav bar (level with
/// the back button) skips to a free account with the 7-doodle allowance. No
/// trial framing at this stage — the claimable 7-day trial is offered later,
/// at the doodle limit.
struct ProPaywallStepView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        PaywallContentView(configuration: PaywallConfiguration(
            context: .onboarding,
            useOnboardingStyle: true,
            paywallSource: "onboarding_paywall",
            onPurchaseComplete: {
                AnalyticsManager.shared.trackPaywallDismissed(source: "onboarding_paywall", didPurchase: true)
                viewModel.completeStep(.proPaywall)
            },
            onContinueFree: {
                AnalyticsManager.shared.trackPaywallDismissed(source: "onboarding_paywall", didPurchase: false)
                viewModel.completeStep(.proPaywall)
            }
        ))
        // The content forces its own dark scheme; this carries it out to the
        // window chrome so the status bar isn't left drawing dark glyphs on the
        // black background this step now has.
        .forcedWindowColorScheme(.dark)
        .postHogScreenView("Onboarding Paywall")
        .onAppear {
            AnalyticsManager.shared.trackPaywallViewed(source: "onboarding_paywall")
        }
    }
}
