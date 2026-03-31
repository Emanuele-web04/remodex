import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  asyncMessages: defineTable({
    direction: v.union(v.literal("outbound"), v.literal("inbound")),
    requestId: v.optional(v.string()),
    messageId: v.string(),
    threadId: v.optional(v.string()),
    fromDeviceId: v.string(),
    toDeviceId: v.string(),
    method: v.optional(v.string()),
    ciphertext: v.string(),
    signature: v.string(),
    status: v.union(
      v.literal("queued"),
      v.literal("processing"),
      v.literal("completed"),
      v.literal("delivered")
    ),
    createdAt: v.number(),
    expiresAt: v.number(),
    idempotencyKey: v.string(),
    processingLeaseExpiresAt: v.optional(v.number()),
  })
    .index("by_idempotency_key", ["idempotencyKey"])
    .index("by_direction_to_device_status_created_at", [
      "direction",
      "toDeviceId",
      "status",
      "createdAt",
    ])
    .index("by_direction_request_to_device_created_at", [
      "direction",
      "requestId",
      "toDeviceId",
      "createdAt",
    ]),
});
