# CJS Mod Diagnostics

Bounded runtime diagnostics for supported Project Zomboid mods. Adapters observe
high-risk boundaries and report compact context to the normal Project Zomboid log
without changing the wrapped mod's behavior.

## Supported adapters

- Wandering Zombies WIP path requests

The Wandering Zombies adapter records startup configuration, the active native or
Java pathfinding backend, sampled normal path requests, throttled warnings for
suspicious requests, and a five-second heartbeat.
Warnings include unloaded target candidates, forced pathfinding, long paths,
bursts, and paths near the physics-overflow coordinates seen in the affected save.

Diagnostics are written to the normal Project Zomboid console log. The adapter does
not cancel requests, alter sandbox settings, retain game objects, or catch errors
from the wrapped mod.
