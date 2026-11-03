# Ocean Idle: Roblox "Business Empire" idle game

A server-authoritative, strictly typed (`--!strict`) Luau foundation for a 3D underwater idle game.
It targets ages 9–12 and runs on mobile. Players walk around a physical arena and step on floor pads to unlock
income **stands**, buy **Multiplier** and **Speed** upgrades, hire **managers** for automation, and trigger
**global buffs**. They then **Evolve** for permanent x42 multipliers and finally raise **Statues** on the Heavenly Stairway.

![Arena layout](docs/arena-layout.png)

## File structure

```
default.project.json         Rojo project (Shared → ReplicatedStorage, Server → ServerScriptService, Client → StarterPlayerScripts)
rokit.toml                   Toolchain pin (rojo 7.7.1)
.luaurc                      languageMode = strict
src/
  shared/                    ReplicatedStorage.Shared
    BigNumber.luau           Hybrid number: plain double < 1e15, mantissa/exponent ≥ 1e15
    NumberFormat.luau        Truncating formatter (1.5K … 1.5UQq / "1.5 Unquinquagintillion") + parse("10B")
    EconomyMath.luau         Pure formulas: stand value/interval/rate, costs, buffs, offline, evolution, statues
    Types.luau               PlayerData (stands + buffs dictionaries), network payloads, season/UI types
    Net.luau                 Remote definitions (server creates, client waits)
    Signal.luau              Tiny typed signal for client controllers
    Config/
      Economy.luau           The 5 stands, upgrade cost curves, managers, the 4 global buffs, offline, Time Warp
      Evolution.luau         8 levels (x42^(L-1)), requirements, the 5 perks (chosen on physical perk pads)
      Statues.luau           10 permanent statues (stand-specific, Offline and All multipliers)
      Stations.luau          Arena layout: the single source of truth for every pad, plot and decor bed
      Monetization.luau      Gamepass / developer product ids (0 = disabled)
      Experiments.luau       A/B experiments + UI defaults
      Seasons/               init.luau registry + Default.luau + CoralCarnival.luau (example event)
  server/                    ServerScriptService.Server
    Main.server.luau         Bootstrap + player lifecycle + BindToClose
    Modules/Guard.luau       Token-bucket rate limiter with strikes
    Modules/DataSchema.luau  Field-by-field sanitizing load, v1 → v2 migration, strict pre-save validation
    Services/
      DataService.luau       Session-locked DataStore persistence, pcall + retries, Studio memory fallback
      EconomyService.luau    Currency authority: stands, manual cycles, managers, buffs, evolution, statues, ticks
      NetService.luau        Single client entry point: validate → rate-limit → proximity → EconomyService
      ArenaService.luau      Builds plaza, stand plots + props, pads, temple, stairway; server proximity check
      SeasonService.luau     Active season from server time, live switching
      ExperimentService.luau Deterministic A/B buckets + live UI overrides
      MonetizationService.luau Gamepass entitlements, idempotent ProcessReceipt
      DevService.luau        /give chat command for testing (Studio, owner, allowlist)
  client/                    StarterPlayer.StarterPlayerScripts.Client
    Main.client.luau         Bootstrap
    Controllers/
      StateController.luau   Receives Tick/Snapshot/Cycle, extrapolates currency every frame
      StationController.luau Step-on detection, [E] interaction, hold-to-run stands, hold-to-evolve
      WorldController.luau   Pad info rows, ghosted locked stands, manager NPC animation, cycle bars, statues
    UI/
      Theme.luau             Oceanic palette, fonts, UI helpers
      HudController.luau     Info-only HUD: currency, income, evolution, stands/buff status, context prompt, toasts
    Ocean/
      OceanSpawner.luau      Progression-driven environment: fish, corals, kelp, bubbles, light rays, LOD
      FishFactory.luau       Primitive-part fish, tropical fish, jellyfish, mantas, whales
docs/arena-layout.png        Top-down map rendered from Config/Stations.luau
tests/                       CLI unit tests (BigNumber, NumberFormat, EconomyMath, Guard)
tools/
  run_luau.py                Runs pure shared modules under the stock `luau` CLI
  sim.luau                   Pacing simulator (greedy player)
```

## Rojo integration

