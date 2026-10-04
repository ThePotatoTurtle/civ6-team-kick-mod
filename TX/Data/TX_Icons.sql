-- ===========================================================================
-- TX_Icons.sql  (modinfo InGameActions UpdateIcons TX_Icons)
-- Team Expulsion 0.1.0, PLAN II.13.
--
-- IconDefinitions(Name, Atlas, 'Index') aliases to existing atlas cells, no
-- new textures (pattern EFV/Data/EFV_Icons.sql:22-41). The notification
-- panel falls back to "ICON_" .. NotificationType (NotificationPanel.lua:25,
-- 793), so each alias is named ICON_<type>. TX_Notifications.sql sets the
-- Icon column to the shipped icon of the same cell; keep the two in step.
-- ===========================================================================

INSERT INTO IconDefinitions (Name, Atlas, 'Index') VALUES
	('ICON_NOTIFICATION_TX_VOTE_REQUIRED',  'ICON_ATLAS_NOTIFICATIONS', 0),    -- GENERIC
	('ICON_NOTIFICATION_TX_KICK_PASSED',    'ICON_ATLAS_NOTIFICATIONS', 122),  -- DIPLO_ALLIANCE_EXPIRED
	('ICON_NOTIFICATION_TX_KICK_DONE',      'ICON_ATLAS_NOTIFICATIONS', 122),  -- DIPLO_ALLIANCE_EXPIRED
	('ICON_NOTIFICATION_TX_REQUEST_FAILED', 'ICON_ATLAS_NOTIFICATIONS', 0);    -- GENERIC
