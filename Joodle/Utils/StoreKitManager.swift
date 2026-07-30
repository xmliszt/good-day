//
//  StoreKitManager.swift
//  Joodle
//
//  Created by StoreKit Manager
//

import Foundation
import StoreKit
import Combine

enum JoodleProducts {
    static let monthly = "dev.liyuxuan.joodle.pro.monthly"
    static let yearly = "dev.liyuxuan.joodle.pro.yearly"
    static let lifetime = "dev.liyuxuan.joodle.pro.lifetime"
    /// Discounted lifetime SKU shown only during the per-user limited-time
    /// offer window. Unpromoted in App Store Connect, so it has no storefront
    /// surface — the app is the only way in.
    static let lifetimePromo = "dev.liyuxuan.joodle.pro.lifetime.promo50"

    /// Either of these grants the lifetime entitlement — every ownership
    /// check must treat them identically.
    static let lifetimeIDs: Set<String> = [lifetime, lifetimePromo]
}

@MainActor
class StoreKitManager: NSObject, ObservableObject {
    static let shared = StoreKitManager()

    @Published var products: [Product] = []
    @Published var purchasedProductIDs: Set<String> = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Subscription status details
    @Published var isInTrialPeriod = false
    @Published var subscriptionExpirationDate: Date?
    @Published var willAutoRenew = true
    @Published var isEligibleForIntroOffer = true
    @Published var currentProductID: String?  // The actual currently active subscription product
    @Published var hasRedeemedOfferCode = false  // Whether user redeemed an offer code (promo code)
    @Published var offerCodeId: String?  // The offer code identifier if applicable
    @Published var hasPendingOfferCode = false  // Whether there's an offer code queued for next renewal
    @Published var pendingOfferCodeId: String?  // The pending offer code identifier
    @Published var pendingPlanProductID: String?  // The product the subscription will renew to (if different from current)

    private let productIDs: [String] = [
        JoodleProducts.monthly,
        JoodleProducts.yearly,
        JoodleProducts.lifetime,
        JoodleProducts.lifetimePromo
    ]

    /// Whether the user owns the lifetime (non-consumable) purchase
    @Published var hasLifetimePurchase = false

    private var updateListenerTask: Task<Void, Never>?
    private var foregroundObserver: AnyCancellable?

    #if DEBUG
    /// When true, prevents updatePurchasedProducts from overwriting preview state
    var isPreviewMode = false
    #endif

    override init() {
        super.init()

        // Add StoreKit 1 observer for App Store promoted in-app purchases
        // This is required for handling purchases initiated from the App Store product page
        SKPaymentQueue.default().add(self)

        // Start listening for StoreKit 2 transaction updates
        updateListenerTask = listenForTransactions()
        setupForegroundObserver()

        Task {
            await loadProducts()
            await updatePurchasedProducts()
        }
    }

    deinit {
        updateListenerTask?.cancel()
        foregroundObserver?.cancel()
        // Remove StoreKit 1 observer
        SKPaymentQueue.default().remove(self)
    }

    // MARK: - Foreground Observer

