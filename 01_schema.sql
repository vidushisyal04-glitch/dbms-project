-- ============================================================
-- MarketSpace: Database Schema
-- 01_schema.sql
-- Run this FIRST
-- ============================================================

CREATE DATABASE IF NOT EXISTS marketspace CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE marketspace;

-- ============================================================
-- USERS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS users (
    user_id       INT AUTO_INCREMENT PRIMARY KEY,
    username      VARCHAR(50)  NOT NULL UNIQUE,
    email         VARCHAR(100) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    full_name     VARCHAR(100) NOT NULL,
    phone         VARCHAR(20),
    location      VARCHAR(100),
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    is_active     TINYINT(1) DEFAULT 1
);

-- ============================================================
-- HIERARCHICAL CATEGORIES TABLE (Self-Referential)
-- parent_id NULL  => top-level department
-- parent_id set   => sub-category of parent
-- ============================================================
CREATE TABLE IF NOT EXISTS categories (
    category_id   INT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(100) NOT NULL,
    description   TEXT,
    parent_id     INT DEFAULT NULL,
    level         INT DEFAULT 0,          -- 0=root, 1=sub, 2=leaf
    icon          VARCHAR(50) DEFAULT 'tag',
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (parent_id) REFERENCES categories(category_id) ON DELETE CASCADE
);

-- ============================================================
-- LISTINGS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS listings (
    listing_id    INT AUTO_INCREMENT PRIMARY KEY,
    seller_id     INT NOT NULL,
    category_id   INT NOT NULL,
    title         VARCHAR(200) NOT NULL,
    description   TEXT,
    price         DECIMAL(12, 2) NOT NULL,
    condition_type ENUM('New','Like New','Good','Fair','Poor') DEFAULT 'Good',
    status        ENUM('active','sold','removed') DEFAULT 'active',
    image_url     VARCHAR(500),
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at    DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    FOREIGN KEY (seller_id)   REFERENCES users(user_id)      ON DELETE CASCADE,
    FOREIGN KEY (category_id) REFERENCES categories(category_id) ON DELETE RESTRICT
);

-- ============================================================
-- ALERTS TABLE  (user registers interest in a category + max price)
-- ============================================================
CREATE TABLE IF NOT EXISTS alerts (
    alert_id      INT AUTO_INCREMENT PRIMARY KEY,
    user_id       INT NOT NULL,
    category_id   INT NOT NULL,
    max_price     DECIMAL(12, 2),          -- NULL = any price
    keywords      VARCHAR(200),            -- optional keyword filter
    is_active     TINYINT(1) DEFAULT 1,
    created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id)     REFERENCES users(user_id)      ON DELETE CASCADE,
    FOREIGN KEY (category_id) REFERENCES categories(category_id) ON DELETE CASCADE
);

-- ============================================================
-- ALERT NOTIFICATIONS TABLE  (trigger writes here)
-- ============================================================
CREATE TABLE IF NOT EXISTS alert_notifications (
    notification_id INT AUTO_INCREMENT PRIMARY KEY,
    alert_id        INT NOT NULL,
    listing_id      INT NOT NULL,
    user_id         INT NOT NULL,
    message         TEXT,
    is_read         TINYINT(1) DEFAULT 0,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (alert_id)   REFERENCES alerts(alert_id)    ON DELETE CASCADE,
    FOREIGN KEY (listing_id) REFERENCES listings(listing_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id)    REFERENCES users(user_id)       ON DELETE CASCADE
);

-- ============================================================
-- TRANSACTIONS TABLE
-- ============================================================
CREATE TABLE IF NOT EXISTS transactions (
    transaction_id  INT AUTO_INCREMENT PRIMARY KEY,
    listing_id      INT NOT NULL,
    buyer_id        INT NOT NULL,
    seller_id       INT NOT NULL,
    amount          DECIMAL(12, 2) NOT NULL,
    status          ENUM('pending','completed','cancelled') DEFAULT 'pending',
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (listing_id) REFERENCES listings(listing_id) ON DELETE RESTRICT,
    FOREIGN KEY (buyer_id)   REFERENCES users(user_id)       ON DELETE RESTRICT,
    FOREIGN KEY (seller_id)  REFERENCES users(user_id)       ON DELETE RESTRICT
);

