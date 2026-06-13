/// A linked list, but also contains a pointer to the last node,
/// which allows you append item to the end of the list with O(1) complexity.
pub fn TailLinkedList(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            next: ?*Node = null,
            data: T,

            pub const Data = T;

            /// Insert a new node after the current one.
            ///
            /// Arguments:
            ///     new_node: Pointer to the new node to insert.
            pub fn insertAfter(node: *Node, new_node: *Node) void {
                new_node.next = node.next;
                node.next = new_node;
            }

            /// Remove a node from the list.
            ///
            /// Arguments:
            ///     node: Pointer to the node to be removed.
            /// Returns:
            ///     node removed
            pub fn removeNext(node: *Node) ?*Node {
                const next_node = node.next orelse return null;
                node.next = next_node.next;
                return next_node;
            }

            /// Iterate over the singly-linked list from this node, until the final node is found.
            /// This operation is O(N).
            pub fn findLast(node: *Node) *Node {
                var it = node;
                while (true) {
                    it = it.next orelse return it;
                }
            }

            /// Iterate over each next node, returning the count of all nodes except the starting one.
            /// This operation is O(N).
            pub fn countChildren(node: *const Node) usize {
                var count: usize = 0;
                var it: ?*const Node = node.next;
                while (it) |n| : (it = n.next) {
                    count += 1;
                }
                return count;
            }
        };

        first: ?*Node = null,
        last: ?*Node = null,

        /// Prepend a new node to the list.
        pub fn prepend(self: *Self, new_node: *Node) void {
            new_node.next = self.first;
            self.first = new_node;
            if (self.last == null) {
                self.last = new_node;
            }
        }

        /// Append a new node to the list.
        pub fn append(self: *Self, new_node: *Node) void {
            if (self.last) |last| {
                last.insertAfter(new_node);
                self.last = new_node;
            } else {
                self.first = new_node;
                self.last = new_node;
            }
        }

        /// Remove and return the first item in the list.
        pub fn popFirst(self: *Self) ?*Node {
            const first = self.first orelse return null;
            self.first = first.next;
            return first;
        }

        /// Iterate over all nodes, returning the count.
        /// This operation is O(N).
        pub fn len(self: Self) usize {
            if (self.first) |n| {
                return 1 + n.countChildren();
            } else {
                return 0;
            }
        }
    };
}
