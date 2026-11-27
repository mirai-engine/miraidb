package engine

import "core:strings"
import "core:sync"

// The trees a statement reads beside its own (A1.8f): a view's query and a
// policy's predicate are kept by their text for a catalog generation, as the
// statement cache keeps a query's, instead of being parsed again at every run
// that reads them (a view's text was parsed by the resolver, the planner and
// the run that materializes it, three times a statement).
//
// A kept tree is one holder's at a time (`running`): a use nested inside another
// of the same tree, or on another thread, parses its own, which is not kept.
// The resolver's trees are kept apart from the ones a run reads (Tree_Use): a
// resolution rewrites the names in the tree it walks, and a run reads a view's
// tree as it was written.
//
// What a tree holds depends on its text alone; what a resolution wrote into it
// depends on the catalog, so a tree is kept for the generation it was used at
// (tx_catalog_generation). A transaction that sees another catalog (one it
// changed, one that began before a change) parses its own and keeps none.

// TREE_CACHE_SIZE is how many trees a store keeps; past it, a tree is parsed
// for its run and freed.
TREE_CACHE_SIZE :: 64

Tree_Use :: enum u8 {
	// View is a view's query as a run reads it: the planner prices it and the
	// run materializes it.
	View,
	// View_Columns is a view's query as the resolver walks it for its columns.
	View_Columns,
	// Policy is a policy's predicate, as `SELECT 1 FROM t WHERE (...)`.
	Policy,
}

Tree_Entry :: struct {
	query:      ^Query,
	running:    bool,
	generation: u64,
}

// Kept_Tree is a tree taken from the cache, to give back (tree_give). Its key
// is the holder's, in the heap, until tree_give hands it to the cache or frees
// it: a holder may outlive the temporary memory of the statement that took it.
Kept_Tree :: struct {
	key:   string,
	query: ^Query,
}

@(private)
tree_key :: proc(use: Tree_Use, text: string, alloc := context.allocator) -> string {
	prefix := [Tree_Use]string {
		.View         = "v\x00",
		.View_Columns = "r\x00",
		.Policy       = "p\x00",
	}
	return strings.concatenate({prefix[use], text}, alloc)
}

// tree_parse is the tree of `text` for `use`: the store's kept one when it is
// there for the transaction's generation and nobody holds it, else a parse of
// its own. The caller gives it back with tree_give, under the same key.
tree_parse :: proc(tx: ^Tx, use: Tree_Use, text: string) -> (tree: Kept_Tree, err: Error) {
	tree.key = tree_key(use, text)
	store := tx != nil ? tx.store : nil
	if generation, holds := tx_catalog_generation(tx); holds && store != nil {
		sync.mutex_lock(&store.tree_cache_mutex)
		entry, found := &store.tree_cache[tree.key]
		if found && !entry.running {
			if entry.generation == generation {
				entry.running = true
				tree.query = entry.query
				sync.mutex_unlock(&store.tree_cache_mutex)
				return tree, ERROR_NONE
			}
			// Kept for another catalog: what a resolution wrote in it is stale.
			key, dropped := delete_key(&store.tree_cache, tree.key)
			delete(key)
			query_destroy(dropped.query)
			free(dropped.query)
		}
		sync.mutex_unlock(&store.tree_cache_mutex)
	}
	parsed, parse_err := sql_parse(text)
	if parse_err.kind != .None {
		query_destroy(&parsed)
		delete(tree.key)
		return {}, parse_err
	}
	tree.query = new(Query)
	tree.query^ = parsed
	return tree, ERROR_NONE
}

// tree_give hands a tree back: the store keeps it for the transaction's
// generation, or it is freed (a full cache, a transaction whose catalog is its
// own, a tree another holder's parse took the place of).
tree_give :: proc(tx: ^Tx, tree: Kept_Tree) {
	if tree.query == nil {
		delete(tree.key)
		return
	}
	store := tx != nil ? tx.store : nil
	generation, holds := tx_catalog_generation(tx)
	if store != nil {
		sync.mutex_lock(&store.tree_cache_mutex)
		entry, found := &store.tree_cache[tree.key]
		if found && entry.query == tree.query {
			if holds && entry.generation == generation {
				entry.running = false
				sync.mutex_unlock(&store.tree_cache_mutex)
				delete(tree.key)
				return
			}
			key, _ := delete_key(&store.tree_cache, tree.key)
			delete(key)
		} else if !found && holds && len(store.tree_cache) < TREE_CACHE_SIZE {
			// The map takes the holder's key.
			store.tree_cache[tree.key] = Tree_Entry{query = tree.query, generation = generation}
			sync.mutex_unlock(&store.tree_cache_mutex)
			return
		}
		sync.mutex_unlock(&store.tree_cache_mutex)
	}
	delete(tree.key)
	query_destroy(tree.query)
	free(tree.query)
}

// tree_cache_clear frees every tree the store keeps.
tree_cache_clear :: proc(store: ^Store) {
	sync.mutex_lock(&store.tree_cache_mutex)
	defer sync.mutex_unlock(&store.tree_cache_mutex)
	for key, entry in store.tree_cache {
		delete(key)
		query_destroy(entry.query)
		free(entry.query)
	}
	delete(store.tree_cache)
	store.tree_cache = nil
}