-- ============================================================
-- MESSAGES TABLE (buyer-seller communication)
-- ============================================================
CREATE TABLE IF NOT EXISTS messages (
    message_id   INT AUTO_INCREMENT PRIMARY KEY,
    listing_id   INT NOT NULL,
    sender_id    INT NOT NULL,
    receiver_id  INT NOT NULL,
    body         TEXT NOT NULL,
    is_read      TINYINT(1) DEFAULT 0,
    sent_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (listing_id)  REFERENCES listings(listing_id) ON DELETE CASCADE,
    FOREIGN KEY (sender_id)   REFERENCES users(user_id)       ON DELETE CASCADE,
    FOREIGN KEY (receiver_id) REFERENCES users(user_id)       ON DELETE CASCADE
);

-- ============================================================
-- VIEWS for convenience
-- ============================================================

-- Full listing info with seller + category name
CREATE OR REPLACE VIEW vw_listing_details AS
SELECT
    l.listing_id,
    l.title,
    l.description,
    l.price,
    l.condition_type,
    l.status,
    l.image_url,
    l.created_at,
    u.username      AS seller_username,
    u.full_name     AS seller_name,
    u.phone         AS seller_phone,
    u.location      AS seller_location,
    c.name          AS category_name,
    c.category_id,
    pc.name         AS parent_category_name,
    pc.category_id  AS parent_category_id
FROM listings l
JOIN users u       ON l.seller_id   = u.user_id
JOIN categories c  ON l.category_id = c.category_id
LEFT JOIN categories pc ON c.parent_id = pc.category_id;

-- Unread notification count per user
CREATE OR REPLACE VIEW vw_unread_notifications AS
SELECT user_id, COUNT(*) AS unread_count
FROM alert_notifications
WHERE is_read = 0
GROUP BY user_id;

DELIMITER $$

-- ============================================================
-- STORED PROCEDURE: Get full category path (breadcrumb)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_get_category_path$$
CREATE PROCEDURE sp_get_category_path(IN p_category_id INT)
BEGIN
    DECLARE done        INT DEFAULT 0;
    DECLARE curr_id     INT DEFAULT p_category_id;
    DECLARE curr_name   VARCHAR(100);
    DECLARE curr_parent INT;
    DECLARE path_result TEXT DEFAULT '';

    -- Walk up the tree
    WHILE curr_id IS NOT NULL DO
        SELECT name, parent_id INTO curr_name, curr_parent
        FROM categories WHERE category_id = curr_id;

        IF path_result = '' THEN
            SET path_result = curr_name;
        ELSE
            SET path_result = CONCAT(curr_name, ' > ', path_result);
        END IF;

        SET curr_id = curr_parent;
    END WHILE;

    SELECT path_result AS category_path;
END$$

-- ============================================================
-- STORED PROCEDURE: Get category tree (recursive-style)
-- ============================================================
DROP PROCEDURE IF EXISTS sp_get_category_subtree$$
CREATE PROCEDURE sp_get_category_subtree(IN p_parent_id INT)
BEGIN
    IF p_parent_id IS NULL THEN
        SELECT c.*, COUNT(l.listing_id) AS listing_count
        FROM categories c
        LEFT JOIN listings l ON c.category_id = l.category_id AND l.status = 'active'
        WHERE c.parent_id IS NULL
        GROUP BY c.category_id;
    ELSE
        SELECT c.*, COUNT(l.listing_id) AS listing_count
        FROM categories c
        LEFT JOIN listings l ON c.category_id = l.category_id AND l.status = 'active'
        WHERE c.parent_id = p_parent_id
        GROUP BY c.category_id;
    END IF;
END$$

-- ============================================================
-- STORED PROCEDURE: Register or update an alert
-- ============================================================
DROP PROCEDURE IF EXISTS sp_upsert_alert$$
CREATE PROCEDURE sp_upsert_alert(
    IN p_user_id     INT,
    IN p_category_id INT,
    IN p_max_price   DECIMAL(12,2),
    IN p_keywords    VARCHAR(200),
    OUT p_alert_id   INT,
    OUT p_status     VARCHAR(20)
)
BEGIN
    DECLARE existing_id INT DEFAULT NULL;

    SELECT alert_id INTO existing_id
    FROM alerts
    WHERE user_id = p_user_id AND category_id = p_category_id
    LIMIT 1;

    IF existing_id IS NOT NULL THEN
        UPDATE alerts
        SET max_price = p_max_price, keywords = p_keywords, is_active = 1
        WHERE alert_id = existing_id;
        SET p_alert_id = existing_id;
        SET p_status   = 'updated';
    ELSE
        INSERT INTO alerts (user_id, category_id, max_price, keywords)
        VALUES (p_user_id, p_category_id, p_max_price, p_keywords);
        SET p_alert_id = LAST_INSERT_ID();
        SET p_status   = 'created';
    END IF;
