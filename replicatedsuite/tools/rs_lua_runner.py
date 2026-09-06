# Shared Lua runner resolution for the Real-Lua harnesses.
#
# The harnesses were originally written against texlua. Any Lua 5.x
# interpreter that can execute a script file works for these pure-simulation
# tests (the mocked ReplicatedSuite environment is engine-agnostic). The game
# runtime itself is Lua 5.1; harnesses that depend on 5.1-only behavior must
# set up their own compat shims (e.g. _G.unpack = table.unpack).
#
# Resolution order: $RS_LUA_RUNNER override, then texlua, then lua5.x, then
# lua. Falls back to the literal name "texlua" so the historical
# FileNotFoundError surfaces unchanged when nothing is installed.

import os
import shutil

_CANDIDATES = ["texlua", "lua5.4", "lua5.3", "lua5.2", "lua5.1", "lua"]


def find_runner():
    override = os.environ.get("RS_LUA_RUNNER")
    if override:
        return override
    for name in _CANDIDATES:
        found = shutil.which(name)
        if found:
            return found
    return "texlua"


RUNNER = find_runner()
