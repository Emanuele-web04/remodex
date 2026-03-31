---
name: convex-helpers-guide
description: Discover and use convex-helpers utilities for relationships, filtering, sessions, custom functions, and more. Use when you need pre-built Convex patterns.
---

# Convex Helpers Guide

Use convex-helpers to add common patterns and utilities to your Convex backend without reinventing the wheel.

## What is convex-helpers?

`convex-helpers` is the official collection of utilities that complement Convex. It provides battle-tested patterns for common backend needs.

**Installation:**
```bash
npm install convex-helpers
```

## Available Helpers

### 1. Relationship Helpers

Traverse relationships between tables in a readable, type-safe way.

**Use when:**
- Loading related data across tables
- Following foreign key relationships
- Building nested data structures

**Example:**
```typescript
import { getOneFrom, getManyFrom } from "convex-helpers/server/relationships";

export const getTaskWithUser = query({
  args: { taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.taskId);
    if (!task) return null;

    // Get related user
    const user = await getOneFrom(
      ctx.db,
      "users",
      "by_id",
      task.userId,
      "_id"
    );

    // Get related comments
    const comments = await getManyFrom(
      ctx.db,
      "comments",
      "by_task",
      task._id,
      "taskId"
    );

    return { ...task, user, comments };
  },
});
```

**Key Functions:**
- `getOneFrom` - Get single related document
- `getManyFrom` - Get multiple related documents
- `getManyVia` - Get many-to-many relationships through junction table

### 2. Custom Functions (Data Protection) ⭐ MOST IMPORTANT

**This is Convex's alternative to Row Level Security (RLS).** Instead of database-level policies, use custom function wrappers to automatically add auth and access control to all queries and mutations.

Create wrapped versions of query/mutation/action with custom behavior.

**Use when:**
- **Data protection and access control** (PRIMARY USE CASE)
- Want to add auth logic to all functions
- Multi-tenant applications
- Role-based access control (RBAC)
- Need to inject common data into ctx
- Building internal-only functions
- Adding logging/monitoring to all functions

**Why this instead of RLS:**
- ✅ TypeScript, not SQL policies
- ✅ Full type safety
- ✅ Easy to test and debug
- ✅ More flexible than database policies
- ✅ Works across your entire backend

**Example: Custom Query with Auto-Auth**
```typescript
// convex/lib/customFunctions.ts
import { customQuery } from "convex-helpers/server/customFunctions";
import { query } from "../_generated/server";

export const authenticatedQuery = customQuery(
  query,
  {
    args: {}, // No additional args required
    input: async (ctx, args) => {
      const identity = await ctx.auth.getUserIdentity();
      if (!identity) {
        throw new Error("Not authenticated");
      }

      const user = await ctx.db
        .query("users")
        .withIndex("by_token", q =>
          q.eq("tokenIdentifier", identity.tokenIdentifier)
        )
        .unique();

      if (!user) throw new Error("User not found");

      // Add user to context
      return { ctx: { ...ctx, user }, args };
    },
  }
);

// Usage in your functions
export const getMyTasks = authenticatedQuery({
  handler: async (ctx) => {
    // ctx.user is automatically available!
    return await ctx.db
      .query("tasks")
      .withIndex("by_user", q => q.eq("userId", ctx.user._id))
      .collect();
  },
});
```

**Example: Multi-Tenant Data Protection**
```typescript
import { customQuery } from "convex-helpers/server/customFunctions";
import { query } from "../_generated/server";

// Organization-scoped query - automatic access control
export const orgQuery = customQuery(query, {
  args: { orgId: v.id("organizations") },
  input: async (ctx, args) => {
    const user = await getCurrentUser(ctx);

    // Verify user is a member of this organization
    const member = await ctx.db
      .query("organizationMembers")
      .withIndex("by_org_and_user", q =>
        q.eq("orgId", args.orgId).eq("userId", user._id)
      )
      .unique();

    if (!member) {
      throw new Error("Not authorized for this organization");
    }

    // Inject org context
    return {
      ctx: {
        ...ctx,
        user,
        orgId: args.orgId,
        role: member.role
      },
      args
    };
  },
});

// Usage - data automatically scoped to organization
export const getOrgProjects = orgQuery({
  args: { orgId: v.id("organizations") },
  handler: async (ctx) => {
    // ctx.user and ctx.orgId automatically available and verified!
    return await ctx.db
      .query("projects")
      .withIndex("by_org", q => q.eq("orgId", ctx.orgId))
      .collect();
  },
});
```

**Example: Role-Based Access Control**
```typescript
import { customMutation } from "convex-helpers/server/customFunctions";
import { mutation } from "../_generated/server";

export const adminMutation = customMutation(mutation, {
  args: {},
  input: async (ctx, args) => {
    const user = await getCurrentUser(ctx);

    if (user.role !== "admin") {
      throw new Error("Admin access required");
    }

    return { ctx: { ...ctx, user }, args };
  },
});

// Usage - only admins can call this
export const deleteUser = adminMutation({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    // Only admins reach this code
    await ctx.db.delete(args.userId);
  },
});
```

