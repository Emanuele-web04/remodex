import { httpRouter } from "convex/server";
import { httpAction, ActionCtx } from "./_generated/server";
import { api } from "./_generated/api";

const http = httpRouter();

function json(value: unknown, init?: ResponseInit) {
  return new Response(JSON.stringify(value), {
    ...init,
    headers: {
      "content-type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
}

async function readJSON(request: Request) {
  return (await request.json()) as Record<string, unknown>;
}

async function handleHealth() {
  return json({ status: "ok", provider: "convex" });
}

async function handleEnqueueOutbound(ctx: ActionCtx, request: Request) {
  const body = await readJSON(request);
  const record = await ctx.runMutation(api.messages.enqueueOutbound, {
    requestId: readOptionalString(body.requestId),
    messageId: readRequiredString(body.messageId, "messageId"),
    threadId: readOptionalString(body.threadId),
    fromDeviceId: readRequiredString(body.fromDeviceId, "fromDeviceId"),
    toDeviceId: readRequiredString(body.toDeviceId, "toDeviceId"),
    method: readOptionalString(body.method),
    ciphertext: readRequiredString(body.ciphertext, "ciphertext"),
    signature: readRequiredString(body.signature, "signature"),
    createdAt: readRequiredNumber(body.createdAt, "createdAt"),
    expiresAt: readRequiredNumber(body.expiresAt, "expiresAt"),
    idempotencyKey: readRequiredString(body.idempotencyKey, "idempotencyKey"),
  });
  return json({ ok: true, message: record });
}

async function handleClaimNextOutbound(ctx: ActionCtx, request: Request) {
  const url = new URL(request.url);
  const toDeviceId = readRequiredString(
    url.searchParams.get("toDeviceId"),
    "toDeviceId"
  );
  const leaseMs = Number(url.searchParams.get("leaseMs") || "15000");
  const message = await ctx.runMutation(api.messages.claimNextOutbound, {
    toDeviceId,
    nowMs: Date.now(),
    leaseMs: Number.isFinite(leaseMs) && leaseMs > 0 ? leaseMs : 15000,
  });
  return json({ ok: true, message });
}

async function handleStoreInboundResponse(ctx: ActionCtx, request: Request, suffix: string) {
  const body = await readJSON(request);
  const result = await ctx.runMutation(api.messages.storeInboundResponse, {
    recordName: readRequiredString(body.recordName, "recordName") as never,
    ciphertext: readOptionalString(body.ciphertext),
    signature: readOptionalString(body.signature),
    nowMs: Date.now(),
    idempotencyKeySuffix: suffix,
  });
  return json({ ok: true, message: result });
}

async function handleFindInboundResponseGET(ctx: ActionCtx, request: Request) {
  const url = new URL(request.url);
  const record = await ctx.runQuery(api.messages.findInboundResponse, {
    requestId: readRequiredString(url.searchParams.get("requestId"), "requestId"),
    toDeviceId: readRequiredString(url.searchParams.get("toDeviceId"), "toDeviceId"),
    nowMs: Date.now(),
  });
  return json({ ok: true, message: record });
}

async function handleFindInboundResponsePOST(ctx: ActionCtx, request: Request) {
  const body = await readJSON(request);
  const record = await ctx.runQuery(api.messages.findInboundResponse, {
    requestId: readRequiredString(body.requestId, "requestId"),
    toDeviceId: readRequiredString(
      body.phoneDeviceId ?? body.toDeviceId,
      "phoneDeviceId"
    ),
    nowMs: Date.now(),
  });
  return json({ ok: true, message: record });
}

async function handleMarkInboundDelivered(ctx: ActionCtx, request: Request) {
  const body = await readJSON(request);
  const result = await ctx.runMutation(api.messages.markInboundDelivered, {
    recordName: readOptionalString(body.recordName) as never,
    requestId: readOptionalString(body.requestId),
    toDeviceId: readOptionalString(body.phoneDeviceId ?? body.toDeviceId),
  });
  return json({ ok: true, message: result });
}

http.route({
  path: "/async/health",
  method: "GET",
  handler: httpAction(handleHealth),
});

http.route({
  path: "/remodex/health",
  method: "GET",
  handler: httpAction(handleHealth),
});

http.route({
  path: "/async/outbound/enqueue",
  method: "POST",
  handler: httpAction(handleEnqueueOutbound),
});

http.route({
  path: "/remodex/messages/outbound",
  method: "POST",
  handler: httpAction(handleEnqueueOutbound),
});

http.route({
  path: "/async/outbound/claim",
  method: "GET",
  handler: httpAction(handleClaimNextOutbound),
});

http.route({
  path: "/async/outbound/claim-next",
  method: "GET",
  handler: httpAction(handleClaimNextOutbound),
});

http.route({
  path: "/remodex/messages/outbound/claim",
  method: "GET",
  handler: httpAction(handleClaimNextOutbound),
});

http.route({
  path: "/async/inbound/respond",
  method: "POST",
  handler: httpAction((ctx, req) => handleStoreInboundResponse(ctx, req, "response")),
});

http.route({
  path: "/async/outbound/respond",
  method: "POST",
  handler: httpAction((ctx, req) => handleStoreInboundResponse(ctx, req, "response")),
});

http.route({
  path: "/remodex/messages/outbound/respond",
  method: "POST",
  handler: httpAction((ctx, req) => handleStoreInboundResponse(ctx, req, "response")),
});

http.route({
  path: "/async/outbound/error",
  method: "POST",
  handler: httpAction((ctx, req) => handleStoreInboundResponse(ctx, req, "error")),
});

http.route({
  path: "/async/inbound/error",
  method: "POST",
  handler: httpAction((ctx, req) => handleStoreInboundResponse(ctx, req, "error")),
});

http.route({
  path: "/remodex/messages/outbound/error",
  method: "POST",
  handler: httpAction((ctx, req) => handleStoreInboundResponse(ctx, req, "error")),
});

http.route({
  path: "/async/inbound/poll",
  method: "GET",
  handler: httpAction(handleFindInboundResponseGET),
});

http.route({
  path: "/async/inbound/poll",
  method: "POST",
  handler: httpAction(handleFindInboundResponsePOST),
});

http.route({
  path: "/remodex/messages/inbound",
  method: "GET",
  handler: httpAction(handleFindInboundResponseGET),
});

http.route({
  path: "/async/inbound/delivered",
  method: "POST",
  handler: httpAction(handleMarkInboundDelivered),
});

http.route({
  path: "/remodex/messages/inbound/delivered",
  method: "POST",
  handler: httpAction(handleMarkInboundDelivered),
});

export default http;

function readOptionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

function readRequiredString(value: unknown, field: string): string {
  const trimmed = readOptionalString(value);
  if (!trimmed) {
    throw new Error(`Missing ${field}.`);
  }
  return trimmed;
}

function readRequiredNumber(value: unknown, field: string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`Missing ${field}.`);
  }
  return parsed;
}
