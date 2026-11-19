# Service connection

Language for the app's relationship with its background agent.

## Language

**Service connection**: the app-owned relationship with the background agent,
including synchronization, repair, and suspension.

**Connection epoch**: the service connection's locally owned freshness identity,
replaced on invalidation and distinct from the agent's revision.

# Backend playback

Language for the backend's audio playback engine and coordinator boundary.

## Language

**Playback controller**: the concrete stateful backend playback engine that
owns audio scheduling, buffering policy, time-stretching, fades, and remote
media integration without owning transcript text or timing alignment.

**Playback output port**: the ordered `Output` callback stream emitting state
changes, playback failures, and external control notifications from the playback
controller to the backend coordinator.