### 3. Filter Helper

Apply complex TypeScript filters to database queries.

**Use when:**
- Need to filter by computed values
- Filtering logic is too complex for indexes
- Working with small result sets

**Example:**
```typescript
import { filter } from "convex-helpers/server/filter";

export const getActiveTasks = query({
  handler: async (ctx) => {
    const now = Date.now();
    const threeDaysAgo = now - 3 * 24 * 60 * 60 * 1000;

    return await filter(
      ctx.db.query("tasks"),
      (task) =>
        !task.completed &&
        task.createdAt > threeDaysAgo &&
        task.priority === "high"
    ).collect();
  },
});
```

**Note:** Still prefer indexes when possible! Use filter for complex logic that can't be indexed.

### 4. Sessions

Track users across requests even when not logged in.

**Use when:**
- Need to track anonymous users
- Building shopping cart for guests
- Tracking user behavior before signup
- A/B testing without auth

**Setup:**
```typescript
// convex/sessions.ts
import { SessionIdArg } from "convex-helpers/server/sessions";
import { query } from "./_generated/server";

export const trackView = query({
  args: {
    ...SessionIdArg, // Adds sessionId: v.string()
    pageUrl: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.insert("pageViews", {
      sessionId: args.sessionId,
      pageUrl: args.pageUrl,
      timestamp: Date.now(),
    });
  },
});
```

**Client (React):**
```typescript
import { useSessionId } from "convex-helpers/react/sessions";
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function MyComponent() {
  const sessionId = useSessionId();

  // Automatically includes sessionId in all requests
  useQuery(api.sessions.trackView, {
    sessionId,
    pageUrl: window.location.href,
  });
}
```

### 5. Zod Validation

Use Zod schemas instead of Convex validators.

**Use when:**
- Already using Zod in your project
- Want more complex validation logic
- Need custom error messages

**Example:**
```typescript
import { zCustomQuery } from "convex-helpers/server/zod";
import { z } from "zod";
import { query } from "./_generated/server";

const argsSchema = z.object({
  email: z.string().email(),
  age: z.number().min(18).max(120),
});

export const createUser = zCustomQuery(query, {
  args: argsSchema,
  handler: async (ctx, args) => {
    // args is typed from Zod schema
    return await ctx.db.insert("users", args);
  },
});
```

### 6. Alternative: Row-Level Security Helper

