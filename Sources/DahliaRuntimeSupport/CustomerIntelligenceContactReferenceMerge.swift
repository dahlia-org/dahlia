public enum CustomerIntelligenceContactReferenceMerge {
    /// Conflict strength is manual > suggestionApproved > ownerChannelConfirmation.
    public static let sql = """
    INSERT OR IGNORE INTO organization_memberships (organizationId, contactId, roleLabel, createdAt)
    SELECT organizationId, :targetID, roleLabel, createdAt
    FROM organization_memberships WHERE contactId = :sourceID;
    DELETE FROM organization_memberships WHERE contactId = :sourceID;

    INSERT OR IGNORE INTO meeting_participants
        (meetingId, contactId, role, responseStatus, source, createdAt, updatedAt)
    SELECT meetingId, :targetID, role, responseStatus, source, createdAt, updatedAt
    FROM meeting_participants WHERE contactId = :sourceID;
    DELETE FROM meeting_participants WHERE contactId = :sourceID;

    UPDATE OR IGNORE project_resource_references
    SET resourceId = :targetID, updatedAt = :now
    WHERE resourceType = 'contact' AND resourceId = :sourceID;
    DELETE FROM project_resource_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID;

    INSERT OR IGNORE INTO insight_references
        (insightId, resourceType, resourceId, referenceRole, createdAt)
    SELECT insightId, resourceType, :targetID, referenceRole, createdAt
    FROM insight_references WHERE resourceType = 'contact' AND resourceId = :sourceID;
    DELETE FROM insight_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID;

    UPDATE meeting_speakers
    SET revision = revision + 1,
        updatedAt = :now
    WHERE id IN (
        SELECT meetingSpeakerId
        FROM speaker_match_observations
        WHERE top1ContactId = :sourceID OR top2ContactId = :sourceID
    );

    UPDATE speaker_match_observations
    SET top1ContactId = CASE
            WHEN top1ContactId IN (:sourceID, :targetID)
              AND top2ContactId IN (:sourceID, :targetID)
            THEN :targetID
            WHEN top1ContactId = :sourceID THEN :targetID
            ELSE top1ContactId
        END,
        top1Score = CASE
            WHEN top1ContactId IN (:sourceID, :targetID)
              AND top2ContactId IN (:sourceID, :targetID)
            THEN MAX(top1Score, top2Score)
            ELSE top1Score
        END,
        top2ContactId = CASE
            WHEN top1ContactId IN (:sourceID, :targetID)
              AND top2ContactId IN (:sourceID, :targetID)
            THEN NULL
            WHEN top2ContactId = :sourceID THEN :targetID
            ELSE top2ContactId
        END,
        top2Score = CASE
            WHEN top1ContactId IN (:sourceID, :targetID)
              AND top2ContactId IN (:sourceID, :targetID)
            THEN NULL
            ELSE top2Score
        END,
        margin = CASE
            WHEN top1ContactId IN (:sourceID, :targetID)
              AND top2ContactId IN (:sourceID, :targetID)
            THEN NULL
            ELSE margin
        END,
        revision = revision + 1,
        updatedAt = :now
    WHERE top1ContactId = :sourceID OR top2ContactId = :sourceID;

    INSERT OR IGNORE INTO conversation_topic_references
        (topicId, resourceType, resourceId, note, createdAt, updatedAt)
    SELECT topicId, resourceType, :targetID, note, createdAt, :now
    FROM conversation_topic_references WHERE resourceType = 'contact' AND resourceId = :sourceID;
    DELETE FROM conversation_topic_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID;

    DROP TABLE IF EXISTS temp.dahlia_speaker_assignments_to_merge;
    CREATE TEMP TABLE dahlia_speaker_assignments_to_merge AS
    SELECT meetingSpeakerId, origin, createdAt
    FROM speaker_contact_assignments WHERE contactId = :sourceID;
    DELETE FROM speaker_contact_assignments WHERE contactId = :sourceID;
    INSERT OR IGNORE INTO speaker_contact_assignments
        (meetingSpeakerId, contactId, origin, createdAt, updatedAt)
    SELECT meetingSpeakerId, :targetID, origin, createdAt, :now
    FROM dahlia_speaker_assignments_to_merge;
    UPDATE speaker_contact_assignments
    SET origin = CASE
            WHEN origin = 'manual' THEN origin
            WHEN EXISTS (
                SELECT 1 FROM dahlia_speaker_assignments_to_merge AS incoming
                WHERE incoming.meetingSpeakerId = speaker_contact_assignments.meetingSpeakerId
                  AND incoming.origin = 'manual'
            ) THEN 'manual'
            WHEN origin = 'suggestionApproved' THEN origin
            WHEN EXISTS (
                SELECT 1 FROM dahlia_speaker_assignments_to_merge AS incoming
                WHERE incoming.meetingSpeakerId = speaker_contact_assignments.meetingSpeakerId
                  AND incoming.origin = 'suggestionApproved'
            ) THEN 'suggestionApproved'
            ELSE 'ownerChannelConfirmation'
        END,
        createdAt = MIN(
            createdAt,
            (SELECT incoming.createdAt
             FROM dahlia_speaker_assignments_to_merge AS incoming
             WHERE incoming.meetingSpeakerId = speaker_contact_assignments.meetingSpeakerId)
        ),
        updatedAt = :now
    WHERE contactId = :targetID
      AND meetingSpeakerId IN (SELECT meetingSpeakerId FROM dahlia_speaker_assignments_to_merge);
    DROP TABLE dahlia_speaker_assignments_to_merge;
    """
}
