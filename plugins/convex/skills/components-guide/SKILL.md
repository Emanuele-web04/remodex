---
name: components-guide
description: Guide to using Convex components for feature encapsulation. Learn about sibling components, creating your own, and when to use components vs monolithic code.
---

# Convex Components Guide

Use components to encapsulate features and build maintainable, reusable backends.

## What Are Convex Components?

**Components are self-contained mini-backends** that bundle:
- Their own database schema
- Their own functions (queries, mutations, actions)
- Their own data (isolated tables)
- Clear API boundaries

**Think of them as:** npm packages for your backend, or microservices without the deployment complexity.

## Why Use Components?

### Traditional Approach (Monolithic)
```
convex/
├── users.ts           (500 lines)
├── files.ts           (600 lines - upload, storage, permissions, rate limiting)
├── payments.ts        (400 lines - Stripe, webhooks, billing)
├── notifications.ts   (300 lines)
└── analytics.ts       (200 lines)

Total: One big codebase, everything mixed together
```

### Component Approach (Encapsulated)
```
convex/
├── components/
│   ├── storage/      (File uploads - reusable)
│   ├── billing/      (Payments - reusable)
│   ├── notifications/ (Alerts - reusable)
│   └── analytics/    (Tracking - reusable)
├── convex.config.ts  (Wire components together)
└── domain/           (Your actual business logic)
    ├── users.ts      (50 lines - uses components)
    └── projects.ts   (75 lines - uses components)

Total: Clean, focused, reusable
```

## Quick Start

### 1. Install a Component

```bash
# Official components from npm
npm install @convex-dev/ratelimiter
```

### 2. Configure in convex.config.ts

```typescript
import { defineApp } from "convex/server";
import ratelimiter from "@convex-dev/ratelimiter/convex.config";

export default defineApp({
  components: {
    ratelimiter,
  },
});
```

### 3. Use in Your Code

```typescript
import { components } from "./_generated/api";

export const createPost = mutation({
  handler: async (ctx, args) => {
    // Use the component
    await components.ratelimiter.check(ctx, {
      key: `user:${ctx.user._id}`,
      limit: 10,
      period: 60000, // 10 requests per minute
    });

    return await ctx.db.insert("posts", args);
  },
});
```

## Sibling Components Pattern

Multiple components working together at the same level:

```typescript
// convex.config.ts
export default defineApp({
  components: {
    // Sibling components - each handles one concern
    auth: authComponent,
    storage: storageComponent,
    payments: paymentsComponent,
    emails: emailComponent,
    analytics: analyticsComponent,
  },
});
```

### Example: Complete Feature Using Siblings

```typescript
// convex/subscriptions.ts
import { components } from "./_generated/api";

export const subscribe = mutation({
  args: { plan: v.string() },
  handler: async (ctx, args) => {
    // 1. Verify authentication (auth component)
    const user = await components.auth.getCurrentUser(ctx);

    // 2. Create payment (payments component)
    const subscription = await components.payments.createSubscription(ctx, {
      userId: user._id,
      plan: args.plan,
      amount: getPlanAmount(args.plan),
    });

    // 3. Track conversion (analytics component)
    await components.analytics.track(ctx, {
      event: "subscription_created",
      userId: user._id,
      plan: args.plan,
    });

    // 4. Send confirmation (emails component)
    await components.emails.send(ctx, {
      to: user.email,
      template: "subscription_welcome",
      data: { plan: args.plan },
    });

    // 5. Store subscription in main app
    await ctx.db.insert("subscriptions", {
      userId: user._id,
      paymentId: subscription.id,
      plan: args.plan,
      status: "active",
    });

    return subscription;
  },
});
```

**What this achieves:**
- ✅ Each component is single-purpose
- ✅ Components are reusable across features
- ✅ Easy to swap implementations (change email provider)
- ✅ Can update components independently
- ✅ Clear separation of concerns

## Official Components

