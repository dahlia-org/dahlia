public enum CustomerIntelligenceContactReferenceMerge {
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

    INSERT OR IGNORE INTO conversation_topic_references
        (topicId, resourceType, resourceId, note, createdAt, updatedAt)
    SELECT topicId, resourceType, :targetID, note, createdAt, :now
    FROM conversation_topic_references WHERE resourceType = 'contact' AND resourceId = :sourceID;
    DELETE FROM conversation_topic_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID;
    """
}
