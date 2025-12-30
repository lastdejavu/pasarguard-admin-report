-- PasarGuard Admin Report triggers (MySQL 8+)
-- Creates:
--   - admin_report_events table (with reported_at to avoid duplicate reporting)
--   - triggers on users: create + limit change + limit->unlimited + unlimited->limit + usage reset

USE pasarguard;

CREATE TABLE IF NOT EXISTS admin_report_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,

  event_type VARCHAR(64) NOT NULL,
  admin_id BIGINT NULL,
  user_id BIGINT NULL,
  username VARCHAR(255) NULL,

  old_data_limit BIGINT NULL,
  new_data_limit BIGINT NULL,

  old_used BIGINT NULL,
  new_used BIGINT NULL,

  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reported_at TIMESTAMP NULL DEFAULT NULL,

  INDEX idx_created_at (created_at),
  INDEX idx_reported_at (reported_at),
  INDEX idx_admin_created (admin_id, created_at),
  INDEX idx_admin_reported (admin_id, reported_at)
);

DELIMITER $$

DROP TRIGGER IF EXISTS trg_report_user_create $$
CREATE TRIGGER trg_report_user_create
AFTER INSERT ON users
FOR EACH ROW
BEGIN
  IF NEW.data_limit IS NULL THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, new_data_limit, new_used)
    VALUES ('UNLIMITED_CREATED', NEW.admin_id, NEW.id, NEW.username, NEW.data_limit, NEW.used_traffic);
  ELSE
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, new_data_limit, new_used)
    VALUES ('USER_CREATED', NEW.admin_id, NEW.id, NEW.username, NEW.data_limit, NEW.used_traffic);
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_report_user_update $$
CREATE TRIGGER trg_report_user_update
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
  -- limited -> unlimited
  IF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('LIMIT_TO_UNLIMITED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  -- unlimited -> limited (usually not a loss; still recorded for audit)
  ELSEIF (OLD.data_limit IS NULL AND NEW.data_limit IS NOT NULL) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('UNLIMITED_TO_LIMIT', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);

  -- limited -> limited (volume change)
  ELSEIF (OLD.data_limit IS NOT NULL AND NEW.data_limit IS NOT NULL AND OLD.data_limit <> NEW.data_limit) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_data_limit, new_data_limit, old_used, new_used)
    VALUES ('DATA_LIMIT_CHANGED', NEW.admin_id, NEW.id, NEW.username, OLD.data_limit, NEW.data_limit, OLD.used_traffic, NEW.used_traffic);
  END IF;

  -- usage reset (any decrease)
  IF (OLD.used_traffic > NEW.used_traffic) THEN
    INSERT INTO admin_report_events(event_type, admin_id, user_id, username, old_used, new_used)
    VALUES ('USAGE_RESET', NEW.admin_id, NEW.id, NEW.username, OLD.used_traffic, NEW.used_traffic);
  END IF;
END $$

DELIMITER ;
