"""
MarketSpace - Flask Backend API
app.py
"""

from flask import Flask, request, jsonify, session
from flask_cors import CORS
import mysql.connector
from mysql.connector import Error
import bcrypt
import os
from datetime import datetime
from functools import wraps

app = Flask(__name__, static_folder='.', static_url_path='')
app.secret_key = os.environ.get('SECRET_KEY', 'marketspace-secret-key-change-in-prod')
CORS(app, supports_credentials=True, origins=["http://localhost:5000", "http://127.0.0.1:5000"])

# ──────────────────────────────────────────────
# DB CONFIG  (edit to match your MySQL setup)
# ──────────────────────────────────────────────
DB_CONFIG = {
    'host':     os.environ.get('DB_HOST',     'localhost'),
    'port':     int(os.environ.get('DB_PORT', 3306)),
    'user':     os.environ.get('DB_USER',     'root'),
    'password': os.environ.get('DB_PASSWORD', 'Aparna_05'),        # ← set your MySQL root password
    'database': 'marketspace',
    'charset':  'utf8mb4',
    'autocommit': False,
}


def get_db():
    """Return a fresh MySQL connection."""
    return mysql.connector.connect(**DB_CONFIG)


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user_id' not in session:
            return jsonify({'error': 'Authentication required'}), 401
        return f(*args, **kwargs)
    return decorated


# ══════════════════════════════════════════════
# AUTH ROUTES
# ══════════════════════════════════════════════

@app.route('/api/auth/register', methods=['POST'])
def register():
    data = request.get_json()
    required = ['username', 'email', 'password', 'full_name']
    if not all(k in data for k in required):
        return jsonify({'error': 'Missing required fields'}), 400

    pw_hash = bcrypt.hashpw(data['password'].encode(), bcrypt.gensalt()).decode()

    try:
        conn = get_db()
        cur = conn.cursor(dictionary=True)
        cur.execute(
            "INSERT INTO users (username, email, password_hash, full_name, phone, location) "
            "VALUES (%s, %s, %s, %s, %s, %s)",
            (data['username'], data['email'], pw_hash,
             data['full_name'], data.get('phone'), data.get('location'))
        )
        conn.commit()
        user_id = cur.lastrowid
        session['user_id']  = user_id
        session['username'] = data['username']
        return jsonify({'message': 'Registered successfully', 'user_id': user_id, 'username': data['username']}), 201
    except Error as e:
        if e.errno == 1062:
            return jsonify({'error': 'Username or email already exists'}), 409
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/auth/login', methods=['POST'])
def login():
    data = request.get_json()
    if not data.get('username') or not data.get('password'):
        return jsonify({'error': 'Username and password required'}), 400

    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM users WHERE username = %s AND is_active = 1", (data['username'],))
        user = cur.fetchone()
        if not user or not bcrypt.checkpw(data['password'].encode(), user['password_hash'].encode()):
            return jsonify({'error': 'Invalid credentials'}), 401

        session['user_id']  = user['user_id']
        session['username'] = user['username']
        return jsonify({
            'message':  'Login successful',
            'user_id':  user['user_id'],
            'username': user['username'],
            'full_name':user['full_name'],
            'location': user['location'],
        })
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/auth/logout', methods=['POST'])
def logout():
    session.clear()
    return jsonify({'message': 'Logged out'})


@app.route('/api/auth/me', methods=['GET'])
def me():
    if 'user_id' not in session:
        return jsonify({'logged_in': False})
    return jsonify({'logged_in': True, 'user_id': session['user_id'], 'username': session['username']})


# ══════════════════════════════════════════════
# CATEGORY ROUTES
# ══════════════════════════════════════════════

@app.route('/api/categories', methods=['GET'])
def get_categories():
    """Return full hierarchical category tree."""
    parent_id = request.args.get('parent_id')
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        if parent_id is None or parent_id == 'null':
            cur.callproc('sp_get_category_subtree', [None])
        else:
            cur.callproc('sp_get_category_subtree', [int(parent_id)])
        for result in cur.stored_results():
            rows = result.fetchall()
        return jsonify(rows)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/categories/tree', methods=['GET'])
def get_full_tree():
    """Return complete nested category tree in one shot."""
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM categories ORDER BY level, parent_id, name")
        rows = cur.fetchall()

        # Build nested dict
        node_map = {r['category_id']: dict(r, children=[]) for r in rows}
        roots = []
        for node in node_map.values():
            if node['parent_id'] is None:
                roots.append(node)
            else:
                parent = node_map.get(node['parent_id'])
                if parent:
                    parent['children'].append(node)
        return jsonify(roots)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/categories/<int:cat_id>/path', methods=['GET'])
