-- TX_Bad.sql (BROKEN fixture)
-- Types row with KIND_NOTIFICATION but no Notifications row -> sql-notification (no DB needed)
INSERT INTO Types (Type, Kind) VALUES ('NOTIFICATION_TX_ORPHAN', 'KIND_NOTIFICATION');

-- unknown Kind -> foreign key violation at the end of the load -> sql-fk (game DB only)
INSERT INTO Types (Type, Kind) VALUES ('TX_BAD_KIND', 'KIND_NOPE');

-- unknown column -> sql (game DB only)
INSERT INTO Notifications (NotificationType, SeverityType, NoSuchColumn) VALUES ('NOTIFICATION_TX_X', 'LOW', 1);

-- unknown table -> sql (game DB only)
INSERT INTO NoSuchTable (A) VALUES (1);

-- CHECK constraint (ExpiresEndOfTurn IN (0,1)) -> sql (game DB only)
INSERT INTO Notifications (NotificationType, ExpiresEndOfTurn) VALUES ('NOTIFICATION_TX_ORPHAN2', 5);

-- missing comma -> sql syntax error (no DB needed)
INSERT INTO Types (Type, Kind) VALUES ('TX_BAD_SYNTAX' 'KIND_NOTIFICATION');
