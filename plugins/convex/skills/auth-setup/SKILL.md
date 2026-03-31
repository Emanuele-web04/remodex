---
name: auth-setup
description: Set up Convex authentication with proper user management, identity mapping, and access control patterns. Use when implementing auth flows.
---

# Convex Authentication Setup

Implement secure authentication in Convex with user management and access control.

## When to Use

- Setting up authentication for the first time
- Implementing user management (users table, identity mapping)
- Creating authentication helper functions
- Setting up OAuth providers (WorkOS, Auth0, etc.)

## Architecture Overview

Convex authentication has two main parts:

1. **Client Authentication**: Use a provider (WorkOS, Auth0, custom JWT)
2. **Backend Identity**: Map auth provider identity to your users table

## Schema Setup

```typescript
// convex/schema.ts
import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  users: defineTable({
    // From auth provider identity
    tokenIdentifier: v.string(), // Unique per auth provider

    // User profile data
    name: v.string(),
    email: v.string(),
    pictureUrl: v.optional(v.string()),

    // Your app-specific fields
    role: v.union(
      v.literal("user"),
      v.literal("admin")
    ),

    createdAt: v.number(),
    updatedAt: v.optional(v.number()),
  })
    .index("by_token", ["tokenIdentifier"])
    .index("by_email", ["email"]),
});
```

## Core Helper Functions

### Get Current User

```typescript
// convex/lib/auth.ts
import { QueryCtx, MutationCtx } from "./_generated/server";
import { Doc } from "./_generated/dataModel";

export async function getCurrentUser(
  ctx: QueryCtx | MutationCtx
): Promise<Doc<"users">> {
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

  if (!user) {
    throw new Error("User not found");
  }

  return user;
}

export async function getCurrentUserOrNull(
  ctx: QueryCtx | MutationCtx
): Promise<Doc<"users"> | null> {
  const identity = await ctx.auth.getUserIdentity();
  if (!identity) {
    return null;
  }

  return await ctx.db
    .query("users")
    .withIndex("by_token", q =>
      q.eq("tokenIdentifier", identity.tokenIdentifier)
    )
    .unique();
}
```

### Require Admin

```typescript
export async function requireAdmin(
  ctx: QueryCtx | MutationCtx
): Promise<Doc<"users">> {
  const user = await getCurrentUser(ctx);

  if (user.role !== "admin") {
    throw new Error("Admin access required");
  }

  return user;
}
```

## User Creation/Upsert

### On First Sign-In

```typescript
// convex/users.ts
import { mutation } from "./_generated/server";
import { v } from "convex/values";

export const storeUser = mutation({
  args: {},
  handler: async (ctx) => {
    const identity = await ctx.auth.getUserIdentity();
    if (!identity) {
      throw new Error("Not authenticated");
    }

    // Check if user exists
    const existingUser = await ctx.db
      .query("users")
      .withIndex("by_token", q =>
        q.eq("tokenIdentifier", identity.tokenIdentifier)
      )
      .unique();

    if (existingUser) {
      // Update last seen or other fields
      await ctx.db.patch(existingUser._id, {
        updatedAt: Date.now(),
      });
      return existingUser._id;
    }

    // Create new user
    const userId = await ctx.db.insert("users", {
      tokenIdentifier: identity.tokenIdentifier,
      name: identity.name ?? "Anonymous",
      email: identity.email ?? "",
      pictureUrl: identity.pictureUrl,
      role: "user",
      createdAt: Date.now(),
    });

    return userId;
  },
});
```

## Access Control Patterns

### Owner-Only Access

```typescript
import { mutation } from "./_generated/server";
import { v } from "convex/values";
import { getCurrentUser } from "./lib/auth";

export const updateProfile = mutation({
  args: {
    name: v.string(),
  },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);

    await ctx.db.patch(user._id, {
      name: args.name,
      updatedAt: Date.now(),
    });
  },
});
```

### Resource Ownership

```typescript
export const deleteTask = mutation({
  args: { taskId: v.id("tasks") },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);

    const task = await ctx.db.get(args.taskId);
    if (!task) {
      throw new Error("Task not found");
    }

    // Check ownership
    if (task.userId !== user._id) {
      throw new Error("You can only delete your own tasks");
    }

    await ctx.db.delete(args.taskId);
  },
});
```

### Team-Based Access

```typescript
// Schema includes membership table
export default defineSchema({
  teams: defineTable({
    name: v.string(),
    ownerId: v.id("users"),
  }),

  teamMembers: defineTable({
    teamId: v.id("teams"),
    userId: v.id("users"),
    role: v.union(v.literal("owner"), v.literal("member")),
  })
    .index("by_team", ["teamId"])
    .index("by_user", ["userId"])
    .index("by_team_and_user", ["teamId", "userId"]),
});

// Helper to check team access
async function requireTeamAccess(
  ctx: MutationCtx,
  teamId: Id<"teams">
): Promise<{ user: Doc<"users">, membership: Doc<"teamMembers"> }> {
  const user = await getCurrentUser(ctx);

  const membership = await ctx.db
    .query("teamMembers")
    .withIndex("by_team_and_user", q =>
      q.eq("teamId", teamId).eq("userId", user._id)
    )
    .unique();

  if (!membership) {
    throw new Error("You don't have access to this team");
  }

  return { user, membership };
}

// Use in functions
export const createProject = mutation({
  args: {
    teamId: v.id("teams"),
    name: v.string(),
  },
  handler: async (ctx, args) => {
    await requireTeamAccess(ctx, args.teamId);

    return await ctx.db.insert("projects", {
      teamId: args.teamId,
      name: args.name,
    });
  },
});
```

