package engine

import "core:mem"
import "core:mem/virtual"
import "core:sync"

// Index_Tree is a memory index: a B+tree of encoded keys, each filing the rows
// that hold it (Index_Slot), that a reader's table shares with the copy a commit
// writes (R7). It was a red-black tree, whose nodes point at their parent: a
// copy had to copy every node and every key, 8-10 ms of a commit over 50 000
// rows with a reader open. Here a copy takes the root with one more reference;
// the writer copies a node it is about to change when another tree still holds
// it (path copying), and the last tree that holds a node frees it.
//
// A node owns the row lists of its slots (Index_Slot.more): a copy of a leaf
// copies them. The keys live in the table's key store (Key_Store), which every
// table that shares the tree holds, so a node copy copies the strings' headers
// and nothing else.
//
// A leaf holds up to IB_FAN keys in order. An interior node holds up to IB_FAN
// children and the separators between them: keys[i] is not above any key of
// kids[i + 1] and is above every key of kids[i]. A node that loses its last
// key leaves its parent; nodes are not merged otherwise.
Index_Tree :: struct {
	root:  ^Ib_Node,
	count: int,
}

IB_FAN :: 32
IB_DEPTH :: 12

Ib_Node :: struct {
	// refs counts the trees and parent nodes that point at this node. Only the
	// writer adds one; a reader ending on its own thread can drop one.
	refs:  int,
	leaf:  bool,
	// count is the keys of a leaf, or the children of an interior node.
	count: int,
	keys:  [IB_FAN]string,
	slots: [IB_FAN]Index_Slot,
	kids:  [IB_FAN]^Ib_Node,
}

@(private)
ib_node_new :: proc(leaf: bool) -> (^Ib_Node, mem.Allocator_Error) {
	node, err := new(Ib_Node)
	if err != nil do return nil, err
	node.refs = 1
	node.leaf = leaf
	return node, nil
}

@(private)
ib_release :: proc(node: ^Ib_Node) {
	if node == nil || sync.atomic_sub(&node.refs, 1) != 1 do return
	if node.leaf {
		for slot in node.slots[:node.count] do delete(slot.more)
	} else {
		for kid in node.kids[:node.count] do ib_release(kid)
	}
	free(node)
}

// ib_free lets go of a tree.
ib_free :: proc(t: ^Index_Tree) {
	ib_release(t.root)
	t^ = {}
}

// ib_share gives `target` the tree of `source`: one more reference to its root.
ib_share :: proc(target: ^Index_Tree, source: ^Index_Tree) {
	ib_free(target)
	if source.root != nil do sync.atomic_add(&source.root.refs, 1)
	target^ = source^
}

// ib_own makes the node `at` points at this tree's own to change: a node
// another tree or node still points at is copied, the copy's children gain a
// parent, and `at` points at the copy.
@(private)
ib_own :: proc(at: ^^Ib_Node) -> (own: ^Ib_Node, err: mem.Allocator_Error) {
	node := at^
	if sync.atomic_load(&node.refs) == 1 do return node, nil
	own = ib_node_new(node.leaf) or_return
	own.count = node.count
	own.keys = node.keys
	if node.leaf {
		own.slots = node.slots
		for &slot in own.slots[:own.count] {
			if len(slot.more) == 0 {
				slot.more = nil
				continue
			}
			more := make([dynamic]Row_Id, len(slot.more)) or_return
			copy(more[:], slot.more[:])
			slot.more = more
		}
	} else {
		own.kids = node.kids
		for kid in own.kids[:own.count] do sync.atomic_add(&kid.refs, 1)
	}
	at^ = own
	ib_release(node)
	return own, nil
}

// ib_leaf_search is where `key` sits in a leaf, or where it would go.
@(private)
ib_leaf_search :: #force_inline proc "contextless" (node: ^Ib_Node, key: string) -> (at: int, found: bool) {
	low, high := 0, node.count
	for low < high {
		middle := (low + high) / 2
		order := text_compare(node.keys[middle], key)
		if order == 0 do return middle, true
		if order < 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low, false
}

