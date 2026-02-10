import Foundation
import SwiftData
import Contacts

#if DEBUG

/// Seeds fixture data by:
/// 1. Clearing all SwiftData
/// 2. Re-importing contacts from the SAM group in Contacts.app
/// 3. Re-importing calendar events (links to contacts via email)
/// 4. Finding Harvey Snodgrass in the database
/// 5. Creating an IUL product for Harvey with Coverage
/// 6. Creating a note that triggers LLM analysis
/// 7. Letting the normal pipeline create evidence, insights, and suggestions
enum FixtureSeeder {
    
    static func seedIfNeeded(using container: ModelContainer) async {
        let context = ModelContext(container)
        
        print("🌱 [FixtureSeeder] Starting fixture seed...")
        
        // Step 1: Clear all existing data
        await clearAllData(context: context)
        
        // Step 2: Re-import contacts from SAM group
        await importAllContacts(context: context)
        
        // Step 3: Re-import calendar events (will link to contacts)
        await importCalendarEvents()
        
        // Step 4: Find Harvey in the database (should exist after import)
        guard let harveyID = await findHarveyInDatabase(context: context) else {
            print("⚠️  [FixtureSeeder] Harvey Snodgrass not found in database after import. Skipping fixture.")
            print("   💡 Create a contact named 'Harvey Snodgrass' in Contacts.app to use this fixture.")
            return
        }
        
        // Step 5: Create Harvey's IUL product with Coverage
        await createHarveysIUL(harveyID: harveyID, context: context)
        
        // Step 6: Create note about William's birth
        await createWilliamBirthNote(harveyID: harveyID, context: context)
        
        try? context.save()
        
        print("✅ [FixtureSeeder] Fixture seed complete!")
        print("   - Contacts imported from SAM group in Contacts.app")
        print("   - Calendar events imported and linked to contacts")
        print("   - Harvey Snodgrass found in database")
        print("   - IUL product created ($30,000 initial, $8,000/year)")
        print("   - Coverage record created (Harvey as insured)")
        print("   - Note about William's birth created")
        print("   - LLM analysis will process note automatically")
    }
    
    // MARK: - Step 1: Clear All Data
    
    private static func clearAllData(context: ModelContext) async {
        print("🗑️  [FixtureSeeder] Clearing all SwiftData...")
        
        // Delete all model types
        await MainActor.run {
            do {
                // Evidence
                let evidence = try context.fetch(FetchDescriptor<SamEvidenceItem>())
                evidence.forEach { context.delete($0) }
                
                // Insights
                let insights = try context.fetch(FetchDescriptor<SamInsight>())
                insights.forEach { context.delete($0) }
                
                // Notes
                let notes = try context.fetch(FetchDescriptor<SamNote>())
                notes.forEach { context.delete($0) }
                
                // Products
                let products = try context.fetch(FetchDescriptor<Product>())
                products.forEach { context.delete($0) }
                
                // Contexts
                let contexts = try context.fetch(FetchDescriptor<SamContext>())
                contexts.forEach { context.delete($0) }
                
                // People
                let people = try context.fetch(FetchDescriptor<SamPerson>())
                people.forEach { context.delete($0) }
                
                try context.save()
                print("✅ [FixtureSeeder] All data cleared")
            } catch {
                print("❌ [FixtureSeeder] Error clearing data: \(error)")
            }
        }
    }
    
    // MARK: - Step 2: Import Contacts from SAM Group
    
    private static func importAllContacts(context: ModelContext) async {
        print("📇 [FixtureSeeder] Importing contacts from SAM group...")
        
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            print("⚠️  [FixtureSeeder] Contacts authorization not granted")
            return
        }
        
        let importer = await MainActor.run {
            ContactsImporter(modelContext: context)
        }
        
