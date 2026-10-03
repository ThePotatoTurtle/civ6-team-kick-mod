-- TX_Icons.sql (fixture): one ICON_<type> alias per notification type
INSERT INTO IconDefinitions (Name, Atlas, 'Index') VALUES
	('ICON_NOTIFICATION_TX_VOTE_REQUIRED', 'ICON_ATLAS_NOTIFICATIONS', 12),
	('ICON_NOTIFICATION_TX_EXPELLED', 'ICON_ATLAS_NOTIFICATIONS', 12);
