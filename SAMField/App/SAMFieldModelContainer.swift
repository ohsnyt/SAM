//
//  SAMFieldModelContainer.swift
//  SAM Field
//
//  Created by Assistant on 4/8/26.
//  Phase F1: iOS Companion App Foundation
//
//  ModelContainer configuration for SAM Field (iOS).
//  Uses the same model set as the macOS app for full data access.
//

import Foundation
import SwiftData

/// All SwiftData models shared between SAM (macOS) and SAM Field (iOS).
/// Must match SAMSchema.allModels in SAMModelContainer.swift exactly.
private let allFieldModels: [any PersistentModel.Type] = [
    SamPerson.self,
    SamContext.self,
    ContextParticipation.self,
    Responsibility.self,
    JointInterest.self,
    ConsentRequirement.self,
    Product.self,
    Coverage.self,
    SamEvidenceItem.self,
    SamInsight.self,
    SamNote.self,
    SamAnalysisArtifact.self,
    UnknownSender.self,
    SamOutcome.self,
    CoachingProfile.self,
    NoteImage.self,
    SamDailyBriefing.self,
    SamUndoEntry.self,
    TimeEntry.self,
    StageTransition.self,
    RecruitingStage.self,
    ProductionRecord.self,
    StrategicDigest.self,
    ContentPost.self,
    BusinessGoal.self,
    ComplianceAuditEntry.self,
    DeducedRelation.self,
    PendingEnrichment.self,
    IntentionalTouch.self,
    LinkedInImport.self,
    NotificationTypeTracker.self,
    ProfileAnalysisRecord.self,
    EngagementSnapshot.self,
    SocialProfileSnapshot.self,
    FacebookImport.self,
    SubstackImport.self,
    SamEvent.self,
    EventParticipation.self,
    SamPresentation.self,
    RoleDefinition.self,
    RoleCandidate.self,
    GoalJournalEntry.self,
    EventEvaluation.self,
    SamTrip.self,
    SamTripStop.self,
    TranscriptSession.self,
    TranscriptSegment.self,
    SpeakerProfile.self,
    PendingUpload.self,
]

/// Model container for the SAM Field iOS app.
enum SAMFieldModelContainer {

    /// Process-lifetime container shared across the iOS app.
    static let shared: ModelContainer = {
        // Ensure Application Support directory exists
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let schema = Schema(allFieldModels)
        let config = ModelConfiguration(
            "SAM_v34",
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SAMFieldModelContainer: failed to create ModelContainer — \(error)")
        }
    }()
}
