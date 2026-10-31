// Native callback-stack boundary from UE4SS f885e8d2 (MIT):
// UE4SS/src/LuaType/LuaUStruct.cpp and
// deps/first/LuaMadeSimple/src/LuaMadeSimple.cpp, Lua::get_bool.
// Unreal metadata is supplied by the Lua harness; Lua stack operations are real.
#include <cstddef>
#include <cstdint>
#include <iostream>

extern "C" {
struct lua_State;
using lua_Integer = long long;
using lua_KContext = intptr_t;
using lua_CFunction = int (*)(lua_State *);
using lua_KFunction = int (*)(lua_State *, int, lua_KContext);
lua_State *luaL_newstate();
void luaL_openlibs(lua_State *);
void lua_close(lua_State *);
int luaL_loadfilex(lua_State *, const char *, const char *);
int lua_pcallk(lua_State *, int, int, int, lua_KContext, lua_KFunction);
void lua_pushcclosure(lua_State *, lua_CFunction, int);
void lua_setglobal(lua_State *, const char *);
const char *lua_pushstring(lua_State *, const char *);
void lua_createtable(lua_State *, int, int);
void lua_rawseti(lua_State *, int, lua_Integer);
int lua_rawgeti(lua_State *, int, lua_Integer);
size_t lua_rawlen(lua_State *, int);
int luaL_ref(lua_State *, int);
void luaL_unref(lua_State *, int, int);
void lua_pushvalue(lua_State *, int);
void lua_rotate(lua_State *, int, int);
void lua_settop(lua_State *, int);
int lua_type(lua_State *, int);
int lua_toboolean(lua_State *, int);
const char *lua_tolstring(lua_State *, int, size_t *);
int lua_error(lua_State *);
}

constexpr int Registry = -1001000;
constexpr int Boolean = 1;
void removeValue(lua_State *state, int index) {
    lua_rotate(state, index, -1);
    lua_settop(state, -2);
}
bool getBool(lua_State *state, int index) {
    const bool value = lua_toboolean(state, index);
    removeValue(state, index); // LuaMadeSimple getters consume their argument.
    return value;
}

int forEach(lua_State *state) {
    // Move the stand-in metadata array out of the callback stack. The real
    // UStruct binding removes its userdata and leaves the callback at index1.
    const auto count = lua_rawlen(state, 2);
    const int items = luaL_ref(state, Registry);
    for (size_t i = 1; i <= count; ++i) {
        lua_pushvalue(state, 1);
        lua_rawgeti(state, Registry, items);
        lua_rawgeti(state, -1, static_cast<lua_Integer>(i));
        removeValue(state, -2);
        if (lua_pcallk(state, 1, 1, 0, 0, nullptr) != 0) {
            luaL_unref(state, Registry, items);
            return lua_error(state);
        }
        // Exact return handling in the user's ForEachProperty/ForEachFunction.
        if (lua_type(state, 2) == Boolean && getBool(state, 2)) {
            break;
        }
        else {
            removeValue(state, 2);
        }
    }
    luaL_unref(state, Registry, items);
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    lua_State *state = luaL_newstate();
    luaL_openlibs(state);
    lua_pushcclosure(state, forEach, 0);
    lua_setglobal(state, "UE4SS_ForEach");
    lua_createtable(state, 3, 0);
    for (int i = 1; i < argc; ++i) {
        lua_pushstring(state, argv[i]);
        lua_rawseti(state, -2, i - 1);
    }
    lua_setglobal(state, "arg");
    int status = luaL_loadfilex(state, argv[1], nullptr);
    if (status == 0) status = lua_pcallk(state, 0, 0, 0, 0, nullptr);
    if (status != 0) std::cerr << lua_tolstring(state, -1, nullptr) << std::endl;
    lua_close(state);
    return status == 0 ? 0 : 1;
}
