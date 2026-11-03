# Ocean Idle: Roblox idle/clicker foundation

A server-authoritative, strictly typed (`--!strict`) Luau foundation for a 3D underwater idle/clicker game.
It targets ages 9–12 and runs on mobile. Players walk around a physical arena and use stations to earn
**Pearls**. They buy generators and Investors, evolve through 8 prestige levels, and eventually climb the
Heavenly Stairway to raise colossal Statues.

## File structure

```
default.project.json         Rojo project (Shared → ReplicatedStorage, Server → ServerScriptService, Client → StarterPlayerScripts)
rokit.toml                   Toolchain pin (rojo 7.7.1)
.luaurc                      languageMode = strict
src/
  shared/                    ReplicatedStorage.Shared
    BigNumber.luau           Hybrid number: plain double < 1e15, mantissa/exponent ≥ 1e15
    NumberFormat.luau        Truncating formatter: 1, 999, 1.5K … 1.5UQq / "1.5 Unquinquagintillion" / 1.23e400
    EconomyMath.luau         Pure formulas (costs, income, offline, evolution, statues), server + sim only
    Types.luau               PlayerData, network payloads, season/UI types
    Net.luau                 Remote definitions (server creates, client waits)
    Signal.luau              Tiny typed signal for client controllers
    Config/
      Economy.luau           Generators, click upgrade, Investors, auto-clicker tiers, offline, limits
      Evolution.luau         8 levels (x42^(L-1)), requirements, perks
      Statues.luau           9 permanent statues (1e32 … 1e156) + stairway unlock
      Stations.luau          Arena layout, the single source of truth for every interactive station
      Monetization.luau      Gamepass / developer product ids (0 = disabled)
      Experiments.luau       A/B experiments + UI defaults
      Seasons/               init.luau registry + Default.luau + CoralCarnival.luau (example event)
  server/                    ServerScriptService.Server
    Main.server.luau         Bootstrap + player lifecycle + BindToClose
    Modules/Guard.luau       Token-bucket rate limiter with strikes
    Modules/DataSchema.luau  Field-by-field sanitizing load + strict pre-save validation
    Services/
      DataService.luau       Session-locked DataStore persistence, pcall + retries, Studio memory fallback
      EconomyService.luau    Currency authority: tick loop, purchases, evolution, statues, offline earnings
      NetService.luau        Single client entry point: validate → rate-limit → proximity → EconomyService
      ArenaService.luau      Builds the physical arena + server-side proximity check
      SeasonService.luau     Active season from server time, live switching
      ExperimentService.luau Deterministic A/B buckets + live UI overrides
      MonetizationService.luau Gamepass entitlements, idempotent ProcessReceipt
  client/                    StarterPlayer.StarterPlayerScripts.Client
    Main.client.luau         Bootstrap
    Controllers/
      StateController.luau   Receives Tick/Snapshot, extrapolates currency every frame
      StationController.luau Nearest-station detection (10 Hz), intent-only Action requests, E/ButtonX
      WorldController.luau   Per-player station labels, statue models, stairway barrier
    UI/
      Theme.luau             Oceanic palette, fonts, UI helpers
      HudController.luau     HUD: currency pill, rate (/s → /nanosecond), evolution, battery, prompts, toasts, perk picker
    Ocean/
      OceanSpawner.luau      Progression-driven environment: fish schools, corals, kelp, bubbles, light rays, LOD
      FishFactory.luau       Primitive-part fish, tropical fish, jellyfish, mantas, whales
tests/                       CLI unit tests (BigNumber, NumberFormat, EconomyMath, Guard)
tools/
  run_luau.py                Runs pure shared modules under the stock `luau` CLI
  sim.luau                   Pacing simulator (greedy player)
```

## Rojo integration

