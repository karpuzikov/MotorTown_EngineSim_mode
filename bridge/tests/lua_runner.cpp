// Tiny test-only runner against the system Lua 5.4 shared library; no SDK.
#include <cstdio>
#include <cstddef>

extern "C" {
struct lua_State;
lua_State* luaL_newstate();
void luaL_openlibs(lua_State*);
int luaL_loadfilex(lua_State*, const char*, const char*);
int lua_pcallk(lua_State*, int, int, int, long, void*);
const char* lua_tolstring(lua_State*, int, std::size_t*);
void lua_close(lua_State*);
}

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    auto* state = luaL_newstate();
    if (!state) return 3;
    luaL_openlibs(state);
    const int loaded = luaL_loadfilex(state, argv[1], nullptr);
    const int ran = loaded == 0 ? lua_pcallk(state, 0, 0, 0, 0, nullptr) : loaded;
    if (ran != 0) {
        std::fprintf(stderr, "%s\n", lua_tolstring(state, -1, nullptr));
    }
    lua_close(state);
    return ran == 0 ? 0 : 1;
}
