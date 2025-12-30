-- NOTE:
-- Installer runs this file with the correct database selected (DB_NAME).
-- So we do NOT hardcode "USE pasarguard;" here.

CREATE TABLE IF NOT EXISTS admin_report_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

  event_type VARCHAR(64) NOT NULL,

  admin_id BIGINT NULL,
  user_id  BIGINT NULL,
  username VARCHAR(255) NULL,

  old_data_limit BIGINT NULL,
  new_data_limit BIGINT NULL,

  old_used BIGINT NULL,
  new_used BIGINT NULL,

  reported_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

  INDEX idx_reported_at (reported_at),
  INDEX idx_admin_time (admin_id, reported_at),
  INDEX idx_user_time (user_id, reported_at)
);

SET @has_col := (
  SELECT COUNT(*)
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'admin_report_events'
    AND COLUMN_NAME = 'reported_at'
);

SET @sql := IF(
  @has_col = 0,
  'ALTER TABLE admin_report_events ADD COLUMN reported_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP',
  'SELECT 1'
);

PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @has_created_at := (
  SELECT COUNT(*)
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = DATABASE()
    AND TABLE_NAME = 'admin_report_events'
    AND COLUMN_NAME = 'created_at'
);

SET @sql2 := IF(
  @has_created_at > 0,
  'UPDATE admin_report_events SET reported_at = created_at WHERE reported_at IS NULL',
  'SELECT 1'
);

PREPARE stmt2 FROM @sql2;
EXECUTE stmt2;
DEALLOCATE PREPARE stmt2;

DELIMITER $$

DROP TRIGGER IF EXISTS trg_report_user_create $$
CREATE TRIGGER trg_report_user_create
AFTER INSERT ON users
FOR EACH ROW
BEGIN
  IF NEW.data_limit IS NULL THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      new_data_limit, new_used
    )
    VALUES (
      'UNLIMITED_CREATED', NEW.admin_id, NEW.id, NEW.username,
      NULL, NEW.used_traffic
    );
  ELSE
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      new_data_limit, new_used
    )
    VALUES (
      'USER_CREATED', NEW.admin_id, NEW.id, NEW.username,
      NEW.data_limit, NEW.used_traffic
    );
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_report_user_update $$
CREATE TRIGGER trg_report_user_update
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
  IF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NULL) THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      old_data_limit, new_data_limit, old_used, new_used
    )
    VALUES (
      'LIMIT_TO_UNLIMITED', NEW.admin_id, NEW.id, NEW.username,
      OLD.data_limit, NULL, OLD.used_traffic, NEW.used_traffic
    );

  ELSEIF (OLD.data_limit IS NULL AND NEW.data_limit IS NOT NULL) THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      old_data_limit, new_data_limit, old_used, new_used
    )
    VALUES (
      'UNLIMITED_TO_LIMIT', NEW.admin_id, NEW.id, NEW.username,
      NULL, NEW.data_limit, OLD.used_traffic, NEW.used_traffic
    );

  ELSEIF (OLD.data_limit <> NEW.data_limit) THEN
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      old_data_limit, new_data_limit, old_used, new_used
    )
    VALUES (
      'DATA_LIMIT_CHANGED', NEW.admin_id, NEW.id, NEW.username,
      OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic
    );
  END IF;

  IF (OLD.used_traffic > NEW.used_traffic) THEN
    -- store current limit so digest can charge FULL LIMIT on reset
    INSERT INTO admin_report_events(
      event_type, admin_id, user_id, username,
      new_data_limit, old_used, new_used
    )
    VALUES (
      'USAGE_RESET', NEW.admin_id, NEW.id, NEW.username,
      NEW.data_limit, OLD.used_traffic, NEW.used_traffic
    );
  END IF;
END $$

DELIMITER ;