    /// Listen for app returning to foreground to refresh subscription status
    /// This catches changes made in the system subscription management sheet
    private func setupForegroundObserver() {
        foregroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.updatePurchasedProducts()
                    // Also sync SubscriptionManager to update feature flags and UI state
                    await SubscriptionManager.shared.updateSubscriptionStatus()
                }
            }
    }

    // MARK: - Load Products

    func loadProducts() async {
        isLoading = true
        errorMessage = nil

        print("📦 StoreKit: Loading products for IDs: \(productIDs)")
        print("📦 StoreKit: Environment - \(getEnvironmentInfo())")

        do {
            let loadedProducts = try await Product.products(for: productIDs)
            print("📦 StoreKit: Loaded \(loadedProducts.count) products")

            for product in loadedProducts {
                print("📦 Product: \(product.id)")
                print("   💰 Display Name: \(product.displayName)")
                print("   💰 Display Price: \(product.displayPrice)")
                print("   💰 Raw Price: \(product.price)")
                print("   💰 Currency Code: \(product.priceFormatStyle.currencyCode)")
                print("   🌍 Locale: \(product.priceFormatStyle.locale.identifier)")
            }

            self.products = loadedProducts.sorted { product1, product2 in
                // Sort monthly first, then yearly
                if product1.id.contains("monthly") {
                    return true
                }
                return false
            }

            if loadedProducts.isEmpty {
                let troubleshootingMessage = """
                No products found. This typically means:

                1. Products not created in App Store Connect
                2. Products not in 'Ready to Submit' or 'Approved' status
                3. Product IDs don't match exactly
                4. Paid Applications Agreement not active
                5. Products just created (wait 24-48 hours for propagation)

                Expected IDs: \(productIDs.joined(separator: ", "))
                """
                errorMessage = String(localized: "Unable to load subscription plans. Please try again later.")
                print("⚠️ StoreKit: \(troubleshootingMessage)")
            }
        } catch let error as StoreKitError {
            let detailedError = handleStoreKitError(error)
            errorMessage = detailedError
            print("❌ StoreKit Error (StoreKitError): \(error)")
            print("❌ Detailed: \(detailedError)")
        } catch {
            errorMessage = String(localized: "Failed to load products: \(error.localizedDescription)")
            print("❌ StoreKit Error: \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Full error description: \(String(describing: error))")
        }

        isLoading = false
    }

    // MARK: - Debug Helpers

    private func getEnvironmentInfo() -> String {
        #if DEBUG
        return "DEBUG build"
        #else
        // Check if running from TestFlight
        if let receiptURL = Bundle.main.appStoreReceiptURL {
            if receiptURL.lastPathComponent == "sandboxReceipt" {
                return "TestFlight/Sandbox"
            } else if receiptURL.path.contains("sandboxReceipt") {
                return "TestFlight/Sandbox (path)"
            }
        }
        return "Production/App Store"
        #endif
    }

    private func handleStoreKitError(_ error: StoreKitError) -> String {
        switch error {
        case .unknown:
            return String(localized: "Unknown StoreKit error. Check App Store Connect configuration.")
        case .userCancelled:
            return String(localized: "Request was cancelled.")
        case .networkError(let underlyingError):
            return String(localized: "Network error: \(underlyingError.localizedDescription). Check internet connection.")
        case .systemError(let underlyingError):
            return String(localized: "System error: \(underlyingError.localizedDescription)")
        case .notAvailableInStorefront:
            return String(localized: "Products not available in your region. Check App Store Connect territories.")
        case .notEntitled:
            return String(localized: "Not entitled to access these products.")
        case .unsupported:
            return String(localized: "This device is not capable of making payments.")
        // `StoreKitError` gains cases across SDKs; anything not listed above is
        // caught by `@unknown default`, so don't name cases the current SDK
        // doesn't have — that fails to compile rather than degrading gracefully.
        @unknown default:
            return String(localized: "Unexpected StoreKit error: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase Product

    func purchase(_ product: Product, paywallSource: String? = nil) async throws -> Transaction? {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                // Check if the transaction is verified
                let transaction = try checkVerified(verification)

                // Update purchased products and sync with SubscriptionManager
                await updatePurchasedProducts()
                await SubscriptionManager.shared.refreshSubscriptionFromStoreKit()

                // Track subscription started
                AnalyticsManager.shared.trackSubscriptionStarted(
                    productId: product.id,
                    isTrial: isInTrialPeriod,
                    isOfferCode: hasRedeemedOfferCode,
                    offerCodeId: offerCodeId,
                    paywallSource: paywallSource
                )

                // Finish the transaction after we've updated our state
                await transaction.finish()

                return transaction

            case .userCancelled:
                // Track purchase cancelled (user cancelled)
                AnalyticsManager.shared.trackPaywallDismissed(source: paywallSource ?? "unknown", didPurchase: false)
                return nil

            case .pending:
                // Transaction is pending approval (Ask to Buy, SCA, etc.)
                // It will appear in Transaction.updates when approved
                return nil

            @unknown default:
                return nil
            }
        } catch {
            // Track purchase failed
            AnalyticsManager.shared.trackPurchaseFailed(
                productId: product.id,
                errorMessage: error.localizedDescription,
                paywallSource: paywallSource
            )
            throw error
        }
    }

    // MARK: - Restore Purchase

    func restorePurchases(paywallSource: String? = nil) async {
        isLoading = true
        errorMessage = nil

        do {
            // AppStore.sync() forces the app to get fresh transaction data from the App Store
            // This satisfies App Store Review Guidelines section 3.1.1 requirement for restore mechanism
            try await AppStore.sync()
            await updatePurchasedProducts()

            // Track restore result
            let success = hasActiveSubscription
            AnalyticsManager.shared.trackRestorePurchasesAttempted(success: success)
            if success, let productId = currentProductID {
                AnalyticsManager.shared.trackSubscriptionRestored(productId: productId, paywallSource: paywallSource)
            }
        } catch {
            errorMessage = String(localized: "Failed to restore purchase: \(error.localizedDescription)")
            debugPrint("Failed to restore purchase: \(error)")
            AnalyticsManager.shared.trackRestorePurchasesAttempted(success: false)
        }

        isLoading = false
    }

    // MARK: - Check Subscription Status

    func updatePurchasedProducts() async {
        #if DEBUG
        guard !isPreviewMode else { return }
        #endif

        var purchasedIDs: Set<String> = []
        var expirationDate: Date?
        var inTrial = false
        var autoRenew = false  // Default to false, will be set to true if we find an active subscription
        var eligibleForIntro = true
        var currentProduct: String?
        var redeemedOfferCode = false
        var offerCode: String?
        var pendingOfferCode = false
        var pendingOfferCodeId: String?
        var pendingPlanProduct: String?

        // Use Product.SubscriptionInfo.status for accurate current subscription detection
        // This is more reliable than Transaction.currentEntitlements for determining the CURRENT plan
        if let subscriptionProduct = products.first(where: { $0.subscription != nil }),
           let subscription = subscriptionProduct.subscription {
            do {
                let statuses = try await subscription.status

                for status in statuses {
                    // Only process active subscription states
                    guard status.state == .subscribed || status.state == .inGracePeriod || status.state == .inBillingRetryPeriod else {
                        continue
                    }

                    // Verify the status components
                    let renewalInfo = try checkVerified(status.renewalInfo)
                    let transactionInfo = try checkVerified(status.transaction)

                    // The transaction's productID is the CURRENTLY active subscription
                    currentProduct = transactionInfo.productID
                    purchasedIDs.insert(transactionInfo.productID)

                    // Check if in trial period or redeemed offer code
                    if let offer = transactionInfo.offer {
                        inTrial = (offer.type == .introductory)
                        redeemedOfferCode = (offer.type == .code)

                        // Get the offer code ID if available
                        if offer.type == .code {
                            offerCode = offer.id
                        }
                    }

                    // Get expiration date from the current transaction
                    if let expiration = transactionInfo.expirationDate {
                        expirationDate = expiration
                    }

                    // Check auto-renewal status
                    // renewalInfo.currentProductID shows what they'll renew to (could be different if they changed plans)
                    autoRenew = renewalInfo.willAutoRenew

                    // Detect pending plan change (e.g. user switched from yearly to monthly)
                    // renewalInfo.currentProductID = product that will be used at next renewal
                    // transactionInfo.productID = currently active product
                    // NOTE: StoreKit Testing (Xcode) does NOT report deferred downgrades via this API,
                    // even though its debug UI shows the change. This works correctly in production/TestFlight.
                    if renewalInfo.currentProductID != transactionInfo.productID {
                        pendingPlanProduct = renewalInfo.currentProductID
                    }

                    // Check for pending offer code in renewal info
                    // This detects when user redeems an offer code while still in intro/trial period
                    if let renewalOfferType = renewalInfo.offerType, renewalOfferType == .code {
                        pendingOfferCode = true
                        pendingOfferCodeId = renewalInfo.offerID
                    }

                    // We found an active subscription, no need to continue
                    break
                }
            } catch {
                debugPrint("Failed to get subscription status: \(error)")
            }
        }

        // Check intro offer eligibility on the user's current active subscription product
        // This must be done AFTER determining currentProduct to get accurate eligibility
        if let productID = currentProduct,
           let activeProduct = products.first(where: { $0.id == productID }),
           let subscription = activeProduct.subscription {
            eligibleForIntro = await subscription.isEligibleForIntroOffer
        } else if let anySubscriptionProduct = products.first(where: { $0.subscription != nil }),
                  let subscription = anySubscriptionProduct.subscription {
            // Fallback: If no current product (user not subscribed), check any subscription product
            eligibleForIntro = await subscription.isEligibleForIntroOffer
        }

        // Check for lifetime (non-consumable) purchase via currentEntitlements
        // Also serves as fallback if subscription.status found nothing
        var foundLifetimeProductID: String?
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checkVerified(result)

                if transaction.revocationDate == nil {
                    purchasedIDs.insert(transaction.productID)

                    // Lifetime purchase takes priority
                    if JoodleProducts.lifetimeIDs.contains(transaction.productID) {
                        foundLifetimeProductID = transaction.productID
                        currentProduct = transaction.productID
                    } else if currentProduct == nil {
                        // Only set subscription as current if we don't have one yet
                        currentProduct = transaction.productID
                    }
                }
            } catch {
                debugPrint("Failed to verify transaction: \(error)")
            }
        }

        // If lifetime is found, override subscription details
        let foundLifetime = foundLifetimeProductID != nil
        if let foundLifetimeProductID {
            currentProduct = foundLifetimeProductID
            expirationDate = nil  // Lifetime has no expiration
            autoRenew = false
            inTrial = false
            redeemedOfferCode = false
            pendingOfferCode = false
            pendingPlanProduct = nil
        }

        // StoreKit is the source of truth - always trust its response
        // If it returns empty, that means no active subscription
        self.purchasedProductIDs = purchasedIDs
        self.currentProductID = currentProduct
        self.isInTrialPeriod = inTrial
        self.subscriptionExpirationDate = expirationDate
        self.willAutoRenew = autoRenew
        self.isEligibleForIntroOffer = eligibleForIntro
        self.hasRedeemedOfferCode = redeemedOfferCode
        self.offerCodeId = offerCode
        self.hasPendingOfferCode = pendingOfferCode
        self.pendingOfferCodeId = pendingOfferCodeId
        self.pendingPlanProductID = pendingPlanProduct
        self.hasLifetimePurchase = foundLifetime

        print("📊 Subscription Status:")
        print("   Active: \(!purchasedIDs.isEmpty)")
        print("   Current Product: \(currentProduct ?? "None")")
        print("   Trial: \(inTrial)")
        print("   Offer Code Redeemed: \(redeemedOfferCode)")
        print("   Offer Code ID: \(offerCode ?? "N/A")")
        print("   Pending Offer Code: \(pendingOfferCode)")
        print("   Pending Offer Code ID: \(pendingOfferCodeId ?? "N/A")")
        print("   Expiration: \(expirationDate?.formatted() ?? "N/A")")
        print("   Auto-Renew: \(autoRenew)")
        print("   Eligible for Intro Offer: \(eligibleForIntro)")
        print("   Lifetime Purchase: \(foundLifetime)")
        print("   Pending Plan Change: \(pendingPlanProduct ?? "None")")
    }

    // MARK: - Transaction Verification

    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Transaction Listener

    /// Listen for transaction updates that happen outside the app
    /// This includes: renewals, cancellations, billing issues, Ask to Buy approvals,
    /// and purchases made on other devices
    private func listenForTransactions() -> Task<Void, Never> {
        return Task(priority: .background) { [weak self] in
            // Iterate through any pending/new transactions
            for await verificationResult in Transaction.updates {
                guard let self = self else { return }

                do {
                    // Only process verified transactions
                    let transaction = try self.checkVerified(verificationResult)

                    // Update our purchased products state
                    await self.updatePurchasedProducts()

                    // Notify SubscriptionManager to sync state and update widget
                    await SubscriptionManager.shared.refreshSubscriptionFromStoreKit()

                    // Finish the transaction only after successful processing
                    await transaction.finish()

                    debugPrint("✅ Transaction update processed: \(transaction.productID)")
                } catch {
                    // Transaction failed verification - log but don't finish
                    // Unverified transactions could be from jailbroken devices
                    debugPrint("❌ Transaction verification failed: \(error)")
                }
            }
        }
    }

    // MARK: - Helper Methods

    var hasActiveSubscription: Bool {
        !purchasedProductIDs.isEmpty
    }

    /// Returns the currently active subscription product
    var currentProduct: Product? {
        guard let productID = currentProductID else { return nil }
        return products.first { $0.id == productID }
    }

    var monthlyProduct: Product? {
        products.first { $0.id.contains("monthly") }
    }

    var yearlyProduct: Product? {
        products.first { $0.id.contains("yearly") }
    }

    /// The full-price lifetime product — exact match so the discounted promo
    /// SKU can never masquerade as the regular one.
    var lifetimeProduct: Product? {
        products.first { $0.id == JoodleProducts.lifetime }
    }

    /// The discounted lifetime SKU, shown only during the limited-time offer window.
    var lifetimePromoProduct: Product? {
        products.first { $0.id == JoodleProducts.lifetimePromo }
    }

    /// Whether the current active product is a lifetime (non-consumable) purchase
    var isLifetimeUser: Bool {
        currentProductID.map { JoodleProducts.lifetimeIDs.contains($0) } == true
    }

    func savingsPercentage() -> Int? {
        guard let monthly = monthlyProduct,
              let yearly = yearlyProduct else {
            print("⚠️ Cannot calculate savings: monthly or yearly product missing")
            return nil
        }

        let monthlyYearlyCost = monthly.price * 12
        let savings = monthlyYearlyCost - yearly.price

        // Convert to NSDecimalNumber for proper division
        let savingsNumber = NSDecimalNumber(decimal: savings)
        let costNumber = NSDecimalNumber(decimal: monthlyYearlyCost)

        // Perform division and multiply by 100 for percentage
        let percentageDecimal = savingsNumber.dividing(by: costNumber).multiplying(by: 100)
        let percentageInt = percentageDecimal.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )).intValue

        return percentageInt
    }
    
    /// Returns the formatted yearly savings amount (e.g., "$24.99")
    func yearlySavingsAmount() -> String? {
        guard let monthly = monthlyProduct,
              let yearly = yearlyProduct else {
            return nil
        }
        
        let monthlyYearlyCost = monthly.price * 12
        let savings = monthlyYearlyCost - yearly.price
        
        // Format using the product's price format style
        return savings.formatted(yearly.priceFormatStyle)
    }
}

