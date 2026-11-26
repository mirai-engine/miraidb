package engine

import "core:os"
import "core:strings"

// remove_tree removes `path` and everything under it; a path that does not
// exist is not an error. core:os's remove_all hands a directory that is not
// empty to the Windows shell (SHFileOperationW), which waits on Explorer: with
// Explorer busy, removing a store's three files took 60-90 s, and the unit
// tests, which remove a directory each, ran past the CI's 900 s. This walks the
// directory and removes each entry itself. A symbolic link is removed, not
// followed.
remove_tree :: proc(path: string) -> os.Error {
	if path == "" do return nil
	err := os.remove(path)
	if err == nil || err == .Not_Exist do return nil
	if !os.is_dir(path) do return err
	entries, read_err := os.read_all_directory_by_path(path, context.allocator)
	if read_err != nil do return read_err
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		child := strings.concatenate({path, "/", entry.name})
		defer delete(child)
		if entry.type == .Directory {
			remove_tree(child) or_return
		} else if remove_err := os.remove(child); remove_err != nil && remove_err != .Not_Exist {
			return remove_err
		}
	}
	return os.remove(path)
}
