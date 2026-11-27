package tests

import "core:strings"
import "core:testing"

// The structural gate of A1 (the prepared statement): one place builds an
// evaluation context, so every context takes the statement's time and its
// links the same way (eval_context), and the execution is split by stage, no
// file of it past A1_EXEC_LINES. sql_exec.odin had 11 519 lines and 20 places
// that built an Eval_Ctx, each with its own conventions.

@(private = "file")
A1_ENGINE := #load_directory("../engine")

@(private = "file")
A1_EXEC_LINES :: 2500

@(private = "file")
A1_EXEC_FILES := []string {
	"sql_exec.odin",
	"sql_query.odin",
	"sql_select.odin",
	"sql_access.odin",
	"sql_window.odin",
	"sql_eval.odin",
	"sql_functions.odin",
	"sql_dml.odin",
	"sql_ddl.odin",
}

@(test)
test_one_place_builds_an_evaluation_context :: proc(t: ^testing.T) {
	testing.expect(t, len(A1_ENGINE) > 50)
	for file in A1_ENGINE {
		text := string(file.data)
		rest := text
		for {
			at := strings.index(rest, "Eval_Ctx{")
			spaced := strings.index(rest, "Eval_Ctx {")
			if at < 0 || (spaced >= 0 && spaced < at) do at = spaced
			if at < 0 do break
			before := rest[:at]
			// The literal handed to eval_context, and the type the constructor
			// returns, are the allowed ones.
			allowed := strings.has_suffix(before, "eval_context(") || strings.has_suffix(before, "-> ")
			testing.expectf(t, allowed, "%s builds an Eval_Ctx outside eval_context: %q", file.name, rest[at:min(at + 60, len(rest))])
			rest = rest[at + len("Eval_Ctx{"):]
		}
	}
}

@(test)
test_no_execution_file_is_past_its_limit :: proc(t: ^testing.T) {
	for name in A1_EXEC_FILES {
		found := false
		for file in A1_ENGINE {
			if file.name != name do continue
			found = true
			lines := strings.count(string(file.data), "\n")
			testing.expectf(t, lines <= A1_EXEC_LINES, "%s has %d lines, past %d", name, lines, A1_EXEC_LINES)
		}
		testing.expectf(t, found, "%s is not in the engine", name)
	}
}
