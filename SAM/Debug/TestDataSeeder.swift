// TestDataSeeder.swift
// SAM — Harvey Snodgrass fictional test dataset
// DEBUG only. All names, phones, emails, and identifiers are entirely fictional.

#if DEBUG
import AppKit
import Foundation
import SwiftData
import OSLog

// MARK: - Test Data Active Flag

extension UserDefaults {
    /// When true, all real-data imports are suppressed and the app runs on seeded test data.
    var isTestDataActive: Bool {
        get { bool(forKey: "sam.testData.active") }
        set { set(newValue, forKey: "sam.testData.active") }
    }
}

// MARK: - Seeder

@MainActor
final class TestDataSeeder {

    static let shared = TestDataSeeder()
    private let logger = Logger(subsystem: "com.sam", category: "TestDataSeeder")

    private init() {}

    // MARK: - Public Entry Point

    /// Wipes all existing data, seeds Harvey Snodgrass test data in-process,
    /// then restarts the app cleanly.
    ///
    /// The previous approach called NSApplication.terminate() *before* seeding,
    /// which triggered a Metal crash: GPU command buffers were still alive from
    /// in-flight AI inference when the process tore down Metal objects.
    ///
    /// This version:
    /// 1. Cancels all background tasks
    /// 2. Seeds the data into a fresh in-process container (no GPU activity involved)
    /// 3. Sets the lockout flag
    /// 4. Only then terminates — by this point AI inference is idle and Metal
    ///    objects can be destroyed safely
    func seedFresh() async {
        logger.notice("TestDataSeeder: beginning fresh seed")

        // 1. Cancel all in-flight imports so no SwiftData writes are in progress
        ContactsImportCoordinator.shared.cancelAll()
        CalendarImportCoordinator.shared.cancelAll()
        MailImportCoordinator.shared.cancelAll()
        CommunicationsImportCoordinator.shared.cancelAll()
        EvernoteImportCoordinator.shared.cancelAll()

        // 2. Brief yield so queued main-actor work drains
        try? await Task.sleep(for: .milliseconds(300))

        // 3. Delete the store files
        if let storeURL = SAMModelContainer.shared.configurations.first?.url {
            let fm = FileManager.default
            try? fm.removeItem(at: storeURL)
            try? fm.removeItem(at: storeURL.appendingPathExtension("shm"))
            try? fm.removeItem(at: storeURL.appendingPathExtension("wal"))
            logger.notice("TestDataSeeder: store files deleted")
        }

        // 4. Replace the shared container with a fresh empty one
        let freshContainer = SAMModelContainer.makeFreshContainer()
        SAMModelContainer.replaceShared(with: freshContainer)
        SAMApp.configureDataLayer(container: freshContainer)
        logger.notice("TestDataSeeder: fresh container installed and repositories rewired")

        // 5. Insert all test data into the new empty store
        let seedContext = ModelContext(freshContainer)
        await insertData(into: seedContext)

        // 6. Set the lockout flag — imports will be suppressed on next launch
        UserDefaults.standard.isTestDataActive = true

        // 7. Schedule TipKit reset for next launch
        UserDefaults.standard.set(true, forKey: "sam.tips.pendingReset")

        // 8. Now terminate — AI inference is idle, Metal is quiescent, safe to exit
        logger.notice("TestDataSeeder: seed committed — restarting cleanly")
        NSApplication.shared.terminate(nil)
    }

