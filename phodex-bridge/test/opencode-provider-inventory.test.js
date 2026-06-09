// FILE: opencode-provider-inventory.test.js
// Purpose: Connected-only OpenCode provider inventory (CR-1 fixtures).

const { describe, test } = require("node:test");
const assert = require("node:assert/strict");

const {
  resolvePreferredProviders,
  flattenConnectedProviderModels,
  discoveryReasonCodeFromInventory,
  buildInventoryMeta,
  buildProviderInventory,
  buildProviderLogoCatalog,
  resolveLogoProviderId,
  stripVariantSuffixes,
  COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS,
  PROVIDER_LOGO_ID_ALIASES,
} = require("../src/opencode-provider-inventory");

function makeProvider({ id, name, source = "api", models = {} }) {
  return { id, name, source, models, env: [] };
}

describe("resolvePreferredProviders — MVP credentialProviderIDs: []", () => {
  test("Mac A: only connected anthropic models, not env openai in all", () => {
    const inventory = {
      connected: ["anthropic"],
      all: [
        makeProvider({
          id: "anthropic",
          name: "Anthropic",
          models: { "claude-sonnet": { id: "claude-sonnet", name: "Claude Sonnet" } },
        }),
        makeProvider({
          id: "openai",
          name: "OpenAI",
          source: "env",
          models: { "gpt-4": { id: "gpt-4", name: "GPT-4" } },
        }),
      ],
    };

    const preferred = resolvePreferredProviders(inventory, { credentialProviderIDs: [] });
    assert.deepEqual(
      preferred.map((p) => p.id),
      ["anthropic"],
    );
    const models = flattenConnectedProviderModels(preferred);
    assert.equal(models.length, 1);
    assert.equal(models[0].upstreamProviderId, "anthropic");
    assert.equal(models[0].upstreamProviderDisplayName, "Anthropic");
  });

  test("Mac B: env-only openai connected shows models (tier 5 fallback)", () => {
    const inventory = {
      connected: ["openai"],
      all: [
        makeProvider({
          id: "openai",
          name: "OpenAI",
          source: "env",
          models: { "gpt-4": { id: "gpt-4", name: "GPT-4" } },
        }),
      ],
    };

    const preferred = resolvePreferredProviders(inventory, { credentialProviderIDs: [] });
    assert.deepEqual(preferred.map((p) => p.id), ["openai"]);
    assert.equal(flattenConnectedProviderModels(preferred).length, 1);
  });

  test("Mac C: empty connected returns no preferred providers", () => {
    const inventory = {
      connected: [],
      all: [
        makeProvider({
          id: "anthropic",
          name: "Anthropic",
          models: { x: { id: "x", name: "X" } },
        }),
      ],
    };

    assert.deepEqual(resolvePreferredProviders(inventory), []);
    assert.equal(discoveryReasonCodeFromInventory(inventory), "no_connected_providers");
    const meta = buildInventoryMeta({ inventory, models: [] });
    assert.equal(meta.reasonCode, "no_connected_providers");
    assert.deepEqual(meta.connectedProviderIds, []);
  });

  test("prefers OpenCode-managed over generic api when no credentials", () => {
    const inventory = {
      connected: ["openai", "opencode"],
      all: [
        makeProvider({ id: "openai", name: "OpenAI", source: "api", models: { a: { id: "a", name: "A" } } }),
        makeProvider({
          id: "opencode",
          name: "OpenCode",
          source: "api",
          models: { free: { id: "free", name: "Free" } },
        }),
      ],
    };

    const preferred = resolvePreferredProviders(inventory, { credentialProviderIDs: [] });
    assert.deepEqual(preferred.map((p) => p.id), ["opencode"]);
  });

  test("mixed env and api connected returns all connected providers", () => {
    const inventory = {
      connected: ["openai", "anthropic"],
      all: [
        makeProvider({
          id: "openai",
          name: "OpenAI",
          source: "env",
          models: { "gpt-4": { id: "gpt-4", name: "GPT-4" } },
        }),
        makeProvider({
          id: "anthropic",
          name: "Anthropic",
          source: "api",
          models: { "claude-sonnet": { id: "claude-sonnet", name: "Claude Sonnet" } },
        }),
      ],
    };

    const preferred = resolvePreferredProviders(inventory, {
      credentialProviderIDs: ["openai", "anthropic"],
    });
    assert.deepEqual(preferred.map((provider) => provider.id).sort(), ["anthropic", "openai"]);
    assert.equal(flattenConnectedProviderModels(preferred).length, 2);
  });

  test("falls back to non-env connected when no opencode-managed", () => {
    const inventory = {
      connected: ["cloudflare-ai-gateway", "openai"],
      all: [
        makeProvider({
          id: "cloudflare-ai-gateway",
          name: "Cloudflare",
          source: "env",
          models: {},
        }),
        makeProvider({
          id: "openai",
          name: "OpenAI",
          source: "api",
          models: { gpt: { id: "gpt", name: "GPT" } },
        }),
      ],
    };

    const preferred = resolvePreferredProviders(inventory, { credentialProviderIDs: [] });
    assert.deepEqual(preferred.map((p) => p.id), ["openai"]);
  });
});