1. **Install the toolchain.** Install [Rokit](https://github.com/rojo-rbx/rokit) and run `rokit install` in the repo root.
   This installs Rojo 7.7.1. Then install the Rojo Studio plugin with `rojo plugin install`.
2. **Live sync.** Run `rojo serve` (default port 34872). In Roblox Studio, open a new **Baseplate** place,
   open the Rojo plugin, and click **Connect**. The arena builds itself at runtime and removes the template
   `Baseplate` and `SpawnLocation` (they z-fight with the arena floor).
3. **Or build a place file.** `rojo build default.project.json -o OceanIdle.rbxl`, then open it in Studio.
4. **DataStores.** Publish the place, then turn on *Game Settings → Security → Enable Studio Access to API Services*.
   Without it, `DataService` warns and keeps data in memory (nothing persists), which is fine for quick iteration.
5. **Monetization.** Create the "Double Income" gamepass and the "Time Warp" developer product. Put their ids in
   `src/shared/Config/Monetization.luau`. Prompt purchases from the Roblox menu or your own shop (the HUD has no buy buttons).
6. **Press Play.** Walk from the spawn to the Pearl Clam (north-east) and stand on its big pad to run it.
7. **Testing shortcut.** Type `/give 10B` in chat (also `1500`, `2.5T`, `1e30`, `1UQq`). It works in Studio, for the
   experience owner, and for user ids added to `ADMIN_USER_IDS` in `DevService.luau`.

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

## How to play (the physical loop)

Everything is bought by **stepping on a floor pad** (once per step) or pressing **[E]** nearby. The HUD only shows information.

| Pad | Where | What it does |
|---|---|---|
| Stand main pad | In front of each stand | Locked: pays the **deed** to unlock the stand. Owned: **stand on it** to run the stand by hand |
| Multiplier | Upgrade row, left | x2 value per cycle per level (x2, x4, x8 …) |
| Manager | Upgrade row, centre | Hires the stand's crab or mermaid. The stand then runs by itself, even offline |
| Speed | Upgrade row, right | Halves the cycle time per level (x2, x4 … x256) |
| Global buff | Plaza diagonals | x2 / x3 / x4 / x6 Global Cash for 30–45 s, then a cooldown |
| Evolve | Arc in front of the temple | Stand still 2 s on the perk you want to Evolve |
| Statue | Heavenly Stairway platform | Permanent colossal multipliers |

## Architecture

```
Client                                   Server
──────                                   ──────
StationController ── Action(stationId) ──▶ NetService
  (step-on / [E] / hold)                     1. type/shape validation (malformed → strikes)
                                             2. station exists (Config/Stations)
                                             3. Guard rate limit per action kind
                                             4. session loaded
                                             5. character within the pad's range (server positions)
                                             ▼
                                           EconomyService (all math, all state)
StateController ◀── Tick {c, r, serverTime, buff} 1 Hz (UnreliableRemoteEvent, 6 numbers)
                ◀── Snapshot (on change: stands, buffs, pad prices and locks)
                ◀── Cycle (hand-run cycle started) / Notify (toasts) / UiConfig (A/B)
HUD:   display = currency + rate × (GetServerTimeNow() − serverTime), every frame
World: per-player pad labels, ghosted locked stands, manager NPC work loop, cycle bars
```

* **Zero client economy math.** The client only formats and compares values the server sent.
* **Server state per player:** `stands[standId] = { level, multiplier, speed, managerHired }` (level 0 = locked, 1 = owned)
  and `buffs[buffId] = { unlocked, activeUntil, readyAt }` (server `os.time()`).
* **No server `Touched`.** Pads don't use touch events, which exploiters can spoof. Proximity is validated against
  `Config/Stations` positions with a small latency tolerance.

## Economy

| Stand | Deed | Base value / cycle | Base cycle | Manager |
|---|---:|---:|---:|---:|
| Pearl Clam | owned | 1 | 1 s | 300 |
| Coral Farm | 2.5K | 30 | 3 s | 30K |
| Kelp Factory | 150K | 1.5K | 6 s | 1.5M |
| Sunken Vault | 2M | 60K | 12 s | 15M |
| Kraken Den | 60M | 1.5M | 24 s | 400M |

* **Value of one cycle:** `baseValue × 2^multiplier × 42^(evo−1) × perks × statues × season × buff`.
  **Interval:** `baseInterval / 2^speed`. **Rate:** value / interval.
* **Upgrade costs** grow x4.5 per Multiplier level and x6 per Speed level (Speed caps at x256). Each level doubles
  income but costs 4.5x more, so payback grows 2.25x per level. Those are the walls: wait (managers), run stands by
  hand, or unlock the next stand.
* **Hand-run vs. managed:** without a manager a stand only works while you stand on its pad (cycles ≥ 0.25 s).
  Managed stands run continuously and are the only income offline.
* **Global buffs** (fixed pads, 4 total): Tidal Rush x2 (unlocks at 2 stands), Coral Bloom x3 (3), Pearl Storm x4 (4),
  Leviathan's Roar x6 (5). Only the strongest active buff applies (no stacking). The cooldown starts when the buff ends.
  Unlocks reset on Evolution.
* **Evolution:** x42^(L−1). Requirements (earned this run): 1e9, 1e17, 1e21, 1e25, 1e34, 1e40, 1e45. Resets currency,
  stands, upgrades, managers and buff unlocks. Keeps statues and perks. Perks: Golden Touch (x2 income),
  Busy Fins (x3 hand-run), Swift Currents (x1.5 speed), Long Tides (+50% buff time), Deep Currents (offline).
* **Statues** (Evolution 5 + 1e25 held): 5 stand statues x1e5, Tide Keeper (offline x1e6), and All x1e6 / x1e12 / x1e20 / x1e30.
  Costs run 1e26 → 1e118. The last one pushes income into the Unquinquagintillions.
* **Offline:** 100% of managed income from server `os.time()`, 8 h cap (+4 h per Deep Currents). Buffs don't apply offline.

`tools/sim.luau` output for the shipped config (greedy active player, active play time only):

```
Total earned 1K        4.6 min      Evolution 5 (x3.11M)   12.5 h
Total earned 1M       17.2 min      Heavenly Stairway      12.7 h
Total earned 1B       53.8 min      Evolution 8 (x230B)    46.2 h
Evolution 2 (x42)     53.8 min      Heart of the Ocean     ~60 h
```

Evolution requirements and statue costs were calibrated with the simulator. Tune `src/shared/Config/*`, then rerun it.
Income grows only polynomially within a run, so moving a threshold by one power of ten shifts its milestone noticeably.

## Anti-cheat and data safety

* Intent-only remotes: the only argument is a whitelisted station id. Extra arguments count as malformed.
* `Guard` token buckets: Run 10/s (burst 15), Purchase 8/s, Buff 2/s, Evolution 0.5/s. Over-limit requests are dropped.
  Only sustained extreme spam (150 strikes) kicks.
* Session-locked profiles (`UpdateAsync` with a lock that expires after 180 s), so two servers can never write the same profile.
* `DataSchema.validateSaved` runs before **every** write. Invalid data is never persisted. Loads repair bad fields one
  at a time and back up the raw record. Version 1 saves (old economy) start fresh, keeping all-time earnings and receipts.
* All DataStore calls go through `pcall` with exponential backoff. `BindToClose` saves and releases everyone.
* `ProcessReceipt` is idempotent. The purchase id is saved in the same document as the grant.

## Seasons and events

Add `src/shared/Config/Seasons/MyEvent.luau` returning a `SeasonDefinition` (window, priority, economy modifiers including
per-stand multipliers, theme), then list it in `Seasons/init.luau`. `SeasonService` picks the highest-priority active
season every minute, recomputes every player's rates, and clients re-theme the ocean. To force one in Studio, set
`ReplicatedStorage:SetAttribute("SeasonOverride", "CoralCarnival")`.

## A/B testing and dynamic UI

`Config/Experiments.luau` defines experiments with weighted variants that override `UiConfig` fields: accent colour,
/ns display, compact HUD, prompt position. Bucketing is a deterministic hash of UserId and key. The assignment is exposed
as the player attribute `Experiments` and logged through `AnalyticsService`. For live changes, write JSON to DataStore
`OceanIdle_LiveConfig_v1`, key `ui` (for example `{"accentColor":"#FF7896","promptPosition":"Center"}`).

## Rendering rules and mobile performance

* No two visible faces are coplanar. Each stacked layer has its own height above its surface (stones +0.3, plot base +0.3,
  pad lip +0.25, pad +0.45, inlay +0.55; sea floor 0.01, plaza 0.4). No glowing sheets at camera height.
* Ocean visuals and manager NPCs are client-only. All schools and NPCs move with `Workspace:BulkMoveTo`.
  Distance bands act as LOD.
* Creature budget comes from the graphics quality level, capped on touch devices. Few, low-rate particle emitters.
  No Bloom or global shadows on mobile.
* The network carries a 6-number Tick per second on an unreliable channel. Snapshots go out only on change.
