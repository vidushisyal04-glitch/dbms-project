# MarketSpace
### A Database-Driven Hierarchical E-Marketplace with PL/SQL Alerting Services

> **Team:** Amogh Haldavanekar (240968254) · Vidushi Syal (24096000) · DSE Section A

---

## Project Structure

---

```text
marketspace/
├── database/
│   ├── 01_schema.sql       ← Tables, Views, Stored Procedures (Lab 1-5, 9)
│   └── 02_triggers.sql     ← PL/SQL Triggers (Alert Engine) (Lab 10)
├── backend/
│   ├── app.py              ← Flask REST API (Lab 11 equivalent)
│   └── requirements.txt    ← Python dependencies
├── frontend/
│   └── index.html          ← Complete Single-Page Application GUI
└── README.md               ← This file
``` 
---

## Prerequisites
| Tool | Version | Download | 
| MySQL | 8.0+ | https://dev.mysql.com/downloads/ |
| Python | 3.9+| https://python.org | 
| pip | latest | Bundled with Python |

---

## Step-by-Step Setup & Run

### STEP 1 — Set Up the Database
Open your MySQL client (MySQL Workbench, terminal, or XAMPP shell):
mysql -u root -p
Run the schema and trigger files in order:
SQL
-- 1. Create all tables, views, and stored procedures
SOURCE /path/to/marketspace/database/01_schema.sql;

-- 2. Create all PL/SQL triggers
SOURCE /path/to/marketspace/database/02_triggers.sql;

Initialize Categories (DML Insert):Since the frontend requires categories to post listings, run these standard INSERT commands to create your foundational departments:SQLUSE marketspace;
INSERT INTO categories (name, description, icon) VALUES ('Electronics', 'Gadgets and devices', 'cpu');
INSERT INTO categories (name, description, icon) VALUES ('Vehicles', 'Cars and bikes', 'truck');
INSERT INTO categories (name, description, icon) VALUES ('Fashion', 'Clothing and apparel', 'shirt');

### STEP 2 — Configure the BackendOpen backend/app.py and find the DB_CONFIG section near the top. Change 'password': '' to your actual MySQL root password.PythonDB_CONFIG = {
    'host':     'localhost',
    'port':     3306,
    'user':     'root',
    'password': 'your_password_here', 
    'database': 'marketspace',
    ...
}