def get_category_path(cat_id):
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.callproc('sp_get_category_path', [cat_id])
        for result in cur.stored_results():
            row = result.fetchone()
        return jsonify(row)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


# ══════════════════════════════════════════════
# LISTING ROUTES
# ══════════════════════════════════════════════

@app.route('/api/listings', methods=['GET'])
def get_listings():
    """Search listings with optional filters."""
    kw       = request.args.get('keyword')
    cat_id   = request.args.get('category_id')
    min_p    = request.args.get('min_price')
    max_p    = request.args.get('max_price')
    cond     = request.args.get('condition')
    sort     = request.args.get('sort', 'newest')

    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.callproc('sp_search_listings', [
            kw or None,
            int(cat_id) if cat_id else None,
            float(min_p) if min_p else None,
            float(max_p) if max_p else None,
            cond or None,
            sort,
        ])
        for result in cur.stored_results():
            rows = result.fetchall()
        # Convert decimals for JSON
        for r in rows:
            r['price'] = float(r['price'])
            if r.get('created_at'):
                r['created_at'] = r['created_at'].isoformat()
        return jsonify(rows)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/listings/<int:listing_id>', methods=['GET'])
def get_listing(listing_id):
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute("SELECT * FROM vw_listing_details WHERE listing_id = %s", (listing_id,))
        row = cur.fetchone()
        if not row:
            return jsonify({'error': 'Not found'}), 404
        row['price'] = float(row['price'])
        if row.get('created_at'):
            row['created_at'] = row['created_at'].isoformat()
        return jsonify(row)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/listings', methods=['POST'])
@login_required
def create_listing():
    data = request.get_json()
    required = ['title', 'price', 'category_id']
    if not all(k in data for k in required):
        return jsonify({'error': 'title, price, category_id required'}), 400

    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute(
            "INSERT INTO listings (seller_id, category_id, title, description, price, condition_type, image_url) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (session['user_id'], data['category_id'], data['title'],
             data.get('description'), float(data['price']),
             data.get('condition', 'Good'), data.get('image_url'))
        )
        conn.commit()
        lid = cur.lastrowid
        return jsonify({'message': 'Listing created', 'listing_id': lid}), 201
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/listings/<int:listing_id>', methods=['DELETE'])
@login_required
def delete_listing(listing_id):
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute("SELECT seller_id FROM listings WHERE listing_id = %s", (listing_id,))
        row = cur.fetchone()
        if not row:
            return jsonify({'error': 'Not found'}), 404
        if row['seller_id'] != session['user_id']:
            return jsonify({'error': 'Forbidden'}), 403
        cur.execute("UPDATE listings SET status='removed' WHERE listing_id=%s", (listing_id,))
        conn.commit()
        return jsonify({'message': 'Listing removed'})
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/listings/<int:listing_id>/buy', methods=['POST'])
@login_required
def buy_listing(listing_id):
    try:
        conn = get_db()
        cur  = conn.cursor()
        args = [listing_id, session['user_id'], '']
        
        # Capture the updated arguments
        result_args = cur.callproc('sp_purchase_listing', args)
        conn.commit()
        
        # result_args[2] is the 3rd argument (p_result)
        result_msg = result_args[2] if result_args[2] else 'ERROR: unknown'
        
        if result_msg.startswith('ERROR'):
            return jsonify({'error': result_msg}), 400
        return jsonify({'message': 'Purchase successful!'})
        
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/my/listings', methods=['GET'])
@login_required
def my_listings():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT l.*, c.name AS category_name FROM listings l "
            "JOIN categories c ON l.category_id = c.category_id "
            "WHERE l.seller_id = %s ORDER BY l.created_at DESC",
            (session['user_id'],)
        )
        rows = cur.fetchall()
        for r in rows:
            r['price'] = float(r['price'])
            if r.get('created_at'): r['created_at'] = r['created_at'].isoformat()
            if r.get('updated_at'): r['updated_at'] = r['updated_at'].isoformat()
        return jsonify(rows)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


# ══════════════════════════════════════════════
# ALERT ROUTES
# ══════════════════════════════════════════════

@app.route('/api/alerts', methods=['GET'])
@login_required
def get_alerts():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT a.*, c.name AS category_name FROM alerts a "
            "JOIN categories c ON a.category_id = c.category_id "
            "WHERE a.user_id = %s ORDER BY a.created_at DESC",
            (session['user_id'],)
        )
        rows = cur.fetchall()
        for r in rows:
            if r.get('max_price'): r['max_price'] = float(r['max_price'])
            if r.get('created_at'): r['created_at'] = r['created_at'].isoformat()
        return jsonify(rows)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/alerts', methods=['POST'])