    /// Inserts all Harvey Snodgrass test data into the provided ModelContext.
    /// Called automatically on launch when sam.testData.active is true and store is empty.
    func insertData(into context: ModelContext) async {
        logger.notice("TestDataSeeder: inserting Harvey Snodgrass dataset")

        let now = Date.now
        let cal = Calendar.current

        func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }
        func daysFromNow(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: now)! }
        func monthsAgo(_ n: Int) -> Date { cal.date(byAdding: .month, value: -n, to: now)! }

        // ──────────────────────────────────────────────
        // MARK: Harvey Snodgrass — the "Me" contact
        // ──────────────────────────────────────────────
        let harvey = SamPerson(
            id: UUID(),
            displayName: "Harvey Snodgrass",
            roleBadges: [],
            email: "harvey.snodgrass@wfgmail-test.com",
            isMe: true
        )
        harvey.displayNameCache = "Harvey Snodgrass"
        harvey.emailCache = "harvey.snodgrass@wfgmail-test.com"
        harvey.emailAliases = ["harvey.snodgrass@wfgmail-test.com", "hsnodgrass@myteam-test.net"]
        harvey.phoneAliases = ["5551230001"]
        harvey.relationshipSummary = "Harvey Snodgrass is a WFG financial representative building his practice in the greater Springfield area. He runs a team of 8 agents, serves 25 active clients, and is actively prospecting new leads through referrals and community events."
        harvey.summaryUpdatedAt = daysAgo(1)
        context.insert(harvey)

        // ──────────────────────────────────────────────
        // MARK: Referral Partners (3)
        // ──────────────────────────────────────────────
        let referralPartners = makeReferralPartners(context: context, daysAgo: daysAgo)

        // ──────────────────────────────────────────────
        // MARK: External Agents (3)
        // ──────────────────────────────────────────────
        let externalAgents = makeExternalAgents(context: context, daysAgo: daysAgo)

        // ──────────────────────────────────────────────
        // MARK: Vendors / Underwriting (4)
        // ──────────────────────────────────────────────
        let vendors = makeVendors(context: context, daysAgo: daysAgo)

        // ──────────────────────────────────────────────
        // MARK: Harvey's Agent Team (8)
        // ──────────────────────────────────────────────
        let agents = makeAgents(context: context, daysAgo: daysAgo)

        // ──────────────────────────────────────────────
        // MARK: Active Clients (25)
        // ──────────────────────────────────────────────
        let clients = makeClients(context: context, daysAgo: daysAgo,
                                   daysFromNow: daysFromNow, monthsAgo: monthsAgo,
                                   referralPartners: referralPartners)

        // ──────────────────────────────────────────────
        // MARK: Active Leads (20)
        // ──────────────────────────────────────────────
        let activeLeads = makeActiveLeads(context: context, daysAgo: daysAgo,
                                           daysFromNow: daysFromNow,
                                           clients: clients)

        // ──────────────────────────────────────────────
        // MARK: Dropped Leads (40)
        // ──────────────────────────────────────────────
        makeDroppedLeads(context: context, daysAgo: daysAgo, monthsAgo: monthsAgo)

        // ──────────────────────────────────────────────
        // MARK: Contexts
        // ──────────────────────────────────────────────
        makeContexts(context: context, harvey: harvey, clients: clients,
                     agents: agents, referralPartners: referralPartners,
                     externalAgents: externalAgents, vendors: vendors)

        // ──────────────────────────────────────────────
        // MARK: Evidence (interaction history)
        // ──────────────────────────────────────────────
        makeEvidence(context: context, harvey: harvey, clients: clients,
                     activeLeads: activeLeads, agents: agents,
                     referralPartners: referralPartners, daysAgo: daysAgo,
                     daysFromNow: daysFromNow)

        // ──────────────────────────────────────────────
        // MARK: Notes
        // ──────────────────────────────────────────────
        makeNotes(context: context, clients: clients, activeLeads: activeLeads,
                  agents: agents, referralPartners: referralPartners,
                  daysAgo: daysAgo)

        // ──────────────────────────────────────────────
        // MARK: Business Goals
        // ──────────────────────────────────────────────
        makeGoals(context: context, now: now, daysFromNow: daysFromNow)

        // ──────────────────────────────────────────────
        // MARK: Outcomes / Coaching Queue
        // ──────────────────────────────────────────────
        makeOutcomes(context: context, clients: clients, activeLeads: activeLeads,
                     agents: agents, referralPartners: referralPartners,
                     daysAgo: daysAgo, daysFromNow: daysFromNow)

        do {
            try context.save()
            logger.notice("TestDataSeeder: committed — \(clients.count) clients, \(activeLeads.count) active leads, \(agents.count) agents")
        } catch {
            logger.error("TestDataSeeder: save failed — \(error)")
        }
    }

    // MARK: - Helpers

    private func person(name: String, email: String, phone: String,
                        badges: [String], summary: String,
                        summaryDaysAgo: Int, cadenceDays: Int? = nil,
                        daysAgo: (Int) -> Date) -> SamPerson {
        let p = SamPerson(id: UUID(), displayName: name, roleBadges: badges,
                          email: email, isMe: false)
        p.displayNameCache = name
        p.emailCache = email
        p.emailAliases = [email]
        p.phoneAliases = [phone]
        p.relationshipSummary = summary
        p.summaryUpdatedAt = daysAgo(summaryDaysAgo)
        if let c = cadenceDays { p.preferredCadenceDays = c }
        return p
    }

    // MARK: - Referral Partners

    private func makeReferralPartners(context: ModelContext,
                                       daysAgo: (Int) -> Date) -> [SamPerson] {
        let specs: [(String, String, String, String)] = [
            ("Sandra Okonkwo",  "s.okonkwo@realtypros-test.com",  "5552340101",
             "Harvey's top referral source — a real estate agent who regularly refers first-time homeowners for life insurance and mortgage protection reviews. She has sent 7 clients in the past year."),
            ("Marcus Treviño",  "marcus.t@trevinolaw-test.com",   "5552340102",
             "Estate planning attorney who refers clients needing life insurance to fund trusts. Two referrals in the past six months. Relationship is warm and mutually beneficial."),
            ("Priya Anand",     "p.anand@hrpros-test.com",        "5552340103",
             "HR consultant who refers small business owners looking for group benefits and individual retirement plans. One referral converted to client. Relationship is developing."),
        ]
        return specs.map { name, email, phone, summary in
            let p = person(name: name, email: email, phone: phone,
                           badges: ["Referral Partner"], summary: summary,
                           summaryDaysAgo: 3, cadenceDays: 30, daysAgo: daysAgo)
            context.insert(p)
            return p
        }
    }

    // MARK: - External Agents

    private func makeExternalAgents(context: ModelContext,
                                     daysAgo: (Int) -> Date) -> [SamPerson] {
        let specs: [(String, String, String, String)] = [
            ("Derek Pham",     "d.pham@wfgexternal-test.com",  "5552340201",
             "Senior WFG agent from the eastern region who assisted with a large IUL case for the Chen family. Co-sold the policy and has agreed to cross-refer business when geography makes sense."),
            ("Yvonne Castillo", "yvonne.c@wfgnetwork-test.com", "5552340202",
             "External agent who helped with an annuity case for a retired client. Knowledgeable about fixed indexed annuities and frequently consulted for complex cases."),
            ("James Whitfield", "j.whitfield@wfgpartners-test.com", "5552340203",
             "Specialist in disability insurance who covered a case Harvey referred out. Has referred one client back. The relationship is cordial and professional."),
        ]
        return specs.map { name, email, phone, summary in
            let p = person(name: name, email: email, phone: phone,
                           badges: ["External Agent"], summary: summary,
                           summaryDaysAgo: 5, daysAgo: daysAgo)
            context.insert(p)
            return p
        }
    }

    // MARK: - Vendors

    private func makeVendors(context: ModelContext,
                              daysAgo: (Int) -> Date) -> [SamPerson] {
        let specs: [(String, String, String, String)] = [
            ("Rachel Nguyen",   "r.nguyen@transamerica-uwtest.com",  "5552340301", "Transamerica"),
            ("Tom Grabowski",   "t.grabowski@nationwidebiz-test.com", "5552340302", "Nationwide"),
            ("Alicia Fountain", "a.fountain@fgl-uwtest.com",          "5552340303", "FGL"),
            ("Byron Stubbs",    "b.stubbs@northamer-uwtest.com",      "5552340304", "North American Company"),
        ]
        return specs.map { name, email, phone, company in
            let p = person(name: name, email: email, phone: phone,
                           badges: ["Vendor"],
                           summary: "\(name) is an underwriting liaison at \(company). Harvey works with them to submit and track policy applications.",
                           summaryDaysAgo: 7, daysAgo: daysAgo)
            context.insert(p)
            return p
        }
    }

    // MARK: - Agent Team (8)

    private func makeAgents(context: ModelContext,
                             daysAgo: (Int) -> Date) -> [SamPerson] {
        let cal = Calendar.current
        let now = Date.now
        func mA(_ n: Int) -> Date { cal.date(byAdding: .month, value: -n, to: now)! }
        func dA(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }

        struct Spec {
            let name: String; let email: String; let phone: String
            let stage: RecruitingStageKind; let enteredDate: Date
            let mentoringLast: Date?; let summary: String
        }

        let specs: [Spec] = [
            Spec(name: "Keisha Morales", email: "k.morales@wfgteam-test.com", phone: "5552340401",
                 stage: .producing, enteredDate: mA(18), mentoringLast: dA(5),
                 summary: "Keisha is Harvey's top producing recruit. Licensed 16 months ago, she consistently writes 3–5 policies per month and is building her own pipeline. On track for promotion to Senior Marketing Director."),
            Spec(name: "Omar Hendricks", email: "o.hendricks@wfgteam-test.com", phone: "5552340402",
                 stage: .producing, enteredDate: mA(14), mentoringLast: dA(8),
                 summary: "Omar has been producing for about a year, focusing on term life and IUL for young families. Steady at 2–3 policies per month. Needs encouragement to ask for referrals more consistently."),
            Spec(name: "Tiffany Roux", email: "t.roux@wfgteam-test.com", phone: "5552340403",
                 stage: .studying, enteredDate: dA(52), mentoringLast: dA(3),
                 summary: "Tiffany signed up 7 weeks ago and is actively studying for her state exam. She attends every training session and is scoring 85%+ on practice exams. She expects to sit for her exam within 3 weeks."),
            Spec(name: "Carlos Ibáñez", email: "c.ibanez@wfgteam-test.com", phone: "5552340404",
                 stage: .licensed, enteredDate: dA(28), mentoringLast: dA(2),
                 summary: "Carlos received his license 4 weeks ago and has submitted his first policy (term life for his brother). He's working his warm market. Harvey meets with him twice a week to build momentum."),
            Spec(name: "Brenda Kowalski", email: "b.kowalski@wfgteam-test.com", phone: "5552340405",
                 stage: .licensed, enteredDate: mA(9), mentoringLast: dA(62),
                 summary: "Brenda got licensed 9 months ago but hasn't written a policy in 4 months due to a family health matter. Harvey has called twice with no response. At risk of going permanently inactive."),
            Spec(name: "Darnell Upton", email: "d.upton@wfgteam-test.com", phone: "5552340406",
                 stage: .firstSale, enteredDate: mA(11), mentoringLast: dA(45),
                 summary: "Darnell wrote one policy in his first month then went quiet. He responds to texts but hasn't booked a meeting in over a month. Harvey suspects he's lost motivation after early momentum stalled."),
            Spec(name: "Felicia Grant", email: "f.grant@wfgteam-test.com", phone: "5552340407",
                 stage: .licensed, enteredDate: mA(7), mentoringLast: dA(30),
                 summary: "Felicia completed licensing but her only application was declined. She's expressed frustration and may need a motivational check-in and help with her sales approach."),
            Spec(name: "Kevin Szymanski", email: "k.szymanski@wfgteam-test.com", phone: "5552340408",
                 stage: .studying, enteredDate: dA(90), mentoringLast: dA(25),
                 summary: "Kevin signed up 3 months ago but has been slow to study and has postponed his exam twice. Harvey hasn't heard from him in 3 weeks. Needs a direct conversation about commitment."),
        ]

        var result: [SamPerson] = []
        for spec in specs {
            let p = person(name: spec.name, email: spec.email, phone: spec.phone,
                           badges: ["Agent"], summary: spec.summary,
                           summaryDaysAgo: 1, daysAgo: daysAgo)
            context.insert(p)

            let rs = RecruitingStage(id: UUID(), person: p, stage: spec.stage,
                                     enteredDate: spec.enteredDate,
                                     mentoringLastContact: spec.mentoringLast)
            context.insert(rs)

            // Initial prospect transition
            let t0 = StageTransition(id: UUID(), person: p, fromStage: "",
                                      toStage: RecruitingStageKind.prospect.rawValue,
                                      transitionDate: cal.date(byAdding: .day, value: -5, to: spec.enteredDate)!,
                                      pipelineType: .recruiting)
            context.insert(t0)

            // Intermediate transitions up to current stage
            addRecruitingTransitions(for: p, upTo: spec.stage,
                                      startDate: spec.enteredDate, context: context)
            result.append(p)
        }
        return result
    }

    private func addRecruitingTransitions(for person: SamPerson,
                                           upTo stage: RecruitingStageKind,
                                           startDate: Date,
                                           context: ModelContext) {
        let cal = Calendar.current
        var date = startDate
        let all: [RecruitingStageKind] = [.prospect, .presented, .signedUp, .studying, .licensed, .firstSale, .producing]
        let targetIdx = all.firstIndex(of: stage) ?? 0
        for i in 0..<targetIdx {
            let t = StageTransition(id: UUID(), person: person,
                                     fromStage: all[i].rawValue,
                                     toStage: all[i + 1].rawValue,
                                     transitionDate: date,
                                     pipelineType: .recruiting)
            context.insert(t)
            date = cal.date(byAdding: .day, value: Int.random(in: 14...28), to: date)!
        }
    }

    // MARK: - Clients (25)

    private func makeClients(context: ModelContext,
                              daysAgo: (Int) -> Date,
                              daysFromNow: (Int) -> Date,
                              monthsAgo: (Int) -> Date,
                              referralPartners: [SamPerson]) -> [SamPerson] {

        struct Prod {
            let type: WFGProductType; let carrier: String
            let premium: Double; let monthsBack: Int
        }
        struct Spec {
            let name: String; let email: String; let phone: String
            let prods: [Prod]; let reviewDays: Int
            let summary: String; let refIdx: Int?
        }

        let specs: [Spec] = [
            Spec(name: "Eleanor Vance", email: "e.vance@personalmail-test.com", phone: "5553010001",
                 prods: [Prod(type: .iul, carrier: "Transamerica", premium: 3600, monthsBack: 14),
                         Prod(type: .retirementPlan, carrier: "Nationwide", premium: 2400, monthsBack: 12)],
                 reviewDays: 28,
                 summary: "Eleanor is a 47-year-old marketing director and one of Harvey's best clients. She purchased an IUL and retirement plan 14 months ago. Interested in discussing long-term care at her upcoming annual review. Strong referral potential — she knows many professionals.",
                 refIdx: 0),
            Spec(name: "Robert & Diana Petrov", email: "r.petrov@family-test.com", phone: "5553010002",
                 prods: [Prod(type: .termLife, carrier: "North American", premium: 1800, monthsBack: 18),
                         Prod(type: .termLife, carrier: "North American", premium: 1200, monthsBack: 18)],
                 reviewDays: 45,
                 summary: "The Petrov family purchased term life policies 18 months ago after buying their first home — referred by Sandra Okonkwo. Robert is a teacher and Diana works part-time. Two young children. Harvey should discuss converting to permanent coverage at their annual review.",
                 refIdx: 0),
            Spec(name: "Marcus Chen", email: "m.chen@techwork-test.com", phone: "5553010003",
                 prods: [Prod(type: .iul, carrier: "Transamerica", premium: 6000, monthsBack: 22),
                         Prod(type: .annuity, carrier: "FGL", premium: 0, monthsBack: 10)],
                 reviewDays: 62,
                 summary: "Marcus is a 52-year-old software engineer with a high income. He purchased a large IUL with Derek Pham's assistance and recently added a fixed indexed annuity for retirement income. He tracks policy performance closely and asks detailed questions.",
                 refIdx: nil),
            Spec(name: "Sonia Adeyemi", email: "s.adeyemi@healthclinic-test.com", phone: "5553010004",
                 prods: [Prod(type: .iul, carrier: "Nationwide", premium: 4800, monthsBack: 8)],
                 reviewDays: 95,
                 summary: "Sonia is a nurse practitioner who purchased an IUL last year focused on retirement. She came via Marcus Treviño's estate planning practice. She wants to add her husband to coverage.",
                 refIdx: 1),
            Spec(name: "Jerome & Latoya Washington", email: "j.washington@homemail-test.com", phone: "5553010005",
                 prods: [Prod(type: .termLife, carrier: "Transamerica", premium: 2200, monthsBack: 30),
                         Prod(type: .retirementPlan, carrier: "Nationwide", premium: 1800, monthsBack: 28)],
                 reviewDays: 110,
                 summary: "Jerome is a firefighter and Latoya is a school administrator. Two-year clients with term life and IRAs for both. Loyal and punctual with reviews. Jerome asked about converting term to permanent at the last meeting.",
                 refIdx: nil),
            Spec(name: "Priscilla Fontaine", email: "p.fontaine@boutique-test.com", phone: "5553010006",
                 prods: [Prod(type: .wholeLife, carrier: "North American", premium: 2800, monthsBack: 20),
                         Prod(type: .retirementPlan, carrier: "FGL", premium: 3200, monthsBack: 18)],
                 reviewDays: 130,
                 summary: "Priscilla owns a boutique clothing store. She has whole life and a retirement plan. Her business is growing and she's exploring a business continuation plan for her partner.",
                 refIdx: nil),
            Spec(name: "Anthony Russo", email: "a.russo@construction-test.com", phone: "5553010007",
                 prods: [Prod(type: .termLife, carrier: "Transamerica", premium: 1600, monthsBack: 36),
                         Prod(type: .other, carrier: "Nationwide", premium: 3000, monthsBack: 24)],
                 reviewDays: 155,
                 summary: "Anthony is a general contractor with term life and disability coverage. He's expressed interest in an IUL but felt the premium was high. A lower-face-amount illustration might be timely for his next review.",
                 refIdx: nil),
            Spec(name: "Grace Kim", email: "g.kim@university-test.com", phone: "5553010008",
                 prods: [Prod(type: .iul, carrier: "FGL", premium: 3600, monthsBack: 11)],
                 reviewDays: 75,
                 summary: "Grace is a 38-year-old university professor who purchased an IUL for tax-advantaged growth. She's analytical and studies every illustration. She just had a new baby and Harvey should discuss the child rider.",
                 refIdx: nil),
            Spec(name: "Thomas & Carol Osei", email: "t.osei@familyhome-test.com", phone: "5553010009",
                 prods: [Prod(type: .termLife, carrier: "North American", premium: 1400, monthsBack: 42),
                         Prod(type: .termLife, carrier: "North American", premium: 1000, monthsBack: 42),
                         Prod(type: .educationPlan, carrier: "Nationwide", premium: 1200, monthsBack: 36)],
                 reviewDays: 88,
                 summary: "Thomas is a pharmacist and Carol a dental hygienist. Three children, strong protection focus. Term life and education savings. Strong candidates for IUL conversion once education expenses ease.",
                 refIdx: 0),
            Spec(name: "Veronica Marsh", email: "v.marsh@realestate-test.com", phone: "5553010010",
                 prods: [Prod(type: .annuity, carrier: "FGL", premium: 0, monthsBack: 6)],
                 reviewDays: 200,
                 summary: "Veronica is a semi-retired real estate investor who rolled over a large 401(k) into a fixed indexed annuity 6 months ago. Very satisfied with the downside protection. Harvey should confirm her income rider election.",
                 refIdx: nil),
            Spec(name: "Darius Freeman", email: "d.freeman@autotech-test.com", phone: "5553010011",
                 prods: [Prod(type: .iul, carrier: "Transamerica", premium: 5400, monthsBack: 16),
                         Prod(type: .termLife, carrier: "Transamerica", premium: 2000, monthsBack: 16)],
                 reviewDays: 37,
                 summary: "Darius is a 44-year-old auto shop owner with both an IUL and term policy. He referred his shop manager Terrence Boyd to Harvey. Expects referrals when nudged.",
                 refIdx: nil),
            Spec(name: "Naomi & James Patel", email: "n.patel@medpractice-test.com", phone: "5553010012",
                 prods: [Prod(type: .iul, carrier: "Nationwide", premium: 7200, monthsBack: 9),
                         Prod(type: .retirementPlan, carrier: "Nationwide", premium: 5000, monthsBack: 9)],
                 reviewDays: 120,
                 summary: "Both physicians. They max employer retirement plans and sought tax-advantaged accumulation through an IUL and supplemental retirement plan. High-income household with significant untapped insurance capacity.",
                 refIdx: nil),
            Spec(name: "Linda Thornton", email: "l.thornton@nonprofit-test.com", phone: "5553010013",
                 prods: [Prod(type: .wholeLife, carrier: "North American", premium: 1800, monthsBack: 48),
                         Prod(type: .retirementPlan, carrier: "FGL", premium: 2400, monthsBack: 36)],
                 reviewDays: 165,
                 summary: "Linda is a nonprofit director — 4-year client. She's a buy-and-hold client who appreciates annual check-ins. She recently mentioned wanting to leave a legacy to her church — a perfect opening for a charitable giving strategy.",
                 refIdx: nil),
            Spec(name: "Brandon Cole", email: "b.cole@logistics-test.com", phone: "5553010014",
                 prods: [Prod(type: .termLife, carrier: "Transamerica", premium: 1400, monthsBack: 7)],
                 reviewDays: 240,
                 summary: "Brandon is 31 and just started his logistics career. He purchased a term policy after his daughter was born. He has student loan debt but expressed interest in wealth building when things stabilize.",
                 refIdx: 2),
            Spec(name: "Hiroshi & Yuki Tanaka", email: "h.tanaka@importco-test.com", phone: "5553010015",
                 prods: [Prod(type: .iul, carrier: "FGL", premium: 4800, monthsBack: 19),
                         Prod(type: .annuity, carrier: "Nationwide", premium: 0, monthsBack: 15)],
                 reviewDays: 52,
                 summary: "Hiroshi runs an import business and Yuki is a graphic designer. IUL for Hiroshi's retirement and a deferred annuity for Yuki. Interested in starting a college savings plan for their teenage son.",
                 refIdx: nil),
            Spec(name: "Carmen Rodriguez", email: "c.rodriguez@nurse-test.com", phone: "5553010016",
                 prods: [Prod(type: .termLife, carrier: "North American", premium: 1200, monthsBack: 25),
                         Prod(type: .iul, carrier: "Transamerica", premium: 2400, monthsBack: 12)],
                 reviewDays: 78,
                 summary: "Carmen is an ER nurse who upgraded from term-only to a combination strategy last year. She's disciplined about saving. Her sister Maria is an active lead in Harvey's pipeline.",
                 refIdx: nil),
            Spec(name: "Geoffrey Okafor", email: "g.okafor@engineering-test.com", phone: "5553010017",
                 prods: [Prod(type: .iul, carrier: "Nationwide", premium: 6000, monthsBack: 30),
                         Prod(type: .retirementPlan, carrier: "FGL", premium: 4000, monthsBack: 30)],
                 reviewDays: 105,
                 summary: "Geoffrey is a 50-year-old civil engineer 15 years from retirement. On track with IUL accumulation and a solid retirement plan. Harvey should begin discussing long-term care insurance given his age.",
                 refIdx: nil),
            Spec(name: "Alexis Turner", email: "a.turner@media-test.com", phone: "5553010018",
                 prods: [Prod(type: .iul, carrier: "Transamerica", premium: 3000, monthsBack: 5)],
                 reviewDays: 280,
                 summary: "Alexis is a 29-year-old media producer who purchased an IUL 5 months ago. New to financial planning and enthusiastic. She's already mentioned two friends who might be interested.",
                 refIdx: nil),
            Spec(name: "Walter & Shirley Boateng", email: "w.boateng@retired-test.com", phone: "5553010019",
                 prods: [Prod(type: .annuity, carrier: "FGL", premium: 0, monthsBack: 40),
                         Prod(type: .wholeLife, carrier: "North American", premium: 2200, monthsBack: 40)],
                 reviewDays: 145,
                 summary: "Walter is a retired city employee and Shirley a retired teacher. Using annuity for supplemental retirement income and whole life as a legacy vehicle. Very satisfied — refer friends. Prefer in-person visits.",
                 refIdx: nil),
            Spec(name: "Nina Kowalczyk", email: "n.kowalczyk@dentist-test.com", phone: "5553010020",
                 prods: [Prod(type: .iul, carrier: "Nationwide", premium: 5200, monthsBack: 13),
                         Prod(type: .other, carrier: "Transamerica", premium: 4800, monthsBack: 13)],
                 reviewDays: 68,
                 summary: "Nina is a dentist who wisely paired an IUL with own-occupation disability insurance. She earns well — her hands are her livelihood. She's referred two colleagues, one of whom is an active lead.",
                 refIdx: nil),
            Spec(name: "Isaiah & Monica Grant", email: "i.grant@teaching-test.com", phone: "5553010021",
                 prods: [Prod(type: .termLife, carrier: "Transamerica", premium: 1600, monthsBack: 52),
                         Prod(type: .termLife, carrier: "North American", premium: 1200, monthsBack: 52),
                         Prod(type: .educationPlan, carrier: "Nationwide", premium: 1000, monthsBack: 48)],
                 reviewDays: 175,
                 summary: "Both educators with three kids in school. Budget-conscious but committed. Term life for both and an education savings plan. Open to IUL once their youngest starts school and expenses decrease.",
                 refIdx: nil),
            Spec(name: "Rachel Bloomfield", email: "r.bloomfield@tech-test.com", phone: "5553010022",
                 prods: [Prod(type: .iul, carrier: "FGL", premium: 7200, monthsBack: 21)],
                 reviewDays: 40,
                 summary: "Rachel is a 41-year-old tech executive with aggressive retirement savings goals. She max-funded her IUL and is on the cusp of adding an annuity for guaranteed income. She's also interested in a policy for her teenage daughter.",
                 refIdx: nil),
            Spec(name: "Patrick Nwosu", email: "p.nwosu@restaurant-test.com", phone: "5553010023",
                 prods: [Prod(type: .termLife, carrier: "North American", premium: 1800, monthsBack: 11),
                         Prod(type: .retirementPlan, carrier: "Nationwide", premium: 2000, monthsBack: 11)],
                 reviewDays: 215,
                 summary: "Patrick runs three restaurants. He has term life and a retirement plan. He's expressed interest in group benefits for his managers. Harvey should prepare a group life overview.",
                 refIdx: nil),
            Spec(name: "Denise & Carl Crawford", email: "d.crawford@suburban-test.com", phone: "5553010024",
                 prods: [Prod(type: .wholeLife, carrier: "North American", premium: 2400, monthsBack: 60),
                         Prod(type: .retirementPlan, carrier: "FGL", premium: 1800, monthsBack: 48),
                         Prod(type: .educationPlan, carrier: "Nationwide", premium: 1200, monthsBack: 36)],
                 reviewDays: 190,
                 summary: "Harvey's longest-standing clients — 5 years. Denise is a pharmacist and Carl is in sales. Whole life, IRAs for both, and an education plan. Carl mentioned wanting to retire in 10 years — time to run updated projections.",
                 refIdx: nil),
            Spec(name: "Yolanda Jefferson", email: "y.jefferson@socialwork-test.com", phone: "5553010025",
                 prods: [Prod(type: .termLife, carrier: "Transamerica", premium: 900, monthsBack: 6),
                         Prod(type: .iul, carrier: "Nationwide", premium: 2000, monthsBack: 3)],
                 reviewDays: 300,
                 summary: "Yolanda is a social worker who purchased a modest term policy 6 months ago and recently added an IUL 3 months ago. New client still in onboarding. Harvey should check in about beneficiary designations.",
                 refIdx: nil),
        ]

        return specs.map { spec in
            let p = person(name: spec.name, email: spec.email, phone: spec.phone,
                           badges: ["Client"], summary: spec.summary,
                           summaryDaysAgo: Int.random(in: 1...7),
                           cadenceDays: 90, daysAgo: daysAgo)
            if let idx = spec.refIdx, idx < referralPartners.count {
                p.referredBy = referralPartners[idx]
            }
            context.insert(p)

            // Pipeline transition: blank → Client
            let t = StageTransition(id: UUID(), person: p, fromStage: "Lead",
                                     toStage: "Client",
                                     transitionDate: monthsAgo(spec.prods.first?.monthsBack ?? 12),
                                     pipelineType: .client)
            context.insert(t)

            // Production records
            for prod in spec.prods {
                let pr = ProductionRecord(id: UUID(), person: p,
                                          productType: prod.type,
                                          status: .issued,
                                          carrierName: prod.carrier,
                                          annualPremium: prod.premium,
                                          submittedDate: monthsAgo(prod.monthsBack),
                                          resolvedDate: monthsAgo(prod.monthsBack - 1),
                                          policyNumber: "POL-\(Int.random(in: 100000...999999))")
                context.insert(pr)
            }

            // Upcoming annual review calendar evidence
            let rev = SamEvidenceItem(id: UUID(), state: .done,
                                       sourceUID: "calendar:review:\(p.id)",
                                       source: .calendar,
                                       occurredAt: daysFromNow(spec.reviewDays),
                                       endedAt: daysFromNow(spec.reviewDays),
                                       title: "Annual Review — \(spec.name)",
                                       snippet: "Annual policy review and financial check-in with \(spec.name).")
            rev.linkedPeople = [p]
            context.insert(rev)

            return p
        }
    }

    // MARK: - Active Leads (20)

    private func makeActiveLeads(context: ModelContext,
                                  daysAgo: (Int) -> Date,
                                  daysFromNow: (Int) -> Date,
                                  clients: [SamPerson]) -> [SamPerson] {

        struct Spec {
            let name: String; let email: String; let phone: String
            let stage: String; let daysInStage: Int
            let summary: String; let apptDays: Int?
        }

        let specs: [Spec] = [
            Spec(name: "Maria Rodriguez", email: "m.rodriguez.lead@personal-test.com", phone: "5553020001",
                 stage: "Applicant", daysInStage: 12,
                 summary: "Carmen Rodriguez's sister. Applied for term life 2 weeks ago — application is with the underwriter. Harvey should check status with Rachel Nguyen this week.",
                 apptDays: 8),
            Spec(name: "Derek Simmons", email: "d.simmons.lead@personal-test.com", phone: "5553020002",
                 stage: "Applicant", daysInStage: 5,
                 summary: "35-year-old electrician with a wife and two kids who submitted a term life application. Underwriting pending a medical history clarification.",
                 apptDays: 14),
            Spec(name: "Asha Krishnamurthy", email: "a.krishnamurthy.lead@tech-test.com", phone: "5553020003",
                 stage: "Lead", daysInStage: 21,
                 summary: "Software engineer referred by Nina Kowalczyk. Attended Harvey's group presentation and is interested in an IUL for tax-advantaged retirement. Slow to book follow-up — Harvey should send the IUL one-pager and suggest a Zoom call.",
                 apptDays: 6),
            Spec(name: "Terrence Boyd", email: "t.boyd.lead@warehouse-test.com", phone: "5553020004",
                 stage: "Lead", daysInStage: 18,
                 summary: "Darius Freeman's shop manager. 38 years old with no life insurance. Engaged at the first meeting but hasn't responded to follow-up calls. May respond better to text.",
                 apptDays: 10),
            Spec(name: "Gloria & Paul Estrada", email: "g.estrada.lead@homemail-test.com", phone: "5553020005",
                 stage: "Lead", daysInStage: 9,
                 summary: "Couple in their early 40s referred by Sandra Okonkwo after purchasing a home. Both interested in mortgage protection. Fact-finding appointment next week.",
                 apptDays: 5),
            Spec(name: "Kevin Park", email: "k.park.lead@dental-test.com", phone: "5553020006",
                 stage: "Lead", daysInStage: 14,
                 summary: "Dentist colleague of Nina Kowalczyk interested in disability insurance and an IUL. Busy professional who prefers email. Harvey sent an intro email last week — no response yet.",
                 apptDays: nil),
            Spec(name: "Beatrice Holloway", email: "b.holloway.lead@nursing-test.com", phone: "5553020007",
                 stage: "Lead", daysInStage: 6,
                 summary: "Travel nurse who attended Harvey's hospital lunch-and-learn. Interested in portable coverage that follows her between states. First one-on-one meeting scheduled next week.",
                 apptDays: 7),
            Spec(name: "Samuel Achebe", email: "s.achebe.lead@finance-test.com", phone: "5553020008",
                 stage: "Applicant", daysInStage: 20,
                 summary: "Financial analyst who submitted a large IUL application. A table rating request was triggered. Harvey is coordinating with Alicia Fountain to address the rating question. Samuel is patient but expects regular updates.",
                 apptDays: 12),
            Spec(name: "Danielle Moss", email: "d.moss.lead@retail-test.com", phone: "5553020009",
                 stage: "Lead", daysInStage: 30,
                 summary: "Retail chain manager referred by Priya Anand. Interested in retirement planning for herself and a potential group plan for store managers. Fact-finding was productive — Harvey is preparing an analysis.",
                 apptDays: 3),
            Spec(name: "Luis & Angela Fuentes", email: "l.fuentes.lead@family-test.com", phone: "5553020010",
                 stage: "Lead", daysInStage: 4,
                 summary: "Young couple with a newborn — Luis is a teacher and Angela is a part-time accountant. Met at a community event. They need life insurance now but have a limited budget. Term is the right start.",
                 apptDays: 4),
            Spec(name: "Collin Hurst", email: "c.hurst.lead@sales-test.com", phone: "5553020011",
                 stage: "Lead", daysInStage: 45,
                 summary: "50-year-old sales executive who came via an online ad. Been slow to commit but recently had a health scare that renewed his urgency. Harvey should emphasize the insurability window.",
                 apptDays: 9),
            Spec(name: "Renata Gomez", email: "r.gomez.lead@accounting-test.com", phone: "5553020012",
                 stage: "Lead", daysInStage: 3,
                 summary: "Accountant referred by Marcus Treviño looking for life insurance to fund a buy-sell agreement. Met this week — Harvey is preparing a business needs analysis.",
                 apptDays: 11),
            Spec(name: "Jerome Pope", email: "j.pope.lead@pastor-test.com", phone: "5553020013",
                 stage: "Lead", daysInStage: 60,
                 summary: "Local pastor referred by Walter Boateng interested in a legacy plan. Modest income — Harvey has met him twice. A smaller IUL with strong cash value accumulation is likely the right fit.",
                 apptDays: 15),
            Spec(name: "Fatima Al-Hassan", email: "f.alhassan.lead@medical-test.com", phone: "5553020014",
                 stage: "Applicant", daysInStage: 8,
                 summary: "Hospitalist physician who submitted a disability insurance application. Decisive and straightforward. Harvey should confirm the benefit period and elimination period election before final approval.",
                 apptDays: 16),
            Spec(name: "Eric Drummond", email: "e.drummond.lead@realestate-test.com", phone: "5553020015",
                 stage: "Lead", daysInStage: 22,
                 summary: "Real estate investor in his mid-40s referred by Sandra Okonkwo. Self-employed, interested in IUL as a tax shelter. Had detailed cap rate questions — Harvey sent an illustration. Follow-up scheduled.",
                 apptDays: 2),
            Spec(name: "Sofia Mendez", email: "s.mendez.lead@design-test.com", phone: "5553020016",
                 stage: "Lead", daysInStage: 17,
                 summary: "Freelance graphic designer in her late 20s referred by Alexis Turner. Wants to start building wealth with limited income. Harvey is preparing a starter IUL illustration scaled to her cash flow.",
                 apptDays: 6),
            Spec(name: "Harry & Josephine Crane", email: "h.crane.lead@retired-test.com", phone: "5553020017",
                 stage: "Lead", daysInStage: 35,
                 summary: "Recently retired postal worker and part-time librarian who attended Harvey's senior planning seminar. Interested in guaranteed income annuities to supplement Social Security.",
                 apptDays: 20),
            Spec(name: "Nadia Petrova", email: "n.petrova.lead@pharmacy-test.com", phone: "5553020018",
                 stage: "Lead", daysInStage: 10,
                 summary: "Pharmacist met at a professional networking event. Young, well-compensated, and open to both protection and accumulation. First meeting scheduled next week.",
                 apptDays: 7),
            Spec(name: "Charles Owusu", email: "c.owusu.lead@logistics-test.com", phone: "5553020019",
                 stage: "Applicant", daysInStage: 15,
                 summary: "Logistics manager referred by Brandon Cole. Applied for term life two weeks ago. Young and healthy — underwriting should be straightforward. Harvey should confirm delivery instructions.",
                 apptDays: 5),
            Spec(name: "Wendy Tran", email: "w.tran.lead@accounting-test.com", phone: "5553020020",
                 stage: "Lead", daysInStage: 2,
                 summary: "Brand new lead introduced by Keisha Morales. 32-year-old CPA interested in life insurance and retirement planning. First appointment booked for this week.",
                 apptDays: 3),
        ]

        return specs.map { spec in
            let p = person(name: spec.name, email: spec.email, phone: spec.phone,
                           badges: [spec.stage], summary: spec.summary,
                           summaryDaysAgo: 1, cadenceDays: 14, daysAgo: daysAgo)
            context.insert(p)

            let t = StageTransition(id: UUID(), person: p, fromStage: "",
                                     toStage: spec.stage,
                                     transitionDate: daysAgo(spec.daysInStage),
                                     pipelineType: .client)
            context.insert(t)

            if let days = spec.apptDays {
                let label = spec.stage == "Applicant" ? "Policy Follow-up" : "Fact-Finding Meeting"
                let ev = SamEvidenceItem(id: UUID(), state: .done,
                                          sourceUID: "calendar:appt:\(p.id)",
                                          source: .calendar,
                                          occurredAt: daysFromNow(days),
                                          endedAt: daysFromNow(days),
                                          title: "\(label) — \(spec.name)",
                                          snippet: "\(label) with \(spec.name).")
                ev.linkedPeople = [p]
                context.insert(ev)
            }
            return p
        }
    }

    // MARK: - Dropped Leads (40, archived)

    private func makeDroppedLeads(context: ModelContext,
                                   daysAgo: (Int) -> Date,
                                   monthsAgo: (Int) -> Date) {

        struct Spec { let name: String; let email: String; let phone: String
            let reason: String; let months: Int }

        let specs: [Spec] = [
            Spec(name: "Gary Snodgrass", email: "gary.s@family-test.com", phone: "5553030001",
                 reason: "Harvey's brother — attended initial training presentation. Was interested but decided he had 'plenty of time.' Last contact 18 months ago.", months: 18),
            Spec(name: "Patricia Snodgrass", email: "pat.s@family-test.com", phone: "5553030002",
                 reason: "Sister-in-law — attended training night. Budget was too tight at the time. Financial situation may have improved.", months: 16),
            Spec(name: "Earl Snodgrass", email: "earl.s@retired-test.com", phone: "5553030003",
                 reason: "Uncle — retired with existing whole life through another company. Listened politely but had no interest in switching.", months: 20),
            Spec(name: "Donna Finch", email: "d.finch@family-test.com", phone: "5553030004",
                 reason: "Harvey's cousin — expressed interest then married someone in insurance and felt loyal to their agent.", months: 22),
            Spec(name: "Tyler Snodgrass", email: "tyler.s@college-test.com", phone: "5553030005",
                 reason: "Harvey's nephew — was a college sophomore when Harvey started. Has since graduated but no follow-up attempted.", months: 14),
            Spec(name: "Mike Bellanca", email: "m.bellanca@friend-test.com", phone: "5553030006",
                 reason: "Childhood friend who came as a favor to Harvey's first training night. Significant credit card debt made any premium unaffordable. May be in better shape now.", months: 19),
            Spec(name: "Sandra Bellanca", email: "s.bellanca@friend-test.com", phone: "5553030007",
                 reason: "Mike's wife — same situation. Budget-constrained at the time. Worth a revisit if Mike's situation improved.", months: 19),
            Spec(name: "Todd Yarborough", email: "t.yarborough@friend-test.com", phone: "5553030008",
                 reason: "College roommate in grad school who said he couldn't commit financially while in school. Has since graduated and is working.", months: 17),
            Spec(name: "Cynthia Yarborough", email: "c.yarborough@friend-test.com", phone: "5553030009",
                 reason: "Todd's wife — also finishing her master's degree. May now be established in her career.", months: 17),
            Spec(name: "Ron Belcher", email: "r.belcher@friend-test.com", phone: "5553030010",
                 reason: "Longtime friend who attended to support Harvey. Had insurance through work. Has since been laid off — benefit coverage may have lapsed.", months: 15),
            Spec(name: "Clarence Hobbs", email: "c.hobbs@training-test.com", phone: "5553030011",
                 reason: "Attended early training seminar — was between jobs and couldn't commit. Contact lost after two follow-up attempts.", months: 20),
            Spec(name: "Michelle Hobbs", email: "m.hobbs@training-test.com", phone: "5553030012",
                 reason: "Clarence's wife — same situation. May be worth a reconnect now.", months: 20),
            Spec(name: "Shaun Prescott", email: "s.prescott@training-test.com", phone: "5553030013",
                 reason: "Attended training night going through a divorce. Said the timing was terrible. Divorce likely finalized — he may have different priorities now.", months: 18),
            Spec(name: "Latasha Burns", email: "l.burns@training-test.com", phone: "5553030014",
                 reason: "Attended training — was 19 and felt she was too young. Now in her early 20s and likely starting a career.", months: 24),
            Spec(name: "DeShawn Harris", email: "d.harris@training-test.com", phone: "5553030015",
                 reason: "Attended training — fully insured through a union benefit plan. Lost his union job 8 months ago. Potential revisit.", months: 22),
            Spec(name: "Harriet Simmons", email: "h.simmons@check-test.com", phone: "5553030016",
                 reason: "Came to confirm she was adequately covered. Harvey confirmed her existing whole life was sufficient. No additional coverage needed at the time.", months: 10),
            Spec(name: "Franklin Wick", email: "f.wick@check-test.com", phone: "5553030017",
                 reason: "Sought Harvey out to review his employer group term. Coverage was adequate. He promised to return when he bought a home.", months: 8),
            Spec(name: "Donna Prescott", email: "d.prescott@check-test.com", phone: "5553030018",
                 reason: "Wanted a second opinion on an existing annuity. Harvey confirmed it was reasonable. She stayed with her current carrier.", months: 7),
            Spec(name: "Armand Lefebvre", email: "a.lefebvre@transition-test.com", phone: "5553030019",
                 reason: "Software developer who was relocating to another state. Said he'd reach out once settled. He's been in his new city 6 months with no contact.", months: 9),
            Spec(name: "Beverly Tran", email: "b.tran@transition-test.com", phone: "5553030020",
                 reason: "Going through a career change from stable employment to starting a business. Budget was uncertain. Her business may now be stable enough to revisit.", months: 11),
            Spec(name: "Quincy Patten", email: "q.patten@transition-test.com", phone: "5553030021",
                 reason: "Recently divorced, going through financial reorganization. Said he'd wait until child support obligations were clearer. May be ready now.", months: 13),
            Spec(name: "Rebecca Stokes", email: "r.stokes@transition-test.com", phone: "5553030022",
                 reason: "Was mid-way through a bankruptcy filing. Wanted to wait until it discharged before taking on any financial commitments. Discharge was likely 6–8 months ago.", months: 15),
            Spec(name: "Andre Coleman", email: "a.coleman@transition-test.com", phone: "5553030023",
                 reason: "Was deploying overseas when Harvey made contact. Has since returned stateside. Contact not re-established.", months: 12),
            Spec(name: "Kenji Watanabe", email: "k.watanabe@debt-test.com", phone: "5553030024",
                 reason: "Young professional with large student loan debt who said he couldn't justify insurance premiums until loans are paid down. May be making progress.", months: 16),
            Spec(name: "Marissa Delgado", email: "m.delgado@debt-test.com", phone: "5553030025",
                 reason: "Single mother with high credit card debt who genuinely couldn't afford any premium. Harvey gave her his card and said to call when her situation improved.", months: 14),
            Spec(name: "Owen Fitch", email: "o.fitch@debt-test.com", phone: "5553030026",
                 reason: "Carrying high car loan and a second mortgage. Felt no room in the budget. Told Harvey to check back in a year — that year has passed.", months: 12),
            Spec(name: "Jasmine Fletcher", email: "j.fletcher@student-test.com", phone: "5553030027",
                 reason: "College student at a university financial literacy event Harvey spoke at. Was interested but had no income. Now approaching graduation.", months: 18),
            Spec(name: "Elijah Odom", email: "e.odom@student-test.com", phone: "5553030028",
                 reason: "Law student referred by a current client. Said he'd call once he passed the bar and got a job. That was 14 months ago.", months: 14),
            Spec(name: "Cassandra Moore", email: "c.moore@student-test.com", phone: "5553030029",
                 reason: "Medical school student who met Harvey at a health fair. Showed genuine interest but said student loans were her only reality. May be in residency now.", months: 20),
            Spec(name: "Brent Hutchinson", email: "b.hutchinson@student-test.com", phone: "5553030030",
                 reason: "PhD student in engineering. Income was a stipend. Said insurance felt premature. Likely finished his degree and is in industry now.", months: 22),
            Spec(name: "Glenda Pace", email: "g.pace@other-test.com", phone: "5553030031",
                 reason: "Retired on a fixed income — wanted coverage but monthly premium was genuinely unaffordable on Social Security alone.", months: 9),
            Spec(name: "Rodney Hicks", email: "r.hicks@other-test.com", phone: "5553030032",
                 reason: "Already had a financial advisor he trusted and was not interested in switching. Was polite but firm. Closed.", months: 11),
            Spec(name: "Tammy Faulkner", email: "t.faulkner@other-test.com", phone: "5553030033",
                 reason: "Attended a free dinner seminar — primarily there for the food. Never genuinely interested. Harvey followed up twice with no response.", months: 8),
            Spec(name: "Preston Gilmore", email: "p.gilmore@other-test.com", phone: "5553030034",
                 reason: "Self-described 'buy term and invest the difference' believer. Lengthy philosophical debate with Harvey but would not consider WFG products. Amicably closed.", months: 7),
            Spec(name: "Ingrid Sorensen", email: "i.sorensen@other-test.com", phone: "5553030035",
                 reason: "Moved internationally — husband took a job in Germany. Coverage complexity in foreign country made it impractical. Lost contact.", months: 10),
            Spec(name: "Marcus Bell", email: "m.bell@other-test.com", phone: "5553030036",
                 reason: "Said he was going to 'think about it' after two meetings. Stopped returning calls after 3 months. Likely found another agent.", months: 9),
            Spec(name: "Ruth Ann Carver", email: "r.carver@other-test.com", phone: "5553030037",
                 reason: "Was interested in a retirement plan but her employer announced a new 401(k) match she didn't want to pass up. Said she'd revisit private coverage later.", months: 6),
            Spec(name: "Timothy Weston", email: "t.weston@other-test.com", phone: "5553030038",
                 reason: "Met at a networking event — wanted the WFG business opportunity but not the products. Harvey explained he was focused on clients currently. No fit.", months: 5),
            Spec(name: "Carla Nix", email: "c.nix@other-test.com", phone: "5553030039",
                 reason: "Attended a group presentation and asked good questions but went cold after Harvey's follow-up email. No response to two subsequent texts.", months: 4),
            Spec(name: "Albert Vasquez", email: "a.vasquez@other-test.com", phone: "5553030040",
                 reason: "Interested in an annuity rollover but stayed with his current financial institution due to familiarity. Respected Harvey's knowledge but stayed put.", months: 3),
        ]

        for spec in specs {
            let p = person(name: spec.name, email: spec.email, phone: spec.phone,
                           badges: ["Lead"], summary: spec.reason,
                           summaryDaysAgo: spec.months * 30, daysAgo: daysAgo)
            p.isArchived = true
            context.insert(p)
        }
    }

    // MARK: - Contexts

    private func makeContexts(context: ModelContext,
                               harvey: SamPerson,
                               clients: [SamPerson],
                               agents: [SamPerson],
                               referralPartners: [SamPerson],
                               externalAgents: [SamPerson],
                               vendors: [SamPerson]) {

        // Harvey's household
        let hhCtx = SamContext(id: UUID(), name: "Snodgrass Household", kind: .household)
        context.insert(hhCtx)
        add(harvey, to: hhCtx, badges: [], isPrimary: true, context: context)

        // Agent team
        let teamCtx = SamContext(id: UUID(), name: "Harvey's Agent Team", kind: .agentTeam)
        context.insert(teamCtx)
        add(harvey, to: teamCtx, badges: ["Team Leader"], isPrimary: true, context: context)
        for a in agents { add(a, to: teamCtx, badges: ["Agent"], isPrimary: false, context: context) }

        // Referral partner contexts
        for rp in referralPartners {
            let ctx = SamContext(id: UUID(), name: "\(rp.displayNameCache ?? "Partner") — Referral Partnership", kind: .referralPartner)
            context.insert(ctx)
            add(rp, to: ctx, badges: ["Referral Partner"], isPrimary: true, context: context)
            add(harvey, to: ctx, badges: [], isPrimary: false, context: context)
        }

        // External agent contexts
        for ea in externalAgents {
            let ctx = SamContext(id: UUID(), name: "\(ea.displayNameCache ?? "Agent") — External Agent", kind: .agentExternal)
            context.insert(ctx)
            add(ea, to: ctx, badges: ["External Agent"], isPrimary: true, context: context)
        }

        // Vendor contexts
        for v in vendors {
            let ctx = SamContext(id: UUID(), name: "\(v.displayNameCache ?? "Vendor") — Underwriting", kind: .vendor)
            context.insert(ctx)
            add(v, to: ctx, badges: ["Vendor"], isPrimary: true, context: context)
        }

        // Client household contexts (first 10)
        for c in clients.prefix(10) {
            let ctx = SamContext(id: UUID(), name: "\(c.displayNameCache ?? "Client") Household", kind: .household)
            context.insert(ctx)
            add(c, to: ctx, badges: ["Primary"], isPrimary: true, context: context)
        }
    }

    private func add(_ p: SamPerson, to ctx: SamContext, badges: [String],
                     isPrimary: Bool, context: ModelContext) {
        let part = ContextParticipation(id: UUID(), person: p, context: ctx,
                                         roleBadges: badges, isPrimary: isPrimary)
        context.insert(part)
    }

    // MARK: - Evidence

    private func makeEvidence(context: ModelContext,
                               harvey: SamPerson,
                               clients: [SamPerson],
                               activeLeads: [SamPerson],
                               agents: [SamPerson],
                               referralPartners: [SamPerson],
                               daysAgo: (Int) -> Date,
                               daysFromNow: (Int) -> Date) {

        func ev(_ title: String, _ snippet: String, _ source: EvidenceSource,
                _ date: Date, _ people: [SamPerson]) {
            let e = SamEvidenceItem(id: UUID(), state: .done,
                                     sourceUID: "\(source.rawValue):\(UUID())",
                                     source: source, occurredAt: date,
                                     title: title, snippet: snippet)
            e.linkedPeople = people
            context.insert(e)
        }

        // Upcoming team training
        ev("Team Training — Weekly Meeting",
           "Weekly session covering sales presentations and objection handling.",
           .calendar, daysFromNow(2), agents)
        ev("1:1 Coaching — Tiffany Roux",
           "Review Tiffany's study progress and run a mock exam session.",
           .calendar, daysFromNow(3), [agents[2]])
        ev("1:1 Coaching — Carlos Ibáñez",
           "Pipeline review — help Carlos set up three new prospect appointments.",
           .calendar, daysFromNow(1), [agents[3]])
        ev("Team Training — Product Deep Dive: IUL",
           "Full team training on IUL mechanics, cap rates, and objections.",
           .calendar, daysFromNow(7), agents)
        ev("Check-in Call — Keisha Morales",
           "Monthly pipeline review and goal setting call with Keisha.",
           .calendar, daysFromNow(4), [agents[0]])
        ev("Check-in Call — Omar Hendricks",
           "Monthly pipeline and referral strategy call with Omar.",
           .calendar, daysFromNow(6), [agents[1]])

        // Past team meetings
        ev("Weekly Team Meeting", "Covered prospecting best practices and objection handling role-play.",
           .calendar, daysAgo(5), agents)
        ev("Weekly Team Meeting", "Q&A on term vs. IUL — Tiffany and Carlos both contributed great questions.",
           .calendar, daysAgo(12), agents)
        ev("Weekly Team Meeting", "Reviewed last month's production numbers and set team goals.",
           .calendar, daysAgo(19), agents)
        ev("1:1 — Keisha Morales", "Worked on Keisha's proposal approach for two stalled cases.",
           .calendar, daysAgo(9), [agents[0]])
        ev("1:1 — Omar Hendricks", "Helped Omar craft a referral ask script to use with existing clients.",
           .calendar, daysAgo(11), [agents[1]])
        ev("Exam Prep — Tiffany Roux", "Worked through practice questions — Tiffany scoring 85%+ consistently.",
           .calendar, daysAgo(3), [agents[2]])
        ev("Carlos Ibáñez — First Policy Submission",
           "Carlos submitted his first policy application — term life for his brother.",
           .note, daysAgo(14), [agents[3]])
        ev("Voicemail — Brenda Kowalski",
           "Left voicemail for Brenda — second attempt with no response.",
           .phoneCall, daysAgo(15), [agents[4]])
        ev("Text — Darnell Upton",
           "Darnell replied to check-in text saying he'd been busy. No meeting booked.",
           .iMessage, daysAgo(8), [agents[5]])

        // Client meetings / reviews
        let clientHistory: [(SamPerson, String, String, Int)] = [
            (clients[0], "Annual Review — Eleanor Vance",
             "Reviewed IUL performance — $28,400 cash value. Eleanor asked about LTC insurance.", 365),
            (clients[2], "Quarterly Check-in — Marcus Chen",
             "Marcus reviewed IUL illustration and confirmed satisfaction. Discussed annuity distribution strategy.", 90),
            (clients[4], "Annual Review — Jerome & Latoya Washington",
             "Reviewed term and IRA. Jerome asked about converting to permanent. Encouraged IRA contribution increase.", 330),
            (clients[6], "Annual Review — Anthony Russo",
             "Anthony asked again about IUL. Ran a quick illustration — he wants to think about it.", 365),
            (clients[7], "Policy Delivery — Grace Kim",
             "Delivered Grace's IUL policy. Explained riders in detail. She signed. Grace just had a baby girl — Emma.", 335),
            (clients[10], "Annual Review — Darius Freeman",
             "Reviewed both policies. Darius mentioned his shop manager Terrence Boyd as a potential lead.", 30),
            (clients[11], "Annual Review — Naomi & James Patel",
             "High-value review. Discussed disability income gap against their existing group benefit.", 90),
            (clients[19], "Policy Review — Nina Kowalczyk",
             "Confirmed disability rider is correct. Nina asked about adding a colleague to Harvey's pipeline.", 45),
            (clients[21], "Planning Meeting — Rachel Bloomfield",
             "Rachel decided to add an annuity. Harvey to prepare a comparison illustration.", 14),
            (clients[22], "Annual Review — Patrick Nwosu",
             "Patrick wants a group benefit plan for his managers. Harvey to research small business group options.", 21),
        ]
        for (person, title, snippet, days) in clientHistory {
            ev(title, snippet, .calendar, daysAgo(days), [person])
        }

        // Phone calls with clients
        for (i, client) in clients.prefix(15).enumerated() {
            ev("Phone Call — \(client.displayNameCache ?? "")",
               "Follow-up call to check in on policy questions and upcoming review.",
               .phoneCall, daysAgo(7 + i * 12), [client])
        }

        // iMessages with leads
        for (i, lead) in activeLeads.prefix(10).enumerated() {
            ev("iMessage — \(lead.displayNameCache ?? "")",
               "Quick check-in text to confirm appointment or share a follow-up resource.",
               .iMessage, daysAgo(2 + i * 3), [lead])
        }

        // Referral partner interactions
        ev("Lunch Meeting — Sandra Okonkwo",
           "Sandra referred the Estrada family and mentioned two more uninsured buyers closing next month.",
           .calendar, daysAgo(8), [referralPartners[0]])
        ev("Phone Call — Marcus Treviño",
           "Discussed mutual client needing an ILIT. Marcus is drafting the trust; Harvey to write the policy.",
           .phoneCall, daysAgo(15), [referralPartners[1]])
        ev("Coffee Meeting — Priya Anand",
           "Priya referred Danielle Moss. Discussed co-hosting a small-business owner workshop.",
           .calendar, daysAgo(21), [referralPartners[2]])
        ev("Thank-you Note — Sandra Okonkwo",
           "Sent a thank-you note and gift card to Sandra for the Petrov referral.",
           .note, daysAgo(60), [referralPartners[0]])

        // Upcoming prospecting meetings
        ev("Prospecting Coffee — Nadia Petrova",
           "First meeting with Nadia — bring financial needs summary and IUL overview.",
           .calendar, daysFromNow(7), [activeLeads[17]])
        ev("Group Presentation — Community Center",
           "Harvey presenting WFG overview to a group of 15 community members.",
           .calendar, daysFromNow(10), [harvey])
        ev("Lunch — Patrick Nwosu (Group Benefits Discussion)",
           "Patrick wants to explore group life for his restaurant managers.",
           .calendar, daysFromNow(18), [clients[22]])
        ev("Financial Literacy Seminar — Library",
           "Harvey co-hosting a public retirement planning seminar with Marcus Treviño.",
           .calendar, daysFromNow(22), [referralPartners[1]])
    }

    // MARK: - Notes

    private func makeNotes(context: ModelContext,
                            clients: [SamPerson],
                            activeLeads: [SamPerson],
                            agents: [SamPerson],
                            referralPartners: [SamPerson],
                            daysAgo: (Int) -> Date) {

        func makeAction(type: NoteActionItem.ActionType,
                        description: String,
                        urgency: NoteActionItem.Urgency,
                        person: SamPerson? = nil) -> NoteActionItem {
            NoteActionItem(id: UUID(), type: type, description: description,
                           urgency: urgency,
                           linkedPersonName: person?.displayNameCache,
                           linkedPersonID: person?.id)
        }

        func note(content: String, summary: String, people: [SamPerson],
                  daysBack: Int, topics: [String] = [],
                  actions: [NoteActionItem] = []) {
            let n = SamNote(id: UUID(), content: content, summary: summary,
                            createdAt: daysAgo(daysBack), updatedAt: daysAgo(daysBack),
                            isAnalyzed: true, sourceType: .typed)
            n.linkedPeople = people
            n.extractedTopics = topics
            n.extractedActionItems = actions
            context.insert(n)
        }

        // Client notes
        note(content: """
            Annual review with Eleanor Vance. Reviewed IUL performance — cash value is at $28,400, tracking ahead of illustration. Eleanor is very happy. She asked about long-term care insurance for the first time — her mother just went into memory care and it has her thinking. I explained the basics and she wants a full presentation at her next review. Also, she mentioned her colleague David Park at work might be interested in talking to me. I should reach out to him.
            """,
             summary: "Eleanor's IUL performing well ($28,400 CV). Interested in LTC triggered by mother's situation. New referral lead: David Park (colleague).",
             people: [clients[0]], daysBack: 365,
             topics: ["IUL performance", "long-term care insurance", "referral opportunity"],
             actions: [
                makeAction(type: .createProposal,
                           description: "Prepare LTC insurance overview for Eleanor's upcoming annual review",
                           urgency: .soon, person: clients[0]),
                makeAction(type: .generalFollowUp,
                           description: "Reach out to David Park — colleague referral from Eleanor Vance",
                           urgency: .standard),
             ])

        note(content: """
            Meeting with Marcus Chen — quarterly check-in. His IUL cash value is at $48,200 — he's tracking the S&P 500 cap closely. He pulled up his annual statement and compared it to a hypothetical direct equity investment and was impressed by the downside floor. We talked about distribution strategy from his annuity. He's concerned about sequence of returns risk in retirement. I should run a Monte Carlo illustration before his next visit.
            """,
             summary: "Marcus's IUL ($48,200 CV) performing well. He wants Monte Carlo analysis for annuity distribution timing and sequence-of-returns risk.",
             people: [clients[2]], daysBack: 90,
             topics: ["IUL accumulation", "annuity distribution", "sequence of returns", "retirement planning"],
             actions: [
                makeAction(type: .createProposal,
                           description: "Prepare Monte Carlo retirement income analysis for Marcus Chen",
                           urgency: .soon, person: clients[2]),
             ])

        note(content: """
            Phone call with Jerome Washington. He asked again about converting his term to permanent coverage. His children are getting older and the mortgage is almost paid off — he wants coverage that lasts past 65. His term expires in 7 years and the conversion window closes in 3. He said he wants to move forward. I'll bring an IUL illustration to his annual review in March.
            """,
             summary: "Jerome wants to convert term to permanent before the conversion window closes in 3 years. Strong IUL opportunity at annual review.",
             people: [clients[4]], daysBack: 45,
             topics: ["term conversion", "permanent life insurance", "IUL"],
             actions: [
                makeAction(type: .createProposal,
                           description: "Prepare term-to-IUL conversion illustration for Jerome Washington's annual review",
                           urgency: .soon, person: clients[4]),
             ])

        note(content: """
            Delivered Grace Kim's IUL policy. We went through every rider page by page — she is thorough and wanted to understand everything. She was particularly interested in the waiver of premium rider in case she became disabled. She also mentioned she just had a baby girl — Emma — born two weeks ago. I explained the child rider and she wants to add it. Need to file a rider amendment. The baby's age means incredibly low premiums for a juvenile rider — she was excited.
            """,
             summary: "Policy delivered to Grace Kim. New baby (Emma, 2 weeks old). Opportunity to add juvenile rider — need to file rider amendment promptly.",
             people: [clients[7]], daysBack: 335,
             topics: ["policy delivery", "life insurance riders", "juvenile insurance", "new baby"],
             actions: [
                makeAction(type: .updateContact,
                           description: "File child rider amendment for Grace Kim — baby Emma, born 2 weeks ago",
                           urgency: .immediate, person: clients[7]),
                makeAction(type: .sendCongratulations,
                           description: "Send congratulations note to Grace Kim on baby Emma",
                           urgency: .immediate, person: clients[7]),
             ])

        note(content: """
            First meeting with Asha Krishnamurthy. She came in well-prepared — had researched IUL online and had specific questions about participation rates and cap rates. She's 34, earns around $130K at her tech company, and maxes her 401(k). She's looking for tax-advantaged overfunding of an IUL. I presented the concept, ran a quick illustration, and she was impressed. She wants to talk to her CPA before committing. I should follow up in two weeks.
            """,
             summary: "Asha is a high-income tech engineer interested in overfunded IUL for tax-advantaged growth. CPA confirmation first. Follow up in 2 weeks.",
             people: [activeLeads[2]], daysBack: 21,
             topics: ["IUL", "tax-advantaged accumulation", "high-income professional"],
             actions: [
                makeAction(type: .generalFollowUp,
                           description: "Follow up with Asha Krishnamurthy — check if she spoke to her CPA",
                           urgency: .soon, person: activeLeads[2]),
                makeAction(type: .generalFollowUp,
                           description: "Send Asha the IUL overfunding one-pager",
                           urgency: .standard, person: activeLeads[2]),
             ])

        note(content: """
            Team training session. Keisha led the role-play today — she's gotten really good at the kitchen table presentation. She handled a price objection beautifully: 'The question isn't whether you can afford this premium, it's whether your family can afford what happens if you don't have it.' I want to capture that phrasing and share it with the whole team.

            Carlos submitted his first policy this week — his brother's term life. He was nervous but walked through the app correctly. I told him the most important thing is to repeat the process before the momentum fades.

            Kevin Szymanski still hasn't responded to my last message. It's been 25 days. I'm going to call him tomorrow and have a direct conversation about whether he's still committed.
            """,
             summary: "Keisha led excellent role-play. Carlos submitted first policy. Kevin Szymanski unresponsive at 25 days — direct conversation needed.",
             people: agents, daysBack: 14,
             topics: ["team training", "sales role-play", "agent development", "first policy"],
             actions: [
                makeAction(type: .generalFollowUp,
                           description: "Call Kevin Szymanski — direct conversation about his commitment to licensing",
                           urgency: .immediate, person: agents[7]),
                makeAction(type: .generalFollowUp,
                           description: "Share Keisha's objection-handling phrase with full team at next training",
                           urgency: .standard, person: agents[0]),
             ])

        note(content: """
            Call with Rachel Bloomfield. She is ready to add a fixed indexed annuity. She wants to use $80,000 from a recently inherited IRA — a trustee-to-trustee transfer to avoid triggering tax. She asked about income rider options and wants guaranteed lifetime income starting at age 70. I need to get her a comparison of two annuity products with different income rider mechanics. Should involve Yvonne Castillo for case details.
            """,
             summary: "Rachel wants an $80K IRA-to-annuity rollover for guaranteed lifetime income at 70. Needs product comparison. Loop in Yvonne Castillo.",
             people: [clients[21]], daysBack: 14,
             topics: ["annuity rollover", "inherited IRA", "income rider", "retirement income"],
             actions: [
                makeAction(type: .createProposal,
                           description: "Prepare annuity product comparison for Rachel Bloomfield — income rider focus",
                           urgency: .immediate, person: clients[21]),
             ])

        note(content: """
            Lunch with Sandra Okonkwo. She had a great quarter — sold 11 properties. She mentioned the Estrada family is closing on a home next month and will need mortgage protection. She also has two other buyers closing this month who are uninsured and will refer them to me if I give her something tangible to hand them at closing. I should create a short one-page 'Why Life Insurance Protects Your Mortgage' flyer with my contact info.
            """,
             summary: "Sandra had a great quarter (11 sales). Two referral opportunities — uninsured buyers closing this month. She needs a one-page mortgage protection flyer for closings.",
             people: [referralPartners[0]], daysBack: 8,
             topics: ["referral partnership", "mortgage protection", "lead generation", "marketing material"],
             actions: [
                makeAction(type: .generalFollowUp,
                           description: "Create one-page mortgage protection flyer for Sandra Okonkwo's buyer closings",
                           urgency: .immediate, person: referralPartners[0]),
             ])

        note(content: """
            Check-in with Danielle Moss. She runs three retail locations. She's looking for retirement planning for herself and group term life for 4 store managers ($50K per person). The group term is a small case but it's a foot in the door for a larger relationship. I need to reach out to Tom Grabowski at Nationwide about small-group options before the next meeting in 3 days.
            """,
             summary: "Danielle Moss — exploring group term for 4 managers plus personal retirement plan. Meeting in 3 days. Contact Tom Grabowski at Nationwide for pricing.",
             people: [activeLeads[8]], daysBack: 3,
             topics: ["group benefits", "small business", "retirement planning", "employer-sponsored insurance"],
             actions: [
                makeAction(type: .generalFollowUp,
                           description: "Call Tom Grabowski at Nationwide — small-group term pricing for Danielle Moss",
                           urgency: .immediate, person: activeLeads[8]),
                makeAction(type: .createProposal,
                           description: "Prepare personal retirement plan analysis for Danielle Moss",
                           urgency: .soon, person: activeLeads[8]),
             ])
    }

    // MARK: - Business Goals

    private func makeGoals(context: ModelContext, now: Date, daysFromNow: (Int) -> Date) {
        let cal = Calendar.current
        let m = cal.component(.month, from: now)
        let y = cal.component(.year, from: now)
        let quarterEndMonth = ((m - 1) / 3 + 1) * 3
        let quarterEnd = cal.date(from: DateComponents(year: y, month: quarterEndMonth + 1, day: 1))
            ?? daysFromNow(90)
        let yearEnd = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1))
            ?? daysFromNow(365)

        let goals: [(GoalType, String, Double, Date)] = [
            (.newClients,        "New clients this quarter",            6,       quarterEnd),
            (.policiesSubmitted, "Policies submitted this quarter",     12,      quarterEnd),
            (.productionVolume,  "Annual premium volume this quarter",  40_000,  quarterEnd),
            (.recruiting,        "New agent recruits this quarter",     2,       quarterEnd),
            (.meetingsHeld,      "Meetings per week",                   15,      daysFromNow(7)),
            (.contentPosts,      "Educational posts this month",        8,       daysFromNow(30)),
            (.deepWorkHours,     "Deep work hours this week",           10,      daysFromNow(7)),
            (.policiesSubmitted, "Total policies this year",            45,      yearEnd),
            (.newClients,        "New clients this year",               20,      yearEnd),
            (.productionVolume,  "Total annual premium this year",      160_000, yearEnd),
        ]

        for (type, title, target, end) in goals {
            let g = BusinessGoal(id: UUID(), goalType: type, title: title,
                                  targetValue: target, startDate: now, endDate: end)
            context.insert(g)
        }
    }

    // MARK: - Outcomes / Coaching Queue

    private func makeOutcomes(context: ModelContext,
                               clients: [SamPerson],
                               activeLeads: [SamPerson],
                               agents: [SamPerson],
                               referralPartners: [SamPerson],
                               daysAgo: (Int) -> Date,
                               daysFromNow: (Int) -> Date) {

        func outcome(_ title: String, _ rationale: String,
                     _ kind: OutcomeKind, _ priority: Double,
                     person: SamPerson? = nil,
                     status: OutcomeStatus = .pending,
                     deadline: Date? = nil,
                     lane: ActionLane = .call) {
            let o = SamOutcome(id: UUID(), title: title, rationale: rationale,
                                outcomeKind: kind, priorityScore: priority,
                                deadlineDate: deadline, status: status,
                                sourceInsightSummary: "Generated from relationship history and pipeline analysis.",
                                linkedPerson: person)
            o.actionLaneRawValue = lane.rawValue
            o.createdAt = daysAgo(Int.random(in: 1...5))
            context.insert(o)
        }

        // High priority
        outcome("Follow up on Maria Rodriguez's application status",
                "Maria's term life application has been with underwriting for 12 days. Checking status keeps momentum and shows professionalism.",
                .followUp, 0.95, person: activeLeads[0], deadline: daysFromNow(2))

        outcome("Prepare LTC overview for Eleanor Vance's annual review",
                "Eleanor mentioned LTC unprompted — her mother just entered memory care. Her review is in 28 days. A polished LTC presentation could lead to a significant policy.",
                .preparation, 0.92, person: clients[0], deadline: daysFromNow(20), lane: .deepWork)

        outcome("Prepare annuity comparison for Rachel Bloomfield",
                "Rachel is ready to do an $80K IRA rollover. A clear comparison of two products with income riders closes this sale.",
                .proposal, 0.90, person: clients[21], deadline: daysFromNow(5), lane: .deepWork)

        outcome("Call Kevin Szymanski — direct commitment conversation",
                "Kevin hasn't responded in 25 days. A direct call will either re-engage him or free up your mentoring capacity.",
                .training, 0.88, person: agents[7], deadline: daysFromNow(1))

        outcome("Create mortgage protection flyer for Sandra Okonkwo",
                "Sandra has two uninsured buyers closing this month. A one-page resource for her to hand at closing is a time-sensitive lead opportunity.",
                .outreach, 0.87, person: referralPartners[0], deadline: daysFromNow(3), lane: .deepWork)

        outcome("Call Brenda Kowalski — re-engagement",
                "Brenda has been unresponsive for 62 days. One more direct outreach determines whether to continue investing time in her development.",
                .training, 0.82, person: agents[4], deadline: daysFromNow(2))

        outcome("Call Tom Grabowski — small-group pricing for Danielle Moss",
                "Danielle's meeting is in 3 days. Getting Nationwide group term pricing before the meeting positions Harvey to close the business line.",
                .preparation, 0.85, person: activeLeads[8], deadline: daysFromNow(2))

        // Medium priority
        outcome("Prepare Jerome Washington conversion illustration",
                "Jerome's term-to-IUL conversion window closes in 3 years. A polished illustration at his annual review converts a long-term client to permanent coverage.",
                .proposal, 0.76, person: clients[4], lane: .deepWork)

        outcome("Post educational content — IUL basics",
                "Harvey hasn't posted on LinkedIn in 11 days. A short educational post on IUL tax advantages keeps him visible to his professional network.",
                .contentCreation, 0.70, lane: .deepWork)

        outcome("Follow up with Asha Krishnamurthy — CPA check-in",
                "Asha indicated she'd speak to her CPA before committing. Three weeks have passed — a friendly nudge will advance the sale or clarify her timeline.",
                .followUp, 0.74, person: activeLeads[2])

        outcome("File child rider amendment for Grace Kim",
                "Grace Kim's baby Emma is 2 weeks old. Filing the juvenile rider amendment now locks in the lowest premium based on current age.",
                .compliance, 0.88, person: clients[7], deadline: daysFromNow(7), lane: .deepWork)

        outcome("Text Terrence Boyd — schedule second meeting",
                "Terrence engaged well at the first meeting but hasn't responded to calls. A text may get through better than phone calls.",
                .followUp, 0.68, person: activeLeads[3], lane: .communicate)

        // Completed (for history)
        outcome("Deliver Grace Kim's IUL policy",
                "Policy delivery is a high-value touch point — trust deepens and referral potential increases.",
                .followUp, 0.85, person: clients[7], status: .completed)

        outcome("Help Carlos Ibáñez submit his first policy",
                "Carlos's first submission builds momentum and confidence. Celebrate the milestone.",
                .training, 0.80, person: agents[3], status: .completed)

        outcome("Send thank-you note to Sandra Okonkwo",
                "Referral gratitude is essential for sustaining the partnership.",
                .outreach, 0.75, person: referralPartners[0], status: .completed)

        outcome("Schedule Tiffany Roux exam prep session",
                "Tiffany is 3 weeks from her exam. A structured study session significantly improves her pass rate.",
                .training, 0.78, person: agents[2], status: .completed)
    }
}

// MARK: - Launch Hook

extension TestDataSeeder {
    /// Call on launch when sam.testData.active is true and the store is empty.
    static func seedIfNeeded(into context: ModelContext) async {
        guard UserDefaults.standard.isTestDataActive else { return }
        let count = (try? context.fetchCount(FetchDescriptor<SamPerson>())) ?? 0
        guard count == 0 else {
            Logger(subsystem: "com.sam", category: "TestDataSeeder")
                .info("Store already has \(count) people — skipping seed.")
            return
        }
        await TestDataSeeder.shared.insertData(into: context)
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted after a successful in-process test data seed. UI coordinators
    /// can observe this to trigger a refresh without requiring an app restart.
    static let samTestDataDidSeed = Notification.Name("com.sam.testDataDidSeed")
}
#endif