### STEP 3 — Install Python Dependencies
```bash
cd marketspace/backend

# Create and activate a virtual environment
python -m venv venv

# Windows: 
venv\Scripts\activate

# macOS/Linux: 
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

---

### STEP 4 — Run the Backend Server
```bash
python app.py
```

---

### STEP 5 — Open the Application
Open your browser and go to 
http://localhost:5000
The Flask server automatically serves the frontend index.html.
 
Testing the PL/SQL Alert System
This is the core feature demonstrating database automation. Follow these steps to see it in action:
1. Click Sign Up and register a new buyer account (e.g., buyer_user).
2. Go to Price Alerts → Create an alert for "Electronics" with a max price of ₹80,000.
3. Log out, then click Sign Up to create a second account representing a seller (e.g., seller_user).
4. Go to Post Listing → Post a new item (e.g., "Gaming Laptop") under "Electronics" priced at ₹75,000.
5. Log out, and log back in as your first buyer_user.
6. Click the 🔔 bell icon in the navbar — you'll see a new alert notification!

What happened behind the scenes: The trg_after_listing_insert PL/SQL trigger fired automatically on the listings table INSERT. It scanned all active alerts, matched the category and price threshold, and wrote a row to alert_notifications. No application code ran — the database handled it entirely.

### Database Architecture

## Tables

| Table| Purpose|
| users | Registered users (buyer + seller) |
| categories | Self-referential hierarchical categories (parent_id → category_id) |
| listings | Product listings with seller, category, price, condition | 
| alerts | User-registered price/category alerts |
| alert_notifications | Auto-populated by PL/SQL triggers when a listing matches |
| transactions | Purchase records |
| messages | Buyer-seller messaging per listing |

## Views

| View | Description |
| vw_listing_details | Full listing info with seller + category via JOINs |
| vw_unread_notifications | Unread notification count per user | 

## Stored Procedures
| Procedure | Description |
| sp_get_category_path | Returns breadcrumb path (e.g., "Electronics > Laptops > MacBooks") |
| sp_get_category_subtree | Returns child categories of a given parent |
| sp_upsert_alert | Creates or updates a user alert (INSERT or UPDATE) |
| sp_search_listings | Dynamic search with filters (keyword, category, price, condition) |
| sp_purchase_listing | Atomic purchase with transaction (UPDATE + INSERT in one commit)

## PL/SQL Triggers
| Trigger | Table | Event | Purpose |
| trg_after_listing_insert | listings | AFTER INSERT |Alert Engine — matches new listing against all active alerts; fires notifications |
| trg_after_listing_sold | listings | AFTER UPDATE | Marks open notifications as read when item sells |
| trg_before_transaction_insert | transactions | BEFORE INSERT | Prevents a seller from buying their own listing |
| trg_before_category_insert | categories | BEFORE INSERT | Auto-computes level field for hierarchy depth |
| trg_after_alert_deactivate | alerts | AFTER UPDATE | Cleans up unread notifications when alert is deactivated |

## Hierarchical Category System
Categories use a self-referential table design:
Electronics (level 0, parent_id = NULL)
  └── Mobile Phones (level 1, parent_id = 1)
       ├── Android Phones (level 2, parent_id = 9)
       ├── iPhones (level 2, parent_id = 9)
       └── Accessories (level 2, parent_id = 9)
  └── Laptops (level 1, parent_id = 1)
       ├── Windows Laptops (level 2, parent_id = 10)
       └── MacBooks (level 2, parent_id = 10)
Alert matching supports both exact and parent-level matching — an alert on "Electronics" fires for any listing in any sub-category of Electronics.

---

### API Endpoints

## Auth
POST /api/auth/register     — Register new user
POST /api/auth/login        — Login
POST /api/auth/logout       — Logout
GET  /api/auth/me           — Current session info

## Listings
GET  /api/listings              — Search (keyword, category_id, min/max price, condition, sort)
GET  /api/listings/<id>         — Single listing detail
POST /api/listings              — Create listing (auth required)
DELETE /api/listings/<id>       — Remove listing (auth + owner required)
POST /api/listings/<id>/buy     — Purchase listing (calls sp_purchase_listing)
GET  /api/my/listings           — My listings (auth required)

## Categories
GET /api/categories             — Root categories (or by ?parent_id=N)
GET /api/categories/tree        — Full nested tree
GET /api/categories/<id>/path   — Breadcrumb path string

## Alerts
GET    /api/alerts              — My active alerts
POST   /api/alerts              — Create/update alert (calls sp_upsert_alert)
DELETE /api/alerts/<id>         — Deactivate alert

## Notifications
GET  /api/notifications             — My notifications (DB-trigger generated)
GET  /api/notifications/unread-count
POST /api/notifications/mark-read   — Mark one or all as read

## Messages
GET  /api/messages/<listing_id>  — Messages for a listing
POST /api/messages               — Send a message

---

### Troubleshooting

Access denied for user 'root'@'localhost'
→ Wrong MySQL password in DB_CONFIG. Double-check and update app.py.

Unknown database 'marketspace'
→ Run 01_schema.sql first — it creates the database.

Frontend loads but API calls fail (CORS / 404)
→ Make sure you're accessing via http://localhost:5000 (not file://).
→ The Flask server must be running (python app.py).

ModuleNotFoundError: No module named 'flask'
→ Run pip install -r requirements.txt inside your virtual environment.

Triggers not firing
→ Verify 02_triggers.sql was executed: SHOW TRIGGERS FROM marketspace;

### Technologies Used

| Layer | Technology |
| Database | MySQL 8.0 + PL/SQL (Stored Procedures, Triggers, Views) |
| Backend API | Python 3 + Flask + mysql-connector-python + bcrypt |
| Frontend GUI | Vanilla HTML5 / CSS3 / JavaScript (Single Page Application)
| Fonts | Google Fonts (Syne + DM Sans) |