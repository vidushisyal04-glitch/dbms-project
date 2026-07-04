-- ============================================================
-- MarketSpace: PL/SQL Triggers & Alert Engine
-- 02_triggers.sql
-- Run AFTER 01_schema.sql
-- ============================================================

USE marketspace;

DELIMITER $$

-- ============================================================
-- TRIGGER: After a new listing is inserted
-- Fires the alert engine:
--   Finds all active alerts where:
--     (a) alert.category_id matches listing.category_id
--         OR listing is in a subcategory of alert.category_id
--     (b) alert.max_price IS NULL OR listing.price <= alert.max_price
--     (c) alert.keywords IS NULL OR keywords appear in title/description
--   Then inserts a notification record for each matching alert
-- ============================================================
DROP TRIGGER IF EXISTS trg_after_listing_insert$$

CREATE TRIGGER trg_after_listing_insert
AFTER INSERT ON listings
FOR EACH ROW
BEGIN
    DECLARE done        INT DEFAULT FALSE;
    DECLARE v_alert_id  INT;
    DECLARE v_user_id   INT;
    DECLARE v_max_price DECIMAL(12,2);
    DECLARE v_keywords  VARCHAR(200);
    DECLARE v_msg       TEXT;
    DECLARE v_cat_name  VARCHAR(100);
    DECLARE v_cat_match INT DEFAULT 0;

    -- Cursor over all active alerts that could match this listing's category
    -- (direct match OR listing category's parent matches alert's category)
    DECLARE alert_cursor CURSOR FOR
        SELECT a.alert_id, a.user_id, a.max_price, a.keywords
        FROM alerts a
        JOIN categories lc ON lc.category_id = NEW.category_id
        WHERE a.is_active = 1
          AND a.user_id != NEW.seller_id   -- don't alert the seller about their own listing
          AND (
                a.category_id = NEW.category_id          -- exact category match
                OR a.category_id = lc.parent_id           -- alert on parent, listing in child
              );

    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = TRUE;

    -- Fetch category name for the message
    SELECT name INTO v_cat_name FROM categories WHERE category_id = NEW.category_id;

    OPEN alert_cursor;

    read_loop: LOOP
        FETCH alert_cursor INTO v_alert_id, v_user_id, v_max_price, v_keywords;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Check price threshold
        IF v_max_price IS NOT NULL AND NEW.price > v_max_price THEN
            ITERATE read_loop;
        END IF;

        -- Check keyword filter (if set)
        IF v_keywords IS NOT NULL AND v_keywords != '' THEN
            IF LOCATE(LOWER(v_keywords), LOWER(NEW.title)) = 0
               AND LOCATE(LOWER(v_keywords), LOWER(NEW.description)) = 0 THEN
                ITERATE read_loop;
            END IF;
        END IF;

        -- Compose notification message
        SET v_msg = CONCAT(
            'New listing matches your alert: "',
            NEW.title,
            '" in category [', v_cat_name, '] ',
            'priced at ₹', FORMAT(NEW.price, 2),
            ' (Listing #', NEW.listing_id, ')'
        );

        -- Insert the notification
        INSERT INTO alert_notifications (alert_id, listing_id, user_id, message, is_read)
        VALUES (v_alert_id, NEW.listing_id, v_user_id, v_msg, 0);

    END LOOP;

    CLOSE alert_cursor;
END$$


-- ============================================================
-- TRIGGER: After listing status changes to 'sold'
-- Deactivates any open alerts for the exact listing
-- and records a "sold" notification to anyone who had it in a watch
-- ============================================================
DROP TRIGGER IF EXISTS trg_after_listing_sold$$

CREATE TRIGGER trg_after_listing_sold
AFTER UPDATE ON listings
FOR EACH ROW
BEGIN
    IF OLD.status != 'sold' AND NEW.status = 'sold' THEN
        -- Mark existing unread notifications for this listing as read (item gone)
        UPDATE alert_notifications
        SET is_read = 1
        WHERE listing_id = NEW.listing_id AND is_read = 0;
    END IF;
END$$


-- ============================================================
-- TRIGGER: Prevent a user from buying their own listing
-- (extra safety at DB level beyond stored procedure)
-- ============================================================
DROP TRIGGER IF EXISTS trg_before_transaction_insert$$

CREATE TRIGGER trg_before_transaction_insert
BEFORE INSERT ON transactions
FOR EACH ROW
BEGIN
    IF NEW.buyer_id = NEW.seller_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A seller cannot buy their own listing.';
    END IF;
END$$


-- ============================================================
-- TRIGGER: Auto-set category level on insert
-- ============================================================
DROP TRIGGER IF EXISTS trg_before_category_insert$$

CREATE TRIGGER trg_before_category_insert
BEFORE INSERT ON categories
FOR EACH ROW
BEGIN
    IF NEW.parent_id IS NULL THEN
        SET NEW.level = 0;
    ELSE
        SELECT level + 1 INTO NEW.level
        FROM categories
        WHERE category_id = NEW.parent_id;
    END IF;
END$$


-- ============================================================
-- TRIGGER: Log when alert is deactivated (audit)
-- ============================================================
DROP TRIGGER IF EXISTS trg_after_alert_deactivate$$

CREATE TRIGGER trg_after_alert_deactivate
AFTER UPDATE ON alerts
FOR EACH ROW
BEGIN
    -- If alert was just deactivated, mark its unread notifications as read
    IF OLD.is_active = 1 AND NEW.is_active = 0 THEN
        UPDATE alert_notifications
        SET is_read = 1
        WHERE alert_id = NEW.alert_id AND is_read = 0;
    END IF;
END$$

DELIMITER ;
