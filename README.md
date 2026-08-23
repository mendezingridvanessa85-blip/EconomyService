# EconomyService

Server-authoritative Roblox economy prototype.

Prototype by Kj52058 / carlos837474

## Overview

`EconomyService.luau` is a server ModuleScript that manages player currency, generators, inventory, offline income, purchases, and prestige progression.

The module creates and owns these remotes inside `ReplicatedStorage.EconomyRemotes`:

- `Purchase`
- `GetState`
- `GetShop`
- `Prestige`

Clients can request actions, but they never provide prices, currency amounts, generator counts, inventory values, rolls, or prestige rewards.

## Persistence and session locking

Each player uses a key in the `EconomyProfiles_v1` DataStore.

Loading, saving, session heartbeats, and session release all use `UpdateAsync`. A load atomically writes a unique session token and an expiring lease. A second server that sees an active lease cancels its write and retries with bounded exponential backoff.

The active server refreshes its lease while the player is online. If a write is cancelled or fails after all retries, the profile is marked unavailable so later gameplay mutations are rejected.

## Income

There are three generator types:

- BasicGenerator: 1 currency per second
- SteelGenerator: 8 currency per second
- QuantumGenerator: 40 currency per second

Online income is calculated from server time and the generator counts stored in the profile.

Offline income is calculated from the server timestamp stored in `LastSeen`. The elapsed time is never negative and is capped at eight hours before being credited on rejoin.

## Shop

The server-side shop contains four items with independent prices:

- BasicGenerator: 50
- SteelGenerator: 300
- QuantumGenerator: 2,000
- ResearchToken: 1,000

The purchase method accepts only a server-known item ID. It checks the loaded profile balance, applies the configured item effect, saves with `UpdateAsync`, and rejects the mutation if persistence fails.

## Prestige

Prestige uses a server-calculated cost that starts at 100,000 and grows by 2.5x per prestige.

A successful prestige:

- Resets currency.
- Resets all generator counts.
- Preserves inventory.
- Increases the prestige count.
- Recalculates a permanent 1.25x stacking multiplier.

The prestige remote accepts no gameplay parameters.

## Setup

Place `EconomyService.luau` in `ServerScriptService` as a ModuleScript, then start it from a server Script:

```lua
local EconomyService = require(script.Parent.EconomyService)

EconomyService.new({
    DataStoreName = "EconomyProfiles_v1",
}):Start()
```

The experience must be published and have the required server API access enabled before DataStore testing.

## Client calls

Purchase an item:

```lua
local result = ReplicatedStorage.EconomyRemotes.Purchase:InvokeServer("BasicGenerator")
```

Read the current state:

```lua
local state = ReplicatedStorage.EconomyRemotes.GetState:InvokeServer()
```

Read the shop:

```lua
local shop = ReplicatedStorage.EconomyRemotes.GetShop:InvokeServer()
```

Prestige:

```lua
local result = ReplicatedStorage.EconomyRemotes.Prestige:InvokeServer()
```

The server ignores extra arguments for state, shop, and prestige requests.