1. **Install the toolchain.** Install [Rokit](https://github.com/rojo-rbx/rokit) and run `rokit install` in the repo root.
   This installs Rojo 7.7.1. Then install the Rojo Studio plugin with `rojo plugin install`.
2. **Live sync.** Run `rojo serve` (default port 34872). In Roblox Studio, open a new **Baseplate** place,
   open the Rojo plugin, and click **Connect**. The `Shared`, `Server` and `Client` folders appear in their
   services. Delete the default `Baseplate` part so it doesn't overlap the sea floor (the arena builds itself at runtime).
3. **Or build a place file.** `rojo build default.project.json -o OceanIdle.rbxl`, then open it in Studio.
4. **DataStores.** Publish the place, then turn on *Game Settings → Security → Enable Studio Access to API Services*.
   Without it, `DataService` warns and keeps data in memory (nothing persists), which is fine for quick iteration.
5. **Monetization.** Create the gamepass ("Infinite Auto-Clicker") and developer product ("Battery Overcharge").
   Put their ids in `src/shared/Config/Monetization.luau`. The HUD buttons appear automatically once an id is non-zero.
6. **Press Play.** Walk to a Giant Pearl Clam and tap **TAP!** (or press **E**). Then use the pads around the ring.

Type-check locally with [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp):

```
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --definitions=globalTypes.d.luau --base-luaurc=.luaurc src
```

Run the unit tests and the pacing simulator (needs the `luau` CLI from [luau-lang/luau releases](https://github.com/luau-lang/luau/releases)):

```
python3 tools/run_luau.py tests/BigNumber.spec.luau tests/Economy.spec.luau
python3 tools/run_luau.py tools/sim.luau
```

## Architecture

```
Client                                   Server
──────                                   ──────
StationController ── Action(stationId, option) ──▶ NetService
  (only "I'm using this station")                    1. type/shape validation (malformed → strikes)
                                                     2. station exists (Config/Stations)
                                                     3. Guard rate limit per action kind
                                                     4. session loaded
                                                     5. character within station radius (server positions)
                                                     ▼
                                                   EconomyService (all math, all state)
StateController ◀── Tick {c, r, serverTime, charge} 1 Hz (UnreliableRemoteEvent, 6 numbers)
                ◀── Snapshot (on change: costs, locks, levels)
                ◀── Notify (toasts) / UiConfig (A/B)
HudController: display = currency + rate × (GetServerTimeNow() − serverTime), every frame
```

* **Zero client economy math.** The client only formats and compares the costs and values the server sent.
  `EconomyMath` is never required on the client.
* **Optimistic clicks.** A tap shows `+value` instantly. The next authoritative Tick replaces the prediction.
* **No server `Touched`.** Pads don't use touch events, which exploiters can spoof. Proximity is validated against
  `Config/Stations` positions with a small latency tolerance.

## Numbers: the BigNumber transition

`BigNumber` is always `{ m, e }`, with two canonical forms:

| Range | Storage | Precision |
|---|---|---|
| `< 1e15` | `m` = exact Luau double, `e = 0` | exact integers (doubles are exact to 2^53 ≈ 9e15) |
| `≥ 1e15` | `1 ≤ m < 10`, `e ≥ 15` | ~15 significant digits, unbounded exponent |

Every operation accepts both forms and returns the canonical one, so economy and UI code never branch on the form.
The formatter **truncates** (never rounds up): `1999 → "1.99K"`, `999,999,999,999,999 → "999T"`. Suffixes run
K, M, B, T, Qa, Qi … Dc, UDc … UQq (Unquinquagintillion) … Ce (Centillion). Scientific notation takes over from 1e306.
The HUD also spells the full name under the number ("Unquinquagintillion") and switches the rate to **/nanosecond**
once income passes 1T/s.

## Economy and pacing

| System | Rule |
|---|---|
| Click | 1 + level, x3 every 25 levels, x10 every 100 (Fin Forge, cost 10 × 1.17^L) |
| Generators (10) | 15 → 5e11 base cost, ×1.15 per level, same milestones; higher tiers need 1–90 Investors (the walls) |
| Investors | 1,000 × 1.14^n each, flat +1% passive income each; wiped on Evolve |
| Auto-clicker | 6 tiers, 2 → 20 clicks/s. Tiers 1–5 have a battery (600 → 216K clicks) you recharge at the Battery Dock. Tier 6 = **infinite**, costs 1e15, needs Evolution 3 |
| Evolution | Level L → x42^(L-1) on all income. Requirements 1e9, 1e15, 1e20, 1e25, 1e30, 1e44, 1e57. Wipes currency, Investors, generators and click levels. Keeps auto-clicker, statues and perks. Choose 1 of 5 stacking perks |
| Statues | Unlock at Evolution 5 + 1e30 held. 9 permanent multipliers (x1e5 … x1e30), costs 1e32 … 1e156 |
| Offline | 100% of passive income (plus the auto-clicker if infinite), from server `os.time()`, 8h cap (+4h per Deep Currents) |

`tools/sim.luau` output for the shipped config (greedy active player, ~2 manual clicks/s, active play time only):

```
Total earned 1K      0.9 min       Evolution 5 (x3.11M)     6.44 h
Total earned 1M      11.3 min      Evolution 6 (x130M)      27.5 h
Total earned 1B      1.24 h        Heavenly Stairway        28.5 h
Evolution 2 (x42)    1.24 h        Evolution 7 (x5.48B)     47.2 h
Evolution 3 (x1.76K) 1.63 h        Evolution 8 (x230B)      ~167 h
Evolution 4 (x74K)   2.77 h        Heart of the Ocean 1e156 ~457 h
```

Tune everything in `src/shared/Config/*`, then rerun the simulator. Compounding milestones make the late game
sensitive: moving one threshold by one power of ten can shift its milestone by tens of hours.

## Anti-cheat and data safety

* Intent-only remotes. Every argument is type-checked, every station id is whitelisted, and every option is a bounded integer.
* `Guard` token buckets: Click 15/s (burst 25), Purchase 8/s, Battery 1/s, Evolution 0.5/s. Over-limit requests are
  dropped. Only sustained extreme spam (150 strikes) kicks.
* Session-locked profiles (`UpdateAsync` with a lock that expires after 180 s), so two servers can never write the same profile.
* `DataSchema.validateSaved` runs before **every** write. Invalid data is never persisted. Loads repair bad fields
  one at a time and back up the raw record.
* All DataStore calls go through `pcall` with exponential backoff. `BindToClose` saves and releases everyone.
* `ProcessReceipt` is idempotent. The purchase id is saved in the same document as the grant.

## Seasons and events

Add `src/shared/Config/Seasons/MyEvent.luau` returning a `SeasonDefinition` (window, priority, economy modifiers, theme),
then list it in `Seasons/init.luau`. `SeasonService` picks the highest-priority active season every minute, recomputes
every player's rates, and clients re-theme the ocean. No core changes needed. To force one in Studio, set
`ReplicatedStorage:SetAttribute("SeasonOverride", "CoralCarnival")`.

## A/B testing and dynamic UI

`Config/Experiments.luau` defines experiments with weighted variants that override `UiConfig` fields: tap button
scale, accent colour, /ns display, compact HUD, prompt position. Bucketing is a deterministic hash of UserId and key,
so it's stable across servers. The assignment is exposed as the player attribute `Experiments` and logged through
`AnalyticsService`. For live changes without a deploy, write JSON to DataStore `OceanIdle_LiveConfig_v1`, key `ui`,
for example `{"accentColor":"#FF7896","tapButtonScale":1.2}`. Servers poll every 2 minutes, validate and clamp it, and
the HUD restyles instantly. `ExperimentService.setLiveOverrides(t)` does the same from server code.

## Mobile performance

* Ocean visuals are client-only. They don't replicate and they scale with the player's own progression.
* Creature budget comes from the graphics quality level, capped at 45 on touch devices.
* All schools move with a single `Workspace:BulkMoveTo` per frame. Distance bands act as LOD (near: every frame,
  mid: every 3rd, far: every 6th).
* Kelp sway and light shimmer are engine-side tweens. Every decorative part is anchored with collision, touch,
  query and shadows off. Shapes and materials are shared so the engine can instance them.
* Few, low-rate particle emitters. No Bloom or global shadows on mobile.
* The network carries a 6-number Tick per second on an unreliable channel. Snapshots go out only on change.
