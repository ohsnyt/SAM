import Foundation

#if canImport(FoundationModels)
import FoundationModels

@Generable(description: "Structured analysis of a financial advisor's meeting note, extracting people, topics, and action items")
fileprivate struct GuidedNoteAnalysis: Sendable {
    @Guide(description: "All people mentioned in the note, including new family members, dependents, and contacts. Pay special attention to relationships like 'son', 'daughter', 'wife', 'husband', 'child', 'spouse'. If someone is referred to by multiple names or nicknames (e.g., 'William' and 'Billy'), list all names.")
    var people: [GuidedPerson]
    
    @Guide(description: "Financial products or services discussed in the note, such as life insurance, retirement plans, annuities, 401k, IRA, disability insurance, etc. Include who each product is for and any amounts mentioned.")
    var keyTopics: [GuidedFinancialTopic]
    
    @Guide(description: "Action items, follow-ups, or next steps mentioned in the note")
    var actions: [String]
}

@Generable(description: "A person mentioned in the advisor's note")
fileprivate struct GuidedPerson: Sendable {
    @Guide(description: "The person's full name or primary name")
    var name: String
    
    @Guide(description: "The person's relationship to the note author or primary client (e.g., 'son', 'daughter', 'wife', 'husband', 'spouse', 'child', 'business partner')")
    var relationship: String?
    
    @Guide(description: "Alternative names, nicknames, or aliases for this person (e.g., 'Billy' for 'William')")
    var aliases: [String]
    
    @Guide(description: "Whether this appears to be a new person not previously known to the advisor (e.g., newborn, new spouse, new business partner)")
    var isNewPerson: Bool
}

@Generable(description: "A financial product or topic discussed in the note")
fileprivate struct GuidedFinancialTopic: Sendable {
    @Guide(description: "The type of financial product (e.g., 'Life Insurance', 'Retirement Plan', 'Annuity', '401k', 'IRA', 'Disability Insurance')")
    var productType: String
    
    @Guide(description: "Dollar amount mentioned, if any (e.g., '$50,000', '$1,000,000')")
    var amount: String?
    
    @Guide(description: "Who this product is for (name of the person)")
    var beneficiary: String?
    
    @Guide(description: "Client's sentiment or intent: 'wants', 'interested', 'considering', 'not interested', 'increase', 'decrease', 'cancel'")
    var sentiment: String?
}

#endif

public struct NoteAnalysisArtifact: Sendable {
    public let summary: String
    public let facts: [String]
    public let affect: String? // e.g., positive/neutral/negative
    public let implications: [String]
    // Guided Generation extracted entities (optional, available when FM is present)
    public let people: [PersonEntity]
    public let topics: [FinancialTopicEntity]
    public let actions: [String]
    public let usedLLM: Bool // Track whether we used FoundationModels or fell back to heuristics

    public init(
        summary: String,
        facts: [String],
        affect: String?,
        implications: [String],
        people: [PersonEntity] = [],
        topics: [FinancialTopicEntity] = [],
        actions: [String] = [],
        usedLLM: Bool = false
    ) {
        self.summary = summary
        self.facts = facts
        self.affect = affect
        self.implications = implications
        self.people = people
        self.topics = topics
        self.actions = actions
        self.usedLLM = usedLLM
    }
}

public struct PersonEntity: Sendable, Hashable {
    public let name: String
    public let relationship: String?
    public let aliases: [String]
    public let isNewPerson: Bool
    
    public init(name: String, relationship: String?, aliases: [String] = [], isNewPerson: Bool = false) {
        self.name = name
        self.relationship = relationship
        self.aliases = aliases
        self.isNewPerson = isNewPerson
    }
}

public struct FinancialTopicEntity: Sendable, Hashable {
    public let productType: String
    public let amount: String?
    public let beneficiary: String?
    public let sentiment: String?
    
    public init(productType: String, amount: String?, beneficiary: String?, sentiment: String? = nil) {
        self.productType = productType
        self.amount = amount
        self.beneficiary = beneficiary
        self.sentiment = sentiment
    }
}

