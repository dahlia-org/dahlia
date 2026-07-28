@testable import Dahlia
import Foundation

#if canImport(Testing)
    import Testing

    @MainActor
    @Suite(.serialized)
    struct CustomerIntelligenceNavigationHistoryTests {
        @Test
        func linkedContactNavigationCanReturnToTheSelectedOrganization() async {
            let settings = AppSettings.shared
            let previousSection = settings.customerIntelligenceSectionRawValue
            let previousScope = settings.customerIntelligenceScopeRawValue
            defer {
                settings.customerIntelligenceSectionRawValue = previousSection
                settings.customerIntelligenceScopeRawValue = previousScope
            }
            let rootID = UUID()
            let departmentID = UUID()
            let contactID = UUID()
            settings.customerIntelligenceSectionRawValue = CustomerIntelligenceSection.organizations.rawValue
            settings.customerIntelligenceScopeRawValue = rootID.uuidString
            let model = CustomerIntelligenceWorkspaceViewModel(dbQueue: nil, vaultID: nil)
            model.selection.organizationID = departmentID

            await model.openContact(contactID)

            #expect(model.section == .contacts)
            #expect(model.selection.contactID == contactID)
            #expect(model.canGoBack)

            await model.goBack()

            #expect(model.section == .organizations)
            #expect(model.scope == .organization(rootID))
            #expect(model.selection.organizationID == departmentID)
            #expect(model.canGoForward)

            await model.goForward()

            #expect(model.section == .contacts)
            #expect(model.selection.contactID == contactID)
        }

        @Test
        func newNavigationAfterGoingBackClearsForwardHistory() async {
            let settings = AppSettings.shared
            let previousSection = settings.customerIntelligenceSectionRawValue
            let previousScope = settings.customerIntelligenceScopeRawValue
            defer {
                settings.customerIntelligenceSectionRawValue = previousSection
                settings.customerIntelligenceScopeRawValue = previousScope
            }
            settings.customerIntelligenceSectionRawValue = CustomerIntelligenceSection.overview.rawValue
            settings.customerIntelligenceScopeRawValue = ""
            let model = CustomerIntelligenceWorkspaceViewModel(dbQueue: nil, vaultID: nil)

            model.selectSection(.contacts)
            await model.goBack()
            #expect(model.canGoForward)

            model.selectSection(.topics)

            #expect(!model.canGoForward)
            #expect(model.section == .topics)
        }
    }
#endif