// MARK: - SKPaymentTransactionObserver (StoreKit 1)

/// Required for handling App Store promoted in-app purchases
/// When a user taps on a promoted IAP on the App Store product page,
/// this observer allows the app to handle the purchase flow
extension StoreKitManager: SKPaymentTransactionObserver {

    /// Called when transactions are updated
    /// For StoreKit 2, we handle most transactions through Transaction.updates,
    /// but this is still needed for promoted in-app purchases
    nonisolated func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        // StoreKit 2 handles most transaction processing through Transaction.updates
        // This method is primarily here for the shouldAddStorePayment callback to work
        // We don't need to process transactions here since StoreKit 2 will handle them
    }

    /// Called when a user initiates an in-app purchase from the App Store
    /// Return true to continue the purchase immediately
    /// Return false to defer the purchase to a later time
    nonisolated func paymentQueue(_ queue: SKPaymentQueue, shouldAddStorePayment payment: SKPayment, for product: SKProduct) -> Bool {
        // Return true to allow the purchase to proceed immediately
        // The transaction will be processed through StoreKit 2's Transaction.updates
        //
        // If you need to defer the purchase (e.g., show a custom paywall first),
        // return false and manually add the payment later:
        // SKPaymentQueue.default().add(payment)
        return true
    }
}

// MARK: - Store Errors

enum StoreError: Error {
    case failedVerification
}
