-- Set the search path for LUA plugins and modules.
package.cpath = package.cpath .. ";lua_plugins/?.so"
package.path = package.path .. ";lua/?.lua;lua/?/init.lua"
