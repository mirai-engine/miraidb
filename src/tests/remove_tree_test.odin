package tests

import "core:os"
import "core:testing"

import db "../engine"

// remove_tree takes a directory and everything under it without the Windows
// shell, which core:os's remove_all waits on for a directory that is not empty.
@(test)
test_remove_tree_takes_a_directory_and_what_it_holds :: proc(t: ^testing.T) {
	root :: "_test_remove_tree"
	_ = db.remove_tree(root)
	testing.expect(t, os.make_directory_all(root + "/a/b") == nil)
	testing.expect(t, os.make_directory_all(root + "/empty") == nil)
	testing.expect(t, os.write_entire_file_from_string(root + "/top", "1") == nil)
	testing.expect(t, os.write_entire_file_from_string(root + "/a/mid", "2") == nil)
	testing.expect(t, os.write_entire_file_from_string(root + "/a/b/deep", "3") == nil)

	testing.expect_value(t, db.remove_tree(root), nil)
	testing.expect(t, !os.exists(root))
	// What is not there is already removed; a single file goes too.
	testing.expect_value(t, db.remove_tree(root), nil)
	testing.expect(t, os.write_entire_file_from_string(root, "file") == nil)
	testing.expect_value(t, db.remove_tree(root), nil)
	testing.expect(t, !os.exists(root))
}
