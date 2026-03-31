---
name: migration-helper
description: Plan and execute Convex schema migrations safely, including adding fields, creating tables, and data transformations. Use when schema changes affect existing data.
---

# Convex Migration Helper

Safely migrate Convex schemas and data when making breaking changes.

## When to Use

- Adding new required fields to existing tables
- Changing field types or structure
- Splitting or merging tables
- Renaming fields
- Migrating from nested to relational data

## Migration Principles

1. **No Automatic Migrations**: Convex doesn't automatically migrate data
2. **Additive Changes are Safe**: Adding optional fields or new tables is safe
3. **Breaking Changes Need Code**: Required fields, type changes need migration code
4. **Zero-Downtime**: Write migrations to keep app running during migration

## Safe Changes (No Migration Needed)

### Adding Optional Field

```typescript
// Before
users: defineTable({
  name: v.string(),
})

// After - Safe! New field is optional
users: defineTable({
  name: v.string(),
  bio: v.optional(v.string()),
})
```

### Adding New Table

```typescript
// Safe to add completely new tables
posts: defineTable({
  userId: v.id("users"),
  title: v.string(),
}).index("by_user", ["userId"])
```

### Adding Index

```typescript
// Safe to add indexes at any time
users: defineTable({
  name: v.string(),
  email: v.string(),
})
  .index("by_email", ["email"]) // New index
```

## Breaking Changes (Migration Required)

### Adding Required Field

**Problem**: Existing documents won't have the new field.

**Solution**: Add as optional first, backfill data, then make required.

```typescript
// Step 1: Add as optional
users: defineTable({
  name: v.string(),
  email: v.optional(v.string()), // Start optional
})

// Step 2: Create migration
import { internalMutation } from "./_generated/server";
import { v } from "convex/values";

export const backfillEmails = internalMutation({
  args: {},
  handler: async (ctx) => {
    const users = await ctx.db.query("users").collect();

    for (const user of users) {
      if (!user.email) {
        await ctx.db.patch(user._id, {
          email: `user-${user._id}@example.com`, // Default value
        });
      }
    }
  },
});

// Step 3: Run migration via dashboard or CLI
// npx convex run migrations:backfillEmails

// Step 4: Make field required (after all data migrated)
users: defineTable({
  name: v.string(),
  email: v.string(), // Now required
})
```

### Changing Field Type

**Example**: Change `tags: v.array(v.string())` to separate table

```typescript
// Step 1: Create new structure (additive)
tags: defineTable({
  name: v.string(),
}).index("by_name", ["name"]),

postTags: defineTable({
  postId: v.id("posts"),
  tagId: v.id("tags"),
})
  .index("by_post", ["postId"])
  .index("by_tag", ["tagId"]),

// Keep old field as optional during migration
posts: defineTable({
  title: v.string(),
  tags: v.optional(v.array(v.string())), // Keep temporarily
})

// Step 2: Write migration
export const migrateTags = internalMutation({
  args: { batchSize: v.optional(v.number()) },
  handler: async (ctx, args) => {
    const batchSize = args.batchSize ?? 100;

    const posts = await ctx.db
      .query("posts")
      .filter(q => q.neq(q.field("tags"), undefined))
      .take(batchSize);

    for (const post of posts) {
      if (!post.tags || post.tags.length === 0) {
        await ctx.db.patch(post._id, { tags: undefined });
        continue;
      }

      // Create tags and relationships
      for (const tagName of post.tags) {
        // Get or create tag
        let tag = await ctx.db
          .query("tags")
          .withIndex("by_name", q => q.eq("name", tagName))
          .unique();

        if (!tag) {
          const tagId = await ctx.db.insert("tags", { name: tagName });
          tag = { _id: tagId, name: tagName };
        }

        // Create relationship
        const existing = await ctx.db
          .query("postTags")
          .withIndex("by_post", q => q.eq("postId", post._id))
          .filter(q => q.eq(q.field("tagId"), tag._id))
          .unique();

        if (!existing) {
          await ctx.db.insert("postTags", {
            postId: post._id,
            tagId: tag._id,
          });
        }
      }

      // Remove old field
      await ctx.db.patch(post._id, { tags: undefined });
    }

    return { migrated: posts.length };
  },
});

// Step 3: Run in batches via cron or manually
// Run multiple times until all migrated

// Step 4: Remove old field from schema
posts: defineTable({
  title: v.string(),
  // tags field removed
})
```

### Renaming Field