public enum NoteLLMAnalyzer {
    public static func analyze(text: String) async throws -> NoteAnalysisArtifact {
        print("🔍 [NoteLLMAnalyzer] Analyzing text (length: \(text.count))")
        
        #if canImport(FoundationModels)
        // Try to use FoundationModels LLM first
        let model = SystemLanguageModel.default
        
        switch model.availability {
        case .available:
            print("✅ [NoteLLMAnalyzer] FoundationModels available - using on-device LLM for semantic analysis")
            do {
                let artifact = try await analyzeLLM(text: text)
                print("✅ [NoteLLMAnalyzer] LLM analysis complete:")
                print("   - Generated: \(artifact.facts.count) facts, \(artifact.implications.count) implications, \(artifact.actions.count) actions")
                print("   - Extracted \(artifact.people.count) people: \(artifact.people.map { "\($0.name) (\($0.relationship ?? "unknown"))\(artifact.people.first?.isNewPerson == true ? " [NEW]" : "")" })")
                print("   - Extracted \(artifact.topics.count) topics: \(artifact.topics.map { "\($0.productType) - \($0.beneficiary ?? "unknown beneficiary")" })")
                return artifact
            } catch {
                print("⚠️ [NoteLLMAnalyzer] LLM analysis failed: \(error)")
                print("⚠️ [NoteLLMAnalyzer] Falling back to heuristic analysis")
                return analyzeHeuristic(text: text)
            }
            
        case .unavailable(.deviceNotEligible):
            print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
            print("⚠️ [NoteLLMAnalyzer] Reason: Device not eligible for Apple Intelligence")
            print("⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis")
            print("⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information")
            return analyzeHeuristic(text: text)
            
        case .unavailable(.appleIntelligenceNotEnabled):
            print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
            print("⚠️ [NoteLLMAnalyzer] Reason: Apple Intelligence is not enabled in System Settings")
            print("⚠️ [NoteLLMAnalyzer] To enable: Settings → Apple Intelligence & Siri → Enable Apple Intelligence")
            print("⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis")
            print("⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information")
            return analyzeHeuristic(text: text)
            
        case .unavailable(.modelNotReady):
            print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
            print("⚠️ [NoteLLMAnalyzer] Reason: Apple Intelligence model is not ready (may be downloading)")
            print("⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis")
            print("⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information")
            return analyzeHeuristic(text: text)
            
        case .unavailable(let reason):
            print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
            print("⚠️ [NoteLLMAnalyzer] Reason: Apple Intelligence unavailable - \(reason)")
            print("⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis")
            print("⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information")
            return analyzeHeuristic(text: text)
        }
        #else
        print("⚠️⚠️⚠️ [NoteLLMAnalyzer] FALLBACK TO HEURISTICS ⚠️⚠️⚠️")
        print("⚠️ [NoteLLMAnalyzer] Reason: FoundationModels framework not available on this platform")
        print("⚠️ [NoteLLMAnalyzer] Using manual pattern matching instead of semantic LLM analysis")
        print("⚠️ [NoteLLMAnalyzer] Results will be less accurate and may miss contextual information")
        return analyzeHeuristic(text: text)
        #endif
    }
    
    #if canImport(FoundationModels)
    /// Use Apple's on-device LLM for semantic analysis of the note text
    private static func analyzeLLM(text: String) async throws -> NoteAnalysisArtifact {
        // Create a session with specialized instructions for financial advisor notes
        let instructions = """
        You are an expert assistant for financial advisors analyzing client meeting notes.
        
        Your tasks:
        1. Extract ALL people mentioned, especially new family members (children, spouses, dependents)
        2. Identify nicknames and aliases (e.g., "William" and "Billy" refer to the same person)
        3. Detect new people (newborns, new spouses, new dependents) - mark these with isNewPerson=true
        4. Extract financial products discussed (life insurance, retirement, annuities, 401k, IRA, etc.)
        5. Link products to the people they're for (beneficiaries)
        6. Identify action items and follow-ups
        7. Understand context and relationships (e.g., "I just had a son named William" means William is a NEW child dependent)
        
        Be thorough and extract ALL relevant information. Pay special attention to family relationships.
        """
        
        let session = LanguageModelSession(instructions: instructions)
        
        let prompt = """
        Analyze this financial advisor's meeting note and extract structured information:
        
        "\(text)"
        
        Extract:
        - All people mentioned (with relationships and aliases)
        - All financial products/topics discussed
        - Action items and follow-ups
        """
        
        let response = try await session.respond(
            to: prompt,
            generating: GuidedNoteAnalysis.self
        )
        
        // Convert LLM output to our artifact format
        let guided = response.content
        
        // Convert people
        let people = guided.people.map { person in
            PersonEntity(
                name: person.name,
                relationship: person.relationship,
                aliases: person.aliases,
                isNewPerson: person.isNewPerson
            )
        }
        
        // Convert topics
        let topics = guided.keyTopics.map { topic in
            FinancialTopicEntity(
                productType: topic.productType,
                amount: topic.amount,
                beneficiary: topic.beneficiary,
                sentiment: topic.sentiment
            )
        }
        
        // Generate summary from first action or first sentence
        let summary: String
        if let firstAction = guided.actions.first {
            summary = firstAction
        } else if let firstSentence = text.split(separator: ".").first {
            summary = String(firstSentence)
        } else {
            summary = String(text.prefix(140))
        }
        
        // Convert actions to facts and implications
        var facts: [String] = []
        var implications: [String] = []
        
        for action in guided.actions {
            let lower = action.lowercased()
            if lower.contains("follow") || lower.contains("schedule") || lower.contains("call") {
                facts.append(action)
            } else {
                implications.append(action)
            }
        }
        
        // Add person-specific implications
        for person in people where person.isNewPerson {
            implications.append("New \(person.relationship ?? "person") identified: \(person.name)")
        }
        
        // Add topic-specific implications
        for topic in topics {
            if let sentiment = topic.sentiment?.lowercased(), sentiment.contains("want") || sentiment.contains("interest") || sentiment.contains("increase") || sentiment.contains("consider") {
                let beneficiaryNote = topic.beneficiary.map { " for \($0)" } ?? ""
                implications.append("Potential opportunity: \(topic.productType)\(beneficiaryNote)")
            }
        }
        
        // Determine affect
        let affect = determineAffect(from: text)
        
        return NoteAnalysisArtifact(
            summary: summary,
            facts: facts,
            affect: affect,
            implications: implications,
            people: people,
            topics: topics,
            actions: guided.actions,
            usedLLM: true
        )
    }
    #endif
    
