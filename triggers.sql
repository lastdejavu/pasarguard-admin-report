-- ============================================================
-- PasarGuard /  Logs Triggers
-- This will auto-log admin actions into users_logs table
-- ============================================================

DROP TRIGGER IF EXISTS InsertLog;
DROP TRIGGER IF EXISTS UpdateLog;
DROP TRIGGER IF EXISTS DeleteLog;

DELIMITER $$

CREATE TRIGGER InsertLog
AFTER INSERT ON users
FOR EACH ROW
BEGIN
  INSERT INTO users_logs (
    admin_id,
    user_id,
    data_limit_old,
    data_limit_new,
    expire_old,
    expire_new,
    used_traffic_old,
    used_traffic_new,
    action,
    log_date
  )
  VALUES (
    NEW.admin_id,
    NEW.id,
    NULL,
    NEW.data_limit,
    NULL,
    NEW.expire,
    NULL,
    NEW.used_traffic,
    'INSERT',
    NOW()
  );
END$$

CREATE TRIGGER UpdateLog
AFTER UPDATE ON users
FOR EACH ROW
BEGIN
  INSERT INTO users_logs (
    admin_id,
    user_id,
    data_limit_old,
    data_limit_new,
    expire_old,
    expire_new,
    used_traffic_old,
    used_traffic_new,
    action,
    log_date
  )
  VALUES (
    NEW.admin_id,
    NEW.id,
    OLD.data_limit,
    NEW.data_limit,
    OLD.expire,
    NEW.expire,
    OLD.used_traffic,
    NEW.used_traffic,
    CASE
      WHEN OLD.data_limit <> NEW.data_limit AND (NEW.data_limit IS NULL OR NEW.data_limit = 0) THEN 'UNLIMITED'
      WHEN OLD.data_limit <> NEW.data_limit THEN 'CHANGE_LIMIT'
      WHEN OLD.expire <> NEW.expire THEN 'CHANGE_EXPIRE'
      WHEN OLD.used_traffic <> NEW.used_traffic AND NEW.used_traffic = 0 THEN 'RESET_USAGE'
      ELSE 'UPDATE'
    END,
    NOW()
  );
END$$

CREATE TRIGGER DeleteLog
AFTER DELETE ON users
FOR EACH ROW
BEGIN
  INSERT INTO users_logs (
    admin_id,
    user_id,
    data_limit_old,
    data_limit_new,
    expire_old,
    expire_new,
    used_traffic_old,
    used_traffic_new,
    action,
    log_date
  )
  VALUES (
    OLD.admin_id,
    OLD.id,
    OLD.data_limit,
    NULL,
    OLD.expire,
    NULL,
    OLD.used_traffic,
    NULL,
    'DELETE',
    NOW()
  );
END$$

DELIMITER ;