**Note:** Convex recommends using **custom functions** (see #2 above) as the primary data protection pattern. This RLS helper is an alternative approach that mimics traditional RLS.

Implement fine-grained access control with RLS-style rules.

**Use when:**
- Prefer RLS-style patterns from PostgreSQL
- Need to apply same rules across many functions
- Want centralized access control rules

**However, custom functions are usually better because:**
- ✅ Type-safe at compile time (RLS is runtime)
- ✅ More explicit (easy to see what auth is applied)
- ✅ Better error messages
- ✅ Easier to test

**Example (if you prefer RLS style):**
```typescript
import { RowLevelSecurity } from "convex-helpers/server/rowLevelSecurity";

const rules = new RowLevelSecurity();

rules.addRule("tasks", async (ctx, task) => {
  const user = await getCurrentUser(ctx);
  // Users can only see their own tasks
  return task.userId === user._id;
});

export const getTasks = query({
  handler: async (ctx) => {
    return await rules.applyRules(
      ctx,
      ctx.db.query("tasks").collect()
    );
  },
});
```

**Recommended instead: Custom functions**
```typescript
export const myQuery = authedQuery({
  handler: async (ctx) => {
    // More explicit, type-safe, better errors
    return await ctx.db
      .query("tasks")
      .withIndex("by_user", q => q.eq("userId", ctx.user._id))
      .collect();
  },
});
```

### 7. Migrations

Run data migrations safely.

**Use when:**
- Backfilling new fields
- Transforming existing data
- Moving between schema versions

**Example:**
```typescript
import { makeMigration } from "convex-helpers/server/migrations";

export const addDefaultPriority = makeMigration({
  table: "tasks",
  migrateOne: async (ctx, doc) => {
    if (doc.priority === undefined) {
      await ctx.db.patch(doc._id, { priority: "medium" });
    }
  },
});

// Run: npx convex run migrations:addDefaultPriority
```

### 8. Triggers

Execute code automatically when data changes.

**Use when:**
- Sending notifications on data changes
- Updating related records
- Logging changes
- Maintaining computed fields

**Example:**
```typescript
import { Triggers } from "convex-helpers/server/triggers";

const triggers = new Triggers();

triggers.register("tasks", "insert", async (ctx, task) => {
  // Send notification when task is created
  await ctx.db.insert("notifications", {
    userId: task.userId,
    type: "task_created",
    taskId: task._id,
  });
});
```

### 9. Aggregations

Compute aggregates efficiently.

**Example:**
```typescript
import { aggregation } from "convex-helpers/server/aggregation";

export const getTaskStats = query({
  handler: async (ctx) => {
    const stats = await aggregation(
      ctx.db.query("tasks"),
      {
        total: "count",
        completed: (task) => task.completed ? 1 : 0,
        totalPriority: (task) =>
          task.priority === "high" ? 3 : task.priority === "medium" ? 2 : 1,
      }
    );

    return {
      total: stats.total,
      completed: stats.completed,
      avgPriority: stats.totalPriority / stats.total,
    };
  },
});
```

## Common Patterns

### Pattern 1: Authenticated Queries with User Context

```typescript
import { customQuery } from "convex-helpers/server/customFunctions";

export const authedQuery = customQuery(query, {
  args: {},
  input: async (ctx, args) => {
    const user = await getCurrentUser(ctx);
    return { ctx: { ...ctx, user }, args };
  },
});

// Now all queries automatically have user in context
export const getMyData = authedQuery({
  handler: async (ctx) => {
    // ctx.user is typed and available!
    return await ctx.db
      .query("data")
      .withIndex("by_user", q => q.eq("userId", ctx.user._id))
      .collect();
  },
});
```

### Pattern 2: Loading Related Data

```typescript
import { getOneFrom, getManyFrom } from "convex-helpers/server/relationships";

export const getPostWithDetails = query({
  args: { postId: v.id("posts") },
  handler: async (ctx, args) => {
    const post = await ctx.db.get(args.postId);
    if (!post) return null;

    // Load author
    const author = await getOneFrom(
      ctx.db,
      "users",
      "by_id",
      post.authorId,
      "_id"
    );

    // Load comments
    const comments = await getManyFrom(
      ctx.db,
      "comments",
      "by_post",
      post._id,
      "postId"
    );

    // Load tags (many-to-many)
    const tagLinks = await getManyFrom(
      ctx.db,
      "postTags",
      "by_post",
      post._id,
      "postId"
    );

    const tags = await Promise.all(
      tagLinks.map(link =>
        getOneFrom(ctx.db, "tags", "by_id", link.tagId, "_id")
      )
    );

    return { ...post, author, comments, tags };
  },
});
```

### Pattern 3: Batch Operations with Error Handling

```typescript
import { asyncMap } from "convex-helpers";

export const batchUpdateTasks = mutation({
  args: {
    taskIds: v.array(v.id("tasks")),
    status: v.string(),
  },
  handler: async (ctx, args) => {
    const results = await asyncMap(args.taskIds, async (taskId) => {
      try {
        const task = await ctx.db.get(taskId);
        if (task) {
          await ctx.db.patch(taskId, { status: args.status });
          return { success: true, taskId };
        }
        return { success: false, taskId, error: "Not found" };
      } catch (error) {
        return { success: false, taskId, error: error.message };
      }
    });

    return results;
  },
});
```

## Best Practices

1. **Start with convex-helpers**
   - Don't reinvent common patterns
   - Use battle-tested utilities
   - Contribute back if you build something useful

2. **Custom Functions for Auth**
   - Create `authedQuery`, `authedMutation`, etc.
   - Inject user context automatically
   - Reduces boilerplate

3. **Relationships Over Nesting**
   - Use relationship helpers
   - Keep data normalized
   - Load related data as needed

4. **Filter Sparingly**
   - Prefer indexes when possible
   - Use filter for complex computed logic
   - Good for small result sets

5. **Sessions for Anonymous Users**
   - Track before signup
   - Migrate to user account later
   - Great for cart, preferences, etc.

## Documentation

- [convex-helpers GitHub](https://github.com/get-convex/convex-helpers)
- [convex-helpers on npm](https://www.npmjs.com/package/convex-helpers)
- [Relationship Helpers Guide](https://stack.convex.dev/functional-relationships-helpers)

## Checklist

- [ ] Installed convex-helpers: `npm install convex-helpers`
- [ ] Using relationship helpers for related data
- [ ] Created custom functions for common auth patterns
- [ ] Using sessions for anonymous tracking (if needed)
- [ ] Prefer indexes over filter when possible
- [ ] Check convex-helpers docs for new utilities

## When to Use What

| Need | Use | Import From |
|------|-----|-------------|
| Load related data | `getOneFrom`, `getManyFrom` | `convex-helpers/server/relationships` |
| Auth in all functions | `customQuery` | `convex-helpers/server/customFunctions` |
| Complex filters | `filter` | `convex-helpers/server/filter` |
| Anonymous users | `useSessionId` | `convex-helpers/react/sessions` |
| Zod validation | `zCustomQuery` | `convex-helpers/server/zod` |
| Data migrations | `makeMigration` | `convex-helpers/server/migrations` |
| Triggers | `Triggers` | `convex-helpers/server/triggers` |