Browse [Component Directory](https://www.convex.dev/components):

### Authentication
- **@convex-dev/better-auth** - Better Auth integration

### Storage
- **@convex-dev/r2** - Cloudflare R2 file storage
- **@convex-dev/storage** - File upload/download

### Payments
- **@convex-dev/polar** - Polar billing & subscriptions

### AI
- **@convex-dev/agent** - AI agent workflows
- **@convex-dev/embeddings** - Vector storage & search

### Backend Utilities
- **@convex-dev/ratelimiter** - Rate limiting
- **@convex-dev/aggregate** - Data aggregations
- **@convex-dev/action-cache** - Cache action results
- **@convex-dev/sharded-counter** - Distributed counters
- **@convex-dev/migrations** - Schema migrations
- **@convex-dev/workflow** - Workflow orchestration

## Creating Your Own Component

### When to Create a Component

**Good reasons:**
- Feature is self-contained
- You'll reuse it across projects
- Want to share with team/community
- Complex feature with its own data model
- Third-party integration wrapper

**Not good reasons:**
- One-off business logic
- Tightly coupled to main app
- Simple utility functions

### Structure

```bash
mkdir -p convex/components/notifications
```

```typescript
// convex/components/notifications/convex.config.ts
import { defineComponent } from "convex/server";

export default defineComponent("notifications");
```

```typescript
// convex/components/notifications/schema.ts
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  notifications: defineTable({
    userId: v.id("users"),
    message: v.string(),
    read: v.boolean(),
    createdAt: v.number(),
  })
    .index("by_user", ["userId"])
    .index("by_user_and_read", ["userId", "read"]),
});
```

```typescript
// convex/components/notifications/send.ts
import { mutation } from "./_generated/server";
import { v } from "convex/values";

export const send = mutation({
  args: {
    userId: v.id("users"),
    message: v.string(),
  },
  handler: async (ctx, args) => {
    await ctx.db.insert("notifications", {
      userId: args.userId,
      message: args.message,
      read: false,
      createdAt: Date.now(),
    });
  },
});

export const markRead = mutation({
  args: { notificationId: v.id("notifications") },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.notificationId, { read: true });
  },
});
```

```typescript
// convex/components/notifications/read.ts
import { query } from "./_generated/server";
import { v } from "convex/values";

export const list = query({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    return await ctx.db
      .query("notifications")
      .withIndex("by_user", q => q.eq("userId", args.userId))
      .order("desc")
      .collect();
  },
});

export const unreadCount = query({
  args: { userId: v.id("users") },
  handler: async (ctx, args) => {
    const unread = await ctx.db
      .query("notifications")
      .withIndex("by_user_and_read", q =>
        q.eq("userId", args.userId).eq("read", false)
      )
      .collect();

    return unread.length;
  },
});
```

### Use Your Component

```typescript
// convex.config.ts
import { defineApp } from "convex/server";
import notifications from "./components/notifications/convex.config";

export default defineApp({
  components: {
    notifications, // Your local component
  },
});
```

```typescript
// convex/tasks.ts - main app code
import { components } from "./_generated/api";

export const completeTask = mutation({
  args: { taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    const task = await ctx.db.get(args.taskId);

    await ctx.db.patch(args.taskId, { completed: true });

    // Use your component
    await components.notifications.send(ctx, {
      userId: task.userId,
      message: `Task "${task.title}" completed!`,
    });
  },
});
```

## Component Communication Patterns

### ✅ Parent → Component (Good)

```typescript
// Main app calls component
await components.storage.upload(ctx, file);
await components.analytics.track(ctx, event);
```

### ✅ Parent → Multiple Siblings (Good)

```typescript
// Main app orchestrates multiple components
await components.auth.verify(ctx);
const file = await components.storage.upload(ctx, data);
await components.notifications.send(ctx, message);
```

### ✅ Component Receives Parent Data (Good)

```typescript
// Pass IDs from parent's tables to component
await components.audit.log(ctx, {
  userId: user._id,        // From parent's users table
  action: "delete",
  resourceId: task._id,    // From parent's tasks table
});

// Component stores these as strings/IDs
// but doesn't access parent tables directly
```

### ❌ Component → Parent Tables (Bad)

```typescript
// Inside component code - DON'T DO THIS
const user = await ctx.db.get(userId); // Error! Can't access parent tables
```

### ❌ Sibling → Sibling (Bad)

Components can't call each other directly. If you need this, they should be in the main app or refactor the design.

## Real-World Examples

### Multi-Tenant SaaS

```typescript
// convex.config.ts
export default defineApp({
  components: {
    auth: "@convex-dev/better-auth",
    organizations: "./components/organizations",
    billing: "./components/billing",
    storage: "@convex-dev/r2",
    analytics: "./components/analytics",
    emails: "./components/emails",
  },
});
```

Each component:
- `auth` - User authentication & sessions
- `organizations` - Tenant isolation & permissions
- `billing` - Stripe integration & subscriptions
- `storage` - File uploads to R2
- `analytics` - Event tracking & metrics
- `emails` - Email sending via SendGrid

### E-Commerce Platform

```typescript
export default defineApp({
  components: {
    cart: "./components/cart",
    inventory: "./components/inventory",
    orders: "./components/orders",
    payments: "@convex-dev/polar",
    shipping: "./components/shipping",
    recommendations: "./components/recommendations",
  },
});
```

### AI Application

```typescript
export default defineApp({
  components: {
    agent: "@convex-dev/agent",
    embeddings: "./components/embeddings",
    documents: "./components/documents",
    chat: "./components/chat",
    workflow: "@convex-dev/workflow",
  },
});
```

## Migration from Monolithic

**Step 1: Identify Features**
```
Current monolith:
- File uploads (mixed with main app)
- Rate limiting (scattered everywhere)
- Analytics (embedded in functions)
```

**Step 2: Extract One Feature**
```bash
# Create component
mkdir -p convex/components/storage

# Move storage code to component
# Update imports in main app
```

**Step 3: Test Independently**
```bash
# Component has its own tests
# No coupling to main app
```

**Step 4: Repeat**
Extract other features incrementally.

## Best Practices

### 1. Single Responsibility
Each component does ONE thing well:
- ✅ storage component handles files
- ✅ auth component handles authentication
- ❌ Don't create "utils" component with everything

### 2. Clear API Surface
```typescript
// Export only what's needed
export { upload, download, delete } from "./storage";

// Keep internals private
// (Don't export helper functions)
```

### 3. Minimal Coupling
```typescript
// ✅ Good: Pass data as arguments
await components.audit.log(ctx, {
  userId: user._id,
  action: "delete"
});

// ❌ Bad: Component accesses parent tables
// (Not even possible, but shows the principle)
```

### 4. Version Your Components
```json
{
  "name": "@yourteam/notifications-component",
  "version": "1.0.0"
}
```

### 5. Document Your Components
Include README with:
- What the component does
- How to install
- How to use
- API reference
- Examples

## Troubleshooting

### Component not found
```bash
# Make sure component is in convex.config.ts
# Run: npx convex dev
```

### Can't access parent tables
```
This is by design! Components are sandboxed.
Pass data as arguments instead.
```

### Component conflicts
```
Each component has isolated tables.
Components can't see each other's data.
```

## Learn More

- [Components Documentation](https://docs.convex.dev/components)
- [Component Directory](https://www.convex.dev/components)
- [Using Components](https://docs.convex.dev/components/using)
- [Authoring Components](https://docs.convex.dev/components/authoring)
- [Stack: Backend Components](https://stack.convex.dev/backend-components)

## Checklist

- [ ] Browse [Component Directory](https://www.convex.dev/components) for existing solutions
- [ ] Install components via npm: `npm install @convex-dev/component-name`
- [ ] Configure in `convex.config.ts`
- [ ] Use sibling components for feature encapsulation
- [ ] Create your own components for reusable features
- [ ] Keep components focused (single responsibility)
- [ ] Test components in isolation
- [ ] Document component APIs
- [ ] Version your components properly

**Remember:** Components are about encapsulation and reusability. When in doubt, prefer components over monolithic code!
