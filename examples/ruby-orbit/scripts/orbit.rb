# orbit.rb — the plain top-level-hooks tier (init/update/deinit) of the
# Ruby Script Runtime Contract, as a minimal readable showcase. Every
# observable milestone logs one `RUBY_<TOKEN>` line so CI can
# `grep -oE 'RUBY_[A-Z0-9_.]+'` and diff the exact ordered sequence — the
# same transcript-assertion pattern the Lua scripting-smoke uses.
#
# Timeline (LABELLE_NULL_FRAMES=5; per frame the plugin Controller runs
# the event inbox, then each script's `update`):
#
#   setup   RUBY_INIT               init(): entity created, Position{0,0}
#                                    written, engine__tick subscribed
#   tick 1  RUBY_MOVED_X_10.0       update(): Position.x += 10, written back
#   tick 2  RUBY_MOVED_X_20.0       tick 1's write PERSISTED, +10 again
#   tick 3  RUBY_ENGINE_TICK_SEEN   first engine__tick reaches the handler
#                                    (subscriptions activate at a drain
#                                    boundary, so it lands one tick late)
#           RUBY_MOVED_X_30.0
#   tick 4  RUBY_MOVED_X_40.0
#   tick 5  RUBY_MOVED_X_50.0
#   deinit  RUBY_DONE
#
# Each X is only reachable through the PREVIOUS tick's persisted write, so
# the sequence pins ECS round-tripping through the real engine, not just
# liveness. Every value (0.0 start, +10.0 steps) is exact in binary
# floating point, so the decimals are deterministic.

def init
  @seen_engine = false

  # The contract creates the entity host-side and hands back its id.
  @mover = Labelle::Entity.create
  @mover.set("Position", x: 0.0, y: 0.0)

  # Builtin-event consumption: an ENGINE event that fires every frame in
  # any game, proving the engine's own bus reaches ruby handlers through
  # the tap. Logged once; the token stays value-stable across frames.
  Labelle.on("engine__tick") do |_ev|
    unless @seen_engine
      @seen_engine = true
      Labelle.log("RUBY_ENGINE_TICK_SEEN")
    end
  end

  Labelle.log("RUBY_INIT")
end

def update(_dt)
  # Read Position back from the ECS (symbol-keyed Hash), advance x, write
  # it back. The token carries the freshly PERSISTED value.
  pos = @mover.get("Position")
  nx = pos[:x] + 10.0
  @mover.set("Position", x: nx, y: pos[:y])
  Labelle.log("RUBY_MOVED_X_#{nx}")
end

def deinit
  Labelle.log("RUBY_DONE")
end
