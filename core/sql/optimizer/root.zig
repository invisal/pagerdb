// Query optimizer: transforms a LogicalPlan into an equivalent but cheaper
// LogicalPlan.  Sits between the logical planner and the physical planner in
// the execute() pipeline, so it works on fully-resolved column indices (never
// raw column names) and never needs the catalog.
//
// Rule order matters: predicates should be pushed down before projections,
// because pushing filters first exposes more redundant projections to eliminate.
// Add new rules at the bottom of optimize() and document why the order is what it is.

const std = @import("std");
const lp = @import("../logical_plan.zig");
const pred = @import("predicate.zig");

pub const Optimizer = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Optimizer {
        return .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Optimizer) void {
        self.arena.deinit();
    }

    // Runs all optimization rules on `plan` and returns the rewritten plan.
    // Rules are applied in a single top-down pass each; add more passes or
    // a fixed-point loop here later if needed.
    pub fn optimize(self: *Optimizer, plan: lp.LogicalPlan) !lp.LogicalPlan {
        // Rule 1: push Filter nodes as close to the leaf scans as possible.
        // This reduces the number of rows that flow through every operator above.
        return pred.pushdownPredicates(self.arena.allocator(), plan);

        // TODO: Rule 2: projection pushdown — trim columns not used downstream.
        // Do this after predicate pushdown so filters have already been pushed
        // and we can see exactly which columns survive to each operator.
    }
};
