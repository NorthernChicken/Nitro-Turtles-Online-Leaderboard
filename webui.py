import os
import requests
from flask import Flask, render_template, request
from time import time
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

def format_score(milliseconds):
    if milliseconds is None: return "N/A"
    seconds = milliseconds // 1000
    ms = milliseconds % 1000
    minutes = seconds // 60
    seconds = seconds % 60
    return f"{minutes:02}:{seconds:02}.{ms:03}"

def get_steam_profiles(steam_ids):
    if not steam_ids or not STEAM_API_KEY:
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

def check_rate_limit():
    """Check if client has exceeded rate limit"""
    client_ip = request.remote_addr
    now = time()
    
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
        return render_template('leaderboard.html',
                             entries=[],
                             current_course=request.args.get('course', 'beach'),
                             course_display_name='Rate Limited',
                             current_mode=request.args.get('mode', 'total'),
                             error='Too many requests. Please wait a moment before refreshing.')
    
    course = request.args.get('course', 'beach')
    # old ui: race
    mode = request.args.get('mode', 'total')
    if mode == 'race': mode = 'total' # old links

    display_name = COURSE_DISPLAY_NAMES.get(course, course.title())

    # volcano has no laps
    if course == 'volcano' and mode == 'lap':
        return render_template('leaderboard.html',
                             entries=[],
                             current_course=course,
                             course_display_name=display_name,
                             current_mode=mode,
                             error='The Volcano course does not have a lap leaderboard.',
                             courses=COURSE_DISPLAY_NAMES)

    target_url = f"{BASE_API_URL}/{course}/{mode}"

    entries = []
    error_msg = None
    api_loading = False

    try:
        lb_response = requests.get(target_url, timeout=10)
        if lb_response.status_code == 200:
            lb_data = lb_response.json()
            if lb_data.get('status') == 'loading':
                api_loading = True
                entries = []
            else:
                entries = lb_data.get('entries', [])
        else:
            error_msg = f"API Error ({lb_response.status_code}): {lb_response.text}"
    except Exception as e:
        error_msg = f"Connection Error: {e}"

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

    return render_template('leaderboard.html', 
                           entries=processed_entries, 
                           current_course=course,
                           course_display_name=display_name,
                           current_mode=mode,
                           error=error_msg,
                           api_loading=api_loading,
                           courses=COURSE_DISPLAY_NAMES)

@app.route('/api/leaderboard/<course>/<mode>')
def api_leaderboard(course, mode):
    target_url = f"{BASE_API_URL}/{course}/{mode}"
    try:
        response = requests.get(target_url, timeout=10)
        return response.json(), response.status_code
    except Exception as e:
        return {"error": str(e)}, 500

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5003)