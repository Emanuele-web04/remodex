---
name: function-creator
description: Create Convex queries, mutations, and actions with proper validation, authentication, and error handling. Use when implementing new API endpoints.
---

# Convex Function Creator

Generate secure, type-safe Convex functions following all best practices.

## When to Use

- Creating new query functions (read data)
- Creating new mutation functions (write data)
- Creating new action functions (external APIs, long-running)
- Adding API endpoints to your Convex backend

## Function Types

### Queries (Read-Only)

- Can only read from database
- Cannot modify data or call external APIs
- Cached and reactive
- Run in transactions

```typescript
import { query } from "./_generated/server";
import { v } from "convex/values";

export const getTask = query({
  args: { taskId: v.id("tasks") },
  returns: v.union(v.object({
    _id: v.id("tasks"),
    text: v.string(),
    completed: v.boolean(),
  }), v.null()),
  handler: async (ctx, args) => {
    return await ctx.db.get(args.taskId);
  },
});
```

### Mutations (Transactional Writes)

- Can read and write to database
- Cannot call external APIs
- Run in ACID transactions
- Automatic retries on conflicts

```typescript
import { mutation } from "./_generated/server";
import { v } from "convex/values";

export const createTask = mutation({
  args: {
    text: v.string(),
    priority: v.optional(v.union(
      v.literal("low"),
      v.literal("medium"),
      v.literal("high")
    )),
  },
  returns: v.id("tasks"),
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Not authenticated");

    return await ctx.db.insert("tasks", {
      text: args.text,
      priority: args.priority ?? "medium",
      completed: false,
      createdAt: Date.now(),
    });
  },
});
```

### Actions (External + Non-Transactional)

- Can call external APIs (fetch, AI, etc.)
- Can call mutations via `ctx.runMutation`
- Cannot directly access database
- No automatic retries
- **Use `"use node"` directive when needing Node.js APIs**

**Important:** If your action needs Node.js-specific APIs (crypto, third-party SDKs, etc.), add `"use node"` at the top of the file. Files with `"use node"` can ONLY contain actions, not queries or mutations.

```typescript
"use node"; // Required for Node.js APIs like OpenAI SDK

import { action } from "./_generated/server";
import { api } from "./_generated/api";
import { v } from "convex/values";
import OpenAI from "openai";

const openai = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });

export const generateTaskSuggestion = action({
  args: { prompt: v.string() },
  returns: v.string(),
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Not authenticated");

    // Call OpenAI (requires "use node")
    const completion = await openai.chat.completions.create({
      model: "gpt-4",
      messages: [{ role: "user", content: args.prompt }],
    });

    const suggestion = completion.choices[0].message.content;

    // Write to database via mutation
    await ctx.runMutation(api.tasks.createTask, {
      text: suggestion,
    });

    return suggestion;
  },
});
```

**Note:** If you only need basic fetch (no Node.js APIs), you can omit `"use node"`. But for third-party SDKs, crypto, or other Node.js features, you must use it.

## Required Components

### 1. Argument Validation

**Always** define `args` with validators:

```typescript
args: {
  id: v.id("tasks"),
  text: v.string(),
  count: v.number(),
  enabled: v.boolean(),
  tags: v.array(v.string()),
  metadata: v.optional(v.object({
    key: v.string(),
  })),
}
```

### 2. Return Type Validation

**Always** define `returns`:

```typescript
returns: v.object({
  _id: v.id("tasks"),
  text: v.string(),
})

// Or for arrays
returns: v.array(v.object({ /* ... */ }))

// Or for nullable
returns: v.union(v.object({ /* ... */ }), v.null())
```

### 3. Authentication Check

**Always** verify auth in public functions:

```typescript
const identity = await ctx.auth.getUserIdentity();
if (!identity) {
  throw new Error("Not authenticated");
}
```

### 4. Authorization Check

**Always** verify ownership/permissions:

```typescript
const task = await ctx.db.get(args.taskId);
if (!task) {
  throw new Error("Task not found");
}

if (task.userId !== user._id) {
  throw new Error("Unauthorized");
}
```

## Complete Examples

### Secure Query with Auth

