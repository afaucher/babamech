# GodotSteam 4.17.1 (GDExtension)

Copied from `../cast/addons/godotsteam` (which got it from bridge-to-friendship). The DLLs in `win64/` are
gitignored: copy them from cast on a fresh checkout. The game reaches Steam only by string name
(`Engine.get_singleton("Steam")`, `ClassDB.instantiate("SteamMultiplayerPeer")`) from `scripts/net/`, so the
project parses and runs (solo / ENet) without them.
