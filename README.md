# BSLegacy online lobby (version 0.23.1)

The Battle Spirits Saga Sim lobby -- Quick Match, Custom Room, spectating and
bug reports -- as a WebSocket server. Made by `tools/make_server_repo.py` in
the game project; **do not edit it here**, run the script again instead.

## Run it on Render (free)

1. Put this folder in a **private** GitHub repository (GitHub Desktop: File >
   Add local repository > Publish, tick "Keep this code private").
2. On render.com: New > **Blueprint** > connect GitHub > pick the
   repository > Apply. (Or New > Web Service > the repository > Language
   **Docker** > Instance type **Free**.)
3. Optional, for bug reports: in Discord, a channel's Settings >
   Integrations > Webhooks > New Webhook > Copy Webhook URL. On Render, the
   service > Environment > `BSL_DISCORD_WEBHOOK` = that address > Save.
4. Wait for "Live". The lobby's address is the service URL with `wss://`:
   `https://bslegacy-lobby.onrender.com` becomes
   `wss://bslegacy-lobby.onrender.com`.
5. In the game project: `python3 tools/make_web_project.py --lobby
   wss://bslegacy-lobby.onrender.com --feedback-url https://YOU.itch.io/GAME`,
   export, and upload the build to itch.io. For the desktop game, put the
   same address in `data/online_lobby.json` ("address").

The free service sleeps after 15 minutes with no players and takes about a
minute to wake; the game waits for it ("if it was asleep, this takes up to a
minute"). During a game it stays awake.

## After each game update

Run `python3 tools/make_server_repo.py` again, commit and push: Render
deploys it by itself. The lobby refuses players on another version.

## Test it on your computer

    godot --headless --path . -- --server --ws --port 8941

and in the game, Settings > Connection > Online lobby: `ws://127.0.0.1:8941`.