// ib_child_of is the child of an interior node that holds or would hold `key`:
// the number of separators not above it.
@(private)
ib_child_of :: #force_inline proc "contextless" (node: ^Ib_Node, key: string) -> int {
	low, high := 0, node.count - 1
	for low < high {
		middle := (low + high) / 2
		if text_compare(node.keys[middle], key) <= 0 {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

// ib_find is the slot of `key`, to read, or nil.
ib_find :: proc "contextless" (t: ^Index_Tree, key: string) -> ^Index_Slot {
	node := t.root
	if node == nil do return nil
	for !node.leaf do node = node.kids[ib_child_of(node, key)]
	at, found := ib_leaf_search(node, key)
	return found ? &node.slots[at] : nil
}

// ib_split splits the full child `at` of `parent`, both this tree's own: the
// upper half goes to a new node after it.
@(private)
ib_split :: proc(parent: ^Ib_Node, at: int) -> mem.Allocator_Error {
	child := parent.kids[at]
	right := ib_node_new(child.leaf) or_return
	half := IB_FAN / 2
	separator: string
	if child.leaf {
		right.count = child.count - half
		copy(right.keys[:right.count], child.keys[half:child.count])
		copy(right.slots[:right.count], child.slots[half:child.count])
		for &slot in child.slots[half:child.count] do slot = {}
		child.count = half
		separator = right.keys[0]
	} else {
		// Children [half, count) move; the separator between the halves goes up.
		right.count = child.count - half
		copy(right.kids[:right.count], child.kids[half:child.count])
		copy(right.keys[:right.count - 1], child.keys[half:child.count - 1])
		separator = child.keys[half - 1]
		child.count = half
	}
	copy(parent.kids[at + 2:parent.count + 1], parent.kids[at + 1:parent.count])
	copy(parent.keys[at + 1:parent.count], parent.keys[at:parent.count - 1])
	parent.kids[at + 1] = right
	parent.keys[at] = separator
	parent.count += 1
	return nil
}

// ib_upsert is the slot of `key`, to change in place, made this tree's own on
// the way down. A key not filed yet is filed, copied into `keys` at its exact
// length, with an empty slot (`inserted`), which the caller fills.
ib_upsert :: proc(t: ^Index_Tree, key: string, keys: mem.Allocator) -> (slot: ^Index_Slot, inserted: bool, err: mem.Allocator_Error) {
	if t.root == nil do t.root = ib_node_new(true) or_return
	node := ib_own(&t.root) or_return
	if node.count == IB_FAN {
		// A full root splits under a new one.
		root := ib_node_new(false) or_return
		root.kids[0] = node
		root.count = 1
		t.root = root
		if split_err := ib_split(root, 0); split_err != nil {
			t.root = node
			free(root)
			return nil, false, split_err
		}
		node = root
	}
	for !node.leaf {
		at := ib_child_of(node, key)
		child := ib_own(&node.kids[at]) or_return
		if child.count == IB_FAN {
			ib_split(node, at) or_return
			if text_compare(node.keys[at], key) <= 0 do at += 1
			child = node.kids[at]
		}
		node = child
	}
	at, found := ib_leaf_search(node, key)
	if found do return &node.slots[at], false, nil
	stored := make([]u8, len(key), keys) or_return
	copy(stored, key)
	copy(node.keys[at + 1:node.count + 1], node.keys[at:node.count])
	copy(node.slots[at + 1:node.count + 1], node.slots[at:node.count])
	node.keys[at] = string(stored)
	node.slots[at] = {}
	node.count += 1
	t.count += 1
	return &node.slots[at], true, nil
}

// ib_remove_id takes row `id` out of the slot of `key`; a slot left empty
// leaves its leaf, and a node left empty leaves its parent.
ib_remove_id :: proc(t: ^Index_Tree, key: string, id: Row_Id) -> mem.Allocator_Error {
	if t.root == nil || ib_find(t, key) == nil do return nil
	ib_own(&t.root) or_return
	ib_remove_in(t, &t.root, key, id) or_return
	root := t.root
	if root.count == 0 {
		ib_release(root)
		t.root = nil
	} else if !root.leaf && root.count == 1 {
		// An interior root with one child gives way to it.
		t.root = root.kids[0]
		root.count = 0
		ib_release(root)
	}
	return nil
}

@(private)
ib_remove_in :: proc(t: ^Index_Tree, at_node: ^^Ib_Node, key: string, id: Row_Id) -> mem.Allocator_Error {
	node := at_node^
	if node.leaf {
		at, found := ib_leaf_search(node, key)
		if !found do return nil
		if !index_slot_remove(&node.slots[at], id) do return nil
		delete(node.slots[at].more)
		copy(node.keys[at:node.count - 1], node.keys[at + 1:node.count])
		copy(node.slots[at:node.count - 1], node.slots[at + 1:node.count])
		node.count -= 1
		node.keys[node.count] = ""
		node.slots[node.count] = {}
		t.count -= 1
		return nil
	}
	at := ib_child_of(node, key)
	child := ib_own(&node.kids[at]) or_return
	ib_remove_in(t, &node.kids[at], key, id) or_return
	if child.count > 0 do return nil
	// The child is empty: it leaves, with the separator before it (or after
	// it, for the first child).
	ib_release(child)
	copy(node.kids[at:node.count - 1], node.kids[at + 1:node.count])
	if node.count > 1 {
		gap := max(at - 1, 0)
		copy(node.keys[gap:node.count - 2], node.keys[gap + 1:node.count - 1])
	}
	node.count -= 1
	node.kids[node.count] = nil
	return nil
}

// Ib_Cursor is a place in a tree: the path from the root, the last step being
// a key of a leaf. It reads; it is good while the tree it walks is not written.
Ib_Cursor :: struct {
	nodes: [IB_DEPTH]^Ib_Node,
	at:    [IB_DEPTH]int,
	depth: int,
	valid: bool,
}

// ib_lower_bound is the first key not below `key`.
ib_lower_bound :: proc(t: ^Index_Tree, key: string) -> (c: Ib_Cursor) {
	node := t.root
	if node == nil do return
	for {
		c.nodes[c.depth] = node
		if node.leaf {
			at, _ := ib_leaf_search(node, key)
			c.at[c.depth] = at
			break
		}
		at := ib_child_of(node, key)
		c.at[c.depth] = at
		c.depth += 1
		node = node.kids[at]
	}
	c.valid = true
	if c.at[c.depth] >= node.count do ib_next_leaf(&c)
	return
}

// ib_first is the first key; ib_last the last.
ib_first :: proc(t: ^Index_Tree) -> (c: Ib_Cursor) {
	node := t.root
	if node == nil do return
	for {
		c.nodes[c.depth] = node
		c.at[c.depth] = 0
		if node.leaf do break
		c.depth += 1
		node = node.kids[0]
	}
	c.valid = node.count > 0
	return
}

ib_last :: proc(t: ^Index_Tree) -> (c: Ib_Cursor) {
	node := t.root
	if node == nil do return
	for {
		c.nodes[c.depth] = node
		c.at[c.depth] = node.count - 1
		if node.leaf do break
		c.depth += 1
		node = node.kids[node.count - 1]
	}
	c.valid = node.count > 0
	return
}

ib_key :: #force_inline proc "contextless" (c: ^Ib_Cursor) -> string {
	return c.nodes[c.depth].keys[c.at[c.depth]]
}

ib_slot :: #force_inline proc "contextless" (c: ^Ib_Cursor) -> ^Index_Slot {
	return &c.nodes[c.depth].slots[c.at[c.depth]]
}

