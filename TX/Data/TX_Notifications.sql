-- ===========================================================================
-- TX_Notifications.sql  (modinfo InGameActions UpdateDatabase TX_Data)
-- Team Kick 1.0.0, PLAN II.7 and II.13.
--
-- One Types row (Kind KIND_NOTIFICATION) and one Notifications row per type
-- (pattern EFV/Data/EFV_Notifications.sql:74-114; columns per R C,
-- 01_GameplaySchema.sql:2109-2123).
-- - Message / Summary: NULL. The text comes at send time from
--   LOC_<type>_MESSAGE / LOC_<type>_SUMMARY (TX_Notify, looked up in G).
-- - ExpiresEndOfTurn 0 on VOTE_REQUIRED and KICK_PASSED: they stay until the
--   UI dismisses them; gameplay re-sends them each turn with AlwaysUnique
--   (TP 2.4; EFV_Notifications.sql:16-25). KICK_DONE, HARD_KICK_DONE (after
--   the war then peace of a hard kick, PLAN Part II notes "Kick modes") and
--   REQUEST_FAILED are one-off news (1).
-- - AutoActivate 0. No end-turn blocking (no such column, R C).
-- - Icon: shipped icons of the same cells as the ICON_<type> aliases in
--   TX_Icons.sql (GENERIC 0, DIPLO_ALLIANCE_EXPIRED 122). Keep both in step.
-- ===========================================================================

INSERT INTO Types (Type, Kind) VALUES
	('NOTIFICATION_TX_VOTE_REQUIRED',  'KIND_NOTIFICATION'),
	('NOTIFICATION_TX_KICK_PASSED',    'KIND_NOTIFICATION'),
	('NOTIFICATION_TX_KICK_DONE',      'KIND_NOTIFICATION'),
	('NOTIFICATION_TX_REQUEST_FAILED', 'KIND_NOTIFICATION'),
	('NOTIFICATION_TX_HARD_KICK_DONE', 'KIND_NOTIFICATION');

INSERT INTO Notifications (NotificationType, SeverityType, ExpiresEndOfTurn, AutoActivate, Icon) VALUES
	('NOTIFICATION_TX_VOTE_REQUIRED',  'HIGH', 0, 0, 'ICON_NOTIFICATION_GENERIC'),
	('NOTIFICATION_TX_KICK_PASSED',    'HIGH', 0, 0, 'ICON_NOTIFICATION_DIPLO_ALLIANCE_EXPIRED'),
	('NOTIFICATION_TX_KICK_DONE',      'MID',  1, 0, 'ICON_NOTIFICATION_DIPLO_ALLIANCE_EXPIRED'),
	('NOTIFICATION_TX_REQUEST_FAILED', 'LOW',  1, 0, 'ICON_NOTIFICATION_GENERIC'),
	('NOTIFICATION_TX_HARD_KICK_DONE', 'MID',  1, 0, 'ICON_NOTIFICATION_DIPLO_ALLIANCE_EXPIRED');
