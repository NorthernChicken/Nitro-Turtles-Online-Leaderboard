extends Node





signal cloud_file_updated(path: String)
signal cloud_file_deleted(path: String)
signal overlay_toggled(active: bool)

var is_owned: bool = false
var steam_app_id: int = 3952070
var steam_id: int = 0
var steam_username: String = ""
var cloud_enabled: bool = false

var lobby_id = 0
var lobby_max_members = 12


var _avatar_cache: Dictionary = {}
var _avatar_pending: Dictionary = {}
var _avatar_queue: Array[int] = []
var _avatar_in_flight: bool = false

func _init() -> void :
    OS.set_environment("SteamAppId", str(steam_app_id))
    OS.set_environment("SteamGameId", str(steam_app_id))


func _ready():
    initialize_steam()
    initialize_steam_cloud()


func _process(_delta: float) -> void :
    Steam.run_callbacks()


func initialize_steam():
    var initialize_response: Dictionary = Steam.steamInitEx()

    if initialize_response["status"] > 0:
        print("Failed to init Steam! Shutting down. %s" % initialize_response)
        get_tree().quit()

    is_owned = Steam.isSubscribed()
    steam_id = Steam.getSteamID()
    steam_username = Steam.getPersonaName()

    Steam.overlay_toggled.connect(_on_steam_overlay_toggled)
    Steam.avatar_loaded.connect(_on_avatar_loaded)

    print("Steam ID: %s" % steam_id)
    print("Steam Username: %s" % steam_username)

    if not is_owned:
        print("User does not own game!")
        get_tree().quit()


func initialize_steam_cloud() -> void :
    var account_enabled: bool = Steam.isCloudEnabledForAccount()
    var app_enabled: bool = Steam.isCloudEnabledForApp()

    if account_enabled and app_enabled:
        cloud_enabled = true
        Steam.local_file_changed.connect(_on_steam_local_file_changed)


func is_cloud_enabled() -> bool:
    return cloud_enabled


func begin_file_write_batch() -> void :
    Steam.beginFileWriteBatch()


func end_file_write_batch() -> void :
    Steam.endFileWriteBatch()


func _on_steam_overlay_toggled(active: bool, _user_initiated: bool, _app_id: int) -> void :
    overlay_toggled.emit(active)


func _on_steam_local_file_changed() -> void :
    for i in Steam.getLocalFileChangeCount():
        var result: Dictionary = Steam.getLocalFileChange(i)
        if result["path_type"] != Steam.FILE_PATH_TYPE_ABSOLUTE:
            continue
        if result["change_type"] == Steam.LOCAL_FILE_CHANGE_FILE_UPDATED:
            cloud_file_updated.emit(result["file"])
        elif result["change_type"] == Steam.LOCAL_FILE_CHANGE_FILE_DELETED:
            cloud_file_deleted.emit(result["file"])


func request_avatar(avatar_steam_id: int, callback: Callable) -> void :

    if _avatar_cache.has(avatar_steam_id):
        callback.call(_avatar_cache[avatar_steam_id])
        return

    if not _avatar_pending.has(avatar_steam_id):
        _avatar_pending[avatar_steam_id] = []
        _avatar_queue.append(avatar_steam_id)
    _avatar_pending[avatar_steam_id].append(callback)
    _flush_avatar_queue()


func _flush_avatar_queue() -> void :
    if _avatar_in_flight or _avatar_queue.is_empty():
        return
    _avatar_in_flight = true
    Steam.getPlayerAvatar(Steam.AVATAR_MEDIUM, _avatar_queue[0])


func _on_avatar_loaded(avatar_id: int, avatar_size: int, data: PackedByteArray) -> void :
    _avatar_in_flight = false

    if not _avatar_queue.is_empty() and _avatar_queue[0] == avatar_id:
        _avatar_queue.pop_front()

    var image: = Image.create_from_data(avatar_size, avatar_size, false, Image.FORMAT_RGBA8, data)
    var texture: = ImageTexture.create_from_image(image)
    _avatar_cache[avatar_id] = texture

    if _avatar_pending.has(avatar_id):
        for cb in _avatar_pending[avatar_id]:
            cb.call(texture)
        _avatar_pending.erase(avatar_id)

    _flush_avatar_queue()


func clear_avatar_cache() -> void :
    _avatar_cache.clear()
    _avatar_pending.clear()
    _avatar_queue.clear()
    _avatar_in_flight = false


func achieve(achievement_name: String):
    print(achievement_name)
    var status = Steam.getAchievement(achievement_name)
    if status["achieved"]:
        return
    Steam.setAchievement(achievement_name)
    Steam.storeStats()


func unachieve(achievement_name: String):
    Steam.clearAchievement(achievement_name)
    Steam.storeStats()


func increment_stat(stat_name: String):
    var current: int = Steam.getStatInt(stat_name)
    Steam.setStatInt(stat_name, current + 1)
    Steam.storeStats()


func clear_all_achievements() -> void :
    for achievement in [
        "WIN", "NO_WATER", "NO_DASH_PADS", "COMEBACK", "ALL_WINS", 
        "FIRST_PLACE", "MARATHON", "ONE_GADGET", "ALL_GADGETS", 
        "RACE_TOUR", "AROUND_WORLD", "ALL_RACES", 
        "SPEEDRUN", "SPEEDRUN_GHOST", "SPEEDRUN_IMPROVEMENT", "CONSISTENCY", "SPEEDRUN_TOUR", 
        "BEACH_MASTER", "REEF_MASTER", "TIDE_MASTER", "RUINS_MASTER", "CLIFFS_MASTER", 
        "PITS_MASTER", "BAY_MASTER", "CRATERS_MASTER", "VOLCANO_MASTER", 
        "URCHIN", "SEAGULL", "SEAWEED", "ROCKET", "BUBBLE", "PROPELLER", 
    ]:
        Steam.clearAchievement(achievement)
    Steam.storeStats()