        do {
            let (imported, updated) = try await importer.importFromSAMGroup()
            await MainActor.run {
                print("✅ [FixtureSeeder] Contacts imported from SAM group: \(imported) new, \(updated) updated")
            }
        } catch ContactsImporter.ImportError.samGroupNotFound {
            await MainActor.run {
                print("⚠️  [FixtureSeeder] SAM group not found in Contacts.app")
                print("   💡 Create a group called 'SAM' in Contacts.app and add Harvey Snodgrass to it")
            }
        } catch {
            await MainActor.run {
                print("❌ [FixtureSeeder] Error importing contacts: \(error)")
            }
        }
    }
    
    // MARK: - Step 3: Import Calendar Events
    
    private static func importCalendarEvents() async {
        print("📅 [FixtureSeeder] Importing calendar events...")
        
        // Use the shared CalendarImportCoordinator to import events
        await CalendarImportCoordinator.shared.importNow()
        
        print("✅ [FixtureSeeder] Calendar events imported and linked to contacts")
    }
    
    // MARK: - Step 4: Find Harvey in Database
    
    private static func findHarveyInDatabase(context: ModelContext) async -> PersistentIdentifier? {
        print("🔍 [FixtureSeeder] Searching for Harvey Snodgrass in database...")
        
        return await MainActor.run {
            do {
                // Fetch all people and search for Harvey by display name
                let descriptor = FetchDescriptor<SamPerson>()
                let allPeople = try context.fetch(descriptor)
                
                // Look for Harvey Snodgrass (case-insensitive)
                if let harvey = allPeople.first(where: { person in
                    let name = person.displayNameCache?.lowercased() ?? person.displayName.lowercased()
                    return name.contains("harvey") && name.contains("snodgrass")
                }) {
                    print("✅ [FixtureSeeder] Found Harvey Snodgrass:")
                    print("   - Name: \(harvey.displayNameCache ?? harvey.displayName)")
                    print("   - Email: \(harvey.emailCache ?? harvey.email ?? "none")")
                    print("   - Contact ID: \(harvey.contactIdentifier ?? "none")")
                    return harvey.persistentModelID
                } else {
                    print("⚠️  [FixtureSeeder] Harvey Snodgrass not found in database")
                    return nil
                }
            } catch {
                print("❌ [FixtureSeeder] Error searching for Harvey: \(error)")
                return nil
            }
        }
    }
    
    // MARK: - Step 5: Create Harvey's IUL Product with Coverage
    
    private static func createHarveysIUL(harveyID: PersistentIdentifier, context: ModelContext) async {
        await MainActor.run {
            print("💼 [FixtureSeeder] Creating IUL product for Harvey...")
            
            guard let harvey = context.model(for: harveyID) as? SamPerson else {
                print("❌ [FixtureSeeder] Could not find Harvey in context")
                return
            }
            
            let iul = Product(
                id: UUID(),
                type: .lifeInsurance,
                name: "IUL Policy - Sample Insurance Co.",
                statusDisplay: "In Force",
                icon: "shield.fill",
                subtitle: "$30,000 initial contribution, $8,000/year premium"
            )
            
            context.insert(iul)
            
            // Create Coverage record linking Harvey as insured (owner/insured typically same person for IUL)
            let coverage = Coverage(
                id: UUID(),
                person: harvey,
                product: iul,
                role: .insured,
                survivorshipRights: false
            )
            
            context.insert(coverage)
            
            print("✅ [FixtureSeeder] IUL created:")
            print("   - Initial contribution: $30,000")
            print("   - Annual premium: $8,000")
            print("   - Status: In Force")
            print("   - Coverage: Harvey Snodgrass (Insured)")
        }
    }
    
    // MARK: - Step 6: Create Note About William's Birth
    
    private static func createWilliamBirthNote(harveyID: PersistentIdentifier, context: ModelContext) async {
        print("📝 [FixtureSeeder] Creating note about William's birth...")
        
        await MainActor.run {
            guard let harvey = context.model(for: harveyID) as? SamPerson else {
                print("❌ [FixtureSeeder] Could not find Harvey in context")
                return
            }
            
            let noteText = """
            I had a son born on September 17, 2023. His name is William. I want my young Billy to have a $50,000 life insurance policy. And in addition, I got a raise at work recently so I'd like to increase my contributions to my IUL. Can we talk about that as well?
            """
            
            let note = SamNote(
                id: UUID(),
                createdAt: Date(),
                text: noteText,
                people: [harvey]
            )
            
            context.insert(note)
            try? context.save()
            
            print("✅ [FixtureSeeder] Note created:")
            print("   - Mentions William (son, born Sept 17, 2023)")
            print("   - Requests $50,000 life insurance for Billy")
            print("   - Mentions raise at work")
            print("   - Wants to increase IUL contributions")
            print("   - LLM will analyze and create:")
            print("     • Evidence item")
            print("     • Signals (life event, product opportunity)")
            print("     • Suggestion to add William as dependent")
            print("     • Summary note for Harvey's contact")
        }
    }
}

#endif