@login_required
def create_alert():
    data = request.get_json()
    if not data.get('category_id'):
        return jsonify({'error': 'category_id required'}), 400

    try:
        conn = get_db()
        cur  = conn.cursor()
        args = [
            session['user_id'],
            data['category_id'],
            float(data['max_price']) if data.get('max_price') else None,
            data.get('keywords'),
            0, ''
        ]
        
        # Capture the modified arguments (which include the OUT parameters)
        result_args = cur.callproc('sp_upsert_alert', args)
        conn.commit()
        
        # result_args[4] is the alert_id, result_args[5] is the status
        return jsonify({
            'message': 'Alert saved', 
            'alert_id': result_args[4], 
            'status': result_args[5]
        }), 201
        
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/alerts/<int:alert_id>', methods=['DELETE'])
@login_required
def delete_alert(alert_id):
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.execute(
            "UPDATE alerts SET is_active=0 WHERE alert_id=%s AND user_id=%s",
            (alert_id, session['user_id'])
        )
        conn.commit()
        return jsonify({'message': 'Alert deactivated'})
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


# ══════════════════════════════════════════════
# NOTIFICATION ROUTES
# ══════════════════════════════════════════════

@app.route('/api/notifications', methods=['GET'])
@login_required
def get_notifications():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT n.*, l.title AS listing_title, l.price AS listing_price "
            "FROM alert_notifications n "
            "JOIN listings l ON n.listing_id = l.listing_id "
            "WHERE n.user_id = %s ORDER BY n.created_at DESC LIMIT 50",
            (session['user_id'],)
        )
        rows = cur.fetchall()
        for r in rows:
            if r.get('listing_price'): r['listing_price'] = float(r['listing_price'])
            if r.get('created_at'): r['created_at'] = r['created_at'].isoformat()
        return jsonify(rows)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/notifications/unread-count', methods=['GET'])
@login_required
def unread_count():
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT COUNT(*) AS count FROM alert_notifications "
            "WHERE user_id=%s AND is_read=0",
            (session['user_id'],)
        )
        row = cur.fetchone()
        return jsonify({'count': row['count']})
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/notifications/mark-read', methods=['POST'])
@login_required
def mark_notifications_read():
    data = request.get_json() or {}
    nid  = data.get('notification_id')
    try:
        conn = get_db()
        cur  = conn.cursor()
        if nid:
            cur.execute(
                "UPDATE alert_notifications SET is_read=1 WHERE notification_id=%s AND user_id=%s",
                (nid, session['user_id'])
            )
        else:
            cur.execute(
                "UPDATE alert_notifications SET is_read=1 WHERE user_id=%s",
                (session['user_id'],)
            )
        conn.commit()
        return jsonify({'message': 'Marked as read'})
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


# ══════════════════════════════════════════════
# MESSAGES ROUTES
# ══════════════════════════════════════════════

@app.route('/api/messages/<int:listing_id>', methods=['GET'])
@login_required
def get_messages(listing_id):
    try:
        conn = get_db()
        cur  = conn.cursor(dictionary=True)
        cur.execute(
            "SELECT m.*, u.username AS sender_username FROM messages m "
            "JOIN users u ON m.sender_id = u.user_id "
            "WHERE m.listing_id = %s "
            "AND (m.sender_id = %s OR m.receiver_id = %s) "
            "ORDER BY m.sent_at ASC",
            (listing_id, session['user_id'], session['user_id'])
        )
        rows = cur.fetchall()
        for r in rows:
            if r.get('sent_at'): r['sent_at'] = r['sent_at'].isoformat()
        return jsonify(rows)
    except Error as e:
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


@app.route('/api/messages', methods=['POST'])
@login_required
def send_message():
    data = request.get_json()
    if not all(k in data for k in ['listing_id', 'receiver_id', 'body']):
        return jsonify({'error': 'listing_id, receiver_id, body required'}), 400
    try:
        conn = get_db()
        cur  = conn.cursor()
        cur.execute(
            "INSERT INTO messages (listing_id, sender_id, receiver_id, body) VALUES (%s,%s,%s,%s)",
            (data['listing_id'], session['user_id'], data['receiver_id'], data['body'])
        )
        conn.commit()
        return jsonify({'message': 'Message sent'}), 201
    except Error as e:
        conn.rollback()
        return jsonify({'error': str(e)}), 500
    finally:
        cur.close(); conn.close()


# ══════════════════════════════════════════════
# SERVE FRONTEND
# ══════════════════════════════════════════════

@app.route('/')
def index():
    return app.send_static_file('index.html')


if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
