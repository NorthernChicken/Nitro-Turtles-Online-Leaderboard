import os
import requests
import sqlite3
import json
import threading
import time
from flask import Flask, render_template, request
from time import time as now_time
from collections import defaultdict

app = Flask(__name__)

# config
request_times = defaultdict(list)
RATE_LIMIT_WINDOW = 10
MAX_REQUESTS_PER_WINDOW = 20
BASE_API_URL = os.getenv('BASE_API_URL', 'http://127.0.0.1:8080/leaderboard')
STEAM_API_KEY = os.getenv('STEAM_API_KEY', 'key')

COURSE_DISPLAY_NAMES = {
    'beach': 'Nitro Turtles Circuit',
    'bay': 'Stormy Bay',
    'volcano': 'Scorched Shell Volcano',
    'pits': 'Turtle Tar Pits',
    'reef': 'Rainbow Reef',
    'tide': 'Tidebreaker Cove',
    'ruins': 'Ancient Turtle Ruins',
    'cliffs': 'Sandstone Spires',
    'craters': 'Cracked Shell Craters'
}

def init_db():
    if os.path.exists('cache.db'):
        os.remove('cache.db')
    conn = sqlite3.connect('cache.db')
    c = conn.cursor()
    c.execute('''CREATE TABLE IF NOT EXISTS leaderboard_cache 
                 (map TEXT, mode TEXT, data_json TEXT, last_updated REAL,
                  PRIMARY KEY (map, mode))''')
    conn.commit()
    conn.close()

init_db()

def format_score(milliseconds):
    if milliseconds is None: return "N/A"
    seconds = milliseconds // 1000
    ms = milliseconds % 1000
    minutes = seconds // 60
    seconds = seconds % 60
    return f"{minutes:02}:{seconds:02}.{ms:03}"

def get_steam_profiles(steam_ids):
    if not steam_ids or not STEAM_API_KEY or STEAM_API_KEY == 'key':
        return {}
    clean_ids = list(set([str(sid) for sid in steam_ids if sid]))
    if not clean_ids:
        return {}
    ids_str = ",".join(clean_ids[:100])
    url = f"http://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key={STEAM_API_KEY}&steamids={ids_str}"
    try:
        response = requests.get(url, timeout=5)
        data = response.json()
        players = data.get('response', {}).get('players', [])
        return {p['steamid']: p for p in players}
    except Exception as e:
        print(f"Error fetching Steam profiles: {e}")
        return {}

def fetch_and_cache_all():
    """Background task to refresh all leaderboards"""
    for course_id in COURSE_DISPLAY_NAMES:
        for mode in ['total', 'lap']:
            if course_id == 'volcano' and mode == 'lap': continue
            
            try:
                # 30s update
                conn = sqlite3.connect('cache.db')
                c = conn.cursor()
                c.execute("SELECT last_updated FROM leaderboard_cache WHERE map=? AND mode=?", (course_id, mode))
                row = c.fetchone()
                if row and now_time() - row[0] < 30:
                    conn.close()
                    continue
                
                target_url = f"{BASE_API_URL}/{course_id}/{mode}"
                lb_response = requests.get(target_url, timeout=10)
                if lb_response.status_code == 200:
                    lb_data = lb_response.json()
                    if lb_data.get('status') == 'loading':
                        conn.close()
                        continue
                    
                    entries = lb_data.get('entries', [])
                    steam_ids = [str(e['steam_id']) for e in entries if e.get('steam_id')]
                    steam_profiles = get_steam_profiles(steam_ids)
                    
                    processed_entries = []
                    for entry in entries:
                        sid = str(entry.get('steam_id'))
                        profile = steam_profiles.get(sid, {})
                        processed_entries.append({
                            'rank': entry.get('place'),
                            'score_formatted': format_score(entry.get('time', 0)),
                            'username': profile.get('personaname', entry.get('name', 'Unknown')),
                            'avatar': profile.get('avatar', ''), 
                            'profile_url': profile.get('profileurl', '#')
                        })
                    
                    c.execute("INSERT OR REPLACE INTO leaderboard_cache (map, mode, data_json, last_updated) VALUES (?, ?, ?, ?)",
                             (course_id, mode, json.dumps(processed_entries), now_time()))
                    conn.commit()
                conn.close()
            except Exception as e:
                print(f"Background update failed for {course_id}/{mode}: {e}")

def background_worker():
    time.sleep(5)
    while True:
        fetch_and_cache_all()
        time.sleep(10)

# bg daemon for updating cache
threading.Thread(target=background_worker, daemon=True).start()

def check_rate_limit():
    client_ip = request.remote_addr
    now = now_time()
    
    request_times[client_ip] = [
        req_time for req_time in request_times[client_ip]
        if now - req_time < RATE_LIMIT_WINDOW
    ]
    
    if len(request_times[client_ip]) >= MAX_REQUESTS_PER_WINDOW:
        return False
    
    request_times[client_ip].append(now)
    return True

@app.route('/')
def index():
    if not check_rate_limit():
        return render_template('leaderboard.html', entries=[], current_course='beach', 
                             course_display_name='Rate Limited', current_mode='total', 
                             error='Too many requests. Please wait a moment.', courses=COURSE_DISPLAY_NAMES)
    
    course = request.args.get('course', 'beach')
    mode = request.args.get('mode', 'total')
    if mode == 'race': mode = 'total'
    display_name = COURSE_DISPLAY_NAMES.get(course, course.title())

    if course == 'volcano' and mode == 'lap':
        return render_template('leaderboard.html', entries=[], current_course=course,
                             course_display_name=display_name, current_mode=mode,
                             error='The Volcano course does not have a lap leaderboard.', courses=COURSE_DISPLAY_NAMES)

    processed_entries = []
    try:
        conn = sqlite3.connect('cache.db')
        c = conn.cursor()
        c.execute("SELECT data_json FROM leaderboard_cache WHERE map=? AND mode=?", (course, mode))
        row = c.fetchone()
        conn.close()
        if row:
            processed_entries = json.loads(row[0])
    except Exception as e:
        print(f"Error reading cache: {e}")

    return render_template('leaderboard.html', 
                           entries=processed_entries, 
                           current_course=course,
                           course_display_name=display_name,
                           current_mode=mode,
                           api_loading=(len(processed_entries) == 0),
                           courses=COURSE_DISPLAY_NAMES)

@app.route('/api/leaderboard/<course>/<mode>')
def api_leaderboard(course, mode):
    try:
        conn = sqlite3.connect('cache.db')
        c = conn.cursor()
        c.execute("SELECT data_json FROM leaderboard_cache WHERE map=? AND mode=?", (course, mode))
        row = c.fetchone()
        conn.close()
        if row:
            return {"entries": json.loads(row[0])}, 200
        return {"entries": [], "status": "loading"}, 200
    except Exception as e:
        return {"error": str(e)}, 500

@app.after_request
def add_header(response):
    response.headers['Cache-Control'] = 'no-store, no-cache, must-revalidate, max-age=0'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    return response

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5003)