    /// Fallback heuristic analysis when FoundationModels is unavailable
    /// Uses simple pattern matching and keyword detection
    private static func analyzeHeuristic(text: String) -> NoteAnalysisArtifact {
        let summary = text.split(separator: ".").first.map(String.init) ?? String(text.prefix(140))
        let base = heuristicPostProcess(fullText: text, summary: summary)
        
        print("⚠️ [NoteLLMAnalyzer] Heuristic analysis complete (LIMITED ACCURACY):")
        print("   - Generated: \(base.facts.count) facts, \(base.implications.count) implications")
        print("   - Extracted \(base.people.count) people: \(base.people.map { "\($0.name) (\($0.relationship ?? "unknown"))" })")
        print("   - Extracted \(base.topics.count) topics: \(base.topics.map { $0.productType })")
        print("⚠️ [NoteLLMAnalyzer] WARNING: Heuristic analysis cannot:")
        print("   - Understand semantic relationships between people")
        print("   - Detect that nicknames refer to the same person")
        print("   - Infer that 'I just had a son' means create a new dependent")
        print("   - Understand context or sentiment accurately")
        
        return NoteAnalysisArtifact(
            summary: base.summary,
            facts: base.facts,
            affect: base.affect,
            implications: base.implications,
            people: base.people,
            topics: base.topics,
            actions: [],
            usedLLM: false
        )
    }

    /// Determine the emotional affect/sentiment of the text
    private static func determineAffect(from text: String) -> String {
        let lower = text.lowercased()
        
        // Positive indicators
        let positiveWords = ["great", "excited", "happy", "wonderful", "excellent", "pleased", "delighted"]
        let positiveCount = positiveWords.filter { lower.contains($0) }.count
        
        // Negative indicators
        let negativeWords = ["worried", "frustrated", "upset", "concerned", "disappointed", "angry"]
        let negativeCount = negativeWords.filter { lower.contains($0) }.count
        
        if positiveCount > negativeCount {
            return "positive"
        } else if negativeCount > positiveCount {
            return "negative"
        } else {
            return "neutral"
        }
    }

    private static func heuristicPostProcess(fullText: String, summary: String) -> NoteAnalysisArtifact {
        let lower = fullText.lowercased()  // Process full text, not just summary
        var facts: [String] = []
        var implications: [String] = []
        var people: [PersonEntity] = []
        var topics: [FinancialTopicEntity] = []

        // Follow-up detection
        if lower.contains("follow up") || lower.contains("follow-up") || lower.contains("talk about") || lower.contains("discuss") || lower.contains("can we") {
            facts.append("Follow-up requested")
        }
        
        // Opportunity detection - expanded keywords
        if lower.contains("interested") || lower.contains("opportunity") ||
           lower.contains("life insurance") || lower.contains("policy") ||
           lower.contains("retirement") || lower.contains("savings") ||
           lower.contains("want") || lower.contains("would like") ||
           lower.contains("need") || lower.contains("looking for") {
            implications.append("Potential opportunity")
        }
        
        // Risk/concern detection
        if lower.contains("concern") || lower.contains("issue") || 
           lower.contains("problem") || lower.contains("worried") {
            implications.append("Potential risk/concern")
        }
        
        // Use shared affect determination
        let affect = determineAffect(from: fullText)
        
        // Simple person extraction - look for "son/daughter/wife/husband/child named X" or "name is X"
        extractPeople(from: fullText, into: &people)
        
        // Simple topic extraction - look for product mentions
        extractTopics(from: fullText, into: &topics)

        return NoteAnalysisArtifact(
            summary: summary, 
            facts: facts, 
            affect: affect, 
            implications: implications,
            people: people,
            topics: topics,
            actions: [],
            usedLLM: false
        )
    }
    