describe("resolveInventoryReasonCode", () => {
  test("orphaned connected IDs without models yield unknown not ok", () => {
    const { resolveInventoryReasonCode } = require("../src/opencode-provider-inventory");
    const inventory = {
      connected: ["missing-provider"],
      all: [
        makeProvider({
          id: "anthropic",
          name: "Anthropic",
          models: { x: { id: "x", name: "X" } },
        }),
      ],
    };
    assert.equal(resolveInventoryReasonCode(inventory, []), "unknown");
  });

  test("connected with models stays ok", () => {
    const { resolveInventoryReasonCode, flattenConnectedProviderModels, resolvePreferredProviders } =
      require("../src/opencode-provider-inventory");
    const inventory = {
      connected: ["anthropic"],
      all: [
        makeProvider({
          id: "anthropic",
          name: "Anthropic",
          models: { x: { id: "x", name: "X" } },
        }),
      ],
    };
    const preferred = resolvePreferredProviders(inventory, { credentialProviderIDs: [] });
    const models = flattenConnectedProviderModels(preferred);
    assert.equal(resolveInventoryReasonCode(inventory, models), "ok");
  });
});

describe("buildProviderInventory", () => {
  test("authenticated disconnected provider appears once", () => {
    const inventory = {
      connected: ["opencode-go"],
      all: [
        makeProvider({
          id: "opencode-go",
          name: "OpenCode Go",
          models: { flash: { id: "flash", name: "Flash" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, {
      credentialProviderIDs: ["deepseek", "opencode-go"],
    });
    const deepseek = rows.find((row) => row.id === "deepseek");
    assert.ok(deepseek);
    assert.equal(deepseek.connectedOnServe, false);
    assert.equal(deepseek.authenticated, true);
    assert.equal(rows.filter((row) => row.id.toLowerCase() === "opencode-go").length, 1);
  });

  test("OpenCode Go inventory row gets logoProviderId opencode-go", () => {
    const inventory = {
      connected: ["opencode-go"],
      all: [
        makeProvider({
          id: "opencode-go",
          name: "OpenCode Go",
          models: { free: { id: "free", name: "Free" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const go = rows.find((row) => row.id === "opencode-go");
    assert.ok(go);
    assert.equal(go.logoProviderId, "opencode-go");
    assert.equal(go.logoAssetId, "provider-opencode-go-logo");
    assert.equal(resolveLogoProviderId("opencode-go", "OpenCode Go"), "opencode-go");
  });

  test("OpenCode Zen inventory row gets logoProviderId opencode-zen", () => {
    const inventory = {
      connected: ["opencode"],
      all: [
        makeProvider({
          id: "opencode",
          name: "OpenCode Zen",
          models: { free: { id: "free", name: "Free" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const zen = rows.find((row) => row.id === "opencode");
    assert.ok(zen);
    assert.equal(zen.displayName, "OpenCode Zen");
    assert.equal(zen.logoProviderId, "opencode-zen");
    assert.equal(zen.logoAssetId, "provider-opencode-zen-logo");
    assert.equal(resolveLogoProviderId("opencode", "OpenCode Zen"), "opencode-zen");
  });

  test("OpenCode Zenith gets opencode logoProviderId", () => {
    assert.equal(resolveLogoProviderId("opencode", "OpenCode Zenith"), "opencode");
    const inventory = {
      connected: ["opencode"],
      all: [
        makeProvider({
          id: "opencode",
          name: "OpenCode Zenith",
          models: { free: { id: "free", name: "Free" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const row = rows.find((entry) => entry.id === "opencode");
    assert.ok(row);
    assert.equal(row.displayName, "OpenCode Zenith");
    assert.equal(row.logoProviderId, "opencode");
    assert.equal(row.logoAssetId, "provider-opencode-logo");
  });

  test("generic opencode provider has opencode logoProviderId", () => {
    const inventory = {
      connected: ["opencode"],
      all: [
        makeProvider({
          id: "opencode",
          name: "OpenCode",
          models: { free: { id: "free", name: "Free" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const row = rows.find((entry) => entry.id === "opencode");
    assert.ok(row);
    assert.equal(row.logoProviderId, "opencode");
    assert.equal(row.logoAssetId, "provider-opencode-logo");
  });

  test("anthropic inventory row gets logoAssetId from committed catalog", () => {
    const inventory = {
      connected: ["anthropic"],
      all: [
        makeProvider({
          id: "anthropic",
          name: "Anthropic",
          models: { sonnet: { id: "sonnet", name: "Sonnet" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const anthropic = rows.find((row) => row.id === "anthropic");
    assert.ok(anthropic);
    assert.equal(anthropic.logoProviderId, "anthropic");
    assert.equal(anthropic.logoAssetId, "provider-anthropic-logo");
  });

  test("amazon-bedrock alias resolves to bedrock logoAssetId", () => {
    const inventory = {
      connected: ["amazon-bedrock"],
      all: [
        makeProvider({
          id: "amazon-bedrock",
          name: "Amazon Bedrock",
          models: { claude: { id: "claude", name: "Claude" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const bedrock = rows.find((row) => row.id === "amazon-bedrock");
    assert.ok(bedrock);
    assert.equal(bedrock.logoProviderId, "bedrock");
    assert.equal(bedrock.logoAssetId, "provider-bedrock-logo");
    assert.equal(resolveLogoProviderId("amazon-bedrock", "Amazon Bedrock"), "bedrock");
  });

  test("github-copilot alias resolves to github logoAssetId", () => {
    assert.equal(resolveLogoProviderId("github-copilot", "GitHub Copilot"), "github");
    const inventory = {
      connected: ["github-copilot"],
      all: [
        makeProvider({
          id: "github-copilot",
          name: "GitHub Copilot",
          models: { gpt: { id: "gpt", name: "GPT" } },
        }),
      ],
    };
    const rows = buildProviderInventory(inventory, { credentialProviderIDs: [] });
    const row = rows.find((entry) => entry.id === "github-copilot");
    assert.ok(row);
    assert.equal(row.logoAssetId, "provider-github-logo");
  });

  test("dedupes canonical id casing from all[]", () => {
    const inventory = {
      connected: ["openai"],
      all: [makeProvider({ id: "OpenAI", name: "OpenAI", models: {} })],
    };
    const rows = buildProviderInventory(inventory, {
      credentialProviderIDs: ["openai"],
    });
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, "OpenAI");
  });
});

describe("resolveLogoProviderId — committed external assets", () => {
  test("maps all 56 committed providers to logoAssetId ids", () => {
    assert.equal(COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.size, 56);
    for (const logoProviderId of COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS) {
      assert.equal(
        resolveLogoProviderId(logoProviderId, ""),
        logoProviderId,
        `expected direct match for ${logoProviderId}`,
      );
    }
  });

  test("maps upstream aliases to committed logo provider ids", () => {
    for (const [upstreamId, logoProviderId] of Object.entries(PROVIDER_LOGO_ID_ALIASES)) {
      assert.equal(resolveLogoProviderId(upstreamId, ""), logoProviderId);
      assert.ok(
        COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.has(logoProviderId),
        `alias target ${logoProviderId} must be committed`,
      );
    }
  });

  test("buildProviderLogoCatalog exposes logoAssetId for key providers", () => {
    const catalog = buildProviderLogoCatalog([
      { id: "anthropic", displayName: "Anthropic", logoProviderId: "anthropic", logoAssetId: "provider-anthropic-logo" },
      { id: "openai", displayName: "OpenAI", logoProviderId: "openai", logoAssetId: "provider-openai-logo" },
      { id: "ollama", displayName: "Ollama" },
    ]);
    assert.equal(catalog.length, 3);
    assert.equal(catalog[0].logoAssetId, "provider-anthropic-logo");
    assert.equal(catalog[1].logoAssetId, "provider-openai-logo");
    assert.equal(catalog[2].logoAssetId, undefined);
  });

  test("unknown provider has no logoProviderId", () => {
    assert.equal(resolveLogoProviderId("abacus", "Abacus"), undefined);
  });

  test("variant suffix stripping maps regional/plan variants to parent logo", () => {
    assert.equal(resolveLogoProviderId("alibaba-coding-plan-cn", ""), "alibaba");
    assert.equal(resolveLogoProviderId("minimax-cn-coding-plan", ""), "minimax");
    assert.equal(resolveLogoProviderId("zai-coding-plan", ""), "zai");
    assert.equal(resolveLogoProviderId("siliconflow-cn", ""), "siliconflow");
    assert.equal(resolveLogoProviderId("xiaomi-token-plan-cn", ""), "xiaomi");
    assert.equal(resolveLogoProviderId("tencent-tokenhub", ""), "tencent");
  });

  test("explicit aliases resolve to committed logo assets", () => {
    for (const [upstream, canonical] of Object.entries(PROVIDER_LOGO_ID_ALIASES)) {
      const result = resolveLogoProviderId(upstream, "");
      assert.equal(result, canonical, `alias ${upstream} -> ${canonical}`);
      assert.ok(
        COMMITTED_EXTERNAL_LOGO_PROVIDER_IDS.has(canonical),
        `alias target ${canonical} must be committed`,
      );
    }
  });
});

describe("stripVariantSuffixes", () => {
  test("strips longest compound suffix first", () => {
    assert.equal(stripVariantSuffixes("alibaba-coding-plan-cn"), "alibaba-coding-plan");
    assert.equal(stripVariantSuffixes("minimax-cn-coding-plan"), "minimax");
  });

  test("strips single suffixes", () => {
    assert.equal(stripVariantSuffixes("zai-coding-plan"), "zai");
    assert.equal(stripVariantSuffixes("siliconflow-cn"), "siliconflow");
    assert.equal(stripVariantSuffixes("xiaomi-token-plan-cn"), "xiaomi-token-plan");
    assert.equal(stripVariantSuffixes("tencent-tokenhub"), "tencent");
  });

  test("returns id unchanged when no suffix matches", () => {
    assert.equal(stripVariantSuffixes("anthropic"), "anthropic");
    assert.equal(stripVariantSuffixes("openai"), "openai");
  });

  test("does not strip nested suffixes recursively", () => {
    assert.equal(stripVariantSuffixes("foo-ai-ai"), "foo-ai");
    assert.equal(stripVariantSuffixes("bar-cn-cn"), "bar-cn");
  });
});

describe("discoveryReasonCodeFromInventory", () => {
  test("unknown when connected key missing", () => {
    assert.equal(discoveryReasonCodeFromInventory({ all: [] }), "unknown");
  });

  test("ok when connected non-empty", () => {
    assert.equal(discoveryReasonCodeFromInventory({ connected: ["anthropic"], all: [] }), "ok");
  });
});