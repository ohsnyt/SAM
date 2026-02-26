import AppIntents

enum RoleFilter: String, AppEnum {
    case any
    case client
    case lead
    case applicant
    case agent
    case referralPartner
    case vendor
    case externalAgent

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Role"

    static var caseDisplayRepresentations: [RoleFilter: DisplayRepresentation] = [
        .any: "Any",
        .client: "Client",
        .lead: "Lead",
        .applicant: "Applicant",
        .agent: "Agent",
        .referralPartner: "Referral Partner",
        .vendor: "Vendor",
        .externalAgent: "External Agent",
    ]

    /// Maps this filter to the raw badge string used in `SamPerson.roleBadges`.
    var badgeString: String? {
        switch self {
        case .any: return nil
        case .client: return "Client"
        case .lead: return "Lead"
        case .applicant: return "Applicant"
        case .agent: return "Agent"
        case .referralPartner: return "Referral Partner"
        case .vendor: return "Vendor"
        case .externalAgent: return "External Agent"
        }
    }
}