END$$

-- ============================================================
-- STORED PROCEDURE: Search listings
-- ============================================================
DROP PROCEDURE IF EXISTS sp_search_listings$$
CREATE PROCEDURE sp_search_listings(
    IN p_keyword     VARCHAR(200),
    IN p_category_id INT,
    IN p_min_price   DECIMAL(12,2),
    IN p_max_price   DECIMAL(12,2),
    IN p_condition   VARCHAR(20),
    IN p_sort        VARCHAR(30)
)
BEGIN
    SET @sql = CONCAT(
        'SELECT l.listing_id, l.title, l.price, l.condition_type, l.image_url, l.created_at, ',
        '       u.username AS seller_username, u.location AS seller_location, ',
        '       c.name AS category_name ',
        'FROM listings l ',
        'JOIN users u ON l.seller_id = u.user_id ',
        'JOIN categories c ON l.category_id = c.category_id ',
        'WHERE l.status = ''active'' '
    );

    IF p_keyword IS NOT NULL AND p_keyword != '' THEN
        SET @sql = CONCAT(@sql, 'AND (l.title LIKE ''%', p_keyword, '%'' OR l.description LIKE ''%', p_keyword, '%'') ');
    END IF;
    IF p_category_id IS NOT NULL THEN
        SET @sql = CONCAT(@sql, 'AND (l.category_id = ', p_category_id, ' OR c.parent_id = ', p_category_id, ') ');
    END IF;
    IF p_min_price IS NOT NULL THEN
        SET @sql = CONCAT(@sql, 'AND l.price >= ', p_min_price, ' ');
    END IF;
    IF p_max_price IS NOT NULL THEN
        SET @sql = CONCAT(@sql, 'AND l.price <= ', p_max_price, ' ');
    END IF;
    IF p_condition IS NOT NULL AND p_condition != '' THEN
        SET @sql = CONCAT(@sql, 'AND l.condition_type = ''', p_condition, ''' ');
    END IF;

    IF p_sort = 'price_asc' THEN
        SET @sql = CONCAT(@sql, 'ORDER BY l.price ASC ');
    ELSEIF p_sort = 'price_desc' THEN
        SET @sql = CONCAT(@sql, 'ORDER BY l.price DESC ');
    ELSE
        SET @sql = CONCAT(@sql, 'ORDER BY l.created_at DESC ');
    END IF;

    PREPARE stmt FROM @sql;
    EXECUTE stmt;
    DEALLOCATE PREPARE stmt;
END$$

-- ============================================================
-- STORED PROCEDURE: Purchase a listing
-- ============================================================
DROP PROCEDURE IF EXISTS sp_purchase_listing$$
CREATE PROCEDURE sp_purchase_listing(
    IN  p_listing_id   INT,
    IN  p_buyer_id     INT,
    OUT p_result       VARCHAR(100)
)
BEGIN
    DECLARE v_seller_id INT;
    DECLARE v_price     DECIMAL(12,2);
    DECLARE v_status    VARCHAR(20);

    SELECT seller_id, price, status
    INTO v_seller_id, v_price, v_status
    FROM listings WHERE listing_id = p_listing_id;

    IF v_status != 'active' THEN
        SET p_result = 'ERROR: Listing is not available';
    ELSEIF v_seller_id = p_buyer_id THEN
        SET p_result = 'ERROR: Cannot buy your own listing';
    ELSE
        START TRANSACTION;
            UPDATE listings SET status = 'sold' WHERE listing_id = p_listing_id;
            INSERT INTO transactions (listing_id, buyer_id, seller_id, amount, status)
            VALUES (p_listing_id, p_buyer_id, v_seller_id, v_price, 'completed');
        COMMIT;
        SET p_result = 'SUCCESS';
    END IF;
END$$

DELIMITER ;