```typescript
export const getMyTasks = query({
  args: {
    status: v.optional(v.union(
      v.literal("active"),
      v.literal("completed")
    )),
  },
  returns: v.array(v.object({
    _id: v.id("tasks"),
    text: v.string(),
    completed: v.boolean(),
  })),
  handler: async (ctx, args) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Not authenticated");

    const user = await ctx.db
      .query("users")
      .withIndex("by_token", q =>
        q.eq("tokenIdentifier", identity.tokenIdentifier)
      )
      .unique();

    if (!user) throw new Error("User not found");

    let query = ctx.db
      .query("tasks")
      .withIndex("by_user", q => q.eq("userId", user._id));

    const tasks = await query.collect();

    if (args.status) {
      return tasks.filter(t =>
        args.status === "completed" ? t.completed : !t.completed
      );
    }

    return tasks;
  },
});
```

### Secure Mutation with Validation

```typescript
export const updateTask = mutation({
  args: {
    taskId: v.id("tasks"),
    text: v.optional(v.string()),
    completed: v.optional(v.boolean()),
  },
  returns: v.id("tasks"),
  handler: async (ctx, args) => {
    // 1. Authentication
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Not authenticated");

    // 2. Get user
    const user = await ctx.db
      .query("users")
      .withIndex("by_token", q =>
        q.eq("tokenIdentifier", identity.tokenIdentifier)
      )
      .unique();

    if (!user) throw new Error("User not found");

    // 3. Get resource
    const task = await ctx.db.get(args.taskId);
    if (!task) throw new Error("Task not found");

    // 4. Authorization
    if (task.userId !== user._id) {
      throw new Error("Unauthorized");
    }

    // 5. Update
    const updates: Partial<typeof task> = {};
    if (args.text !== undefined) updates.text = args.text;
    if (args.completed !== undefined) updates.completed = args.completed;

    await ctx.db.patch(args.taskId, updates);
    return args.taskId;
  },
});
```

### Action Calling External API

**Create separate file for actions that need Node.js:**

```typescript
// convex/taskActions.ts
"use node"; // Required for SendGrid SDK

import { action } from "./_generated/server";
import { api } from "./_generated/api";
import { v } from "convex/values";
import sendgrid from "@sendgrid/mail";

sendgrid.setApiKey(process.env.SENDGRID_API_KEY);

export const sendTaskReminder = action({
  args: { taskId: v.id("tasks") },
  returns: v.boolean(),
  handler: async (ctx, args) => {
    // 1. Auth
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) throw new Error("Not authenticated");

    // 2. Get data via query
    const task = await ctx.runQuery(api.tasks.getTask, {
      taskId: args.taskId,
    });

    if (!task) throw new Error("Task not found");

    // 3. Call external service (using Node.js SDK)
    await sendgrid.send({
      to: identity.email,
      from: "noreply@example.com",
      subject: "Task Reminder",
      text: `Don't forget: ${task.text}`,
    });

    // 4. Update via mutation
    await ctx.runMutation(api.tasks.markReminderSent, {
      taskId: args.taskId,
    });

    return true;
  },
});
```

**Note:** Keep queries and mutations in `convex/tasks.ts` (without "use node"), and actions that need Node.js in `convex/taskActions.ts` (with "use node").

## Internal Functions

For backend-only functions (called by scheduler, other functions):

```typescript
import { internalMutation } from "./_generated/server";

export const processExpiredTasks = internalMutation({
  args: {},
  handler: async (ctx) => {
    // No auth needed - only callable from backend
    const now = Date.now();
    const expired = await ctx.db
      .query("tasks")
      .withIndex("by_due_date", q => q.lt("dueDate", now))
      .collect();

    for (const task of expired) {
      await ctx.db.patch(task._id, { status: "expired" });
    }
  },
});
```

## Checklist

- [ ] `args` defined with validators
- [ ] `returns` defined with validator
- [ ] Authentication check (`ctx.auth.getUserIdentity()`)
- [ ] Authorization check (ownership/permissions)
- [ ] All promises awaited
- [ ] Indexed queries (no `.filter()` on queries)
- [ ] Error handling with descriptive messages
- [ ] Scheduled functions use `internal.*` not `api.*`
- [ ] If using Node.js APIs: `"use node"` at top of file
- [ ] If file has `"use node"`: Only actions (no queries/mutations)
- [ ] Actions in separate file from queries/mutations when using "use node"