```typescript
// Step 1: Add new field (optional)
users: defineTable({
  name: v.string(),
  displayName: v.optional(v.string()), // New name
})

// Step 2: Copy data
export const renameField = internalMutation({
  handler: async (ctx) => {
    const users = await ctx.db.query("users").collect();

    for (const user of users) {
      await ctx.db.patch(user._id, {
        displayName: user.name,
      });
    }
  },
});

// Step 3: Update schema (remove old field)
users: defineTable({
  displayName: v.string(),
})

// Step 4: Update all code to use new field name
```

## Migration Patterns

### Batch Processing

For large tables, process in batches:

```typescript
export const migrateBatch = internalMutation({
  args: {
    cursor: v.optional(v.string()),
    batchSize: v.number(),
  },
  handler: async (ctx, args) => {
    const batchSize = args.batchSize;
    let query = ctx.db.query("largeTable");

    // Use cursor for pagination if needed
    const items = await query.take(batchSize);

    for (const item of items) {
      await ctx.db.patch(item._id, {
        // migration logic
      });
    }

    return {
      processed: items.length,
      hasMore: items.length === batchSize,
    };
  },
});
```

### Scheduled Migration

Use cron jobs for gradual migration:

```typescript
// convex/crons.ts
import { cronJobs } from "convex/server";
import { internal } from "./_generated/api";

const crons = cronJobs();

crons.interval(
  "migrate-batch",
  { minutes: 5 }, // Every 5 minutes
  internal.migrations.migrateBatch,
  { batchSize: 100 }
);

export default crons;
```

### Dual-Write Pattern

For zero-downtime migrations:

```typescript
// Write to both old and new structure during transition
export const createPost = mutation({
  args: { title: v.string(), tags: v.array(v.string()) },
  handler: async (ctx, args) => {
    const user = await getCurrentUser(ctx);

    // Create post
    const postId = await ctx.db.insert("posts", {
      userId: user._id,
      title: args.title,
      // Keep writing old field during migration
      tags: args.tags,
    });

    // ALSO write to new structure
    for (const tagName of args.tags) {
      let tag = await ctx.db
        .query("tags")
        .withIndex("by_name", q => q.eq("name", tagName))
        .unique();

      if (!tag) {
        const tagId = await ctx.db.insert("tags", { name: tagName });
        tag = { _id: tagId };
      }

      await ctx.db.insert("postTags", {
        postId,
        tagId: tag._id,
      });
    }

    return postId;
  },
});

// After migration complete, remove old writes
```

## Testing Migrations

### Verify Migration Success

```typescript
export const verifyMigration = query({
  args: {},
  handler: async (ctx) => {
    const total = (await ctx.db.query("users").collect()).length;
    const migrated = (await ctx.db
      .query("users")
      .filter(q => q.neq(q.field("newField"), undefined))
      .collect()
    ).length;

    return {
      total,
      migrated,
      remaining: total - migrated,
      percentComplete: (migrated / total) * 100,
    };
  },
});
```

## Migration Checklist

- [ ] Identify breaking change
- [ ] Add new structure as optional/additive
- [ ] Write migration function (internal mutation)
- [ ] Test migration on sample data
- [ ] Run migration in batches if large dataset
- [ ] Verify migration completed (all records updated)
- [ ] Update application code to use new structure
- [ ] Deploy new code
- [ ] Remove old fields from schema
- [ ] Clean up migration code

## Common Pitfalls

1. **Don't make field required immediately**: Always add as optional first
2. **Don't migrate in a single transaction**: Batch large migrations
3. **Don't forget to update queries**: Update all code using old field
4. **Don't delete old field too soon**: Wait until all data migrated
5. **Test thoroughly**: Verify migration on dev environment first

## Example: Complete Migration Flow

```typescript
// 1. Current schema
export default defineSchema({
  users: defineTable({
    name: v.string(),
  }),
});

// 2. Add optional field
export default defineSchema({
  users: defineTable({
    name: v.string(),
    role: v.optional(v.union(
      v.literal("user"),
      v.literal("admin")
    )),
  }),
});

// 3. Migration function
export const addDefaultRoles = internalMutation({
  handler: async (ctx) => {
    const users = await ctx.db.query("users").collect();
    for (const user of users) {
      if (!user.role) {
        await ctx.db.patch(user._id, { role: "user" });
      }
    }
  },
});

// 4. Run migration: npx convex run migrations:addDefaultRoles

// 5. Verify: Check all users have role

// 6. Make required
export default defineSchema({
  users: defineTable({
    name: v.string(),
    role: v.union(
      v.literal("user"),
      v.literal("admin")
    ),
  }),
});
```
