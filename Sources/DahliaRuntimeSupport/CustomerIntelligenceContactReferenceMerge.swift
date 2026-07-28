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

    DELETE FROM project_resource_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID
      AND EXISTS (
          SELECT 1
          FROM project_resource_references AS targetRef
          WHERE targetRef.projectId = project_resource_references.projectId
            AND targetRef.resourceType = 'contact'
            AND targetRef.resourceId = :targetID
      );
    DELETE FROM project_resource_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID
      AND rowid NOT IN (
          SELECT MIN(rowid)
          FROM project_resource_references
          WHERE resourceType = 'contact' AND resourceId = :sourceID
          GROUP BY projectId
      );
    UPDATE OR IGNORE project_resource_references
    SET resourceId = :targetID, updatedAt = :now
    WHERE resourceType = 'contact' AND resourceId = :sourceID;
    DELETE FROM project_resource_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID;

    DELETE FROM insight_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID
      AND EXISTS (
          SELECT 1
          FROM insight_references AS targetRef
          WHERE targetRef.insightId = insight_references.insightId
            AND targetRef.resourceType = 'contact'
            AND targetRef.resourceId = :targetID
      );
    DELETE FROM insight_references
    WHERE resourceType = 'contact' AND resourceId = :sourceID
      AND rowid NOT IN (
          SELECT MIN(rowid)
          FROM insight_references
          WHERE resourceType = 'contact' AND resourceId = :sourceID
          GROUP BY insightId
      );
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