// ib_next moves to the next key; `valid` turns false past the last.
ib_next :: #force_inline proc "contextless" (c: ^Ib_Cursor) {
	c.at[c.depth] += 1
	if c.at[c.depth] < c.nodes[c.depth].count do return
	ib_next_leaf(c)
}

// ib_next_leaf moves from past the end of a leaf to the first key of the next.
@(private)
ib_next_leaf :: proc "contextless" (c: ^Ib_Cursor) {
	leaf := c.depth
	level := leaf - 1
	for level >= 0 && c.at[level] + 1 >= c.nodes[level].count do level -= 1
	if level < 0 {
		c.valid = false
		return
	}
	c.at[level] += 1
	for level < leaf {
		next := c.nodes[level].kids[c.at[level]]
		level += 1
		c.nodes[level] = next
		c.at[level] = 0
	}
}

// ib_advance moves to the next key and answers whether there is one; it is
// the post statement of a walk (`c.valid = ib_advance(&c)`), which Odin wants
// to be an assignment.
ib_advance :: #force_inline proc "contextless" (c: ^Ib_Cursor) -> bool {
	ib_next(c)
	return c.valid
}

ib_retreat :: #force_inline proc "contextless" (c: ^Ib_Cursor) -> bool {
	ib_prev(c)
	return c.valid
}

// ib_prev moves to the key before; `valid` turns false before the first.
ib_prev :: proc "contextless" (c: ^Ib_Cursor) {
	if c.at[c.depth] > 0 {
		c.at[c.depth] -= 1
		return
	}
	leaf := c.depth
	level := leaf - 1
	for level >= 0 && c.at[level] == 0 do level -= 1
	if level < 0 {
		c.valid = false
		return
	}
	c.at[level] -= 1
	for level < leaf {
		next := c.nodes[level].kids[c.at[level]]
		level += 1
		c.nodes[level] = next
		c.at[level] = next.count - 1
	}
}

// Key_Store holds the keys of a table's memory indexes, for every table that
// shares its trees: the one a reader keeps and the copy a commit writes. A
// key's bytes stay until the last of those tables is gone, as they stayed in
// the table's arena until the table was dropped; only the writer adds keys,
// and an arena never moves what it handed out.
Key_Store :: struct {
	arena:     virtual.Arena,
	allocator: mem.Allocator,
	refs:      int,
}

key_store_make :: proc() -> (^Key_Store, mem.Allocator_Error) {
	store, err := new(Key_Store)
	if err != nil do return nil, err
	if arena_err := virtual.arena_init_growing(&store.arena); arena_err != .None {
		free(store)
		return nil, .Out_Of_Memory
	}
	store.allocator = arena_allocator_guarded(&store.arena)
	store.refs = 1
	return store, nil
}

key_store_acquire :: proc(store: ^Key_Store) {
	if store != nil do sync.atomic_add(&store.refs, 1)
}

key_store_release :: proc(store: ^Key_Store) {
	if store == nil || sync.atomic_sub(&store.refs, 1) != 1 do return
	virtual.arena_destroy(&store.arena)
	free(store)
}
