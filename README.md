# Nitro Turtles Online Leaderboard

A webui for displaying leaderboard data from [Nitro Turtles](https://store.steampowered.com/app/3952070/Nitro_Turtles/)

## How
The game provides no API access, so I am using the Godotsteam SDK to request leaderboard data, pretending to be a normal game client.

There are two parts, the API server and the webapp

- The API server is written in GDScript in Godot and creates a local http server to act as an api endpoint for the webui.
- The webui queries the API server and displays the data to clients.

Steam must be running in the background since Steamworks must verify you own the game
