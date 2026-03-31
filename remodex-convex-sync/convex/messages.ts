import { query, mutation } from "./_generated/server";
import { v } from "convex/values";

function serializeMessage(
  doc: {
    _id: unknown;
    requestId?: string;
    messageId: string;
    threadId?: string;
    fromDeviceId: string;
    toDeviceId: string;
    method?: string;
    ciphertext: string;
    signature: string;
    status: "queued" | "processing" | "completed" | "delivered";
    createdAt: number;
    expiresAt: number;
    idempotencyKey: string;
  } | null
) {
  if (!doc) {
    return null;
  }

  return {
    recordName: String(doc._id),
    requestId: doc.requestId ?? "",
    messageId: doc.messageId,
    threadId: doc.threadId ?? "",
    fromDeviceId: doc.fromDeviceId,
    toDeviceId: doc.toDeviceId,
    method: doc.method ?? "",
    ciphertext: doc.ciphertext,
    signature: doc.signature,
    status: doc.status,
    createdAt: doc.createdAt,
    expiresAt: doc.expiresAt,
    idempotencyKey: doc.idempotencyKey,
  };
}

export const enqueueOutbound = mutation({
  args: {
    requestId: v.optional(v.string()),
    messageId: v.string(),
    threadId: v.optional(v.string()),
    fromDeviceId: v.string(),
    toDeviceId: v.string(),
    method: v.optional(v.string()),
    ciphertext: v.string(),
    signature: v.string(),
    createdAt: v.number(),
    expiresAt: v.number(),
    idempotencyKey: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("asyncMessages")
      .withIndex("by_idempotency_key", (q) => q.eq("idempotencyKey", args.idempotencyKey))
      .first();
    if (existing) {
      return serializeMessage(existing);
    }

    const insertedId = await ctx.db.insert("asyncMessages", {
      direction: "outbound",
      requestId: args.requestId,
      messageId: args.messageId,
      threadId: args.threadId,
      fromDeviceId: args.fromDeviceId,
      toDeviceId: args.toDeviceId,
      method: args.method,
      ciphertext: args.ciphertext,
      signature: args.signature,
      status: "queued",
      createdAt: args.createdAt,
      expiresAt: args.expiresAt,
      idempotencyKey: args.idempotencyKey,
    });

    return serializeMessage(await ctx.db.get(insertedId));
  },
});

export const claimNextOutbound = mutation({
  args: {
    toDeviceId: v.string(),
    nowMs: v.number(),
    leaseMs: v.number(),
  },
  handler: async (ctx, args) => {
    const queued = await ctx.db
      .query("asyncMessages")
      .withIndex("by_direction_to_device_status_created_at", (q) =>
        q
          .eq("direction", "outbound")
          .eq("toDeviceId", args.toDeviceId)
          .eq("status", "queued")
      )
      .order("asc")
      .take(20);

    const candidate =
      queued.find((entry) => entry.expiresAt > args.nowMs) ??
      (
        await ctx.db
          .query("asyncMessages")
          .withIndex("by_direction_to_device_status_created_at", (q) =>
            q
              .eq("direction", "outbound")
              .eq("toDeviceId", args.toDeviceId)
              .eq("status", "processing")
          )
          .order("asc")
          .take(20)
      ).find(
        (entry) =>
          entry.expiresAt > args.nowMs &&
          (entry.processingLeaseExpiresAt ?? 0) <= args.nowMs
      );

    if (!candidate) {
      return null;
    }

    await ctx.db.patch(candidate._id, {
      status: "processing",
      processingLeaseExpiresAt: args.nowMs + args.leaseMs,
    });

    return serializeMessage(await ctx.db.get(candidate._id));
  },
});

export const storeInboundResponse = mutation({
  args: {
    recordName: v.id("asyncMessages"),
    ciphertext: v.optional(v.string()),
    signature: v.optional(v.string()),
    nowMs: v.number(),
    idempotencyKeySuffix: v.string(),
  },
  handler: async (ctx, args) => {
    const outbound = await ctx.db.get(args.recordName);
    if (!outbound || outbound.direction !== "outbound") {
      throw new Error("Outbound message was not found.");
    }

    if (args.ciphertext && args.signature && outbound.requestId) {
      const idempotencyKey =
        `${outbound.requestId}|${outbound.toDeviceId}|${args.idempotencyKeySuffix}`;
      const existing = await ctx.db
        .query("asyncMessages")
        .withIndex("by_idempotency_key", (q) => q.eq("idempotencyKey", idempotencyKey))
        .first();
      if (!existing) {
        await ctx.db.insert("asyncMessages", {
          direction: "inbound",
          requestId: outbound.requestId,
          messageId: crypto.randomUUID(),
          threadId: outbound.threadId,
          fromDeviceId: outbound.toDeviceId,
          toDeviceId: outbound.fromDeviceId,
          method: outbound.method,
          ciphertext: args.ciphertext,
          signature: args.signature,
          status: "completed",
          createdAt: args.nowMs,
          expiresAt: args.nowMs + 60 * 60 * 1000,
          idempotencyKey,
        });
      }
    }

    await ctx.db.patch(outbound._id, {
      status: "completed",
      processingLeaseExpiresAt: undefined,
    });

    return { ok: true };
  },
});

export const findInboundResponse = query({
  args: {
    requestId: v.string(),
    toDeviceId: v.string(),
  },
  handler: async (ctx, args) => {
    const matches = await ctx.db
      .query("asyncMessages")
      .withIndex("by_direction_request_to_device_created_at", (q) =>
        q
          .eq("direction", "inbound")
          .eq("requestId", args.requestId)
          .eq("toDeviceId", args.toDeviceId)
      )
      .order("asc")
      .take(10);

    const active = matches.find((entry) => entry.expiresAt > Date.now());
    return serializeMessage(active ?? null);
  },
});

export const markInboundDelivered = mutation({
  args: {
    recordName: v.optional(v.id("asyncMessages")),
    requestId: v.optional(v.string()),
    toDeviceId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    let inbound = args.recordName ? await ctx.db.get(args.recordName) : null;
    if (!inbound && args.requestId && args.toDeviceId) {
      const requestId = args.requestId;
      const toDeviceId = args.toDeviceId;
      const matches = await ctx.db
        .query("asyncMessages")
        .withIndex("by_direction_request_to_device_created_at", (q) =>
          q
            .eq("direction", "inbound")
            .eq("requestId", requestId)
            .eq("toDeviceId", toDeviceId)
        )
        .order("asc")
        .take(1);
      inbound = matches[0] ?? null;
    }

    if (!inbound || inbound.direction !== "inbound") {
      return { ok: false };
    }

    await ctx.db.patch(inbound._id, {
      status: "delivered",
    });
    return { ok: true };
  },
});
