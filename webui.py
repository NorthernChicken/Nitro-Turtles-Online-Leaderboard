import os
import requests
from flask import Flask, render_template, request
from time import time
from collections import defaultdict

app = Flask(__name__)

# config
request_times = defaultdict(list)
RATE_LIMIT_WINDOW = 10
MAX_REQUESTS_PER_WINDOW = 10
BASE_API_URL = os.getenv('BASE_API_URL', 'http://127.0.0.1:8000/leaderboard')
STEAM_API_KEY = os.getenv('STEAM_API_KEY', 'api')

COURSE_DISPLAY_NAMES = {
    'beach': 'Nitro Turtles Circuit',
    'reef': 'Rainbow Reef'
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
    # Rate limiting check
    if not check_rate_limit():
        return render_template('leaderboard.html',
                             entries=[],
                             current_course=request.args.get('course', 'beach'),
                             course_display_name='Rate Limited',
                             current_mode=request.args.get('mode', 'race'),
                             error='Too many requests. Please wait a moment before refreshing.')
    
    course = request.args.get('course', 'beach')
    mode = request.args.get('mode', 'race')

    # display name is different from api name
    display_name = COURSE_DISPLAY_NAMES.get(course, course.title())

    endpoint_suffix = course + ("lap" if mode == 'lap' else "")
    target_url = f"{BASE_API_URL}/{endpoint_suffix}"

    entries = []
    error_msg = None

    try:
        lb_response = requests.get(target_url, timeout=10)
        if lb_response.status_code == 200:
            lb_data = lb_response.json()
            entries = lb_data.get('entries', [])
        else:
            error_msg = f"API Error: {lb_response.status_code}"
    except Exception as e:
        error_msg = f"Connection Error: {e}"

    steam_ids = [str(e['steam_id']) for e in entries if e.get('steam_id')]
    steam_profiles = get_steam_profiles(steam_ids)

    processed_entries = []
    for entry in entries:
        sid = str(entry.get('steam_id'))
        profile = steam_profiles.get(sid, {})
        processed_entries.append({
            'rank': entry.get('rank'),
            'score_formatted': format_score(entry.get('score', 0)),
            'username': profile.get('personaname', entry.get('name', 'Unknown')),
            'avatar': profile.get('avatar', ''), 
            'profile_url': profile.get('profileurl', '#')
        })

    return render_template('leaderboard.html', 
                           entries=processed_entries, 
                           current_course=course,
                           course_display_name=display_name,
                           current_mode=mode,
                           error=error_msg)

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5003)