package engine

import "base:runtime"

// map_erase removes one entry from a map. The standard library in this Odin
// release no longer ships a `delete(map, key)` builtin, so every removal goes
// through the runtime's erase primitive.
map_erase :: proc(m: ^map[$K]$V, key: K) -> bool {
	k := key
	_, _, ok := runtime.map_erase_static(m, &k)
	return ok
}