## Public vs Private Queries

### Public Query (No Auth Required)

```typescript
export const listPublicPosts = query({
  args: {},
  handler: async (ctx) => {
    // No auth check - anyone can read
    return await ctx.db
      .query("posts")
      .withIndex("by_published", q => q.eq("published", true))
      .collect();
  },
});
```

### Private Query (Auth Required)

```typescript
export const getMyPosts = query({
  args: {},
  handler: async (ctx) => {
    const user = await getCurrentUser(ctx);

    return await ctx.db
      .query("posts")
      .withIndex("by_user", q => q.eq("userId", user._id))
      .collect();
  },
});
```

### Hybrid Query (Optional Auth)

```typescript
export const getPosts = query({
  args: {},
  handler: async (ctx) => {
    const user = await getCurrentUserOrNull(ctx);

    if (user) {
      // Show all posts including drafts for this user
      return await ctx.db
        .query("posts")
        .withIndex("by_user", q => q.eq("userId", user._id))
        .collect();
    } else {
      // Show only public posts for anonymous users
      return await ctx.db
        .query("posts")
        .withIndex("by_published", q => q.eq("published", true))
        .collect();
    }
  },
});
```

## Client Setup with WorkOS

WorkOS AuthKit provides a complete authentication solution with minimal setup.

### React/Vite Setup

```bash
npm install @workos-inc/authkit-react
```

```typescript
// src/main.tsx
import { AuthKitProvider, useAuth } from "@workos-inc/authkit-react";
import { ConvexReactClient } from "convex/react";
import { ConvexProvider } from "convex/react";

const convex = new ConvexReactClient(import.meta.env.VITE_CONVEX_URL);

// Configure Convex to use WorkOS auth
convex.setAuth(useAuth);

function App() {
  return (
    <AuthKitProvider clientId={import.meta.env.VITE_WORKOS_CLIENT_ID}>
      <ConvexProvider client={convex}>
        <YourApp />
      </ConvexProvider>
    </AuthKitProvider>
  );
}
```

### Next.js Setup

```bash
npm install @workos-inc/authkit-nextjs
```

```typescript
// app/layout.tsx
import { AuthKitProvider } from "@workos-inc/authkit-nextjs";
import { ConvexClientProvider } from "./ConvexClientProvider";

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html>
      <body>
        <AuthKitProvider>
          <ConvexClientProvider>
            {children}
          </ConvexClientProvider>
        </AuthKitProvider>
      </body>
    </html>
  );
}
```

```typescript
// app/ConvexClientProvider.tsx
"use client";

import { ConvexReactClient } from "convex/react";
import { ConvexProvider } from "convex/react";
import { useAuth } from "@workos-inc/authkit-nextjs";

const convex = new ConvexReactClient(process.env.NEXT_PUBLIC_CONVEX_URL!);

export function ConvexClientProvider({ children }: { children: React.ReactNode }) {
  const { getToken } = useAuth();

  convex.setAuth(async () => {
    return await getToken();
  });

  return <ConvexProvider client={convex}>{children}</ConvexProvider>;
}
```

### Environment Variables

```bash
# .env.local (React/Vite)
VITE_CONVEX_URL=https://your-deployment.convex.cloud
VITE_WORKOS_CLIENT_ID=your_workos_client_id

# .env.local (Next.js)
NEXT_PUBLIC_CONVEX_URL=https://your-deployment.convex.cloud
NEXT_PUBLIC_WORKOS_CLIENT_ID=your_workos_client_id
WORKOS_API_KEY=your_workos_api_key
WORKOS_COOKIE_PASSWORD=generate_a_random_32_character_string
```

### Call storeUser on Sign-In

```typescript
// In your app after user signs in
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";
import { useEffect } from "react";
import { useAuth } from "@workos-inc/authkit-react";

function YourApp() {
  const { user } = useAuth();
  const storeUser = useMutation(api.users.storeUser);

  useEffect(() => {
    if (user) {
      storeUser();
    }
  }, [user, storeUser]);

  // ... rest of your app
}
```

### Alternative Auth Providers

If you need to use a different provider, see the [Convex auth documentation](https://docs.convex.dev/auth) for:
- Custom JWT
- Auth0
- Other OAuth providers

## Checklist

- [ ] Users table with `tokenIdentifier` index
- [ ] `getCurrentUser` helper function
- [ ] `storeUser` mutation for first sign-in
- [ ] Authentication check in all protected functions
- [ ] Authorization check for resource access
- [ ] Clear error messages ("Not authenticated", "Unauthorized")
- [ ] Client auth provider configured (WorkOS, Auth0, etc.)