    /// Extract person names and relationships from text using simple patterns
    private static func extractPeople(from text: String, into people: inout [PersonEntity]) {
        let patterns: [(pattern: String, defaultRelationship: String?, indicatesNew: Bool)] = [
            // "I just had a son. His name is William" - indicates new person
            (#"(?:just had|recently had|new)\s+(?:a\s+)?(son|daughter|child|baby).*?(?:name is|named|called)\s+([A-Z][a-z]+)"#, "child", true),
            // "My wife Mary"
            (#"(?:my|his|her)\s+(wife|husband|spouse|partner)\s+([A-Z][a-z]+)"#, nil, false),
            // "name is William" or "named Billy"
            (#"(?:name is|named|called)\s+([A-Z][a-z]+)"#, nil, false),
        ]
        
        for (patternStr, defaultRelationship, indicatesNew) in patterns {
            guard let regex = try? NSRegularExpression(pattern: patternStr, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            
            for match in matches {
                var name: String?
                var relationship: String? = defaultRelationship
                
                // Extract captured groups
                if match.numberOfRanges >= 2 {
                    if let range = Range(match.range(at: match.numberOfRanges - 1), in: text) {
                        name = String(text[range])
                    }
                    // If we have 3 groups, the middle one is the relationship
                    if match.numberOfRanges >= 3, let range = Range(match.range(at: 1), in: text) {
                        relationship = String(text[range])
                    }
                }
                
                if let name = name, !people.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                    people.append(PersonEntity(
                        name: name,
                        relationship: relationship,
                        aliases: [],
                        isNewPerson: indicatesNew
                    ))
                }
            }
        }
    }
    
    /// Extract financial products and amounts from text
    private static func extractTopics(from text: String, into topics: inout [FinancialTopicEntity]) {
        let lower = text.lowercased()
        
        // Life insurance mentions
        if lower.contains("life insurance") || lower.contains("policy") {
            let amount = extractAmount(from: text, near: "life insurance") ?? extractAmount(from: text, near: "policy")
            let beneficiary = extractBeneficiary(from: text)
            topics.append(FinancialTopicEntity(
                productType: "Life Insurance",
                amount: amount,
                beneficiary: beneficiary,
                sentiment: determineSentiment(from: text, product: "life insurance")
            ))
        }
        
        // Retirement mentions
        if lower.contains("retirement") || lower.contains("401k") || lower.contains("ira") {
            let amount = extractAmount(from: text, near: "retirement") ?? extractAmount(from: text, near: "savings")
            topics.append(FinancialTopicEntity(
                productType: "Retirement",
                amount: amount,
                beneficiary: nil,
                sentiment: determineSentiment(from: text, product: "retirement")
            ))
        }
    }
    
    private static func determineSentiment(from text: String, product: String) -> String? {
        let lower = text.lowercased()
        let context = lower.components(separatedBy: product).first ?? ""
        
        if context.contains("want") || context.contains("would like") || context.contains("interested") {
            return "wants"
        } else if context.contains("increase") {
            return "increase"
        } else if context.contains("consider") {
            return "considering"
        }
        return nil
    }
    
    private static func extractAmount(from text: String, near keyword: String) -> String? {
        // Look for $X,XXX or $XX,XXX pattern within ~50 chars of keyword
        guard let keywordRange = text.range(of: keyword, options: .caseInsensitive) else { return nil }
        let searchStart = text.index(keywordRange.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let searchEnd = text.index(keywordRange.upperBound, offsetBy: 50, limitedBy: text.endIndex) ?? text.endIndex
        let searchText = String(text[searchStart..<searchEnd])
        
        if let regex = try? NSRegularExpression(pattern: #"\$[\d,]+"#),
           let match = regex.firstMatch(in: searchText, range: NSRange(searchText.startIndex..., in: searchText)),
           let range = Range(match.range, in: searchText) {
            return String(searchText[range])
        }
        return nil
    }
    
    private static func extractBeneficiary(from text: String) -> String? {
        // Look for "for [name]" patterns
        if let regex = try? NSRegularExpression(pattern: #"for (?:my |his |her )?([A-Z][a-z]+)"#, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.numberOfRanges >= 2,
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        return nil
    }
}

